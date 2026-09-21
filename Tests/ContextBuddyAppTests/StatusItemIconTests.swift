import AppKit
import XCTest
import ContextBuddyCore
@testable import ContextBuddyApp

// Coverage for the §9.1 icon contract (SPEC.md §9.1).
//
// The regression this guards (#34): NSImageView (like the NSButton that drew
// the icon before #35) only recolors a *template* image. When the status
// item's image was marked `isTemplate = false`, every per-state tint in
// IconStyle was discarded — four of the seven states drew pure black,
// invisible on a dark menu bar, and the rest drew SF Symbols' multicolor
// variants. #90 retired those tints in favour of the system's own colour, and
// `isTemplate` became more load-bearing rather than less: it is now the only
// channel through which the glyph gets any colour at all.
//
// The §9.2 motion section asserts on StatusItemIcon.Motion, the record the
// hosted image view keeps of the effects it started: NSImageView exposes no
// list of running symbol effects, and what plays on screen is a human check.
//
// Three kinds of assertion here, deliberately kept apart:
//
//   * Contrast floors are computed from the *resolved ink colour*, read from a
//     pixel the glyph fully covers, against each appearance's measured band of
//     menu bar backgrounds (#90). A fully covered pixel carries the system's
//     chosen colour exactly, at any raster scale.
//
//   * Direction — which side of the bar the glyph lands on — is asserted from
//     rendered pixels, because it is stable across raster scales even where
//     magnitude is not.
//
//   * Ink coverage and silhouette are asserted separately from contrast, so a
//     legible colour cannot ship as an invisible hairline and two states
//     cannot collapse into one shape now that colour no longer separates them.
//
// Absolute contrast must NOT be asserted on an alpha-weighted *mean* over
// rendered pixels. That mean is dominated by partially covered edge pixels, so
// the same glyph measures 1.73:1 at 1x and 6.76:1 at 2x — a number describing
// the rasterizer, not the colour. An earlier revision of this file did exactly
// that and passed locally while failing on CI. Reading one fully covered pixel
// is not the same mistake; `resolvedInk` asserts the coverage before it trusts
// the colour.
//
// Needs an NSApplication: `bitmapImageRepForCachingDisplay` and `cacheDisplay`
// draw through AppKit, so `makeButton` bootstraps one.
@MainActor
final class StatusItemIconTests: XCTestCase {

    // §9.1's contrast basis (#90). The menu bar is transparent, not a grey:
    // measured on macOS 26.6.2 by sweeping the desktop picture from black to
    // white and reading the bar back out of screen captures, it runs L=0.0000
    // over a black picture to L=0.9647 over a white one. The two constants
    // this replaced — sRGB 0.11 and 0.96 — described a bar that does not occur.
    //
    // macOS also switches the status item's *effective appearance* with the
    // wallpaper's brightness while the system stays in Dark Mode, verified
    // with a probe status item tinted blue under .darkAqua and red under
    // .aqua. So each appearance covers its own band, and the bands are
    // disjoint: wallpaper 160 gives a .darkAqua bar at L=0.195, wallpaper 168
    // an .aqua bar at L=0.546, with nothing reachable in between. An earlier
    // draft of this issue proposed asserting against L=0.35; no bar presents
    // it.
    //
    // Luminances, not sRGB channel values. Colorimetry.grey(forLuminance:)
    // converts, because `render` and the compositing below take a channel.
    private static let darkAquaBand: [Double] = [0.000, 0.050, 0.120, 0.160, 0.195]
    private static let aquaBand: [Double] = [0.546, 0.630, 0.750, 0.870, 0.965]

    private static let bands: [(NSAppearance.Name, [Double])] = [
        (.darkAqua, darkAquaBand), (.aqua, aquaBand)
    ]

    // The floor §9.1 commits to, and it is a ceiling as much as a floor: pure
    // white over the top of the .darkAqua band (L=0.195) is 4.29:1, so 4.5:1
    // is not reachable there by any colour, tinted or system-supplied. macOS
    // does not reach it either — Docker's icon measured 3.93:1 at that
    // background in the same capture as ContextBuddy's 3.92:1. Raising this
    // above 4.29 asserts something no menu bar icon on this platform can do.
    private static let contrastFloor = 4.2

    // One background per appearance, for the tests that are about ink or
    // shape rather than about the band. Interior points, not extremes.
    private static let menuBars: [(NSAppearance.Name, Double)] = [
        (.darkAqua, Colorimetry.grey(forLuminance: 0.050)),
        (.aqua, Colorimetry.grey(forLuminance: 0.870))
    ]

    // MARK: - §9.1 contrast, from the resolved ink

    // The mechanism the whole floor now rests on (#90). Every glyph ships as a
    // template image with `contentTintColor` nil, which is what lets the system
    // colour it against the bar. Declaring any colour opts the glyph out of
    // that and pins it to one side, which is how five of the seven states came
    // to sit below their stated floor on a real screen.
    //
    // This is the cheapest test in the file and the one that matters most: the
    // numbers in §9.1 are measured on a real menu bar, and the only thing a
    // unit test can hold is that the mechanism producing them is still engaged.
    func testEveryStateShipsAnUntintedTemplateSoTheSystemColoursIt() {
        for state in BuddyState.allCases {
            let button = makeButton(appearance: .darkAqua)
            StatusItemIcon.apply(state: state, animationsEnabled: false, to: button)
            guard let view = StatusItemIcon.imageView(in: button) else {
                XCTFail("\(state.rawValue): apply installed no StatusIconImageView"); continue
            }
            XCTAssertNil(
                view.contentTintColor,
                "\(state.rawValue) declares a tint. That opts the glyph out of the system's "
                + "inversion against the menu bar (§9.1, #90) — the bar is transparent and the "
                + "system, not this repo, picks the colour."
            )
            XCTAssertEqual(
                view.image?.isTemplate, true,
                "\(state.rawValue) is not a template image, so the system cannot colour it"
            )
        }
    }

