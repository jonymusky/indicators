import XCTest
@testable import IndicatorsCore

final class PricingTests: XCTestCase {
    let catalog = PricingCatalog.bundled

    func testBundledCatalogLoads() {
        XCTAssertGreaterThan(catalog.prices.count, 100)
        XCTAssertNotNil(catalog.price(for: "claude-fable-5-1"))
        XCTAssertNotNil(catalog.price(for: "gpt-6-astra"))
        XCTAssertNotNil(catalog.price(for: "gemini-2.5-pro"))
    }

    func testFuzzyLookup() {
        XCTAssertEqual(catalog.price(for: "anthropic/claude-fable-5-1"), catalog.price(for: "claude-fable-5-1"))
        XCTAssertEqual(catalog.price(for: "CLAUDE-FABLE-5-1"), catalog.price(for: "claude-fable-5-1"))
        // Dated variants fall back to the base model.
        XCTAssertEqual(catalog.price(for: "claude-sonnet-5-20261231"), catalog.price(for: "claude-sonnet-5"))
        XCTAssertNil(catalog.price(for: "totally-unknown-model"))
    }

    /// Reproduces ccusage's number for one real day of Claude Code usage (2026-09-21, claude-fable-5-1).
    func testClaudeCostMatchesCcusageWith1hCache() throws {
        let usage = TokenUsage(input: 5710, cacheRead: 47_356_708, cacheWrite: 1_271_767, cacheWrite1h: 1_271_767, output: 287_302)
        let cost = try XCTUnwrap(catalog.cost(model: "claude-fable-5-1", usage: usage))
        XCTAssertEqual(cost, 51.6967, accuracy: 0.01)
    }

    /// Reproduces ccusage's number for one real day of Codex usage (2026-09-21, gpt-6-astra).
    func testCodexCostMatchesCcusage() throws {
        let usage = TokenUsage(input: 7_492_850, cacheRead: 62_601_856, cacheWrite: 0, output: 293_877)
        let cost = try XCTUnwrap(catalog.cost(model: "gpt-6-astra", usage: usage))
        XCTAssertEqual(cost, 152.2242, accuracy: 0.01)
    }

    func testFiveMinuteCacheUsesBaseWriteRate() {
        let price = ModelPrice(input: 1, output: 1, cacheRead: 0.1, cacheWrite: 1.25, cacheWrite1h: 2)
        XCTAssertEqual(price.cost(for: TokenUsage(cacheWrite: 100, cacheWrite1h: 0)), 125)
        XCTAssertEqual(price.cost(for: TokenUsage(cacheWrite: 100, cacheWrite1h: 100)), 200)
        XCTAssertEqual(price.cost(for: TokenUsage(cacheWrite: 100, cacheWrite1h: 40)), 60 * 1.25 + 40 * 2)
    }

    func testLiteLLMParsing() throws {
        let json = """
        {"gemini/gemini-9-pro":{"litellm_provider":"gemini","mode":"chat","input_cost_per_token":1e-06,"output_cost_per_token":2e-06},
         "gpt-9":{"litellm_provider":"openai","mode":"responses","input_cost_per_token":3e-06,"output_cost_per_token":4e-06,"cache_read_input_token_cost":1e-07},
         "text-embedding":{"litellm_provider":"openai","mode":"embedding","input_cost_per_token":1e-07,"output_cost_per_token":0},
         "cohere/x":{"litellm_provider":"cohere","mode":"chat","input_cost_per_token":1,"output_cost_per_token":1}}
        """
        let catalog = try PricingCatalog.fromLiteLLM(data: Data(json.utf8))
        XCTAssertEqual(catalog.prices.count, 2)
        XCTAssertEqual(catalog.price(for: "gemini-9-pro")?.input, 1e-06)
        XCTAssertEqual(catalog.price(for: "gpt-9")?.cacheRead, 1e-07)
    }
}
