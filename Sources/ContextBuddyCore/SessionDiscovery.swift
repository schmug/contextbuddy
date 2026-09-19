import Foundation
import CryptoKit

// MARK: - SessionDiscovery
//
// Per §2: the buddy watches `~/.claude/inspector/sessions/` and the plugin
// writes to `sessions/<project-hash>/`. Project hash is the first 12 hex
// chars of sha256(canonical_project_path), the absolute path with symlinks
// resolved (issue #4). This module owns:
//   - the hash function
//   - listing sessions by MRU (most-recent last.json mtime, falling back to
//     the session directory's mtime while a session has no grade yet)
//   - resolving "current" session (MRU unless explicitly pinned)

public struct SessionRef: Equatable, Sendable {
    public let projectHash: String
    public let directory: URL
    public let lastUpdated: Date?
    // mtime of the session directory itself. A session has no last.json until
    // its first grade lands, so this is the only timestamp a fresh session has.
    public let directoryModified: Date?
    // Absolute project path from meta.json (§4.9). nil for session dirs the
    // plugin wrote before meta.json existed — the hash is one-way, so there is
    // nothing to fall back on but the hash itself.
    public let projectPath: String?

    public init(
        projectHash: String,
        directory: URL,
        lastUpdated: Date?,
        directoryModified: Date? = nil,
        projectPath: String? = nil
    ) {
        self.projectHash = projectHash
        self.directory = directory
        self.lastUpdated = lastUpdated
        self.directoryModified = directoryModified
        self.projectPath = projectPath
    }

    // Display name for the popover's project footer row.
    public var projectName: String? {
        projectPath.flatMap { SessionDiscovery.projectName(forPath: $0) }
    }

    // The timestamp MRU orders on: the last grade when there is one, otherwise
    // the directory mtime (issue #5). Without the fallback a brand-new session
    // lost to every graded one, however stale, and the buddy watched the wrong
    // project until the first grade arrived.
    public var lastActivity: Date? {
        lastUpdated ?? directoryModified
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

    // sha256(canonical_project_path)[:12] per §2. The input is canonicalized
    // first (issue #4): on macOS the same directory is reachable as /tmp/x and
    // /private/tmp/x, and hashing the string verbatim split one project's
    // session across two directories. Must agree byte-for-byte with
    // plugin/lib/project_hash.sh; both test suites pin the same constant.
    public static func projectHash(for absolutePath: String) -> String {
        let data = Data(canonicalProjectPath(absolutePath).utf8)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    // realpath(3) of the path: symlinks, `.` and `..` resolved, trailing slash
    // dropped. Same precedent as Watcher.canonicalize — URL.resolvingSymlinksInPath
    // does not reliably follow the top-level /var and /tmp symlinks. A path
    // realpath cannot resolve (it does not exist) comes back verbatim, with no
    // parent-directory fallback: a project path the hooks hash always exists,
    // and the plugin's `cd -P && pwd -P` falls back to the verbatim string the
    // same way, so both sides agree on unresolvable input too.
    public static func canonicalProjectPath(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
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

    // List all session directories with their last.json mtime (nil if absent)
    // and the directory's own mtime. Sorted descending by lastActivity, so an
    // ungraded session ranks by when its directory was last touched rather
    // than always last. Equal timestamps fall back to hash order so the
    // listing is stable from one call to the next.
    public func listSessions() -> [SessionRef] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let refs: [SessionRef] = entries.compactMap { (entry: URL) -> SessionRef? in
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { return nil }
            let hash = entry.lastPathComponent
            let lastJson = entry.appendingPathComponent("last.json")
            let mtime = (try? lastJson.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let dirMtime = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            return SessionRef(
                projectHash: hash,
                directory: entry,
                lastUpdated: mtime,
                directoryModified: dirMtime,
                projectPath: Self.projectPath(inSessionDirectory: entry)
            )
        }
        return refs.sorted { (lhs: SessionRef, rhs: SessionRef) -> Bool in
            switch (lhs.lastActivity, rhs.lastActivity) {
            case let (l?, r?) where l != r:
                return l > r
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.projectHash < rhs.projectHash
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
