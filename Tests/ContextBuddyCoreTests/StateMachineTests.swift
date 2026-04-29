import XCTest
@testable import ContextBuddyCore

final class StateMachineTests: XCTestCase {
    private let cfg = Config.defaults
    private let now = Date(timeIntervalSince1970: 1_777_000_000)

    // MARK: - Attention by score threshold (§5.1, §6)

    func testIdleToAttentionOnConfidenceCross() {
        let grade = makeGrade(confidence: 3, atomicity: 8, drift: 1, pollution: 2)
        let result = StateMachine.evaluate(prev: .idle, grade: grade, history: .empty, cfg: cfg, now: now)
        XCTAssertEqual(result.state, .attention)
        XCTAssertEqual(result.transition?.dominantSignal, .confidence)
        XCTAssertEqual(result.transition?.trigger, "confidence<4")
    }

    func testIdleToAttentionOnAtomicityCross() {
        let grade = makeGrade(confidence: 8, atomicity: 3, drift: 1, pollution: 2)
        let r = StateMachine.evaluate(prev: .idle, grade: grade, history: .empty, cfg: cfg, now: now)
        XCTAssertEqual(r.state, .attention)
        XCTAssertEqual(r.transition?.dominantSignal, .atomicity)
    }

    func testIdleToAttentionOnDriftCross() {
        let grade = makeGrade(confidence: 8, atomicity: 8, drift: 7, pollution: 2)
        let r = StateMachine.evaluate(prev: .idle, grade: grade, history: .empty, cfg: cfg, now: now)
        XCTAssertEqual(r.state, .attention)
        XCTAssertEqual(r.transition?.dominantSignal, .drift)
        XCTAssertEqual(r.transition?.trigger, "drift>6")
    }

    func testIdleToAttentionOnPollutionCross() {
        let grade = makeGrade(confidence: 8, atomicity: 8, drift: 1, pollution: 8)
        let r = StateMachine.evaluate(prev: .idle, grade: grade, history: .empty, cfg: cfg, now: now)
        XCTAssertEqual(r.state, .attention)
        XCTAssertEqual(r.transition?.dominantSignal, .pollution)
        XCTAssertEqual(r.transition?.trigger, "pollution>7")
    }

    // Q2 decision: atomicity > confidence > drift > pollution.
    func testDominantPrecedenceWhenMultipleCross() {
        let grade = makeGrade(confidence: 3, atomicity: 3, drift: 9, pollution: 9)
        let r = StateMachine.evaluate(prev: .idle, grade: grade, history: .empty, cfg: cfg, now: now)
        XCTAssertEqual(r.transition?.dominantSignal, .atomicity, "atomicity wins ties (Q2)")
    }

    func testAttentionAutoClears() {
        let prevHistory = StateHistory(consecutiveAllHigh: 0, openTurn: nil, lastGradeAt: now, lastGrade: nil, latestDerivedState: .attention)
        let cleanGrade = makeGrade(confidence: 8, atomicity: 8, drift: 1, pollution: 2)
        let r = StateMachine.evaluate(prev: .attention, grade: cleanGrade, history: prevHistory, cfg: cfg, now: now.addingTimeInterval(1))
        XCTAssertEqual(r.state, .idle)
        XCTAssertEqual(r.transition?.trigger, "all_clear")
    }

    // MARK: - Celebrate (§5.5)

    func testCelebrateFiresOnNthConsecutiveCleanGrade() {
        var history = StateHistory.empty
        var prev: BuddyState = .idle
        let n = cfg.thresholds.celebrateConsecutiveN

        for i in 1...(n - 1) {
            let g = makeGrade(turn: i, phase: .post, confidence: 8, atomicity: 8, drift: 1, pollution: 2)
            let r = StateMachine.evaluate(prev: prev, grade: g, history: history, cfg: cfg, now: now)
            XCTAssertNotEqual(r.state, .celebrate, "should not fire before grade #\(n)")
            prev = r.state
            history = r.history
        }
        let final = makeGrade(turn: n, phase: .post, confidence: 8, atomicity: 8, drift: 1, pollution: 2)
        let r = StateMachine.evaluate(prev: prev, grade: final, history: history, cfg: cfg, now: now)
        XCTAssertEqual(r.state, .celebrate)
        XCTAssertEqual(r.history.consecutiveAllHigh, 0, "counter resets after celebrate fires")
    }

