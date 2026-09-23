import Foundation

/// The AI vendors the app tracks.
public enum Provider: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case openai
    case gemini
    case grok
    case cursor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .cursor: return "Cursor"
        }
    }

    /// One-letter tag used in the menu bar label.
    public var tag: String {
        switch self {
        case .claude: return "C"
        case .openai: return "O"
        case .gemini: return "G"
        case .grok: return "X"
        case .cursor: return "Cu"
        }
    }

    /// Where local session logs come from, for display.
    public var localSource: String {
        switch self {
        case .claude: return "Claude Code"
        case .openai: return "Codex CLI"
        case .gemini: return "Gemini CLI"
        case .grok: return "n/a"
        case .cursor: return "n/a"
        }
    }
}

/// A rate-limit window as exposed by the vendor (e.g. 5-hour session, weekly).
public struct UsageWindow: Identifiable, Sendable, Equatable, Codable {
    public var id: String { label }
    public var label: String
    /// 0...100
    public var percentUsed: Double
    public var resetsAt: Date?

    public init(label: String, percentUsed: Double, resetsAt: Date? = nil) {
        self.label = label
        self.percentUsed = min(max(percentUsed, 0), 100)
        self.resetsAt = resetsAt
    }

    /// Two-letter tag for compact display: "5h", "wk", or the first letters of the label.
    public var shortTag: String {
        let lower = label.lowercased()
        if lower.hasPrefix("5h") || lower.contains("session") || lower.hasSuffix("h window") { return "5h" }
        if lower.hasPrefix("weekly") || lower.hasPrefix("7d") { return "wk" }
        if lower.hasPrefix("extra") { return "extra" }
        return String(label.prefix(3)).lowercased()
    }

    public var isSession: Bool { shortTag == "5h" }
    public var isWeekly: Bool { shortTag == "wk" }
}

/// Token counts in the four billing buckets shared by every vendor.
public struct TokenUsage: Sendable, Equatable, Codable {
    public var input: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    /// Cache-write tokens billed at the 1-hour TTL rate (Anthropic only). Subset of `cacheWrite`.
    public var cacheWrite1h: Int
    public var output: Int

    public init(input: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, cacheWrite1h: Int = 0, output: Int = 0) {
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
        self.output = output
    }

    public var total: Int { input + cacheRead + cacheWrite + output }
    public var isEmpty: Bool { total == 0 }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
            output: lhs.output + rhs.output
        )
    }

    public static func += (lhs: inout TokenUsage, rhs: TokenUsage) { lhs = lhs + rhs }
}

/// One billable API call reconstructed from a local log.
public struct UsageEvent: Sendable, Equatable, Codable {
    public var timestamp: Date
    public var model: String
    public var usage: TokenUsage
    /// Dedup key when the log may contain the same API response twice.
    public var dedupKey: String?

    public init(timestamp: Date, model: String, usage: TokenUsage, dedupKey: String? = nil) {
        self.timestamp = timestamp
        self.model = model
        self.usage = usage
        self.dedupKey = dedupKey
    }
}

/// Aggregated usage for one model.
public struct ModelUsage: Identifiable, Sendable, Equatable, Codable {
    public var id: String { model }
    public var model: String
    public var usage: TokenUsage
    public var cost: Double

    public init(model: String, usage: TokenUsage, cost: Double) {
        self.model = model
        self.usage = usage
        self.cost = cost
    }
}

/// Costs and tokens derived from local logs, priced at public API list prices.
public struct LocalUsageReport: Sendable, Equatable, Codable {
    public var today: [ModelUsage]
    public var costToday: Double
    public var costLast7Days: Double
    public var costLast30Days: Double
    public var costMonthToDate: Double
    public var tokensToday: TokenUsage
    public var lastActivity: Date?
    public var filesScanned: Int
    /// Models seen in the window that had no price in the catalog.
    public var unpricedModels: [String]
    /// Cost per local day for the last 30 days, oldest first, zeros included.
    public var dailyCosts: [DailyCost]

    public init(today: [ModelUsage] = [], costToday: Double = 0, costLast7Days: Double = 0, costLast30Days: Double = 0,
                costMonthToDate: Double = 0, tokensToday: TokenUsage = TokenUsage(), lastActivity: Date? = nil,
                filesScanned: Int = 0, unpricedModels: [String] = [], dailyCosts: [DailyCost] = []) {
        self.dailyCosts = dailyCosts
        self.today = today
        self.costToday = costToday
        self.costLast7Days = costLast7Days
        self.costLast30Days = costLast30Days
        self.costMonthToDate = costMonthToDate
        self.tokensToday = tokensToday
        self.lastActivity = lastActivity
        self.filesScanned = filesScanned
        self.unpricedModels = unpricedModels
    }
}

public struct DailyCost: Sendable, Equatable, Codable, Identifiable {
    public var id: String { day }
    public var day: String
    public var cost: Double

    public init(day: String, cost: Double) {
        self.day = day
        self.cost = cost
    }
}

/// Spend reported by the vendor's own billing/admin API.
public struct APISpend: Sendable, Equatable, Codable {
    public var today: Double
    public var monthToDate: Double
    public var currency: String
    /// Prepaid balance where the vendor exposes one (xAI).
    public var balance: Double?
    public var fetchedAt: Date

    public init(today: Double, monthToDate: Double, currency: String = "USD", balance: Double? = nil, fetchedAt: Date = Date()) {
        self.today = today
        self.monthToDate = monthToDate
        self.currency = currency
        self.balance = balance
        self.fetchedAt = fetchedAt
    }
}

/// Where the rate-limit windows came from.
public enum WindowsSource: String, Sendable, Codable {
    case liveAPI = "live"
    /// The last successful live answer, reused because the latest request failed.
    case cachedLive = "cached"
    case localLog = "local log"
}

/// Everything the UI shows for one provider.
public struct ProviderSnapshot: Identifiable, Sendable, Equatable {
    public var id: Provider { provider }
    public var provider: Provider
    public var plan: String?
    public var windows: [UsageWindow]
    public var windowsSource: WindowsSource?
    public var windowsUpdatedAt: Date?
    public var local: LocalUsageReport?
    public var apiSpend: APISpend?
    /// Human-readable, non-fatal problems (missing credentials, expired token...).
    public var notes: [String]
    public var updatedAt: Date

    public init(provider: Provider, plan: String? = nil, windows: [UsageWindow] = [], windowsSource: WindowsSource? = nil,
                windowsUpdatedAt: Date? = nil, local: LocalUsageReport? = nil, apiSpend: APISpend? = nil,
                notes: [String] = [], updatedAt: Date = Date()) {
        self.provider = provider
        self.plan = plan
        self.windows = windows
        self.windowsSource = windowsSource
        self.windowsUpdatedAt = windowsUpdatedAt
        self.local = local
        self.apiSpend = apiSpend
        self.notes = notes
        self.updatedAt = updatedAt
    }

    /// The window closest to exhaustion, used for the menu bar label.
    public var peakWindow: UsageWindow? { windows.max(by: { $0.percentUsed < $1.percentUsed }) }

    /// Picks the window the menu bar should display, falling back to the peak one.
    public func menuBarWindow(_ preference: MenuBarWindow) -> UsageWindow? {
        switch preference {
        case .peak: return peakWindow
        case .session: return windows.first(where: \.isSession) ?? peakWindow
        case .weekly: return windows.first(where: \.isWeekly) ?? peakWindow
        }
    }
}
