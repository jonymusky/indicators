import XCTest
@testable import IndicatorsCore

final class NewSourcesTests: XCTestCase {
    func testOpenCodeParserFeedsTheRightProvider() throws {
        let dir = try Fixtures.tempDir()
        let json = """
        {"id":"msg_1","role":"assistant","sessionID":"ses_1","providerID":"anthropic","modelID":"claude-sonnet-5",
         "tokens":{"input":1200,"output":300,"reasoning":50,"cache":{"read":8000,"write":400}},"cost":0.01,
         "time":{"created":1790000000000,"completed":1790000005000}}
        """
        let file = try Fixtures.write(json, name: "ses_1/msg_1.json", in: dir)
        let claude = try OpenCodeLogParser(provider: .claude).parse(file: file)
        XCTAssertEqual(claude.events.count, 1)
        XCTAssertEqual(claude.events[0].usage, TokenUsage(input: 1200, cacheRead: 8000, cacheWrite: 400, output: 350))
        XCTAssertEqual(claude.events[0].dedupKey, "msg_1")
        XCTAssertEqual(try OpenCodeLogParser(provider: .openai).parse(file: file).events.count, 0)
        XCTAssertEqual(OpenCodeLogParser.provider(forProviderID: "google"), .gemini)
    }

    func testCursorUsageParsing() throws {
        let json = """
        {"gpt-4":{"numRequests":320,"numRequestsTotal":320,"numTokens":1,"maxRequestUsage":500,"maxTokenUsage":null},
         "gpt-3.5-turbo":{"numRequests":10,"maxRequestUsage":null},"startOfMonth":"2026-09-01T00:00:00.000Z"}
        """
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let usage = CursorUsageFetcher.parse(obj)
        XCTAssertEqual(usage.windows.count, 1)
        XCTAssertEqual(usage.windows[0].percentUsed, 64, accuracy: 1e-9)
        XCTAssertTrue(usage.windows[0].label.hasPrefix("Premium requests"))
        XCTAssertNotNil(usage.windows[0].resetsAt)
    }

    func testCursorSummaryParsing() throws {
        let json = """
        {"billingCycleStart":"2026-09-10T00:00:00.000Z","billingCycleEnd":"2026-10-10T00:00:00.000Z","membershipType":"pro","isUnlimited":0,
         "individualUsage":{"plan":{"enabled":1,"used":1450,"limit":2000,"remaining":550,"totalPercentUsed":72.5,"apiPercentUsed":60,"autoPercentUsed":12.5},
                            "onDemand":{"enabled":1,"used":320,"limit":null,"remaining":null}}}
        """
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let usage = CursorUsageFetcher.parseSummary(obj)
        XCTAssertEqual(usage.plan, "Pro")
        XCTAssertEqual(usage.windows.count, 2)
        XCTAssertEqual(usage.windows[0].label, "Plan usage ($14.50 of $20)")
        XCTAssertEqual(usage.windows[0].percentUsed, 72.5, accuracy: 1e-9)
        XCTAssertEqual(usage.windows[1].label, "On-demand spend $3.20 (no limit)")
        XCTAssertNotNil(usage.windows[0].resetsAt)
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("0.3.0", than: "0.2.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2.0-beta", than: "0.2.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.2.1", than: "0.2"))
        XCTAssertEqual(UpdateChecker.normalize("v0.2.0"), "0.2.0")
    }

    func testCursorJWTSubject() {
        // header.payload.signature with payload {"sub":"auth0|user_abc"}
        let payload = Data(#"{"sub":"auth0|user_abc"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(CursorUsageFetcher.userID(fromJWT: "h.\(payload).s"), "user_abc")
        XCTAssertNil(CursorUsageFetcher.userID(fromJWT: "nope"))
    }

    func testDailyCostsSeries() {
        let cal = Calendar.current
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 12))!
        let usage = TokenUsage(input: 1_000_000)
        let events = [UsageEvent(timestamp: now, model: "claude-sonnet-5", usage: usage),
                      UsageEvent(timestamp: cal.date(byAdding: .day, value: -2, to: now)!, model: "claude-sonnet-5", usage: usage)]
        let report = UsageAggregator.report(events: events, catalog: .bundled, now: now, calendar: cal)
        XCTAssertEqual(report.dailyCosts.count, 30)
        XCTAssertEqual(report.dailyCosts.last?.day, "2026-09-22")
        XCTAssertGreaterThan(report.dailyCosts.last!.cost, 0)
        XCTAssertGreaterThan(report.dailyCosts[27].cost, 0)
        XCTAssertEqual(report.dailyCosts[28].cost, 0)
    }

    func testAlertsFireOnceWhenCrossing() {
        let reset = Date(timeIntervalSince1970: 1_790_000_000)
        func snap(_ pct: Double, reset: Date) -> ProviderSnapshot {
            ProviderSnapshot(provider: .claude, windows: [UsageWindow(label: "Weekly", percentUsed: pct, resetsAt: reset)])
        }
        let first = UsageAlerts.compute(previous: [.claude: snap(70, reset: reset)], current: [.claude: snap(85, reset: reset)],
                                        thresholds: [80, 95], notifyOnReset: true, alreadySent: [])
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].title, "Claude reached 80%")
        // Same state again: nothing new. Already-sent keys are also respected.
        let again = UsageAlerts.compute(previous: [.claude: snap(85, reset: reset)], current: [.claude: snap(86, reset: reset)],
                                        thresholds: [80, 95], notifyOnReset: true, alreadySent: Set(first.map(\.key)))
        XCTAssertTrue(again.isEmpty)
        // Jumping over two thresholds announces both; a reset announces once.
        let jump = UsageAlerts.compute(previous: [.claude: snap(10, reset: reset)], current: [.claude: snap(97, reset: reset)],
                                       thresholds: [80, 95], notifyOnReset: true, alreadySent: [])
        XCTAssertEqual(jump.map(\.title), ["Claude reached 80%", "Claude reached 95%"])
        let rolled = UsageAlerts.compute(previous: [.claude: snap(97, reset: reset)], current: [.claude: snap(2, reset: reset.addingTimeInterval(604800))],
                                         thresholds: [80], notifyOnReset: true, alreadySent: [])
        XCTAssertEqual(rolled.map(\.title), ["Claude Weekly reset"])
    }
}