    func testCelebrateCounterResetsOnSubSevenGrade() {
        var history = StateHistory.empty
        var prev: BuddyState = .idle
        let n = cfg.thresholds.celebrateConsecutiveN

        for i in 1...(n - 1) {
            let g = makeGrade(turn: i, phase: .post, confidence: 8, atomicity: 8, drift: 1, pollution: 2)
            let r = StateMachine.evaluate(prev: prev, grade: g, history: history, cfg: cfg, now: now)
            prev = r.state
            history = r.history
        }
        XCTAssertEqual(history.consecutiveAllHigh, n - 1)
        let dirty = makeGrade(turn: n, phase: .post, confidence: 6, atomicity: 8, drift: 1, pollution: 2)
        let r = StateMachine.evaluate(prev: prev, grade: dirty, history: history, cfg: cfg, now: now)
        XCTAssertEqual(r.history.consecutiveAllHigh, 0)
        XCTAssertNotEqual(r.state, .celebrate)
    }

    func testCelebrateFallthroughIsBusyWhenTurnOpen() {
        // Pre-grade with all-high scores at counter == N-1 will tick to N and
        // fire celebrate. latestDerivedState should be .busy because the
        // pre-grade leaves an open turn.
        let history = StateHistory(consecutiveAllHigh: cfg.thresholds.celebrateConsecutiveN - 1, openTurn: nil, lastGradeAt: now, lastGrade: nil, latestDerivedState: .idle)
        let pre = makeGrade(turn: 7, phase: .pre, confidence: 8, atomicity: 8, drift: 1, pollution: 2)
        let r = StateMachine.evaluate(prev: .idle, grade: pre, history: history, cfg: cfg, now: now)
        XCTAssertEqual(r.state, .celebrate)
        XCTAssertEqual(r.history.latestDerivedState, .busy)
        XCTAssertEqual(StateMachine.decayCelebrate(history: r.history), .busy)
    }

    func testCelebrateFallthroughIsIdleAfterPostGrade() {
        let history = StateHistory(consecutiveAllHigh: cfg.thresholds.celebrateConsecutiveN - 1, openTurn: 7, lastGradeAt: now, lastGrade: nil, latestDerivedState: .busy)
        let post = makeGrade(turn: 7, phase: .post, confidence: 8, atomicity: 8, drift: 1, pollution: 2)
        let r = StateMachine.evaluate(prev: .busy, grade: post, history: history, cfg: cfg, now: now)
        XCTAssertEqual(r.state, .celebrate)
        XCTAssertEqual(r.history.latestDerivedState, .idle)
        XCTAssertEqual(StateMachine.decayCelebrate(history: r.history), .idle)
    }

    // MARK: - Dizzy (§5.4)

    func testDizzyOnLoopSentinel() {
        let g = makeGrade(dominantSignal: .loop)
        let r = StateMachine.evaluate(prev: .idle, grade: g, history: .empty, cfg: cfg, now: now)
        XCTAssertEqual(r.state, .dizzy)
        XCTAssertEqual(r.transition?.trigger, "loop")
        XCTAssertEqual(r.transition?.dominantSignal, .loop)
    }

    func testDizzyOnContextPressureSentinel() {
        let g = makeGrade(dominantSignal: .contextPressure)
        let r = StateMachine.evaluate(prev: .idle, grade: g, history: .empty, cfg: cfg, now: now)
        XCTAssertEqual(r.state, .dizzy)
        XCTAssertEqual(r.transition?.trigger, "context_pressure")
    }

