import SwiftUI
import ContextBuddyCore

struct PopoverView: View {
    let snapshot: BuddyCore.Snapshot
    let tokenRowPct: Int
    let onAck: () -> Void
    let onMute: () -> Void
    let onOpenInspector: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            scoreRow
            if shouldShowTokenRow { tokenRow }
            if let line = dominantLine {
                Text(line)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actionRow
        }
        .padding(12)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(emoji)
            Text(snapshot.state.rawValue)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if let hash = snapshot.projectHash {
                Text(hash.prefix(6) + "…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var scoreRow: some View {
        HStack(spacing: 10) {
            if let scores = snapshot.lastGrade?.scores {
                Text(formatted("conf", scores.confidence.value))
                Text(formatted("atom", scores.atomicity.value))
                Text(formatted("drift", scores.drift.value))
                Text(formatted("pol", scores.pollution.value))
            } else {
                Text("no grade yet").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private var shouldShowTokenRow: Bool {
        guard let grade = snapshot.lastGrade, grade.tokensLimit > 0 else { return false }
        let pct = Int((Double(grade.tokensUsed) / Double(grade.tokensLimit)) * 100)
        return pct > tokenRowPct
    }

    private var tokenRow: some View {
        HStack {
            if let grade = snapshot.lastGrade {
                Text("⚡ \(short(grade.tokensUsed)) / \(short(grade.tokensLimit)) (\(percent(grade)))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

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

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button("Ack") { onAck() }
                .keyboardShortcut("a", modifiers: [])
            if showMuteButton {
                Button(muteLabel) { onMute() }
                    .keyboardShortcut("m", modifiers: [])
            }
            Button("Open inspector") { onOpenInspector() }
                .keyboardShortcut("i", modifiers: [])
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

    private func formatted(_ label: String, _ value: Int) -> String {
        "\(label):\(value)"
    }

    private func short(_ n: Int) -> String {
        if n >= 1000 { return "\(n / 1000)k" }
        return String(n)
    }

    private func percent(_ grade: Grade) -> String {
        guard grade.tokensLimit > 0 else { return "0%" }
        let pct = Int((Double(grade.tokensUsed) / Double(grade.tokensLimit)) * 100)
        return "\(pct)%"
    }
}
