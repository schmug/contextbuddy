import AppKit
import SwiftUI
import ContextBuddyCore

// Maps BuddyState to (SFSymbol name, tint, animation policy) per §9.1.
// Animation policy is owned here so the SwiftUI view can mirror it without
// re-deciding. Honors `[ui].animations_enabled = false` by suppressing all
// motion (still emits the symbol + tint).
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
            return Style(symbol: "exclamationmark.triangle", tint: .systemOrange,
                         animation: animationsEnabled ? .scalePulseOnce : .none)
        case .celebrate:
            return Style(symbol: "sparkles", tint: .systemYellow,
                         animation: animationsEnabled ? .bounceOnce : .none)
        case .dizzy:
            return Style(symbol: "exclamationmark.arrow.circlepath", tint: .systemOrange,
                         animation: animationsEnabled ? .wiggleRepeating : .none)
        case .heart:
            return Style(symbol: "heart.fill", tint: .systemPink,
                         animation: animationsEnabled ? .pulseOnce : .none)
        }
    }

    struct Style: Equatable {
        let symbol: String
        let tint: NSColor
        let animation: Animation
    }

    // Literal mapping to §9.1. macOS 15+ minimum (Package.swift) means every
    // effect below is available without fallback per §15.
    enum Animation: Equatable {
        case none
        case scalePulseOnce       // 300ms scale pulse (attention)
        case bounceOnce           // .bounce ~2.5s (celebrate)
        case wiggleRepeating      // .wiggle indefinite (dizzy)
        case pulseOnce            // .pulse held ~3s (heart)
        case rotateRepeating      // subtle rotation indefinite (busy)
    }
}

struct StatusIconView: View {
    let state: BuddyState
    let animationsEnabled: Bool

    var body: some View {
        let style = IconStyle.style(for: state, animationsEnabled: animationsEnabled)
        let base = Image(systemName: style.symbol)
            .renderingMode(.template)
            .foregroundStyle(Color(nsColor: style.tint))
            .frame(width: 18, height: 18)
        applyAnimation(style.animation, to: base)
    }

    @ViewBuilder
    private func applyAnimation<V: View>(_ anim: IconStyle.Animation, to view: V) -> some View {
        switch anim {
        case .none:
            view
        case .scalePulseOnce:
            // §9.1 says "300ms scale pulse on transition (one-shot)". .bounce
            // is SwiftUI's nearest scale-flavored effect (a quick scale up +
            // settle). value:state ties one fire per state change.
            view.symbolEffect(.bounce, options: .nonRepeating, value: state)
        case .bounceOnce:
            view.symbolEffect(.bounce, options: .nonRepeating, value: state)
        case .wiggleRepeating:
            view.symbolEffect(.wiggle, options: .repeating)
        case .pulseOnce:
            view.symbolEffect(.pulse, options: .nonRepeating, value: state)
        case .rotateRepeating:
            view.symbolEffect(.rotate, options: .repeating)
        }
    }
}

// Applies the §9.1 style for a state to the menubar button.
//
// Extracted from MenubarController.renderIcon() so ContextBuddyAppTests can
// render the same pixels into an offscreen NSButton — the controller's own
// button belongs to a live NSStatusItem, which a test process cannot create.
// MenubarController.renderIcon() must stay a thin caller of this, or the tests
// stop covering what ships.
enum StatusItemIcon {
    @MainActor
    static func apply(state: BuddyState, animationsEnabled: Bool, to button: NSButton) {
        let style = IconStyle.style(for: state, animationsEnabled: animationsEnabled)
        let image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: state.rawValue)
        // A template image is the only kind NSButton recolors with
        // contentTintColor. Setting this to `false` makes the button draw SF
        // Symbols' own rendering instead — black for the monochrome symbols,
        // the multicolor variant for the rest — and silently discards every
        // tint in the table above (#34). ContextBuddyAppTests measures the
        // rendered pixels, so flipping it back fails the suite.
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = style.tint
        button.toolTip = "ContextBuddy: \(state.rawValue)"
    }
}
