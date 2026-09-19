import AppKit
import XCTest
import ContextBuddyCore
@testable import ContextBuddyApp

// Coverage for the §9.1 icon contract (SPEC.md §9.1).
//
// The regression this guards (#34): NSImageView (like the NSButton that drew
// the icon before #35) only recolors a *template* image with
// `contentTintColor`. When the status item's image was marked
// `isTemplate = false`, every per-state tint in IconStyle was discarded — four
// of the seven states drew pure black, invisible on a dark menu bar, and the
// rest drew SF Symbols' multicolor variants instead of §9.1's colors.
//
// The §9.2 motion section asserts on StatusItemIcon.Motion, the record the
// hosted image view keeps of the effects it started: NSImageView exposes no
// list of running symbol effects, and what plays on screen is a human check.
//
// Two kinds of assertion here, deliberately kept apart:
//
//   * Contrast floors are computed from the *resolved tint color*, composited
//     over the menu bar at its own alpha. This is what "is this tint legible
//     against the menu bar" means, and it does not depend on how finely the
//     glyph happens to be rasterized.
//
//   * Everything measured from rendered pixels compares two renders taken
//     under identical conditions (hue against the declared tint, one tint
//     against another), so raster density cancels out.
//
// Absolute contrast must NOT be asserted on rendered pixels. An alpha-weighted
// mean over a thin stroke is dominated by partially covered edge pixels, so the
// same glyph measures 1.73:1 at 1x and 6.76:1 at 2x — that number describes the
// rasterizer, not the color. An earlier revision of this file did exactly that
// and passed locally while failing on CI.
//
// Needs an NSApplication: `bitmapImageRepForCachingDisplay` and `cacheDisplay`
// draw through AppKit, so `makeButton` bootstraps one.
@MainActor
final class StatusItemIconTests: XCTestCase {

    // The menu bar is translucent over the wallpaper, so there is no single
    // true value. These are the representative greys #34's measurements used.
    private static let darkMenuBar = 0.11
    private static let lightMenuBar = 0.96

    private static let menuBars: [(NSAppearance.Name, Double)] = [
        (.darkAqua, darkMenuBar), (.aqua, lightMenuBar)
    ]

    // MARK: - Contrast floors, from the resolved tint

