import Foundation

/// User-defined model routing: which model to use for a task, and what to fall back to when the
/// primary model's provider is close to its rate limit. Stored at `~/.config/indicators/routing.json`.
public struct RoutingRule: Codable, Sendable, Equatable, Identifiable {
    public var id: String { task }
    /// Task name or tag, matched case-insensitively (e.g. "code-review", "refactor", "chat").
    public var task: String
    public var primary: String
    public var fallback: [String]
    /// Percent used at which the primary's provider is considered saturated. Nil → config default.
    public var threshold: Double?
    public var notes: String?

    public init(task: String, primary: String, fallback: [String] = [], threshold: Double? = nil, notes: String? = nil) {
        self.task = task
        self.primary = primary
        self.fallback = fallback
        self.threshold = threshold
        self.notes = notes
    }
}

public struct RoutingConfig: Codable, Sendable, Equatable {
    public var defaultThreshold: Double
    public var rules: [RoutingRule]
    /// Used when no rule matches the task.
    public var fallbackRule: RoutingRule?

    public init(defaultThreshold: Double = 90, rules: [RoutingRule] = [], fallbackRule: RoutingRule? = nil) {
        self.defaultThreshold = defaultThreshold
        self.rules = rules
        self.fallbackRule = fallbackRule
    }

    public static var fileURL: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("indicators/routing.json")
    }

    public static func load(from url: URL = fileURL) -> RoutingConfig {
        guard let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(RoutingConfig.self, from: data) else {
            return RoutingConfig()
        }
        return config
    }

    public func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public func rule(for task: String) -> RoutingRule? {
        let needle = task.lowercased()
        return rules.first { $0.task.lowercased() == needle }
            ?? rules.first { needle.contains($0.task.lowercased()) || $0.task.lowercased().contains(needle) }
            ?? fallbackRule
    }

    public mutating func upsert(_ rule: RoutingRule) {
        if let i = rules.firstIndex(where: { $0.task.lowercased() == rule.task.lowercased() }) {
            rules[i] = rule
        } else {
            rules.append(rule)
        }
    }

    @discardableResult
    public mutating func remove(task: String) -> Bool {
        let before = rules.count
        rules.removeAll { $0.task.lowercased() == task.lowercased() }
        return rules.count != before
    }
}

/// Maps a model name to the provider whose limits govern it.
public enum ModelRouting {
    public static func provider(for model: String) -> Provider? {
        let m = model.lowercased()
        if m.hasPrefix("claude") || m.contains("anthropic") { return .claude }
        if m.hasPrefix("gpt") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") || m.contains("codex") || m.contains("openai") { return .openai }
        if m.hasPrefix("gemini") || m.contains("google") { return .gemini }
        if m.hasPrefix("grok") || m.contains("xai") { return .grok }
        return nil
    }

    public struct Candidate: Sendable, Equatable {
        public var model: String
        public var provider: Provider?
        /// Highest usage among the provider's windows, nil when unknown.
        public var peakPercent: Double?
        public var peakWindow: String?
        public var resetsAt: Date?
        public var available: Bool
        public var reason: String
    }

    public struct Recommendation: Sendable, Equatable {
        public var task: String
        public var matchedRule: String?
        public var chosen: Candidate?
        public var candidates: [Candidate]
        public var threshold: Double
    }

    /// Walks primary → fallbacks and picks the first whose provider is below the threshold.
    /// Providers with no live data are treated as available (we only skip what we know is saturated).
    public static func recommend(task: String, config: RoutingConfig, snapshots: [Provider: ProviderSnapshot]) -> Recommendation {
        guard let rule = config.rule(for: task) else {
            return Recommendation(task: task, matchedRule: nil, chosen: nil, candidates: [], threshold: config.defaultThreshold)
        }
        let threshold = rule.threshold ?? config.defaultThreshold
        var candidates: [Candidate] = []
        for model in [rule.primary] + rule.fallback {
            let provider = provider(for: model)
            let snap = provider.flatMap { snapshots[$0] }
            let peak = snap?.peakWindow
            var candidate = Candidate(model: model, provider: provider, peakPercent: peak?.percentUsed, peakWindow: peak?.label,
                                      resetsAt: peak?.resetsAt, available: true, reason: "")
            if let peak {
                if peak.percentUsed >= threshold {
                    candidate.available = false
                    candidate.reason = "\(provider!.displayName) \(peak.label) at \(Int(peak.percentUsed))% (threshold \(Int(threshold))%)"
                } else {
                    candidate.reason = "\(provider!.displayName) \(peak.label) at \(Int(peak.percentUsed))%"
                }
            } else if let provider {
                candidate.reason = "No live limits for \(provider.displayName); assumed available"
            } else {
                candidate.reason = "Unknown provider; assumed available"
            }
            candidates.append(candidate)
        }
        let chosen = candidates.first(where: \.available) ?? candidates.first
        return Recommendation(task: task, matchedRule: rule.task, chosen: chosen, candidates: candidates, threshold: threshold)
    }
}
