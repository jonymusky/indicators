import XCTest
@testable import IndicatorsCore

final class FetcherParsingTests: XCTestCase {
    func testAnthropicUsageParsing() throws {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Fixtures.anthropicUsageJSON.utf8)) as? [String: Any])
        let usage = ClaudeUsageFetcher.parse(obj)
        XCTAssertEqual(usage.windows.map(\.label), ["5h session", "Weekly"])
        XCTAssertEqual(usage.windows[0].percentUsed, 14)
        XCTAssertNotNil(usage.windows[0].resetsAt) // six-digit fractional seconds are handled
        XCTAssertTrue(usage.notes.isEmpty)
    }

    func testAnthropicLimitsArrayFallback() throws {
        let json = """
        {"limits":[{"kind":"session","percent":33,"resets_at":"2026-09-22T17:20:00Z"},{"kind":"weekly_scoped","scope":"opus","percent":18}]}
        """
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let usage = ClaudeUsageFetcher.parse(obj)
        XCTAssertEqual(usage.windows.map(\.label), ["5h session", "Weekly · opus"])
    }

    func testCodexUsageParsing() throws {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Fixtures.codexUsageJSON.utf8)) as? [String: Any])
        let usage = CodexUsageFetcher.parse(obj)
        XCTAssertEqual(usage.plan, "Pro Lite")
        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows[0].label, "Weekly")
        XCTAssertEqual(usage.windows[0].percentUsed, 94)
        XCTAssertEqual(usage.windows[0].resetsAt, Date(timeIntervalSince1970: 1790337979))
    }

    func testGeminiQuotaParsing() throws {
        let json = """
        {"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0.4,"resetTime":"2026-09-22T17:00:00Z"},
                    {"modelId":"gemini-2.5-pro","remainingFraction":0.9},
                    {"modelId":"gemini-2.5-flash","remainingFraction":1.0}]}
        """
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let usage = GeminiQuotaFetcher.parse(obj)
        XCTAssertEqual(usage.windows.map(\.label), ["gemini-2.5-flash", "gemini-2.5-pro"])
        XCTAssertEqual(usage.windows[1].percentUsed, 60, accuracy: 1e-9)
        XCTAssertEqual(usage.windows[0].percentUsed, 0, accuracy: 1e-9)
    }

    func testDateParsing() {
        XCTAssertNotNil(DateParsing.iso8601("2026-09-22T12:47:09.336Z"))
        XCTAssertNotNil(DateParsing.iso8601("2026-09-22T12:47:09Z"))
        XCTAssertNotNil(DateParsing.iso8601("2026-09-22T17:20:00.284662+00:00"))
        XCTAssertEqual(DateParsing.epoch(1_790_000_000), Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(DateParsing.epoch(1_790_000_000_000), Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testWindowLabels() {
        XCTAssertEqual(WindowLabel.fromMinutes(300), "5h window")
        XCTAssertEqual(WindowLabel.fromMinutes(10080), "Weekly")
        XCTAssertEqual(WindowLabel.fromSeconds(604800), "Weekly")
        XCTAssertEqual(WindowLabel.fromSeconds(0), "Window")
    }
}
