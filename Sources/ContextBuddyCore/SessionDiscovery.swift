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

    // Display name for the popover's project footer row. Computed on access
    // because it walks the filesystem to the git root (issue #42); the snapshot
    // path goes through BuddyCore, which caches the name per session hash.
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

    // Read the last grader attempt out of a session directory's
    // grader_status.json (§4.10, issue #92). Returns nil when the file is
    // absent — every session dir written before this record existed, and every
    // dir whose first grader attempt has not finished yet. Absence means "no
    // attempt recorded", never "the grader is fine": the caller shows nothing
    // extra, exactly as it did before the record existed.
    //
    // Read on demand rather than cached: unlike the project path this changes
    // turn by turn, and it is one small file read per snapshot.
    public static func graderStatus(inSessionDirectory directory: URL) -> GraderStatus? {
        let url = directory.appendingPathComponent("grader_status.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GraderStatus.self, from: data)
    }

    // Display name for an absolute project path: the name of the repository it
    // sits in (issue #42). Walks up from the path to the nearest ancestor that
    // holds a `.git` entry. A `.git` directory names that ancestor. A `.git`
    // file is a linked worktree's pointer, `gitdir: <main>/.git/worktrees/<n>`,
    // and names the main checkout instead — the worktree directory name
    // ("objective-cerf-9a0580") is exactly what the footer row must not show.
    // A `.git` file that is anything else (unreadable, empty, a submodule's
    // `gitdir: ../.git/modules/<n>`, a `--separate-git-dir` checkout) names the
    // directory holding it, which is that checkout's own name. With no `.git`
    // above the path — outside any repo, or a project deleted since the hook
    // recorded it — the name is the last path component, as before #42.
    //
    // Deliberately not the full path: it would leak /Users/<username>/… into a
    // screenshot-able UI and would not fit the 320pt popover. The popover's
    // tooltip keeps the recorded path; this only changes the label.
    //
    // Reads the filesystem directly and never shells out to git: one stat per
    // ancestor plus one small file read. BuddyCore caches the result per session
    // hash next to the path (Core.swift), so the walk does not run per snapshot.
    public static func projectName(forPath path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let recorded = URL(fileURLWithPath: path)
        let fallback = recorded.lastPathComponent
        guard !fallback.isEmpty, fallback != "/" else { return nil }
        return repositoryName(enclosing: recorded) ?? fallback
    }

    // Name of the nearest repository enclosing `url` (itself included), or nil
    // when no ancestor holds a `.git` entry. The loop terminates because each
    // step drops one path component and stops before the root.
    static func repositoryName(enclosing url: URL) -> String? {
        var directory = url.standardizedFileURL
        while directory.pathComponents.count > 1 {
            let gitEntry = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: gitEntry.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return directory.lastPathComponent }
                return mainCheckoutName(fromGitFile: gitEntry) ?? directory.lastPathComponent
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    // A linked worktree's `.git` file holds one line, `gitdir: <path>`, where
    // <path> is `<main checkout>/.git/worktrees/<worktree name>` — absolute as
    // `git worktree add` writes it, or relative to the worktree after
    // `git worktree repair --relative-paths`. Returns the main checkout's
    // directory name. nil when the file cannot be read, has no gitdir line, or
    // points anywhere other than a `worktrees/` entry under a `.git` directory.
    static func mainCheckoutName(fromGitFile file: URL) -> String? {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = contents.split(whereSeparator: { (character: Character) -> Bool in
            character.isNewline
        })
        guard let line = lines.first(where: { (line: Substring) -> Bool in
            line.hasPrefix("gitdir:")
        }) else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        let gitDirectory: URL
        if target.hasPrefix("/") {
            gitDirectory = URL(fileURLWithPath: target)
        } else {
            let worktree = file.deletingLastPathComponent()
            gitDirectory = worktree.appendingPathComponent(target).standardizedFileURL
        }
        // ["/", …, "<main>", ".git", "worktrees", "<name>"]: the checkout is the
        // component before `.git`, and index 0 is the filesystem root.
        let components = gitDirectory.pathComponents
        guard let gitIndex = components.lastIndex(of: ".git"), gitIndex > 1 else { return nil }
        guard gitIndex + 1 < components.count, components[gitIndex + 1] == "worktrees" else {
            return nil
        }
        return components[gitIndex - 1]
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
