import Foundation

// MARK: - BuddyCore
//
// The public actor exposed to ContextBuddyApp (§3). Composes Watcher,
// StateMachine, Storage, SessionDiscovery, and Config. Owns the timers for
// transient-state decay (heart 3 s, celebrate 2.5 s) and the periodic sleep
// tick.
//
// Intentionally read-only against external systems other than state.db and
// feedback.jsonl. No Anthropic API calls — those live in the plugin (§15).

public actor BuddyCore {
    public struct Snapshot: Sendable, Equatable {
        public let state: BuddyState
        public let projectHash: String?
        public let lastGrade: Grade?
        public let pinnedHash: String?

        public init(
            state: BuddyState,
            projectHash: String?,
            lastGrade: Grade?,
            pinnedHash: String?
        ) {
            self.state = state
            self.projectHash = projectHash
            self.lastGrade = lastGrade
            self.pinnedHash = pinnedHash
        }
    }

    // Per §5.1 / §9.1 / §9.2 timings.
    public static let heartHoldSeconds: TimeInterval = 3.0
    public static let celebrateHoldSeconds: TimeInterval = 2.5
    public static let sleepTickSeconds: TimeInterval = 30.0

    private let inspectorRoot: URL
    private let sessionsRoot: URL
    private let configURL: URL
    private let storage: Storage
    private let discovery: SessionDiscovery
    private let watcher: Watcher

    private var state: BuddyState = .sleep
    private var histories: [String: StateHistory] = [:]
    private var pinnedHash: String?
    private var currentHash: String?
    private var config: Config = .defaults
    private var configMTime: Date?

    private var subscriber: AsyncStream<Snapshot>.Continuation?
    private var watcherTask: Task<Void, Never>?
    private var sleepTickTask: Task<Void, Never>?
    private var heartTask: Task<Void, Never>?
    private var celebrateTask: Task<Void, Never>?

    public init(inspectorRoot: URL? = nil) async throws {
        let root = inspectorRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/inspector", isDirectory: true)
        self.inspectorRoot = root
        self.sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        self.configURL = root.appendingPathComponent("config.toml")

        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)

        let stateDBURL = Self.stateDBURL()
        self.storage = try await Storage(url: stateDBURL)
        self.discovery = SessionDiscovery(sessionsRoot: sessionsRoot)
        self.watcher = Watcher(sessionsRoot: sessionsRoot)

        reloadConfig()
        bootstrapStateFromDisk()
    }

    public static func stateDBURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("ContextBuddy/state.db")
    }

    // MARK: Public API

    public func subscribe() -> AsyncStream<Snapshot> {
        AsyncStream { continuation in
            self.subscriber = continuation
            continuation.yield(self.makeSnapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.clearSubscriber() }
            }
        }
    }

    public func start() {
        guard watcherTask == nil else { return }
        watcherTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.watcher.events() {
                await self.handleWatcherEvent(event)
            }
        }
        sleepTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.sleepTickSeconds * 1_000_000_000))
                if Task.isCancelled { break }
                await self?.runSleepTick()
            }
        }
    }

    public func stop() {
        watcherTask?.cancel()
        watcherTask = nil
        sleepTickTask?.cancel()
        sleepTickTask = nil
        heartTask?.cancel()
        heartTask = nil
        celebrateTask?.cancel()
        celebrateTask = nil
        watcher.stop()
    }

    public func currentSnapshot() -> Snapshot {
        makeSnapshot()
    }

    public func pinSession(_ hash: String?) {
        pinnedHash = hash
        if let hash, let session = discovery.listSessions().first(where: { $0.projectHash == hash }) {
            currentHash = session.projectHash
            loadGradeForCurrentSession()
            broadcast()
        } else if hash == nil {
            // Unpin: snap to MRU.
            currentHash = discovery.listSessions().first?.projectHash
            loadGradeForCurrentSession()
            broadcast()
        }
    }

    public func recordFeedback(
        action: FeedbackAction,
        signal: DominantSignal,
        scope: FeedbackScope = .session
    ) async {
        guard let hash = currentHash else { return }
        let event = FeedbackEvent(
            timestamp: Self.iso8601(Date()),
            turn: histories[hash]?.lastGrade?.turn ?? 0,
            action: action,
            signal: signal,
            scope: scope
        )
        await appendFeedbackJSONL(event, hash: hash)
        try? await storage.recordFeedback(event, projectHash: hash)

        if action == .ack {
            triggerHeart()
        }
    }

    // MARK: Internals

    private func clearSubscriber() {
        subscriber = nil
    }

    private func handleWatcherEvent(_ event: Watcher.Event) async {
        // Pin-aware filtering.
        if let pinnedHash, pinnedHash != event.projectHash { return }

        // Switch current session to the one that just produced an event
        // (this is by definition the MRU when unpinned).
        if pinnedHash == nil { currentHash = event.projectHash }

        guard let grade = loadGrade(at: event.lastJsonURL) else { return }

        reloadConfigIfChanged()

        let priorState = state
        let priorHistory = histories[event.projectHash] ?? .empty
        let result = StateMachine.evaluate(
            prev: priorHistory.latestDerivedState,
            grade: grade,
            history: priorHistory,
            cfg: config,
            now: Date()
        )
        histories[event.projectHash] = result.history

        // Heart in flight overrides newly-derived state until it decays —
        // the heart task will revert to result.state when it expires.
        if state != .heart {
            state = result.state
        }

        if let transition = result.transition {
            try? await storage.recordTransition(transition, projectHash: event.projectHash)
        }

        if result.state == .celebrate, priorState != .celebrate {
            scheduleCelebrateDecay()
        }

        broadcast()
    }

    private func runSleepTick() {
        let hash = currentHash ?? ""
        let history = histories[hash] ?? .empty
        let result = StateMachine.tick(prev: state, history: history, now: Date())
        if result.state != state, state != .heart, state != .celebrate {
            state = result.state
            if let t = result.transition, !hash.isEmpty {
                Task { try? await self.storage.recordTransition(t, projectHash: hash) }
            }
            broadcast()
        }
    }

    private func triggerHeart() {
        heartTask?.cancel()
        let priorState = state
        state = .heart
        if let hash = currentHash {
            let transition = StateTransition(
                from: priorState, to: .heart,
                trigger: "ack", at: Date()
            )
            Task { try? await self.storage.recordTransition(transition, projectHash: hash) }
        }
        broadcast()
        heartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.heartHoldSeconds * 1_000_000_000))
            await self?.expireHeart()
        }
    }

    private func expireHeart() {
        guard state == .heart else { return }
        let hash = currentHash ?? ""
        let history = histories[hash] ?? .empty
        state = StateMachine.decayHeart(history: history)
        broadcast()
    }

    private func scheduleCelebrateDecay() {
        celebrateTask?.cancel()
        celebrateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.celebrateHoldSeconds * 1_000_000_000))
            await self?.expireCelebrate()
        }
    }

    private func expireCelebrate() {
        guard state == .celebrate else { return }
        let hash = currentHash ?? ""
        let history = histories[hash] ?? .empty
        state = StateMachine.decayCelebrate(history: history)
        broadcast()
    }

    private func bootstrapStateFromDisk() {
        let mru = discovery.listSessions()
        guard let first = mru.first else {
            state = .sleep
            return
        }
        currentHash = first.projectHash
        loadGradeForCurrentSession()
    }

    private func loadGradeForCurrentSession() {
        guard let hash = currentHash else { return }
        let lastJson = sessionsRoot.appendingPathComponent(hash).appendingPathComponent("last.json")
        guard let grade = loadGrade(at: lastJson) else {
            state = .sleep
            return
        }
        let priorHistory = histories[hash] ?? .empty
        let result = StateMachine.evaluate(
            prev: priorHistory.latestDerivedState,
            grade: grade,
            history: priorHistory,
            cfg: config,
            now: Date()
        )
        histories[hash] = result.history
        state = result.state
    }

    private func loadGrade(at url: URL) -> Grade? {
        // FSEvents may fire mid-write; one retry covers the common case.
        for attempt in 0..<2 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.025) }
            if let data = try? Data(contentsOf: url),
               let grade = try? GradeCoding.decoder.decode(Grade.self, from: data) {
                return grade
            }
        }
        FileHandle.standardError.write(Data("ContextBuddy: failed to parse \(url.path)\n".utf8))
        return nil
    }

    private func reloadConfig() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: configURL.path)
        configMTime = attrs?[.modificationDate] as? Date
        config = Config.load(from: configURL) { error in
            FileHandle.standardError.write(Data("ContextBuddy: config error: \(error)\n".utf8))
        }
    }

    private func reloadConfigIfChanged() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: configURL.path)
        let mtime = attrs?[.modificationDate] as? Date
        if mtime != configMTime {
            reloadConfig()
        }
    }

    private func appendFeedbackJSONL(_ event: FeedbackEvent, hash: String) async {
        let url = sessionsRoot.appendingPathComponent(hash).appendingPathComponent("feedback.jsonl")
        guard let data = try? FeedbackCoding.encoder.encode(event) else { return }
        var line = data
        line.append(0x0A) // \n
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try line.write(to: url)
            }
        } catch {
            FileHandle.standardError.write(
                Data("ContextBuddy: failed to append feedback: \(error)\n".utf8)
            )
        }
    }

    private func makeSnapshot() -> Snapshot {
        let lastGrade = currentHash.flatMap { histories[$0]?.lastGrade }
        return Snapshot(
            state: state,
            projectHash: currentHash,
            lastGrade: lastGrade,
            pinnedHash: pinnedHash
        )
    }

    private func broadcast() {
        subscriber?.yield(makeSnapshot())
    }

    nonisolated(unsafe) private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func iso8601(_ date: Date) -> String {
        iso8601Formatter.string(from: date)
    }
}
