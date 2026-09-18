import AppKit
import XCTest
import ContextBuddyCore
@testable import ContextBuddyApp

// Pixel-level coverage for the §9.1 icon contract (SPEC.md §9.1).
//
// The regression this guards (#34): NSButton only recolors a *template* image
// with `contentTintColor`. When the status item's image was marked
// `isTemplate = false`, every per-state tint in IconStyle was discarded and
// four of the seven states drew as pure black — ~1.2:1 against a dark menu
// bar, i.e. invisible.
//
// Each test renders the real shipping code path (`StatusItemIcon.apply`) into
// an offscreen NSButton under an explicit appearance, composites the result
// over a menu bar background, and measures it.
//
// Needs an NSApplication: `bitmapImageRepForCachingDisplay` draws through
// AppKit, so `makeButton` bootstraps one.
@MainActor
final class StatusItemIconTests: XCTestCase {

    // The menu bar is translucent over the wallpaper, so there is no single
    // true value. These are the representative greys the #34 measurements used.
    // They sit at the favorable end for the dark bar — a darker bar only raises
    // contrast for a light glyph — so a floor met here is met in practice.
    private static let darkMenuBar = 0.11
    private static let lightMenuBar = 0.96

    private static let menuBars: [(NSAppearance.Name, Double)] = [
        (.darkAqua, darkMenuBar), (.aqua, lightMenuBar)
    ]

    // MARK: - Contrast floors

    // idle and busy are what the user sees ~99% of the time. Both must clear
    // the WCAG AA non-text floor on either menu bar.
    func testIdleAndBusyClearAAContrastOnBothMenuBars() {
        for state in [BuddyState.idle, .busy] {
            for (appearance, background) in Self.menuBars {
                let ratio = render(state, appearance: appearance, background: background).contrastRatio
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5,
                    "\(state.rawValue) on the \(appearance.rawValue) menu bar: \(Colorimetry.f(ratio)):1"
                )
            }
        }
    }

    // All seven states on the dark menu bar. `sleep` is `.secondary` by
    // contract — deliberately dimmed — so every state is held to the WCAG AA
    // large-text/UI-component floor of 3:1 rather than 4.5:1. With the #34 bug
    // present, sleep/idle/busy/dizzy all land at ~1.2:1 here.
    func testEveryStateIsLegibleOnTheDarkMenuBar() {
        for state in BuddyState.allCases {
            let ratio = render(state, appearance: .darkAqua, background: Self.darkMenuBar).contrastRatio
            XCTAssertGreaterThanOrEqual(
                ratio, 3.0,
                "\(state.rawValue) on the dark menu bar: \(Colorimetry.f(ratio)):1"
            )
        }
    }

    // sleep/idle/busy take `.labelColor` / `.secondaryLabelColor`, which must
    // resolve per appearance rather than being pinned to one variant. The
    // invariant is that the glyph lands on the opposite side of its own
    // background in each appearance: light-on-dark, then dark-on-light. A
    // hardcoded white would fail the light half.
    //
    // Comparing the two appearances' absolute luminances would not work —
    // `.secondaryLabelColor` is semi-transparent in both, so a dimmed glyph
    // composited over a light bar lands near the same value as a bright one
    // composited over a dark bar.
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
            XCTAssertGreaterThanOrEqual(
                onLight.contrastRatio, 2.5,
                "\(state.rawValue) on the light menu bar: \(Colorimetry.f(onLight.contrastRatio)):1"
            )
        }
    }

    // MARK: - The tint reaches the pixels

    // The chromatic states must render at the IconStyle tint's own hue, not at
    // SF Symbols' multicolor variant. With #34 present, `attention` drew
    // multicolor yellow (~22 degrees off systemOrange) and `heart` multicolor
    // red (~11 degrees off systemPink).
    func testChromaticStatesRenderAtTheDeclaredTintHue() {
        for state in [BuddyState.attention, .celebrate, .dizzy, .heart] {
            for (appearance, background) in Self.menuBars {
                let measured = render(state, appearance: appearance, background: background)
                let tintHue = hue(of: IconStyle.style(for: state, animationsEnabled: false).tint,
                                  in: appearance)
                XCTAssertEqual(
                    Colorimetry.hueDistance(measured.hue, tintHue), 0, accuracy: 5,
                    "\(state.rawValue) on \(appearance.rawValue): rendered hue "
                    + "\(Colorimetry.f(measured.hue)) vs declared tint hue \(Colorimetry.f(tintHue))"
                )
            }
        }
    }

    // The direct guard on `isTemplate`. A non-template image ignores
    // `contentTintColor` entirely, so swapping the tint leaves the pixels
    // byte-identical. Covers every state, including `celebrate`, whose
    // multicolor variant happens to match systemYellow and so slips past the
    // hue test above.
    func testSwappingTheTintChangesTheRenderedPixels() {
        for state in BuddyState.allCases {
            let blue = render(state, appearance: .darkAqua, background: Self.darkMenuBar,
                              overrideTint: .systemBlue)
            let green = render(state, appearance: .darkAqua, background: Self.darkMenuBar,
                               overrideTint: .systemGreen)
            let apart = Colorimetry.distance(blue.rgb, green.rgb)
            XCTAssertGreaterThan(
                apart, 0.1,
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
            XCTAssertEqual(button.image?.accessibilityDescription, state.rawValue)
            XCTAssertEqual(button.toolTip, "ContextBuddy: \(state.rawValue)")
        }
    }
}

