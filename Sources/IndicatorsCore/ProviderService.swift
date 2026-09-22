import Foundation

/// Builds a `ProviderSnapshot` for each provider by combining local logs, live rate limits, and admin spend.
public final class ProviderService: @unchecked Sendable {
    public var client: HTTPClient
    public private(set) var catalog: PricingCatalog
    private let caches: [Provider: ParseCache]
    private let lock = NSLock()

    public init(client: HTTPClient = HTTPClient()) {
        self.client = client
        self.catalog = Self.loadCatalog()
        var caches: [Provider: ParseCache] = [:]
        for p in Provider.allCases { caches[p] = ParseCache(fileURL: AppPaths.cacheFile(for: p)) }
        self.caches = caches
    }

    private func currentCatalog() -> PricingCatalog {
        lock.lock(); defer { lock.unlock() }
        return catalog
    }

    private func setCatalog(_ fresh: PricingCatalog) {
        lock.lock(); defer { lock.unlock() }
        catalog = fresh
    }

    static func loadCatalog() -> PricingCatalog {
        if let data = try? Data(contentsOf: AppPaths.pricingFile), let cached = try? PricingCatalog.fromLiteLLM(data: data) {
            return cached
        }
        return .bundled
    }

    /// Downloads the latest LiteLLM table. Failures are silent; the bundled snapshot keeps working.
    public func refreshPricing() async {
        guard let data = try? await client.data(PricingCatalog.liteLLMURL, timeout: 30),
              let fresh = try? PricingCatalog.fromLiteLLM(data: data) else { return }
        setCatalog(fresh)
        try? FileManager.default.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: AppPaths.pricingFile, options: .atomic)
    }

    public func snapshot(for provider: Provider, settings: AppSettings, now: Date = Date()) async -> ProviderSnapshot {
        let catalog = currentCatalog()
        var snap = ProviderSnapshot(provider: provider, updatedAt: now)

        // Local logs (blocking file IO, run off the main actor).
        let parser: LocalLogParser? = {
            switch provider {
            case .claude: return ClaudeCodeLogParser()
            case .openai: return CodexLogParser()
            case .gemini: return GeminiLogParser()
            case .grok: return nil
            }
        }()
        var localLimits: LocalRateLimits?
        if let parser, let cache = caches[provider] {
            let service = LocalUsageService(parser: parser, cache: cache, lookbackDays: settings.lookbackDays)
            let result = await Task.detached(priority: .utility) { service.run(catalog: catalog, now: now) }.value
            if result.rootsFound.isEmpty {
                snap.notes.append("\(provider.localSource) logs not found; local cost estimate unavailable.")
            } else {
                snap.local = result.report
            }
            localLimits = result.rateLimits
        }

        // Live rate limits.
        do {
            let live: LiveUsage?
            switch provider {
            case .claude: live = try await ClaudeUsageFetcher(client: client).fetch()
            case .openai: live = try await CodexUsageFetcher(client: client).fetch()
            case .gemini: live = try await GeminiQuotaFetcher(client: client).fetch()
            case .grok: live = nil
            }
            if let live {
                snap.windows = live.windows
                snap.windowsSource = .liveAPI
                snap.windowsUpdatedAt = now
                snap.plan = live.plan ?? snap.plan
                snap.notes += live.notes
            }
        } catch {
            if let localLimits {
                snap.windows = localLimits.windows
                snap.windowsSource = .localLog
                snap.windowsUpdatedAt = localLimits.observedAt
                snap.plan = localLimits.plan.map(CodexUsageFetcher.planName)
            }
            snap.notes.append(error.localizedDescription)
        }
        if provider == .grok, KeychainStore.get(.xaiManagementKey) == nil {
            snap.notes.append("Add an xAI management key in Settings to see API spend and balance.")
        }

        // Vendor billing APIs (optional, keys supplied by the user).
        do {
            switch provider {
            case .claude:
                if let key = KeychainStore.get(.anthropicAdminKey) {
                    snap.apiSpend = try await AnthropicAdminFetcher(client: client).fetch(adminKey: key, now: now)
                }
            case .openai:
                if let key = KeychainStore.get(.openaiAdminKey) {
                    snap.apiSpend = try await OpenAIAdminFetcher(client: client).fetch(adminKey: key, now: now)
                }
            case .grok:
                if let key = KeychainStore.get(.xaiManagementKey), let team = KeychainStore.get(.xaiTeamID) {
                    snap.apiSpend = try await XAIBillingFetcher(client: client).fetch(managementKey: key, teamID: team, now: now)
                }
            case .gemini:
                break
            }
        } catch {
            snap.notes.append("Billing API: \(error.localizedDescription)")
        }
        return snap
    }
}
