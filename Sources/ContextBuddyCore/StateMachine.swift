import Foundation

// MARK: - BuddyState
//
// The seven states the buddy renders per SPEC.md §5.1. State machine output is
// drawn from {sleep, idle, busy, attention, celebrate, dizzy}; `heart` is
// layered on top by BuddyCore (set imperatively on user ack, decays on a
// timer). See §5.2 for full precedence.

public enum BuddyState: String, Codable, Equatable, Sendable, CaseIterable {
    case sleep
    case idle
    case busy
    case attention
    case celebrate
    case dizzy
    case heart
}

// MARK: - StateHistory
//
// Mutable bookkeeping carried between state-machine evaluations. Owned by
// BuddyCore; passed by value into StateMachine.evaluate.

public struct StateHistory: Equatable, Sendable {
    // Count of consecutive grades where all four scores >= 7. Reset to 0 on
    // any sub-7 grade or after a celebrate fires (§5.5).
    public var consecutiveAllHigh: Int

    // Turn number of the most recent UserPromptSubmit not yet matched by a
    // Stop. nil when no turn is open.
    public var openTurn: Int?

    // Wall-clock instant of the most recent grade event. Drives the sleep
    // timeout (§5.1).
    public var lastGradeAt: Date?

    public var lastGrade: Grade?

    // The state that grade-driven evaluation produced ignoring transient
    // overrides (heart, celebrate). When a transient state decays, BuddyCore
    // reverts to this. For attention/dizzy/busy/idle this equals the rendered
    // state. For celebrate this is the post-celebrate fall-through state.
    public var latestDerivedState: BuddyState

    public init(
        consecutiveAllHigh: Int = 0,
        openTurn: Int? = nil,
        lastGradeAt: Date? = nil,
        lastGrade: Grade? = nil,
        latestDerivedState: BuddyState = .sleep
    ) {
        self.consecutiveAllHigh = consecutiveAllHigh
        self.openTurn = openTurn
        self.lastGradeAt = lastGradeAt
        self.lastGrade = lastGrade
        self.latestDerivedState = latestDerivedState
    }

    public static let empty = StateHistory()
}

// MARK: - StateTransition
//
// Logged to state.db (§4.7) on every state change. `trigger` format follows
// §4.7's examples: e.g., "atomicity<4", "loop", "context_pressure",
// "celebrate_5", "idle_timeout", "all_clear", "open_turn".

public struct StateTransition: Equatable, Sendable {
    public var from: BuddyState
    public var to: BuddyState
    public var trigger: String
    public var dominantSignal: DominantSignal?
    public var turn: Int?
    public var at: Date

    public init(
        from: BuddyState,
        to: BuddyState,
        trigger: String,
        dominantSignal: DominantSignal? = nil,
        turn: Int? = nil,
        at: Date
    ) {
        self.from = from
        self.to = to
        self.trigger = trigger
        self.dominantSignal = dominantSignal
        self.turn = turn
        self.at = at
    }
}

// MARK: - StateMachine
//
// Pure functions over (prev, grade, history, cfg, now). No I/O, no timers.
// BuddyCore owns the timers for transient-state decay (heart, celebrate) and
// the periodic tick that may transition idle → sleep.

public enum StateMachine {
    // §5.1: "no grade events for >5 min and no open turn". Hard-coded — the
    // spec does not expose this in config.toml.
    public static let sleepTimeout: TimeInterval = 300

    // §5.5 says "all four scores ≥7" but §8.2 (canonical example) fires
    // celebrate with drift=1 and pollution=3 — confirming that drift and
    // pollution are inverted-semantic dimensions where low is good. We
    // interpret §5.5 as "all four in the green zone": confidence/atomicity
    // ≥ 7, drift/pollution ≤ 3. The example wins per §8 prose ("canonical
    // reference for JSON shape, rationale tone, popover layout, and
    // suggestion log format"). Worth confirming with the spec author at the
    // next review checkpoint.
    public static let highSideThreshold: Int = 7   // confidence, atomicity
    public static let lowSideThreshold: Int = 3    // drift, pollution

    // Q2 decision: when multiple thresholds cross, pick the dominant in this
    // order. atomicity is most-actionable per §6 prose.
    public static let dimensionPrecedence: [Dimension] = [
        .atomicity, .confidence, .drift, .pollution
    ]

