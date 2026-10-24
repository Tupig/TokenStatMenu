import Foundation
import CoreFoundation

/// 增量分帧按字节操作：一个 UTF-8 标量可能跨越多个网络回调。
/// SSE 的 data 行以换行符拼接；comments/event/id 字段从不计入 token。
public struct StreamParser {
    public enum Format { case sse, ndjson }
    private let format: Format
    private var pending = Data()
    private var dataLines: [Data] = []
    private var eventSize = 0
    public init(format: Format) { self.format = format }

    public mutating func feed(_ bytes: Data, eof: Bool = false) throws -> [Data] {
        pending.append(bytes)
        guard pending.count <= 2_097_152 else { throw StatError.message("单个流事件过大") }
        var result: [Data] = []
        while let i = pending.firstIndex(of: 10) {
            var line = Data(pending[..<i]); pending.removeSubrange(...i)
            if line.last == 13 { line.removeLast() }
            try consume(line, into: &result)
        }
        if eof {
            if !pending.isEmpty { try consume(pending, into: &result); pending.removeAll() }
            flush(into: &result)
        }
        return result
    }
    private mutating func consume(_ line: Data, into result: inout [Data]) throws {
        if format == .ndjson { if !line.isEmpty { result.append(line) }; return }
        if line.isEmpty { flush(into: &result); return }
        if line.starts(with: Data("data:".utf8)) {
            var data = Data(line.dropFirst(5))
            if data.first == 32 { data.removeFirst() }
            eventSize += data.count
            guard eventSize <= 2_097_152 else { throw StatError.message("SSE data 事件过大") }
            dataLines.append(data)
        }
    }
    private mutating func flush(into result: inout [Data]) {
        if !dataLines.isEmpty {
            var data = Data()
            for (i, line) in dataLines.enumerated() { if i > 0 { data.append(10) }; data.append(line) }
            result.append(data)
        }
        dataLines.removeAll(keepingCapacity: true); eventSize = 0
    }
}

public struct TokenUsage: Codable, Equatable {
    public var input: Int
    public var output: Int
    public var total: Int { input + output }
    public init(input: Int, output: Int) { self.input = input; self.output = output }
}

public struct Observation {
    public var output = ""
    public var usage: TokenUsage?
    public var terminal = false
    public var failed = false
    public var serverInputTPS: Double?
    public var serverOutputTPS: Double?
    public init() {}
}

public enum TokenEstimator {
    /// 仅作启发式估算。可加的权重确保改变 chunk 边界不会改变总量。
    public static func units(_ text: String) -> Double {
        text.unicodeScalars.reduce(0) { total, s in
            total + (s.value < 128 ? 0.25 : 1.0)
        }
    }
    public static func input(_ object: [String: Any]) -> Int {
        func count(_ v: Any) -> Double {
            if let s = v as? String { return s.hasPrefix("data:") ? 0 : units(s) }
            if let a = v as? [Any] { return a.reduce(0) { $0 + count($1) } }
            if let d = v as? [String: Any] {
                return d.reduce(0) { $0 + (["image_url", "image", "images", "audio", "file_data"].contains($1.key) ? 0 : count($1.value)) }
            }
            return 0
        }
        return Int(ceil(count(object["messages"] ?? object["input"] ?? object["prompt"] ?? "") + count(object["tools"] ?? [])))
    }
}

