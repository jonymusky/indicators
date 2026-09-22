import Foundation

/// Small helpers for walking untyped JSON safely.
enum JSON {
    static func dict(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    static func array(_ value: Any?) -> [Any]? { value as? [Any] }
    static func string(_ value: Any?) -> String? { value as? String }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: return v
        case let v as Double: return Int(v)
        case let v as NSNumber: return v.intValue
        case let v as String: return Int(v)
        default: return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as NSNumber: return v.doubleValue
        case let v as String: return Double(v)
        default: return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? { value as? Bool }

    static func date(_ value: Any?) -> Date? {
        if let s = value as? String { return DateParsing.iso8601(s) }
        if let n = double(value) { return DateParsing.epoch(n) }
        return nil
    }
}

enum DateParsing {
    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func iso8601(_ s: String) -> Date? {
        withFractional.date(from: s) ?? plain.date(from: s) ?? pythonStyle(s)
    }

    /// Handles "2026-09-22T17:20:00.284662+00:00" (six fractional digits) which ISO8601DateFormatter rejects.
    private static func pythonStyle(_ s: String) -> Date? {
        guard let dot = s.firstIndex(of: "."), let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) else { return nil }
        let trimmed = String(s[..<dot]) + String(s[tz...])
        return plain.date(from: trimmed)
    }

    /// Accepts seconds or milliseconds since 1970.
    static func epoch(_ n: Double) -> Date {
        n > 1e12 ? Date(timeIntervalSince1970: n / 1000) : Date(timeIntervalSince1970: n)
    }
}

extension Calendar {
    /// Local-day key like 2026-09-22.
    func dayKey(for date: Date) -> String {
        let c = dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
