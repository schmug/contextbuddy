import Foundation

// MARK: - ScoreMeter
//
// The model behind the popover's four threshold meters (SPEC.md §9.3).
//
// It lives in Core, not in ContextBuddyApp, because ContextBuddyApp has no
// test target and this is the logic that has to be right: two of the four
// dimensions are higher-is-better and two are higher-is-worse (§6), so a bare
// integer cannot tell the user whether it is a problem. The old score row
// (`conf:2 atom:5 drift:0 pol:1`) rendered all four identically and left the
// polarity to be inferred from the rubric.
//
// `status` normalizes that: `.crossed` means "this one is the problem" on all
// four dimensions regardless of which direction is bad. The view maps status
// to colour, so the user never has to know the polarity to read the row.

public extension Dimension {
    // Per §6: confidence and atomicity are qualities to maximize; drift and
    // pollution are quantities to minimize.
    var higherIsBetter: Bool {
        switch self {
        case .confidence, .atomicity: return true
        case .drift, .pollution: return false
        }
    }

    // Full-word label. The abbreviations the old row used ("pol", "atom")
    // were ambiguous — "pol" reads as policy or polarity.
    var displayName: String {
        switch self {
        case .confidence: return "Confidence"
        case .atomicity: return "Atomicity"
        case .drift: return "Drift"
        case .pollution: return "Pollution"
        }
    }

    // The one-line rubric question from §6.
    var question: String {
        switch self {
        case .confidence: return "is the prompt well-specified?"
        case .atomicity: return "is it one thing?"
        case .drift: return "are we still doing what we said?"
        case .pollution: return "how much of the context is dead weight?"
        }
    }

    func attentionThreshold(in thresholds: Config.Thresholds) -> Int {
        switch self {
        case .confidence: return thresholds.confidenceAttention
        case .atomicity: return thresholds.atomicityAttention
        case .drift: return thresholds.driftAttention
        case .pollution: return thresholds.pollutionAttention
        }
    }
}

// Where a score sits relative to its own attention threshold.
public enum ScoreStatus: Equatable, Sendable {
    case ok        // comfortable
    case near      // exactly at the boundary — one step from triggering
    case crossed   // past the threshold; this is an attention trigger per §5.2
}

public struct ScoreMeter: Equatable, Sendable {
    public let dimension: Dimension
    public let value: Int
    public let threshold: Int
    public let status: ScoreStatus
    // True when this dimension is the grade's dominant_signal — the score
    // that drove the current state. False for every meter when the dominant
    // signal is a mechanical sentinel (loop / context_pressure), which no
    // score caused.
    public let isDriver: Bool

    public static let scale = 10

    public init(dimension: Dimension, value: Int, thresholds: Config.Thresholds, isDriver: Bool) {
        let threshold = dimension.attentionThreshold(in: thresholds)
        self.dimension = dimension
        self.value = value
        self.threshold = threshold
        self.isDriver = isDriver

        // §5.2: confidence/atomicity trigger BELOW their threshold;
        // drift/pollution trigger ABOVE it. Sitting exactly on the threshold
        // has not triggered, but is one step away.
        if dimension.higherIsBetter {
            if value < threshold { self.status = .crossed }
            else if value == threshold { self.status = .near }
            else { self.status = .ok }
        } else {
            if value > threshold { self.status = .crossed }
            else if value == threshold { self.status = .near }
            else { self.status = .ok }
        }
    }

    // The bar draws the RAW score, not "goodness" — a bar that inverted for
    // drift and pollution would visibly disagree with the number beside it.
    // Colour carries the polarity instead. Clamped so a malformed grade
    // cannot draw outside its track, while `value` keeps whatever the grader
    // emitted (§13: warn, do not error).
    public var fillFraction: Double {
        min(1.0, max(0.0, Double(value) / Double(Self.scale)))
    }

    // Position of the threshold tick along the same track.
    public var thresholdFraction: Double {
        min(1.0, max(0.0, Double(threshold) / Double(Self.scale)))
    }

    public var directionText: String {
        dimension.higherIsBetter ? "higher is better" : "lower is better"
    }

    // What the threshold means in words, for the tooltip.
    public var thresholdText: String {
        dimension.higherIsBetter
            ? "attention below \(threshold)"
            : "attention above \(threshold)"
    }

    public func tooltip(rationale: String) -> String {
        var lines = [
            "\(dimension.displayName) \(value)/\(Self.scale) — \(dimension.question)",
            "\(directionText); \(thresholdText).",
        ]
        if isDriver {
            lines.append("This score drove the current state.")
        }
        let trimmed = rationale.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines.append("")
            lines.append(trimmed)
        }
        return lines.joined(separator: "\n")
    }

    // The four meters in §6 rubric order, which is also the order the status
    // line prints — the two surfaces stay scannable together.
    public static func meters(
        for scores: Scores,
        thresholds: Config.Thresholds,
        dominantSignal: DominantSignal?
    ) -> [ScoreMeter] {
        let driver = dominantSignal.flatMap { Dimension(rawValue: $0.rawValue) }
        return Dimension.allCases.map { dimension in
            ScoreMeter(
                dimension: dimension,
                value: scores[dimension].value,
                thresholds: thresholds,
                isDriver: dimension == driver
            )
        }
    }
}
