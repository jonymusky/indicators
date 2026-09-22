import XCTest
@testable import IndicatorsCore

final class ParserTests: XCTestCase {
    func testClaudeParserDedupsAndSkipsSynthetic() throws {
        let dir = try Fixtures.tempDir()
        let file = try Fixtures.write(Fixtures.claudeJSONL, name: "p/s.jsonl", in: dir)
        let parsed = try ClaudeCodeLogParser().parse(file: file)
        XCTAssertEqual(parsed.events.count, 3) // duplicate is kept here; dedup happens in aggregation
        let report = UsageAggregator.report(events: parsed.events, catalog: .bundled, now: parsed.events[0].timestamp)
        XCTAssertEqual(report.today.count, 2)
        let fable = try XCTUnwrap(report.today.first { $0.model == "claude-fable-5-1" })
        XCTAssertEqual(fable.usage.input, 100)
        XCTAssertEqual(fable.usage.cacheWrite1h, 1000)
        XCTAssertEqual(report.tokensToday.total, 100 + 1000 + 5000 + 200 + 10 + 50)
        XCTAssertTrue(report.unpricedModels.isEmpty)
    }

    func testCodexParserUsesCumulativeDeltas() throws {
        let dir = try Fixtures.tempDir()
        let file = try Fixtures.write(Fixtures.codexJSONL, name: "2026/09/21/rollout.jsonl", in: dir)
        let parsed = try CodexLogParser().parse(file: file)
        XCTAssertEqual(parsed.events.count, 2)
        XCTAssertEqual(parsed.events[0].model, "gpt-6-astra")
        XCTAssertEqual(parsed.events[0].usage, TokenUsage(input: 500, cacheRead: 1500, output: 100))
        XCTAssertEqual(parsed.events[1].usage, TokenUsage(input: 500, cacheRead: 500, output: 50))
        let limits = try XCTUnwrap(parsed.rateLimits)
        XCTAssertEqual(limits.plan, "plus")
        XCTAssertEqual(limits.windows.map(\.label), ["5h window", "Weekly"])
        XCTAssertEqual(limits.windows[0].percentUsed, 22)
        XCTAssertEqual(limits.windows[1].percentUsed, 41)
    }

    func testGeminiParserNormalizesBuckets() throws {
        let dir = try Fixtures.tempDir()
        let file = try Fixtures.write(Fixtures.geminiJSON, name: "hash/chats/session.json", in: dir)
        let parsed = try GeminiLogParser().parse(file: file)
        XCTAssertEqual(parsed.events.count, 1)
        XCTAssertEqual(parsed.events[0].model, "gemini-2.5-pro")
        XCTAssertEqual(parsed.events[0].usage, TokenUsage(input: 48999 - 47458, cacheRead: 47458, output: 34 + 21))
        // Files outside a chats/ directory are ignored.
        let other = try Fixtures.write(Fixtures.geminiJSON, name: "hash/logs.json", in: dir)
        XCTAssertEqual(try GeminiLogParser().parse(file: other).events.count, 0)
    }

    func testLocalUsageServiceUsesCacheAndLookback() throws {
        let dir = try Fixtures.tempDir()
        _ = try Fixtures.write(Fixtures.claudeJSONL, name: "projects/a/s.jsonl", in: dir)
        struct Parser: LocalLogParser {
            let root: URL
            var provider: Provider { .claude }
            var fileExtensions: Set<String> { ["jsonl"] }
            func roots(environment: [String: String], home: URL) -> [URL] { [root] }
            func parse(file: URL) throws -> ParsedFile { try ClaudeCodeLogParser().parse(file: file) }
        }
        let cache = ParseCache(fileURL: dir.appendingPathComponent("cache.json"))
        let service = LocalUsageService(parser: Parser(root: dir.appendingPathComponent("projects")), cache: cache)
        let now = DateParsing.iso8601("2026-09-21T20:00:00Z")!
        let first = service.run(catalog: .bundled, now: now)
        XCTAssertEqual(first.report.filesScanned, 1)
        XCTAssertEqual(first.report.today.count, 2)
        XCTAssertGreaterThan(first.report.costToday, 0)
        XCTAssertEqual(first.report.costLast7Days, first.report.costToday)
        // Second run comes from cache and yields the same report.
        let second = LocalUsageService(parser: Parser(root: dir.appendingPathComponent("projects")),
                                       cache: ParseCache(fileURL: dir.appendingPathComponent("cache.json"))).run(catalog: .bundled, now: now)
        XCTAssertEqual(second.report, first.report)
        // A "now" far in the future puts the events outside every window.
        let later = service.run(catalog: .bundled, now: now.addingTimeInterval(86400 * 40))
        XCTAssertEqual(later.report.costLast30Days, 0)
    }

    func testAggregatorWindows() {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 12))!
        let usage = TokenUsage(input: 1_000_000)
        let events = [
            UsageEvent(timestamp: now, model: "claude-sonnet-5", usage: usage),
            UsageEvent(timestamp: cal.date(byAdding: .day, value: -3, to: now)!, model: "claude-sonnet-5", usage: usage),
            UsageEvent(timestamp: cal.date(byAdding: .day, value: -10, to: now)!, model: "claude-sonnet-5", usage: usage),
            UsageEvent(timestamp: cal.date(byAdding: .day, value: -40, to: now)!, model: "claude-sonnet-5", usage: usage),
        ]
        let report = UsageAggregator.report(events: events, catalog: .bundled, now: now, calendar: cal)
        let unit = PricingCatalog.bundled.cost(model: "claude-sonnet-5", usage: usage)!
        XCTAssertEqual(report.costToday, unit, accuracy: 1e-9)
        XCTAssertEqual(report.costLast7Days, 2 * unit, accuracy: 1e-9)
        XCTAssertEqual(report.costLast30Days, 3 * unit, accuracy: 1e-9)
        XCTAssertEqual(report.costMonthToDate, 3 * unit, accuracy: 1e-9)
    }
}
