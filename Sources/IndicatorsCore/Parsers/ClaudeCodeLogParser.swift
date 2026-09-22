import Foundation

/// Reads Claude Code session transcripts (`~/.claude/projects/**/*.jsonl`).
///
/// Each assistant line carries `message.usage` with the four token buckets. The same API response can be
/// written more than once (streaming updates), so events are deduplicated by `message.id + requestId`,
/// which is what ccusage does as well.
public struct ClaudeCodeLogParser: LocalLogParser {
    public var provider: Provider { .claude }
    public var fileExtensions: Set<String> { ["jsonl"] }

    public init() {}

    public func roots(environment: [String: String], home: URL) -> [URL] {
        var roots: [URL] = []
        if let configDir = environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty {
            for dir in configDir.split(separator: ",") {
                roots.append(URL(fileURLWithPath: String(dir)).appendingPathComponent("projects"))
            }
        }
        roots.append(home.appendingPathComponent(".claude/projects"))
        roots.append(home.appendingPathComponent(".config/claude/projects"))
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    public var supportsIncrementalParsing: Bool { true }

    public func parse(file: URL) throws -> ParsedFile {
        try parse(reader: LineReader(url: file))
    }

    public func parse(file: URL, from offset: Int) throws -> ParsedFile {
        try parse(reader: LineReader(url: file, offset: offset))
    }

    func parse(reader: LineReader) throws -> ParsedFile {
        var events: [UsageEvent] = []
        reader.forEachLine(containing: ["\"usage\"", "\"assistant\""]) { line in
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  JSON.string(obj["type"]) == "assistant",
                  let message = JSON.dict(obj["message"]),
                  let usage = JSON.dict(message["usage"]),
                  let timestamp = JSON.date(obj["timestamp"]) else { return }
            let model = JSON.string(message["model"]) ?? "unknown"
            if model == "<synthetic>" { return }
            let cacheWrite = JSON.int(usage["cache_creation_input_tokens"]) ?? 0
            let cacheDetail = JSON.dict(usage["cache_creation"])
            let write1h = JSON.int(cacheDetail?["ephemeral_1h_input_tokens"]) ?? 0
            let tokens = TokenUsage(
                input: JSON.int(usage["input_tokens"]) ?? 0,
                cacheRead: JSON.int(usage["cache_read_input_tokens"]) ?? 0,
                cacheWrite: cacheWrite,
                cacheWrite1h: min(write1h, cacheWrite),
                output: JSON.int(usage["output_tokens"]) ?? 0
            )
            var dedup: String?
            if let messageID = JSON.string(message["id"]) {
                if let requestID = JSON.string(obj["requestId"]) {
                    dedup = messageID + ":" + requestID
                } else if let session = JSON.string(obj["sessionId"]) {
                    dedup = session + ":" + messageID
                } else {
                    dedup = messageID
                }
            }
            events.append(UsageEvent(timestamp: timestamp, model: model, usage: tokens, dedupKey: dedup))
        }
        return ParsedFile(events: events)
    }

    /// Whether the transcript directory exists for this user.
    public static func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path)
    }
}
