import SwiftUI
import IndicatorsCore

struct ProviderCardView: View {
    let snapshot: ProviderSnapshot
    @StateObject private var showModels = ViewState(false)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            if snapshot.windows.isEmpty {
                Text(noWindowsText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 7) {
                    ForEach(snapshot.windows) { window in
                        WindowRow(window: window)
                    }
                }
            }
            if let local = snapshot.local {
                costRow(local)
            }
            if let spend = snapshot.apiSpend {
                apiSpendRow(spend)
            }
            if let local = snapshot.local, !local.today.isEmpty {
                modelsDisclosure(local)
            }
            if !notes.isEmpty {
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.cardStroke))
    }

    private var notes: [String] {
        // Hide the "no live windows" note when local-log windows filled in.
        snapshot.notes.filter { !($0.hasPrefix("Anthropic returned") && !snapshot.windows.isEmpty) }
    }

    private var noWindowsText: String {
        switch snapshot.provider {
        case .grok: return "Grok subscription limits are not exposed by xAI."
        default: return "No rate-limit data yet."
        }
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            ProviderGlyph(provider: snapshot.provider)
            Text(snapshot.provider.displayName).font(.system(.body, weight: .semibold))
            if let plan = snapshot.plan {
                Text(plan)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            Spacer()
            if let source = snapshot.windowsSource {
                HStack(spacing: 4) {
                    Circle().fill(source == .liveAPI ? Theme.level(0) : Color.orange).frame(width: 6, height: 6)
                    Text(sourceText(source)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sourceText(_ source: WindowsSource) -> String {
        switch source {
        case .liveAPI: return "live"
        case .localLog:
            if let at = snapshot.windowsUpdatedAt { return "from log · \(Format.relative(at))" }
            return "from log"
        }
    }

    private func costRow(_ local: LocalUsageReport) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            stat("Today", Format.money(local.costToday))
            Spacer()
            stat("7 days", Format.money(local.costLast7Days))
            Spacer()
            stat("Month", Format.money(local.costMonthToDate))
            Spacer()
            stat("Tokens today", Format.tokens(local.tokensToday.total))
        }
    }

    private func apiSpendRow(_ spend: APISpend) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "creditcard").font(.caption).foregroundStyle(.secondary)
            Text("Billed by \(vendorName): today \(Format.money(spend.today)) · month \(Format.money(spend.monthToDate))")
            if let balance = spend.balance {
                Text("· balance \(Format.money(balance))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var vendorName: String {
        switch snapshot.provider {
        case .claude: return "Anthropic"
        case .openai: return "OpenAI"
        case .gemini: return "Google"
        case .grok: return "xAI"
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .rounded).weight(.semibold).monospacedDigit())
        }
    }

    private func modelsDisclosure(_ local: LocalUsageReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showModels.value.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showModels.value ? "chevron.down" : "chevron.right").font(.caption2)
                    Text("Models today · \(local.today.count)").font(.caption)
                    Spacer()
                    Text("via \(snapshot.provider.localSource)").font(.caption2).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showModels.value {
                ForEach(local.today) { model in
                    HStack {
                        Text(model.model).font(.caption.monospaced()).lineLimit(1)
                        Spacer()
                        Text("in \(Format.tokens(model.usage.input + model.usage.cacheRead + model.usage.cacheWrite)) · out \(Format.tokens(model.usage.output))")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(Format.money(model.cost)).font(.caption.monospacedDigit())
                    }
                    .padding(.leading, 14)
                }
                if !local.unpricedModels.isEmpty {
                    Text("No price for: \(local.unpricedModels.joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(.orange).padding(.leading, 14)
                }
            }
        }
    }
}

struct WindowRow: View {
    let window: UsageWindow

    var body: some View {
        HStack(spacing: 8) {
            Text(window.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
                .lineLimit(1)
            UsageBar(percent: window.percentUsed)
            Text(Format.percent(window.percentUsed))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(Theme.level(window.percentUsed))
                .frame(width: 36, alignment: .trailing)
            Text(Format.resets(window.resetsAt) ?? "")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 96, alignment: .trailing)
                .lineLimit(1)
        }
    }
}