    func testDizzyClearsWhenNeitherSignalPresent() {
        let priorHistory = StateHistory(consecutiveAllHigh: 0, openTurn: nil, lastGradeAt: now, lastGrade: nil, latestDerivedState: .dizzy)
        let g = makeGrade(confidence: 8, atomicity: 8, drift: 1, pollution: 2)
        let r = StateMachine.evaluate(prev: .dizzy, grade: g, history: priorHistory, cfg: cfg, now: now)
        XCTAssertEqual(r.state, .idle)
        XCTAssertEqual(r.transition?.trigger, "all_clear")
    }

    // MARK: - Precedence (§5.2)

    func testDizzyBeatsAttention() {
        // Loop sentinel set AND atomicity below threshold — dizzy should win.
        let g = makeGrade(confidence: 8, atomicity: 2, drift: 1, pollution: 2, dominantSignal: .loop)
        let r = StateMachine.evaluate(prev: .idle, grade: g, history: .empty, cfg: cfg, now: now)
        XCTAssertEqual(r.state, .dizzy)
    }

    func testAttentionBeatsCelebrate() {
        // Even with N consecutive all-high history, a sub-7 grade firing
        // attention should win over celebrate (precedence) — celebrate can't
        // fire on a sub-7 grade anyway, but the explicit guard documents §5.2.
        var history = StateHistory.empty
        history.consecutiveAllHigh = cfg.thresholds.celebrateConsecutiveN
        let g = makeGrade(confidence: 3, atomicity: 8, drift: 1, pollution: 2)
        let r = StateMachine.evaluate(prev: .idle, grade: g, history: history, cfg: cfg, now: now)
        XCTAssertEqual(r.state, .attention)
    }

    // MARK: - Busy (§5.1)

    func testBusyOnPreWithoutPost() {
        let pre = makeGrade(turn: 5, phase: .pre, confidence: 8, atomicity: 8, drift: 1, pollution: 2)
        let r = StateMachine.evaluate(prev: .idle, grade: pre, history: .empty, cfg: cfg, now: now)
        XCTAssertEqual(r.state, .busy)
        XCTAssertEqual(r.history.openTurn, 5)
    }

    func testBusyClearsOnMatchingPost() {
        let preHistory = StateHistory(consecutiveAllHigh: 0, openTurn: 5, lastGradeAt: now, lastGrade: nil, latestDerivedState: .busy)
        let post = makeGrade(turn: 5, phase: .post, confidence: 8, atomicity: 8, drift: 1, pollution: 2)
        let r = StateMachine.evaluate(prev: .busy, grade: post, history: preHistory, cfg: cfg, now: now)
        XCTAssertEqual(r.state, .idle)
        XCTAssertNil(r.history.openTurn)
    }

    func testQ9SleepClearsOnNewPreGoesToBusy() {
        let priorHistory = StateHistory(consecutiveAllHigh: 0, openTurn: nil, lastGradeAt: now.addingTimeInterval(-3600), lastGrade: nil, latestDerivedState: .sleep)
        let pre = makeGrade(turn: 1, phase: .pre, confidence: 8, atomicity: 8, drift: 1, pollution: 2)
        let r = StateMachine.evaluate(prev: .sleep, grade: pre, history: priorHistory, cfg: cfg, now: now)
        XCTAssertEqual(r.state, .busy)
    }

    func testQ9SleepClearsOnNewPostGoesToIdle() {
        let priorHistory = StateHistory(consecutiveAllHigh: 0, openTurn: nil, lastGradeAt: now.addingTimeInterval(-3600), lastGrade: nil, latestDerivedState: .sleep)
        let post = makeGrade(turn: 1, phase: .post, confidence: 8, atomicity: 8, drift: 1, pollution: 2)
        let r = StateMachine.evaluate(prev: .sleep, grade: post, history: priorHistory, cfg: cfg, now: now)
        XCTAssertEqual(r.state, .idle)
    }

    // MARK: - Sleep tick (§5.1)

