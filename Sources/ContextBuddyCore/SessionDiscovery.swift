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

    public init(projectHash: String, directory: URL, lastUpdated: Date?) {
        self.projectHash = projectHash
        self.directory = directory
        self.lastUpdated = lastUpdated
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
            return SessionRef(projectHash: hash, directory: entry, lastUpdated: mtime)
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
