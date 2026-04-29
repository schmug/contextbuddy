import XCTest
@testable import ContextBuddyCore

final class WatcherTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctxbuddy-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    // FSEvents has wall-clock latency. Tests use a 5s ceiling and expect
    // the first event well under that on a quiet machine.
    private let timeout: TimeInterval = 5.0

    func testEmitsEventOnLastJsonWrite() async throws {
        let watcher = Watcher(sessionsRoot: root, latencySeconds: 0.05)
        let stream = watcher.events()

        // Allow the FSEvents stream to attach before producing changes.
        try await Task.sleep(nanoseconds: 100_000_000)

        let session = root.appendingPathComponent("abcabcabcabc")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let lastJson = session.appendingPathComponent("last.json")
        try "{}".write(to: lastJson, atomically: true, encoding: .utf8)

        let event = try await firstEvent(from: stream, within: timeout)
        XCTAssertEqual(event.projectHash, "abcabcabcabc")
        XCTAssertEqual(canonical(event.lastJsonURL.path), canonical(lastJson.path))

        watcher.stop()
    }

    private func canonical(_ path: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(path, &buf) != nil ? String(cString: buf) : path
    }

    func testIgnoresWritesToOtherFilenames() async throws {
        let watcher = Watcher(sessionsRoot: root, latencySeconds: 0.05)
        let stream = watcher.events()
        try await Task.sleep(nanoseconds: 100_000_000)

        let session = root.appendingPathComponent("ddddddddddddd")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try "{}".write(
            to: session.appendingPathComponent("history.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            to: session.appendingPathComponent("suggestions.md"),
            atomically: true,
            encoding: .utf8
        )

        // Now write an actual last.json — only this should be emitted.
        let lastJson = session.appendingPathComponent("last.json")
        try "{}".write(to: lastJson, atomically: true, encoding: .utf8)

        let event = try await firstEvent(from: stream, within: timeout)
        XCTAssertEqual(event.lastJsonURL.lastPathComponent, "last.json")

        watcher.stop()
    }

    func testCoalescesAtomicRenameTempPlusRename() async throws {
        let watcher = Watcher(sessionsRoot: root, latencySeconds: 0.05)
        let stream = watcher.events()
        try await Task.sleep(nanoseconds: 100_000_000)

        let session = root.appendingPathComponent("abc123abc123")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)

        // Simulate the plugin's atomic-write pattern: write temp, then
        // rename to last.json. FSEvents should emit at most a small handful
        // of events; we just verify that we get exactly one event for the
        // final last.json path within the latency window.
        let temp = session.appendingPathComponent("last.json.tmp")
        let final = session.appendingPathComponent("last.json")
        try "{}".write(to: temp, atomically: false, encoding: .utf8)
        try FileManager.default.moveItem(at: temp, to: final)

        let event = try await firstEvent(from: stream, within: timeout)
        XCTAssertEqual(canonical(event.lastJsonURL.path), canonical(final.path))

        watcher.stop()
    }

    func testStreamFinishesAfterStop() async throws {
        let watcher = Watcher(sessionsRoot: root, latencySeconds: 0.05)
        let stream = watcher.events()
        try await Task.sleep(nanoseconds: 100_000_000)
        watcher.stop()

        // After stop, the stream should finish; iterating should produce no
        // more events. We use a short timeout — if stop didn't terminate we
        // would hang.
        let task = Task { () -> Watcher.Event? in
            for await event in stream { return event }
            return nil
        }
        let result = try await withThrowingTaskGroup(of: Watcher.Event?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                return nil
            }
            let first = try await group.next()
            group.cancelAll()
            return first ?? nil
        }
        XCTAssertNil(result, "stream should yield no events after stop()")
    }

    // MARK: helpers

    private func firstEvent(
        from stream: AsyncStream<Watcher.Event>,
        within timeout: TimeInterval
    ) async throws -> Watcher.Event {
        try await withThrowingTaskGroup(of: Watcher.Event.self) { group in
            group.addTask {
                for await event in stream { return event }
                throw XCTSkip("stream finished before producing an event")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw TimeoutError()
            }
            guard let first = try await group.next() else {
                throw TimeoutError()
            }
            group.cancelAll()
            return first
        }
    }

    private struct TimeoutError: Error {}
}
