import Foundation
import TokenStatCore

@main struct CoreChecks {
    static var failures = 0
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        if !condition() { failures += 1; print("FAIL: \(name)") }
    }
    static func json(_ string: String) -> Data { Data(string.utf8) }
    static func main() throws {
        var window = RateWindow()
        window.add(tokens: 10, at: 10); window.add(tokens: 15, at: 11)
        check(window.rate(at: 12) == 5, "5-second rate")
        check(window.rate(at: 15.1) == 3, "old bucket expires")
        check(window.rate(at: 16.1) == 0, "idle rate clears")
        var parser = StreamParser(format: .sse)
        let stream = json(": ping\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\r\n\r\ndata: [DONE]\r\n\r\n")
        var frames: [Data] = []
        for byte in stream { frames += try parser.feed(Data([byte])) }
        check(frames.count == 2, "SSE survives every UTF8/network split")
        let first = try UsageDecoder.decode(frames[0], streaming: true)
        check(first.output == "你好", "UTF8 preserved")
        check(tryDecode(frames[1]).terminal, "DONE terminal")
        var multiline = StreamParser(format: .sse)
        let parts = try multiline.feed(json("event: chunk\ndata: {\"a\":\ndata: 1}\n\n"))
        check(String(decoding: parts[0], as: UTF8.self) == "{\"a\":\n1}", "multi-line data joins")
        var ndjson = StreamParser(format: .ndjson)
        let native = try ndjson.feed(json("{\"message\":{\"content\":\"ok\"}}\n{\"done\":true,\"prompt_eval_count\":20,\"eval_count\":10,\"eval_duration\":2000000000}"), eof: true)
        check(native.count == 2, "NDJSON EOF flush")
        let ollama = try UsageDecoder.decode(native[1], streaming: true)
        check(ollama.usage?.total == 30 && ollama.serverOutputTPS == 5, "Ollama final usage and server TPS")
        let responses = try UsageDecoder.decode(json("{\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":7,\"output_tokens\":9}}}"), streaming: true)
        check(responses.terminal && responses.usage?.total == 16, "Responses final nested usage")
        let tool = try UsageDecoder.decode(json("{\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{\"arguments\":\"{}\"}}]}}]}"), streaming: true)
        check(tool.output == "{}", "tool call deltas counted")
        let nilError = try UsageDecoder.decode(json("{\"error\":null,\"choices\":[{\"message\":{\"content\":\"OK\"}}]}"), streaming: false)
        check(!nilError.failed, "null error field is not a failure")
        check(TokenEstimator.units("hello你好") == TokenEstimator.units("he") + TokenEstimator.units("llo你") + TokenEstimator.units("好"), "estimate independent of chunk boundaries")
        var config = AppConfiguration(); config.inputPrice = 1; config.outputPrice = 2
        let engine = MetricsEngine()
        let a = engine.begin(model: "m", input: 30, config: config, now: 10)
        let b = engine.begin(model: "m", input: 40, config: config, now: 10)
        engine.firstByte(a, now: 10.25)
        var delta = Observation(); delta.output = "hello你好"
        engine.observe(a, delta, now: 11)
        let before = engine.snapshot(now: 12).outputTPS
        var usage = Observation(); usage.usage = TokenUsage(input: 100, output: 50)
        engine.observe(a, usage, now: 12); engine.observe(a, usage, now: 12)
        let partial = engine.snapshot(now: 12)
        check(partial.input == 140 && partial.output == 50 && partial.active == 2, "authoritative usage replaces estimate; independent concurrent requests")
        check(partial.outputTPS == before, "usage reconciliation does not spike speed")
        engine.finish(a, success: true, now: 13)
        check(engine.finish(a, success: false, now: 14) == nil, "finish is idempotent")
        engine.finish(b, success: false, now: 14)
        let final = engine.snapshot(now: 15)
        check(final.requests == 2 && final.failures == 1 && final.active == 0, "failure and request accounting")
        check(final.outputTPS == 0 && final.input == 140, "idle and final totals")
        check(abs(final.costUSD - 0.00024) < 1e-10, "cost calculated from final usage")
        check(final.averageFirstByteMS == 250, "first-byte latency")
        let isolated = MetricsEngine()
        let old = isolated.begin(model: "old", input: 1, config: config, now: 10)
        var burst = Observation(); burst.output = String(repeating: "a", count: 80)
        isolated.observe(old, burst, now: 11)
        _ = isolated.begin(model: "waiting", input: 1, config: config, now: 12)
        isolated.finish(old, success: true, now: 12)
        check(isolated.snapshot(now: 12).outputTPS == 0, "completed request must not inflate another active request speed")
        let month = QuotaSnapshot.currentMonth()
        let quota = try QuotaSnapshot.parse(json("{\"data\":{\"used_tokens\":800,\"total_tokens\":1000,\"month\":\"\(month)\"}}"), config: config)
        check(quota.fraction == 0.8 && quota.remaining == 200, "quota mapping")
        do { _ = try QuotaSnapshot.parse(json("{}"), config: config); check(false, "missing quota should fail") } catch { check(true, "missing quota fails") }
        do { _ = try QuotaSnapshot.parse(json("{\"data\":{\"used_tokens\":1,\"month\":\"1999-01\"}}"), config: config); check(false, "stale month should fail") } catch { check(true, "stale month fails") }
        var http = HTTPDecoder()
        let raw = json("POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 7\r\n\r\n{\"a\":1}")
        var request: LocalRequest?
        for byte in raw { request = try http.feed(Data([byte])) ?? request }
        check(request?.body == json("{\"a\":1}"), "HTTP byte-split Content-Length")
        var chunks = HTTPDecoder()
        let c = try chunks.feed(json("POST /api/chat HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n"))
        check(c?.body == json("abcde"), "HTTP chunked decoding")
        do { var h = HTTPDecoder(); _ = try h.feed(json("POST / HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n")); check(false, "ambiguous framing should fail") } catch { check(true, "ambiguous framing rejected") }
        do { var h = HTTPDecoder(); _ = try h.feed(json("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n")); check(false, "negative body should fail") } catch { check(true, "negative body rejected") }
        do { var c = config; c.endpoint = "http://example.org/v1/chat/completions"; _ = try c.validated(); check(false, "remote plaintext should fail") } catch { check(true, "remote plaintext guard") }
        let url = try config.upstreamURL(for: "/v1/responses")
        check(url.path == "/v1/responses", "upstream route mapping")
        let concurrent = MetricsEngine(), prices = config
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            let id = concurrent.begin(model: "worker", input: 1, config: prices, now: 100)
            var event = Observation(); event.usage = TokenUsage(input: 7, output: 3)
            concurrent.observe(id, event, now: 101)
            concurrent.finish(id, success: true, now: 102)
        }
        let totals = concurrent.snapshot(now: 103)
        check(totals.requests == 100 && totals.input == 700 && totals.output == 300, "100 concurrent completions never lose counts")
        check(totals.active == 0 && totals.failures == 0, "all concurrent requests finalized once")
        try gatewayChecks()
        try windowQuotaChecks()
        try localCodexUsageChecks()
        print("\(checks - failures)/\(checks) checks passed")
        if failures > 0 { exit(1) }
    }
    static func tryDecode(_ data: Data) -> Observation { (try? UsageDecoder.decode(data, streaming: true)) ?? Observation() }
}