    // What the resolved ink is, and why the absolute floor is NOT asserted here.
    //
    // Offscreen there is no menu bar and no vibrancy source, and the view sets
    // `allowsVibrancy`, so an untinted template resolves to the equivalent of
    // `.secondaryLabelColor` — measured pure white at alpha 0.549 under
    // .darkAqua and pure black at alpha 0.502 under .aqua, identical for all
    // seven states. On a real bar the same glyph measures ink at rgb 230-242
    // on a dark bar and 27-35 on a light one. Compositing the offscreen colour
    // over a band background yields 2.44:1 at the top of the .darkAqua band,
    // which describes `xctest` and not the product.
    //
    // So §9.1's numbers are measured from a screen capture of the running
    // status item and recorded there; the PR that changes them carries the
    // capture. Asserting a fabricated offscreen ratio is the mistake #90 was
    // filed about, and it is not repeated here in the other direction.
    //
    // What offscreen rendering *can* prove, and what this asserts, is that the
    // ink is the achromatic pole of its appearance: white on a dark bar, black
    // on a light one, with no hue of its own. A tint creeping back in — the
    // regression this whole change removes — fails here immediately, because
    // every one of §9.1's retired tints carried either a hue or the wrong pole.
    func testResolvedInkIsTheAchromaticPoleOfItsAppearance() {
        for (appearance, _) in Self.bands {
            let wantsWhite = appearance == .darkAqua
            for state in BuddyState.allCases {
                let ink = resolvedInk(state, appearance: appearance)
                XCTAssertGreaterThan(
                    ink.alpha, 0.3,
                    "\(state.rawValue) on \(appearance.rawValue) painted no ink to read"
                )
                let (red, green, blue) = ink.rgb
                let high = max(red, max(green, blue))
                let low = min(red, min(green, blue))
                XCTAssertEqual(
                    high - low, 0, accuracy: 0.02,
                    "\(state.rawValue) on \(appearance.rawValue) carries a hue: rgb "
                    + "\(Colorimetry.f(red)), \(Colorimetry.f(green)), \(Colorimetry.f(blue)). "
                    + "The system colours the glyph now — nothing may set contentTintColor."
                )
                if wantsWhite {
                    XCTAssertGreaterThan(high, 0.98,
                                         "\(state.rawValue) on a dark bar resolves to "
                                         + "\(Colorimetry.f(high)), not the white pole")
                } else {
                    XCTAssertLessThan(low, 0.02,
                                      "\(state.rawValue) on a light bar resolves to "
                                      + "\(Colorimetry.f(low)), not the black pole")
                }
            }
        }
    }

    // The property that makes one band belong to one appearance: the glyph
    // lands on the opposite side of the bar from the bar itself, at every
    // background in that appearance's band. A colour hardcoded to one side
    // inverts the other half of the range, and direction is stable across
    // raster scales even though magnitude is not.
    //
    // Before #90 this covered only sleep/idle/busy, the three achromatic
    // states. Now that the system colours all seven, all seven must invert.
    func testEveryStateInvertsAgainstTheBarAcrossTheWholeBand() {
        for (appearance, band) in Self.bands {
            let darkBar = appearance == .darkAqua
            for state in BuddyState.allCases {
                for luminance in band {
                    let background = Colorimetry.grey(forLuminance: luminance)
                    let measured = render(state, appearance: appearance, background: background)
                    let glyph = measured.luminance
                    let bar = measured.backgroundLuminance
                    if darkBar {
                        XCTAssertGreaterThan(
                            glyph, bar,
                            "\(state.rawValue) should draw lighter than a .darkAqua bar at L="
                            + "\(Colorimetry.f(luminance)); got glyph \(Colorimetry.f(glyph))"
                        )
                    } else {
                        XCTAssertLessThan(
                            glyph, bar,
                            "\(state.rawValue) should draw darker than an .aqua bar at L="
                            + "\(Colorimetry.f(luminance)); got glyph \(Colorimetry.f(glyph))"
                        )
                    }
                }
            }
        }
    }

