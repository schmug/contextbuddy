import XCTest
@testable import ContextBuddyCore

// ScoreMeter is the pure model behind the popover's four threshold meters
// (SPEC.md §9.3). It exists in Core rather than the app target so the
// polarity and threshold logic is testable — ContextBuddyApp has no test
// target.
//
// The property under test is the one the old `conf:N atom:N drift:N pol:N`
// row could not express: two dimensions are higher-is-better and two are
// higher-is-worse, so a bare integer cannot tell the user whether it is a
// problem. `status` normalizes that — `.crossed` means "this one is the
// problem" on all four dimensions regardless of direction.
final class ScoreMeterTests: XCTestCase {
    private let thresholds = Config.defaults.thresholds  // conf 4, atom 4, drift 6, pol 7

    // MARK: - Polarity

    func testConfidenceAndAtomicityAreHigherIsBetter() {
        XCTAssertTrue(Dimension.confidence.higherIsBetter)
        XCTAssertTrue(Dimension.atomicity.higherIsBetter)
    }

    func testDriftAndPollutionAreHigherIsWorse() {
        XCTAssertFalse(Dimension.drift.higherIsBetter)
        XCTAssertFalse(Dimension.pollution.higherIsBetter)
    }

    // MARK: - Status, higher-is-better dimensions

    func testConfidenceBelowThresholdIsCrossed() {
        // SPEC §5.2: confidence < confidence_attention (4) triggers attention.
        let meter = ScoreMeter(dimension: .confidence, value: 2, thresholds: thresholds, isDriver: true)
        XCTAssertEqual(meter.status, .crossed)
    }

    func testConfidenceExactlyAtThresholdIsNear() {
        // 4 is not < 4, so it has not crossed — but it is one step away.
        let meter = ScoreMeter(dimension: .confidence, value: 4, thresholds: thresholds, isDriver: false)
        XCTAssertEqual(meter.status, .near)
    }

    func testConfidenceComfortablyAboveThresholdIsOK() {
        let meter = ScoreMeter(dimension: .confidence, value: 8, thresholds: thresholds, isDriver: false)
        XCTAssertEqual(meter.status, .ok)
    }

    // MARK: - Status, higher-is-worse dimensions

    func testDriftAboveThresholdIsCrossed() {
        // SPEC §5.2: drift > drift_attention (6) triggers attention.
        let meter = ScoreMeter(dimension: .drift, value: 7, thresholds: thresholds, isDriver: false)
        XCTAssertEqual(meter.status, .crossed)
    }

    func testDriftExactlyAtThresholdIsNear() {
        let meter = ScoreMeter(dimension: .drift, value: 6, thresholds: thresholds, isDriver: false)
        XCTAssertEqual(meter.status, .near)
    }

    func testDriftZeroIsOK() {
        // The case the old shorthand row got wrong: drift:0 looks like a low
        // number next to conf:2, but it is the best possible drift score.
        let meter = ScoreMeter(dimension: .drift, value: 0, thresholds: thresholds, isDriver: false)
        XCTAssertEqual(meter.status, .ok)
    }

    func testPollutionUsesItsOwnThreshold() {
        // pollution_attention is 7, not 4 — a shared threshold would be wrong.
        XCTAssertEqual(ScoreMeter(dimension: .pollution, value: 6, thresholds: thresholds, isDriver: false).status, .ok)
        XCTAssertEqual(ScoreMeter(dimension: .pollution, value: 7, thresholds: thresholds, isDriver: false).status, .near)
        XCTAssertEqual(ScoreMeter(dimension: .pollution, value: 8, thresholds: thresholds, isDriver: false).status, .crossed)
    }

    // MARK: - Screenshot case: the whole row at once

    func testLiveAttentionGradeProducesExactlyOneCrossedMeter() {
        // conf:2 atom:5 drift:0 pol:1 — the grade in the reported screenshot.
        // Only confidence should read as a problem.
        let scores = Scores(
            confidence: Score(value: 2, rationale: "no acceptance criteria"),
            atomicity: Score(value: 5, rationale: "two actions bundled"),
            drift: Score(value: 0, rationale: "aligned"),
            pollution: Score(value: 1, rationale: "clean")
        )
        let meters = ScoreMeter.meters(for: scores, thresholds: thresholds, dominantSignal: .confidence)

        XCTAssertEqual(meters.count, 4)
        XCTAssertEqual(meters.filter { $0.status == .crossed }.map(\.dimension), [.confidence])
        XCTAssertEqual(meters.first(where: { $0.isDriver })?.dimension, .confidence)
    }

