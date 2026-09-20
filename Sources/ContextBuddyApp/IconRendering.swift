import AppKit
import ContextBuddyCore

// Maps BuddyState to (SFSymbol name, tint, animation policy) per §9.1.
// The three chromatic tints are appearance-dependent — see `orange` below.
// Animation policy is owned here so StatusIconImageView can mirror it without
// re-deciding. `animationsEnabled` is `[ui].animations_enabled` ANDed with the
// system Reduce Motion switch — StatusItemIcon.animationsEnabled(ui:reduceMotion:)
// composes them and MenubarController.renderIcon() passes the result — and
// false suppresses all motion (still emits the symbol + tint). (#36)
enum IconStyle {
    static func style(for state: BuddyState, animationsEnabled: Bool) -> Style {
        switch state {
        case .sleep:
            return Style(symbol: "moon.zzz", tint: .secondaryLabelColor, animation: .none)
        case .idle:
            return Style(symbol: "circle", tint: .labelColor, animation: .none)
        case .busy:
            return Style(symbol: "circle.dotted", tint: .labelColor,
                         animation: animationsEnabled ? .rotateRepeating : .none)
        case .attention:
            return Style(symbol: "exclamationmark.triangle", tint: orange,
                         animation: animationsEnabled ? .scalePulseOnce : .none)
        case .celebrate:
            return Style(symbol: "sparkles", tint: yellow,
                         animation: animationsEnabled ? .bounceOnce : .none)
        case .dizzy:
            return Style(symbol: "exclamationmark.arrow.circlepath", tint: orange,
                         animation: animationsEnabled ? .wiggleRepeating : .none)
        case .heart:
            return Style(symbol: "heart.fill", tint: pink,
                         animation: animationsEnabled ? .pulseOnce : .none)
        }
    }

    // §9.1's three chromatic tints, each a dynamic color: the system color the
    // SPEC names on a dark menu bar, a darkened variant of the same hue family
    // on a light one.
    //
    // The plain `.system*` colors are only legible on a dark bar. Resolved and
    // composited over sRGB grey 0.96 they measure 2.11:1 (orange), 1.38:1
    // (yellow) and 3.34:1 (pink) — `celebrate` all but invisible — against the
    // 4.5:1 floor §9.1 now commits to (#44). The light values below measure
    // 4.79:1, 4.82:1 and 5.27:1 and stay at least 25.6 degrees apart in hue,
    // so darkening does not collapse the three states into one brown glyph;
    // StatusItemIconTests pins both properties.
    //
    // Each hex is sRGB and round-trips through the generic RGB space AppKit
    // rasterizes into unchanged. A more saturated pink (0xD80048) clipped
    // there and rendered 7 degrees off its declared hue, failing the
    // rendered-hue test. Re-check that round trip before raising saturation.
    static var orange: NSColor { Tints.shared.orange }
    static var yellow: NSColor { Tints.shared.yellow }
    static var pink: NSColor { Tints.shared.pink }

    // One instance, built once, so each accessor above hands back the *same*
    // NSColor every call. IconStyle.Style is Equatable and
    // StatusIconImageView.render compares the incoming style against the
    // current one to tell a state transition from a redundant snapshot (§9.2);
    // a fresh dynamic NSColor per call never compares equal, which would
    // remove and re-add the held effect on every snapshot and make dizzy's
    // wiggle visibly restart.
    //
    // A holder rather than three `nonisolated(unsafe) static let`s: NSColor is
    // Sendable on the macOS 26 SDK and not on the macos-15 CI runner's, so the
    // annotation warns on one and is required on the other (#43, #46). This
    // compiles clean on both. The stored properties are immutable and AppKit
    // resolves a dynamic color per drawing appearance on whatever thread
    // draws, which is what `@unchecked` is asserting.
    private final class Tints: @unchecked Sendable {
        static let shared = Tints()
        let orange = adaptive("contextbuddy.attention", light: 0xB1_50_00) { .systemOrange }
        let yellow = adaptive("contextbuddy.celebrate", light: 0x7B_6C_00) { .systemYellow }
        let pink = adaptive("contextbuddy.heart", light: 0xC4_20_48) { .systemPink }
    }

