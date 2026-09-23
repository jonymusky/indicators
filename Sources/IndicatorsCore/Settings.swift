import Foundation

/// User preferences backed by UserDefaults.
public struct AppSettings: Sendable, Equatable {
    public var refreshIntervalMinutes: Int = 5
    public var enabledProviders: Set<Provider> = Set(Provider.allCases)
    public var showPercentInMenuBar: Bool = true
    public var showCostInMenuBar: Bool = false
    public var showResetInMenuBar: Bool = false
    public var menuBarLabelStyle: MenuBarLabelStyle = .names
    public var menuBarWindow: MenuBarWindow = .peak
    public var lookbackDays: Int = 35
    public var notificationsEnabled: Bool = false
    public var notifyThresholds: [Int] = [80, 95]
    public var notifyOnReset: Bool = true

    public init() {}

    enum Keys {
        static let interval = "refreshIntervalMinutes"
        static let enabled = "enabledProviders"
        static let showPercent = "showPercentInMenuBar"
        static let showCost = "showCostInMenuBar"
        static let showReset = "showResetInMenuBar"
        static let labelStyle = "menuBarLabelStyle"
        static let window = "menuBarWindow"
        static let notify = "notificationsEnabled"
        static let thresholds = "notifyThresholds"
        static let notifyReset = "notifyOnReset"
    }

    public static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        var s = AppSettings()
        if defaults.object(forKey: Keys.interval) != nil { s.refreshIntervalMinutes = max(1, defaults.integer(forKey: Keys.interval)) }
        if let raw = defaults.stringArray(forKey: Keys.enabled) {
            s.enabledProviders = Set(raw.compactMap(Provider.init(rawValue:)))
        }
        if defaults.object(forKey: Keys.showPercent) != nil { s.showPercentInMenuBar = defaults.bool(forKey: Keys.showPercent) }
        if defaults.object(forKey: Keys.showCost) != nil { s.showCostInMenuBar = defaults.bool(forKey: Keys.showCost) }
        if defaults.object(forKey: Keys.showReset) != nil { s.showResetInMenuBar = defaults.bool(forKey: Keys.showReset) }
        if let raw = defaults.string(forKey: Keys.labelStyle), let style = MenuBarLabelStyle(rawValue: raw) { s.menuBarLabelStyle = style }
        if let raw = defaults.string(forKey: Keys.window), let window = MenuBarWindow(rawValue: raw) { s.menuBarWindow = window }
        if defaults.object(forKey: Keys.notify) != nil { s.notificationsEnabled = defaults.bool(forKey: Keys.notify) }
        if let t = defaults.array(forKey: Keys.thresholds) as? [Int], !t.isEmpty { s.notifyThresholds = t.sorted() }
        if defaults.object(forKey: Keys.notifyReset) != nil { s.notifyOnReset = defaults.bool(forKey: Keys.notifyReset) }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(refreshIntervalMinutes, forKey: Keys.interval)
        defaults.set(enabledProviders.map(\.rawValue).sorted(), forKey: Keys.enabled)
        defaults.set(showPercentInMenuBar, forKey: Keys.showPercent)
        defaults.set(showCostInMenuBar, forKey: Keys.showCost)
        defaults.set(showResetInMenuBar, forKey: Keys.showReset)
        defaults.set(menuBarLabelStyle.rawValue, forKey: Keys.labelStyle)
        defaults.set(menuBarWindow.rawValue, forKey: Keys.window)
        defaults.set(notificationsEnabled, forKey: Keys.notify)
        defaults.set(notifyThresholds, forKey: Keys.thresholds)
        defaults.set(notifyOnReset, forKey: Keys.notifyReset)
    }
}

/// How each provider is named in the menu bar.
public enum MenuBarLabelStyle: String, CaseIterable, Sendable, Codable {
    case names      // "Claude 22%"
    case initials   // "C 22%"

    public var title: String {
        switch self {
        case .names: return "Names (Claude 22%)"
        case .initials: return "Initials (C 22%)"
        }
    }
}

/// Which rate-limit window the menu bar percentage refers to.
public enum MenuBarWindow: String, CaseIterable, Sendable, Codable {
    case peak       // whichever window is closest to its limit
    case session    // the short (5-hour) window
    case weekly     // the 7-day window

    public var title: String {
        switch self {
        case .peak: return "Closest to limit"
        case .session: return "Session (5h)"
        case .weekly: return "Weekly"
        }
    }
}

public enum AppPaths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Indicators", isDirectory: true)
    }

    public static func cacheFile(for provider: Provider) -> URL {
        supportDirectory.appendingPathComponent("parse-cache-\(provider.rawValue).json")
    }

    public static var pricingFile: URL { supportDirectory.appendingPathComponent("pricing-litellm.json") }
    public static var liveCacheFile: URL { supportDirectory.appendingPathComponent("live-usage-cache.json") }
}
