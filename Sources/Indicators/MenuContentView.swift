import SwiftUI
import IndicatorsCore

struct MenuContentView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // No ScrollView here: inside a MenuBarExtra window it collapses to zero height.
            VStack(spacing: 10) {
                if store.orderedSnapshots.isEmpty {
                    emptyState
                }
                ForEach(store.orderedSnapshots) { snap in
                    ProviderCardView(snapshot: snap)
                }
            }
            .padding(12)
            Divider()
            footer
        }
        .frame(width: 400)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.33percent").font(.title3).foregroundStyle(.secondary)
            Text("Indicators").font(.headline)
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh now")
            }
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            if let last = store.lastRefresh {
                Text("Updated \(Format.relative(last))")
            } else {
                Text("Loading…")
            }
            Spacer()
            Text("Costs are API list-price estimates from local logs")
                .lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .trailing) {
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
                .padding(.trailing, 14)
                .opacity(0)
        }
        .contextMenu { Button("Quit Indicators") { NSApp.terminate(nil) } }
        .background(
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 14)
                    .keyboardShortcut("q")
            }
            .opacity(0.001)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray").font(.largeTitle).foregroundStyle(.tertiary)
            Text("No providers enabled").font(.callout)
            Text("Turn some on in Settings.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}
