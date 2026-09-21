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
    // Optional: only the typesafe/Jev backend emits it. Absent for the
    // anthropic, ollama and openai_compatible backends.
    public var signals: Signals?
    // Optional, additive (issue #47): the session's Claude model id as read
    // from the transcript (e.g. "claude-fable-5-1") and where tokens_limit
    // came from: "override" | "autocompact" | "model" | "observed" | "default".
    // Absent from grades written before #47; nil encodes as no key, not null.
    public var model: String?
    public var limitSource: String?

    public init(
        schemaVersion: Int = 1,
        phase: Phase,
        turn: Int,
        timestamp: String,
        scores: Scores,
        tokensUsed: Int,
        tokensLimit: Int,
        dominantSignal: DominantSignal?,
        summaryUpdate: String,
        signals: Signals? = nil,
        model: String? = nil,
        limitSource: String? = nil
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
        self.signals = signals
        self.model = model
        self.limitSource = limitSource
    }
}

// MARK: - Signals
//
// The typesafe backend's per-turn judgment block. Every field is optional:
// the block itself is backend-specific, and Jev's schema may gain fields
// without this app knowing about them (§13 — warn, do not error).
//
// Before this existed the block was decoded and silently discarded, so the
// popover had no access to intent, severity or the harm probabilities.

public struct Signals: Codable, Equatable, Sendable {
    public var backend: String?
    public var model: String?
    public var isTask: Double?
    public var taskGated: Bool?
    public var intent: Intent?
    public var isCorrection: Double?
    public var destructive: Double?
    public var bypass: Double?
    public var severity: Double?
    public var masses: Masses?

    public init(
        backend: String? = nil,
        model: String? = nil,
        isTask: Double? = nil,
        taskGated: Bool? = nil,
        intent: Intent? = nil,
        isCorrection: Double? = nil,
        destructive: Double? = nil,
        bypass: Double? = nil,
        severity: Double? = nil,
        masses: Masses? = nil
    ) {
        self.backend = backend
        self.model = model
        self.isTask = isTask
        self.taskGated = taskGated
        self.intent = intent
        self.isCorrection = isCorrection
        self.destructive = destructive
        self.bypass = bypass
        self.severity = severity
        self.masses = masses
    }

    public struct Intent: Codable, Equatable, Sendable {
        public var choice: String?
        // NOTE: .convertFromSnakeCase does NOT reach these keys — the strategy
        // only rewrites keys backed by a CodingKey, so `fix_bug` arrives
        // verbatim. `Intent.humanize` still handles both spellings so a future
        // decoder change degrades to cosmetics. Pinned by
        // SignalsTests.testProbabilityKeysKeepTheirRawSnakeCaseSpelling.
        public var probabilities: [String: Double]?
        public var confidence: Double?

        public init(choice: String? = nil, probabilities: [String: Double]? = nil, confidence: Double? = nil) {
            self.choice = choice
            self.probabilities = probabilities
            self.confidence = confidence
        }

        // Highest-probability intents first, zero-probability entries dropped
        // (a 0% row is noise in a 320pt popover). Ties break on label so the
        // popover does not reshuffle between identical grades.
        // Written as explicit statements rather than one chained expression:
        // the chained form (filter -> map -> sorted-with-ternary -> prefix ->
        // map) exceeded the Swift type-checker's time budget on the CI runner
        // and failed to build there while compiling locally, since that budget
        // is wall-clock and so machine-speed dependent.
        public func topIntents(limit: Int) -> [IntentProbability] {
            guard limit > 0, let probabilities else { return [] }

            var ranked: [IntentProbability] = []
            for (key, value) in probabilities where value > 0 {
                ranked.append(IntentProbability(label: Intent.humanize(key), probability: value))
            }

            ranked.sort { (lhs: IntentProbability, rhs: IntentProbability) -> Bool in
                if lhs.probability != rhs.probability {
                    return lhs.probability > rhs.probability
                }
                return lhs.label < rhs.label
            }

            if ranked.count > limit {
                ranked.removeSubrange(limit...)
            }
            return ranked
        }

        // The humanized form of `choice`, for display next to topIntents.
        public var choiceLabel: String? {
            choice.map(Intent.humanize)
        }