    func testMetersAreOrderedConfidenceAtomicityDriftPollution() {
        // Order is load-bearing: it matches SPEC §6's rubric order and the
        // statusline, so the two surfaces stay scannable together.
        let meters = ScoreMeter.meters(
            for: Scores(
                confidence: Score(value: 5, rationale: ""),
                atomicity: Score(value: 5, rationale: ""),
                drift: Score(value: 5, rationale: ""),
                pollution: Score(value: 5, rationale: "")
            ),
            thresholds: thresholds,
            dominantSignal: nil
        )
        XCTAssertEqual(meters.map(\.dimension), [.confidence, .atomicity, .drift, .pollution])
    }

    func testNonDimensionDominantSignalMarksNoDriver() {
        // `loop` and `context_pressure` are mechanical sentinels, not scores —
        // no meter should claim to be their cause.
        let meters = ScoreMeter.meters(
            for: Scores(
                confidence: Score(value: 8, rationale: ""),
                atomicity: Score(value: 8, rationale: ""),
                drift: Score(value: 1, rationale: ""),
                pollution: Score(value: 2, rationale: "")
            ),
            thresholds: thresholds,
            dominantSignal: .loop
        )
        XCTAssertTrue(meters.allSatisfy { !$0.isDriver })
    }

    // MARK: - Bar geometry

    func testFillFractionIsRawValueOverTen() {
        // The bar draws the raw score; colour carries polarity. Drawing
        // "goodness" instead would make the bar disagree with the number.
        XCTAssertEqual(ScoreMeter(dimension: .drift, value: 0, thresholds: thresholds, isDriver: false).fillFraction, 0.0)
        XCTAssertEqual(ScoreMeter(dimension: .confidence, value: 5, thresholds: thresholds, isDriver: false).fillFraction, 0.5)
        XCTAssertEqual(ScoreMeter(dimension: .atomicity, value: 10, thresholds: thresholds, isDriver: false).fillFraction, 1.0)
    }

    func testThresholdFractionMarksTheTick() {
        XCTAssertEqual(ScoreMeter(dimension: .confidence, value: 2, thresholds: thresholds, isDriver: false).thresholdFraction, 0.4)
        XCTAssertEqual(ScoreMeter(dimension: .pollution, value: 2, thresholds: thresholds, isDriver: false).thresholdFraction, 0.7)
    }

    func testOutOfRangeValuesAreClampedForDrawingOnly() {
        // A malformed grade must not draw a bar outside its track, but the
        // displayed number stays whatever the grader actually emitted (§13:
        // warn, do not error).
        let high = ScoreMeter(dimension: .confidence, value: 42, thresholds: thresholds, isDriver: false)
        XCTAssertEqual(high.fillFraction, 1.0)
        XCTAssertEqual(high.value, 42)

        let low = ScoreMeter(dimension: .drift, value: -3, thresholds: thresholds, isDriver: false)
        XCTAssertEqual(low.fillFraction, 0.0)
        XCTAssertEqual(low.value, -3)
    }

    // MARK: - Tooltip copy

    func testTooltipNamesDirectionAndThreshold() {
        let meter = ScoreMeter(dimension: .drift, value: 0, thresholds: thresholds, isDriver: false)
        let help = meter.tooltip(rationale: "Tightly aligned with the anchor goal.")

        XCTAssertTrue(help.contains("Drift"), "tooltip should name the dimension in full")
        XCTAssertTrue(help.contains("0/10"), "tooltip should anchor the scale")
        XCTAssertTrue(help.contains("lower is better"), "tooltip must state the polarity")
        XCTAssertTrue(help.contains("6"), "tooltip should name the attention threshold")
        XCTAssertTrue(help.contains("Tightly aligned"), "tooltip must carry the grader rationale")
    }

    func testDriverTooltipSaysItDroveTheState() {
        let meter = ScoreMeter(dimension: .confidence, value: 2, thresholds: thresholds, isDriver: true)
        XCTAssertTrue(meter.tooltip(rationale: "no acceptance criteria").contains("drove"))
    }
}
