import Foundation
import IndicatorsCore

// indicators-mcp — a local MCP server (stdio, newline-delimited JSON-RPC 2.0) that lets an agent see
// your live rate-limit headroom and costs, and ask which model to use for a task given your routing
// rules and current usage. Register it with e.g.:
//   claude mcp add indicators -- /Applications/Indicators.app/Contents/MacOS/indicators-mcp

let service = ProviderService()
let settings = AppSettings.load()
let snapshotTTL: TimeInterval = 60
var snapshotCache: (at: Date, value: [Provider: ProviderSnapshot])?

func snapshots(force: Bool = false) async -> [Provider: ProviderSnapshot] {
    if !force, let cache = snapshotCache, Date().timeIntervalSince(cache.at) < snapshotTTL { return cache.value }
    var result: [Provider: ProviderSnapshot] = [:]
    await withTaskGroup(of: ProviderSnapshot.self) { group in
        for provider in Provider.allCases { group.addTask { await service.snapshot(for: provider, settings: settings) } }
        for await snap in group { result[snap.provider] = snap }
    }
    snapshotCache = (Date(), result)
    return result
}

let iso = ISO8601DateFormatter()

func json(_ snap: ProviderSnapshot) -> [String: Any] {
    var d: [String: Any] = [
        "provider": snap.provider.rawValue,
        "name": snap.provider.displayName,
        "plan": snap.plan as Any,
        "windows": snap.windows.map { w -> [String: Any] in
            ["label": w.label, "percent_used": w.percentUsed, "resets_at": w.resetsAt.map(iso.string) as Any]
        },
        "windows_source": snap.windowsSource?.rawValue as Any,
        "notes": snap.notes,
    ]
    if let local = snap.local {
        d["local_cost_estimate"] = [
            "source": snap.provider.localSource,
            "today": local.costToday, "last_7_days": local.costLast7Days, "last_30_days": local.costLast30Days,
            "month_to_date": local.costMonthToDate,
            "tokens_today": ["input": local.tokensToday.input, "cache_read": local.tokensToday.cacheRead,
                             "cache_write": local.tokensToday.cacheWrite, "output": local.tokensToday.output],
            "models_today": local.today.map { ["model": $0.model, "cost": $0.cost, "input": $0.usage.input,
                                                "cache_read": $0.usage.cacheRead, "output": $0.usage.output] },
        ]
    }
    if let spend = snap.apiSpend {
        d["billed_spend"] = ["today": spend.today, "month_to_date": spend.monthToDate, "currency": spend.currency, "balance": spend.balance as Any]
    }
    return d
}

func json(_ c: ModelRouting.Candidate) -> [String: Any] {
    ["model": c.model, "provider": c.provider?.rawValue as Any, "available": c.available,
     "peak_percent": c.peakPercent as Any, "peak_window": c.peakWindow as Any,
     "resets_at": c.resetsAt.map(iso.string) as Any, "reason": c.reason]
}

func json(_ rule: RoutingRule) -> [String: Any] {
    ["task": rule.task, "primary": rule.primary, "fallback": rule.fallback, "threshold": rule.threshold as Any, "notes": rule.notes as Any]
}

// MARK: - Tools

struct Tool {
    let name: String
    let description: String
    let schema: [String: Any]
    let run: ([String: Any]) async throws -> Any
}