        // "fixBug" / "fix_bug" -> "fix bug".
        public static func humanize(_ key: String) -> String {
            var out = ""
            for character in key.replacingOccurrences(of: "_", with: " ") {
                if character.isUppercase {
                    out.append(" ")
                    out.append(Character(character.lowercased()))
                } else {
                    out.append(character)
                }
            }
            return out
        }
    }

    public struct IntentProbability: Equatable, Sendable {
        public let label: String
        public let probability: Double

        public init(label: String, probability: Double) {
            self.label = label
            self.probability = probability
        }
    }

    // Jev's belief mass per attention dimension. Typed rather than a
    // dictionary so snake_case conversion lands on a known property instead
    // of an unpredictable key spelling.
    public struct Masses: Codable, Equatable, Sendable {
        public var confidenceLow: Double?
        public var atomicityLow: Double?
        public var driftHigh: Double?
        public var pollutionHigh: Double?

        public init(
            confidenceLow: Double? = nil,
            atomicityLow: Double? = nil,
            driftHigh: Double? = nil,
            pollutionHigh: Double? = nil
        ) {
            self.confidenceLow = confidenceLow
            self.atomicityLow = atomicityLow
            self.driftHigh = driftHigh
            self.pollutionHigh = pollutionHigh
        }
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
// mechanically-set sentinels (loop, context_pressure), the harm sentinel, or
// null. Per §7.5 the grader never emits loop/context_pressure — those are set
// by the plugin. harm (issue #7, §5.4) is set by the typesafe grader when
// signals.destructive or signals.bypass reaches [grader.typesafe].harm_action;
// StateMachine maps it to attention, not dizzy. An unknown raw value fails the
// whole decode and the buddy ignores the grade, which is why harm must be a
// case here and not a string the app tolerates.
public enum DominantSignal: String, Codable, Equatable, Sendable {
    case confidence
    case atomicity
    case drift
    case pollution
    case loop
    case contextPressure = "context_pressure"
    case harm
}

// MARK: - GraderStatus (grader_status.json)
//
// Per §4.10 (issue #92). The plugin writes one record per grader attempt,
// whatever the outcome; the buddy reads it to tell "nobody typed anything"
// apart from "the grader cannot run". Before this file existed the two were
// the same picture: a grader with no reachable credential wrote nothing at
// all, and the buddy held `sleep` indefinitely with no way to say why.
//
// Decoded leniently on purpose. An unrecognized `status` or `reason` — a
// newer plugin writing next to an older app, the two halves ship together but
// are installed separately — degrades to `.unknown` rather than failing the
// whole decode. Failing would put the app back in the state this record
// exists to end: no grade and no explanation.
public struct GraderStatus: Equatable, Sendable {
    public enum Outcome: String, Equatable, Sendable {
        // A grade was produced and written.
        case ok
        // The grader ran and declined to grade this turn (the typesafe
        // backend's is_task gate). Not a fault.
        case skipped
        // The grader could not produce a grade.
        case error
        case unknown
    }

    // Why there is no grade. nil when `status` is ok.
    public enum Reason: String, Equatable, Sendable {
        case notATask = "not_a_task"
        case missingKey = "missing_key"
        case notConfigured = "not_configured"
        case transportFailure = "transport_failure"
        case invalidResponse = "invalid_response"
        case unknown
    }

    public var schemaVersion: Int
    public var timestamp: String
    public var phase: Phase?
    public var turn: Int
    public var backend: String
    public var status: Outcome
    public var reason: Reason?
    // A fixed sentence chosen by the plugin from the reason class. It never
    // carries anything the backend printed (plugin/lib/grader_status.sh), so
    // it cannot leak a credential — but it is also not rendered in the UI,
    // which shows backend and reason only.
    public var detail: String?

    public init(
        schemaVersion: Int = 1,
        timestamp: String,
        phase: Phase?,
        turn: Int,
        backend: String,
        status: Outcome,
        reason: Reason?,
        detail: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.timestamp = timestamp
        self.phase = phase
        self.turn = turn
        self.backend = backend
        self.status = status
        self.reason = reason
        self.detail = detail
    }

