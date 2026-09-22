import Foundation

enum Fixtures {
    /// Two distinct Claude Code responses plus a duplicated line (same message id + requestId).
    static let claudeJSONL = """
    {"type":"user","timestamp":"2026-09-21T12:00:00.000Z","message":{"role":"user","content":"hi"}}
    {"type":"assistant","timestamp":"2026-09-21T12:00:05.000Z","requestId":"req_1","sessionId":"s1","message":{"id":"msg_1","model":"claude-fable-5-1","usage":{"input_tokens":100,"cache_creation_input_tokens":1000,"cache_read_input_tokens":5000,"output_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":1000,"ephemeral_5m_input_tokens":0}}}}
    {"type":"assistant","timestamp":"2026-09-21T12:00:06.000Z","requestId":"req_1","sessionId":"s1","message":{"id":"msg_1","model":"claude-fable-5-1","usage":{"input_tokens":100,"cache_creation_input_tokens":1000,"cache_read_input_tokens":5000,"output_tokens":200,"cache_creation":{"ephemeral_1h_input_tokens":1000,"ephemeral_5m_input_tokens":0}}}}
    {"type":"assistant","timestamp":"2026-09-21T13:00:00.000Z","requestId":"req_2","sessionId":"s1","message":{"id":"msg_2","model":"claude-sonnet-5","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50}}}
    {"type":"assistant","timestamp":"2026-09-21T13:00:01.000Z","message":{"id":"msg_3","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}
    """

    /// Cumulative totals: first event is the baseline, second is +1000 input (+500 cached) +50 output.
    static let codexJSONL = """
    {"timestamp":"2026-09-21T10:00:00.000Z","type":"session_meta","payload":{"id":"x","model_provider":"openai"}}
    {"timestamp":"2026-09-21T10:00:01.000Z","type":"turn_context","payload":{"turn_id":"t1","model":"gpt-6-astra"}}
    {"timestamp":"2026-09-21T10:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"cached_input_tokens":1500,"cache_write_input_tokens":0,"output_tokens":100,"reasoning_output_tokens":10,"total_tokens":2100},"last_token_usage":{"input_tokens":2000,"cached_input_tokens":1500,"cache_write_input_tokens":0,"output_tokens":100,"reasoning_output_tokens":10,"total_tokens":2100},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":20.0,"window_minutes":300,"resets_at":1790000000},"secondary":{"used_percent":40.0,"window_minutes":10080,"resets_at":1790500000},"plan_type":"plus"}}}
    {"timestamp":"2026-09-21T10:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":21.0,"window_minutes":300,"resets_at":1790000000},"secondary":null,"plan_type":"plus"}}}
    {"timestamp":"2026-09-21T10:05:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000,"cached_input_tokens":2000,"cache_write_input_tokens":0,"output_tokens":150,"reasoning_output_tokens":10,"total_tokens":3150},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":500,"cache_write_input_tokens":0,"output_tokens":50,"reasoning_output_tokens":0,"total_tokens":1050},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":22.0,"window_minutes":300,"resets_at":1790000000},"secondary":{"used_percent":41.0,"window_minutes":10080,"resets_at":1790500000},"plan_type":"plus"}}}
    """

    static let geminiJSON = """
    {"sessionId":"g1","messages":[
      {"id":"u1","timestamp":"2026-09-21T09:00:00.000Z","type":"user","content":"hola"},
      {"id":"m1","timestamp":"2026-09-21T09:00:05.000Z","type":"gemini","content":"...","model":"gemini-2.5-pro","tokens":{"input":48999,"output":34,"cached":47458,"thoughts":21,"tool":0,"total":49054}}
    ]}
    """

    static let anthropicUsageJSON = """
    {"five_hour":{"utilization":14.0,"resets_at":"2026-09-22T17:20:00.284662+00:00"},"seven_day":{"utilization":9.0,"resets_at":"2026-09-27T17:00:00.284678+00:00"},"seven_day_opus":null,"extra_usage":{"is_enabled":false,"monthly_limit":5000,"used_credits":0.0}}
    """

    static let codexUsageJSON = """
    {"plan_type":"prolite","rate_limit":{"allowed":true,"primary_window":{"used_percent":94,"limit_window_seconds":604800,"reset_after_seconds":256642,"reset_at":1790337979},"secondary_window":null},"credits":{"has_credits":false,"balance":"0"}}
    """

    static func write(_ contents: String, name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("indicators-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