// MARK: - Offscreen rendering

extension StatusItemIconTests {

    // `swift test` runs under `xctest`, which has no NSApplication of its own,
    // and `bitmapImageRepForCachingDisplay` draws through AppKit. Touching
    // `NSApplication.shared` creates one; `.prohibited` keeps the process out
    // of the Dock and off the activation path. A static `let` runs once.
    //
    // Deliberately not an `override func setUp()`: that override inherits
    // XCTestCase's nonisolated context rather than this class's @MainActor
    // annotation on Swift 6.0, so touching NSApplication from it fails to
    // compile there while building fine on newer toolchains.
    @MainActor
    static let bootstrapAppKit: Void = {
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
    }()

    func makeButton(appearance: NSAppearance.Name) -> NSButton {
        _ = Self.bootstrapAppKit
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        button.appearance = NSAppearance(named: appearance)
        button.isBordered = false
        button.title = ""
        button.imagePosition = .imageOnly
        return button
    }

    // Renders one state offscreen and returns the alpha-weighted mean of the
    // glyph composited over `background`.
    //
    // Compositing rather than sampling only opaque pixels matters:
    // `.secondaryLabelColor` is semi-transparent throughout, so an "alpha > 0.9"
    // filter finds no pixels at all for `sleep`.
    func render(
        _ state: BuddyState,
        appearance: NSAppearance.Name,
        background: Double,
        overrideTint: NSColor? = nil
    ) -> Colorimetry.Measurement {
        let button = makeButton(appearance: appearance)
        StatusItemIcon.apply(state: state, animationsEnabled: false, to: button)
        if let overrideTint { button.contentTintColor = overrideTint }

        guard let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else {
            XCTFail("no bitmap rep for \(state.rawValue)")
            return Colorimetry.Measurement(rgb: (background, background, background), background: background)
        }
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
            return Colorimetry.Measurement(rgb: (background, background, background), background: background)
        }
        return Colorimetry.Measurement(
            rgb: (sum.0 / weight, sum.1 / weight, sum.2 / weight), background: background
        )
    }

    // Resolves a dynamic NSColor under `appearance` and returns its hue.
    func hue(of color: NSColor, in appearance: NSAppearance.Name) -> Double {
        var rgb = (0.0, 0.0, 0.0)
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            guard let resolved = color.usingColorSpace(.sRGB) else { return }
            rgb = (Double(resolved.redComponent), Double(resolved.greenComponent), Double(resolved.blueComponent))
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

        var luminance: Double { Colorimetry.luminance(rgb) }
        var hue: Double { Colorimetry.hue(rgb) }
        var backgroundLuminance: Double { Colorimetry.luminance((background, background, background)) }

        // WCAG 2.x contrast ratio against the menu bar this was composited over.
        var contrastRatio: Double {
            let glyph = luminance, bar = backgroundLuminance
            return (max(glyph, bar) + 0.05) / (min(glyph, bar) + 0.05)
        }
    }

    // WCAG 2.x relative luminance.
    static func luminance(_ rgb: (Double, Double, Double)) -> Double {
        func channel(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.0) + 0.7152 * channel(rgb.1) + 0.0722 * channel(rgb.2)
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