struct ToolError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func str(_ args: [String: Any], _ key: String) -> String? { (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
func num(_ v: Any?) -> Double? { (v as? Double) ?? (v as? Int).map(Double.init) ?? (v as? NSNumber)?.doubleValue }
func int(_ v: Any?) -> Int? { num(v).map(Int.init) }

let tools: [Tool] = [
    Tool(name: "get_usage",
         description: "Current AI usage per provider (Claude, OpenAI, Gemini, Grok): rate-limit windows with percent used and reset time, plan, cost estimates from local CLI logs (today, 7d, 30d, month), tokens today, and billed spend when configured. Use it to decide whether a provider has headroom before delegating work.",
         schema: ["type": "object", "properties": [
            "provider": ["type": "string", "enum": Provider.allCases.map(\.rawValue), "description": "Limit to one provider"],
            "refresh": ["type": "boolean", "description": "Bypass the 60s cache"]]],
         run: { args in
            let all = await snapshots(force: args["refresh"] as? Bool ?? false)
            if let p = str(args, "provider") {
                guard let provider = Provider(rawValue: p), let snap = all[provider] else { throw ToolError(message: "Unknown provider \(p)") }
                return json(snap)
            }
            return ["providers": Provider.allCases.compactMap { all[$0] }.map(json), "generated_at": iso.string(from: Date())]
         }),
    Tool(name: "recommend_model",
         description: "Pick the model to use for a task from the user's routing rules (~/.config/indicators/routing.json): returns the primary model unless its provider's rate-limit usage is at or above the rule's threshold, in which case the first fallback with headroom is returned. Always explains why. Call list_routing_rules to see available task names.",
         schema: ["type": "object", "required": ["task"], "properties": [
            "task": ["type": "string", "description": "Task name or tag, e.g. code-review, refactor, chat, summarize"]]],
         run: { args in
            guard let task = str(args, "task"), !task.isEmpty else { throw ToolError(message: "task is required") }
            let config = RoutingConfig.load()
            let rec = ModelRouting.recommend(task: task, config: config, snapshots: await snapshots())
            guard let chosen = rec.chosen else {
                return ["task": task, "model": NSNull(), "reason": "No routing rule matches '\(task)' and no default rule is set. Use set_routing_rule.",
                        "rules": config.rules.map(\.task)]
            }
            return ["task": task, "matched_rule": rec.matchedRule as Any, "model": chosen.model, "provider": chosen.provider?.rawValue as Any,
                    "is_fallback": chosen.model != config.rule(for: task)?.primary, "reason": chosen.reason,
                    "threshold_percent": rec.threshold, "candidates": rec.candidates.map(json)]
         }),
    Tool(name: "list_routing_rules",
         description: "List the user's model routing rules: task → primary model, fallbacks, and saturation threshold.",
         schema: ["type": "object", "properties": [:]],
         run: { _ in
            let config = RoutingConfig.load()
            return ["default_threshold_percent": config.defaultThreshold, "rules": config.rules.map(json),
                    "default_rule": config.fallbackRule.map(json) as Any, "file": RoutingConfig.fileURL.path]
         }),
    Tool(name: "set_routing_rule",
         description: "Create or update a routing rule for a task: which model to use first and which to fall back to when the primary's provider is saturated. Use task \"default\" to set the rule used when nothing else matches.",
         schema: ["type": "object", "required": ["task", "primary"], "properties": [
            "task": ["type": "string"], "primary": ["type": "string", "description": "Model id, e.g. claude-opus-5"],
            "fallback": ["type": "array", "items": ["type": "string"], "description": "Ordered fallback models"],
            "threshold": ["type": "number", "description": "Percent used at which the primary is skipped (default 90)"],
            "notes": ["type": "string"]]],
         run: { args in
            guard let task = str(args, "task"), !task.isEmpty, let primary = str(args, "primary"), !primary.isEmpty else {
                throw ToolError(message: "task and primary are required")
            }
            var config = RoutingConfig.load()
            let rule = RoutingRule(task: task, primary: primary, fallback: (args["fallback"] as? [String]) ?? [],
                                   threshold: num(args["threshold"]), notes: str(args, "notes"))
            if task.lowercased() == "default" { config.fallbackRule = rule } else { config.upsert(rule) }
            try config.save()
            return ["saved": json(rule), "file": RoutingConfig.fileURL.path]
         }),
    Tool(name: "delete_routing_rule",
         description: "Delete a routing rule by task name.",
         schema: ["type": "object", "required": ["task"], "properties": ["task": ["type": "string"]]],
         run: { args in
            guard let task = str(args, "task") else { throw ToolError(message: "task is required") }
            var config = RoutingConfig.load()
            let removed = task.lowercased() == "default" ? (config.fallbackRule != nil) : config.remove(task: task)
            if task.lowercased() == "default" { config.fallbackRule = nil }
            try config.save()
            return ["deleted": removed, "task": task]
         }),
    Tool(name: "estimate_cost",
         description: "Estimate the USD cost of a request for a model at public API list prices.",
         schema: ["type": "object", "required": ["model"], "properties": [
            "model": ["type": "string"], "input_tokens": ["type": "integer"], "output_tokens": ["type": "integer"],
            "cache_read_tokens": ["type": "integer"], "cache_write_tokens": ["type": "integer"]]],
         run: { args in
            guard let model = str(args, "model") else { throw ToolError(message: "model is required") }
            let usage = TokenUsage(input: int(args["input_tokens"]) ?? 0, cacheRead: int(args["cache_read_tokens"]) ?? 0,
                                   cacheWrite: int(args["cache_write_tokens"]) ?? 0, output: int(args["output_tokens"]) ?? 0)
            guard let price = service.catalog.price(for: model) else { throw ToolError(message: "No price known for \(model)") }
            return ["model": model, "cost_usd": price.cost(for: usage),
                    "price_per_million": ["input": price.input * 1e6, "output": price.output * 1e6,
                                          "cache_read": (price.cacheRead ?? price.input) * 1e6, "cache_write": (price.cacheWrite ?? price.input) * 1e6]]
         }),
    Tool(name: "list_models",
         description: "Models seen in your local CLI logs in the last 30 days with their spend, plus which CLIs are installed. Useful to pick realistic model ids for routing rules.",
         schema: ["type": "object", "properties": [:]],
         run: { _ in
            let all = await snapshots()
            var models: [[String: Any]] = []
            for provider in Provider.allCases {
                for m in all[provider]?.local?.today ?? [] {
                    models.append(["model": m.model, "provider": provider.rawValue, "cost_today": m.cost])
                }
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            return ["models_used_today": models,
                    "installed": ["claude_code": ClaudeCodeLogParser.isInstalled(home: home), "codex_cli": CodexLogParser.isInstalled(home: home),
                                  "gemini_cli": GeminiLogParser.isInstalled(home: home)],
                    "priced_models": service.catalog.prices.count]
         }),
]

// MARK: - JSON-RPC loop

func write(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func reply(id: Any, result: Any) { write(["jsonrpc": "2.0", "id": id, "result": result]) }
func fail(id: Any, code: Int, message: String) { write(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) }

func handle(_ msg: [String: Any]) async {
    let method = msg["method"] as? String ?? ""
    let id = msg["id"] ?? NSNull()
    let isNotification = msg["id"] == nil
    switch method {
    case "initialize":
        reply(id: id, result: [
            "protocolVersion": (msg["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "indicators", "version": "0.2.0"],
            "instructions": "Local AI usage and routing. Call get_usage for rate-limit headroom and costs; recommend_model before choosing a model for a task; set_routing_rule to store the user's preferences.",
        ])
    case "notifications/initialized", "notifications/cancelled":
        return
    case "ping":
        reply(id: id, result: [:])
    case "tools/list":
        reply(id: id, result: ["tools": tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] }])
    case "tools/call":
        let params = msg["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        guard let tool = tools.first(where: { $0.name == name }) else { fail(id: id, code: -32602, message: "Unknown tool \(name)"); return }
        do {
            let result = try await tool.run(params["arguments"] as? [String: Any] ?? [:])
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            reply(id: id, result: ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "structuredContent": result])
        } catch {
            reply(id: id, result: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
        }
    default:
        if !isNotification { fail(id: id, code: -32601, message: "Method not found: \(method)") }
    }
}

if CommandLine.arguments.contains("--help") {
    print("indicators-mcp: MCP server over stdio. Register with your agent, e.g.\n  claude mcp add indicators -- \(CommandLine.arguments[0])")
    exit(0)
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty, let data = line.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        await handle(msg)
    }
    semaphore.signal()
}
semaphore.wait()
