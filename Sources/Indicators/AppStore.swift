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

    /// Demo/preview hooks (see `openPreviewWindow`).
    @Published var demoExpandAll = false
    @Published var settingsTab: SettingsTab = .general

    init() {
        settings = AppSettings.load()
        scheduleTimer()
        Task {
            await refresh()
            await service.refreshPricing()
        }
        let env = ProcessInfo.processInfo.environment
        if env["INDICATORS_PREVIEW"] == "1" || env["INDICATORS_DEMO"] == "1" {
            // Wait for the app to finish launching before touching AppKit windows.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                if let appearance = env["INDICATORS_APPEARANCE"] {
                    NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
                }
                self?.openPreviewWindow()
            }
        }
        if env["INDICATORS_DEMO"] == "1" { runDemoScript() }
    }

    /// Debug aid: `INDICATORS_PREVIEW=1 build/Indicators.app/Contents/MacOS/Indicators` shows the popover
    /// content in a regular window at the top-left of the screen (screenshots, UI work without Xcode).
    private func openPreviewWindow() {
        let root = MenuContentView()
            .environmentObject(self)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Indicators Preview"
        window.styleMask = [.borderless]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        hosting.sizingOptions = [.preferredContentSize]
        // Keep the top-left corner pinned while SwiftUI grows or shrinks the content.
        let topLeft = NSPoint(x: 40, y: (NSScreen.main?.visibleFrame.maxY ?? 900) - 20)
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { _ in
            window.setFrameTopLeftPoint(topLeft)
        }
        window.setFrameTopLeftPoint(NSPoint(x: 40, y: (NSScreen.main?.visibleFrame.maxY ?? 900) - 20))
        window.makeKeyAndOrderFront(nil)
        previewWindow = window
        NSApp.activate(ignoringOtherApps: true)
        // Print the content frame in screencapture coordinates (top-left origin) so scripts can crop exactly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let screen = window.screen ?? NSScreen.main, let content = window.contentView else { return }
            let frame = window.convertToScreen(content.frame)
            let top = screen.frame.maxY - frame.maxY
            print("PREVIEW_FRAME \(Int(frame.minX)) \(Int(top)) \(Int(frame.width)) \(Int(frame.height)) WINDOW \(window.windowNumber)")
            fflush(stdout)
        }
    }

    private var previewWindow: NSWindow?

    /// `INDICATORS_DEMO=1`: scripted walkthrough used to record the README GIF.
    private func runDemoScript() {
        // Timings leave room for the first refresh, which re-parses the active session logs.
        let steps: [(Double, () -> Void)] = [
            (5.0, { [weak self] in withAnimation { self?.demoExpandAll = true } }),
            (8.0, { [weak self] in self?.showSettings(tab: .general) }),
            (11.5, { [weak self] in self?.settingsTab = .keys }),
            (15.0, { [weak self] in
                self?.closeSettings()
                withAnimation { self?.demoExpandAll = false }
            }),
        ]
        for (delay, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    }

    private var demoSettingsWindow: NSWindow?

    private func showSettings(tab: SettingsTab) {
        settingsTab = tab
        guard demoSettingsWindow == nil else { return }
        let hosting = NSHostingController(rootView: SettingsView().environmentObject(self))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Indicators Settings"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        let anchor = previewWindow?.frame ?? NSRect(x: 40, y: 400, width: 400, height: 600)
        window.setFrameTopLeftPoint(NSPoint(x: anchor.maxX + 16, y: anchor.maxY))
        window.makeKeyAndOrderFront(nil)
        demoSettingsWindow = window
        print("SETTINGS_WINDOW \(window.windowNumber)")
        fflush(stdout)
    }

    private func closeSettings() {
        demoSettingsWindow?.close()
        demoSettingsWindow = nil
    }

    var enabledProviders: [Provider] { Provider.allCases.filter { settings.enabledProviders.contains($0) } }

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
                if settings.showResetInMenuBar, let countdown = Format.countdown(window.resetsAt) { part += " ↻\(countdown)" }
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
