import Foundation

/// Per-token USD prices for one model.
public struct ModelPrice: Codable, Sendable, Equatable {
    public var provider: String?
    public var input: Double
    public var output: Double
    public var cacheRead: Double?
    public var cacheWrite: Double?
    public var cacheWrite1h: Double?

    public init(provider: String? = nil, input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil, cacheWrite1h: Double? = nil) {
        self.provider = provider
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
    }

    public func cost(for usage: TokenUsage) -> Double {
        let write1h = min(usage.cacheWrite1h, usage.cacheWrite)
        let write5m = usage.cacheWrite - write1h
        var total = Double(usage.input) * input
        total += Double(usage.output) * output
        total += Double(usage.cacheRead) * (cacheRead ?? input)
        total += Double(write5m) * (cacheWrite ?? input)
        total += Double(write1h) * (cacheWrite1h ?? cacheWrite ?? input)
        return total
    }
}

/// Model price lookup with fuzzy matching, seeded from a bundled LiteLLM snapshot and refreshable at runtime.
public struct PricingCatalog: Sendable, Equatable {
    public private(set) var prices: [String: ModelPrice]
    public var generatedOn: String

    public init(prices: [String: ModelPrice], generatedOn: String = "") {
        self.prices = prices
        self.generatedOn = generatedOn
    }

    public static let bundled: PricingCatalog = {
        let data = Data(PricingData.json.utf8)
        let prices = (try? JSONDecoder().decode([String: ModelPrice].self, from: data)) ?? [:]
        return PricingCatalog(prices: prices, generatedOn: PricingData.generatedOn)
    }()

    public static let liteLLMURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!

    /// Parses LiteLLM's full table into a catalog restricted to the vendors we track.
    public static func fromLiteLLM(data: Data) throws -> PricingCatalog {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PricingError.invalidTable
        }
        let providers: Set<String> = ["anthropic", "openai", "gemini", "xai"]
        var prices: [String: ModelPrice] = [:]
        for (key, value) in raw {
            guard let dict = value as? [String: Any],
                  let provider = dict["litellm_provider"] as? String, providers.contains(provider),
                  let mode = dict["mode"] as? String, mode == "chat" || mode == "responses",
                  let input = dict["input_cost_per_token"] as? Double,
                  let output = dict["output_cost_per_token"] as? Double else { continue }
            let name = key.contains("/") ? String(key.split(separator: "/", maxSplits: 1)[1]) : key
            if prices[name] != nil { continue }
            prices[name] = ModelPrice(
                provider: provider,
                input: input,
                output: output,
                cacheRead: dict["cache_read_input_token_cost"] as? Double,
                cacheWrite: dict["cache_creation_input_token_cost"] as? Double,
                cacheWrite1h: dict["cache_creation_input_token_cost_above_1hr"] as? Double
            )
        }
        guard !prices.isEmpty else { throw PricingError.invalidTable }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return PricingCatalog(prices: prices, generatedOn: formatter.string(from: Date()))
    }

    /// Exact match first, then provider-prefix stripping, then longest key that the model name contains.
    public func price(for model: String) -> ModelPrice? {
        var name = model.lowercased()
        if let exact = prices[name] { return exact }
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
            if let exact = prices[name] { return exact }
        }
        // Dated variants like claude-opus-5-20260101 or gpt-5.4-2026-03-05.
        var best: (key: String, price: ModelPrice)?
        for (key, price) in prices where name.hasPrefix(key) || key.hasPrefix(name) {
            if best == nil || key.count > best!.key.count { best = (key, price) }
        }
        if let best { return best.price }
        // Vendor aliases such as "gpt-5-codex-preview" -> "gpt-5-codex".
        for (key, price) in prices where name.contains(key) {
            if best == nil || key.count > best!.key.count { best = (key, price) }
        }
        return best?.price
    }

    public func cost(model: String, usage: TokenUsage) -> Double? {
        price(for: model)?.cost(for: usage)
    }
}

public enum PricingError: Error, LocalizedError {
    case invalidTable
    public var errorDescription: String? { "The pricing table could not be parsed." }
}
