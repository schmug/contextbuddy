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
        // SPEC §8.3 worked example 3: atomicity is scored on the action's boundary,
        // not on the retry count (repeats are loop detection's job, §5.4). Pins the
        // fixture so a drift back to the retry-penalised 6 fails here.
        XCTAssertEqual(grade.scores.atomicity.value, 9, "example 3 atomicity per the §6 rubric")
        XCTAssertEqual(grade.scores.confidence.value, 7)
        XCTAssertEqual(grade.scores.drift.value, 2)
        XCTAssertEqual(grade.scores.pollution.value, 5)

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

    // Issue #7: the typesafe grader sets "harm" when signals.destructive or
    // signals.bypass reaches the action threshold. Additive: schema_version
    // stays 1 and a grade without `signals` decodes exactly as before.
    func testHarmSentinelRoundTrip() throws {
        let grade = sampleGrade(dominantSignal: .harm)
        let encoded = try GradeCoding.encoder.encode(grade)
        let json = String(data: encoded, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"dominant_signal\":\"harm\""))
        let decoded = try GradeCoding.decoder.decode(Grade.self, from: encoded)
        XCTAssertEqual(decoded.dominantSignal, .harm)
        XCTAssertNil(decoded.signals, "a harm grade without signals still decodes")
        XCTAssertEqual(decoded, grade)
    }

    func testHarmGradeWithTypesafeSignalsDecodes() throws {
        let json = """
        {
          "schema_version": 1,
          "phase": "pre",
          "turn": 3,
          "timestamp": "2026-09-19T00:00:00Z",
          "scores": {
            "confidence": {"value": 8, "rationale": "x"},
            "atomicity": {"value": 8, "rationale": "x"},
            "drift": {"value": 1, "rationale": "x"},
            "pollution": {"value": 2, "rationale": "x"}
          },
          "tokens_used": 100,
          "tokens_limit": 200000,
          "dominant_signal": "harm",
          "summary_update": "x",
          "signals": {"backend": "typesafe", "destructive": 0.99, "bypass": 0.97, "severity": 2.1}
        }
        """.data(using: .utf8)!
        let grade = try GradeCoding.decoder.decode(Grade.self, from: json)
        XCTAssertEqual(grade.schemaVersion, 1)
        XCTAssertEqual(grade.dominantSignal, .harm)
        XCTAssertEqual(grade.signals?.destructive, 0.99)
        XCTAssertEqual(grade.signals?.bypass, 0.97)
        XCTAssertEqual(grade.signals?.severity, 2.1)
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

    // Issue #47: the hooks record the session model and where tokens_limit came from.
    // Both are optional and additive; grades written before #47 carry neither.
    func testModelAndLimitSourceDecodeWhenPresent() throws {
        let json = """
        {
          "schema_version": 1,
          "phase": "pre",
          "turn": 1,
          "timestamp": "2026-09-19T00:00:00Z",
          "scores": {
            "confidence": {"value": 5, "rationale": "x"},
            "atomicity": {"value": 5, "rationale": "x"},
            "drift": {"value": 5, "rationale": "x"},
            "pollution": {"value": 5, "rationale": "x"}
          },
          "tokens_used": 176474,
          "tokens_limit": 1000000,
          "model": "claude-fable-5-1",
          "limit_source": "model",
          "dominant_signal": null,
          "summary_update": "x"
        }
        """.data(using: .utf8)!
        let grade = try GradeCoding.decoder.decode(Grade.self, from: json)
        XCTAssertEqual(grade.model, "claude-fable-5-1")
        XCTAssertEqual(grade.limitSource, "model")
        XCTAssertEqual(grade.tokensLimit, 1_000_000)
        let roundTrip = try GradeCoding.decoder.decode(Grade.self, from: GradeCoding.encoder.encode(grade))
        XCTAssertEqual(roundTrip.model, "claude-fable-5-1")
        XCTAssertEqual(roundTrip.limitSource, "model")
    }

    func testModelAndLimitSourceAreNilForOlderGrades() throws {
        let grade = sampleGrade(phase: .pre, pollutionRationale: "x")
        XCTAssertNil(grade.model)
        XCTAssertNil(grade.limitSource)
        let encoded = String(decoding: try GradeCoding.encoder.encode(grade), as: UTF8.self)
        XCTAssertFalse(encoded.contains("\"model\""), "nil optionals must be omitted, not written as null")
        XCTAssertFalse(encoded.contains("limit_source"))
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
        XCTAssertEqual(cfg.grader.backend, "anthropic")
        XCTAssertEqual(cfg.grader.model, "claude-haiku-4-5-20251001")
        XCTAssertEqual(cfg.grader.slidingWindowTurns, 3)
        XCTAssertEqual(cfg.grader.inspectModel, "claude-sonnet-4-6")
        XCTAssertEqual(cfg.grader.ollama.endpoint, "http://localhost:11434")
        XCTAssertEqual(cfg.grader.openaiCompatible.endpoint, "http://localhost:1234/v1")
        XCTAssertEqual(cfg.grader.openaiCompatible.apiKeyEnv, "")
        XCTAssertEqual(cfg.grader.typesafe.apiKeyEnv, "TYPESAFE_API_KEY")
        XCTAssertEqual(cfg.grader.typesafe.endpoint, "https://api.typesafe.ai")
        XCTAssertEqual(cfg.grader.typesafe.taskGate, 0.5)
        XCTAssertEqual(cfg.grader.typesafe.harmAction, 0.7)
        XCTAssertTrue(cfg.ui.animationsEnabled)
        XCTAssertEqual(cfg.ui.tokenRowPct, 70)
    }

    func testConfigParsesOllamaBackend() throws {
        let source = """
        [grader]
        backend = "ollama"
        model = "qwen2.5:14b-instruct"

        [grader.ollama]
        endpoint = "http://192.168.1.5:11434"
        """
        let parsed = try Config.parse(source)
        XCTAssertEqual(parsed.grader.backend, "ollama")
        XCTAssertEqual(parsed.grader.model, "qwen2.5:14b-instruct")
        XCTAssertEqual(parsed.grader.ollama.endpoint, "http://192.168.1.5:11434")
    }

    func testConfigParsesOpenAICompatibleBackend() throws {
        let source = """
        [grader]
        backend = "openai_compatible"

        [grader.openai_compatible]
        endpoint = "http://localhost:8000/v1"
        api_key_env = "MY_LOCAL_KEY"
        """
        let parsed = try Config.parse(source)
        XCTAssertEqual(parsed.grader.backend, "openai_compatible")
        XCTAssertEqual(parsed.grader.openaiCompatible.endpoint, "http://localhost:8000/v1")
        XCTAssertEqual(parsed.grader.openaiCompatible.apiKeyEnv, "MY_LOCAL_KEY")
    }

    // Issue #8: before the section was known, `[grader.typesafe]` threw
    // unknownSection and Config.load fell back to defaults for the whole
    // file, thresholds included. The section must parse and leave the
    // thresholds the file set.
    func testConfigParsesTypesafeBackendWithThresholdsIntact() throws {
        let source = """
        [thresholds]
        atomicity_attention = 5

        [grader]
        backend = "typesafe"
        model = "jev-1.13.0"

        [grader.typesafe]
        api_key_env = "MY_JEV_KEY"
        endpoint = "http://127.0.0.1:8080"
        task_gate = 0.6
        harm_action = 0.9
        """
        let parsed = try Config.parse(source)
        XCTAssertEqual(parsed.thresholds.atomicityAttention, 5)
        XCTAssertEqual(parsed.grader.backend, "typesafe")
        XCTAssertEqual(parsed.grader.typesafe.apiKeyEnv, "MY_JEV_KEY")
        XCTAssertEqual(parsed.grader.typesafe.endpoint, "http://127.0.0.1:8080")
        XCTAssertEqual(parsed.grader.typesafe.taskGate, 0.6)
        XCTAssertEqual(parsed.grader.typesafe.harmAction, 0.9)
    }

    func testConfigTypesafeUnknownKeyStillThrows() {
        let source = """
        [grader.typesafe]
        api_key = "sk-never-in-config"
        """
        XCTAssertThrowsError(try Config.parse(source)) { error in
            XCTAssertEqual(
                error as? ConfigParseError,
                .unknownKey(section: "grader.typesafe", key: "api_key")
            )
        }
    }

    func testConfigTypesafeGateTypeMismatchThrows() {
        let source = """
        [grader.typesafe]
        task_gate = "half"
        """
        XCTAssertThrowsError(try Config.parse(source)) { error in
            guard case .typeMismatch(let section, let key, let expected, _) =
                    (error as? ConfigParseError) else {
                return XCTFail("expected typeMismatch, got \(error)")
            }
            XCTAssertEqual(section, "grader.typesafe")
            XCTAssertEqual(key, "task_gate")
            XCTAssertEqual(expected, "float in 0...1")
        }
    }

    // task_gate and harm_action are probabilities. `task_gate = 50` (percent
    // confusion) used to parse and gate every turn; anything outside 0...1 is
    // now a typeMismatch, and so are the ".5", "1." and leading-zero forms the
    // shell parser (plugin/lib/config.sh toml_get_section_float) already sends
    // to the default. 1.0 is the top of the range and stands.
    func testConfigTypesafeGateOutsideUnitIntervalThrows() throws {
        let source = """
        [grader.typesafe]
        task_gate = 50
        """
        XCTAssertThrowsError(try Config.parse(source)) { error in
            guard case .typeMismatch(let section, let key, _, let got) =
                    (error as? ConfigParseError) else {
                return XCTFail("expected typeMismatch, got \(error)")
            }
            XCTAssertEqual(section, "grader.typesafe")
            XCTAssertEqual(key, "task_gate")
            XCTAssertEqual(got, "50")
        }
        for literal in [".5", "1.", "1.5", "00.5"] {
            XCTAssertThrowsError(try Config.parse("[grader.typesafe]\nharm_action = \(literal)"), literal)
        }
        let top = try Config.parse("[grader.typesafe]\nharm_action = 1.0")
        XCTAssertEqual(top.grader.typesafe.harmAction, 1.0)
    }

    // endpoint carries the Bearer key: plaintext http is only allowed to a
    // loopback host. Mirrors endpointSchemeError in plugin/grader/jev.mjs.
    func testConfigTypesafeEndpointRequiresHttpsUnlessLoopback() throws {
        let source = """
        [grader.typesafe]
        endpoint = "http://api.example.com"
        """
        XCTAssertThrowsError(try Config.parse(source)) { error in
            guard case .typeMismatch(let section, let key, _, _) =
                    (error as? ConfigParseError) else {
                return XCTFail("expected typeMismatch, got \(error)")
            }
            XCTAssertEqual(section, "grader.typesafe")
            XCTAssertEqual(key, "endpoint")
        }
        let allowed = ["https://api.example.com", "http://localhost:8080", "http://127.0.0.1:8080", "http://[::1]:8080"]
        for url in allowed {
            let parsed = try Config.parse("[grader.typesafe]\nendpoint = \"\(url)\"")
            XCTAssertEqual(parsed.grader.typesafe.endpoint, url)
        }
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
