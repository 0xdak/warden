import SwiftUI
import GuardCore

/// Our own palette: deep teal accent, warm amber caution, brick red danger.
enum Theme {
    static let accent = Color(red: 0.07, green: 0.50, blue: 0.50)
    static let caution = Color(red: 0.86, green: 0.55, blue: 0.10)
    static let danger = Color(red: 0.78, green: 0.22, blue: 0.20)
    static let ok = Color(red: 0.20, green: 0.58, blue: 0.36)
    static let codeBackground = Color.primary.opacity(0.06)
    static let card = Color.primary.opacity(0.04)

    static func color(_ o: EventRecord.Outcome) -> Color {
        switch o { case .allowed: ok; case .blocked: danger; case .asked: caution; case .observed: .secondary }
    }
    static func color(_ s: Severity) -> Color {
        switch s { case .low: .secondary; case .medium: caution; case .high: danger; case .critical: danger }
    }
    static func color(_ a: RuleAction) -> Color {
        switch a { case .off: .secondary; case .allow: ok; case .observe: .secondary; case .ask: caution; case .block: danger }
    }
}

struct SeverityBadge: View {
    let severity: Severity
    var body: some View {
        Text(severity.title.uppercased()).font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Theme.color(severity).opacity(0.15), in: Capsule())
            .foregroundStyle(Theme.color(severity))
    }
}

struct OutcomeBadge: View {
    let outcome: EventRecord.Outcome
    var body: some View {
        Text(outcome.title).font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Theme.color(outcome).opacity(0.14), in: Capsule())
            .foregroundStyle(Theme.color(outcome))
    }
}

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = title { Text(t).font(.headline) }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct StatTile: View {
    let value: Int
    let label: String
    var tint: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(tint).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct EventRow: View {
    let e: EventRecord
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            OutcomeBadge(outcome: e.outcome).frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.summary).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.tail)
                Text("\(e.agent.displayName) · \(e.projectName)\(e.ruleName.map { " · \($0)" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(e.ts, style: .relative).font(.caption).foregroundStyle(.secondary)
        }
    }
}

