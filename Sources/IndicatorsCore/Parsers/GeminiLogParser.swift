import Foundation

/// Reads Gemini CLI chat sessions (`~/.gemini/tmp/<project>/chats/*.json`).
///
/// Model turns carry a `tokens` object. `input` already contains `cached`, and `thoughts` are billed as
/// output, so both are normalized to the shared `TokenUsage` buckets.
public struct GeminiLogParser: LocalLogParser {
    public var provider: Provider { .gemini }
    public var fileExtensions: Set<String> { ["json"] }

    public init() {}

    public func roots(environment: [String: String], home: URL) -> [URL] {
        var roots: [URL] = []
        if let dir = environment["GEMINI_CLI_HOME"], !dir.isEmpty {
            roots.append(URL(fileURLWithPath: dir).appendingPathComponent(".gemini/tmp"))
        }
        roots.append(home.appendingPathComponent(".gemini/tmp"))
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    public func parse(file: URL) throws -> ParsedFile {
        // Only chat transcripts live under a "chats" directory; skip logs.json and tool caches.
        guard file.deletingLastPathComponent().lastPathComponent == "chats" else { return ParsedFile() }
        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = JSON.array(obj["messages"]) else { return ParsedFile() }
        var events: [UsageEvent] = []
        for case let message as [String: Any] in messages {
            guard JSON.string(message["type"]) == "gemini",
                  let tokens = JSON.dict(message["tokens"]),
                  let timestamp = JSON.date(message["timestamp"]) else { continue }
            let input = JSON.int(tokens["input"]) ?? 0
            let cached = JSON.int(tokens["cached"]) ?? 0
            let output = (JSON.int(tokens["output"]) ?? 0) + (JSON.int(tokens["thoughts"]) ?? 0)
            let usage = TokenUsage(input: max(input - cached, 0), cacheRead: cached, output: output)
            let model = JSON.string(message["model"]) ?? "gemini"
            events.append(UsageEvent(timestamp: timestamp, model: model, usage: usage, dedupKey: JSON.string(message["id"])))
        }
        return ParsedFile(events: events)
    }

    public static func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini").path)
    }
}
