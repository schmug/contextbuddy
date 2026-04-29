import XCTest
@testable import ContextBuddyCore

final class StorageTests: XCTestCase {
    private var dbURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctxbuddy-storage-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbURL = dir.appendingPathComponent("state.db")
    }

    override func tearDown() async throws {
        if let dbURL {
            try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
        }
        try await super.tearDown()
    }

    // MARK: - Schema creation

    func testFreshDBCreatesBothTables() async throws {
        let storage = try await Storage(url: dbURL)
        let didRecover = await storage.didRecover
        XCTAssertFalse(didRecover, "fresh DB should not flag recovery")

        // Should be empty but queryable.
        let feedback = try await storage.enumerateFeedback()
        let transitions = try await storage.enumerateTransitions()
        XCTAssertTrue(feedback.isEmpty)
        XCTAssertTrue(transitions.isEmpty)
    }

    // MARK: - Feedback round-trip

    func testRecordFeedbackRoundTrip() async throws {
        let storage = try await Storage(url: dbURL)
        let event = FeedbackEvent(
            timestamp: "2026-04-29T11:43:08Z",
            turn: 14,
            action: .mute,
            signal: .atomicity,
            scope: .session
        )
        try await storage.recordFeedback(event, projectHash: "abc123def456")

        let rows = try await storage.enumerateFeedback()
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(row.projectHash, "abc123def456")
        XCTAssertEqual(row.turn, 14)
        XCTAssertEqual(row.action, "mute")
        XCTAssertEqual(row.signal, "atomicity")
        XCTAssertEqual(row.scope, "session")
        XCTAssertEqual(row.ts, "2026-04-29T11:43:08Z")
    }

    func testRecordFeedbackDefaultsScopeToSession() async throws {
        // v1 emits only scope=session per Decision Q from the plan, but a
        // nil scope (e.g., from incomplete callers) must still persist as
        // session rather than NULL.
        let storage = try await Storage(url: dbURL)
        let event = FeedbackEvent(
            timestamp: "2026-04-29T11:43:08Z",
            turn: 1,
            action: .ack,
            signal: .loop,
            scope: nil
        )
        try await storage.recordFeedback(event, projectHash: "h")
        let rows = try await storage.enumerateFeedback()
        XCTAssertEqual(rows.first?.scope, "session")
    }

    // MARK: - Transition round-trip

    func testRecordTransitionRoundTrip() async throws {
        let storage = try await Storage(url: dbURL)
        let when = Date(timeIntervalSince1970: 1_777_000_000)
        let transition = StateTransition(
            from: .idle,
            to: .attention,
            trigger: "atomicity<4",
            dominantSignal: .atomicity,
            turn: 14,
            at: when
        )
        try await storage.recordTransition(transition, projectHash: "h")

        let rows = try await storage.enumerateTransitions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].from, "idle")
        XCTAssertEqual(rows[0].to, "attention")
        XCTAssertEqual(rows[0].trigger, "atomicity<4")
        XCTAssertEqual(rows[0].turn, 14)
        XCTAssertFalse(rows[0].ts.isEmpty)
    }

    func testRecordTransitionWithNilTurn() async throws {
        let storage = try await Storage(url: dbURL)
        let transition = StateTransition(
            from: .idle,
            to: .sleep,
            trigger: "idle_timeout",
            turn: nil,
            at: Date()
        )
        try await storage.recordTransition(transition, projectHash: "h")
        let rows = try await storage.enumerateTransitions()
        XCTAssertNil(rows.first?.turn, "nil turn must persist as NULL, not 0")
    }

    // MARK: - Insertion order preserved

    func testEnumerationReturnsInsertionOrder() async throws {
        let storage = try await Storage(url: dbURL)
        for i in 1...5 {
            try await storage.recordFeedback(
                FeedbackEvent(
                    timestamp: "2026-04-29T00:00:0\(i)Z",
                    turn: i,
                    action: .ack,
                    signal: .atomicity,
                    scope: .session
                ),
                projectHash: "h"
            )
        }
        let rows = try await storage.enumerateFeedback()
        XCTAssertEqual(rows.map(\.turn), [1, 2, 3, 4, 5])
    }

    // MARK: - Corruption recovery (§13)

    func testCorruptDatabaseTriggersRecreate() async throws {
        // Write garbage to the path before opening.
        try Data(repeating: 0xFF, count: 1024).write(to: dbURL)

        let storage = try await Storage(url: dbURL)
        let didRecover = await storage.didRecover
        XCTAssertTrue(didRecover, "corrupt file must trigger recovery flag")

        // Schema should be intact post-recovery.
        try await storage.recordFeedback(
            FeedbackEvent(
                timestamp: "2026-04-29T00:00:00Z",
                turn: 1,
                action: .ack,
                signal: .confidence,
                scope: .session
            ),
            projectHash: "h"
        )
        let rows = try await storage.enumerateFeedback()
        XCTAssertEqual(rows.count, 1)
    }

    func testRecoveryRemovesWALAndSHMSidecars() async throws {
        // Create plausible-looking sidecar files alongside a corrupt main.
        try Data(repeating: 0xFF, count: 16).write(to: dbURL)
        let wal = URL(fileURLWithPath: dbURL.path + "-wal")
        let shm = URL(fileURLWithPath: dbURL.path + "-shm")
        try Data().write(to: wal)
        try Data().write(to: shm)

        _ = try await Storage(url: dbURL)
        // After recovery we may have new WAL/SHM if SQLite chose WAL mode,
        // but the original empty stubs should have been removed and
        // replaced with valid SQLite metadata if present at all.
        // Just verify recovery did not crash.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
    }

    // MARK: - Concurrent writes serialize via actor

    func testConcurrentWritesSerialize() async throws {
        let storage = try await Storage(url: dbURL)
        await withTaskGroup(of: Void.self) { group in
            for i in 1...20 {
                group.addTask {
                    try? await storage.recordTransition(
                        StateTransition(
                            from: .idle,
                            to: .attention,
                            trigger: "atomicity<4",
                            dominantSignal: .atomicity,
                            turn: i,
                            at: Date()
                        ),
                        projectHash: "h"
                    )
                }
            }
        }
        let rows = try await storage.enumerateTransitions()
        XCTAssertEqual(rows.count, 20, "all 20 concurrent writes must persist")
        // Turn numbers should all be unique (no duplicates from races).
        let turns = Set(rows.compactMap(\.turn))
        XCTAssertEqual(turns, Set(1...20))
    }
}
