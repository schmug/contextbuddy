import XCTest
@testable import ContextBuddyCore

// The typesafe/Jev backend writes a `signals` block into last.json that the
// Grade struct had no property for, so JSONDecoder discarded all of it. These
// tests pin the decode so the popover's "why" disclosure can render it.
//
// Every field is optional: the LLM backends (anthropic, ollama,
// openai_compatible) emit no `signals` at all, and per SPEC §13 an unknown or
// absent field warns rather than errors.
final class SignalsTests: XCTestCase {
    func testDecodesSignalsBlockFromTypesafeGrade() throws {
        let grade = try GradeCoding.decoder.decode(Grade.self, from: try fixtureData("grade_with_signals"))
        let signals = try XCTUnwrap(grade.signals)

        XCTAssertEqual(signals.backend, "typesafe")
        XCTAssertEqual(signals.model, "jev-1.13.0")
        XCTAssertEqual(signals.isTask, 0.98)
        XCTAssertEqual(signals.taskGated, false)
        XCTAssertEqual(signals.isCorrection, 0.04)
        XCTAssertEqual(signals.destructive, 0.01)
        XCTAssertEqual(signals.bypass, 0.02)
        XCTAssertEqual(signals.severity, 0.19)
    }

    func testDecodesIntentChoiceAndConfidence() throws {
        let grade = try GradeCoding.decoder.decode(Grade.self, from: try fixtureData("grade_with_signals"))
        let intent = try XCTUnwrap(grade.signals?.intent)

        // `choice` is a JSON *value*, not a key, so it is never touched by the
        // decoder's snake_case key conversion. Display code can trust it.
        XCTAssertEqual(intent.choice, "investigate")
        XCTAssertEqual(intent.confidence, 0.58)
    }

    func testDecodesTypedMasses() throws {
        let grade = try GradeCoding.decoder.decode(Grade.self, from: try fixtureData("grade_with_signals"))
        let masses = try XCTUnwrap(grade.signals?.masses)

        XCTAssertEqual(masses.confidenceLow, 0.8)
        XCTAssertEqual(masses.atomicityLow, 0.07)
        XCTAssertEqual(masses.driftHigh, 0.01)
    }

    // MARK: - The dictionary-key trap

    func testProbabilityKeysKeepTheirRawSnakeCaseSpelling() throws {
        // GradeCoding.decoder sets .convertFromSnakeCase, but that strategy
        // applies only to keys backed by a CodingKey — NOT to the keys of a
        // [String: Double]. So `fix_bug` survives verbatim.
        //
        // This is pinned rather than assumed: the opposite belief is the
        // natural one, and if a future Swift release starts converting
        // dictionary keys the popover's intent list would silently go blank.
        // `Intent.humanize` deliberately handles both spellings so that
        // change would degrade to cosmetics rather than breakage.
        let grade = try GradeCoding.decoder.decode(Grade.self, from: try fixtureData("grade_with_signals"))
        let probabilities = try XCTUnwrap(grade.signals?.intent?.probabilities)

        XCTAssertEqual(probabilities["fix_bug"], 0.16, "got keys: \(Array(probabilities.keys).sorted())")
        XCTAssertEqual(probabilities["plan_or_evaluate"], 0.1)
        XCTAssertEqual(probabilities["investigate"], 0.63)
        XCTAssertNil(probabilities["fixBug"], "decoder should not be camelCasing dictionary keys")
    }

    func testTopIntentsSortDescendingAndHumanizeBothSpellings() throws {
        let grade = try GradeCoding.decoder.decode(Grade.self, from: try fixtureData("grade_with_signals"))
        let top = try XCTUnwrap(grade.signals?.intent).topIntents(limit: 3)

        XCTAssertEqual(top.map(\.label), ["investigate", "fix bug", "plan or evaluate"])
        XCTAssertEqual(top.first?.probability, 0.63)
    }

    func testZeroProbabilityIntentsAreDroppedFromTheTopList() throws {
        let grade = try GradeCoding.decoder.decode(Grade.self, from: try fixtureData("grade_with_signals"))
        let all = try XCTUnwrap(grade.signals?.intent).topIntents(limit: 99)

        XCTAssertFalse(all.contains { $0.probability == 0 }, "a 0% intent is noise in a 320pt popover")
    }

    // MARK: - Backward compatibility

    func testGradeWithoutSignalsStillDecodes() throws {
        // The anthropic/ollama backends emit no `signals` key at all.
        let grade = try GradeCoding.decoder.decode(Grade.self, from: try fixtureData("example1_pre_turn14"))
        XCTAssertNil(grade.signals)
    }

    func testSignalsSurviveARoundTrip() throws {
        let grade = try GradeCoding.decoder.decode(Grade.self, from: try fixtureData("grade_with_signals"))
        let reDecoded = try GradeCoding.decoder.decode(Grade.self, from: try GradeCoding.encoder.encode(grade))
        XCTAssertEqual(grade, reDecoded)
    }

    func testEncodingOmitsSignalsWhenAbsent() throws {
        let grade = try GradeCoding.decoder.decode(Grade.self, from: try fixtureData("example1_pre_turn14"))
        let json = String(data: try GradeCoding.encoder.encode(grade), encoding: .utf8)!
        XCTAssertFalse(json.contains("\"signals\""), "a nil signals block must not round-trip into a null key")
    }

    // MARK: - Helpers

    private func fixtureData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw XCTSkip("fixture \(name).json not found in test bundle")
        }
        return try Data(contentsOf: url)
    }
}