    // §9.1 used to claim `sleep` is the least assertive of the seven, and #90
    // took that claim away rather than rehoming it. It was a conjunction, and
    // colour carried three of its four clauses: `sleep` was the only tint that
    // was achromatic AND below full label strength, and it was the lowest
    // contrast of the set on a light bar. The system now draws all seven in
    // one ink, so none of those can be true of `sleep` in particular.
    //
    // Nor does the drawing rescue it. Measured through one opaque tint,
    // `moon.zzz` paints 11.07% of the glyph box against `busy` at 9.27%,
    // `celebrate` at 9.72% and `heart` at 10.15% — `sleep` is mid-pack, not
    // the lightest. Asserting otherwise would be asserting something false.
    //
    // What is left is real but small, and it is all this pins: `sleep` is
    // motionless, and it carries no colour of its own — its ink is the same
    // ink every other state gets, which is what stops a future change from
    // quietly re-dimming it the way #89 and #91 had to undo. SPEC §9.1 records
    // the loss rather than pretending the guarantee survived.
    //
    // Only the ink's *colour* is compared, never `resolvedInk`'s alpha. That
    // alpha says how completely the stroke covers its best-covered pixel,
    // which is a property of the symbol's artwork and the rasterizer, not of
    // the colour: locally every glyph reached the same 0.549, while the CI
    // runner's SF Symbols set produced 0.471 to 0.549 across the seven and
    // failed an equality that had nothing to do with what it claimed to test.
    func testSleepCarriesNoColourOfItsOwnAndDoesNotMove() {
        let sleep = IconStyle.style(for: .sleep, animationsEnabled: true)
        XCTAssertEqual(sleep.animation, .none, "sleep must not animate")

        for (appearance, _) in Self.bands {
            let quiet = resolvedInk(.sleep, appearance: appearance)
            for state in BuddyState.allCases where state != .sleep {
                let other = resolvedInk(state, appearance: appearance)
                XCTAssertEqual(
                    Colorimetry.distance(quiet.rgb, other.rgb), 0, accuracy: 0.01,
                    "sleep's ink on \(appearance.rawValue) differs from \(state.rawValue)'s. "
                    + "sleep is dimmed by symbol and stillness now, not by colour (§9.1, #90)."
                )
            }
        }
    }

    // A legible tint is worthless if the glyph is a hairline. Ink coverage is
    // the alpha-weighted fraction of the button the symbol actually paints;
    // unlike mean contrast it is scale-invariant (measured identical to within
    // 3% at 1x, 2x and 4x). Thinnest in the set is `circle.dotted` at 0.032.
    func testEveryStateDrawsEnoughInkToBeVisible() {
        for state in BuddyState.allCases {
            for (appearance, background) in Self.menuBars {
                let coverage = render(state, appearance: appearance, background: background).inkCoverage
                XCTAssertGreaterThan(
                    coverage, 0.015,
                    "\(state.rawValue) on \(appearance.rawValue) paints only "
                    + "\(Colorimetry.f(coverage * 100))% of the button"
                )
            }
        }
    }

    // MARK: - The template reaches the pixels

    // The direct guard on `isTemplate` (#34), which #90 made load-bearing
    // twice: a non-template image ignores the view's colour entirely, so it
    // ignores the system's choice too and draws SF Symbols' own rendering.
    //
    // Forcing a tint is the only way to detect that from pixels, so this test
    // sets one deliberately — it is the one place in the suite that does, and
    // it proves the channel the system colours the glyph through is open. Two
    // different forced tints produce byte-identical pixels when the bug is
    // present: separation is exactly 0.000 at every raster scale, against
    // 0.149 or better when it is not.
    func testSwappingTheTintChangesTheRenderedPixels() {
        let background = Self.menuBars[0].1
        for state in BuddyState.allCases {
            let blue = render(state, appearance: .darkAqua, background: background,
                              overrideTint: .systemBlue)
            let green = render(state, appearance: .darkAqua, background: background,
                               overrideTint: .systemGreen)
            let apart = Colorimetry.distance(blue.rgb, green.rgb)
            XCTAssertGreaterThan(
                apart, 0.05,
                "\(state.rawValue): contentTintColor is not reaching the pixels — blue and green "
                + "renders are only \(Colorimetry.f(apart)) apart. Is the image still isTemplate = true?"
            )
        }
    }

    // MARK: - #37: one configuration, even weight, distinct silhouettes

    // Every name in the §9.1 table must exist in the macOS 15 SF Symbols set.
    // `NSImage(systemSymbolName:)` returns nil for an unknown name and
    // StatusIconImageView then assigns nil to `image`, so a typo ships as a
    // blank menu bar with no error anywhere. The macOS 15 floor is verified
    // against CoreGlyphs' own `name_availability.plist` (see SPEC §9.1); this
    // test is the runtime half — it catches a name that does not resolve on
    // whatever SDK is building.
    func testEverySymbolInTheTableResolvesToAnImage() {
        for state in BuddyState.allCases {
            let name = IconStyle.style(for: state, animationsEnabled: false).symbol
            XCTAssertNotNil(
                NSImage(systemSymbolName: name, accessibilityDescription: nil),
                "\(state.rawValue): \"\(name)\" does not resolve — the menu bar would render nothing"
            )
        }
    }

