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

    func testProjectHashHashesUnresolvablePathVerbatim() {
        // Neither path exists, so realpath(3) cannot resolve it and the string
        // is hashed verbatim: no normalization, the trailing slash still
        // distinguishes. The plugin's `cd -P && pwd -P` falls back the same
        // way, which is what keeps both sides agreeing on unresolvable input.
        XCTAssertNotEqual(
            SessionDiscovery.projectHash(for: "/x"),
            SessionDiscovery.projectHash(for: "/x/")
        )
    }

    // MARK: - Canonical hashing (issue #4)

    func testProjectHashResolvesSymlinksBeforeHashing() throws {
        // /tmp is a symlink to /private/tmp on every macOS, and Claude Code's
        // hooks see the project cwd in either form depending on entry point.
        // Both must hash to sha256("/private/tmp")[:12]. The plugin's test
        // (Tests/plugin/test_project_hash_canonical.sh) pins the same
        // constant, so the two implementations cannot drift apart without
        // failing one of the two tests. Change both or neither.
        let expected = "11fe14a563f7"
        XCTAssertEqual(SessionDiscovery.projectHash(for: "/private/tmp"), expected)
        XCTAssertEqual(SessionDiscovery.projectHash(for: "/tmp"), expected)

        // A user-made symlink resolves too (Homebrew prefixes, dev-volume mounts).
        let real = root.appendingPathComponent("real")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(
            SessionDiscovery.projectHash(for: link.path),
            SessionDiscovery.projectHash(for: real.path)
        )
        XCTAssertEqual(
            SessionDiscovery.canonicalProjectPath(link.path),
            SessionDiscovery.canonicalProjectPath(real.path)
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
        // An ungraded session still lists (nil lastUpdated, no crash) and takes
        // its place in the MRU order from its directory mtime. Older than the
        // graded session here, so it still sorts last.
        _ = makeSession(named: "withjson", lastJsonAge: 30)
        makeUngradedSession(named: "nojson", directoryAge: 60)
        let discovery = SessionDiscovery(sessionsRoot: root)
        let sessions = discovery.listSessions()
        XCTAssertEqual(sessions.map(\.projectHash), ["withjson", "nojson"])
        XCTAssertNil(sessions.last?.lastUpdated)
        XCTAssertNotNil(sessions.last?.directoryModified)
    }

    func testListSessionsFreshUngradedOutranksStaleGraded() throws {
        // Issue #5 reproducer: a session that has not received its first grade
        // (session.md + empty turns/, no last.json) was created just now; the
        // other project's session was graded a week ago. MRU must resolve to
        // the fresh one, or the menubar watches the wrong project.
        let aWeek: TimeInterval = 604_800
        _ = makeSession(named: "stalegraded_", lastJsonAge: aWeek)
        makeUngradedSession(named: "freshungrade", directoryAge: 5)

        let discovery = SessionDiscovery(sessionsRoot: root)
        XCTAssertEqual(
            discovery.listSessions().map(\.projectHash),
            ["freshungrade", "stalegraded_"]
        )
        XCTAssertEqual(discovery.currentSession(pinnedHash: nil)?.projectHash, "freshungrade")
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
        // Under the temp root, never a host-absolute path: the resolver walks
        // up to the nearest `.git`, so a hard-coded path would name whatever
        // repository this machine keeps above it.
        let path = root.appendingPathComponent("projects/contextbuddy").path
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

    // MARK: - Project name resolves to the git root (issue #42)
    //
    // Fabricated on disk rather than `git init`: the resolver reads the `.git`
    // entry directly and never shells out, so a bare `.git/` directory and a
    // hand-written `.git` pointer file are exactly what it sees in production.

    func testProjectNameIsTheCheckoutNameInAPlainRepo() throws {
        let checkout = root.appendingPathComponent("contextbuddy")
        let nested = checkout.appendingPathComponent("Sources/ContextBuddyCore")
        try FileManager.default.createDirectory(
            at: checkout.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertEqual(SessionDiscovery.projectName(forPath: checkout.path), "contextbuddy")
        XCTAssertEqual(
            SessionDiscovery.projectName(forPath: nested.path),
            "contextbuddy",
            "a cwd below the checkout still names the checkout, not the subdirectory"
        )
    }

    func testProjectNameInAWorktreeIsTheMainCheckoutName() throws {
        // `git worktree add` leaves a one-line `.git` file in the worktree:
        // `gitdir: <main>/.git/worktrees/<name>`. The worktree lives outside
        // the main checkout here so the name can only come from following that
        // pointer, never from the walk reaching <main>/.git by accident.
        let main = root.appendingPathComponent("contextbuddy")
        let worktree = root.appendingPathComponent("elsewhere/objective-cerf-9a0580")
        try FileManager.default.createDirectory(
            at: main.appendingPathComponent(".git/worktrees/objective-cerf-9a0580"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: \(main.path)/.git/worktrees/objective-cerf-9a0580\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(SessionDiscovery.projectName(forPath: worktree.path), "contextbuddy")

        // `git worktree repair --relative-paths` writes the pointer relative to
        // the worktree; that resolves the same way.
        let relative = main.appendingPathComponent(".claude/worktrees/wf-1234")
        try FileManager.default.createDirectory(at: relative, withIntermediateDirectories: true)
        try "gitdir: ../../../.git/worktrees/wf-1234\n".write(
            to: relative.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(SessionDiscovery.projectName(forPath: relative.path), "contextbuddy")
    }

    func testProjectNameFallsBackToLastPathComponentOutsideAnyRepo() throws {
        // No `.git` anywhere above the path: the pre-#42 rule, last component.
        let plain = root.appendingPathComponent("notes/scratch")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertEqual(SessionDiscovery.projectName(forPath: plain.path), "scratch")

        // A `.git` file that is not a worktree pointer names the directory it
        // sits in, same as the fallback, and never crashes the resolver.
        let garbage = root.appendingPathComponent("garbage")
        try FileManager.default.createDirectory(at: garbage, withIntermediateDirectories: true)
        try "not a gitdir pointer".write(
            to: garbage.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(SessionDiscovery.projectName(forPath: garbage.path), "garbage")

        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data().write(to: empty.appendingPathComponent(".git"))
        XCTAssertEqual(SessionDiscovery.projectName(forPath: empty.path), "empty")

        // A path with no repository above it that does not exist on disk
        // keeps the old edge behaviour, trailing slash included. (A deleted
        // project inside a repository still names that repository: the walk
        // only needs the ancestors to exist.)
        let gone = root.appendingPathComponent("gone/contextbuddy")
        XCTAssertEqual(SessionDiscovery.projectName(forPath: gone.path), "contextbuddy")
        XCTAssertEqual(SessionDiscovery.projectName(forPath: gone.path + "/"), "contextbuddy")

        // Degenerate input. `/only` is the one path that cannot move under the
        // temp root: a single component stops the walk before the root, and
        // the result holds unless `/only/.git` is a worktree pointer file.
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

    // A session directory the plugin has laid out but never graded: session.md
    // and an empty turns/, no last.json. The directory mtime is set last, since
    // creating entries inside it would bump it again.
    private func makeUngradedSession(named hash: String, directoryAge: TimeInterval) {
        let dir = root.appendingPathComponent(hash)
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("turns"),
            withIntermediateDirectories: true
        )
        try? "# session".write(
            to: dir.appendingPathComponent("session.md"),
            atomically: true,
            encoding: .utf8
        )
        let when = Date().addingTimeInterval(-directoryAge)
        try? FileManager.default.setAttributes(
            [.modificationDate: when],
            ofItemAtPath: dir.path
        )
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