    // Evaluate a fresh grade. Returns the rendered state (could be a
    // transient like celebrate), an updated history, and the transition for
    // logging.
    public static func evaluate(
        prev: BuddyState,
        grade: Grade,
        history: StateHistory,
        cfg: Config,
        now: Date
    ) -> (state: BuddyState, history: StateHistory, transition: StateTransition?) {
        var h = history
        h.lastGrade = grade
        h.lastGradeAt = now

        // Open-turn bookkeeping.
        switch grade.phase {
        case .pre:
            h.openTurn = grade.turn
        case .post:
            if h.openTurn == grade.turn {
                h.openTurn = nil
            }
        }

        // Celebrate counter.
        let allHigh = isAllHigh(grade.scores)
        if allHigh {
            h.consecutiveAllHigh += 1
        } else {
            h.consecutiveAllHigh = 0
        }

        // Resolve state by precedence (excluding heart, which is overlay).
        var derived: BuddyState
        var trigger: String
        var dominant: DominantSignal? = nil

        if grade.dominantSignal == .loop {
            derived = .dizzy
            trigger = "loop"
            dominant = .loop
        } else if grade.dominantSignal == .contextPressure {
            derived = .dizzy
            trigger = "context_pressure"
            dominant = .contextPressure
        } else if let crossing = firstCrossedThreshold(grade.scores, cfg: cfg.thresholds) {
            derived = .attention
            trigger = crossing.triggerString
            dominant = crossing.dominant
        } else if h.consecutiveAllHigh >= cfg.thresholds.celebrateConsecutiveN {
            // Reset counter so the next celebrate requires another N clean
            // grades (§5.5).
            h.consecutiveAllHigh = 0
            // Underlying post-celebrate state is busy or idle depending on
            // openTurn — this is what celebrate decays to.
            h.latestDerivedState = (h.openTurn != nil) ? .busy : .idle
            let transition = StateTransition(
                from: prev,
                to: .celebrate,
                trigger: "celebrate_\(cfg.thresholds.celebrateConsecutiveN)",
                dominantSignal: nil,
                turn: grade.turn,
                at: now
            )
            return (.celebrate, h, prev == .celebrate ? nil : transition)
        } else if h.openTurn != nil {
            derived = .busy
            trigger = "open_turn"
        } else {
            derived = .idle
            trigger = (prev == .attention || prev == .dizzy) ? "all_clear" : "idle"
        }

        h.latestDerivedState = derived

        let transition: StateTransition? = (prev == derived) ? nil : StateTransition(
            from: prev,
            to: derived,
            trigger: trigger,
            dominantSignal: dominant,
            turn: grade.turn,
            at: now
        )
        return (derived, h, transition)
    }

    // Time-based tick. Called by BuddyCore on a periodic timer (and on initial
    // launch with no grades yet). Returns sleep if §5.1 conditions are met,
    // otherwise returns prev unchanged.
    public static func tick(
        prev: BuddyState,
        history: StateHistory,
        now: Date
    ) -> (state: BuddyState, transition: StateTransition?) {
        // Don't override transient states; let their decay timers handle it.
        if prev == .heart || prev == .celebrate {
            return (prev, nil)
        }
        // Don't sleep while a turn is open — agent is working.
        if history.openTurn != nil {
            return (prev, nil)
        }
        // No grades yet -> sleep.
        guard let last = history.lastGradeAt else {
            if prev == .sleep {
                return (.sleep, nil)
            }
            return (.sleep, StateTransition(from: prev, to: .sleep, trigger: "no_grades", at: now))
        }
        if now.timeIntervalSince(last) > sleepTimeout {
            if prev == .sleep {
                return (.sleep, nil)
            }
            return (
                .sleep,
                StateTransition(from: prev, to: .sleep, trigger: "idle_timeout", at: now)
            )
        }
        return (prev, nil)
    }

    // Called by BuddyCore when the celebrate animation timer expires. Returns
    // the underlying derived state to revert to.
    public static func decayCelebrate(history: StateHistory) -> BuddyState {
        history.latestDerivedState
    }

    // Called by BuddyCore when the heart timer expires. Returns the derived
    // state that was active before the heart override.
    public static func decayHeart(history: StateHistory) -> BuddyState {
        history.latestDerivedState
    }

    // MARK: - Helpers

    private static func isAllHigh(_ scores: Scores) -> Bool {
        Dimension.allCases.allSatisfy { isInCelebrateZone($0, value: scores[$0].value) }
    }

    private static func isInCelebrateZone(_ dim: Dimension, value: Int) -> Bool {
        switch dim {
        case .confidence, .atomicity: return value >= highSideThreshold
        case .drift, .pollution: return value <= lowSideThreshold
        }
    }

    private struct ThresholdCrossing {
        let dominant: DominantSignal
        let triggerString: String
    }

    private static func firstCrossedThreshold(
        _ scores: Scores,
        cfg: Config.Thresholds
    ) -> ThresholdCrossing? {
        // Walk dimensions in Q2 precedence order; return first violator.
        for dim in dimensionPrecedence {
            let value = scores[dim].value
            switch dim {
            case .confidence:
                if value < cfg.confidenceAttention {
                    return ThresholdCrossing(
                        dominant: .confidence,
                        triggerString: "confidence<\(cfg.confidenceAttention)"
                    )
                }
            case .atomicity:
                if value < cfg.atomicityAttention {
                    return ThresholdCrossing(
                        dominant: .atomicity,
                        triggerString: "atomicity<\(cfg.atomicityAttention)"
                    )
                }
            case .drift:
                if value > cfg.driftAttention {
                    return ThresholdCrossing(
                        dominant: .drift,
                        triggerString: "drift>\(cfg.driftAttention)"
                    )
                }
            case .pollution:
                if value > cfg.pollutionAttention {
                    return ThresholdCrossing(
                        dominant: .pollution,
                        triggerString: "pollution>\(cfg.pollutionAttention)"
                    )
                }
            }
        }
        return nil
    }
}
