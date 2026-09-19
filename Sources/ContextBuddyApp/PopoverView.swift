import SwiftUI
import ContextBuddyCore

// The popover per SPEC.md §9.3.
//
// The score row used to render as `conf:2 atom:5 drift:0 pol:1`. That format
// could not express the one thing a reader needs: confidence and atomicity are
// higher-is-better while drift and pollution are higher-is-worse (§6), so in
// that example `conf:2` was the alarm and `drift:0` was perfect — and both
// read as "small number". The four meters below encode each score's distance
// from its OWN attention threshold as colour, so `.crossed` means "this is the
// problem" on every dimension regardless of direction. See ScoreMeter.
struct PopoverView: View {
    let snapshot: BuddyCore.Snapshot
    let tokenRowPct: Int
    let onAck: () -> Void
    let onMute: () -> Void
    let onOpenInspector: () -> Void

    @State private var showSignals = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            scoreSection
            if let grade = snapshot.lastGrade, grade.tokensLimit > 0 { tokenRow(grade) }
            if let line = dominantLine {
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if snapshot.lastGrade != nil { signalsDisclosure }
            actionRow
            Divider()
            projectFooterRow
        }
        .padding(12)
        .frame(width: 320)
    }

    // Project footer row (§9.3). Names the project the scores belong to, so a
    // yellow `attention` with several projects graded at once is attributable at
    // a glance. Not to be confused with plugin/statusline.sh, which is Claude
    // Code's status line and already runs in the project's own $PWD.
    //
    // Falls back to the hash prefix when the session dir has no meta.json —
    // those dirs predate the hook that writes it and the hash is one-way, so a
    // fragment of the digest is genuinely all that is known.
    private var projectFooterRow: some View {
        HStack(spacing: 4) {
            Text("📁")
                .font(.system(size: 11))
            Text(projectLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .help(projectTooltip)
    }

    private var projectLabel: String {
        if let name = snapshot.projectName, !name.isEmpty { return name }
        if let hash = snapshot.projectHash { return hash.prefix(6) + "…" }
        return "no session"
    }

    // The full path stays out of the row itself — it leaks /Users/<username>/…
    // into a screenshot-able surface and will not fit 320pt.
    private var projectTooltip: String {
        if let path = snapshot.projectPath { return path }
        if let hash = snapshot.projectHash {
            return "Project path unknown (session \(hash)); it is recorded on the next graded turn."
        }
        return "No active session."
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text(emoji)
            Text(snapshot.state.rawValue)
                .font(.system(size: 13, weight: .semibold))
                .help(stateHelp)
            if let grade = snapshot.lastGrade {
                Text("turn \(grade.turn) · \(grade.phase.rawValue)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .help(gradeAgeHelp(grade))
            }
            Spacer()
            if let hash = snapshot.projectHash {
                Text(hash.prefix(6) + "…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .help("Project hash \(hash)\nsha256 of the project's absolute path, first 12 chars.")
            }
        }
    }

    // MARK: - Scores

    @ViewBuilder
    private var scoreSection: some View {
        if let grade = snapshot.lastGrade {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(
                    ScoreMeter.meters(
                        for: grade.scores,
                        thresholds: snapshot.thresholds,
                        dominantSignal: grade.dominantSignal
                    ),
                    id: \.dimension
                ) { meter in
                    ScoreMeterRow(meter: meter, rationale: grade.scores[meter.dimension].rationale)
                }
            }
        } else {
            Text("no grade yet")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .help("The plugin writes a grade on each UserPromptSubmit and Stop hook.")
        }
    }

    // MARK: - Token economics
    //
    // §9.3 originally hid this row below token_row_pct. It is now always
    // rendered and merely de-emphasized under the threshold: "how close am I
    // to a compact?" is a question the user asks deliberately, and a row that
    // vanishes cannot answer it.

    private func tokenRow(_ grade: Grade) -> some View {
        let pct = percentValue(grade)
        let over = pct > tokenRowPct
        return HStack(spacing: 4) {
            Text("⚡")
            Text("\(TokenFormat.short(grade.tokensUsed)) / \(TokenFormat.short(grade.tokensLimit))")
            Text("(\(pct)%)")
                .fontWeight(over ? .semibold : .regular)
            Spacer()
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(over ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
        .help(
            """
            Context window: \(grade.tokensUsed.formatted()) of \(grade.tokensLimit.formatted()) tokens (\(pct)%).
            Highlighted above \(tokenRowPct)% ([ui].token_row_pct).
            """
        )
    }

    // MARK: - Signals disclosure
    //
    // The typesafe backend writes a `signals` block that Grade had no property
    // for, so it was decoded and discarded. Collapsed by default: it is the
    // answer to "why did it say that", not something to read every turn.

    private var signalsDisclosure: some View {
        DisclosureGroup(isExpanded: $showSignals) {
            VStack(alignment: .leading, spacing: 4) {
                if let signals = snapshot.lastGrade?.signals {
                    if let intent = signals.intent { intentRows(intent) }
                    harmRow(signals)
                    if let backend = signals.backend {
                        Text("\(backend)\(signals.model.map { " · \($0)" } ?? "")")
                            .foregroundStyle(.tertiary)
                            .help("Grader backend and model that produced this grade.")
                    }
                } else {
                    Text("This backend reports scores only — no signal breakdown.")
                        .foregroundStyle(.tertiary)
                }
                // summary_update is only shown for backends with no `signals`
                // block. The typesafe backend packs the same digest into it
                // ("intent investigate (63%); correction 4%; …"), so rendering
                // both repeats every number the rows above already show.
                if snapshot.lastGrade?.signals == nil,
                   let summary = snapshot.lastGrade?.summaryUpdate, !summary.isEmpty {
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("Rolling session summary, updated each grade.")
                }
            }
            .font(.system(size: 11))
            .padding(.top, 4)
        } label: {
            Text("Why this grade")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func intentRows(_ intent: Signals.Intent) -> some View {
        let top = intent.topIntents(limit: 3)
        if !top.isEmpty {
            ForEach(top, id: \.label) { entry in
                HStack(spacing: 6) {
                    Text(entry.label)
                        .foregroundStyle(entry.label == intent.choiceLabel ? .primary : .secondary)
                    Spacer()
                    Text(pct(entry.probability))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .help(
                """
                What the grader judged this turn was for.
                \(intent.confidence.map { "Classifier confidence \(pct($0))." } ?? "")
                """
            )
        }
    }

    @ViewBuilder
    private func harmRow(_ signals: Signals) -> some View {
        let parts: [(String, Double)] = [
            ("correction", signals.isCorrection),
            ("destructive", signals.destructive),
            ("bypass", signals.bypass),
        ].compactMap { name, value in value.map { (name, $0) } }

        // Two columns, not one row: four monospaced label+value pairs do not
        // fit across 320pt and wrap mid-word ("destructi / ve 1%").
        let cells: [(String, String)] = parts.map { ($0.0, pct($0.1)) }
            + (signals.severity.map { [("severity", "\(String(format: "%.1f", $0))/3")] } ?? [])

        if !cells.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                ForEach(Array(stride(from: 0, to: cells.count, by: 2)), id: \.self) { index in
                    GridRow {
                        harmCell(cells[index])
                        if index + 1 < cells.count { harmCell(cells[index + 1]) }
                    }
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
            .help(
                """
                Harm signals for this turn.
                correction — the prompt is correcting the agent.
                destructive — the turn asks for a destructive action.
                bypass — the turn asks to route around a guardrail.
                severity — combined 0-3 scale.
                """
            )
        }
    }

    private func harmCell(_ cell: (String, String)) -> some View {
        HStack(spacing: 4) {
            Text(cell.0)
            Text(cell.1).foregroundStyle(.secondary)
        }
        .frame(width: 136, alignment: .leading)
    }

    // MARK: - Rationale

    private var dominantLine: String? {
        guard let grade = snapshot.lastGrade else { return nil }
        switch snapshot.state {
        case .attention:
            return grade.dominantSignal.flatMap { rationale(for: $0, grade: grade) }
        case .dizzy:
            switch grade.dominantSignal {
            case .loop:
                return "Loop detected. Same file edited in consecutive turns."
            case .contextPressure:
                return "Context pressure: tokens used > threshold."
            default:
                return grade.summaryUpdate
            }
        case .celebrate:
            return "Sustained quality streak."
        case .heart:
            return "Got it."
        case .busy, .idle, .sleep:
            return grade.summaryUpdate
        }
    }

    private func rationale(for signal: DominantSignal, grade: Grade) -> String? {
        switch signal {
        case .confidence: return grade.scores.confidence.rationale
        case .atomicity: return grade.scores.atomicity.rationale
        case .drift: return grade.scores.drift.rationale
        case .pollution: return grade.scores.pollution.rationale
        case .loop, .contextPressure: return nil
        }
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button("Ack") { onAck() }
                .keyboardShortcut("a", modifiers: [])
                .help("Acknowledge this state (A).\nRecords an ack in feedback.jsonl and returns the buddy to idle.")
            if showMuteButton {
                Button(muteLabel) { onMute() }
                    .keyboardShortcut("m", modifiers: [])
                    .help("Stop surfacing this signal for the rest of the session (M).\nRecorded in feedback.jsonl; other signals still fire.")
            }
            Button("Open inspector") { onOpenInspector() }
                .keyboardShortcut("i", modifiers: [])
                .help("Open this project's session folder in Finder (I).\nContains last.json, history.jsonl, suggestions.md and per-turn grades.")
            Spacer()
        }
        .font(.system(size: 12))
    }

    private var showMuteButton: Bool {
        // Per §9.3: mute hidden in celebrate / heart states.
        switch snapshot.state {
        case .celebrate, .heart, .idle, .sleep, .busy: return false
        case .attention, .dizzy: return true
        }
    }

    private var muteLabel: String {
        let signal = snapshot.lastGrade?.dominantSignal?.rawValue ?? "signal"
        return "Mute \"\(signal)\""
    }

    // MARK: - Formatting

    private var emoji: String {
        switch snapshot.state {
        case .sleep: return "💤"
        case .idle: return "⚪"
        case .busy: return "🔄"
        case .attention: return "🟡"
        case .celebrate: return "✨"
        case .dizzy: return "🌀"
        case .heart: return "💖"
        }
    }

    private var stateHelp: String {
        switch snapshot.state {
        case .sleep: return "No graded session recently. The buddy is idle until the plugin writes a grade."
        case .idle: return "All four scores are within their thresholds."
        case .busy: return "A turn is in flight."
        case .attention: return "A score crossed its attention threshold — the orange meter below. Clears when the next grade brings all four back within range."
        case .celebrate: return "A sustained streak of grades with all four scores in range."
        case .dizzy: return "A mechanical signal fired: an edit loop, or context pressure."
        case .heart: return "Acknowledged."
        }
    }

    private func gradeAgeHelp(_ grade: Grade) -> String {
        let phase = grade.phase == .pre ? "before the agent replied" : "after the agent replied"
        guard let date = ISO8601DateFormatter().date(from: grade.timestamp) else {
            return "Turn \(grade.turn), graded \(phase).\n\(grade.timestamp)"
        }
        let relative = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        return "Turn \(grade.turn), graded \(phase) \(relative).\n\(date.formatted(date: .abbreviated, time: .standard))"
    }

    private func percentValue(_ grade: Grade) -> Int {
        guard grade.tokensLimit > 0 else { return 0 }
        return Int((Double(grade.tokensUsed) / Double(grade.tokensLimit)) * 100)
    }

    private func pct(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

// MARK: - ScoreMeterRow
//
// One dimension: full-word label, a bar drawing the raw score with a tick at
// the attention threshold, the value against its scale, and a marker when this
// score is the grade's dominant_signal.
//
// The bar deliberately draws the RAW value rather than "goodness" — an
// inverted bar for drift and pollution would visibly disagree with the number
// beside it. Colour carries the polarity.
struct ScoreMeterRow: View {
    let meter: ScoreMeter
    let rationale: String

    private var color: Color {
        switch meter.status {
        case .crossed: return .orange   // matches the attention icon tint, §9.1
        case .near: return .yellow
        case .ok: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(meter.dimension.displayName)
                .font(.system(size: 11))
                .foregroundStyle(meter.status == .ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
                .frame(width: 72, alignment: .leading)

            track

            Text("\(meter.value)/\(ScoreMeter.scale)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(meter.status == .ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
                .frame(width: 38, alignment: .trailing)

            Text(meter.isDriver ? "⚠" : " ")
                .font(.system(size: 10))
                .frame(width: 12)
        }
        .help(meter.tooltip(rationale: rationale))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meter.dimension.displayName) \(meter.value) out of \(ScoreMeter.scale)")
        .accessibilityValue(accessibilityStatus)
        .accessibilityHint(rationale)
    }

    private var track: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(color.opacity(meter.status == .ok ? 0.55 : 1.0))
                    .frame(width: max(2, geo.size.width * meter.fillFraction))
                // Threshold tick: the point at which this dimension starts
                // driving attention.
                Rectangle()
                    .fill(Color.primary.opacity(0.45))
                    .frame(width: 1)
                    .offset(x: geo.size.width * meter.thresholdFraction)
            }
        }
        .frame(height: 6)
    }

    private var accessibilityStatus: String {
        switch meter.status {
        case .crossed: return "past the attention threshold of \(meter.threshold)"
        case .near: return "at the attention threshold of \(meter.threshold)"
        case .ok: return "within range"
        }
    }
}
