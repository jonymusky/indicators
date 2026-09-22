import Foundation

/// Reads OpenAI Codex CLI rollouts (`~/.codex/sessions/**/*.jsonl`).
///
/// Codex emits `token_count` events with cumulative `total_token_usage`; the per-call delta is derived from
/// consecutive totals (falling back to `last_token_usage` when the counter resets). Codex's `input_tokens`
/// already includes `cached_input_tokens`, so cached tokens are subtracted to get the uncached input.
/// The same events carry the account's rate-limit windows, which we keep as a fallback when the live
/// endpoint is unavailable.
public struct CodexLogParser: LocalLogParser {
    public var provider: Provider { .openai }
    public var fileExtensions: Set<String> { ["jsonl"] }

    public init() {}

    public func roots(environment: [String: String], home: URL) -> [URL] {
        var roots: [URL] = []
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            roots.append(URL(fileURLWithPath: codexHome).appendingPathComponent("sessions"))
        }
        roots.append(home.appendingPathComponent(".codex/sessions"))
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private struct Totals: Equatable {
        var input = 0, cached = 0, cacheWrite = 0, output = 0
        init() {}
        init(_ dict: [String: Any]) {
            input = JSON.int(dict["input_tokens"]) ?? 0
            cached = JSON.int(dict["cached_input_tokens"]) ?? 0
            cacheWrite = JSON.int(dict["cache_write_input_tokens"]) ?? 0
            output = JSON.int(dict["output_tokens"]) ?? 0
        }
        static func - (l: Totals, r: Totals) -> Totals {
            var t = Totals()
            t.input = l.input - r.input; t.cached = l.cached - r.cached
            t.cacheWrite = l.cacheWrite - r.cacheWrite; t.output = l.output - r.output
            return t
        }
        var isMonotonic: Bool { input >= 0 && cached >= 0 && cacheWrite >= 0 && output >= 0 }
        var usage: TokenUsage {
            TokenUsage(input: max(input - cached, 0), cacheRead: cached, cacheWrite: cacheWrite, output: output)
        }
    }

    public func parse(file: URL) throws -> ParsedFile {
        let reader = try LineReader(url: file)
        var events: [UsageEvent] = []
        var model = "unknown"
        var previous = Totals()
        var rateLimits: LocalRateLimits?
        reader.forEachLine { line in
            // Cheap prefilter before JSON decoding.
            guard line.range(of: Data("token_count".utf8)) != nil
                    || line.range(of: Data("turn_context".utf8)) != nil
                    || line.range(of: Data("session_meta".utf8)) != nil else { return }
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = JSON.string(obj["type"]),
                  let payload = JSON.dict(obj["payload"]) else { return }
            switch type {
            case "turn_context", "session_meta":
                if let m = JSON.string(payload["model"]), !m.isEmpty { model = m }
            case "event_msg":
                guard JSON.string(payload["type"]) == "token_count",
                      let timestamp = JSON.date(obj["timestamp"]) else { return }
                if let info = JSON.dict(payload["info"]), let totalDict = JSON.dict(info["total_token_usage"]) {
                    let total = Totals(totalDict)
                    var delta = total - previous
                    if !delta.isMonotonic, let last = JSON.dict(info["last_token_usage"]) {
                        delta = Totals(last)
                    }
                    previous = total
                    let usage = delta.usage
                    if !usage.isEmpty {
                        events.append(UsageEvent(timestamp: timestamp, model: model, usage: usage))
                    }
                }
                if let limits = JSON.dict(payload["rate_limits"]) {
                    let parsed = Self.windows(from: limits)
                    if !parsed.isEmpty {
                        rateLimits = LocalRateLimits(windows: parsed, plan: JSON.string(limits["plan_type"]), observedAt: timestamp)
                    }
                }
            default:
                return
            }
        }
        return ParsedFile(events: events, rateLimits: rateLimits)
    }

    static func windows(from limits: [String: Any]) -> [UsageWindow] {
        var result: [UsageWindow] = []
        for key in ["primary", "secondary"] {
            guard let w = JSON.dict(limits[key]), let percent = JSON.double(w["used_percent"]) else { continue }
            let minutes = JSON.int(w["window_minutes"]) ?? 0
            result.append(UsageWindow(label: WindowLabel.fromMinutes(minutes), percentUsed: percent, resetsAt: JSON.date(w["resets_at"])))
        }
        return result
    }

    public static func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path)
    }
}

public enum WindowLabel {
    public static func fromMinutes(_ minutes: Int) -> String {
        fromSeconds(minutes * 60)
    }

    public static func fromSeconds(_ seconds: Int) -> String {
        switch seconds {
        case 0: return "Window"
        case ..<3600: return "\(seconds / 60)m window"
        case ..<86400: return "\(seconds / 3600)h window"
        case 86400..<604800: return "\(seconds / 86400)d window"
        case 604800: return "Weekly"
        default: return "\(seconds / 86400)d window"
        }
    }
}