    func testTickSleepsAfterTimeoutWithNoOpenTurn() {
        let history = StateHistory(consecutiveAllHigh: 0, openTurn: nil, lastGradeAt: now.addingTimeInterval(-301), lastGrade: nil, latestDerivedState: .idle)
        let r = StateMachine.tick(prev: .idle, history: history, now: now)
        XCTAssertEqual(r.state, .sleep)
        XCTAssertEqual(r.transition?.trigger, "idle_timeout")
    }

    func testTickDoesNotSleepWhenTurnOpen() {
        let history = StateHistory(consecutiveAllHigh: 0, openTurn: 5, lastGradeAt: now.addingTimeInterval(-3600), lastGrade: nil, latestDerivedState: .busy)
        let r = StateMachine.tick(prev: .busy, history: history, now: now)
        XCTAssertEqual(r.state, .busy)
        XCTAssertNil(r.transition)
    }

    func testTickDoesNotInterruptHeartOrCelebrate() {
        let history = StateHistory(consecutiveAllHigh: 0, openTurn: nil, lastGradeAt: now.addingTimeInterval(-3600), lastGrade: nil, latestDerivedState: .idle)
        XCTAssertEqual(StateMachine.tick(prev: .heart, history: history, now: now).state, .heart)
        XCTAssertEqual(StateMachine.tick(prev: .celebrate, history: history, now: now).state, .celebrate)
    }

    func testTickSleepsWhenNoGradesEverReceived() {
        let r = StateMachine.tick(prev: .idle, history: .empty, now: now)
        XCTAssertEqual(r.state, .sleep)
    }

    func testTickIdleStaysIdleWithinTimeout() {
        let history = StateHistory(consecutiveAllHigh: 0, openTurn: nil, lastGradeAt: now.addingTimeInterval(-60), lastGrade: nil, latestDerivedState: .idle)
        let r = StateMachine.tick(prev: .idle, history: history, now: now)
        XCTAssertEqual(r.state, .idle)
        XCTAssertNil(r.transition)
    }

    // MARK: - Transient decay helpers

    func testDecayHeartReturnsLatestDerivedState() {
        let history = StateHistory(consecutiveAllHigh: 0, openTurn: nil, lastGradeAt: now, lastGrade: nil, latestDerivedState: .attention)
        XCTAssertEqual(StateMachine.decayHeart(history: history), .attention)
    }

    func testDecayCelebrateReturnsLatestDerivedState() {
        let history = StateHistory(consecutiveAllHigh: 0, openTurn: 5, lastGradeAt: now, lastGrade: nil, latestDerivedState: .busy)
        XCTAssertEqual(StateMachine.decayCelebrate(history: history), .busy)
    }

    // MARK: - No-op transition (state didn't change)

    func testNoTransitionEmittedWhenStateUnchanged() {
        let history = StateHistory(consecutiveAllHigh: 0, openTurn: nil, lastGradeAt: now, lastGrade: nil, latestDerivedState: .idle)
        let g = makeGrade(confidence: 8, atomicity: 8, drift: 1, pollution: 2)
        let r = StateMachine.evaluate(prev: .idle, grade: g, history: history, cfg: cfg, now: now)
        XCTAssertEqual(r.state, .idle)
        XCTAssertNil(r.transition, "no transition emitted when prev == new")
    }

    // MARK: - Helpers

    private func makeGrade(
        turn: Int = 1,
        phase: Phase = .post,
        confidence: Int = 8,
        atomicity: Int = 8,
        drift: Int = 1,
        pollution: Int = 2,
        dominantSignal: DominantSignal? = nil
    ) -> Grade {
        Grade(
            phase: phase,
            turn: turn,
            timestamp: "2026-04-29T00:00:00Z",
            scores: Scores(
                confidence: Score(value: confidence, rationale: "c"),
                atomicity: Score(value: atomicity, rationale: "a"),
                drift: Score(value: drift, rationale: "d"),
                pollution: Score(value: pollution, rationale: "p")
            ),
            tokensUsed: 100,
            tokensLimit: 200_000,
            dominantSignal: dominantSignal,
            summaryUpdate: "test"
        )
    }
}