    // #37's first complaint: the seven symbols were built with no
    // SymbolConfiguration at all, so each rendered at its own natural metrics
    // (widths 15/16/17pt, heights 14/15/17pt). They now share one point size.
    //
    // This asserts the property that is actually achievable, which is NOT
    // "image.size is equal across states": SF Symbols have different aspect
    // ratios, and the only way to force one size is to draw each glyph into a
    // fixed canvas — which replaces NSSymbolImageRep with NSCustomImageRep and
    // takes every §9.1 animation with it (see the test below). What a shared
    // pointSize does guarantee is one type size for the whole set, and that
    // every glyph fits inside StatusItemIcon.glyphBox so `.scaleNone` never
    // clips one. The status item itself no longer changes width regardless:
    // StatusItemIcon.length is fixed.
    func testEveryStateSharesOneSymbolConfigurationAndFitsTheGlyphBox() {
        var natural = 0
        for state in BuddyState.allCases {
            let name = IconStyle.style(for: state, animationsEnabled: false).symbol
            guard let raw = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
                XCTFail("\(state.rawValue): \(name) does not resolve"); continue
            }
            let button = makeButton(appearance: .darkAqua)
            StatusItemIcon.apply(state: state, animationsEnabled: false, to: button)
            guard let shipped = StatusItemIcon.imageView(in: button)?.image else {
                XCTFail("\(state.rawValue): no image"); continue
            }
            // Spelled out rather than chained: the optional-chained form blew
            // the type checker's expression budget on Swift 6.4 (CLAUDE.md,
            // "CI compiles with Swift 6.1.2").
            guard let configured = raw.withSymbolConfiguration(IconStyle.symbolConfiguration) else {
                XCTFail("\(state.rawValue): the shared configuration does not apply to \(name)"); continue
            }
            let expected: NSSize = configured.size
            XCTAssertEqual(shipped.size.width, expected.width, accuracy: 0.01,
                           "\(state.rawValue) is not built through IconStyle.symbolConfiguration")
            XCTAssertEqual(shipped.size.height, expected.height, accuracy: 0.01,
                           "\(state.rawValue) is not built through IconStyle.symbolConfiguration")
            XCTAssertLessThanOrEqual(
                shipped.size.width, StatusItemIcon.glyphBox.width,
                "\(state.rawValue) is \(Colorimetry.f(shipped.size.width))pt wide and would clip in the "
                + "\(Colorimetry.f(StatusItemIcon.glyphBox.width))pt glyph box (imageScaling is .scaleNone)")
            XCTAssertLessThanOrEqual(
                shipped.size.height, StatusItemIcon.glyphBox.height,
                "\(state.rawValue) is \(Colorimetry.f(shipped.size.height))pt tall and would clip in the "
                + "\(Colorimetry.f(StatusItemIcon.glyphBox.height))pt glyph box (imageScaling is .scaleNone)")
            if abs(shipped.size.height - raw.size.height) > 0.01 { natural += 1 }
        }
        XCTAssertGreaterThan(natural, 0,
                             "no state's metrics changed — is a SymbolConfiguration being applied at all?")
    }

    // The regression the previous test's comment describes, pinned directly.
    // `addSymbolEffect` animates the layers inside an NSSymbolImageRep. Draw a
    // configured symbol into a fixed-size NSImage to equalise `image.size` and
    // the result is an NSCustomImageRep with no symbol data, so every §9.1
    // effect silently becomes a no-op — #35 all over again, and invisible to
    // the motion tests above, which only assert what StatusItemIcon *recorded*.
    func testTheShippedImageIsStillASymbolImage() {
        for state in BuddyState.allCases {
            let button = makeButton(appearance: .darkAqua)
            StatusItemIcon.apply(state: state, animationsEnabled: true, to: button)
            let reps = StatusItemIcon.imageView(in: button)?.image?.representations ?? []
            let classes = reps.map { NSStringFromClass(type(of: $0)) }
            XCTAssertTrue(
                classes.contains("NSSymbolImageRep"),
                "\(state.rawValue) is backed by \(classes) rather than NSSymbolImageRep — SF Symbol "
                + "effects have no layers to animate. Do not wrap the symbol in a fixed-size canvas.")
        }
    }

    // #37's second complaint: optical weight swung 5.5x across the set —
    // `circle.dotted` (busy, the state shown most while work happens) at 3.18%
    // of the button against `heart.fill` at 18.63%, measured the same way. The
    // set did not read as one family.
    //
    // Measured through an opaque tint, so this is the glyph's own weight and
    // nothing else. The shipped tint's alpha is deliberately not in it:
    // `sleep` is the one translucent tint, and renders 6.63% on a dark bar and
    // 6.06% on a light one against the same moon's 11.07% opaque. That dimming
    // is a property of the colour, governed by the contrast floors above and by
    // testSleepStaysTheQuietestState — folding it in here would report a
    // deliberately quiet state as a badly drawn one. That the tinted glyph is
    // still thick enough to see is a separate assertion
    // (testEveryStateDrawsEnoughInkToBeVisible).
    //
    // §9.1 states a 2x band. Measured 7.85% (busy) to 13.86% (idle) = 1.77x.
    func testInkCoverageAcrossTheSetStaysInsideTheStatedBand() {
        var measured: [(BuddyState, Double)] = []
        for state in BuddyState.allCases {
            let opaque = render(state, appearance: .darkAqua, background: Self.menuBars[0].1,
                                overrideTint: .white)
            measured.append((state, opaque.inkCoverage))
        }
        let lo = measured.min { $0.1 < $1.1 }!, hi = measured.max { $0.1 < $1.1 }!
        let report = measured
            .map { "\($0.0.rawValue) \(Colorimetry.f($0.1 * 100))%" }
            .joined(separator: ", ")
        XCTAssertGreaterThan(lo.1, 0.05, "\(lo.0.rawValue) is the faintest at "
                             + "\(Colorimetry.f(lo.1 * 100))% — \(report)")
        XCTAssertLessThan(hi.1, 0.20, "\(hi.0.rawValue) is the heaviest at "
                          + "\(Colorimetry.f(hi.1 * 100))% — \(report)")
        XCTAssertLessThanOrEqual(hi.1 / lo.1, 2.0,
                                 "ink coverage spans \(Colorimetry.f(hi.1 / lo.1))x across the set "
                                 + "(\(hi.0.rawValue) vs \(lo.0.rawValue)); §9.1 states a 2x band — \(report)")
    }

    // #37's third complaint, and the one §9.6 makes expensive: two pairs of
    // states were near-indistinguishable, collapsing seven signals into about
    // four. `circle` (idle) and `circle.dotted` (busy) shared an outline and
    // differed only in stroke continuity; `exclamationmark.triangle`
    // (attention) and `exclamationmark.arrow.circlepath` (dizzy) were both an
    // orange exclamation mark with the same tint.
    //
    // Measured with colour removed, so this is a claim about shape alone:
    // 1 - soft IoU of the two glyphs' alpha masks at the real 22pt/2x size,
    // each energy-normalised (so a heavier glyph cannot score "different"
    // merely by painting more) and Gaussian-blurred to stand in for how little
    // detail survives at menu bar size. 0 is the same shape, 1 is no overlap.
    //
    // The old pairs measured 0.109 (idle/busy) and 0.736 (attention/dizzy);
    // the new ones 0.753 and 0.780, and the closest of all 21 pairs is 0.682.
    // The 0.45 floor leaves room for SF Symbols artwork differing between the
    // CI runner's symbol set and a newer local one.
    func testStatesSharingATintAreDistinguishableBySilhouetteAlone() {
        for (first, second) in [(BuddyState.idle, BuddyState.busy),
                                (BuddyState.attention, BuddyState.dizzy)] {
            let apart = Colorimetry.silhouetteDistance(alphaMask(first), alphaMask(second))
            XCTAssertGreaterThan(
                apart, 0.45,
                "\(first.rawValue) and \(second.rawValue) share a tint and their silhouettes are only "
                + "\(Colorimetry.f(apart)) apart at menu bar size — they will read as one state")
        }
    }

    // The weaker guarantee for the whole set: no two of the seven, whatever
    // their tints, collapse into the same shape.
    func testNoTwoStatesCollapseIntoTheSameSilhouette() {
        let all = BuddyState.allCases
        var masks: [BuddyState: [Double]] = [:]
        for state in all { masks[state] = alphaMask(state) }
        for (index, first) in all.enumerated() {
            for second in all[(index + 1)...] {
                let apart = Colorimetry.silhouetteDistance(masks[first]!, masks[second]!)
                XCTAssertGreaterThan(
                    apart, 0.40,
                    "\(first.rawValue) and \(second.rawValue) are only \(Colorimetry.f(apart)) apart "
                    + "in silhouette at menu bar size")
            }
        }
    }

    // MARK: - Accessibility and tooltip

    func testEveryStateCarriesItsAccessibilityDescriptionAndTooltip() {
        for state in BuddyState.allCases {
            let button = makeButton(appearance: .darkAqua)
            StatusItemIcon.apply(state: state, animationsEnabled: false, to: button)
            XCTAssertEqual(button.accessibilityLabel(), state.rawValue)
            XCTAssertEqual(StatusItemIcon.imageView(in: button)?.image?.accessibilityDescription, state.rawValue)
            XCTAssertEqual(button.toolTip, "ContextBuddy: \(state.rawValue)")
        }
    }

    // MARK: - §9.2 motion

    // A one-shot plays on the transition into its state, once, and each of the
    // three one-shot states plays its own §9.1 effect. None of them is held.
    func testOneShotEffectsPlayOncePerTransitionIntoTheState() {
        let button = makeButton(appearance: .darkAqua)
        let expected: [(BuddyState, IconStyle.Animation)] = [
            (.attention, .scalePulseOnce), (.celebrate, .bounceOnce), (.heart, .pulseOnce)
        ]
        StatusItemIcon.apply(state: .idle, animationsEnabled: true, to: button)
        for (index, entry) in expected.enumerated() {
            let (state, animation) = entry
            StatusItemIcon.apply(state: state, animationsEnabled: true, to: button)
            let recorded = motion(of: button)
            XCTAssertEqual(recorded.oneShotsStarted, index + 1, state.rawValue)
            XCTAssertEqual(recorded.lastOneShot, animation, state.rawValue)
            XCTAssertNil(recorded.held, "\(state.rawValue) is a one-shot, not a held effect")
        }
    }

    // The rule from #35: MenubarController.renderIcon() runs on every published
    // snapshot, and a snapshot that repeats the state must not replay the
    // one-shot. Leaving and re-entering the state is a transition again.
    func testARepeatedSnapshotDoesNotReplayTheOneShot() {
        let button = makeButton(appearance: .darkAqua)
        StatusItemIcon.apply(state: .idle, animationsEnabled: true, to: button)
        StatusItemIcon.apply(state: .attention, animationsEnabled: true, to: button)
        StatusItemIcon.apply(state: .attention, animationsEnabled: true, to: button)
        StatusItemIcon.apply(state: .attention, animationsEnabled: true, to: button)
        XCTAssertEqual(motion(of: button).oneShotsStarted, 1, "three attention snapshots, one pulse")

        StatusItemIcon.apply(state: .idle, animationsEnabled: true, to: button)
        StatusItemIcon.apply(state: .attention, animationsEnabled: true, to: button)
        XCTAssertEqual(motion(of: button).oneShotsStarted, 2, "re-entering attention is a transition")
    }

    // busy rotates and dizzy wiggles for as long as the state lasts: started on
    // entry, left running by a repeated snapshot, removed on exit. Neither
    // counts as a one-shot. `heldStarts` is the assertion that matters for the
    // repeated snapshot: `held` reads the same whether the effect was left
    // alone or removed and re-added, and only the count tells them apart.
    func testHeldEffectsRunWhileTheStateLastsAndStopWhenItEnds() {
        let held: [(BuddyState, IconStyle.Animation)] = [(.busy, .rotateRepeating), (.dizzy, .wiggleRepeating)]
        for entry in held {
            let (state, animation) = entry
            let button = makeButton(appearance: .darkAqua)
            StatusItemIcon.apply(state: .idle, animationsEnabled: true, to: button)
            StatusItemIcon.apply(state: state, animationsEnabled: true, to: button)
            XCTAssertEqual(motion(of: button).held, animation, state.rawValue)
            XCTAssertEqual(motion(of: button).heldStarts, 1, "\(state.rawValue): entering starts it once")
            StatusItemIcon.apply(state: state, animationsEnabled: true, to: button)
            XCTAssertEqual(motion(of: button).held, animation, "\(state.rawValue): a repeated snapshot keeps it running")
            XCTAssertEqual(motion(of: button).heldStarts, 1,
                           "\(state.rawValue): a repeated snapshot must not remove and re-add the effect")
            StatusItemIcon.apply(state: .idle, animationsEnabled: true, to: button)
            XCTAssertNil(motion(of: button).held, "\(state.rawValue) -> idle stops it")
            XCTAssertEqual(motion(of: button).oneShotsStarted, 0, "\(state.rawValue) is held, not one-shot")
        }
    }

    // §9.2: routine transitions are silent. sleep, idle and busy start no
    // one-shot in either direction; busy's rotation is held motion (above).
    func testRoutineTransitionsStartNoOneShot() {
        let button = makeButton(appearance: .darkAqua)
        for state in [BuddyState.sleep, .idle, .busy, .idle, .busy, .sleep] {
            StatusItemIcon.apply(state: state, animationsEnabled: true, to: button)
        }
        XCTAssertEqual(motion(of: button).oneShotsStarted, 0)
        XCTAssertNil(motion(of: button).lastOneShot)
    }

    // `animationsEnabled: false` keeps the glyph and tint and starts no effect,
    // held or one-shot, through every transition. That is the `apply` argument;
    // the config key and Reduce Motion reach it through
    // StatusItemIcon.animationsEnabled(ui:reduceMotion:), pinned below (#36).
    func testAnimationsDisabledStartsNoMotion() {
        let button = makeButton(appearance: .darkAqua)
        for state in BuddyState.allCases {
            StatusItemIcon.apply(state: state, animationsEnabled: false, to: button)
            XCTAssertEqual(motion(of: button), StatusItemIcon.Motion(), state.rawValue)
        }
    }

    // MARK: - #36: `[ui].animations_enabled` and Reduce Motion

    // The two switches compose as AND: motion plays only when the config
    // allows it and the system is not reducing motion. Neither overrides the
    // other, so `animations_enabled = true` cannot re-enable motion the user
    // turned off system-wide, and Reduce Motion off cannot re-enable motion
    // the config turned off.
    func testMotionPlaysOnlyWhenConfigAllowsAndTheSystemIsNotReducingIt() {
        let table: [(config: Bool, reduceMotion: Bool, expected: Bool)] = [
            (true, false, true),
            (true, true, false),
            (false, false, false),
            (false, true, false),
        ]
        for row in table {
            let ui = Config.UI(animationsEnabled: row.config, tokenRowPct: 70)
            XCTAssertEqual(
                StatusItemIcon.animationsEnabled(ui: ui, reduceMotion: row.reduceMotion),
                row.expected,
                "animations_enabled=\(row.config), reduceMotion=\(row.reduceMotion)"
            )
        }
    }

    // #36's acceptance: `animations_enabled = true` plus Reduce Motion on is
    // `.none` for every state, and through `apply` that means no effect is
    // started, held or one-shot, across every transition.
    func testReduceMotionSuppressesEveryStateEvenWhenConfigAllowsMotion() {
        let ui = Config.UI(animationsEnabled: true, tokenRowPct: 70)
        let enabled = StatusItemIcon.animationsEnabled(ui: ui, reduceMotion: true)
        let button = makeButton(appearance: .darkAqua)
        for state in BuddyState.allCases {
            XCTAssertEqual(
                IconStyle.style(for: state, animationsEnabled: enabled).animation, .none,
                "\(state.rawValue) must not animate under Reduce Motion"
            )
            StatusItemIcon.apply(state: state, animationsEnabled: enabled, to: button)
            XCTAssertEqual(motion(of: button), StatusItemIcon.Motion(), state.rawValue)
        }
    }

    // The once-per-transition rule depends on one image view remembering the
    // previous state across calls. A second `apply` must reuse the view it
    // installed, not stack another one on the button.
    func testApplyInstallsOneImageViewAndReusesIt() {
        let button = makeButton(appearance: .darkAqua)
        StatusItemIcon.apply(state: .idle, animationsEnabled: true, to: button)
        let first = StatusItemIcon.imageView(in: button)
        StatusItemIcon.apply(state: .busy, animationsEnabled: true, to: button)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === StatusItemIcon.imageView(in: button))
        XCTAssertEqual(button.subviews.count, 1)
        XCTAssertEqual(first?.state, .busy)
    }

    // Clicks must reach the status item's button: the popover and the menu are
    // its target/action (MenubarController.handleClick), and a subview that
    // took hit-testing would swallow them.
    func testTheImageViewStaysOutOfHitTesting() {
        let button = makeButton(appearance: .darkAqua)
        StatusItemIcon.apply(state: .idle, animationsEnabled: true, to: button)
        let container = NSView(frame: button.frame)
        container.addSubview(button)
        let centre = NSPoint(x: button.frame.midX, y: button.frame.midY)
        XCTAssertTrue(container.hitTest(centre) === button)
    }
}

