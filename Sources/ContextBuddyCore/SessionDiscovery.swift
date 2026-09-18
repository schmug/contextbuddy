import Foundation
import CryptoKit

// MARK: - SessionDiscovery
//
// Per §2: the buddy watches `~/.claude/inspector/sessions/` and the plugin
// writes to `sessions/<project-hash>/`. Project hash is the first 12 hex
// chars of sha256(absolute_project_path). This module owns:
//   - the hash function
//   - listing sessions by MRU (most-recent last.json mtime)
//   - resolving "current" session (MRU unless explicitly pinned)

public struct SessionRef: Equatable, Sendable {
    public let projectHash: String
    public let directory: URL
    public let lastUpdated: Date?
    // Absolute project path from meta.json (§4.9). nil for session dirs the
    // plugin wrote before meta.json existed — the hash is one-way, so there is
    // nothing to fall back on but the hash itself.
    public let projectPath: String?

    public init(
        projectHash: String,
        directory: URL,
        lastUpdated: Date?,
        projectPath: String? = nil
    ) {
        self.projectHash = projectHash
        self.directory = directory
        self.lastUpdated = lastUpdated
        self.projectPath = projectPath
    }

    // Display name for the popover's project footer row.
    public var projectName: String? {
        projectPath.flatMap { SessionDiscovery.projectName(forPath: $0) }
    }
}

// meta.json — project identity for a session dir, written by the plugin hooks
// (SPEC.md §4.9). Deliberately separate from Grade/last.json: project identity
// is session metadata, not a graded score, and it must be correct from turn one
// rather than only after the first successful grade.
struct SessionMeta: Decodable {
    let projectPath: String

    enum CodingKeys: String, CodingKey {
        case projectPath = "project_path"
    }
}

public struct SessionDiscovery: Sendable {
    public let sessionsRoot: URL

    public init(sessionsRoot: URL) {
        self.sessionsRoot = sessionsRoot
    }

    // sha256(absolute_path)[:12] per §2.
    public static func projectHash(for absolutePath: String) -> String {
        let data = Data(absolutePath.utf8)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    // Read the recorded project path out of a session directory's meta.json.
    // Returns nil when the file is absent or unreadable — every caller falls
    // back to the project hash rather than showing nothing.
    public static func projectPath(inSessionDirectory directory: URL) -> String? {
        let meta = directory.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: meta),
              let decoded = try? JSONDecoder().decode(SessionMeta.self, from: data),
              !decoded.projectPath.isEmpty
        else { return nil }
        return decoded.projectPath
    }

    // Last path component of an absolute project path, e.g. "contextbuddy".
    // Deliberately not the full path: it would leak /Users/<username>/… into a
    // screenshot-able UI and would not fit the 320pt popover.
    //
    // Deliberately not smarter than the last component either. In a git worktree
    // this yields the worktree directory name (e.g. "objective-cerf-9a0580"),
    // not the repo name — walking up to the git root is a follow-up, not this.
    public static func projectName(forPath path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        return name
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/inspector/sessions", isDirectory: true)
    }

    // List all session directories with their last.json mtime (nil if absent).
    // Sorted descending by lastUpdated; sessions with no last.json sort last.
    public func listSessions() -> [SessionRef] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let refs: [SessionRef] = entries.compactMap { entry in
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { return nil }
            let hash = entry.lastPathComponent
            let lastJson = entry.appendingPathComponent("last.json")
            let mtime = (try? lastJson.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            return SessionRef(
                projectHash: hash,
                directory: entry,
                lastUpdated: mtime,
                projectPath: Self.projectPath(inSessionDirectory: entry)
            )
        }
        return refs.sorted { lhs, rhs in
            switch (lhs.lastUpdated, rhs.lastUpdated) {
            case let (l?, r?): return l > r
            case (nil, nil): return lhs.projectHash < rhs.projectHash
            case (nil, _): return false
            case (_, nil): return true
            }
        }
    }

    // Resolve "current" session per §2: MRU unless explicitly pinned.
    public func currentSession(pinnedHash: String?) -> SessionRef? {
        let all = listSessions()
        if let pinnedHash, let pinned = all.first(where: { $0.projectHash == pinnedHash }) {
            return pinned
        }
        return all.first
    }
}
