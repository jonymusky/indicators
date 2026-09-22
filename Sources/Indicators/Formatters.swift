import Foundation
import IndicatorsCore

enum Format {
    static let currency: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.currencySymbol = "$"
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        return f
    }()

    static func money(_ value: Double) -> String {
        if value >= 1000 {
            currency.maximumFractionDigits = 0
            currency.minimumFractionDigits = 0
            defer { currency.maximumFractionDigits = 2; currency.minimumFractionDigits = 2 }
            return currency.string(from: NSNumber(value: value)) ?? "$0"
        }
        return currency.string(from: NSNumber(value: value)) ?? "$0.00"
    }

    static func moneyShort(_ value: Double) -> String {
        if value >= 1000 { return String(format: "$%.1fk", value / 1000) }
        if value >= 100 { return String(format: "$%.0f", value) }
        return String(format: "$%.2f", value)
    }

    static func tokens(_ n: Int) -> String {
        let v = Double(n)
        switch v {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", v / 1_000)
        case ..<1_000_000_000: return String(format: "%.1fM", v / 1_000_000)
        default: return String(format: "%.2fB", v / 1_000_000_000)
        }
    }

    static func percent(_ v: Double) -> String { String(format: "%.0f%%", v) }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<5: return "just now"
        case ..<60: return "\(seconds)s ago"
        case ..<3600: return "\(seconds / 60)m ago"
        case ..<86400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86400)d ago"
        }
    }

    static func resets(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "resetting" }
        if seconds < 3600 { return "resets in \(max(seconds / 60, 1))m" }
        if seconds < 86400 { return "resets in \(seconds / 3600)h \((seconds % 3600) / 60)m" }
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return "resets \(f.string(from: date))"
    }
}
