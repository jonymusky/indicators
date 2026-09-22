import Foundation
import SwiftUI
import IndicatorsCore

/// Owns the refresh loop and the latest snapshot for every provider.
@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var snapshots: [Provider: ProviderSnapshot] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published var settings: AppSettings {
        didSet {
            settings.save()
            if settings.refreshIntervalMinutes != oldValue.refreshIntervalMinutes { scheduleTimer() }
            if settings.enabledProviders != oldValue.enabledProviders { Task { await refresh() } }
        }
    }

    let service = ProviderService()
    private var timer: Timer?

    init() {
        settings = AppSettings.load()
        scheduleTimer()
        Task {
            await refresh()
            await service.refreshPricing()
        }
        if ProcessInfo.processInfo.environment["INDICATORS_PREVIEW"] == "1" {
            // Wait for the app to finish launching before touching AppKit windows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.openPreviewWindow() }
        }
    }

    /// Debug aid: `INDICATORS_PREVIEW=1 build/Indicators.app/Contents/MacOS/Indicators` shows the popover
    /// content in a regular window at the top-left of the screen (screenshots, UI work without Xcode).
    private func openPreviewWindow() {
        let hosting = NSHostingController(rootView: MenuContentView().environmentObject(self))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Indicators Preview"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.setFrameTopLeftPoint(NSPoint(x: 40, y: (NSScreen.main?.visibleFrame.maxY ?? 900) - 20))
        window.makeKeyAndOrderFront(nil)
        previewWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    private var previewWindow: NSWindow?

    var orderedSnapshots: [ProviderSnapshot] {
        Provider.allCases.filter { settings.enabledProviders.contains($0) }.compactMap { snapshots[$0] }
    }

    /// Compact text shown next to the menu bar icon, e.g. "Claude 14% wk · OpenAI 94% wk".
    var menuBarTitle: String {
        var parts: [String] = []
        if settings.showPercentInMenuBar {
            for snap in orderedSnapshots {
                guard let window = snap.menuBarWindow(settings.menuBarWindow) else { continue }
                let name = settings.menuBarLabelStyle == .names ? snap.provider.displayName : snap.provider.tag
                var part = "\(name) \(Format.percent(window.percentUsed))"
                // Only annotate the window when there is more than one to tell apart.
                if snap.windows.count > 1 { part += " \(window.shortTag)" }
                parts.append(part)
            }
        }
        if settings.showCostInMenuBar {
            let total = orderedSnapshots.reduce(0.0) { $0 + ($1.local?.costToday ?? 0) }
            if total > 0 { parts.append(Format.moneyShort(total)) }
        }
        return parts.joined(separator: " · ")
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let enabled = settings.enabledProviders
        let settings = self.settings
        let service = self.service
        await withTaskGroup(of: ProviderSnapshot.self) { group in
            for provider in enabled {
                group.addTask { await service.snapshot(for: provider, settings: settings) }
            }
            for await snap in group { snapshots[snap.provider] = snap }
        }
        for provider in Provider.allCases where !enabled.contains(provider) { snapshots[provider] = nil }
        lastRefresh = Date()
        isRefreshing = false
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(settings.refreshIntervalMinutes, 1) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }
}
