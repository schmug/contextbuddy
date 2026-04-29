import XCTest
@testable import ContextBuddyCore

final class CoreTests: XCTestCase {
    private var inspectorRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        inspectorRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctxbuddy-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: inspectorRoot.appendingPathComponent("sessions"),
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: inspectorRoot)
        try await super.tearDown()
    }

    func testBootstrapEmptyInspectorReturnsSleep() async throws {
        let core = try await BuddyCore(inspectorRoot: inspectorRoot)
        let snap = await core.currentSnapshot()
        XCTAssertEqual(snap.state, .sleep)
        XCTAssertNil(snap.projectHash)
        XCTAssertNil(snap.lastGrade)
    }

    func testBootstrapFromExistingLastJsonFromDisk() async throws {
        let hash = "aaaaaaaaaaaa"
        try writeFixtureGrade(hash: hash, fixture: "example2_post_turn22")
        let core = try await BuddyCore(inspectorRoot: inspectorRoot)
        let snap = await core.currentSnapshot()
        XCTAssertEqual(snap.projectHash, hash)
        XCTAssertEqual(snap.lastGrade?.turn, 22)
        XCTAssertEqual(snap.state, .idle, "celebrate-eligible grade with no prior history → idle")
    }

    func testWatcherEventTransitionsToAttention() async throws {
        let core = try await BuddyCore(inspectorRoot: inspectorRoot)
        let stream = await core.subscribe()
        await core.start()
        defer { Task { await core.stop() } }

        // FSEvents needs a beat to attach.
        try await Task.sleep(nanoseconds: 150_000_000)

        let hash = "bbbbbbbbbbbb"
        try writeFixtureGrade(hash: hash, fixture: "example1_pre_turn14")

        let snap = try await firstSnapshot(matching: { $0.state == .attention }, from: stream, within: 5.0)
        XCTAssertEqual(snap.state, .attention)
        XCTAssertEqual(snap.lastGrade?.turn, 14)
    }

    func testRecordFeedbackTriggersHeart() async throws {
        // Seed a grade so currentHash is set.
        let hash = "ccccccccccdd"
        try writeFixtureGrade(hash: hash, fixture: "example2_post_turn22")
        let core = try await BuddyCore(inspectorRoot: inspectorRoot)
        let stream = await core.subscribe()

        // Drain the bootstrap snapshot.
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()

        await core.recordFeedback(action: .ack, signal: .atomicity)

        let snap = try await nextSnapshot(from: &iterator, within: 1.0)
        XCTAssertEqual(snap.state, .heart)

        // Verify feedback persisted to feedback.jsonl.
        let url = inspectorRoot.appendingPathComponent("sessions/\(hash)/feedback.jsonl")
        let data = try Data(contentsOf: url)
        let line = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(line.contains("\"action\":\"ack\""))
        XCTAssertTrue(line.contains("\"signal\":\"atomicity\""))
    }

    func testPinSessionOverridesMRU() async throws {
        try writeFixtureGrade(hash: "olderolderold", fixture: "example2_post_turn22", mtimeAge: 100)
        try writeFixtureGrade(hash: "newernewerne", fixture: "example1_pre_turn14", mtimeAge: 5)

        let core = try await BuddyCore(inspectorRoot: inspectorRoot)
        var snap = await core.currentSnapshot()
        XCTAssertEqual(snap.projectHash, "newernewerne", "default MRU is newer")

        await core.pinSession("olderolderold")
        snap = await core.currentSnapshot()
        XCTAssertEqual(snap.projectHash, "olderolderold")
        XCTAssertEqual(snap.pinnedHash, "olderolderold")
    }

    // MARK: helpers

    private func writeFixtureGrade(
        hash: String,
        fixture: String,
        mtimeAge: TimeInterval? = nil
    ) throws {
        let dir = inspectorRoot.appendingPathComponent("sessions/\(hash)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("last.json")
        guard let src = Bundle.module.url(
            forResource: fixture,
            withExtension: "json",
            subdirectory: "Fixtures"
        ) else {
            XCTFail("missing fixture \(fixture)")
            return
        }
        let data = try Data(contentsOf: src)
        try data.write(to: target)
        if let age = mtimeAge {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)],
                ofItemAtPath: target.path
            )
        }
    }

    private func firstSnapshot(
        matching predicate: @Sendable @escaping (BuddyCore.Snapshot) -> Bool,
        from stream: AsyncStream<BuddyCore.Snapshot>,
        within timeout: TimeInterval
    ) async throws -> BuddyCore.Snapshot {
        try await withThrowingTaskGroup(of: BuddyCore.Snapshot.self) { group in
            group.addTask {
                for await snap in stream where predicate(snap) {
                    return snap
                }
                throw CoreTestTimeout()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CoreTestTimeout()
            }
            guard let first = try await group.next() else { throw CoreTestTimeout() }
            group.cancelAll()
            return first
        }
    }

    private func nextSnapshot(
        from iterator: inout AsyncStream<BuddyCore.Snapshot>.AsyncIterator,
        within timeout: TimeInterval
    ) async throws -> BuddyCore.Snapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snap = await iterator.next() { return snap }
        }
        throw CoreTestTimeout()
    }
}

private struct CoreTestTimeout: Error {}