public enum UsageDecoder {
    public static func decode(_ data: Data, streaming: Bool) throws -> Observation {
        var result = Observation()
        if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" {
            result.terminal = true; return result
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StatError.message("流返回非 JSON 对象") }
        let counts = try JSONDecoder().decode(ExactCounts.self, from: data)
        if let error = obj["error"], !(error is NSNull) { result.failed = true; result.terminal = true }
        result.usage = counts.usage
        // OpenAI Chat：流式时只统计 delta，绝不将完整的最终消息重复统计两次。
        if let choices = obj["choices"] as? [[String: Any]] {
            for choice in choices {
                let message = choice[streaming ? "delta" : "message"] as? [String: Any] ?? [:]
                result.output += message["content"] as? String ?? ""
                result.output += message["reasoning_content"] as? String ?? ""
                if let tools = message["tool_calls"] as? [[String: Any]] {
                    for tool in tools { result.output += (tool["function"] as? [String: Any])?["arguments"] as? String ?? "" }
                }
                if let reason = choice["finish_reason"] as? String, !reason.isEmpty { result.terminal = true }
            }
        }
        // OpenAI Responses：累计用量嵌套在 response.completed 中。
        if let type = obj["type"] as? String {
            if ["response.output_text.delta", "response.reasoning_text.delta", "response.reasoning_summary_text.delta", "response.function_call_arguments.delta"].contains(type) {
                result.output += obj["delta"] as? String ?? ""
            }
            if ["response.completed", "response.failed", "response.incomplete"].contains(type) {
                result.terminal = true
                result.failed = type != "response.completed"
                if let r = obj["response"] as? [String: Any], r["usage"] is [String: Any] { result.usage = counts.responseUsage }
            }
        }
        if !streaming, let output = obj["output"] as? [[String: Any]] {
            for item in output {
                for content in item["content"] as? [[String: Any]] ?? [] { result.output += content["text"] as? String ?? "" }
                result.output += item["arguments"] as? String ?? ""
            }
            if let status = obj["status"] as? String, ["failed", "incomplete"].contains(status) { result.failed = true }
        }
        // Ollama 原生 NDJSON：权威的计数与耗时出现在最后一个对象上。
        if let message = obj["message"] as? [String: Any] {
            result.output += message["content"] as? String ?? ""
            result.output += message["thinking"] as? String ?? ""
        }
        result.output += obj["response"] as? String ?? ""
        if obj["done"] as? Bool == true {
            result.terminal = true
            if let usage = counts.ollamaUsage {
                result.usage = usage
                result.serverInputTPS = serverTPS(count: usage.input, nanoseconds: obj["prompt_eval_duration"])
                result.serverOutputTPS = serverTPS(count: usage.output, nanoseconds: obj["eval_duration"])
            }
        }
        return result
    }
    // 必须直接从原始 JSON 读取 Decimal：JSONSerialization/NSNumber 已可能舍入小数计数。
    private struct ExactCounts: Decodable {
        private enum Key: String, CodingKey {
            case usage, response
            case promptTokens = "prompt_tokens", completionTokens = "completion_tokens"
            case inputTokens = "input_tokens", outputTokens = "output_tokens"
            case promptEvalCount = "prompt_eval_count", evalCount = "eval_count"
        }
        let usage: TokenUsage?
        let responseUsage: TokenUsage?
        let ollamaUsage: TokenUsage?

        init(from decoder: Decoder) throws {
            let root = try decoder.container(keyedBy: Key.self)
            usage = (try? root.nestedContainer(keyedBy: Key.self, forKey: .usage)).flatMap(Self.tokens)
            let response = try? root.nestedContainer(keyedBy: Key.self, forKey: .response)
            responseUsage = (try? response?.nestedContainer(keyedBy: Key.self, forKey: .usage)).flatMap(Self.tokens)
            ollamaUsage = Self.tokens(root, input: .promptEvalCount, output: .evalCount)
        }

        private static func tokens(_ container: KeyedDecodingContainer<Key>) -> TokenUsage? {
            tokens(container, input: container.contains(.promptTokens) ? .promptTokens : .inputTokens,
                   output: container.contains(.completionTokens) ? .completionTokens : .outputTokens)
        }

        private static func tokens(_ container: KeyedDecodingContainer<Key>, input: Key, output: Key) -> TokenUsage? {
            guard let input = count(container, key: input), let output = count(container, key: output) else { return nil }
            return TokenUsage(input: input, output: output)
        }

        private static func count(_ container: KeyedDecodingContainer<Key>, key: Key) -> Int? {
            guard var value = try? container.decode(Decimal.self, forKey: key),
                  !value.isNaN, value >= 0, value < Decimal(1_000_000_000_000) else { return nil }
            var integer = Decimal()
            NSDecimalRound(&integer, &value, 0, .down)
            guard value == integer else { return nil }
            return NSDecimalNumber(decimal: value).intValue
        }
    }

    private static func serverTPS(count: Int, nanoseconds: Any?) -> Double? {
        guard let number = nanoseconds as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let duration = number.doubleValue
        guard duration.isFinite, duration > 0 else { return nil }
        let seconds = duration / 1e9
        guard seconds.isFinite, seconds > 0 else { return nil }
        let value = Double(count) / seconds
        return value.isFinite && value >= 0 ? value : nil
    }
}
