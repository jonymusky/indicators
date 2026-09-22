import SwiftUI
import ServiceManagement
import IndicatorsCore

enum SettingsTab: Hashable {
    case general, keys, about
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        TabView(selection: $store.settingsTab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            KeysSettings().tabItem { Label("Billing APIs", systemImage: "key") }.tag(SettingsTab.keys)
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .frame(width: 480)
        .frame(minHeight: 440)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}

struct GeneralSettings: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var launchAtLogin = ViewState(SMAppService.mainApp.status == .enabled)
    @StateObject private var loginError = ViewState<String?>(nil)

    var body: some View {
        Form {
            Section("Providers") {
                ForEach(Provider.allCases) { provider in
                    Toggle(isOn: binding(for: provider)) {
                        HStack(spacing: 8) {
                            ProviderGlyph(provider: provider, size: 18)
                            Text(provider.displayName)
                            Text(sourceHint(provider)).foregroundStyle(.secondary).font(.caption)
                        }
                    }
                }
            }
            Section("Menu bar") {
                Toggle("Show usage percentages", isOn: $store.settings.showPercentInMenuBar)
                Picker("Provider labels", selection: $store.settings.menuBarLabelStyle) {
                    ForEach(MenuBarLabelStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Percentage shown", selection: $store.settings.menuBarWindow) {
                    ForEach(MenuBarWindow.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Show time until reset", isOn: $store.settings.showResetInMenuBar)
                Toggle("Show today's estimated cost", isOn: $store.settings.showCostInMenuBar)
                Picker("Refresh every", selection: $store.settings.refreshIntervalMinutes) {
                    Text("1 minute").tag(1)
                    Text("2 minutes").tag(2)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("30 minutes").tag(30)
                }
            }
            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin.value)
                    .onChange(of: launchAtLogin.value) { _, enabled in toggleLogin(enabled) }
                if let error = loginError.value {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
    }

    private func sourceHint(_ provider: Provider) -> String {
        switch provider {
        case .claude: return "Claude Code session + logs"
        case .openai: return "Codex CLI session + logs"
        case .gemini: return "Gemini CLI session + logs"
        case .grok: return "xAI Management API only"
        }
    }

    private func binding(for provider: Provider) -> Binding<Bool> {
        Binding(
            get: { store.settings.enabledProviders.contains(provider) },
            set: { on in
                if on { store.settings.enabledProviders.insert(provider) } else { store.settings.enabledProviders.remove(provider) }
            }
        )
    }

    private func toggleLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError.value = nil
        } catch {
            loginError.value = "Could not update login item: \(error.localizedDescription). Move Indicators.app to /Applications and try again."
            launchAtLogin.value = SMAppService.mainApp.status == .enabled
        }
    }
}

struct KeysSettings: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var values = ViewState<[KeychainStore.Key: String]>([:])
    @StateObject private var saved = ViewState(false)

    var body: some View {
        Form {
            Section {
                Text("Optional. These keys read your organization's real invoiced spend straight from each vendor's billing API. They are stored in your macOS Keychain and only ever sent to that vendor.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Anthropic") {
                SecureField("sk-ant-admin…", text: field(.anthropicAdminKey))
                Text("Admin API key from console.anthropic.com → Settings → Admin keys.").font(.caption).foregroundStyle(.secondary)
            }
            Section("OpenAI") {
                SecureField("sk-admin…", text: field(.openaiAdminKey))
                Text("Admin key from platform.openai.com → Organization → Admin keys.").font(.caption).foregroundStyle(.secondary)
            }
            Section("xAI (Grok)") {
                SecureField("Management API key", text: field(.xaiManagementKey))
                TextField("Team ID", text: field(.xaiTeamID))
                Text("Both from console.x.ai → Team → Management keys.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Spacer()
                    if saved.value { Text("Saved").font(.caption).foregroundStyle(.secondary) }
                    Button("Save & refresh") { save() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { load() }
    }

    private func field(_ key: KeychainStore.Key) -> Binding<String> {
        Binding(get: { values.value[key] ?? "" }, set: { values.value[key] = $0; saved.value = false })
    }

    private func load() {
        for key in KeychainStore.Key.allCases { values.value[key] = KeychainStore.get(key) ?? "" }
    }

    private func save() {
        for key in KeychainStore.Key.allCases { KeychainStore.set(values.value[key], for: key) }
        saved.value = true
        Task { await store.refresh() }
    }
}

struct AboutSettings: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Indicators").font(.title2.weight(.semibold))
            Text("AI usage & cost in your menu bar").foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 6) {
                Text("Pricing table: \(store.service.catalog.prices.count) models, LiteLLM snapshot \(store.service.catalog.generatedOn)")
                Text("Local logs are read-only. No telemetry. Credentials never leave your machine except to their own vendor.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            Link("github.com/jonymusky/indicators", destination: URL(string: "https://github.com/jonymusky/indicators")!)
                .font(.caption)
        }
        .padding(24)
    }
}