    // `bestMatch` rather than a raw name comparison so the high-contrast and
    // vibrant appearances resolve to the variant they are derived from instead
    // of silently falling through to the light branch.
    //
    // `dark` is a closure, not an NSColor: the provider may be `@Sendable` on
    // some SDKs, and a captured NSColor is not. Nothing non-Sendable crosses
    // into it.
    private static func adaptive(
        _ name: String,
        light: UInt32,
        dark: @escaping @Sendable () -> NSColor
    ) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark() : srgb(light)
        }
    }

    // 0xRRGGBB in sRGB. Pinned to sRGB, not the generic/calibrated space, so
    // the measured contrast ratios above are the ones that actually ship.
    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    struct Style: Equatable {
        let symbol: String
        let tint: NSColor
        let animation: Animation
    }

    // Literal mapping to §9.1. macOS 15+ minimum (Package.swift) means every
    // effect below is available without fallback per §15. The one-shot cases
    // play on the transition into the state and stop; the repeating cases run
    // for as long as the state is held (§9.2).
    enum Animation: Equatable {
        case none
        case scalePulseOnce       // 300ms scale pulse (attention)
        case bounceOnce           // .bounce ~2.5s (celebrate)
        case wiggleRepeating      // .wiggle indefinite (dizzy)
        case pulseOnce            // .pulse held ~3s (heart)
        case rotateRepeating      // subtle rotation indefinite (busy)
    }
}

// Applies the §9.1 style for a state to the menubar button: glyph, tint,
// motion, tooltip and accessibility label.
//
// Extracted from MenubarController.renderIcon() so ContextBuddyAppTests can
// render the same pixels into an offscreen NSButton — the controller's own
// button belongs to a live NSStatusItem, which a test process cannot create.
// MenubarController.renderIcon() must stay a thin caller of this, or the tests
// stop covering what ships.
//
// The glyph is drawn by a StatusIconImageView that `apply` installs in the
// button on its first call, not by the button's own `image`: SF Symbol effects
// are an NSImageView API (`addSymbolEffect`), and NSStatusItem.button is an
// NSButton. The SwiftUI view that first carried §9.1's `symbolEffect`s was
// never hosted anywhere, so the shipped icon never moved (#35).
enum StatusItemIcon {
    // Width of the status item, fixed when MenubarController creates it. The
    // button's own image is nil now, so `NSStatusItem.variableLength` would
    // size the item to nothing. A fixed width also keeps the neighbouring
    // items still when the glyph changes and leaves the bounce and wiggle room
    // to move without clipping: the 22pt glyph square plus 3pt each side.
    static let length: CGFloat = 28

    // What the image view last did about motion. StatusItemIconTests reads it:
    // NSImageView exposes no list of the symbol effects running on it, so this
    // record is the only way to assert §9.2's once-per-transition rule.
    struct Motion: Equatable {
        // The repeating effect running while the state is held; nil when none.
        var held: IconStyle.Animation? = nil
        // Held effects started since the view was installed. `held` alone
        // cannot show a restart: render() re-assigns it to the same value
        // after a remove-and-re-add, so this count is what pins "a repeated
        // snapshot leaves the running effect alone" (§9.2).
        var heldStarts = 0
        // One-shots started since the view was installed. Advances once per
        // transition into a one-shot state; a snapshot that repeats the state
        // leaves it unchanged (§9.2).
        var oneShotsStarted = 0
        var lastOneShot: IconStyle.Animation? = nil
    }

    // The value for apply's `animationsEnabled:`. Motion plays only when
    // `[ui].animations_enabled` allows it AND the system is not reducing
    // motion (System Settings > Accessibility > Display > Reduce motion);
    // neither switch overrides the other (#36). Pure, so StatusItemIconTests
    // pins the table without a controller.
    static func animationsEnabled(ui: Config.UI, reduceMotion: Bool) -> Bool {
        ui.animationsEnabled && !reduceMotion
    }

