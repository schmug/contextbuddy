import Foundation

// MARK: - Grade (last.json, history.jsonl line, turns/NNN-{pre,post}.json)
//
// Schema per SPEC.md §4.1. Field rules locked: snake_case JSON, integer score
// values, ISO 8601 UTC timestamps. Decoding ignores unknown fields by default
// (Decodable behavior). schemaVersion=1 in v1; consumers warn (do not error)
// on unknown versions per §13.

public struct Grade: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var phase: Phase
    public var turn: Int
    public var timestamp: String
    public var scores: Scores
    public var tokensUsed: Int
    public var tokensLimit: Int
    public var dominantSignal: DominantSignal?
    public var summaryUpdate: String

    public init(
        schemaVersion: Int = 1,
        phase: Phase,
        turn: Int,
        timestamp: String,
        scores: Scores,
        tokensUsed: Int,
        tokensLimit: Int,
        dominantSignal: DominantSignal?,
        summaryUpdate: String
    ) {
        self.schemaVersion = schemaVersion
        self.phase = phase
        self.turn = turn
        self.timestamp = timestamp
        self.scores = scores
        self.tokensUsed = tokensUsed
        self.tokensLimit = tokensLimit
        self.dominantSignal = dominantSignal
        self.summaryUpdate = summaryUpdate
    }
}

public enum Phase: String, Codable, Sendable {
    case pre
    case post
}

public struct Scores: Codable, Equatable, Sendable {
    public var confidence: Score
    public var atomicity: Score
    public var drift: Score
    public var pollution: Score

    public init(confidence: Score, atomicity: Score, drift: Score, pollution: Score) {
        self.confidence = confidence
        self.atomicity = atomicity
        self.drift = drift
        self.pollution = pollution
    }

    public subscript(dimension: Dimension) -> Score {
        switch dimension {
        case .confidence: return confidence
        case .atomicity: return atomicity
        case .drift: return drift
        case .pollution: return pollution
        }
    }
}

public struct Score: Codable, Equatable, Sendable {
    public var value: Int
    public var rationale: String

    public init(value: Int, rationale: String) {
        self.value = value
        self.rationale = rationale
    }
}

// The four scored dimensions. Used for typed access to a Scores instance and
// for dominantSignal precedence resolution.
public enum Dimension: String, CaseIterable, Sendable {
    case confidence
    case atomicity
    case drift
    case pollution
}

// dominant_signal can be one of the four scored dimensions, the two
// mechanically-set sentinels (loop, context_pressure), or null. Per §7.5 the
// grader never emits loop/context_pressure — those are set by the plugin.
public enum DominantSignal: String, Codable, Equatable, Sendable {
    case confidence
    case atomicity
    case drift
    case pollution
    case loop
    case contextPressure = "context_pressure"
}

// MARK: - FeedbackEvent (feedback.jsonl)
//
// Per §4.6. Buddy writes; plugin reads (eventually).

public struct FeedbackEvent: Codable, Equatable, Sendable {
    public var timestamp: String
    public var turn: Int
    public var action: FeedbackAction
    public var signal: DominantSignal
    public var scope: FeedbackScope?

    public init(
        timestamp: String,
        turn: Int,
        action: FeedbackAction,
        signal: DominantSignal,
        scope: FeedbackScope?
    ) {
        self.timestamp = timestamp
        self.turn = turn
        self.action = action
        self.signal = signal
        self.scope = scope
    }
}

public enum FeedbackAction: String, Codable, Sendable {
    case ack
    case mute
}

public enum FeedbackScope: String, Codable, Sendable {
    case session
    case persistent
}

// MARK: - Config (config.toml)
//
// Per §4.8 plus the Q7 addition (token_row_pct in [ui]). Hand-rolled TOML
// parser (the schema is flat and fixed; pulling a TOML library is overkill).
// On parse failure, callers receive Config.defaults with a thrown error so
// they can log per §13 and proceed.

public struct Config: Equatable, Sendable {
    public var thresholds: Thresholds
    public var grader: Grader
    public var ui: UI

    public struct Thresholds: Equatable, Sendable {
        public var confidenceAttention: Int
        public var atomicityAttention: Int
        public var driftAttention: Int
        public var pollutionAttention: Int
        public var celebrateConsecutiveN: Int
        public var loopEditsInWindow: Int
        public var loopWindowTurns: Int
        public var contextPressurePct: Int

        public init(
            confidenceAttention: Int,
            atomicityAttention: Int,
            driftAttention: Int,
            pollutionAttention: Int,
            celebrateConsecutiveN: Int,
            loopEditsInWindow: Int,
            loopWindowTurns: Int,
            contextPressurePct: Int
        ) {
            self.confidenceAttention = confidenceAttention
            self.atomicityAttention = atomicityAttention
            self.driftAttention = driftAttention
            self.pollutionAttention = pollutionAttention
            self.celebrateConsecutiveN = celebrateConsecutiveN
            self.loopEditsInWindow = loopEditsInWindow
            self.loopWindowTurns = loopWindowTurns
            self.contextPressurePct = contextPressurePct
        }
    }

    public struct Grader: Equatable, Sendable {
        public var model: String
        public var slidingWindowTurns: Int
        public var inspectModel: String

