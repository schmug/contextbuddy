import XCTest
@testable import ContextBuddyCore

final class SchemaTests: XCTestCase {
    // MARK: - Grade round-trips (§4.1, §8 worked examples)

    func testExample1AttentionGradeRoundTrip() throws {
        let data = try fixtureData("example1_pre_turn14")
        let grade = try GradeCoding.decoder.decode(Grade.self, from: data)

        XCTAssertEqual(grade.schemaVersion, 1)
        XCTAssertEqual(grade.phase, .pre)
        XCTAssertEqual(grade.turn, 14)
        XCTAssertEqual(grade.scores.atomicity.value, 3)
        XCTAssertEqual(grade.scores.pollution.value, 4)
        XCTAssertTrue(grade.scores.pollution.rationale.hasPrefix("(carried from turn 13)"))
        XCTAssertEqual(grade.dominantSignal, .atomicity)
        XCTAssertEqual(grade.tokensUsed, 47823)
        XCTAssertEqual(grade.tokensLimit, 200_000)

        let reEncoded = try GradeCoding.encoder.encode(grade)
        let reDecoded = try GradeCoding.decoder.decode(Grade.self, from: reEncoded)
        XCTAssertEqual(grade, reDecoded)
    }

    func testExample2CelebrateGradeRoundTrip() throws {
        let data = try fixtureData("example2_post_turn22")
        let grade = try GradeCoding.decoder.decode(Grade.self, from: data)

        XCTAssertEqual(grade.phase, .post)
        XCTAssertEqual(grade.turn, 22)
        XCTAssertNil(grade.dominantSignal, "celebrate-grade should have null dominant_signal")
        XCTAssertGreaterThanOrEqual(grade.scores.confidence.value, 7)
        XCTAssertGreaterThanOrEqual(grade.scores.atomicity.value, 7)

        let reEncoded = try GradeCoding.encoder.encode(grade)
        let reDecoded = try GradeCoding.decoder.decode(Grade.self, from: reEncoded)
        XCTAssertEqual(grade, reDecoded)
    }

    func testExample3DizzyLoopGradeRoundTrip() throws {
        let data = try fixtureData("example3_post_turn29")
        let grade = try GradeCoding.decoder.decode(Grade.self, from: data)

        XCTAssertEqual(grade.phase, .post)
        XCTAssertEqual(grade.dominantSignal, .loop, "plugin-set sentinel must decode")

        let reEncoded = try GradeCoding.encoder.encode(grade)
        let reEncodedString = String(data: reEncoded, encoding: .utf8)!
        XCTAssertTrue(
            reEncodedString.contains("\"dominant_signal\":\"loop\""),
            "loop sentinel must encode back to snake_case JSON value"
        )
    }