    // Every §9.1 tint against the dark menu bar. This is where #34 lived: four
    // states drew black there. Measured 4.84:1 (heart) to 12.46:1 (idle/busy).
    func testEveryTintClearsAAContrastOnTheDarkMenuBar() {
        for state in BuddyState.allCases {
            let ratio = tintContrast(state, appearance: .darkAqua, background: Self.darkMenuBar)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "\(state.rawValue) on the dark menu bar: \(Colorimetry.f(ratio)):1"
            )
        }
    }

    // idle and busy are what the user sees ~99% of the time, so both must clear
    // AA on either bar. sleep is `.secondary` by contract — deliberately dimmed
    // — and is held to the 3:1 large-text/UI-component floor instead.
    //
    // The chromatic states are absent on purpose: §9.1's orange, yellow and
    // pink cannot clear 4.5:1 against a near-white bar (1.38:1 to 3.34:1) and
    // only different tints would fix that, which §9.1 forbids. See #44.
    func testAdaptiveTintsClearTheirFloorsOnBothMenuBars() {
        for (state, floor) in [(BuddyState.idle, 4.5), (.busy, 4.5), (.sleep, 3.0)] {
            for (appearance, background) in Self.menuBars {
                let ratio = tintContrast(state, appearance: appearance, background: background)
                XCTAssertGreaterThanOrEqual(
                    ratio, floor,
                    "\(state.rawValue) on the \(appearance.rawValue) menu bar: "
                    + "\(Colorimetry.f(ratio)):1, floor \(Colorimetry.f(floor)):1"
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
            let coverage = render(state, appearance: .darkAqua, background: Self.darkMenuBar).inkCoverage
            XCTAssertGreaterThan(
                coverage, 0.015,
                "\(state.rawValue) paints only \(Colorimetry.f(coverage * 100))% of the button"
            )
        }
    }

    // MARK: - Appearance adaptivity

    // sleep/idle/busy take `.labelColor` / `.secondaryLabelColor`, which must
    // resolve per appearance rather than being pinned to one variant. The
    // invariant is the *direction*: the glyph lands on the opposite side of its
    // own background in each appearance. Direction is stable across raster
    // scales even though the magnitude is not, and a hardcoded white inverts
    // the light half.
    func testAdaptiveStatesResolveAgainstTheButtonAppearance() {
        for state in [BuddyState.sleep, .idle, .busy] {
            let onDark = render(state, appearance: .darkAqua, background: Self.darkMenuBar)
            XCTAssertGreaterThan(
                onDark.luminance, onDark.backgroundLuminance,
                "\(state.rawValue) should draw lighter than the dark menu bar; got glyph "
                + "\(Colorimetry.f(onDark.luminance)) vs bar \(Colorimetry.f(onDark.backgroundLuminance))"
            )

            let onLight = render(state, appearance: .aqua, background: Self.lightMenuBar)
            XCTAssertLessThan(
                onLight.luminance, onLight.backgroundLuminance,
                "\(state.rawValue) should draw darker than the light menu bar; got glyph "
                + "\(Colorimetry.f(onLight.luminance)) vs bar \(Colorimetry.f(onLight.backgroundLuminance))"
            )
        }
    }

    // MARK: - The tint reaches the pixels

    // The chromatic states must render at the IconStyle tint's own hue, not at
    // SF Symbols' multicolor variant. With #34 present, `attention` drew
    // multicolor yellow (~22 degrees off systemOrange) and `heart` multicolor
    // red (~11 degrees off systemPink). Hue drifts by at most 0.3 degrees
    // across raster scales, so the 5 degree tolerance is about the color, not
    // the rasterizer.
    func testChromaticStatesRenderAtTheDeclaredTintHue() {
        for state in [BuddyState.attention, .celebrate, .dizzy, .heart] {
            for (appearance, background) in Self.menuBars {
                let measured = render(state, appearance: appearance, background: background)
                let declared = hue(of: IconStyle.style(for: state, animationsEnabled: false).tint,
                                   in: appearance)
                XCTAssertEqual(
                    Colorimetry.hueDistance(measured.hue, declared), 0, accuracy: 5,
                    "\(state.rawValue) on \(appearance.rawValue): rendered hue "
                    + "\(Colorimetry.f(measured.hue)) vs declared tint hue \(Colorimetry.f(declared))"
                )
            }
        }
    }

    // The direct guard on `isTemplate`, and the one that also covers
    // `celebrate`, whose multicolor variant happens to match systemYellow and
    // so slips past the hue test. A non-template image ignores
    // `contentTintColor` entirely, so two different tints produce
    // byte-identical pixels: separation is exactly 0.000 at every raster scale
    // when the bug is present, against 0.149 or better when it is not.
    func testSwappingTheTintChangesTheRenderedPixels() {
        for state in BuddyState.allCases {
            let blue = render(state, appearance: .darkAqua, background: Self.darkMenuBar,
                              overrideTint: .systemBlue)
            let green = render(state, appearance: .darkAqua, background: Self.darkMenuBar,
                               overrideTint: .systemGreen)
            let apart = Colorimetry.distance(blue.rgb, green.rgb)
            XCTAssertGreaterThan(
                apart, 0.05,
                "\(state.rawValue): contentTintColor is not reaching the pixels — blue and green "
                + "renders are only \(Colorimetry.f(apart)) apart. Is the image still isTemplate = true?"
            )
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
    // counts as a one-shot.
    func testHeldEffectsRunWhileTheStateLastsAndStopWhenItEnds() {
        let held: [(BuddyState, IconStyle.Animation)] = [(.busy, .rotateRepeating), (.dizzy, .wiggleRepeating)]
        for entry in held {
            let (state, animation) = entry
            let button = makeButton(appearance: .darkAqua)
            StatusItemIcon.apply(state: .idle, animationsEnabled: true, to: button)
            StatusItemIcon.apply(state: state, animationsEnabled: true, to: button)
            XCTAssertEqual(motion(of: button).held, animation, state.rawValue)
            StatusItemIcon.apply(state: state, animationsEnabled: true, to: button)
            XCTAssertEqual(motion(of: button).held, animation, "\(state.rawValue): a repeated snapshot keeps it running")
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

    // `[ui].animations_enabled = false` keeps the glyph and tint and starts no
    // effect, held or one-shot, through every transition.
    func testAnimationsDisabledStartsNoMotion() {
        let button = makeButton(appearance: .darkAqua)
        for state in BuddyState.allCases {
            StatusItemIcon.apply(state: state, animationsEnabled: false, to: button)
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

    // WCAG contrast of a state's declared tint against a menu bar background,
    // resolved under `appearance` and composited at the tint's own alpha.
    // `.secondaryLabelColor` is semi-transparent, so the alpha matters.
    func tintContrast(_ state: BuddyState, appearance: NSAppearance.Name, background: Double) -> Double {
        let tint = IconStyle.style(for: state, animationsEnabled: false).tint
        var rgba = (0.0, 0.0, 0.0, 1.0)
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            guard let c = tint.usingColorSpace(.sRGB) else { return }
            rgba = (Double(c.redComponent), Double(c.greenComponent),
                    Double(c.blueComponent), Double(c.alphaComponent))
        }
        let a = rgba.3
        let composited = (rgba.0 * a + background * (1 - a),
                          rgba.1 * a + background * (1 - a),
                          rgba.2 * a + background * (1 - a))
        return Colorimetry.contrastRatio(Colorimetry.luminance(composited),
                                         Colorimetry.luminance((background, background, background)))
    }

    // Renders one state offscreen. Returns the alpha-weighted mean of the glyph
    // composited over `background`, plus how much ink it painted.
    //
    // Compositing rather than sampling only opaque pixels matters:
    // `.secondaryLabelColor` is semi-transparent throughout, so an "alpha > 0.9"
    // filter finds no pixels at all for `sleep`. Only use the mean for
    // comparisons between two renders — see the note at the top of the file.
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

    // The motion record of the image view `apply` installed in `button`.
    func motion(of button: NSButton, file: StaticString = #filePath, line: UInt = #line) -> StatusItemIcon.Motion {
        guard let view = StatusItemIcon.imageView(in: button) else {
            XCTFail("apply installed no StatusIconImageView", file: file, line: line)
            return StatusItemIcon.Motion(held: nil, oneShotsStarted: -1, lastOneShot: nil)
        }
        return view.motion
    }

    // Resolves a dynamic NSColor under `appearance` and returns its hue.
    func hue(of color: NSColor, in appearance: NSAppearance.Name) -> Double {
        var rgb = (0.0, 0.0, 0.0)
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            guard let c = color.usingColorSpace(.sRGB) else { return }
            rgb = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        return Colorimetry.hue(rgb)
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

    static func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)).squareRoot()
    }

    static func f(_ v: Double) -> String { String(format: "%.2f", v) }
}
