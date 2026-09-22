import Foundation

/// Team spend and prepaid balance from xAI's Management API. Needs a management key and the team id.
public struct XAIBillingFetcher: Sendable {
    public static let baseURL = URL(string: "https://management-api.x.ai/v1/billing/teams")!
    public var client: HTTPClient

    public init(client: HTTPClient = HTTPClient()) { self.client = client }

    public func fetch(managementKey: String, teamID: String, now: Date = Date()) async throws -> APISpend {
        let headers = ["Authorization": "Bearer \(managementKey)"]
        let team = Self.baseURL.appendingPathComponent(teamID)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let monthStart = utc.date(from: utc.dateComponents([.year, .month], from: now))!
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let body: [String: Any] = [
            "analyticsRequest": [
                "timeRange": ["startTime": fmt.string(from: monthStart), "endTime": fmt.string(from: now), "timezone": "Etc/GMT"],
                "timeUnit": "TIME_UNIT_DAY",
                "values": [["name": "usd", "aggregation": "AGGREGATION_SUM"]],
                "groupBy": [],
                "filters": [],
            ],
        ]
        let usageJSON = try await client.json("POST", team.appendingPathComponent("usage"), headers: headers,
                                              body: try JSONSerialization.data(withJSONObject: body))
        var total = 0.0
        var today = 0.0
        let todayStart = utc.startOfDay(for: now)
        if let obj = usageJSON as? [String: Any], let series = JSON.array(obj["timeSeries"]) {
            for case let s as [String: Any] in series {
                for case let point as [String: Any] in JSON.array(s["dataPoints"]) ?? [] {
                    let value = (JSON.array(point["values"]) ?? []).compactMap { JSON.double($0) }.first ?? 0
                    total += value
                    if let ts = JSON.date(point["timestamp"]), ts >= todayStart { today += value }
                }
            }
        }

        var balance: Double?
        if let balanceJSON = try? await client.json("GET", team.appendingPathComponent("prepaid/balance"), headers: headers),
           let obj = balanceJSON as? [String: Any] {
            balance = JSON.double(JSON.dict(obj["total"])?["val"])
        }
        return APISpend(today: today, monthToDate: total, balance: balance, fetchedAt: now)
    }
}