    @MainActor
    static func apply(state: BuddyState, animationsEnabled: Bool, to button: NSButton) {
        let view = imageView(in: button) ?? install(in: button)
        view.render(state: state, animationsEnabled: animationsEnabled)
        button.setAccessibilityLabel(state.rawValue)
        button.toolTip = "ContextBuddy: \(state.rawValue)"
    }

    // The image view `apply` installed in `button`; nil before the first call.
    @MainActor
    static func imageView(in button: NSButton) -> StatusIconImageView? {
        for subview in button.subviews {
            if let view = subview as? StatusIconImageView { return view }
        }
        return nil
    }

    @MainActor
    private static func install(in button: NSButton) -> StatusIconImageView {
        let view = StatusIconImageView(frame: button.bounds)
        view.autoresizingMask = [.width, .height]
        view.imageScaling = .scaleNone
        view.imageAlignment = .alignCenter
        view.isEditable = false
        // The button is the accessibility element; `apply` labels it.
        view.setAccessibilityElement(false)
        button.addSubview(view)
        return view
    }
}

// Draws the status item's glyph and runs its §9.1 motion. One per button,
// installed and driven by StatusItemIcon.apply.
final class StatusIconImageView: NSImageView {
    private(set) var state: BuddyState?
    private(set) var style: IconStyle.Style?
    private(set) var motion = StatusItemIcon.Motion()

    // Clicks belong to the button underneath: left opens the popover, right
    // opens the menu (MenubarController.handleClick). Staying out of
    // hit-testing keeps the button's target/action firing as it did when the
    // button drew the image itself.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // NSStatusBarButton draws its template image with menu-bar vibrancy;
    // matching it keeps the glyph looking like the neighbouring items.
    override var allowsVibrancy: Bool { true }

    func render(state: BuddyState, animationsEnabled: Bool) {
        let next = IconStyle.style(for: state, animationsEnabled: animationsEnabled)
        let transition = state != self.state
        // Same state, same style: a redundant snapshot. Leave a running effect
        // alone — removing and re-adding it would visibly restart the wiggle
        // on every snapshot — and start nothing (§9.2).
        guard transition || next != style else { return }
        self.state = state
        self.style = next

        // A template image is the only kind NSImageView recolors with
        // contentTintColor. Setting this to `false` makes the view draw SF
        // Symbols' own rendering instead — black for the monochrome symbols,
        // the multicolor variant for the rest — and silently discards every
        // tint in the table above (#34). ContextBuddyAppTests measures the
        // rendered pixels, so flipping it back fails the suite.
        let symbol = NSImage(systemSymbolName: next.symbol, accessibilityDescription: state.rawValue)
        symbol?.isTemplate = true
        // Effects belong to the view, not the image: clear the old state's
        // held effect, and any one-shot still playing, before the next starts.
        removeAllSymbolEffects(animated: false)
        motion.held = nil
        image = symbol
        contentTintColor = next.tint

        switch next.animation {
        case .none:
            break
        case .rotateRepeating:
            addSymbolEffect(.rotate, options: .repeating)
            motion.held = .rotateRepeating
            motion.heldStarts += 1
        case .wiggleRepeating:
            addSymbolEffect(.wiggle, options: .repeating)
            motion.held = .wiggleRepeating
            motion.heldStarts += 1
        case .scalePulseOnce, .bounceOnce:
            // §9.1 says "300ms scale pulse on transition" for attention;
            // .bounce is the nearest scale-flavored one-shot
            // (IMPLEMENTATION_PLAN.md, "§9.1 animations" row).
            guard transition else { break }
            addSymbolEffect(.bounce, options: .nonRepeating)
            motion.oneShotsStarted += 1
            motion.lastOneShot = next.animation
        case .pulseOnce:
            guard transition else { break }
            addSymbolEffect(.pulse, options: .nonRepeating)
            motion.oneShotsStarted += 1
            motion.lastOneShot = .pulseOnce
        }
    }
}
