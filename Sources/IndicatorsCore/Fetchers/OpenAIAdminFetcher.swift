import Foundation

/// Organization spend from OpenAI's Costs API (`/v1/organization/costs`). Needs an admin key.
public struct OpenAIAdminFetcher: Sendable {
    public static let baseURL = URL(string: "https://api.openai.com/v1/organization/costs")!
    public var client: HTTPClient

    public init(client: HTTPClient = HTTPClient()) { self.client = client }

    public func fetch(adminKey: String, now: Date = Date()) async throws -> APISpend {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let monthStart = utc.date(from: utc.dateComponents([.year, .month], from: now))!
        let todayStart = utc.startOfDay(for: now)
        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "start_time", value: String(Int(monthStart.timeIntervalSince1970))),
            .init(name: "bucket_width", value: "1d"),
            .init(name: "limit", value: "31"),
        ]
        let headers = ["Authorization": "Bearer \(adminKey)"]
        var total = 0.0
        var today = 0.0
        var pageURL: URL? = components.url
        var pages = 0
        while let url = pageURL, pages < 5 {
            pages += 1
            let json = try await client.json("GET", url, headers: headers)
            guard let obj = json as? [String: Any], let data = JSON.array(obj["data"]) else { throw HTTPError.invalidResponse }
            for case let bucket as [String: Any] in data {
                let start = JSON.double(bucket["start_time"]).map { Date(timeIntervalSince1970: $0) }
                var bucketTotal = 0.0
                for case let result as [String: Any] in JSON.array(bucket["results"]) ?? [] {
                    bucketTotal += JSON.double(JSON.dict(result["amount"])?["value"]) ?? 0
                }
                total += bucketTotal
                if let start, start >= todayStart { today += bucketTotal }
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
