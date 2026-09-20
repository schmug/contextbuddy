import XCTest
@testable import ContextBuddyCore

// Coverage for grader_status.json (§4.10, issue #92) — the record that tells
// "nobody typed anything" apart from "the grader cannot run".
//
// The fixtures are written as literal JSON rather than encoded from a
// GraderStatus, because the producer is plugin/lib/grader_status.sh and the
// thing under test is whether this side reads what that side writes. The
// strings below are copied from that script's output.
final class GraderStatusTests: XCTestCase {
    private func decode(_ json: String) throws -> GraderStatus {
        try JSONDecoder().decode(GraderStatus.self, from: Data(json.utf8))
    }

    func testDecodesTheMissingKeyRecordTheHooksWrite() throws {
        let status = try decode("""
        {"schema_version":1,"timestamp":"2026-09-20T18:00:00Z","phase":"pre","turn":3,
         "backend":"typesafe","status":"error","reason":"missing_key",
         "detail":"The typesafe backend has no credential."}
        """)
        XCTAssertEqual(status.schemaVersion, 1)
        XCTAssertEqual(status.phase, .pre)
        XCTAssertEqual(status.turn, 3)
        XCTAssertEqual(status.backend, "typesafe")
        XCTAssertEqual(status.status, .error)
        XCTAssertEqual(status.reason, .missingKey)
        XCTAssertTrue(status.isFailure)
        XCTAssertEqual(status.summaryLine, "grading unavailable — typesafe: no API key reachable from this project")
    }

    func testOkRecordIsNotAFailure() throws {
        let status = try decode("""
        {"schema_version":1,"timestamp":"2026-09-20T18:00:00Z","phase":"post","turn":3,
         "backend":"anthropic","status":"ok","reason":null,"detail":"Graded by the anthropic backend."}
        """)
        XCTAssertEqual(status.status, .ok)
        XCTAssertNil(status.reason)
        XCTAssertFalse(status.isFailure)
    }

    // The typesafe is_task gate declining a turn is the grader working, not
    // failing. Surfacing it as a fault would put a warning on the menubar every
    // time someone typed "thanks".
    func testSkippedTurnIsNotAFailure() throws {
        let status = try decode("""
        {"schema_version":1,"timestamp":"2026-09-20T18:00:00Z","phase":"pre","turn":1,
         "backend":"typesafe","status":"skipped","reason":"not_a_task","detail":"…"}
        """)
        XCTAssertEqual(status.status, .skipped)
        XCTAssertEqual(status.reason, .notATask)
        XCTAssertFalse(status.isFailure)
    }

    func testEveryReasonClassHasItsOwnPhrase() throws {
        let reasons = ["missing_key", "not_configured", "transport_failure", "invalid_response"]
        var phrases: Set<String> = []
        for reason in reasons {
            let status = try decode("""
            {"schema_version":1,"timestamp":"t","phase":"pre","turn":1,
             "backend":"typesafe","status":"error","reason":"\(reason)","detail":"d"}
            """)
            XCTAssertTrue(status.isFailure, "\(reason) should read as a failure")
            phrases.insert(status.reasonPhrase)
        }
        XCTAssertEqual(phrases.count, reasons.count, "two reason classes share a phrase")
    }

    // A newer plugin writing next to an older app. The two halves ship together
    // but are installed separately, and failing the decode would put the app
    // back in the state this record exists to end: no grade and no explanation.
    func testUnknownReasonDegradesInsteadOfFailingTheDecode() throws {
        let status = try decode("""
        {"schema_version":2,"timestamp":"t","phase":"pre","turn":1,
         "backend":"newbackend","status":"error","reason":"quota_exhausted","detail":"d"}
        """)
        XCTAssertEqual(status.reason, .unknown)
        XCTAssertTrue(status.isFailure, "an unrecognized reason on an error is still an error")
        XCTAssertEqual(status.backend, "newbackend")
    }

    func testUnknownStatusIsNotReportedAsAFailure() throws {
        let status = try decode("""
        {"schema_version":2,"timestamp":"t","phase":"pre","turn":1,
         "backend":"newbackend","status":"deferred","reason":null,"detail":"d"}
        """)
        XCTAssertEqual(status.status, .unknown)
        XCTAssertFalse(status.isFailure, "an unrecognized status must not raise a warning it cannot explain")
    }

    func testGarbageIsRejected() {
        XCTAssertNil(try? decode("not json"))
    }

    // MARK: - Reading it out of a session directory

    func testReadsTheRecordOutOfASessionDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctxbuddy-gs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(
            SessionDiscovery.graderStatus(inSessionDirectory: dir),
            "absence means no attempt recorded, not a failure"
        )

        try """
        {"schema_version":1,"timestamp":"t","phase":"pre","turn":2,"backend":"typesafe",\
        "status":"error","reason":"missing_key","detail":"d"}
        """.write(to: dir.appendingPathComponent("grader_status.json"), atomically: true, encoding: .utf8)

        let status = try XCTUnwrap(SessionDiscovery.graderStatus(inSessionDirectory: dir))
        XCTAssertEqual(status.reason, .missingKey)
    }
}
