import Foundation
import SQLite3

// SQLite wrapper for state.db (§4.7). Two writers: feedback events (§4.6)
// and state transitions (§5). v1 has no read consumers — enumerate methods
// exist for the test suite and for v2 corpus analytics.
//
// Per §13, on corruption or open failure we delete the file and recreate.
// The store is "best-effort, not durable contract."

public actor Storage {
    private var db: OpaquePointer?
    private let url: URL
    public private(set) var didRecover: Bool = false

    public init(url: URL) async throws {
        self.url = url
        try Self.ensureParentDirectory(url)
        do {
            try openAndPrepare()
        } catch StorageError.corruptOrUnopenable {
            try recover()
            try openAndPrepare()
            didRecover = true
        }
    }

    // Storage lives for the app's lifetime in production. Tests recreate
    // per-case but don't bother closing — SQLite releases handles on
    // process exit. Avoiding actor-isolated deinit also keeps Swift 6
    // strict concurrency happy.

    // MARK: Writers

    public func recordFeedback(_ event: FeedbackEvent, projectHash: String) throws {
        let sql = """
            INSERT INTO feedback_events (project_hash, turn, action, signal, scope, ts)
            VALUES (?, ?, ?, ?, ?, ?)
        """
        try runStatement(sql) { stmt in
            try bind(stmt, index: 1, projectHash)
            try bind(stmt, index: 2, event.turn)
            try bind(stmt, index: 3, event.action.rawValue)
            try bind(stmt, index: 4, event.signal.rawValue)
            try bind(stmt, index: 5, (event.scope ?? .session).rawValue)
            try bind(stmt, index: 6, event.timestamp)
        }
    }

    public func recordTransition(_ transition: StateTransition, projectHash: String) throws {
        let sql = """
            INSERT INTO state_transitions (project_hash, from_state, to_state, trigger, turn, ts)
            VALUES (?, ?, ?, ?, ?, ?)
        """
        try runStatement(sql) { stmt in
            try bind(stmt, index: 1, projectHash)
            try bind(stmt, index: 2, transition.from.rawValue)
            try bind(stmt, index: 3, transition.to.rawValue)
            try bind(stmt, index: 4, transition.trigger)
            if let turn = transition.turn {
                try bind(stmt, index: 5, turn)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            try bind(stmt, index: 6, Self.iso8601(transition.at))
        }
    }

    // MARK: Readers (test/v2-only)

    public struct FeedbackRow: Equatable, Sendable {
        public let id: Int64
        public let projectHash: String
        public let turn: Int
        public let action: String
        public let signal: String
        public let scope: String
        public let ts: String
    }

    public struct TransitionRow: Equatable, Sendable {
        public let id: Int64
        public let projectHash: String
        public let from: String
        public let to: String
        public let trigger: String
        public let turn: Int?
        public let ts: String
    }

    public func enumerateFeedback() throws -> [FeedbackRow] {
        var rows: [FeedbackRow] = []
        try query("SELECT id, project_hash, turn, action, signal, scope, ts FROM feedback_events ORDER BY id ASC") { stmt in
            rows.append(FeedbackRow(
                id: sqlite3_column_int64(stmt, 0),
                projectHash: Self.text(stmt, 1),
                turn: Int(sqlite3_column_int64(stmt, 2)),
                action: Self.text(stmt, 3),
                signal: Self.text(stmt, 4),
                scope: Self.text(stmt, 5),
                ts: Self.text(stmt, 6)
            ))
        }
        return rows
    }

    public func enumerateTransitions() throws -> [TransitionRow] {
        var rows: [TransitionRow] = []
        try query("SELECT id, project_hash, from_state, to_state, trigger, turn, ts FROM state_transitions ORDER BY id ASC") { stmt in
            rows.append(TransitionRow(
                id: sqlite3_column_int64(stmt, 0),
                projectHash: Self.text(stmt, 1),
                from: Self.text(stmt, 2),
                to: Self.text(stmt, 3),
                trigger: Self.text(stmt, 4),
                turn: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 5)),
                ts: Self.text(stmt, 6)
            ))
        }
        return rows
    }

    // MARK: Internals

    private func openAndPrepare() throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        if rc != SQLITE_OK {
            if let handle { sqlite3_close(handle) }
            throw StorageError.corruptOrUnopenable
        }
        self.db = handle
        do {
            try createSchemaIfNeeded()
        } catch {
            sqlite3_close(self.db)
            self.db = nil
            throw StorageError.corruptOrUnopenable
        }
    }

    private func recover() throws {
        try? FileManager.default.removeItem(at: url)
        let journal = url.appendingPathExtension("journal")
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let shm = URL(fileURLWithPath: url.path + "-shm")
        for sidecar in [journal, wal, shm] {
            try? FileManager.default.removeItem(at: sidecar)
        }
    }

    private func createSchemaIfNeeded() throws {
        let ddl = """
            CREATE TABLE IF NOT EXISTS feedback_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              project_hash TEXT NOT NULL,
              turn INTEGER NOT NULL,
              action TEXT NOT NULL,
              signal TEXT NOT NULL,
              scope TEXT NOT NULL,
              ts TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS state_transitions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              project_hash TEXT NOT NULL,
              from_state TEXT NOT NULL,
              to_state TEXT NOT NULL,
              trigger TEXT NOT NULL,
              turn INTEGER,
              ts TEXT NOT NULL
            );
        """
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, ddl, nil, nil, &errmsg)
        if rc != SQLITE_OK {
            let msg = errmsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errmsg)
            throw StorageError.runFailed(message: msg)
        }
    }

    private func runStatement(
        _ sql: String,
        bind binder: (OpaquePointer) throws -> Void
    ) throws {
        guard let db else { throw StorageError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw StorageError.runFailed(message: "prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        try binder(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw StorageError.runFailed(message: "step failed: \(msg)")
        }
    }

    private func query(
        _ sql: String,
        row: (OpaquePointer) -> Void
    ) throws {
        guard let db else { throw StorageError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw StorageError.runFailed(message: "prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            row(stmt)
        }
    }

    private func bind(_ stmt: OpaquePointer, index: Int32, _ value: String) throws {
        let rc = sqlite3_bind_text(stmt, index, value, -1, Self.SQLITE_TRANSIENT)
        if rc != SQLITE_OK { throw StorageError.runFailed(message: "bind text failed (\(rc))") }
    }

    private func bind(_ stmt: OpaquePointer, index: Int32, _ value: Int) throws {
        let rc = sqlite3_bind_int64(stmt, index, Int64(value))
        if rc != SQLITE_OK { throw StorageError.runFailed(message: "bind int failed (\(rc))") }
    }

    private static let SQLITE_TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )

    private static func text(_ stmt: OpaquePointer, _ idx: Int32) -> String {
        guard let cstr = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: cstr)
    }

    private static func ensureParentDirectory(_ url: URL) throws {
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
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

public enum StorageError: Error, Equatable {
    case notOpen
    case corruptOrUnopenable
    case runFailed(message: String)
}
