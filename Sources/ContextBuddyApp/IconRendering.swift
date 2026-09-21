import AppKit
import ContextBuddyCore

// Maps BuddyState to (SFSymbol name, animation policy) per §9.1. The glyph's
// colour is not in that mapping: the system supplies it (see "Why there is no
// tint table here any more" below).
//
// The glyph set was redesigned in #37 against three measured faults: no
// SymbolConfiguration at all, optical weight swinging 5.5x across the seven,
// and two pairs of states that shared a silhouette. `circle` (idle) and
// `circle.dotted` (busy) differed only in stroke continuity — 0.109 apart in
// silhouette, which at 15pt is not a difference — and `attention` and `dizzy`
// were both an orange exclamation mark. Since §9.6 gives the buddy no
// notification, no sound and no window, two states that read alike are two
// states the product cannot signal. Every symbol below exists in the macOS 15
// SF Symbols set (CoreGlyphs `name_availability.plist`), which is the floor
// Package.swift sets; an unknown name resolves to nil and renders a blank
// menu bar with no error.
// No tint is declared here at all. Every glyph ships as a template image with
// `contentTintColor` left nil, which is the menu bar extra contract Apple
// states: "Both interface icons and symbols use black and clear colors to
// define their shapes; the system can apply other colors to the black areas in
// each image so it looks good on both dark and light menu bars, and when your
// menu bar extra is selected." Handing the system a template is what makes the
// glyph track the bar; declaring a colour opts out of it (#90).
// Animation policy is owned here so StatusIconImageView can mirror it without
// re-deciding. `animationsEnabled` is `[ui].animations_enabled` ANDed with the
// system Reduce Motion switch — StatusItemIcon.animationsEnabled(ui:reduceMotion:)
// composes them and MenubarController.renderIcon() passes the result — and
// false suppresses all motion (still emits the symbol). (#36)
enum IconStyle {
    // One configuration for all seven glyphs (#37). Without it each symbol
    // rendered at its own natural metrics — widths of 15, 16 and 17pt, heights
    // of 14, 15 and 17pt — so the set had no shared type size at all.
    //
    // 15pt is the largest size at which every glyph in the table below still
    // fits inside StatusItemIcon.glyphBox; the widest, `progress.indicator`,
    // measures 19x18pt and `repeat` 20x16pt. The image view scales nothing
    // (`imageScaling = .scaleNone`), so a glyph wider than the box is clipped
    // rather than shrunk — `infinity` at 23pt was rejected for exactly that.
    // StatusItemIconTests asserts the fit for every state.
    //
    // This does NOT make `image.size` equal across the seven: SF Symbols have
    // different aspect ratios, and the only way to force one size is to draw
    // each glyph into a fixed canvas — which replaces the NSSymbolImageRep
    // with an NSCustomImageRep and silently kills every §9.1 animation with
    // it (#35's regression, re-measured: `isSymbolImage` goes 1 -> 0). Equal
    // widths are not needed anyway; StatusItemIcon.length is fixed, so the
    // status item has not changed width since #35 regardless of the glyph.
    // Held in an @unchecked Sendable holder because
    // NSImage.SymbolConfiguration is not Sendable, so a plain `static let`
    // fails strict concurrency, and `nonisolated(unsafe)` is load-bearing on
    // one of the two SDKs this repo builds against and a warning on the other
    // (#43, #46). The holder compiles clean on both. The instance is
    // immutable and only read.
    static var symbolConfiguration: NSImage.SymbolConfiguration { Metrics.shared.configuration }

    private final class Metrics: @unchecked Sendable {
        static let shared = Metrics()
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
    }

    static func style(for state: BuddyState, animationsEnabled: Bool) -> Style {
        switch state {
        case .sleep:
            return Style(symbol: "moon.zzz", animation: .none)
        case .idle:
            return Style(symbol: "record.circle", animation: .none)
        case .busy:
            return Style(symbol: "progress.indicator",
                         animation: animationsEnabled ? .rotateRepeating : .none)
        case .attention:
            return Style(symbol: "exclamationmark.triangle",
                         animation: animationsEnabled ? .scalePulseOnce : .none)
        case .celebrate:
            return Style(symbol: "sparkles",
                         animation: animationsEnabled ? .bounceOnce : .none)
        case .dizzy:
            return Style(symbol: "repeat",
                         animation: animationsEnabled ? .wiggleRepeating : .none)
        case .heart:
            return Style(symbol: "heart",
                         animation: animationsEnabled ? .pulseOnce : .none)
        }
    }

