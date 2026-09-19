import AppKit
import XCTest
import ContextBuddyCore
@testable import ContextBuddyApp

// Coverage for the §9.4 "Recent sessions" submenu titling rule (#39, #41).
//
// The submenu exists to choose a session, and a 12-hex digest cannot be chosen
// by inspection. Each item is titled by project name, resolved through
// SessionRef.projectName — the same git-root resolver as the popover footer
// row (§9.3) — and falls back to the hash prefix when the session dir predates
// meta.json. The hash never leaves representedObject: pinning
// (menuPinSession → BuddyCore.pinSession) and the checkmark both key on it.
//
// Session dirs are laid out for real under a temp root and go through
// SessionDiscovery.listSessions(), so the meta.json read is the production
// one. Project paths stay under the temp root: the name resolver walks up to
// the nearest `.git`, and a host-absolute path would name whatever repository
// this machine keeps above it.
//
// No setUp/tearDown override: on Swift 6.1 that override inherits XCTestCase's
// nonisolated context rather than this class's @MainActor annotation, so the
// temp root is scoped per test with `withSessionsRoot` instead.
@MainActor
final class RecentSessionsMenuTests: XCTestCase {

    func testItemsAreTitledByProjectNameAndFallBackToTheHashPrefix() throws {
        try withSessionsRoot { root in
            let named = makeSession(
                in: root, projectPath: root.appendingPathComponent("work/contextbuddy").path, lastJsonAge: 10
            )
            // A session dir from before the hook wrote meta.json: still listed,
            // titled by its hash prefix exactly as the popover footer does.
            let bare = makeSession(in: root, hash: "abcdef123456", projectPath: nil, lastJsonAge: 20)

            let sessions = Array(SessionDiscovery(sessionsRoot: root).listSessions().prefix(5))
            let items = MenubarController.recentSessionItems(for: sessions, pinnedHash: nil)

            XCTAssertEqual(items.map(\.title), ["contextbuddy", "abcdef…"])
            XCTAssertEqual(items.map { $0.representedObject as? String }, [named, bare])
            XCTAssertFalse(items.contains { $0.title.isEmpty }, "a session must never render as a blank row")
        }
    }

    func testPinnedItemIsCheckedByHashAndKeepsTheHashAsRepresentedObject() throws {
        try withSessionsRoot { root in
            let current = makeSession(
                in: root, projectPath: root.appendingPathComponent("work/current").path, lastJsonAge: 10
            )
            let pinned = makeSession(in: root, hash: "0123456789ab", projectPath: nil, lastJsonAge: 20)

            let sessions = Array(SessionDiscovery(sessionsRoot: root).listSessions().prefix(5))
            let items = MenubarController.recentSessionItems(for: sessions, pinnedHash: pinned)

            XCTAssertEqual(items.map(\.state), [.off, .on])
            // The pin target is the hash, whatever the row is titled: a name is
            // neither unique nor known for every session.
            XCTAssertEqual(items[1].representedObject as? String, pinned)
            XCTAssertEqual(items[0].representedObject as? String, current)
        }
    }

    func testSessionsThatResolveToTheSameNameStayDistinguishable() throws {
        try withSessionsRoot { root in
            // ~/work/api and ~/side/api: distinct projects, one last path
            // component. Each row keeps its name and gains its own hash prefix.
            let work = makeSession(in: root, projectPath: root.appendingPathComponent("work/api").path, lastJsonAge: 10)
            let side = makeSession(in: root, projectPath: root.appendingPathComponent("side/api").path, lastJsonAge: 20)
            let docs = makeSession(in: root, projectPath: root.appendingPathComponent("work/docs").path, lastJsonAge: 30)

            let sessions = Array(SessionDiscovery(sessionsRoot: root).listSessions().prefix(5))
            let items = MenubarController.recentSessionItems(for: sessions, pinnedHash: nil)

            XCTAssertEqual(
                items.map(\.title),
                ["api (\(work.prefix(6)))", "api (\(side.prefix(6)))", "docs"]
            )
            XCTAssertEqual(Set(items.map(\.title)).count, items.count, "every visible row must be distinct")
            XCTAssertEqual(items.map { $0.representedObject as? String }, [work, side, docs])
        }
    }

    // MARK: - Fixtures

    private func withSessionsRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctxbuddy-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    // Lays out `sessions/<hash>/` with a last.json aged `lastJsonAge` seconds
    // (listSessions orders on it) and, when a project path is given, the
    // meta.json the plugin hook writes (SPEC.md §4.9). Returns the hash, which
    // is sha256 of the path when there is one.
    @discardableResult
    private func makeSession(
        in root: URL,
        hash explicitHash: String? = nil,
        projectPath: String?,
        lastJsonAge: TimeInterval
    ) -> String {
        let hash = explicitHash ?? SessionDiscovery.projectHash(for: projectPath ?? "")
        let dir = root.appendingPathComponent(hash)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lastJson = dir.appendingPathComponent("last.json")
        try? "{}".write(to: lastJson, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-lastJsonAge)],
            ofItemAtPath: lastJson.path
        )
        if let projectPath {
            let encoded = String(
                data: try! JSONSerialization.data(
                    withJSONObject: ["schema_version": 1, "project_path": projectPath]
                ),
                encoding: .utf8
            )!
            try? encoded.write(to: dir.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        }
        return hash
    }
}
