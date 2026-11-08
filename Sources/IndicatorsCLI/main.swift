import Foundation
import IndicatorsCore

// A small command-line companion: prints the same numbers the menu bar app shows.
// Usage:
//   indicators-cli report [--json]   Local-log cost estimate per provider (like ccusage)
//   indicators-cli usage             Live rate-limit windows per provider
//   indicators-cli skills [--json] [--refresh]   Globally installed agent skills and available updates
//   indicators-cli skills find <query>           Search the skills.sh directory

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "report"
let wantsJSON = args.contains("--json")

func printReport() {
    let service = ProviderService()
    let settings = AppSettings.load()
    var output: [String: Any] = [:]
    for provider in Provider.allCases where provider != .grok {
        let parser: LocalLogParser = {
            switch provider {
            case .claude: return ClaudeCodeLogParser()
            case .openai: return CodexLogParser()
            default: return GeminiLogParser()
            }
        }()
        let cache = ParseCache(fileURL: AppPaths.cacheFile(for: provider))
        let result = LocalUsageService(parser: parser, cache: cache, lookbackDays: settings.lookbackDays).run(catalog: service.catalog)
        let r = result.report
        if wantsJSON {
            output[provider.rawValue] = [
                "costToday": r.costToday, "costLast7Days": r.costLast7Days, "costLast30Days": r.costLast30Days,
                "costMonthToDate": r.costMonthToDate, "filesScanned": r.filesScanned,
                "modelsToday": r.today.map { ["model": $0.model, "cost": $0.cost, "input": $0.usage.input, "cacheRead": $0.usage.cacheRead,
                                              "cacheWrite": $0.usage.cacheWrite, "output": $0.usage.output] },
                "unpriced": r.unpricedModels,
            ]
        } else {
            print("\(provider.displayName) (\(provider.localSource)) — \(r.filesScanned) files, roots: \(result.rootsFound.map(\.path).joined(separator: ", "))")
            print(String(format: "  today $%.2f · 7d $%.2f · 30d $%.2f · month $%.2f", r.costToday, r.costLast7Days, r.costLast30Days, r.costMonthToDate))
            for m in r.today {
                print(String(format: "  %@  $%.2f  in %d  cacheRead %d  cacheWrite %d  out %d", m.model, m.cost, m.usage.input, m.usage.cacheRead, m.usage.cacheWrite, m.usage.output))
            }
            if !r.unpricedModels.isEmpty { print("  unpriced: \(r.unpricedModels.joined(separator: ", "))") }
            if let limits = result.rateLimits {
                print("  last rate limits in log (\(limits.observedAt)): " + limits.windows.map { "\($0.label) \(Int($0.percentUsed))%" }.joined(separator: ", "))
            }
        }
    }
    if wantsJSON, let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
}

func printUsage() async {
    let service = ProviderService()
    let settings = AppSettings.load()
    for provider in Provider.allCases {
        let snap = await service.snapshot(for: provider, settings: settings)
        print("\(provider.displayName) plan=\(snap.plan ?? "-") source=\(snap.windowsSource?.rawValue ?? "-")")
        for w in snap.windows {
            print(String(format: "  %@ %.0f%% resets %@", w.label, w.percentUsed, w.resetsAt.map { "\($0)" } ?? "-"))
        }
        if let spend = snap.apiSpend { print(String(format: "  billed: today $%.2f month $%.2f", spend.today, spend.monthToDate)) }
        for note in snap.notes { print("  note: \(note)") }
    }
}

func printSkills() async {
    if args.dropFirst().first == "find" {
        let query = args.dropFirst(2).filter { !$0.hasPrefix("--") }.joined(separator: " ")
        do {
            let results = try await SkillsDirectory().search(query)
            let installed = Set(SkillsScanner().scan().map(\.name))
            for r in results {
                let mark = installed.contains(r.skillId) ? "✓" : " "
                print("\(mark) \(r.name.padding(toLength: 32, withPad: " ", startingAt: 0)) \(String(r.installs).padding(toLength: 9, withPad: " ", startingAt: 0)) npx skills add \(r.source) --skill \(r.skillId) -g")
            }
        } catch { print("search failed: \(error)") }
        return
    }
    let scanned = SkillsScanner().scan()
    let skills = await SkillUpdateChecker().check(scanned, force: args.contains("--refresh"))
    if wantsJSON {
        let encoder = JSONEncoder.isoPretty
        if let data = try? encoder.encode(skills) { print(String(decoding: data, as: UTF8.self)) }
        return
    }
    let updates = skills.filter { $0.update == .available }.count
    print("\(skills.count) skills · \(updates) update\(updates == 1 ? "" : "s") available")
    for s in skills {
        let status: String
        switch (s.kind, s.update) {
        case (.managed, .available): status = "update available"
        case (.managed, .upToDate): status = "up to date"
        case (.managed, .unknown): status = "managed"
        case (.untracked, _): status = "not in lock file"
        case (.local, _): status = "local"
        }
        let origin = s.source ?? (s.path as NSString).abbreviatingWithTildeInPath
        print("  \(s.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(status.padding(toLength: 17, withPad: " ", startingAt: 0)) \(origin)  [\(s.agents.joined(separator: ", "))]")
    }
}

switch command {
case "usage":
    let semaphore = DispatchSemaphore(value: 0)
    Task { await printUsage(); semaphore.signal() }
    semaphore.wait()
case "skills":
    let semaphore = DispatchSemaphore(value: 0)
    Task { await printSkills(); semaphore.signal() }
    semaphore.wait()
case "report":
    printReport()
default:
    print("usage: indicators-cli [report [--json] | usage | skills [--json] [--refresh] | skills find <query>]")
    exit(2)
}