    // Why there is no tint table here any more (#90).
    //
    // §9.1 used to assert a 4.5:1 floor against two opaque greys, sRGB 0.11
    // for the dark menu bar and 0.96 for the light one, and every tint in the
    // table was tuned against them. Neither background occurs. Measured on
    // macOS 26.6.2 by sweeping the desktop picture from black to white and
    // reading the bar back out of a screen capture:
    //
    //   * The bar is effectively transparent. It reads L=0.0000 over a black
    //     desktop picture and L=0.9647 over a white one — the modelled dark
    //     bar's L=0.011 is off by the whole range, not by a margin.
    //   * macOS switches the status item's *effective appearance* with the
    //     wallpaper's brightness while the system stays in Dark Mode. A probe
    //     status item tinted blue under .darkAqua and red under .aqua rendered
    //     blue over a black picture and red over a white one.
    //   * The two appearances therefore cover disjoint bands, measured
    //     .darkAqua L=[0.000, 0.195] and .aqua L=[0.546, 0.965]. The switch is
    //     a step: wallpaper 160 gives a .darkAqua bar at L=0.195, wallpaper
    //     168 an .aqua bar at L=0.546. Nothing in between is reachable.
    //   * No flat colour clears 4.5:1 across the .darkAqua band. Beating
    //     L=0.195 from the light side needs a glyph at L>=1.052, and pure
    //     white is 1.0 — it reaches 4.29:1 and stops. That is a proof, not a
    //     tuning problem, so no tint table could have been correct.
    //
    // The fix is to stop declaring a colour. A template image with
    // `contentTintColor` nil is coloured by the system, which inverts it with
    // the bar. Measured against Docker's icon in the same captures, ink versus
    // its own local bar:
    //
    //   bar L=0.000  16.83:1 (Docker 16.79)   bar L=0.147  4.69:1 (4.62)
    //   bar L=0.188   3.92:1 (Docker 3.93)    bar L=0.521  9.37:1 (9.27)
    //   bar L=0.956  15.06:1 (Docker 14.74)
    //
    // ContextBuddy now tracks the system's own menu bar items within 2% at
    // every background. The worst point, 3.92:1, is a macOS ceiling that
    // Docker hits too; it is not something a tint could have bought back.
    // `.labelColor` is not equivalent — its alpha lets the bar through, and it
    // measured 8.84:1 where the untinted template measured 15.06:1 on a white
    // bar.
    //
    // Consequence for the set: colour no longer separates the seven states, so
    // silhouette carries all of it. #88's separations are the guarantee that
    // this works — 0.753 for idle/busy, 0.780 for attention/dizzy, 0.682 for
    // the closest of all 21 pairs — and StatusItemIconTests holds them.
    //
    // Do not reintroduce `contentTintColor` to recolour a state. It opts the
    // glyph out of the system's inversion, which is the whole mechanism.

    // No `tint`: the system colours the template image (see above). Style stays
    // Equatable because StatusIconImageView.render compares it to tell a
    // transition from a redundant snapshot (§9.2).
    struct Style: Equatable {
        let symbol: String
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

// Applies the §9.1 style for a state to the menubar button: glyph, motion,
// tooltip and accessibility label.
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

    // The square the glyph is drawn in, inside that item. IconStyle's shared
    // SymbolConfiguration is sized so every §9.1 symbol fits here: the image
    // view scales nothing, so anything larger is clipped on all four sides.
    static let glyphBox = NSSize(width: 22, height: 22)

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

    // `graderStatus` adds one tooltip line when the grader could not run
    // (§4.10, issue #92). The glyph, tint and motion are untouched: a broken
    // grader is a tooling fault, not a grade, and §9.1's seven states each mean
    // something about the conversation. It reaches the accessibility label too,
    // because a hover tooltip is not available to VoiceOver.
    @MainActor
    static func apply(
        state: BuddyState,
        animationsEnabled: Bool,
        graderStatus: GraderStatus? = nil,
        to button: NSButton
    ) {
        let view = imageView(in: button) ?? install(in: button)
        view.render(state: state, animationsEnabled: animationsEnabled)
        button.setAccessibilityLabel(accessibilityLabel(state: state, graderStatus: graderStatus))
        button.toolTip = toolTip(state: state, graderStatus: graderStatus)
    }

    // Pure, so StatusItemIconTests pins the wording without a live status item.
    static func toolTip(state: BuddyState, graderStatus: GraderStatus?) -> String {
        let base = "ContextBuddy: \(state.rawValue)"
        guard let graderStatus, graderStatus.isFailure else { return base }
        return "\(base)\n\(graderStatus.summaryLine)"
    }

    static func accessibilityLabel(state: BuddyState, graderStatus: GraderStatus?) -> String {
        guard let graderStatus, graderStatus.isFailure else { return state.rawValue }
        return "\(state.rawValue), \(graderStatus.summaryLine)"
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

        // `isTemplate` is load-bearing twice over. Setting it false makes the
        // view draw SF Symbols' own rendering instead — black for the
        // monochrome symbols, the multicolor variant for the rest (#34) — and
        // it is also what lets the system colour the glyph against the menu
        // bar at all (#90). ContextBuddyAppTests measures the rendered pixels,
        // so flipping it back fails the suite.
        // `withSymbolConfiguration` returns a new NSImage and does not carry
        // the accessibility description over, so it is set again on the result
        // — StatusItemIconTests reads it off the shipped image.
        let symbol = NSImage(systemSymbolName: next.symbol, accessibilityDescription: state.rawValue)?
            .withSymbolConfiguration(IconStyle.symbolConfiguration)
        symbol?.isTemplate = true
        symbol?.accessibilityDescription = state.rawValue
        // Effects belong to the view, not the image: clear the old state's
        // held effect, and any one-shot still playing, before the next starts.
        removeAllSymbolEffects(animated: false)
        motion.held = nil
        image = symbol
        // Explicitly nil, not merely unset: the view is reused across states,
        // so a tint left behind by an earlier render would stick and opt the
        // glyph out of the system's inversion (#90).
        contentTintColor = nil

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