    func testContextPressureSentinelRoundTrip() throws {
        let grade = sampleGrade(dominantSignal: .contextPressure)
        let encoded = try GradeCoding.encoder.encode(grade)
        let json = String(data: encoded, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"dominant_signal\":\"context_pressure\""))
        let decoded = try GradeCoding.decoder.decode(Grade.self, from: encoded)
        XCTAssertEqual(decoded.dominantSignal, .contextPressure)
    }

    func testUnknownFieldsAreIgnored() throws {
        // §4 contract: unknown fields must not error.
        let json = """
        {
          "schema_version": 1,
          "phase": "pre",
          "turn": 1,
          "timestamp": "2026-04-29T00:00:00Z",
          "scores": {
            "confidence": {"value": 5, "rationale": "x"},
            "atomicity": {"value": 5, "rationale": "x"},
            "drift": {"value": 5, "rationale": "x"},
            "pollution": {"value": 5, "rationale": "x"}
          },
          "tokens_used": 0,
          "tokens_limit": 200000,
          "dominant_signal": null,
          "summary_update": "x",
          "future_field": "ignored",
          "another_unknown": {"nested": true}
        }
        """.data(using: .utf8)!
        XCTAssertNoThrow(try GradeCoding.decoder.decode(Grade.self, from: json))
    }

    func testFutureSchemaVersionDecodesSoCallersCanWarn() throws {
        // Per §13: buddy reads and warns (does not error) on unknown versions.
        let json = """
        {
          "schema_version": 99,
          "phase": "post",
          "turn": 1,
          "timestamp": "2026-04-29T00:00:00Z",
          "scores": {
            "confidence": {"value": 5, "rationale": "x"},
            "atomicity": {"value": 5, "rationale": "x"},
            "drift": {"value": 5, "rationale": "x"},
            "pollution": {"value": 5, "rationale": "x"}
          },
          "tokens_used": 0,
          "tokens_limit": 200000,
          "dominant_signal": null,
          "summary_update": "x"
        }
        """.data(using: .utf8)!
        let grade = try GradeCoding.decoder.decode(Grade.self, from: json)
        XCTAssertEqual(grade.schemaVersion, 99)
    }

    func testCarriedPollutionRationalePreservesPrefix() throws {
        // §6 pollution carry-forward rule. Schema decode must not strip the prefix.
        let grade = sampleGrade(
            phase: .pre,
            pollutionRationale: "(carried from turn 7) accumulated tool results"
        )
        let encoded = try GradeCoding.encoder.encode(grade)
        let decoded = try GradeCoding.decoder.decode(Grade.self, from: encoded)
        XCTAssertEqual(
            decoded.scores.pollution.rationale,
            "(carried from turn 7) accumulated tool results"
        )
    }

    // MARK: - FeedbackEvent (§4.6)

    func testFeedbackMuteRoundTrip() throws {
        let data = try fixtureData("feedback_session_mute", ext: "json")
        let event = try FeedbackCoding.decoder.decode(FeedbackEvent.self, from: data)
        XCTAssertEqual(event.action, .mute)
        XCTAssertEqual(event.signal, .atomicity)
        XCTAssertEqual(event.scope, .session)
        XCTAssertEqual(event.turn, 14)

        let reEncoded = try FeedbackCoding.encoder.encode(event)
        let reDecoded = try FeedbackCoding.decoder.decode(FeedbackEvent.self, from: reEncoded)
        XCTAssertEqual(event, reDecoded)
    }

    func testFeedbackAckLoopSentinel() throws {
        // The "loop" / "context_pressure" sentinels must be valid signal values
        // for ack/mute events.
        let event = FeedbackEvent(
            timestamp: "2026-04-29T13:09:00Z",
            turn: 29,
            action: .ack,
            signal: .loop,
            scope: nil
        )
        let data = try FeedbackCoding.encoder.encode(event)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"signal\":\"loop\""))
        XCTAssertTrue(json.contains("\"action\":\"ack\""))
    }

    // MARK: - Config (§4.8)

    func testConfigDefaults() {
        let cfg = Config.defaults
        XCTAssertEqual(cfg.thresholds.confidenceAttention, 4)
        XCTAssertEqual(cfg.thresholds.atomicityAttention, 4)
        XCTAssertEqual(cfg.thresholds.driftAttention, 6)
        XCTAssertEqual(cfg.thresholds.pollutionAttention, 7)
        XCTAssertEqual(cfg.thresholds.celebrateConsecutiveN, 5)
        XCTAssertEqual(cfg.thresholds.loopEditsInWindow, 3)
        XCTAssertEqual(cfg.thresholds.loopWindowTurns, 3)
        XCTAssertEqual(cfg.thresholds.contextPressurePct, 85)
        XCTAssertEqual(cfg.grader.model, "claude-haiku-4-5-20251001")
        XCTAssertEqual(cfg.grader.slidingWindowTurns, 3)
        XCTAssertEqual(cfg.grader.inspectModel, "claude-sonnet-4-6")
        XCTAssertTrue(cfg.ui.animationsEnabled)
        XCTAssertEqual(cfg.ui.tokenRowPct, 70)
    }

    func testConfigParsesDefaultFile() throws {
        let url = try fixtureURL("config_default", ext: "toml")
        let source = try String(contentsOf: url, encoding: .utf8)
        let parsed = try Config.parse(source)
        XCTAssertEqual(parsed, .defaults)
    }

    func testConfigParseSkipsCommentsAndBlankLines() throws {
        let source = """
        # comment line
        [thresholds]
        confidence_attention = 5  # inline override

        [ui]
        animations_enabled = false
        token_row_pct = 80
        """
        let parsed = try Config.parse(source)
        XCTAssertEqual(parsed.thresholds.confidenceAttention, 5)
        XCTAssertFalse(parsed.ui.animationsEnabled)
        XCTAssertEqual(parsed.ui.tokenRowPct, 80)
        // Other thresholds keep defaults
        XCTAssertEqual(parsed.thresholds.atomicityAttention, Config.defaults.thresholds.atomicityAttention)
    }

    func testConfigUnknownSectionThrows() {
        let source = """
        [bogus]
        foo = 1
        """
        XCTAssertThrowsError(try Config.parse(source)) { error in
            XCTAssertEqual(error as? ConfigParseError, .unknownSection("bogus"))
        }
    }

    func testConfigUnknownKeyThrows() {
        let source = """
        [thresholds]
        not_a_key = 1
        """
        XCTAssertThrowsError(try Config.parse(source)) { error in
            XCTAssertEqual(
                error as? ConfigParseError,
                .unknownKey(section: "thresholds", key: "not_a_key")
            )
        }
    }

    func testConfigTypeMismatchThrows() {
        let source = """
        [thresholds]
        confidence_attention = "four"
        """
        XCTAssertThrowsError(try Config.parse(source)) { error in
            guard case .typeMismatch(let section, let key, let expected, _) =
                    (error as? ConfigParseError) else {
                return XCTFail("expected typeMismatch, got \(error)")
            }
            XCTAssertEqual(section, "thresholds")
            XCTAssertEqual(key, "confidence_attention")
            XCTAssertEqual(expected, "integer")
        }
    }

    func testConfigLoadFallsBackToDefaultsOnMissingFile() {
        let nonexistent = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).toml")
        var captured: Error?
        let cfg = Config.load(from: nonexistent) { captured = $0 }
        XCTAssertEqual(cfg, .defaults)
        XCTAssertNil(captured, "missing-file path returns defaults silently (no parse occurred)")
    }

    func testConfigLoadFallsBackToDefaultsOnMalformed() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctxbuddy-malformed-\(UUID().uuidString).toml")
        try "[bogus]\nfoo = 1".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var captured: Error?
        let cfg = Config.load(from: tmp) { captured = $0 }
        XCTAssertEqual(cfg, .defaults)
        XCTAssertEqual(captured as? ConfigParseError, .unknownSection("bogus"))
    }

    // MARK: - Helpers

    private func fixtureData(_ name: String, ext: String = "json") throws -> Data {
        let url = try fixtureURL(name, ext: ext)
        return try Data(contentsOf: url)
    }

    private func fixtureURL(_ name: String, ext: String = "json") throws -> URL {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: ext,
            subdirectory: "Fixtures"
        ) else {
            throw XCTSkip("fixture \(name).\(ext) not found in test bundle")
        }
        return url
    }

    private func sampleGrade(
        phase: Phase = .post,
        dominantSignal: DominantSignal? = nil,
        pollutionRationale: String = "clean"
    ) -> Grade {
        Grade(
            phase: phase,
            turn: 1,
            timestamp: "2026-04-29T00:00:00Z",
            scores: Scores(
                confidence: Score(value: 8, rationale: "ok"),
                atomicity: Score(value: 8, rationale: "ok"),
                drift: Score(value: 1, rationale: "ok"),
                pollution: Score(value: 2, rationale: pollutionRationale)
            ),
            tokensUsed: 100,
            tokensLimit: 200_000,
            dominantSignal: dominantSignal,
            summaryUpdate: "test"
        )
    }
}
