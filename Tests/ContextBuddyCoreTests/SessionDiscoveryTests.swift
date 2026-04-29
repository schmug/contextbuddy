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
}

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}
