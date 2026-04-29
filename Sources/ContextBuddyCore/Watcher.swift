import Foundation
import CoreServices

// MARK: - Watcher
//
// FSEvents-backed watcher for `~/.claude/inspector/sessions/`. Emits one
// event per detected mutation of any `last.json` under any project-hash
// subdirectory. The 50 ms FSEvents latency knob coalesces the
// temp-file-then-rename pair the plugin uses for atomic writes (§4.3).
//
// Lifecycle: `events()` returns an `AsyncStream`. The stream's continuation
// is finished when the caller cancels its iteration or when `stop()` is
// called. Repeated calls to `events()` after termination return a fresh
// stream — but only one stream may be active at a time.

public final class Watcher: @unchecked Sendable {
    public struct Event: Sendable, Equatable {
        public let projectHash: String
        public let lastJsonURL: URL

        public init(projectHash: String, lastJsonURL: URL) {
            self.projectHash = projectHash
            self.lastJsonURL = lastJsonURL
        }
    }

    private let sessionsRoot: URL
    private let latencySeconds: Double
    private let queue = DispatchQueue(label: "com.donthype.contextbuddy.watcher")

    // All access to these must happen on `queue`.
    private var stream: FSEventStreamRef?
    private var continuation: AsyncStream<Event>.Continuation?

    public init(sessionsRoot: URL, latencySeconds: Double = 0.05) {
        // FSEvents reports canonical (resolved-symlink) paths. macOS
        // temporary directories (/var/folders/...) are symlinks to
        // /private/var/folders/..., so we resolve via realpath(3) — neither
        // URL.resolvingSymlinksInPath() nor NSString.resolvingSymlinksInPath
        // reliably follows the top-level /var symlink in tests.
        self.sessionsRoot = Self.canonicalize(sessionsRoot)
        self.latencySeconds = latencySeconds
    }

    private static func canonicalize(_ url: URL) -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(url.path, &buffer) != nil {
            return URL(fileURLWithPath: String(cString: buffer))
        }
        // Path may not exist yet (we'll create it). Try the parent.
        let parent = url.deletingLastPathComponent()
        if realpath(parent.path, &buffer) != nil {
            let parentCanonical = URL(fileURLWithPath: String(cString: buffer))
            return parentCanonical.appendingPathComponent(url.lastPathComponent)
        }
        return url
    }

    deinit {
        stopSync()
    }

    public func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                self.tearDownStreamLocked()
                self.continuation = continuation
                self.startStreamLocked()
                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { self.tearDownStreamLocked() }
                }
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.tearDownStreamLocked()
        }
    }

    private func stopSync() {
        // Used from deinit. Best-effort; queue may already be torn down.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: queue-isolated

    private func startStreamLocked() {
        // Ensure the watched path exists; FSEvents tolerates missing paths
        // by emitting nothing, but creating the directory means the plugin
        // can populate it later without us needing to restart.
        try? FileManager.default.createDirectory(
            at: sessionsRoot,
            withIntermediateDirectories: true
        )

        let info = Unmanaged.passUnretained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: info,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let pathsToWatch = [sessionsRoot.path] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latencySeconds,
            flags
        ) else {
            continuation?.finish()
            continuation = nil
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func tearDownStreamLocked() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        continuation?.finish()
        continuation = nil
    }

    private func handlePaths(_ paths: [String]) {
        for path in paths where path.hasSuffix("/last.json") {
            let url = URL(fileURLWithPath: path)
            let projectHash = url.deletingLastPathComponent().lastPathComponent
            guard url.path.hasPrefix(sessionsRoot.path + "/") else { continue }
            guard !projectHash.isEmpty else { continue }
            continuation?.yield(Event(projectHash: projectHash, lastJsonURL: url))
        }
    }

    // C-callback shim. info points to the Watcher instance (unretained).
    private static let callback: FSEventStreamCallback = {
        _, info, numEvents, eventPaths, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue()
        // We requested kFSEventStreamCreateFlagUseCFTypes, so eventPaths is a
        // CFArray of CFString.
        let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        var paths: [String] = []
        paths.reserveCapacity(numEvents)
        for i in 0..<CFArrayGetCount(cfArray) {
            let raw = CFArrayGetValueAtIndex(cfArray, i)
            let cfStr = unsafeBitCast(raw, to: CFString.self)
            paths.append(cfStr as String)
        }
        watcher.handlePaths(paths)
    }
}