        public init(model: String, slidingWindowTurns: Int, inspectModel: String) {
            self.model = model
            self.slidingWindowTurns = slidingWindowTurns
            self.inspectModel = inspectModel
        }
    }

    public struct UI: Equatable, Sendable {
        public var animationsEnabled: Bool
        public var tokenRowPct: Int

        public init(animationsEnabled: Bool, tokenRowPct: Int) {
            self.animationsEnabled = animationsEnabled
            self.tokenRowPct = tokenRowPct
        }
    }

    public init(thresholds: Thresholds, grader: Grader, ui: UI) {
        self.thresholds = thresholds
        self.grader = grader
        self.ui = ui
    }

    // Compiled-in defaults from §4.8 plus Q7 (token_row_pct = 70).
    public static let defaults = Config(
        thresholds: Thresholds(
            confidenceAttention: 4,
            atomicityAttention: 4,
            driftAttention: 6,
            pollutionAttention: 7,
            celebrateConsecutiveN: 5,
            loopEditsInWindow: 3,
            loopWindowTurns: 3,
            contextPressurePct: 85
        ),
        grader: Grader(
            model: "claude-haiku-4-5-20251001",
            slidingWindowTurns: 3,
            inspectModel: "claude-sonnet-4-6"
        ),
        ui: UI(animationsEnabled: true, tokenRowPct: 70)
    )
}

public enum ConfigParseError: Error, Equatable {
    case unknownSection(String)
    case unknownKey(section: String, key: String)
    case malformedLine(String)
    case typeMismatch(section: String, key: String, expected: String, got: String)
}

public extension Config {
    // Parse a TOML string conforming to §4.8. Unknown sections or keys throw;
    // malformed values throw. Callers handling §13 fallback should catch and
    // substitute Config.defaults.
    static func parse(_ source: String) throws -> Config {
        var thresholds = defaults.thresholds
        var grader = defaults.grader
        var ui = defaults.ui

        var section = ""
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if !["thresholds", "grader", "ui"].contains(section) {
                    throw ConfigParseError.unknownSection(section)
                }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else {
                throw ConfigParseError.malformedLine(line)
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let valueRaw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            switch section {
            case "thresholds":
                let v = try parseInt(valueRaw, section: section, key: key)
                switch key {
                case "confidence_attention": thresholds.confidenceAttention = v
                case "atomicity_attention": thresholds.atomicityAttention = v
                case "drift_attention": thresholds.driftAttention = v
                case "pollution_attention": thresholds.pollutionAttention = v
                case "celebrate_consecutive_n": thresholds.celebrateConsecutiveN = v
                case "loop_edits_in_window": thresholds.loopEditsInWindow = v
                case "loop_window_turns": thresholds.loopWindowTurns = v
                case "context_pressure_pct": thresholds.contextPressurePct = v
                default: throw ConfigParseError.unknownKey(section: section, key: key)
                }
            case "grader":
                switch key {
                case "model":
                    grader.model = try parseString(valueRaw, section: section, key: key)
                case "sliding_window_turns":
                    grader.slidingWindowTurns = try parseInt(valueRaw, section: section, key: key)
                case "inspect_model":
                    grader.inspectModel = try parseString(valueRaw, section: section, key: key)
                default:
                    throw ConfigParseError.unknownKey(section: section, key: key)
                }
            case "ui":
                switch key {
                case "animations_enabled":
                    ui.animationsEnabled = try parseBool(valueRaw, section: section, key: key)
                case "token_row_pct":
                    ui.tokenRowPct = try parseInt(valueRaw, section: section, key: key)
                default:
                    throw ConfigParseError.unknownKey(section: section, key: key)
                }
            default:
                throw ConfigParseError.malformedLine("key \(key) outside any section")
            }
        }

        return Config(thresholds: thresholds, grader: grader, ui: ui)
    }

    // Best-effort load with §13 fallback. Returns defaults on any error,
    // emitting the error via the optional logger closure for the caller to
    // route to stderr.
    static func load(from url: URL, logger: ((Error) -> Void)? = nil) -> Config {
        guard let data = try? Data(contentsOf: url),
              let source = String(data: data, encoding: .utf8) else {
            return defaults
        }
        do {
            return try parse(source)
        } catch {
            logger?(error)
            return defaults
        }
    }
}

private func stripComment(_ line: String) -> String {
    // TOML comments start with `#`. We don't support `#` inside strings in v1.
    guard let hash = line.firstIndex(of: "#") else { return line }
    return String(line[..<hash])
}

private func parseInt(_ value: String, section: String, key: String) throws -> Int {
    if let v = Int(value) { return v }
    throw ConfigParseError.typeMismatch(section: section, key: key, expected: "integer", got: value)
}

private func parseBool(_ value: String, section: String, key: String) throws -> Bool {
    switch value {
    case "true": return true
    case "false": return false
    default:
        throw ConfigParseError.typeMismatch(section: section, key: key, expected: "boolean", got: value)
    }
}

private func parseString(_ value: String, section: String, key: String) throws -> String {
    guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else {
        throw ConfigParseError.typeMismatch(section: section, key: key, expected: "string", got: value)
    }
    return String(value.dropFirst().dropLast())
}

// MARK: - Coding helpers

public enum GradeCoding {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

public enum FeedbackCoding {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}
