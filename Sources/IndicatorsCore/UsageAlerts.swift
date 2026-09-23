import Foundation

/// Decides which notifications to send when a refresh replaces the previous snapshots.
public enum UsageAlerts {
    public struct Alert: Equatable, Sendable {
        /// Stable key so the same event is never announced twice (persist the keys you have sent).
        public var key: String
        public var title: String
        public var body: String
    }

    public static func compute(previous: [Provider: ProviderSnapshot], current: [Provider: ProviderSnapshot],
                               thresholds: [Int], notifyOnReset: Bool, alreadySent: Set<String>) -> [Alert] {
        var alerts: [Alert] = []
        let iso = ISO8601DateFormatter()
        for (provider, snap) in current {
            let before = previous[provider]
            for window in snap.windows {
                let old = before?.windows.first { $0.label == window.label }
                let cycle = window.resetsAt.map(iso.string) ?? "none"
                for threshold in thresholds.sorted() {
                    let t = Double(threshold)
                    guard window.percentUsed >= t, (old?.percentUsed ?? 0) < t || old == nil else { continue }
                    let key = "\(provider.rawValue)|\(window.label)|\(threshold)|\(cycle)"
                    if alreadySent.contains(key) { continue }
                    var body = "\(window.label) is at \(Int(window.percentUsed))%."
                    if let reset = window.resetsAt { body += " Resets \(relative(reset))." }
                    alerts.append(Alert(key: key, title: "\(provider.displayName) reached \(threshold)%", body: body))
                }
                if notifyOnReset, let old, let oldReset = old.resetsAt, let newReset = window.resetsAt,
                   newReset > oldReset, old.percentUsed >= 50 {
                    let key = "\(provider.rawValue)|\(window.label)|reset|\(cycle)"
                    if !alreadySent.contains(key) {
                        alerts.append(Alert(key: key, title: "\(provider.displayName) \(window.label) reset",
                                            body: "Back to \(Int(window.percentUsed))% used."))
                    }
                }
            }
        }
        return alerts
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "now" }
        if seconds < 3600 { return "in \(max(seconds / 60, 1)) min" }
        if seconds < 86400 { return "in \(seconds / 3600) h" }
        let f = DateFormatter(); f.dateFormat = "EEE HH:mm"
        return f.string(from: date)
    }
}
