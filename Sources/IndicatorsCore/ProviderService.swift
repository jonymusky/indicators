import Foundation

/// Builds a `ProviderSnapshot` for each provider by combining local logs, live rate limits, and admin spend.
public final class ProviderService: @unchecked Sendable {
    public var client: HTTPClient
    public private(set) var catalog: PricingCatalog
    private let caches: [Provider: ParseCache]
    private let lock = NSLock()
    private var lastLive: [Provider: (usage: LiveUsage, at: Date)] = [:]

    /// Last good live answers survive restarts (and rate limits) so the menu bar never goes blank.
    private struct LiveCacheEntry: Codable { var usage: LiveUsage; var at: Date }

    private func loadLiveCache() {
        guard let data = try? Data(contentsOf: AppPaths.liveCacheFile),
              let decoded = try? JSONDecoder().decode([String: LiveCacheEntry].self, from: data) else { return }
        lock.lock(); defer { lock.unlock() }
        for (key, entry) in decoded {
            if let provider = Provider(rawValue: key), Date().timeIntervalSince(entry.at) < 86400 * 3 {
                lastLive[provider] = (entry.usage, entry.at)
            }
        }
    }

    private func saveLiveCache() {
        lock.lock()
        let snapshot = lastLive
        lock.unlock()
        var out: [String: LiveCacheEntry] = [:]
        for (provider, value) in snapshot { out[provider.rawValue] = LiveCacheEntry(usage: value.usage, at: value.at) }
        try? FileManager.default.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(out) { try? data.write(to: AppPaths.liveCacheFile, options: .atomic) }
    }
    private var liveBackoffUntil: [Provider: Date] = [:]

    private func backoff(for provider: Provider) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return liveBackoffUntil[provider]
    }

    private func setBackoff(for provider: Provider, until: Date) {
        lock.lock(); defer { lock.unlock() }
        liveBackoffUntil[provider] = until
    }

    private func rememberLive(_ usage: LiveUsage, for provider: Provider, at: Date) {
        lock.lock()
        lastLive[provider] = (usage, at)
        lock.unlock()
        saveLiveCache()
    }

    private func recallLive(for provider: Provider) -> (usage: LiveUsage, at: Date)? {
        lock.lock(); defer { lock.unlock() }
        return lastLive[provider]
    }

    public init(client: HTTPClient = HTTPClient()) {
        self.client = client
        self.catalog = Self.loadCatalog()
        var caches: [Provider: ParseCache] = [:]
        for p in Provider.allCases { caches[p] = ParseCache(fileURL: AppPaths.cacheFile(for: p)) }
        self.caches = caches
        loadLiveCache()
    }

    private func currentCatalog() -> PricingCatalog {
        lock.lock(); defer { lock.unlock() }
        return catalog
    }

    private func setCatalog(_ fresh: PricingCatalog) {
        lock.lock(); defer { lock.unlock() }
        catalog = fresh
    }

    /// Turns transport errors into one-line, non-technical notes.
    static func describe(_ error: Error, provider: Provider) -> String {
        if case HTTPError.status(let code, _) = error {
            switch code {
            case 401, 403: return "\(provider.displayName) rejected the saved login. Sign in again in the CLI."
            case 429: return "\(provider.displayName) rate-limited the usage check; it will retry on the next refresh."
            case 500...599: return "\(provider.displayName) usage service is having trouble (HTTP \(code))."
            default: return "\(provider.displayName) usage check failed (HTTP \(code))."
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return "Offline or blocked: could not reach \(provider.displayName)." }
        return error.localizedDescription
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

        // Local logs (blocking file IO, run off the main actor). Several sources can feed one provider.
        var parsers: [LocalLogParser] = []
        switch provider {
        case .claude: parsers = [ClaudeCodeLogParser(), OpenCodeLogParser(provider: .claude)]
        case .openai: parsers = [CodexLogParser(), OpenCodeLogParser(provider: .openai)]
        case .gemini: parsers = [GeminiLogParser(), OpenCodeLogParser(provider: .gemini)]
        case .grok: parsers = [OpenCodeLogParser(provider: .grok)]
        case .cursor: parsers = []
        }
        var localLimits: LocalRateLimits?
        if !parsers.isEmpty {
            let lookback = settings.lookbackDays
            let results = await Task.detached(priority: .utility) { () -> [LocalUsageService.Result] in
                parsers.enumerated().map { index, parser in
                    let cacheURL = index == 0 ? AppPaths.cacheFile(for: provider)
                        : AppPaths.supportDirectory.appendingPathComponent("parse-cache-\(provider.rawValue)-\(index).json")
                    let cache = ParseCache(fileURL: cacheURL)
                    return LocalUsageService(parser: parser, cache: cache, lookbackDays: lookback).run(catalog: catalog, now: now)
                }
            }.value
            let found = results.filter { !$0.rootsFound.isEmpty }
            if found.isEmpty {
                if provider.localSource != "n/a" {
                    snap.notes.append("\(provider.localSource) logs not found; local cost estimate unavailable.")
                }
            } else {
                let events = found.flatMap(\.events)
                snap.local = UsageAggregator.report(events: events, catalog: catalog, now: now, filesScanned: found.reduce(0) { $0 + $1.filesScanned })
            }
            localLimits = results.compactMap(\.rateLimits).max { $0.observedAt < $1.observedAt }
        }

        // Live rate limits. After a 429 the vendor is left alone for a while.
        do {
            if let until = backoff(for: provider), until > now {
                throw HTTPError.status(429, "")
            }
            let live: LiveUsage?
            switch provider {
            case .claude: live = try await ClaudeUsageFetcher(client: client).fetch()
            case .openai: live = try await CodexUsageFetcher(client: client).fetch()
            case .gemini: live = try await GeminiQuotaFetcher(client: client).fetch()
            case .grok: live = nil
            case .cursor: live = try await CursorUsageFetcher(client: client).fetch()
            }
            if let live {
                snap.windows = live.windows
                snap.windowsSource = .liveAPI
                snap.windowsUpdatedAt = now
                snap.plan = live.plan ?? snap.plan
                snap.notes += live.notes
                rememberLive(live, for: provider, at: now)
            }
        } catch {
            if case HTTPError.status(429, _) = error, backoff(for: provider).map({ $0 <= now }) ?? true {
                setBackoff(for: provider, until: now.addingTimeInterval(15 * 60))
            }
            if let cached = recallLive(for: provider) {
                snap.windows = cached.usage.windows
                snap.windowsSource = .cachedLive
                snap.windowsUpdatedAt = cached.at
                snap.plan = cached.usage.plan ?? snap.plan
            } else if let localLimits {
                snap.windows = localLimits.windows
                snap.windowsSource = .localLog
                snap.windowsUpdatedAt = localLimits.observedAt
                snap.plan = localLimits.plan.map(CodexUsageFetcher.planName)
            }
            snap.notes.append(Self.describe(error, provider: provider))
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
            case .gemini, .cursor:
                break
            }
        } catch {
            snap.notes.append("Billing API: \(error.localizedDescription)")
        }
        return snap
    }
}