    // The one question the UI asks: should the user be told grading is not
    // happening? `skipped` is deliberately not a failure — the grader ran.
    public var isFailure: Bool { status == .error }

    // The line the popover row, the menubar tooltip and the right-click menu
    // all show (§9.3 / §9.4). Backend and reason class only.
    public var summaryLine: String {
        "grading unavailable — \(backend): \(reasonPhrase)"
    }

    public var reasonPhrase: String {
        switch reason {
        case .missingKey: return "no API key reachable from this project"
        case .notConfigured: return "backend not configured"
        case .transportFailure: return "backend unreachable"
        case .invalidResponse: return "backend returned an invalid grade"
        case .notATask: return "turn not graded"
        case .unknown, .none: return "unknown reason"
        }
    }
}

extension GraderStatus: Codable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case timestamp, phase, turn, backend, status, reason, detail
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp) ?? ""
        phase = (try c.decodeIfPresent(String.self, forKey: .phase)).flatMap(Phase.init(rawValue:))
        turn = try c.decodeIfPresent(Int.self, forKey: .turn) ?? 0
        backend = try c.decodeIfPresent(String.self, forKey: .backend) ?? "unknown"
        let rawStatus = try c.decodeIfPresent(String.self, forKey: .status)
        status = rawStatus.flatMap(Outcome.init(rawValue:)) ?? .unknown
        if let rawReason = try c.decodeIfPresent(String.self, forKey: .reason) {
            reason = Reason(rawValue: rawReason) ?? .unknown
        } else {
            reason = nil
        }
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(phase?.rawValue, forKey: .phase)
        try c.encode(turn, forKey: .turn)
        try c.encode(backend, forKey: .backend)
        try c.encode(status.rawValue, forKey: .status)
        try c.encodeIfPresent(reason?.rawValue, forKey: .reason)
        try c.encodeIfPresent(detail, forKey: .detail)
    }
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
        public var backend: String
        public var model: String
        public var slidingWindowTurns: Int
        public var inspectModel: String
        public var ollama: Ollama
        public var openaiCompatible: OpenAICompatible

        public struct Ollama: Equatable, Sendable {
            public var endpoint: String
            public init(endpoint: String) { self.endpoint = endpoint }
        }

        public struct OpenAICompatible: Equatable, Sendable {
            public var endpoint: String
            public var apiKeyEnv: String
            public init(endpoint: String, apiKeyEnv: String) {
                self.endpoint = endpoint
                self.apiKeyEnv = apiKeyEnv
            }
        }

        // [grader.typesafe] (issue #8). apiKeyEnv is the NAME of the
        // environment variable holding the key, never the key: the key value
        // is never written to config.toml or any grade file. taskGate is the
        // is_task probability below which the typesafe backend skips the turn;
        // harmAction the destructive/bypass probability the hooks treat as
        // actionable. Both are unit-interval floats. Consumed by
        // plugin/lib/job.sh and plugin/grader/invoke.sh; the app only needs to
        // know the section so the file keeps its thresholds.
        public struct Typesafe: Equatable, Sendable {
            public var apiKeyEnv: String
            public var endpoint: String
            public var taskGate: Double
            public var harmAction: Double
            public init(apiKeyEnv: String, endpoint: String, taskGate: Double, harmAction: Double) {
                self.apiKeyEnv = apiKeyEnv
                self.endpoint = endpoint
                self.taskGate = taskGate
                self.harmAction = harmAction
            }
        }

        public var typesafe: Typesafe

        public init(
            backend: String = "anthropic",
            model: String,
            slidingWindowTurns: Int,
            inspectModel: String,
            ollama: Ollama = Ollama(endpoint: "http://localhost:11434"),
            openaiCompatible: OpenAICompatible = OpenAICompatible(endpoint: "http://localhost:1234/v1", apiKeyEnv: ""),
            typesafe: Typesafe = Typesafe(apiKeyEnv: "TYPESAFE_API_KEY", endpoint: "https://api.typesafe.ai", taskGate: 0.5, harmAction: 0.7)
        ) {
            self.backend = backend
            self.model = model
            self.slidingWindowTurns = slidingWindowTurns
            self.inspectModel = inspectModel
            self.ollama = ollama
            self.openaiCompatible = openaiCompatible
            self.typesafe = typesafe
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
            backend: "anthropic",
            model: "claude-haiku-4-5-20251001",
            slidingWindowTurns: 3,
            inspectModel: "claude-sonnet-4-6",
            ollama: Grader.Ollama(endpoint: "http://localhost:11434"),
            openaiCompatible: Grader.OpenAICompatible(endpoint: "http://localhost:1234/v1", apiKeyEnv: ""),
            typesafe: Grader.Typesafe(
                apiKeyEnv: "TYPESAFE_API_KEY",
                endpoint: "https://api.typesafe.ai",
                taskGate: 0.5,
                harmAction: 0.7
            )
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
                let knownSections = ["thresholds", "grader", "grader.ollama", "grader.openai_compatible", "grader.typesafe", "ui"]
                if !knownSections.contains(section) {
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
                case "backend":
                    grader.backend = try parseString(valueRaw, section: section, key: key)
                case "model":
                    grader.model = try parseString(valueRaw, section: section, key: key)
                case "sliding_window_turns":
                    grader.slidingWindowTurns = try parseInt(valueRaw, section: section, key: key)
                case "inspect_model":
                    grader.inspectModel = try parseString(valueRaw, section: section, key: key)
                default:
                    throw ConfigParseError.unknownKey(section: section, key: key)
                }
            case "grader.ollama":
                switch key {
                case "endpoint":
                    grader.ollama.endpoint = try parseString(valueRaw, section: section, key: key)
                default:
                    throw ConfigParseError.unknownKey(section: section, key: key)
                }
            case "grader.openai_compatible":
                switch key {
                case "endpoint":
                    grader.openaiCompatible.endpoint = try parseString(valueRaw, section: section, key: key)
                case "api_key_env":
                    grader.openaiCompatible.apiKeyEnv = try parseString(valueRaw, section: section, key: key)
                default:
                    throw ConfigParseError.unknownKey(section: section, key: key)
                }
            case "grader.typesafe":
                switch key {
                case "api_key_env":
                    grader.typesafe.apiKeyEnv = try parseString(valueRaw, section: section, key: key)
                case "endpoint":
                    grader.typesafe.endpoint = try parseEndpoint(valueRaw, section: section, key: key)
                case "task_gate":
                    grader.typesafe.taskGate = try parseDouble(valueRaw, section: section, key: key)
                case "harm_action":
                    grader.typesafe.harmAction = try parseDouble(valueRaw, section: section, key: key)
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

// TOML float or integer literal inside the unit interval: "0", "0.5", "1",
// "1.0". Sign, exponent, underscore and leading-zero forms are rejected, as
// are ".5", "1." and anything above 1: the only float keys are probability
// gates, and `task_gate = 50` (percent confusion) would otherwise gate every
// turn. The accepted shape matches toml_get_section_float in
// plugin/lib/config.sh, so both parsers agree on every literal.
private func parseDouble(_ value: String, section: String, key: String) throws -> Double {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    let whole = parts.count <= 2 && (parts[0] == "0" || parts[0] == "1")
    let fraction = parts.count == 1 || (!parts[1].isEmpty && parts[1].allSatisfy { $0.isASCII && $0.isNumber })
    if whole, fraction, let v = Double(value), v <= 1 { return v }
    throw ConfigParseError.typeMismatch(section: section, key: key, expected: "float in 0...1", got: value)
}

// [grader.typesafe].endpoint receives the Bearer key, so plaintext http is
// only allowed to a loopback host. Mirrors endpointSchemeError in
// plugin/grader/jev.mjs, which applies the same rule at request time.
private func parseEndpoint(_ value: String, section: String, key: String) throws -> String {
    let raw = try parseString(value, section: section, key: key)
    let url = URL(string: raw)
    let scheme = url?.scheme?.lowercased() ?? ""
    let host = (url?.host(percentEncoded: false) ?? "").lowercased()
    let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    let loopback = bare == "localhost" || bare == "127.0.0.1" || bare == "::1"
    if scheme == "https" || (scheme == "http" && loopback) { return raw }
    throw ConfigParseError.typeMismatch(
        section: section, key: key,
        expected: "https:// URL (http:// only for localhost, 127.0.0.1, ::1)", got: raw
    )
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
