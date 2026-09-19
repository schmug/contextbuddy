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

    // The popover colours each score meter by its distance from that
    // dimension's own attention threshold, so the thresholds have to reach the
    // view. `config` is private to the actor; Snapshot is the only channel.
    func testSnapshotCarriesDefaultThresholds() async throws {
        let core = try await BuddyCore(inspectorRoot: inspectorRoot)
        let snap = await core.currentSnapshot()
        XCTAssertEqual(snap.thresholds, Config.defaults.thresholds)
    }

    func testSnapshotCarriesThresholdsFromConfigFile() async throws {
        try """
        [thresholds]
        confidence_attention = 9
        pollution_attention = 2
        """.write(
            to: inspectorRoot.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let core = try await BuddyCore(inspectorRoot: inspectorRoot)
        let snap = await core.currentSnapshot()
        XCTAssertEqual(snap.thresholds.confidenceAttention, 9)
        XCTAssertEqual(snap.thresholds.pollutionAttention, 2)
        XCTAssertEqual(snap.thresholds.driftAttention, Config.defaults.thresholds.driftAttention,
                       "unset keys keep their compiled-in default")
    }

    // `[ui]` takes the same route as the thresholds (#36): the controller's
    // icon and popover read it from Snapshot, so both keys have to survive
    // the trip from config.toml through the actor.
    func testSnapshotCarriesUIFromConfigFile() async throws {
        let core = try await BuddyCore(inspectorRoot: inspectorRoot)
        let unconfigured = await core.currentSnapshot()
        XCTAssertEqual(unconfigured.ui, Config.defaults.ui, "no file: compiled-in defaults")

        try writeConfig("""
        [ui]
        animations_enabled = false
        token_row_pct = 10
        """)
        let configured = try await BuddyCore(inspectorRoot: inspectorRoot)
        let snap = await configured.currentSnapshot()
        XCTAssertFalse(snap.ui.animationsEnabled)
        XCTAssertEqual(snap.ui.tokenRowPct, 10)
    }

    // Acceptance for #36's "without restarting the app". reloadConfigIfChanged()
    // used to run on the watcher path only, so a `[ui]` edit with no grade in
    // flight sat unread indefinitely. The tick now checks the file too, and a
    // config-only change (state stays .sleep throughout) still reaches the
    // subscriber: the popover and icon re-render on snapshots, nothing else.
    func testSleepTickPicksUpAConfigEditAndBroadcastsIt() async throws {
        let core = try await BuddyCore(inspectorRoot: inspectorRoot)
        let stream = await core.subscribe()
        let bootstrap = await core.currentSnapshot()
        XCTAssertTrue(bootstrap.ui.animationsEnabled, "defaults until the file exists")

        try writeConfig("""
        [ui]
        animations_enabled = false
        token_row_pct = 10
        """, mtimeAge: 200)
        await core.runSleepTick()
        // firstSnapshot, not nextSnapshot: its timeout is real, so a tick that
        // never broadcasts fails here instead of hanging the suite. The
        // bootstrap snapshot the stream opened with still carries the
        // defaults and is skipped by the predicate.
        let disabled = try await firstSnapshot(
            matching: { !$0.ui.animationsEnabled }, from: stream, within: 1.0
        )
        XCTAssertEqual(disabled.ui.tokenRowPct, 10, "the tick reloaded the edited file")
        XCTAssertEqual(disabled.state, .sleep, "a config-only change broadcasts without a state change")

        // Setting it back restores motion. A distinct mtime is what the reload
        // keys on, so the second edit is dated apart from the first. Read
        // through currentSnapshot(): firstSnapshot's timeout cancels the
        // stream, and re-subscribing races the actor's onTermination cleanup.
        try writeConfig("""
        [ui]
        animations_enabled = true
        """, mtimeAge: 100)
        await core.runSleepTick()
        let restored = await core.currentSnapshot()
        XCTAssertTrue(restored.ui.animationsEnabled)
        XCTAssertEqual(restored.ui.tokenRowPct, Config.defaults.ui.tokenRowPct,
                       "a key dropped from the file falls back to its default, not the previous value")
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

    func testSnapshotCarriesProjectNameFromMetaJson() async throws {
        // The popover's project footer row reads Snapshot, so the name has to
        // survive the trip from the session dir through BuddyCore (issue #38).
        // Under the temp root, never a host-absolute path: the resolver walks
        // up to the nearest `.git`, so a hard-coded path would name whatever
        // repository this machine keeps above it.
        let path = inspectorRoot.appendingPathComponent("projects/contextbuddy").path
        let hash = SessionDiscovery.projectHash(for: path)
        try writeFixtureGrade(hash: hash, fixture: "example2_post_turn22")
        try writeMeta(hash: hash, projectPath: path)

        let core = try await BuddyCore(inspectorRoot: inspectorRoot)
        let snap = await core.currentSnapshot()
        XCTAssertEqual(snap.projectPath, path)
        XCTAssertEqual(snap.projectName, "contextbuddy")
    }

    func testPinningAnotherSessionSwitchesTheProjectName() async throws {
        // Acceptance for issue #38: the footer row must follow the active
        // session, not stay on whichever one the popover opened with.
        let mruPath = inspectorRoot.appendingPathComponent("projects/dmarcheck").path
        let pinnedPath = inspectorRoot.appendingPathComponent("projects/contextbuddy").path
        let mruHash = SessionDiscovery.projectHash(for: mruPath)
        let pinnedHash = SessionDiscovery.projectHash(for: pinnedPath)
        try writeFixtureGrade(hash: mruHash, fixture: "example1_pre_turn14", mtimeAge: 5)
        try writeFixtureGrade(hash: pinnedHash, fixture: "example2_post_turn22", mtimeAge: 100)
        try writeMeta(hash: mruHash, projectPath: mruPath)
        try writeMeta(hash: pinnedHash, projectPath: pinnedPath)

        let core = try await BuddyCore(inspectorRoot: inspectorRoot)
        var snap = await core.currentSnapshot()
        XCTAssertEqual(snap.projectName, "dmarcheck", "MRU names its own project")

        await core.pinSession(pinnedHash)
        snap = await core.currentSnapshot()
        XCTAssertEqual(snap.projectName, "contextbuddy", "pin switches the named project")

        await core.pinSession(nil)
        snap = await core.currentSnapshot()
        XCTAssertEqual(snap.projectName, "dmarcheck", "unpin snaps back to the MRU's project")
    }

    func testSnapshotProjectNameIsTheRepoRootResolvedOncePerSessionHash() async throws {
        // Issue #42 at the Core level. The recorded path sits two levels below
        // a fabricated checkout, so the name can only come from the walk up to
        // `.git`. Deleting `.git` between two snapshots then pins the hard
        // constraint: the walk runs once per session hash, and a later
        // snapshot reports the cached name without touching the filesystem.
        // Without the cache the second snapshot would walk again, find no
        // repository, and fall back to "ContextBuddyCore".
        let checkout = inspectorRoot.appendingPathComponent("repos/contextbuddy")
        let gitDirectory = checkout.appendingPathComponent(".git")
        let recorded = checkout.appendingPathComponent("Sources/ContextBuddyCore")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recorded, withIntermediateDirectories: true)
        let hash = SessionDiscovery.projectHash(for: recorded.path)
        try writeFixtureGrade(hash: hash, fixture: "example2_post_turn22")
        try writeMeta(hash: hash, projectPath: recorded.path)

        let core = try await BuddyCore(inspectorRoot: inspectorRoot)
        var snap = await core.currentSnapshot()
        XCTAssertEqual(snap.projectName, "contextbuddy", "the git root names the project, not the cwd")

        try FileManager.default.removeItem(at: gitDirectory)
        snap = await core.currentSnapshot()
        XCTAssertEqual(
            snap.projectName,
            "contextbuddy",
            "resolved once per session hash: a later snapshot never walks the filesystem again"
        )
    }

    func testSnapshotProjectNameIsNilWithoutMetaJson() async throws {
        let hash = "eeeeeeeeeeee"
        try writeFixtureGrade(hash: hash, fixture: "example2_post_turn22")
        let core = try await BuddyCore(inspectorRoot: inspectorRoot)
        let snap = await core.currentSnapshot()
        XCTAssertEqual(snap.projectHash, hash)
        XCTAssertNil(snap.projectPath)
        XCTAssertNil(snap.projectName)
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

    // Writes config.toml under the temp root. `mtimeAge` dates the file that
    // many seconds in the past: BuddyCore.reloadConfigIfChanged keys on the
    // mtime, and two writes within one test can otherwise land too close
    // together to read as a change.
    private func writeConfig(_ toml: String, mtimeAge: TimeInterval? = nil) throws {
        let url = inspectorRoot.appendingPathComponent("config.toml")
        try toml.write(to: url, atomically: true, encoding: .utf8)
        if let age = mtimeAge {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)],
                ofItemAtPath: url.path
            )
        }
    }

    private func writeMeta(hash: String, projectPath: String) throws {
        let dir = inspectorRoot.appendingPathComponent("sessions/\(hash)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: ["schema_version": 1, "project_path": projectPath]
        )
        try data.write(to: dir.appendingPathComponent("meta.json"))
    }

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
