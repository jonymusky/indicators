import Foundation

/// Organization spend from Anthropic's Admin API (`/v1/organizations/cost_report`). Needs an admin key (`sk-ant-admin…`).
public struct AnthropicAdminFetcher: Sendable {
    public static let baseURL = URL(string: "https://api.anthropic.com/v1/organizations/cost_report")!
    public var client: HTTPClient

    public init(client: HTTPClient = HTTPClient()) { self.client = client }

    public func fetch(adminKey: String, now: Date = Date()) async throws -> APISpend {
        let cal = Calendar(identifier: .gregorian)
        var utc = cal
        utc.timeZone = TimeZone(identifier: "UTC")!
        let monthStart = utc.date(from: utc.dateComponents([.year, .month], from: now))!
        let formatter = ISO8601DateFormatter()
        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "starting_at", value: formatter.string(from: monthStart)),
            .init(name: "bucket_width", value: "1d"),
            .init(name: "limit", value: "31"),
        ]
        let headers = ["x-api-key": adminKey, "anthropic-version": "2023-06-01"]
        var total = 0.0
        var today = 0.0
        var pageURL: URL? = components.url
        let todayKey = utc.dayKey(for: now)
        var pages = 0
        while let url = pageURL, pages < 5 {
            pages += 1
            let json = try await client.json("GET", url, headers: headers)
            guard let obj = json as? [String: Any], let data = JSON.array(obj["data"]) else { throw HTTPError.invalidResponse }
            for case let bucket as [String: Any] in data {
                let start = JSON.date(bucket["starting_at"])
                var bucketTotal = 0.0
                for case let result as [String: Any] in JSON.array(bucket["results"]) ?? [] {
                    // Amount is a decimal string in cents.
                    bucketTotal += (JSON.double(result["amount"]) ?? 0) / 100
                }
                total += bucketTotal
                if let start, utc.dayKey(for: start) == todayKey { today += bucketTotal }
            }
            if JSON.bool(obj["has_more"]) == true, let next = JSON.string(obj["next_page"]) {
                var c = components
                c.queryItems?.append(.init(name: "page", value: next))
                pageURL = c.url
            } else {
                pageURL = nil
            }
        }
        return APISpend(today: today, monthToDate: total, fetchedAt: now)
    }
}