// MARK: - Measurement

extension StatusItemIconTests {

    // The status item is 22pt square, rendered at 2x on every Mac that ships a
    // Retina display. Pinning the backing store rather than taking whatever
    // `bitmapImageRepForCachingDisplay` picks keeps the numbers in the comments
    // above reproducible between a developer machine and a headless runner.
    private static let buttonPoints = 22
    private static let renderScale = 2

    // `swift test` runs under `xctest`, which has no NSApplication of its own.
    // Touching `NSApplication.shared` creates one; `.prohibited` keeps the
    // process out of the Dock and off the activation path. A static `let` runs
    // once.
    //
    // Deliberately not an `override func setUp()`: that override inherits
    // XCTestCase's nonisolated context rather than this class's @MainActor
    // annotation on Swift 6.1, so touching NSApplication from it fails to
    // compile there while building fine on newer toolchains.
    @MainActor
    static let bootstrapAppKit: Void = {
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
    }()

    func makeButton(appearance: NSAppearance.Name) -> NSButton {
        _ = Self.bootstrapAppKit
        let side = CGFloat(Self.buttonPoints)
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: side, height: side))
        button.appearance = NSAppearance(named: appearance)
        button.isBordered = false
        button.title = ""
        button.imagePosition = .imageOnly
        return button
    }

    // The colour the system resolved for a state's glyph, read from a pixel
    // the stroke *fully* covers. Returns the best-covered pixel's colour and
    // its alpha, so a caller can assert the coverage was real before trusting
    // the colour — a partially covered pixel carries the background too, which
    // is the measurement error this file exists to avoid.
    //
    // Rendered with no tint override, so this is exactly what ships.
    func resolvedInk(
        _ state: BuddyState,
        appearance: NSAppearance.Name
    ) -> (rgb: (Double, Double, Double), alpha: Double) {
        let button = makeButton(appearance: appearance)
        StatusItemIcon.apply(state: state, animationsEnabled: false, to: button)
        let pixels = Self.buttonPoints * Self.renderScale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            XCTFail("could not allocate a bitmap for \(state.rawValue)")
            return ((0, 0, 0), 0)
        }
        rep.size = button.bounds.size
        button.cacheDisplay(in: button.bounds, to: rep)

        var best = ((0.0, 0.0, 0.0), 0.0)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let px = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let alpha = Double(px.alphaComponent)
                guard alpha > best.1 else { continue }
                let rgb = (Double(px.redComponent), Double(px.greenComponent), Double(px.blueComponent))
                best = (rgb, alpha)
            }
        }
        return (best.0, best.1)
    }

    // Renders one state offscreen. Returns the alpha-weighted mean of the glyph
    // composited over `background`, plus how much ink it painted.
    //
    // Compositing rather than sampling only opaque pixels matters: `sleep`'s
    // tint is semi-transparent throughout, so an "alpha > 0.9" filter finds no
    // pixels at all for it. Only use the mean for comparisons between two
    // renders — see the note at the top of the file.
    func render(
        _ state: BuddyState,
        appearance: NSAppearance.Name,
        background: Double,
        overrideTint: NSColor? = nil
    ) -> Colorimetry.Measurement {
        let button = makeButton(appearance: appearance)
        StatusItemIcon.apply(state: state, animationsEnabled: false, to: button)
        if let overrideTint { StatusItemIcon.imageView(in: button)?.contentTintColor = overrideTint }

        let pixels = Self.buttonPoints * Self.renderScale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            XCTFail("could not allocate a bitmap for \(state.rawValue)")
            return Colorimetry.Measurement(rgb: (background, background, background),
                                           background: background, inkCoverage: 0)
        }
        rep.size = button.bounds.size
        button.cacheDisplay(in: button.bounds, to: rep)

        var sum = (0.0, 0.0, 0.0)
        var weight = 0.0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                // usingColorSpace(.sRGB) before reading components: the rep's
                // own space is device-dependent.
                guard let px = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let a = Double(px.alphaComponent)
                guard a > 0.01 else { continue }
                sum.0 += (Double(px.redComponent) * a + background * (1 - a)) * a
                sum.1 += (Double(px.greenComponent) * a + background * (1 - a)) * a
                sum.2 += (Double(px.blueComponent) * a + background * (1 - a)) * a
                weight += a
            }
        }
        guard weight > 0 else {
            XCTFail("\(state.rawValue) rendered nothing on \(appearance.rawValue)")
            return Colorimetry.Measurement(rgb: (background, background, background),
                                           background: background, inkCoverage: 0)
        }
        return Colorimetry.Measurement(
            rgb: (sum.0 / weight, sum.1 / weight, sum.2 / weight),
            background: background,
            inkCoverage: weight / Double(rep.pixelsWide * rep.pixelsHigh)
        )
    }

    // The glyph's alpha channel alone, with colour entirely out of the picture:
    // the shape #37 asks about, at the size it is actually read. Rendered over
    // a transparent backing rather than a menu bar grey, so a light-bar and a
    // dark-bar render of the same symbol produce the same mask.
    func alphaMask(_ state: BuddyState) -> [Double] {
        let side = Self.buttonPoints * Self.renderScale
        let button = makeButton(appearance: .darkAqua)
        StatusItemIcon.apply(state: state, animationsEnabled: false, to: button)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            XCTFail("could not allocate a mask bitmap for \(state.rawValue)")
            return [Double](repeating: 0, count: side * side)
        }
        rep.size = button.bounds.size
        button.cacheDisplay(in: button.bounds, to: rep)
        var mask = [Double](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                mask[y * side + x] = Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
        }
        return mask
    }

    // The motion record of the image view `apply` installed in `button`.
    func motion(of button: NSButton, file: StaticString = #filePath, line: UInt = #line) -> StatusItemIcon.Motion {
        guard let view = StatusItemIcon.imageView(in: button) else {
            XCTFail("apply installed no StatusIconImageView", file: file, line: line)
            return StatusItemIcon.Motion(held: nil, oneShotsStarted: -1, lastOneShot: nil)
        }
        return view.motion
    }

}

