import AppKit
import XCTest
import ContextBuddyCore
@testable import ContextBuddyApp

// The three surfaces that say "the grader cannot run" (issue #92): the menubar
// tooltip, the right-click menu line, and — not covered here, because §15
// forbids tests for SwiftUI views — the popover row.
//
// §9.6 keeps the buddy peripheral and quiet, so the load-bearing assertions are
// as much about what does NOT change: no notification, no sound, no icon or
// tint change. A broken grader is a tooling fault; the seven §9.1 states each
// mean something about the conversation and none of them means this.
@MainActor
final class GraderStatusSurfaceTests: XCTestCase {

    private func status(
        _ outcome: GraderStatus.Outcome,
        _ reason: GraderStatus.Reason?,
        backend: String = "typesafe"
    ) -> GraderStatus {
        GraderStatus(
            timestamp: "2026-09-20T18:00:00Z",
            phase: .pre,
            turn: 3,
            backend: backend,
            status: outcome,
            reason: reason,
            detail: "The \(backend) backend has no credential."
        )
    }

    // MARK: - Tooltip

    func testTooltipIsUnchangedWhenGradingWorks() {
        XCTAssertEqual(
            StatusItemIcon.toolTip(state: .sleep, graderStatus: nil),
            "ContextBuddy: sleep"
        )
        XCTAssertEqual(
            StatusItemIcon.toolTip(state: .idle, graderStatus: status(.ok, nil)),
            "ContextBuddy: idle"
        )
        XCTAssertEqual(
            StatusItemIcon.toolTip(state: .idle, graderStatus: status(.skipped, .notATask)),
            "ContextBuddy: idle",
            "a declined turn is the grader working, not failing"
        )
    }

    func testTooltipGainsOneLineWhenTheGraderCannotRun() {
        let tip = StatusItemIcon.toolTip(state: .sleep, graderStatus: status(.error, .missingKey))
        XCTAssertEqual(tip.split(separator: "\n").count, 2, "exactly one added line")
        XCTAssertTrue(tip.hasPrefix("ContextBuddy: sleep\n"), "the state line stays first: \(tip)")
        XCTAssertTrue(tip.contains("typesafe"), "the line names the backend: \(tip)")
        XCTAssertTrue(tip.contains("no API key"), "the line names the reason class: \(tip)")
    }

    // A hover tooltip is not available to VoiceOver, so the same sentence has
    // to reach the accessibility label.
    func testAccessibilityLabelCarriesTheSameSentence() {
        XCTAssertEqual(StatusItemIcon.accessibilityLabel(state: .idle, graderStatus: nil), "idle")
        let label = StatusItemIcon.accessibilityLabel(state: .idle, graderStatus: status(.error, .missingKey))
        XCTAssertTrue(label.hasPrefix("idle,"), label)
        XCTAssertTrue(label.contains("grading unavailable"), label)
    }

    // The failure that actually hides: a credential that dies after a healthy
    // session. last.json still holds a good grade and the state is whatever it
    // graded, so the warning has to survive a non-sleep state.
    func testWarningSurvivesAHealthyLookingState() {
        let tip = StatusItemIcon.toolTip(state: .celebrate, graderStatus: status(.error, .transportFailure))
        XCTAssertTrue(tip.hasPrefix("ContextBuddy: celebrate\n"), tip)
        XCTAssertTrue(tip.contains("unreachable"), tip)
    }

    // MARK: - Menu line

    func testMenuItemNamesTheBackendAndReasonAndIsNotClickable() {
        let item = MenubarController.graderStatusMenuItem(for: status(.error, .missingKey))
        XCTAssertFalse(item.isEnabled, "the fix is a credential outside the app; there is nothing to click")
        XCTAssertNil(item.action)
        XCTAssertTrue(item.title.contains("typesafe"), item.title)
        XCTAssertTrue(item.title.contains("no API key"), item.title)
        XCTAssertEqual(item.toolTip, "The typesafe backend has no credential.")
    }

    // MARK: - What must not change (§9.1 / §9.6)

    func testTheGlyphAndTintAreUntouchedByAFailingGrader() {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        StatusItemIcon.apply(state: .idle, animationsEnabled: false, graderStatus: nil, to: button)
        let healthy = StatusItemIcon.imageView(in: button)?.image?.tiffRepresentation

        StatusItemIcon.apply(
            state: .idle,
            animationsEnabled: false,
            graderStatus: status(.error, .missingKey),
            to: button
        )
        let broken = StatusItemIcon.imageView(in: button)?.image?.tiffRepresentation

        XCTAssertNotNil(healthy)
        XCTAssertEqual(healthy, broken, "a grader fault must not repaint the §9.1 icon")
        XCTAssertNotEqual(button.toolTip, "ContextBuddy: idle", "…but it must reach the tooltip")
    }
}
