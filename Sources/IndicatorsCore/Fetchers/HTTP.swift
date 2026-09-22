import Foundation

public enum HTTPError: Error, LocalizedError {
    case status(Int, String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .status(let code, let body):
            let snippet = body.prefix(160).replacingOccurrences(of: "\n", with: " ")
            return "HTTP \(code)\(snippet.isEmpty ? "" : ": \(snippet)")"
        case .invalidResponse: return "Invalid response"
        }
    }
}

/// Thin URLSession wrapper with a short timeout and a stable User-Agent.
public struct HTTPClient: Sendable {
    public var session: URLSession
    public var userAgent: String

    public init(session: URLSession = .shared, userAgent: String = "Indicators/1.0 (macOS; +https://github.com/jonymusky/indicators)") {
        self.session = session
        self.userAgent = userAgent
    }

    public func json(_ method: String, _ url: URL, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 20) async throws -> Any {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let body {
            request.httpBody = body
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError.status(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    public func data(_ url: URL, timeout: TimeInterval = 20) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw HTTPError.status(http.statusCode, "") }
        return data
    }
}

/// Result of asking a vendor for the account's rate-limit windows.
public struct LiveUsage: Sendable, Equatable, Codable {
    public var windows: [UsageWindow]
    public var plan: String?
    public var notes: [String]

    public init(windows: [UsageWindow], plan: String? = nil, notes: [String] = []) {
        self.windows = windows
        self.plan = plan
        self.notes = notes
    }
}

public enum CredentialError: Error, LocalizedError {
    case missing(String)
    case expired(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let hint): return hint
        case .expired(let hint): return hint
        }
    }
}
