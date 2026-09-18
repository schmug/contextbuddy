import XCTest
@testable import ContextBuddyCore

final class SessionDiscoveryTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctxbuddy-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    // MARK: - projectHash

    func testProjectHashIsDeterministic() {
        let h1 = SessionDiscovery.projectHash(for: "/Users/cory/dev/contextbuddy")
        let h2 = SessionDiscovery.projectHash(for: "/Users/cory/dev/contextbuddy")
        XCTAssertEqual(h1, h2)
    }

    func testProjectHashIs12HexChars() {
        let hash = SessionDiscovery.projectHash(for: "/abs/path")
        XCTAssertEqual(hash.count, 12)
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit })
    }

    func testProjectHashDistinctPathsDistinctHashes() {
        // Sample 100 random absolute-style paths; ensure no collision in this batch.
        var seen: Set<String> = []
        for i in 0..<100 {
            let path = "/abs/path/\(UUID().uuidString)/\(i)"
            let h = SessionDiscovery.projectHash(for: path)
            XCTAssertFalse(seen.contains(h), "collision on \(path)")
            seen.insert(h)
        }
    }

    func testProjectHashDifferentForCanonicalEdgeCases() {
        // Trailing slash should produce a different hash. Plugin hashes
        // exactly $PWD; consistency between hooks and tests means we must
        // not normalize.
        XCTAssertNotEqual(
            SessionDiscovery.projectHash(for: "/x"),
            SessionDiscovery.projectHash(for: "/x/")
        )
    }

    // MARK: - MRU listing

    func testListSessionsSortsByLastJsonMtimeDescending() throws {
        let h1 = makeSession(named: "aaaaaaaaaaaa", lastJsonAge: 100)
        let h2 = makeSession(named: "bbbbbbbbbbbb", lastJsonAge: 50)
        let h3 = makeSession(named: "cccccccccccc", lastJsonAge: 200)

        let discovery = SessionDiscovery(sessionsRoot: root)
        let sessions = discovery.listSessions()
        XCTAssertEqual(sessions.map(\.projectHash), [h2, h1, h3])
    }

    func testListSessionsHandlesMissingLastJson() throws {
        _ = makeSession(named: "withjson", lastJsonAge: 30)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("nojson"),
            withIntermediateDirectories: true
        )
        let discovery = SessionDiscovery(sessionsRoot: root)
        let sessions = discovery.listSessions()
        XCTAssertEqual(sessions.first?.projectHash, "withjson")
        XCTAssertEqual(sessions.last?.projectHash, "nojson")
        XCTAssertNil(sessions.last?.lastUpdated)
    }

    func testListSessionsEmptyRootReturnsEmpty() {
        let discovery = SessionDiscovery(sessionsRoot: root)
        XCTAssertTrue(discovery.listSessions().isEmpty)
    }

    func testListSessionsNonExistentRootReturnsEmpty() {
        let nonexistent = root.appendingPathComponent("does-not-exist")
        let discovery = SessionDiscovery(sessionsRoot: nonexistent)
        XCTAssertTrue(discovery.listSessions().isEmpty)
    }

    // MARK: - Project metadata (meta.json, issue #38)
    //
    // The hash is one-way, so the popover's project footer row can only name a
    // project when the plugin recorded the absolute path. These pin both halves
    // of that contract: the name resolves when meta.json is there, and every
    // accessor degrades to nil (never a crash) when it is not.

    func testSessionRefResolvesProjectPathAndNameFromMetaJson() throws {
        let path = "/Users/cory/dev/contextbuddy"
        let hash = SessionDiscovery.projectHash(for: path)
        makeSession(named: hash, lastJsonAge: 10)
        writeMeta(hash: hash, projectPath: path)

        let session = SessionDiscovery(sessionsRoot: root).listSessions().first
        XCTAssertEqual(session?.projectPath, path)
        XCTAssertEqual(session?.projectName, "contextbuddy")
    }

    func testRecordedProjectPathHashesBackToItsDirectoryName() throws {
        // The whole point of recording the path: it must agree with the hash
        // the directory is named after, or the footer row names the wrong repo.
        let path = "/Users/cory/dev/some other project"
        let hash = SessionDiscovery.projectHash(for: path)
        makeSession(named: hash, lastJsonAge: 10)
        writeMeta(hash: hash, projectPath: path)

        let session = SessionDiscovery(sessionsRoot: root).listSessions().first
        let recorded = try XCTUnwrap(session?.projectPath)
        XCTAssertEqual(SessionDiscovery.projectHash(for: recorded), session?.projectHash)
    }

    func testSessionRefFallsBackToNilWhenMetaJsonAbsent() throws {
        // Session dirs created before meta.json existed. Fallback, not a crash.
        makeSession(named: "abcabcabcabc", lastJsonAge: 10)
        let session = SessionDiscovery(sessionsRoot: root).listSessions().first
        XCTAssertEqual(session?.projectHash, "abcabcabcabc")
        XCTAssertNil(session?.projectPath)
        XCTAssertNil(session?.projectName)
    }

    func testSessionRefIgnoresMalformedMetaJson() throws {
        let hash = "deadbeefdead"
        makeSession(named: hash, lastJsonAge: 10)
        try "not json at all".write(
            to: root.appendingPathComponent(hash).appendingPathComponent("meta.json"),
            atomically: true,
            encoding: .utf8
        )
        let session = SessionDiscovery(sessionsRoot: root).listSessions().first
        XCTAssertNil(session?.projectPath)
        XCTAssertNil(session?.projectName)
    }

    func testProjectNameIsLastPathComponent() {
        XCTAssertEqual(SessionDiscovery.projectName(forPath: "/a/b/contextbuddy"), "contextbuddy")
        XCTAssertEqual(SessionDiscovery.projectName(forPath: "/a/b/contextbuddy/"), "contextbuddy")
        XCTAssertEqual(SessionDiscovery.projectName(forPath: "/only"), "only")
        XCTAssertNil(SessionDiscovery.projectName(forPath: ""))
        XCTAssertNil(SessionDiscovery.projectName(forPath: "/"))
    }

    // MARK: - Pinning

    func testCurrentSessionPrefersPinned() throws {
        _ = makeSession(named: "newest______", lastJsonAge: 10)
        _ = makeSession(named: "older_______", lastJsonAge: 100)

        let discovery = SessionDiscovery(sessionsRoot: root)
        XCTAssertEqual(discovery.currentSession(pinnedHash: nil)?.projectHash, "newest______")
        XCTAssertEqual(
            discovery.currentSession(pinnedHash: "older_______")?.projectHash,
            "older_______"
        )
    }

    func testCurrentSessionFallsBackToMRUWhenPinnedHashNotFound() throws {
        _ = makeSession(named: "abcabcabcabc", lastJsonAge: 5)
        let discovery = SessionDiscovery(sessionsRoot: root)
        XCTAssertEqual(
            discovery.currentSession(pinnedHash: "doesnotexist")?.projectHash,
            "abcabcabcabc"
        )
    }

    // MARK: - Helpers

    @discardableResult
    private func makeSession(named hash: String, lastJsonAge: TimeInterval) -> String {
        let dir = root.appendingPathComponent(hash)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lastJson = dir.appendingPathComponent("last.json")
        try? "{}".write(to: lastJson, atomically: true, encoding: .utf8)
        let when = Date().addingTimeInterval(-lastJsonAge)
        try? FileManager.default.setAttributes(
            [.modificationDate: when],
            ofItemAtPath: lastJson.path
        )
        return hash
    }

    private func writeMeta(hash: String, projectPath: String) {
        let dir = root.appendingPathComponent(hash)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoded = String(
            data: try! JSONSerialization.data(
                withJSONObject: ["schema_version": 1, "project_path": projectPath]
            ),
            encoding: .utf8
        )!
        try? encoded.write(
            to: dir.appendingPathComponent("meta.json"),
            atomically: true,
            encoding: .utf8
        )
    }
}

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}