// MARK: - Colorimetry
//
// Pure arithmetic, deliberately outside the @MainActor test class so the
// measurement math stays callable from anywhere.

enum Colorimetry {

    struct Measurement {
        let rgb: (Double, Double, Double)
        let background: Double
        // Alpha-weighted fraction of the button the glyph paints.
        let inkCoverage: Double

        var luminance: Double { Colorimetry.luminance(rgb) }
        var hue: Double { Colorimetry.hue(rgb) }
        var backgroundLuminance: Double { Colorimetry.luminance((background, background, background)) }
    }

    // WCAG 2.x relative luminance.
    static func luminance(_ rgb: (Double, Double, Double)) -> Double {
        func channel(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.0) + 0.7152 * channel(rgb.1) + 0.0722 * channel(rgb.2)
    }

    static func contrastRatio(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    // The sRGB channel value of the grey whose relative luminance is `L` — the
    // inverse of `luminance` for an achromatic colour. §9.1's bands are stated
    // as luminances because that is what a menu bar capture is measured in,
    // and `render` takes a channel.
    static func grey(forLuminance luminance: Double) -> Double {
        if luminance <= 0.0031308 { return luminance * 12.92 }
        let encoded: Double = pow(luminance, 1 / 2.4)
        return 1.055 * encoded - 0.055
    }

    // HSV hue in degrees; NaN for achromatic input.
    static func hue(_ rgb: (Double, Double, Double)) -> Double {
        let (r, g, b) = rgb
        let mx = max(r, g, b), mn = min(r, g, b), delta = mx - mn
        guard delta > 1e-9 else { return .nan }
        var h: Double
        if mx == r {
            h = (g - b) / delta
        } else if mx == g {
            h = 2 + (b - r) / delta
        } else {
            h = 4 + (r - g) / delta
        }
        h *= 60
        return h < 0 ? h + 360 : h
    }

    // Shortest angular distance in degrees. NaN on either side means the
    // comparison is meaningless, so return the maximum rather than passing.
    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        guard a.isFinite, b.isFinite else { return 180 }
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    // How different two glyphs are in shape alone, at menu bar size.
    //
    // 1 - soft IoU of two square alpha masks. Each mask is first blurred, to
    // stand in for the detail that does not survive at 15pt in peripheral
    // vision (`circle` and `circle.dotted` are 22 disconnected dots apart at
    // full resolution and the same ring once blurred, which is exactly the
    // complaint), then energy-normalised, so a heavier glyph cannot score
    // "different" merely by painting more ink than its partner.
    //
    // 0 is the same shape, 1 is no overlap at all.
    static func silhouetteDistance(_ a: [Double], _ b: [Double], sigma: Double = 1.2) -> Double {
        let side = Int(Double(a.count).squareRoot().rounded())
        guard side * side == a.count, a.count == b.count else { return 0 }
        let ba = blur(a, side: side, sigma: sigma), bb = blur(b, side: side, sigma: sigma)
        let sa = ba.reduce(0, +), sb = bb.reduce(0, +)
        guard sa > 0, sb > 0 else { return 0 }
        var intersection = 0.0, union = 0.0
        for i in 0..<ba.count {
            let x = ba[i] / sa, y = bb[i] / sb
            intersection += min(x, y)
            union += max(x, y)
        }
        guard union > 0 else { return 0 }
        return 1 - intersection / union
    }

    // Separable Gaussian blur over a square single-channel image, clamped at
    // the edges.
    static func blur(_ source: [Double], side: Int, sigma: Double) -> [Double] {
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var horizontal = [Double](repeating: 0, count: source.count)
        var out = [Double](repeating: 0, count: source.count)
        for y in 0..<side {
            for x in 0..<side {
                var acc = 0.0
                for (k, weight) in kernel.enumerated() {
                    acc += source[y * side + min(side - 1, max(0, x + k - radius))] * weight
                }
                horizontal[y * side + x] = acc
            }
        }
        for y in 0..<side {
            for x in 0..<side {
                var acc = 0.0
                for (k, weight) in kernel.enumerated() {
                    acc += horizontal[min(side - 1, max(0, y + k - radius)) * side + x] * weight
                }
                out[y * side + x] = acc
            }
        }
        return out
    }

    static func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)).squareRoot()
    }

    static func f(_ v: Double) -> String { String(format: "%.2f", v) }
}

