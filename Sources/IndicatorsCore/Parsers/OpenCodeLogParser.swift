import Foundation

/// Reads OpenCode message files (`~/.local/share/opencode/storage/message/<session>/<message>.json`).
///
/// OpenCode talks to many vendors, so one parser instance feeds one `Provider`: assistant messages whose
/// `providerID` maps to that provider are turned into events; the rest are ignored. `tokens.input` is
/// treated as uncached input and `tokens.reasoning` is billed as output.
public struct OpenCodeLogParser: LocalLogParser {
    public let provider: Provider
    public var fileExtensions: Set<String> { ["json"] }

    public init(provider: Provider) { self.provider = provider }

    public func roots(environment: [String: String], home: URL) -> [URL] {
        var roots: [URL] = []
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            roots.append(URL(fileURLWithPath: xdg).appendingPathComponent("opencode/storage/message"))
        }
        roots.append(home.appendingPathComponent(".local/share/opencode/storage/message"))
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    public static func provider(forProviderID id: String) -> Provider? {
        switch id.lowercased() {
        case "anthropic", "claude": return .claude
        case "openai", "azure": return .openai
        case "google", "gemini", "google-vertex", "vertex": return .gemini
        case "xai", "grok": return .grok
        default: return nil
        }
    }

    public func parse(file: URL) throws -> ParsedFile {
        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              JSON.string(obj["role"]) == "assistant",
              let providerID = JSON.string(obj["providerID"]), Self.provider(forProviderID: providerID) == provider,
              let tokens = JSON.dict(obj["tokens"]) else { return ParsedFile() }
        let cache = JSON.dict(tokens["cache"])
        let usage = TokenUsage(
            input: JSON.int(tokens["input"]) ?? 0,
            cacheRead: JSON.int(cache?["read"]) ?? 0,
            cacheWrite: JSON.int(cache?["write"]) ?? 0,
            output: (JSON.int(tokens["output"]) ?? 0) + (JSON.int(tokens["reasoning"]) ?? 0)
        )
        let time = JSON.dict(obj["time"])
        guard let timestamp = JSON.date(time?["completed"]) ?? JSON.date(time?["created"]) else { return ParsedFile() }
        let model = JSON.string(obj["modelID"]) ?? "unknown"
        return ParsedFile(events: [UsageEvent(timestamp: timestamp, model: model, usage: usage, dedupKey: JSON.string(obj["id"]))])
    }

    public static func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(".local/share/opencode").path)
    }
}
