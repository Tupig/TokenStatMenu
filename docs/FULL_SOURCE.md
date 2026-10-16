# TokenStatMenu 完整源码

## 项目整体架构

```mermaid
flowchart LR
    Client[Codex / SDK / 其他客户端] -->|HTTP + 本机令牌| Proxy[127.0.0.1 本机代理]
    Proxy -->|企业 Key / HTTPS| API[企业网关 / OpenAI 兼容 API / Ollama]
    API -->|SSE / NDJSON / JSON 原样转发| Proxy
    Proxy --> Parser[StreamParser + UsageDecoder]
    Parser --> Engine[MetricsEngine + 5 秒滑动窗口]
    Engine --> Menu[NSStatusItem 顶部实时标题]
    Engine --> Panel[SwiftUI 弹出面板 + 10 分钟曲线]
    Quota[企业用量接口 + 独立 Key] --> Panel
    Quota --> Menu
```

选择本机转发代理是因为应用无法凭空读取其他进程的 TLS 流。它不修改系统代理，也不自动修改 Codex 或企业客户端配置。所有已存在、未经过代理的会话不计入统计。


## 分文件完整源码

### .github/workflows/build.yml

```yaml
name: macOS build
on:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
jobs:
  build:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
        with:
          persist-credentials: false
      - name: Public content guardrail
        run: python3 script/check_public_content.py --git-index
      - name: Core and gateway discovery checks
        run: swift run --build-system native TokenStatCoreChecks
      - name: Native Xcode build
        run: xcodebuild -project TokenStatMenu.xcodeproj -scheme TokenStatMenu -configuration Release -derivedDataPath /tmp/TokenStatMenu-CI CODE_SIGNING_ALLOWED=NO build
```

### Package.swift

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenStatMenu",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TokenStatMenu", targets: ["TokenStatMenu"])],
    targets: [
        .target(name: "TokenStatCore"),
        .executableTarget(name: "TokenStatMenu", dependencies: ["TokenStatCore"]),
        .executableTarget(name: "TokenStatCoreChecks", dependencies: ["TokenStatCore"], path: "Tests/TokenStatCoreTests")
    ]
)
```

### Sources/TokenStatCore/Configuration.swift

```swift
import Foundation

public struct AppConfiguration: Codable, Equatable {
    public var endpoint = "http://127.0.0.1:11434/v1/chat/completions"
    public var model = ""
    public var port = 18765
    public var includeUsage = true
    public var allowInsecureHTTP = false
    public var inputPrice = 0.0       // USD per million input tokens
    public var outputPrice = 0.0      // USD per million output tokens
    public var currency = "USD"
    public var usdToCNY = 7.0        // User-supplied reference, never called a live FX quote.
    public var monthlyLimit = 0.0
    public var usageURL = ""
    public var usedPath = "data.used_tokens"
    public var limitPath = "data.total_tokens"
    public var periodPath = "data.month"
    public var refreshSeconds = 60.0
    public var loggingEnabled = false
    public var historyEnabled = true
    public init() {}

    public func validated() throws -> AppConfiguration {
        guard (1024...65535).contains(port) else { throw StatError.message("代理端口必须为 1024–65535") }
        let url = try checkedURL(endpoint)
        let paths = ["/chat/completions", "/responses", "/api/chat", "/api/generate"]
        guard paths.contains(where: { url.path.hasSuffix($0) }) else {
            throw StatError.message("Endpoint 须以 /chat/completions、/responses、/api/chat 或 /api/generate 结尾")
        }
        if ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""), url.port == port {
            throw StatError.message("上游不能指向本机统计代理自身")
        }
        if !usageURL.isEmpty { _ = try checkedURL(usageURL) }
        for number in [inputPrice, outputPrice, monthlyLimit] {
            guard number.isFinite, number >= 0, number <= 1e15 else { throw StatError.message("价格与配额必须是有限非负数") }
        }
        guard usdToCNY.isFinite, usdToCNY > 0, usdToCNY < 1000,
              refreshSeconds.isFinite, (15...3600).contains(refreshSeconds),
              ["USD", "CNY"].contains(currency) else { throw StatError.message("请检查汇率、币种或刷新间隔（15–3600 秒）") }
        guard !usedPath.isEmpty else { throw StatError.message("已用量字段路径不能为空") }
        return self
    }

    public func checkedURL(_ string: String) throws -> URL {
        guard let url = URL(string: string), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              ["https", "http"].contains(url.scheme ?? "") else { throw StatError.message("无效 URL；密钥请填写在独立字段") }
        if url.scheme == "http", !["localhost", "127.0.0.1", "::1"].contains(host), !allowInsecureHTTP {
            throw StatError.message("远程接口应使用 HTTPS；私网 HTTP 需显式开启")
        }
        return url
    }

    /// Map the four supported local paths onto the configured upstream prefix.
    public func upstreamURL(for path: String) throws -> URL {
        let known = ["/v1/chat/completions", "/v1/responses", "/api/chat", "/api/generate"]
        guard known.contains(path) else { throw StatError.message("不支持的请求路径") }
        var parts = URLComponents(url: try checkedURL(endpoint), resolvingAgainstBaseURL: false)!
        let openAI = ["/chat/completions", "/responses"]
        if let suffix = openAI.first(where: { parts.path.hasSuffix($0) }) {
            // A provider base may be /v1 OR /enterprise/route. Preserve it exactly.
            let base = String(parts.path.dropLast(suffix.count))
            if path.hasPrefix("/v1/") { parts.path = base + String(path.dropFirst(3)) }
            else { parts.path = (base.hasSuffix("/v1") ? String(base.dropLast(3)) : base) + path }
        } else if let suffix = known.first(where: { parts.path.hasSuffix($0) }) {
            parts.path = String(parts.path.dropLast(suffix.count)) + path
        } else { throw StatError.message("无效 Endpoint 路径") }
        guard let url = parts.url else { throw StatError.message("无法生成上游 URL") }
        return url
    }
}

public enum StatError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}
```

### Sources/TokenStatCore/GatewayDiscovery.swift

```swift
import Foundation

/// Deliberately contains no authentication fields. Results stay in local UI memory.
public struct GatewayCandidate: Identifiable, Codable, Equatable {
    public var id: String { source + "|" + provider + "|" + endpoint }
    public let source: String
    public let provider: String
    public let endpoint: String
    public let model: String
    public let isActive: Bool
}

/// A small, fail-closed reader for common Codex scalar TOML settings, not a general
/// TOML parser. Only model/provider/profile/base_url/wire_api are retained. It does
/// not open auth.json, shell profiles, browser storage, databases or keychains.
public enum GatewayDiscovery {
    public static func readCodexConfig(at url: URL, source: String) -> [GatewayCandidate] {
        guard let file = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 1_048_577), data.count <= 1_048_576,
              let text = String(data: data, encoding: .utf8) else { return [] }
        return codexCandidates(text, source: source)
    }

    public static func codexCandidates(_ text: String, source: String) -> [GatewayCandidate] {
        var root: [String: String] = [:], providers: [String: [String: String]] = [:]
        var profiles: [String: [String: String]] = [:]
        var table: [String] = [], duplicates = Set<String>(), seen = Set<String>()
        var multiline: String?
        for rawLine in text.components(separatedBy: .newlines) {
            if let delimiter = multiline {
                if rawLine.contains(delimiter) { multiline = nil }
                continue
            }
            let line = withoutComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                table = line.hasSuffix("]") && !line.hasPrefix("[[")
                    ? (tablePath(String(line.dropFirst().dropLast())) ?? ["invalid"]) : ["invalid"]
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            // Skip multiline bodies even for unrecognized keys; their contents are not config.
            if let delimiter = ["\"\"\"", "'''"].first(where: { value.hasPrefix($0) }) {
                if !value.dropFirst(3).contains(delimiter) { multiline = delimiter }
                continue
            }
            let allowed: Set<String> = table.isEmpty ? ["model", "model_provider", "profile"]
                : table.first == "model_providers" && table.count == 2 ? ["base_url", "wire_api"]
                : table.first == "profiles" && table.count == 2 ? ["model", "model_provider"] : []
            guard allowed.contains(key) else { continue }
            // Duplicate values are ambiguous. Never guess which upstream should receive a key.
            let identity = table.joined(separator: ".") + ":" + key
            if !seen.insert(identity).inserted { duplicates.insert(identity) }
            guard let scalar = quotedString(value) else { duplicates.insert(identity); continue }
            if table.isEmpty { root[key] = scalar }
            else if table[0] == "model_providers" { providers[table[1], default: [:]][key] = scalar }
            else { profiles[table[1], default: [:]][key] = scalar }
        }
        guard !duplicates.contains(where: { $0.hasPrefix(":") || $0.hasPrefix("profiles.") }) else { return [] }
        let profile = root["profile"].flatMap { profiles[$0] } ?? [:]
        let selectedProvider = profile["model_provider"] ?? root["model_provider"] ?? "openai"
        let selectedModel = profile["model"] ?? root["model"] ?? ""
        return providers.compactMap { name, settings -> GatewayCandidate? in
            guard !duplicates.contains(where: { $0.hasPrefix("model_providers.\(name):") }),
                  let base = settings["base_url"] else { return nil }
            return candidate(baseURL: base, provider: name, source: source,
                model: name == selectedProvider ? selectedModel : "",
                wireAPI: settings["wire_api"] ?? "responses", isActive: name == selectedProvider)
        }.sorted { a, b in a.isActive != b.isActive ? a.isActive : a.provider < b.provider }
    }

    public static func environmentCandidates(_ environment: [String: String]) -> [GatewayCandidate] {
        var result: [GatewayCandidate] = []
        if let base = environment["OPENAI_BASE_URL"], let c = candidate(baseURL: base,
            provider: "OpenAI 兼容接口", source: "进程环境 OPENAI_BASE_URL", model: environment["OPENAI_MODEL"] ?? "", wireAPI: "chat") { result.append(c) }
        if let host = environment["OLLAMA_HOST"], !host.isEmpty {
            let base = host.contains("://") ? host : "http://" + host
            if let c = candidate(baseURL: base, provider: "Ollama", source: "进程环境 OLLAMA_HOST", wireAPI: "ollama") { result.append(c) }
        }
        return result
    }

    public static func candidate(baseURL: String, provider: String, source: String,
        model: String = "", wireAPI: String = "responses", isActive: Bool = false) -> GatewayCandidate? {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject entire URLs with embedded credentials/query/fragment, rather than stripping
        // credentials and silently turning a signed URL into a different endpoint.
        guard var url = URLComponents(string: base), ["http", "https"].contains(url.scheme ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              !url.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              ["responses", "chat", "ollama"].contains(wireAPI) else { return nil }
        while url.path.hasSuffix("/") { url.path.removeLast() }
        let suffixes = ["/chat/completions", "/responses", "/api/chat", "/api/generate"]
        if !suffixes.contains(where: { url.path.hasSuffix($0) }) {
            url.path += wireAPI == "ollama" ? "/api/chat" : wireAPI == "chat" ? "/chat/completions" : "/responses"
        }
        guard let endpoint = url.url?.absoluteString else { return nil }
        return GatewayCandidate(source: source, provider: provider, endpoint: endpoint,
            model: model, isActive: isActive)
    }

    private static func quotedString(_ value: String) -> String? {
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            let inner = String(value.dropFirst().dropLast())
            return inner.contains("'") ? nil : inner
        }
        guard value.hasPrefix("\""), value.hasSuffix("\""),
              let data = value.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String
    }
    private static func withoutComment(_ line: String) -> String {
        var quote: Character?, escaped = false, result = ""
        for c in line {
            if escaped { escaped = false; result.append(c); continue }
            if quote == "\"", c == "\\" { escaped = true; result.append(c); continue }
            if let current = quote { if c == current { quote = nil } }
            else if c == "#" { break }
            else if c == "\"" || c == "'" { quote = c }
            result.append(c)
        }
        return result
    }
    private static func tablePath(_ value: String) -> [String]? {
        var parts: [String] = [], current = "", quote: Character?, escaped = false
        for c in value {
            if escaped { escaped = false; current.append(c); continue }
            if quote == "\"", c == "\\" { escaped = true; current.append(c); continue }
            if let q = quote { if c == q { quote = nil } }
            else if c == "\"" || c == "'" { quote = c }
            else if c == "." { parts.append(current); current = ""; continue }
            current.append(c)
        }
        guard quote == nil else { return nil }
        parts.append(current)
        let parsed = parts.compactMap { part -> String? in
            let p = part.trimmingCharacters(in: .whitespaces)
            if let string = quotedString(p) { return string }
            return !p.isEmpty && p.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil ? p : nil
        }
        return parsed.count == parts.count ? parsed : nil
    }
}
```

### Sources/TokenStatCore/HTTPDecoder.swift

```swift
import Foundation

public struct LocalRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
}

/// One HTTP/1.1 request per connection. Responses advertise Connection: close.
/// Content-Length and chunked request bodies are supported; ambiguous framing is rejected.
public struct HTTPDecoder {
    private var buffer = Data()
    private var head: (String, String, [String: String])?
    private var body = Data()
    private var chunkLength: Int?
    private var trailers = false
    public init() {}
    public mutating func feed(_ data: Data) throws -> LocalRequest? {
        buffer.append(data)
        guard buffer.count + body.count <= 8_454_144 else { throw StatError.message("请求超过 8MB") }
        if head == nil {
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 65_536 { throw StatError.message("请求头超过 64KB") }; return nil
            }
            guard range.lowerBound <= 65_536,
                  let text = String(data: buffer[..<range.lowerBound], encoding: .utf8) else { throw StatError.message("无效 HTTP 请求头") }
            let lines = text.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0", first[1].hasPrefix("/"), !first[1].hasPrefix("//") else { throw StatError.message("只支持 HTTP/1.x origin-form") }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw StatError.message("无效 HTTP header") }
                let key = String(line[..<colon]).lowercased()
                guard headers[key] == nil else { throw StatError.message("拒绝重复请求头") }
                headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard headers["expect"] == nil else { throw StatError.message("请禁用 Expect 请求头") }
            if headers["content-length"] != nil && headers["transfer-encoding"] != nil { throw StatError.message("不能同时使用 Content-Length 和 Transfer-Encoding") }
            if let te = headers["transfer-encoding"], te.lowercased() != "chunked" { throw StatError.message("不支持的 Transfer-Encoding") }
            head = (String(first[0]), String(first[1]), headers)
            buffer.removeSubrange(..<range.upperBound)
        }
        guard let (method, path, headers) = head else { return nil }
        if headers["transfer-encoding"]?.lowercased() == "chunked" {
            while true {
                if trailers {
                    if buffer.starts(with: Data("\r\n".utf8)) { return LocalRequest(method: method, path: path, headers: headers, body: body) }
                    if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { return LocalRequest(method: method, path: path, headers: headers, body: body) }
                    guard buffer.count < 65_536 else { throw StatError.message("Trailer 过大") }; return nil
                }
                if chunkLength == nil {
                    guard let lineEnd = buffer.range(of: Data("\r\n".utf8)) else { return nil }
                    let text = String(decoding: buffer[..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";", maxSplits: 1).first ?? ""
                    guard let length = Int(text, radix: 16), length >= 0, length <= 8_388_608 - body.count else { throw StatError.message("无效 chunk 长度") }
                    buffer.removeSubrange(..<lineEnd.upperBound)
                    if length == 0 { trailers = true; continue }
                    chunkLength = length
                }
                let n = chunkLength!
                guard buffer.count >= n + 2 else { return nil }
                let end = buffer.index(buffer.startIndex, offsetBy: n)
                guard buffer[end] == 13, buffer[buffer.index(after: end)] == 10 else { throw StatError.message("无效 chunk 结束符") }
                body.append(buffer.prefix(n)); buffer.removeFirst(n + 2); chunkLength = nil
            }
        }
        let rawLength = headers["content-length"] ?? "0"
        guard let length = Int(rawLength), length >= 0, length <= 8_388_608 else { throw StatError.message("无效 Content-Length") }
        guard buffer.count >= length else { return nil }
        return LocalRequest(method: method, path: path, headers: headers, body: Data(buffer.prefix(length)))
    }
}
```

### Sources/TokenStatCore/MetricsEngine.swift

```swift
import Foundation

public struct RequestRecord: Codable {
    public var id: String
    public var date: Date
    public var model: String
    public var input: Int
    public var output: Int
    public var exact: Bool
    public var success: Bool
    public var durationMS: Double
    public var firstByteMS: Double?
    public var inputWaitTPS: Double?
    public var serverInputTPS: Double?
    public var serverOutputTPS: Double?
    public var costUSD: Double
    public var error: String?
}

public struct MetricsSnapshot: Codable {
    public var input = 0
    public var output = 0
    public var total: Int { input + output }
    public var requests = 0
    public var failures = 0
    public var active = 0
    public var estimatedRequests = 0
    public var outputTPS = 0.0
    public var inputWaitTPS = 0.0
    public var averageFirstByteMS: Double?
    public var averageDurationMS: Double?
    public var costUSD = 0.0
    public var last: RequestRecord?
    public init() {}
}

/// All request mutations are protected by one short lock. No I/O occurs under it.
public final class MetricsEngine {
    private struct Active {
        var start: Double
        var date: Date
        var model: String
        var input: Int
        var output = 0
        var outputUnits = 0.0
        var window = RateWindow()
        var usage: TokenUsage?
        var firstByte: Double?
        var firstOutput: Double?
        var inputPrice: Double
        var outputPrice: Double
        var serverInputTPS: Double?
        var serverOutputTPS: Double?
        var count: TokenUsage { usage ?? TokenUsage(input: input, output: output) }
        var cost: Double { (Double(count.input) * inputPrice + Double(count.output) * outputPrice) / 1e6 }
    }
    private let lock = NSLock()
    private var active: [UUID: Active] = [:]
    private var completed = MetricsSnapshot()
    private var durationSum = 0.0
    private var byteSum = 0.0
    private var byteCount = 0
    private var finishedCount = 0
    public init() {}

    @discardableResult public func begin(model: String, input: Int, config: AppConfiguration, now: Double = ProcessInfo.processInfo.systemUptime) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID()
        active[id] = Active(start: now, date: Date(), model: model, input: input, inputPrice: config.inputPrice, outputPrice: config.outputPrice)
        completed.requests += 1
        return id
    }
    public func firstByte(_ id: UUID, now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        if active[id]?.firstByte == nil { active[id]?.firstByte = now }
    }
    public func observe(_ id: UUID, _ observation: Observation, now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard var r = active[id] else { return }
        if !observation.output.isEmpty {
            if r.firstOutput == nil { r.firstOutput = now }
            r.outputUnits += TokenEstimator.units(observation.output)
            let newCount = Int(ceil(r.outputUnits))
            r.window.add(tokens: Double(max(0, newCount - r.output)), at: now)
            r.output = newCount
        }
        // Replace cumulative usage; don't add it, and don't manufacture a speed spike.
        if let usage = observation.usage { r.usage = usage }
        r.serverInputTPS = observation.serverInputTPS ?? r.serverInputTPS
        r.serverOutputTPS = observation.serverOutputTPS ?? r.serverOutputTPS
        active[id] = r
    }
    @discardableResult public func finish(_ id: UUID, success: Bool, error: String? = nil, now: Double = ProcessInfo.processInfo.systemUptime) -> RequestRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let r = active.removeValue(forKey: id) else { return nil } // Exactly once, even on cancellation races.
        let elapsed = max(0, now - r.start) * 1000
        let first = r.firstByte.map { max(0, $0 - r.start) * 1000 }
        let inputRate = r.firstOutput.map { Double(r.count.input) / max(0.001, $0 - r.start) }
        let record = RequestRecord(id: id.uuidString, date: r.date, model: r.model, input: r.count.input,
            output: r.count.output, exact: r.usage != nil, success: success, durationMS: elapsed,
            firstByteMS: first, inputWaitTPS: inputRate, serverInputTPS: r.serverInputTPS,
            serverOutputTPS: r.serverOutputTPS, costUSD: r.cost, error: error)
        completed.input += r.count.input; completed.output += r.count.output
        completed.costUSD += r.cost; completed.failures += success ? 0 : 1
        completed.estimatedRequests += r.usage == nil ? 1 : 0
        finishedCount += 1; durationSum += elapsed
        if let first { byteSum += first; byteCount += 1 }
        completed.last = record
        return record
    }
    public func snapshot(now: Double = ProcessInfo.processInfo.systemUptime) -> MetricsSnapshot {
        lock.lock(); defer { lock.unlock() }
        var s = completed
        s.active = active.count
        // Windows belong to requests: a completed request cannot inflate a new one.
        for (id, var r) in active {
            s.outputTPS += r.window.rate(at: now)
            s.input += r.count.input; s.output += r.count.output; s.costUSD += r.cost
            s.estimatedRequests += r.usage == nil ? 1 : 0
            s.inputWaitTPS += Double(r.count.input) / max(0.5, (r.firstOutput ?? now) - r.start)
            active[id] = r
        }
        s.averageFirstByteMS = byteCount > 0 ? byteSum / Double(byteCount) : nil
        s.averageDurationMS = finishedCount > 0 ? durationSum / Double(finishedCount) : nil
        return s
    }
}
```

### Sources/TokenStatCore/ProxyServer.swift

```swift
import Foundation
import Network

/// Public local API: POST supported inference routes, GET /health, authenticated GET /tokenstat/status.
/// No CONNECT, TLS interception, global proxy settings, or enterprise credential discovery.
public final class ProxyServer {
    private let queue = DispatchQueue(label: "TokenStatMenu.proxy", qos: .utility)
    private var listener: NWListener?
    private var peers: [UUID: ProxyPeer] = [:]
    private let engine: MetricsEngine
    public var onStatus: ((String) -> Void)?
    public var onRecord: ((RequestRecord) -> Void)?
    public init(engine: MetricsEngine) { self.engine = engine }
    public func start(config: AppConfiguration, apiKey: String, localKey: String) {
        queue.async { [self] in
            stopOnQueue()
            do {
                _ = try config.validated()
                guard !localKey.isEmpty else { throw StatError.message("缺少本机访问令牌") }
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(config.port))!)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready: self.onStatus?("监听 127.0.0.1:\(config.port)")
                    case .failed: self.onStatus?("监听失败：端口被占用或网络不可用"); self.stopOnQueue()
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    guard self.peers.count < 32 else { connection.cancel(); return }
                    let id = UUID()
                    let peer = ProxyPeer(connection: connection, queue: self.queue, config: config,
                        apiKey: apiKey, localKey: localKey, engine: self.engine,
                        onRecord: { [weak self] in self?.onRecord?($0) },
                        onClose: { [weak self] in self?.peers.removeValue(forKey: id) })
                    self.peers[id] = peer; peer.start()
                }
                listener.start(queue: queue)
            } catch { onStatus?(error.localizedDescription) }
        }
    }
    public func stop() { queue.async { self.stopOnQueue(); self.onStatus?("已停止") } }
    private func stopOnQueue() {
        listener?.cancel(); listener = nil
        let current = Array(peers.values)
        for peer in current { peer.close(reason: "代理停止") }
        peers.removeAll()
    }
}

private final class ProxyPeer: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    let connection: NWConnection
    let queue: DispatchQueue
    let config: AppConfiguration
    let apiKey: String
    let localKey: String
    let engine: MetricsEngine
    let onRecord: (RequestRecord) -> Void
    let onClose: () -> Void
    var decoder = HTTPDecoder()
    var parser: StreamParser?
    var nonstream = Data()
    var session: URLSession?
    var task: URLSessionDataTask?
    var requestID: UUID?
    var status = 0
    var streaming = false
    var sawTerminal = false
    var streamFailed = false
    var parseFailed = false
    var closed = false
    var finishWhenDrained = false
    var sending = false
    var writes: [Data] = []
    var queuedBytes = 0
    var suspended = false
    var headerDeadline: DispatchWorkItem?

    init(connection: NWConnection, queue: DispatchQueue, config: AppConfiguration, apiKey: String,
         localKey: String, engine: MetricsEngine, onRecord: @escaping (RequestRecord) -> Void, onClose: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.config = config; self.apiKey = apiKey
        self.localKey = localKey; self.engine = engine; self.onRecord = onRecord; self.onClose = onClose
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close(reason: "调用方连接中断") }
        }
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { [weak self] in self?.close(reason: "请求接收超时") }
        headerDeadline = deadline; queue.asyncAfter(deadline: .now() + 30, execute: deadline)
        receiveRequest()
    }
    func receiveRequest() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            do {
                if let request = try self.decoder.feed(data ?? Data()) {
                    self.headerDeadline?.cancel(); self.headerDeadline = nil
                    self.handle(request)
                    self.decoder = HTTPDecoder() // Release the buffered request after forwarding it.
                    // Observe a client disconnect while URLSession is still producing data.
                    self.observeDisconnect(); return
                }
                if complete || error != nil { self.close(reason: "请求不完整") }
                else { self.receiveRequest() }
            } catch { self.respond(400, message: error.localizedDescription) }
        }
    }
    func observeDisconnect() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, complete, error in
            guard let self, !self.closed else { return }
            if error != nil { self.close(reason: "调用方断开") }
            // A clean TCP write-half-close is legal. Sending detects full-close failure.
            else if !complete { self.observeDisconnect() }
        }
    }
    func handle(_ request: LocalRequest) {
        if request.method == "GET", request.path == "/health" { respond(200, message: "TokenStatMenu running"); return }
        guard request.headers["authorization"] == "Bearer \(localKey)" else { respond(401, message: "需要 TokenStatMenu 本机访问令牌"); return }
        if request.method == "GET", request.path == "/tokenstat/status" {
            respondData(200, data: (try? JSONEncoder().encode(engine.snapshot())) ?? Data("{}".utf8)); return
        }
        guard request.method == "POST" else { respond(405, message: "仅支持 POST 推理请求"); return }
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else { respond(415, message: "需要 application/json"); return }
        do {
            let upstream = try config.upstreamURL(for: request.path)
            guard var object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { throw StatError.message("请求正文必须是 JSON 对象") }
            if !config.model.isEmpty { object["model"] = config.model }
            guard let model = object["model"] as? String, !model.isEmpty else { throw StatError.message("请求或设置中需要模型名称") }
            streaming = object["stream"] as? Bool ?? request.path.hasPrefix("/api/")
            if streaming, request.path == "/v1/chat/completions", config.includeUsage {
                var options = object["stream_options"] as? [String: Any] ?? [:]
                options["include_usage"] = true; object["stream_options"] = options
            }
            var outbound = URLRequest(url: upstream)
            outbound.httpMethod = "POST"; outbound.httpBody = try JSONSerialization.data(withJSONObject: object)
            outbound.setValue("application/json", forHTTPHeaderField: "Content-Type")
            outbound.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if !apiKey.isEmpty { outbound.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            outbound.setValue(streaming ? "text/event-stream, application/x-ndjson, application/json" : "application/json", forHTTPHeaderField: "Accept")
            requestID = engine.begin(model: model, input: TokenEstimator.input(object), config: config)
            let settings = URLSessionConfiguration.ephemeral
            settings.urlCache = nil; settings.httpCookieStorage = nil
            settings.timeoutIntervalForRequest = 120; settings.timeoutIntervalForResource = 3600
            let operations = OperationQueue(); operations.maxConcurrentOperationCount = 1; operations.underlyingQueue = queue
            session = URLSession(configuration: settings, delegate: self, delegateQueue: operations)
            task = session!.dataTask(with: outbound); task!.resume()
        } catch { respond(400, message: error.localizedDescription) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward a bearer token to a redirected host.
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !closed, let response = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        status = response.statusCode
        let type = response.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
        if streaming, (200..<300).contains(status) {
            if type.contains("text/event-stream") { parser = StreamParser(format: .sse) }
            else if type.contains("ndjson") || type.contains("jsonl") { parser = StreamParser(format: .ndjson) }
        }
        // Only forward safe response headers. URLSession may already have decompressed the body.
        let safeType = type.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        enqueue(Data("HTTP/1.1 \(status) Response\r\nContent-Type: \(safeType)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8))
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !closed else { return }
        if let id = requestID { engine.firstByte(id) }
        if (200..<300).contains(status), !parseFailed {
            do {
                if parser != nil { for frame in try parser!.feed(data) { try observe(frame, streaming: true) } }
                else {
                    guard nonstream.count + data.count <= 8_388_608 else { throw StatError.message("非流式响应超过统计上限") }
                    nonstream.append(data)
                }
            } catch { parseFailed = true }
        }
        var chunk = Data(String(data.count, radix: 16).utf8); chunk.append(Data("\r\n".utf8)); chunk.append(data); chunk.append(Data("\r\n".utf8)); enqueue(chunk)
    }
    func observe(_ data: Data, streaming: Bool) throws {
        let observation = try UsageDecoder.decode(data, streaming: streaming)
        if let id = requestID { engine.observe(id, observation) }
        sawTerminal = sawTerminal || observation.terminal
        streamFailed = streamFailed || observation.failed
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !closed else { return }
        if !parseFailed, (200..<300).contains(status) {
            do {
                if parser != nil { for frame in try parser!.feed(Data(), eof: true) { try observe(frame, streaming: true) } }
                else if !nonstream.isEmpty { try observe(nonstream, streaming: false) }
                else { parseFailed = true }
            } catch { parseFailed = true }
        }
        let success = error == nil && (200..<300).contains(status) && !parseFailed && !streamFailed && (parser == nil || sawTerminal)
        let reason = success ? nil : (error != nil ? "传输失败或取消" : "HTTP \(status) / 流未完成或统计解析失败")
        if let id = requestID, let record = engine.finish(id, success: success, error: reason) { onRecord(record) }
        requestID = nil
        if status == 0 { respond(502, message: "上游连接失败，请检查 Endpoint 和网络") }
        else if error != nil { close(reason: "上游传输失败") } // Leave chunk framing incomplete: caller must see transport failure.
        else { enqueue(Data("0\r\n\r\n".utf8)); finishWhenDrained = true; drain() }
        session.finishTasksAndInvalidate(); self.session = nil
    }
    func respond(_ code: Int, message: String) {
        let data = (try? JSONSerialization.data(withJSONObject: ["message": message])) ?? Data()
        respondData(code, data: data)
    }
    func respondData(_ code: Int, data: Data) {
        headerDeadline?.cancel()
        var response = Data("HTTP/1.1 \(code) Response\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(data); enqueue(response); finishWhenDrained = true; drain()
    }
    func enqueue(_ data: Data) {
        guard !closed else { return }
        queuedBytes += data.count
        guard queuedBytes <= 4_194_304 else { close(reason: "调用方读取过慢"); return }
        writes.append(data)
        if queuedBytes > 262_144, !suspended, let task { task.suspend(); suspended = true }
        drain()
    }
    func drain() {
        guard !closed, !sending else { return }
        if writes.isEmpty { if finishWhenDrained { close(reason: nil) }; return }
        sending = true
        let bytes = writes.removeFirst()
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            self.sending = false; self.queuedBytes -= bytes.count
            if error != nil { self.close(reason: "调用方断开"); return }
            if self.suspended, self.queuedBytes < 65_536 { self.task?.resume(); self.suspended = false }
            self.drain()
        })
    }
    func close(reason: String?) {
        guard !closed else { return }; closed = true
        headerDeadline?.cancel(); headerDeadline = nil
        task?.cancel(); session?.invalidateAndCancel(); session = nil
        if let id = requestID, let record = engine.finish(id, success: false, error: reason ?? "连接关闭") { onRecord(record) }
        requestID = nil; connection.cancel(); writes.removeAll(); onClose()
    }
}
```

### Sources/TokenStatCore/Quota.swift

```swift
import Foundation
import CoreFoundation

public struct QuotaSnapshot: Codable {
    public var used: Double
    public var limit: Double?
    public var month: String
    public var fetchedAt: Date
    public var fraction: Double? { limit.flatMap { $0 > 0 ? used / $0 : nil } }
    public var remaining: Double? { limit.map { max(0, $0 - used) } }
    public static func currentMonth(at date: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"; return formatter.string(from: date)
    }
    public static func parse(_ data: Data, config: AppConfiguration, now: Date = Date()) throws -> QuotaSnapshot {
        let object = try JSONSerialization.jsonObject(with: data)
        func value(_ path: String) -> Any? {
            guard !path.isEmpty else { return nil }
            return path.split(separator: ".").reduce(Optional(object)) { node, key in
                if let dict = node as? [String: Any] { return dict[String(key)] }
                if let array = node as? [Any], let i = Int(key), array.indices.contains(i) { return array[i] }
                return nil
            }
        }
        func number(_ v: Any?) -> Double? {
            let n: Double?
            if let raw = v as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID() { n = raw.doubleValue }
            else if let raw = v as? String { n = Double(raw) }
            else { n = nil }
            guard let n, n.isFinite, n >= 0, n <= 1e15 else { return nil }
            return n
        }
        guard let used = number(value(config.usedPath)) else { throw StatError.message("企业用量响应缺少有效已用 Token 字段") }
        let month = currentMonth(at: now)
        if !config.periodPath.isEmpty {
            guard value(config.periodPath) as? String == month else { throw StatError.message("企业接口月份缺失或不是本月（需要 yyyy-MM）") }
        }
        let apiLimit = number(value(config.limitPath))
        if !config.limitPath.isEmpty, apiLimit == nil, config.monthlyLimit == 0 { throw StatError.message("配额字段无效，且未设置手动上限") }
        let limit = config.monthlyLimit > 0 ? config.monthlyLimit : apiLimit
        return QuotaSnapshot(used: used, limit: limit, month: month, fetchedAt: now)
    }
}
```

### Sources/TokenStatCore/RateWindow.swift

```swift
import Foundation

public struct RateWindow {
    // 100ms buckets cap memory to ~51 entries, regardless of SSE chunk frequency.
    private var buckets: [Int: Double] = [:]
    public init() {}
    public mutating func add(tokens: Double, at time: Double) {
        guard tokens.isFinite, tokens > 0 else { return }
        buckets[Int(floor(time * 10)), default: 0] += tokens
        prune(at: time)
    }
    public mutating func rate(at time: Double) -> Double {
        prune(at: time)
        return buckets.values.reduce(0, +) / 5
    }
    private mutating func prune(at time: Double) {
        let cutoff = Int(floor((time - 5) * 10))
        buckets = buckets.filter { $0.key > cutoff }
    }
}
```

### Sources/TokenStatCore/StreamParser.swift

```swift
import Foundation
import CoreFoundation

/// Incremental framing operates on bytes: a UTF-8 scalar can span network callbacks.
/// SSE data lines join with newline; comments/event/id fields never count as tokens.
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
    /// Heuristic only. Additive weights ensure changing chunk boundaries doesn't change totals.
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
        if let error = obj["error"], !(error is NSNull) { result.failed = true; result.terminal = true }
        if let usage = obj["usage"] as? [String: Any] { result.usage = tokens(usage) }
        // OpenAI Chat: only deltas while streaming, never count the full final message twice.
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
        // OpenAI Responses: aggregate usage is nested in response.completed.
        if let type = obj["type"] as? String {
            if ["response.output_text.delta", "response.reasoning_text.delta", "response.reasoning_summary_text.delta", "response.function_call_arguments.delta"].contains(type) {
                result.output += obj["delta"] as? String ?? ""
            }
            if ["response.completed", "response.failed", "response.incomplete"].contains(type) {
                result.terminal = true
                result.failed = type != "response.completed"
                if let r = obj["response"] as? [String: Any], let u = r["usage"] as? [String: Any] { result.usage = tokens(u) }
            }
        }
        if !streaming, let output = obj["output"] as? [[String: Any]] {
            for item in output {
                for content in item["content"] as? [[String: Any]] ?? [] { result.output += content["text"] as? String ?? "" }
                result.output += item["arguments"] as? String ?? ""
            }
            if let status = obj["status"] as? String, ["failed", "incomplete"].contains(status) { result.failed = true }
        }
        // Ollama native NDJSON: authoritative counts and durations arrive on the final object.
        if let message = obj["message"] as? [String: Any] {
            result.output += message["content"] as? String ?? ""
            result.output += message["thinking"] as? String ?? ""
        }
        result.output += obj["response"] as? String ?? ""
        if obj["done"] as? Bool == true {
            result.terminal = true
            if let input = nonnegativeInt(obj["prompt_eval_count"]), let output = nonnegativeInt(obj["eval_count"]) {
                result.usage = TokenUsage(input: input, output: output)
                if let n = obj["prompt_eval_duration"] as? Double, n > 0 { result.serverInputTPS = Double(input) / (n / 1e9) }
                if let n = obj["eval_duration"] as? Double, n > 0 { result.serverOutputTPS = Double(output) / (n / 1e9) }
            }
        }
        return result
    }
    private static func tokens(_ o: [String: Any]) -> TokenUsage? {
        guard let input = nonnegativeInt(o["prompt_tokens"] ?? o["input_tokens"]),
              let output = nonnegativeInt(o["completion_tokens"] ?? o["output_tokens"]) else { return nil }
        return TokenUsage(input: input, output: output)
    }
    private static func nonnegativeInt(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue < 1e12 else { return nil }
        return n.intValue
    }
}
```

### Sources/TokenStatMenu/AppModel.swift

```swift
import AppKit
import Combine
#if SWIFT_PACKAGE
import TokenStatCore
#endif
import UniformTypeIdentifiers

struct SpeedPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

@MainActor final class AppModel: ObservableObject {
    // Explicit launch-only flag: fixtures never masquerade as enterprise measurements.
    let isTestFixture = CommandLine.arguments.contains("--test-fixture")
    @Published var config = AppConfiguration()
    @Published var stats = MetricsSnapshot()
    @Published var quota: QuotaSnapshot?
    @Published var quotaError = "未配置企业用量接口"
    @Published var proxyStatus = "启动中"
    @Published var message = ""
    @Published var history: [SpeedPoint] = []
    @Published var quotaLoading = false
    @Published var panelVisible = false
    @Published var gateways: [GatewayCandidate] = []
    @Published var discoveryStatus = "正在读取本机网关配置…"
    @Published var discovering = false
    let engine = MetricsEngine()
    private lazy var proxy = ProxyServer(engine: engine)
    private let logger = StatLogger()
    private var timer: Timer?
    private var quotaLoop: Task<Void, Never>?
    private var quotaFetch: Task<Void, Never>?
    private var generation = 0
    private var lastHistory = Date.distantPast
    private(set) var localKey = ""
    private var apiKey = ""
    private var usageKey = ""
    var onTick: (() -> Void)?

    init(preview: Bool = false) {
        // Offline view rendering must never touch local configuration or credentials.
        if preview { proxyStatus = "模拟预览 · 无网络、无本机配置"; discoveryStatus = "离线预览"; return }
        proxy.onStatus = { [weak self] status in Task { @MainActor in self?.proxyStatus = status } }
        proxy.onRecord = { [weak self] record in
            Task { @MainActor in if self?.config.loggingEnabled == true { self?.logger.append(record) } }
        }
        logger.onError = { [weak self] error in Task { @MainActor in self?.message = error } }
        do {
            config = try ConfigStore.load()
            localKey = try KeychainStore.localToken()
            apiKey = try KeychainStore.resolve("upstream", environment: "TOKENSTAT_API_KEY")
            usageKey = try KeychainStore.resolve("usage", environment: "TOKENSTAT_USAGE_KEY")
            startServices()
        } catch { message = error.localizedDescription; proxyStatus = "未启动：检查设置" }
        // A single 2Hz main timer updates menu text. Network callbacks never redraw the UI.
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        timer?.tolerance = 0.1
        RunLoop.main.add(timer!, forMode: .common)
        discoverGateways()
    }
    /// One bounded scan at startup or on explicit refresh. Never polls the filesystem.
    func discoverGateways() {
        guard !discovering else { return }
        if CommandLine.arguments.contains("--disable-discovery") { discoveryStatus = "本次启动已停用自动发现"; return }
        discovering = true
        let process = ProcessInfo.processInfo.environment
        let allowed = ["OPENAI_BASE_URL", "OPENAI_MODEL", "OLLAMA_HOST"]
        let environment = Dictionary(uniqueKeysWithValues: allowed.compactMap { name in process[name].map { (name, $0) } })
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let override = process["CODEX_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        let directory = override ?? home
        let source = override == nil ? "~/.codex/config.toml" : "$CODEX_HOME/config.toml"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let results = GatewayDiscovery.readCodexConfig(at: directory.appendingPathComponent("config.toml"), source: source)
                + GatewayDiscovery.environmentCandidates(environment)
            Task { @MainActor in
                guard let self else { return }
                self.gateways = results; self.discovering = false
                self.discoveryStatus = results.isEmpty ? "未发现可用网关，可手动填写" : "已发现 \(results.count) 个配置 · 未读取认证信息"
            }
        }
    }
    func shutdown() { timer?.invalidate(); quotaLoop?.cancel(); quotaFetch?.cancel(); proxy.stop() }
    func tick() {
        stats = engine.snapshot()
        let now = Date()
        if config.historyEnabled, now.timeIntervalSince(lastHistory) >= 1 {
            history.append(SpeedPoint(date: now, value: stats.outputTPS))
            history.removeAll { now.timeIntervalSince($0.date) > 600 }
            if history.count > 600 { history.removeFirst(history.count - 600) }
            lastHistory = now
        }
        if quota?.month != QuotaSnapshot.currentMonth(), quota != nil { quota = nil; quotaError = "已跨月，等待本月用量" }
        onTick?()
    }
    var freshQuota: QuotaSnapshot? {
        guard let quota, quota.month == QuotaSnapshot.currentMonth(), Date().timeIntervalSince(quota.fetchedAt) < max(120, config.refreshSeconds * 2) else { return nil }
        return quota
    }
    var currencyFactor: Double { config.currency == "CNY" ? config.usdToCNY : 1 }
    var currencySymbol: String { config.currency == "CNY" ? "¥" : "$" }
    var hasRequestData: Bool { stats.requests > 0 }
    var dataNotice: String {
        if isTestFixture { return "模拟测试 · 以下速度、Token、费用和配额均非企业真实数据" }
        return hasRequestData ? "本次启动 · 仅统计经过本机代理的请求" : "未采集到请求数据 · 尚未观测到客户端流量"
    }
    var title: String {
        let value = !hasRequestData ? "T:—" : stats.active > 0
            ? String(format: "T:≈%.1ftok/s", stats.outputTPS) : "T:0.0tok/s"
        return (isTestFixture ? "测试 " : "") + value
    }
    var alertColor: NSColor {
        guard let ratio = freshQuota?.fraction else { return .labelColor }
        return ratio >= 0.95 ? .systemRed : ratio >= 0.8 ? .systemYellow : .labelColor
    }
    func credentials() -> (String, String) { (apiKey, usageKey) }
    func apply(_ newConfig: AppConfiguration, upstreamKey: String, quotaKey: String) -> Bool {
        guard stats.active == 0 else { message = "请求进行中，请等待完成后再修改代理配置"; return false }
        do {
            _ = try newConfig.validated()
            try KeychainStore.write("upstream", value: upstreamKey)
            try KeychainStore.write("usage", value: quotaKey)
            if localKey.isEmpty { localKey = try KeychainStore.localToken() }
            try ConfigStore.save(newConfig)
            config = newConfig; apiKey = upstreamKey; usageKey = quotaKey
            if !config.historyEnabled { history.removeAll() }
            message = "设置已保存"; startServices(); return true
        } catch { message = error.localizedDescription; return false }
    }
    func reload() {
        guard stats.active == 0 else { message = "请求进行中，暂不能重新加载"; return }
        do { config = try ConfigStore.load(); message = "配置已重新加载"; startServices() }
        catch { message = error.localizedDescription }
    }
    private func startServices() {
        generation += 1; quotaLoop?.cancel(); quotaFetch?.cancel(); quotaFetch = nil; quotaLoading = false
        quota = nil; quotaError = config.usageURL.isEmpty ? "未配置企业用量接口，已用量未知" : "等待企业接口"
        proxy.start(config: config, apiKey: apiKey, localKey: localKey)
        if !config.usageURL.isEmpty {
            quotaLoop = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.refreshQuota()
                    do { try await Task.sleep(nanoseconds: UInt64(self.config.refreshSeconds * 1e9)) }
                    catch { return }
                }
            }
        }
    }
    func refreshQuota() {
        guard !config.usageURL.isEmpty, !quotaLoading else { return }
        quotaLoading = true
        let config = config, key = usageKey, version = generation
        quotaFetch = Task { [weak self] in
            defer { if self?.generation == version { self?.quotaLoading = false } }
            do {
                let result = try await QuotaClient.fetch(config: config, key: key)
                guard !Task.isCancelled, self?.generation == version else { return }
                self?.quota = result; self?.quotaError = ""
            } catch {
                guard !Task.isCancelled, self?.generation == version else { return }
                self?.quotaError = (error as? StatError)?.localizedDescription ?? "企业用量请求失败：检查网络、URL 和认证"
            }
        }
    }
    func copyConnection() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://127.0.0.1:\(config.port)/v1", forType: .string)
        message = "已复制本机 Base URL"
    }
    func copyKey() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(localKey, forType: .string)
        message = "已复制本机访问令牌（仅供客户端连接本机代理）"
    }
    func exportLogs() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "TokenStatMenu-statistics.jsonl"
        panel.allowedContentTypes = [.json, .data]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.logger.export(to: url) { error in
                Task { @MainActor in self?.message = error ?? "统计日志已导出" }
            }
        }
    }
}
```

### Sources/TokenStatMenu/DashboardView.swift

```swift
import SwiftUI
import Charts
#if SWIFT_PACKAGE
import TokenStatCore
#endif

// Select the property wrapper explicitly for SDKs that also expose a State macro.
typealias ValueState<Value> = SwiftUI.State<Value>

@MainActor struct DashboardView: View {
    @ObservedObject var model: AppModel
    @ValueState private var settings = false
    init(model: AppModel, settings: Bool = false) {
        self.model = model
        _settings = State(initialValue: settings)
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isTestFixture || !model.hasRequestData {
                HStack(spacing: 7) {
                    Image(systemName: model.isTestFixture ? "testtube.2" : "info.circle")
                    Text(model.dataNotice).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10))
                .foregroundStyle(model.isTestFixture ? Color.orange : Color.secondary)
                .padding(.horizontal, 16).padding(.bottom, 10)
            }
            if settings { SettingsView(model: model) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        liveCard
                        sessionCard
                        quotaCard
                        if model.config.historyEnabled, model.panelVisible { historyCard }
                        costCard
                        requestCard
                        connectionCard
                    }.padding(.horizontal, 16).padding(.bottom, 14)
                }
            }
            footer
        }
        .frame(width: 460, height: 700)
        .background(.regularMaterial)
        .background(PanelPalette.gradient.opacity(0.09))
        .groupBoxStyle(PanelCardStyle())
        .tint(PanelPalette.blue)
    }
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(PanelPalette.gradient, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("TokenStatMenu").font(.system(size: 16, weight: .bold, design: .rounded))
                Text(settings ? "本机网关与偏好设置" : "实时用量 · 本次启动")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { settings.toggle() } label: {
                Image(systemName: settings ? "chart.bar.xaxis" : "slider.horizontal.3")
                    .frame(width: 28, height: 28)
            }.buttonStyle(.borderless).help(settings ? "返回概览" : "连接与设置")
                .accessibilityLabel(settings ? "返回概览" : "连接与设置")
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").frame(width: 24, height: 28)
            }.buttonStyle(.borderless).help("退出 TokenStatMenu").accessibilityLabel("退出")
        }.padding(16)
    }
    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("实时输出", systemImage: "bolt.horizontal.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(PanelPalette.blue)
                Spacer()
                StatusPill(label: model.stats.active > 0 ? "\(model.stats.active) 个请求进行中" : model.hasRequestData ? "当前空闲" : "等待接入",
                    color: model.stats.active > 0 ? .green : PanelPalette.violet)
            }
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(!model.hasRequestData ? "—" : model.stats.active > 0 ? String(format: "≈%.1f", model.stats.outputTPS) : "0.0")
                    .font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("tok/s").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("输入 / 首输出等待").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(model.stats.active > 0 ? String(format: "≈%.1f", model.stats.inputWaitTPS) : "—")
                        .font(.system(size: 19, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("tok/s · 推算").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            Text("输出为 5 秒窗口文本估算；输入比值含网络与排队时间。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if let rate = model.stats.last?.serverOutputTPS {
                metric("上次 Ollama 服务端平均输出", String(format: "%.1f tok/s", rate))
            }
            if let rate = model.stats.last?.serverInputTPS {
                metric("上次 Ollama 服务端平均输入", String(format: "%.1f tok/s", rate))
            }
        }
        .padding(16)
        .background(PanelPalette.gradient.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(PanelPalette.blue.opacity(0.22)))
    }
    private var sessionCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    tokenTile("总 TOKEN", value: model.stats.total, color: .primary)
                    Divider().frame(height: 40)
                    tokenTile("输入", value: model.stats.input, color: PanelPalette.blue)
                    tokenTile("输出", value: model.stats.output, color: PanelPalette.violet)
                }
                Text(!model.hasRequestData ? "尚无请求数据；这里不代表企业总用量。" : model.stats.estimatedRequests > 0 ? "含 \(model.stats.estimatedRequests) 个请求估算，最终 usage 到达后校正。" : "累计值已由上游 usage 确认。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } label: { Label("本次启动累计", systemImage: "square.stack.3d.up") }
    }
    private func tokenTile(_ label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            Text(measuredCount(value)).font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(color).monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                .textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var quotaCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 18) {
                    QuotaRing(fraction: model.quota?.fraction)
                    VStack(spacing: 7) {
                        metric("已消耗", model.quota.map { count($0.used) } ?? "未知")
                        metric("月度配额", model.quota?.limit.map(count) ?? (model.config.monthlyLimit > 0 ? count(model.config.monthlyLimit) : "未设置"))
                        metric("剩余配额", model.quota?.remaining.map(count) ?? "未知")
                        if let fraction = model.quota?.fraction {
                            ProgressView(value: min(1, max(0, fraction)))
                                .tint(fraction >= 0.95 ? .red : fraction >= 0.8 ? .yellow : PanelPalette.blue)
                        }
                    }
                }
                HStack {
                    if let quota = model.quota {
                        Text(model.freshQuota == nil ? "数据已过期" : "更新于 \(quota.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    } else { Text("配置用量接口后显示企业配额") }
                    Spacer()
                    Button { model.refreshQuota() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).disabled(model.quotaLoading || model.config.usageURL.isEmpty)
                        .help("刷新企业用量").accessibilityLabel("刷新企业用量")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                if !model.quotaError.isEmpty, !model.config.usageURL.isEmpty {
                    Text(model.quotaError).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        } label: { HStack { Label("企业配额", systemImage: "chart.donut"); Spacer(); Text(QuotaSnapshot.currentMonth()).font(.system(size: 10)) } }
    }
    private var costCard: some View {
        GroupBox {
            VStack(spacing: 8) {
                metric("输入 / 百万 Token", model.config.inputPrice > 0 ? money(model.config.inputPrice * model.currencyFactor) : "未设置 / 免费")
                metric("输出 / 百万 Token", model.config.outputPrice > 0 ? money(model.config.outputPrice * model.currencyFactor) : "未设置 / 免费")
                metric("累计费用", !model.hasRequestData ? "—" : money(model.stats.costUSD * model.currencyFactor))
                Text("按自定义单价估算，非企业账单；零单价不代表实际免费。缓存不另行折扣。\(model.config.currency == "CNY" ? "USD→CNY 汇率 \(model.config.usdToCNY)（手填）。" : "")")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } label: { Label("费用估算 · \(model.config.currency)", systemImage: "creditcard") }
    }
    private var requestCard: some View {
        GroupBox {
            VStack(spacing: 8) {
                metric("总请求 / 失败", "\(model.stats.requests) / \(model.stats.failures)")
                metric("平均首响应字节延迟", model.stats.averageFirstByteMS.map { String(format: "%.0f ms", $0) } ?? "—")
                metric("平均完整请求耗时", model.stats.averageDurationMS.map { String(format: "%.0f ms", $0) } ?? "—")
                if let last = model.stats.last {
                    metric("上次请求", "\(last.success ? "完成" : "失败") · \(last.exact ? "usage" : "估算")")
                    if let error = last.error { Text(error).font(.system(size: 10)).foregroundStyle(.orange) }
                }
            }
        } label: { Label("请求与响应", systemImage: "arrow.left.arrow.right") }
    }
    private var historyCard: some View {
        GroupBox {
            Chart(model.history) { point in
                AreaMark(x: .value("时间", point.date), y: .value("tok/s", point.value))
                    .foregroundStyle(LinearGradient(colors: [PanelPalette.blue.opacity(0.22), PanelPalette.violet.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("时间", point.date), y: .value("tok/s", point.value))
                    .foregroundStyle(PanelPalette.blue).lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartYScale(domain: 0...max(1, (model.history.map(\.value).max() ?? 1) * 1.1))
            .frame(height: 96)
            .accessibilityLabel("近十分钟输出 token 估算速度曲线")
        } label: { Label("近 10 分钟 · 输出估算 tok/s", systemImage: "waveform.path.ecg") }
    }
    private var connectionCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Text("仅统计经过本机代理的请求，不自动接管其他应用。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    Button("复制 Base URL") { model.copyConnection() }
                    Button("复制本机令牌") { model.copyKey() }
                    Spacer()
                    Button { model.exportLogs() } label: { Image(systemName: "square.and.arrow.up") }
                        .help("导出统计日志").accessibilityLabel("导出统计日志")
                }.controlSize(.small)
            }
        } label: { Label("本机连接", systemImage: "network") }
    }
    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(model.stats.active > 0 ? Color.green : Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
            Text(model.message.isEmpty ? model.proxyStatus : model.message)
                .lineLimit(2).font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(.horizontal, 16).padding(.vertical, 9)
    }
    private func metric(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).fontWeight(.medium).monospacedDigit().textSelection(.enabled) }.font(.system(size: 11))
    }
    private func count(_ n: Int) -> String { n.formatted() }
    private func count(_ n: Double) -> String { n.formatted(.number.precision(.fractionLength(0))) }
    private func measuredCount(_ n: Int) -> String {
        guard model.hasRequestData else { return "—" }
        return (model.stats.estimatedRequests > 0 ? "≈" : "") + count(n)
    }
    private func money(_ n: Double) -> String { model.currencySymbol + String(format: "%.6f", n) }
}
```

### Sources/TokenStatMenu/QuotaClient.swift

```swift
import Foundation
#if SWIFT_PACKAGE
import TokenStatCore
#endif

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum QuotaClient {
    static func fetch(config: AppConfiguration, key: String) async throws -> QuotaSnapshot {
        let url = try config.checkedURL(config.usageURL)
        var request = URLRequest(url: url); request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 15; settings.timeoutIntervalForResource = 20
        settings.urlCache = nil; settings.httpCookieStorage = nil
        let session = URLSession(configuration: settings, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StatError.message("企业用量接口返回 HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw StatError.message("企业用量响应超过 1MB") }
            data.append(byte)
        }
        return try QuotaSnapshot.parse(data, config: config)
    }
}
```

### Sources/TokenStatMenu/SettingsView.swift

```swift
import SwiftUI
#if SWIFT_PACKAGE
import TokenStatCore
#endif

@MainActor struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ValueState private var draft: AppConfiguration
    @ValueState private var apiKey: String
    @ValueState private var quotaKey: String
    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.config)
        let keys = model.credentials()
        _apiKey = State(initialValue: keys.0); _quotaKey = State(initialValue: keys.1)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                discoverySection
                upstreamSection
                priceSection
                quotaSection
                otherSection
                HStack {
                    Button("保存并应用") { _ = model.apply(draft, upstreamKey: apiKey, quotaKey: quotaKey) }.buttonStyle(.borderedProminent)
                    Button("重新加载 plist") { model.reload(); draft = model.config }
                }
                Text(model.isTestFixture ? "配置：隔离模拟配置" : "配置：\(AppPaths.configURL.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(16)
        }
        .textFieldStyle(.roundedBorder)
    }
    private var discoverySection: some View {
        GroupBox("本机网关 · 自动发现") {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.discoveryStatus).font(.caption).foregroundStyle(.secondary)
                ForEach(model.gateways) { gateway in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(gateway.provider + (gateway.isActive ? " · Codex 当前配置" : "")).font(.caption).bold()
                            Spacer()
                            Button("填入") {
                                if draft.endpoint != gateway.endpoint {
                                    // Do not accidentally send old credentials to a newly chosen host.
                                    apiKey = ""; quotaKey = ""; draft.usageURL = ""
                                }
                                draft.endpoint = gateway.endpoint; draft.model = gateway.model
                                model.message = "已填入网关地址；请自行配置认证后保存。发现地址不代表已经接入流量。"
                            }
                        }
                        Text(gateway.endpoint).font(.caption2).textSelection(.enabled)
                        Text(gateway.source).font(.caption2).foregroundStyle(.secondary)
                    }
                    Divider()
                }
                Button(model.discovering ? "扫描中…" : "重新扫描") { model.discoverGateways() }.disabled(model.discovering)
                Text("只在本机识别地址、模型与提供方；不读取其他应用的密钥、Cookie 或认证文件。不会修改 Codex 配置，也不会联网探测。更换地址时清空待保存的旧密钥，避免误发。")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(6)
        }
    }
    private var upstreamSection: some View {
        GroupBox("API 与本机代理") {
            VStack(alignment: .leading, spacing: 8) {
                field("上游完整 Endpoint", text: $draft.endpoint)
                Text("例如 https://企业网关/v1/chat/completions；Ollama 可使用 http://127.0.0.1:11434/api/chat")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("上游 API Key（保存在钥匙串）").font(.caption)
                SecureField("Ollama 本机可留空", text: $apiKey)
                field("模型覆盖（留空沿用请求中的 model）", text: $draft.model)
                HStack { Text("本机端口"); TextField("18765", value: $draft.port, format: .number.grouping(.never)).frame(width: 100) }.font(.caption)
                Toggle("Chat 流请求附带 include_usage", isOn: $draft.includeUsage)
                Toggle("允许远程私网 HTTP（密钥将明文传输）", isOn: $draft.allowInsecureHTTP)
                Text("客户端 Base URL 指向本机，客户端 API Key 使用“复制本机令牌”的值。企业 Key 只填在上方。")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(6)
        }
    }
    private var priceSection: some View {
        GroupBox("自定义价格") {
            VStack(alignment: .leading, spacing: 8) {
                number("输入 USD / 百万 Token", value: $draft.inputPrice)
                number("输出 USD / 百万 Token", value: $draft.outputPrice)
                Picker("显示币种", selection: $draft.currency) { Text("USD").tag("USD"); Text("CNY").tag("CNY") }.pickerStyle(.segmented)
                number("1 USD = CNY（手填汇率）", value: $draft.usdToCNY)
            }.padding(6)
        }
    }
    private var quotaSection: some View {
        GroupBox("企业月度 Token 接口") {
            VStack(alignment: .leading, spacing: 8) {
                field("用量 GET URL（可留空）", text: $draft.usageURL)
                Text("用量接口 Bearer Key（独立于推理 Key）").font(.caption)
                SecureField("可留空；不自动复用上游密钥", text: $quotaKey)
                field("已用 Token 字段路径", text: $draft.usedPath)
                field("总配额字段路径（可留空）", text: $draft.limitPath)
                field("月份字段路径（yyyy-MM；留空信任接口本月语义）", text: $draft.periodPath)
                number("手动月度 Token 上限（0 = 接口值）", value: $draft.monthlyLimit)
                number("刷新秒数（15–3600）", value: $draft.refreshSeconds)
                Text("字段必须是 Token 数量，不能填金额或积分。手动配额不会推算全企业已用量。达到 80% 黄色、95% 红色，仅改变菜单栏颜色。")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(6)
        }
    }
    private var otherSection: some View {
        GroupBox("历史与日志") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("显示近 10 分钟速度图", isOn: $draft.historyEnabled)
                Toggle("记录脱敏请求统计日志", isOn: $draft.loggingEnabled)
                Text("不记录提示词、回答或密钥。日志只保留当前与上一份，每份约 10MB；本次启动统计不会从日志恢复。")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("导出日志") { model.exportLogs() }
            }.padding(6)
        }
    }
    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(label).font(.caption); TextField(label, text: text).labelsHidden() }
    }
    private func number(_ label: String, value: Binding<Double>) -> some View {
        HStack { Text(label); Spacer(); TextField(label, value: value, format: .number).labelsHidden().frame(width: 110) }.font(.caption)
    }
}
```

### Sources/TokenStatMenu/StatusBarController.swift

```swift
import AppKit
import SwiftUI

@MainActor final class StatusBarController: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let model: AppModel
    private var lastTitle = ""
    private var lastColor: NSColor?
    private var lastDiagnostic = Date.distantPast
    init(model: AppModel) {
        self.model = model
        // Keep a strong reference: a local NSStatusItem vanishes when deallocated.
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.autosaveName = "TokenStatMenu.Metrics"
        popover.behavior = .transient; popover.animates = false; popover.delegate = self
        popover.contentSize = NSSize(width: 460, height: 700)
        popover.contentViewController = NSHostingController(rootView: DashboardView(model: model))
        if let button = item.button {
            button.target = self; button.action = #selector(toggle)
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.setAccessibilityLabel("TokenStatMenu 实时 Token 速度")
        }
        model.onTick = { [weak self] in self?.refreshTitle() }
        refreshTitle()
    }
    func refreshTitle() {
        let title = model.title, color = model.alertColor
        if title != lastTitle || color != lastColor {
            lastTitle = title; lastColor = color
            item.button?.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: color
            ])
        }
        item.button?.toolTip = "\(model.dataNotice) · 输出估算速度（5 秒窗口）· \(model.proxyStatus)"
        writeDiagnosticsIfRequested()
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) } else { show() }
    }
    func show() {
        guard let button = item.button else { return }
        model.panelVisible = true
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    func popoverDidClose(_ notification: Notification) { model.panelVisible = false }
    /// Opt-in local diagnostic output for integration tests; no credentials or content.
    /// Reports actual AppKit title and popover state, not a separately simulated UI.
    private func writeDiagnosticsIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--diagnostics-output"), args.indices.contains(index + 1),
              Date().timeIntervalSince(lastDiagnostic) >= 1 else { return }
        lastDiagnostic = Date()
        struct Report: Encodable {
            let isTestFixture: Bool
            let hasRequestData: Bool
            let dataNotice: String
            let discoveredGateways: Int
            let title: String
            let popoverShown: Bool
            let statusItemVisible: Bool
            let active: Int
            let quotaUsed: Double?
            let quotaFraction: Double?
            let quotaError: String
            let alert: String
        }
        let appliedColor = (item.button?.attributedTitle.length ?? 0) > 0
            ? item.button?.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            : nil
        let report = Report(isTestFixture: model.isTestFixture, hasRequestData: model.hasRequestData,
            dataNotice: model.dataNotice, discoveredGateways: model.gateways.count,
            title: item.button?.attributedTitle.string ?? "", popoverShown: popover.isShown,
            statusItemVisible: item.isVisible, active: model.stats.active,
            quotaUsed: model.quota?.used, quotaFraction: model.quota?.fraction, quotaError: model.quotaError,
            alert: appliedColor == .systemRed ? "red" : appliedColor == .systemYellow ? "yellow" : "normal")
        if let data = try? JSONEncoder().encode(report) {
            let url = URL(fileURLWithPath: args[index + 1])
            DispatchQueue.global(qos: .utility).async { try? data.write(to: url, options: .atomic) }
        }
    }
}
```

### Sources/TokenStatMenu/Storage.swift

```swift
import Foundation
import Security
#if SWIFT_PACKAGE
import TokenStatCore
#endif

enum AppPaths {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TokenStatMenu")
    static var configURL: URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--config"), args.indices.contains(i + 1) { return URL(fileURLWithPath: args[i + 1]) }
        return support.appendingPathComponent("config.plist")
    }
    static var logs: URL { configURL.deletingLastPathComponent().appendingPathComponent("Logs") }
}

enum ConfigStore {
    static func load() throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: AppPaths.configURL.path) else { return AppConfiguration() }
        let defaults = try PropertyListEncoder().encode(AppConfiguration())
        var base = try PropertyListSerialization.propertyList(from: defaults, format: nil) as! [String: Any]
        let loaded = try PropertyListSerialization.propertyList(from: Data(contentsOf: AppPaths.configURL), format: nil)
        guard let values = loaded as? [String: Any] else { throw StatError.message("配置必须是 plist 字典") }
        base.merge(values) { _, new in new }
        let data = try PropertyListSerialization.data(fromPropertyList: base, format: .xml, options: 0)
        return try PropertyListDecoder().decode(AppConfiguration.self, from: data).validated()
    }
    static func save(_ config: AppConfiguration) throws {
        _ = try config.validated()
        try FileManager.default.createDirectory(at: AppPaths.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .xml
        try encoder.encode(config).write(to: AppPaths.configURL, options: .atomic)
    }
}

enum KeychainStore {
    private static let service = "com.tupig.TokenStatMenu"
    static func read(_ name: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: name, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw StatError.message("无法读取 TokenStatMenu 钥匙串（\(status)）")
        }
        return text
    }
    static func write(_ name: String, value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StatError.message("无法保存 TokenStatMenu 钥匙串（\(status)）") }
    }
    static func resolve(_ name: String, environment: String) throws -> String {
        if let value = ProcessInfo.processInfo.environment[environment] { return value }
        return try read(name)
    }
    static func localToken() throws -> String {
        if let value = ProcessInfo.processInfo.environment["TOKENSTAT_LOCAL_KEY"], !value.isEmpty { return value }
        let existing = try read("local")
        if !existing.isEmpty { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw StatError.message("本机令牌生成失败") }
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        try write("local", value: value); return value
    }
}

final class StatLogger {
    private let queue = DispatchQueue(label: "TokenStatMenu.log", qos: .utility)
    var onError: ((String) -> Void)?
    func append(_ record: RequestRecord) {
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at: AppPaths.logs, withIntermediateDirectories: true)
                let url = AppPaths.logs.appendingPathComponent("requests.jsonl")
                let previous = AppPaths.logs.appendingPathComponent("requests.previous.jsonl")
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 10_000_000 {
                    if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                    try FileManager.default.moveItem(at: url, to: previous)
                }
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                var data = try encoder.encode(record); data.append(10)
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data)
            } catch { onError?("统计日志写入失败") }
        }
    }
    func export(to url: URL, completion: @escaping (String?) -> Void) {
        queue.async {
            do {
                var result = Data()
                for name in ["requests.previous.jsonl", "requests.jsonl"] {
                    let path = AppPaths.logs.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: path.path) { result.append(try Data(contentsOf: path)) }
                }
                try result.write(to: url, options: .atomic); completion(nil)
            } catch { completion("导出失败：无法读写所选文件") }
        }
    }
}
```

### Sources/TokenStatMenu/TokenStatMenuApp.swift

```swift
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var status: StatusBarController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let model = AppModel(); self.model = model
        status = StatusBarController(model: model)
        // Explicit inspection option only. Normal launches never open a window/popover.
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.status?.show() }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        status?.show(); return false
    }
}

@main struct TokenStatMenuApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
```

### Sources/TokenStatMenu/PanelStyle.swift

```swift
import SwiftUI

// Original native components inspired by compact translucent desktop dashboards.
// Semantic foregrounds/materials keep both system appearances legible.
enum PanelPalette {
    static let blue = Color(red: 0.24, green: 0.43, blue: 0.96)
    static let violet = Color(red: 0.55, green: 0.39, blue: 0.89)
    static let gradient = LinearGradient(colors: [blue, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct PanelCardStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.07)))
    }
}

struct StatusPill: View {
    let label: String
    var color: Color = PanelPalette.blue
    var body: some View {
        Text(label).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color).padding(.horizontal, 9).padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityLabel(label)
    }
}

struct QuotaRing: View {
    let fraction: Double?
    var body: some View {
        ZStack {
            Circle().stroke(PanelPalette.blue.opacity(0.12), lineWidth: 7)
            if let fraction {
                Circle().trim(from: 0, to: min(1, max(0, fraction)))
                    .stroke(PanelPalette.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 2) {
                Text(fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                    .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(fraction == nil ? "未知" : "已使用").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 84, height: 84)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fraction.map { String(format: "配额已使用 %.1f%%", $0 * 100) } ?? "企业用量未知")
    }
}
```

### Resources/Info.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TokenStatMenu</string>
<key>CFBundleIdentifier</key><string>com.tupig.TokenStatMenu</string>
<key>CFBundleName</key><string>TokenStatMenu</string>
<key>CFBundleDisplayName</key><string>TokenStatMenu</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict>
<key>NSAllowsArbitraryLoads</key><true/>
</dict>
</dict></plist>
```

### Resources/config.example.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>endpoint</key><string>http://127.0.0.1:11434/v1/chat/completions</string>
<key>model</key><string></string>
<key>port</key><integer>18765</integer>
<key>includeUsage</key><true/>
<key>allowInsecureHTTP</key><false/>
<key>inputPrice</key><real>0</real>
<key>outputPrice</key><real>0</real>
<key>currency</key><string>USD</string>
<key>usdToCNY</key><real>7.0</real>
<key>monthlyLimit</key><real>0</real>
<key>usageURL</key><string></string>
<key>usedPath</key><string>data.used_tokens</string>
<key>limitPath</key><string>data.total_tokens</string>
<key>periodPath</key><string>data.month</string>
<key>refreshSeconds</key><real>60</real>
<key>loggingEnabled</key><false/>
<key>historyEnabled</key><true/>
</dict></plist>
```

### TokenStatMenu.xcodeproj/project.pbxproj

```text
// !$*UTF8*$!
{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {
8E4403D07D4E24DF01F86E5D = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "Configuration.swift"; sourceTree = "<group>"; };
6A3864C6E6DB561D02F46C35 = { isa = PBXBuildFile; fileRef = 8E4403D07D4E24DF01F86E5D; };
6060CB36BD32E4DE62121D71 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "GatewayDiscovery.swift"; sourceTree = "<group>"; };
08BC9043587CC788D01C24E7 = { isa = PBXBuildFile; fileRef = 6060CB36BD32E4DE62121D71; };
25DB8EC2672FE7C810B75A38 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "HTTPDecoder.swift"; sourceTree = "<group>"; };
C6D71C6FAB45AC1E6B57A569 = { isa = PBXBuildFile; fileRef = 25DB8EC2672FE7C810B75A38; };
4C87C1C697E481BB11B23261 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "MetricsEngine.swift"; sourceTree = "<group>"; };
BACF14F65A3D26C56E4559AC = { isa = PBXBuildFile; fileRef = 4C87C1C697E481BB11B23261; };
99081DE7CEB5C9C7DAFEADA1 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "ProxyServer.swift"; sourceTree = "<group>"; };
DDA47B3DEE61C34C2F297CF7 = { isa = PBXBuildFile; fileRef = 99081DE7CEB5C9C7DAFEADA1; };
4B0A93085460A2D4B5B2F8C2 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "Quota.swift"; sourceTree = "<group>"; };
49E56DE5EE1D3357BC99E0B5 = { isa = PBXBuildFile; fileRef = 4B0A93085460A2D4B5B2F8C2; };
A1B8AA05224B907A20995624 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "RateWindow.swift"; sourceTree = "<group>"; };
E51281927C6E41F6B2F2A59B = { isa = PBXBuildFile; fileRef = A1B8AA05224B907A20995624; };
951D8E55C70DA883B1E10A70 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "StreamParser.swift"; sourceTree = "<group>"; };
06CC516465ECBFB9656FCFE3 = { isa = PBXBuildFile; fileRef = 951D8E55C70DA883B1E10A70; };
AF7F4C7B765701F258FB7F4D = { isa = PBXGroup; children = (8E4403D07D4E24DF01F86E5D, 6060CB36BD32E4DE62121D71, 25DB8EC2672FE7C810B75A38, 4C87C1C697E481BB11B23261, 99081DE7CEB5C9C7DAFEADA1, 4B0A93085460A2D4B5B2F8C2, A1B8AA05224B907A20995624, 951D8E55C70DA883B1E10A70,); path = "Sources/TokenStatCore"; sourceTree = "<group>"; };
11043337019FA9BE53E5DEA5 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "AppModel.swift"; sourceTree = "<group>"; };
60476D6C0F010F89CDCF9332 = { isa = PBXBuildFile; fileRef = 11043337019FA9BE53E5DEA5; };
B3117F547294E09EFEF92409 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "DashboardView.swift"; sourceTree = "<group>"; };
BBE06DCD34D248AEC63DEFB1 = { isa = PBXBuildFile; fileRef = B3117F547294E09EFEF92409; };
1568C8A45BC98EBCCE9A8EA4 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "PanelStyle.swift"; sourceTree = "<group>"; };
1C6C1E79E7D0D3008EFA0C51 = { isa = PBXBuildFile; fileRef = 1568C8A45BC98EBCCE9A8EA4; };
54DC60746B43C432B61ADBD4 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "QuotaClient.swift"; sourceTree = "<group>"; };
29DBAC87E7D2D08969C25259 = { isa = PBXBuildFile; fileRef = 54DC60746B43C432B61ADBD4; };
7DBBE1964667520E74C4B575 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "SettingsView.swift"; sourceTree = "<group>"; };
DF47DB83567E12D94C90C186 = { isa = PBXBuildFile; fileRef = 7DBBE1964667520E74C4B575; };
262E8C516B62E763FA6537BF = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "StatusBarController.swift"; sourceTree = "<group>"; };
775730CD86C47FBDC9419E49 = { isa = PBXBuildFile; fileRef = 262E8C516B62E763FA6537BF; };
3D39E548358F39784FDEFE9F = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "Storage.swift"; sourceTree = "<group>"; };
F2E25F94650242E3A64878B7 = { isa = PBXBuildFile; fileRef = 3D39E548358F39784FDEFE9F; };
9215CF293A4FF1D70E77EC32 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "TokenStatMenuApp.swift"; sourceTree = "<group>"; };
B71BD30B9E5D41A06B13B456 = { isa = PBXBuildFile; fileRef = 9215CF293A4FF1D70E77EC32; };
96BD6B98AF8DAF812B21484D = { isa = PBXGroup; children = (11043337019FA9BE53E5DEA5, B3117F547294E09EFEF92409, 1568C8A45BC98EBCCE9A8EA4, 54DC60746B43C432B61ADBD4, 7DBBE1964667520E74C4B575, 262E8C516B62E763FA6537BF, 3D39E548358F39784FDEFE9F, 9215CF293A4FF1D70E77EC32,); path = "Sources/TokenStatMenu"; sourceTree = "<group>"; };
A8792157CB4F27FB949C035F = { isa = PBXFileReference; explicitFileType = wrapper.application; path = TokenStatMenu.app; sourceTree = BUILT_PRODUCTS_DIR; };
0A3E27B8CA818264D75C8D81 = { isa = PBXGroup; children = (A8792157CB4F27FB949C035F,); name = Products; sourceTree = "<group>"; };
9B987D631012EC23CDD96B6A = { isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Resources/Info.plist"; sourceTree = "<group>"; };
652E7FD0652728D9B3EF13DF = { isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Resources/config.example.plist"; sourceTree = "<group>"; };
0D6E4079E36703EBD37C0072 = { isa = PBXGroup; children = (AF7F4C7B765701F258FB7F4D, 96BD6B98AF8DAF812B21484D, 9B987D631012EC23CDD96B6A, 652E7FD0652728D9B3EF13DF, 0A3E27B8CA818264D75C8D81,); sourceTree = "<group>"; };
878A52FC5FF6A57D50B7B870 = { isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (6A3864C6E6DB561D02F46C35, 08BC9043587CC788D01C24E7, C6D71C6FAB45AC1E6B57A569, BACF14F65A3D26C56E4559AC, DDA47B3DEE61C34C2F297CF7, 49E56DE5EE1D3357BC99E0B5, E51281927C6E41F6B2F2A59B, 06CC516465ECBFB9656FCFE3, 60476D6C0F010F89CDCF9332, BBE06DCD34D248AEC63DEFB1, 1C6C1E79E7D0D3008EFA0C51, 29DBAC87E7D2D08969C25259, DF47DB83567E12D94C90C186, 775730CD86C47FBDC9419E49, F2E25F94650242E3A64878B7, B71BD30B9E5D41A06B13B456,); runOnlyForDeploymentPostprocessing = 0; };
E2AA269EB967A8853A258BFA = { isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
41D311A605520FC7B8B9A980 = { isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
5DF0EAF287A59303D4EFEAF3 = { isa = XCBuildConfiguration; name = Debug; buildSettings = { MACOSX_DEPLOYMENT_TARGET = 13.0; SDKROOT = macosx; CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0; }; };
B8EB4DC6EE71CC2FBFD201B8 = { isa = XCBuildConfiguration; name = Debug; buildSettings = {
        PRODUCT_NAME = TokenStatMenu;
        PRODUCT_BUNDLE_IDENTIFIER = com.tupig.TokenStatMenu;
        INFOPLIST_FILE = Resources/Info.plist;
        GENERATE_INFOPLIST_FILE = NO;
        CODE_SIGN_IDENTITY = "-";
        CODE_SIGN_STYLE = Manual;
        ENABLE_APP_SANDBOX = NO;
        ENABLE_HARDENED_RUNTIME = YES;
        SWIFT_OPTIMIZATION_LEVEL = "-Onone";
        LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";
    }; };
C62D9534737287C44FD6EF43 = { isa = XCBuildConfiguration; name = Release; buildSettings = { MACOSX_DEPLOYMENT_TARGET = 13.0; SDKROOT = macosx; CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0; }; };
2EF9ECCD715FED9D8FF379BE = { isa = XCBuildConfiguration; name = Release; buildSettings = {
        PRODUCT_NAME = TokenStatMenu;
        PRODUCT_BUNDLE_IDENTIFIER = com.tupig.TokenStatMenu;
        INFOPLIST_FILE = Resources/Info.plist;
        GENERATE_INFOPLIST_FILE = NO;
        CODE_SIGN_IDENTITY = "-";
        CODE_SIGN_STYLE = Manual;
        ENABLE_APP_SANDBOX = NO;
        ENABLE_HARDENED_RUNTIME = YES;
        SWIFT_OPTIMIZATION_LEVEL = "-O";
        LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";
    }; };
AD1646610FAAB916B1DAB3FC = { isa = XCConfigurationList; buildConfigurations = (5DF0EAF287A59303D4EFEAF3, C62D9534737287C44FD6EF43,); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
9C5B038A078AB1DFD15318F0 = { isa = XCConfigurationList; buildConfigurations = (B8EB4DC6EE71CC2FBFD201B8, 2EF9ECCD715FED9D8FF379BE,); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
34A04005BCAF206EEC990BD9 = { isa = PBXNativeTarget; buildConfigurationList = 9C5B038A078AB1DFD15318F0;
    buildPhases = (878A52FC5FF6A57D50B7B870, E2AA269EB967A8853A258BFA, 41D311A605520FC7B8B9A980,); buildRules = (); dependencies = ();
    name = TokenStatMenu; productName = TokenStatMenu; productReference = A8792157CB4F27FB949C035F; productType = "com.apple.product-type.application"; };
244210E48437B6556980A702 = { isa = PBXProject; attributes = { LastUpgradeCheck = 1600; };
    buildConfigurationList = AD1646610FAAB916B1DAB3FC; compatibilityVersion = "Xcode 14.0"; developmentRegion = en;
    hasScannedForEncodings = 0; knownRegions = (en, Base, "zh-Hans",);
    mainGroup = 0D6E4079E36703EBD37C0072; productRefGroup = 0A3E27B8CA818264D75C8D81; projectDirPath = ""; projectRoot = ""; targets = (34A04005BCAF206EEC990BD9,); };
}; rootObject = 244210E48437B6556980A702; }
```

### Tests/TokenStatCoreTests/CoreChecks.swift

```swift
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
        print("\(checks - failures)/\(checks) checks passed")
        if failures > 0 { exit(1) }
    }
    static func tryDecode(_ data: Data) -> Observation { (try? UsageDecoder.decode(data, streaming: true)) ?? Observation() }
}
```

### Tests/TokenStatCoreTests/GatewayDiscoveryChecks.swift

```swift
import Foundation
import TokenStatCore

extension CoreChecks {
    static func gatewayChecks() throws {
        let text = #"""
        model_provider = "corp"
        model = "example-model"
        api_key = "fixture-secret-do-not-copy"
        [model_providers.corp]
        base_url = "https://gateway.example/airoute"
        wire_api = "responses"
        experimental_bearer_token = "fixture-private-token"
        [model_providers.local]
        base_url = 'http://localhost:1234/v1'
        wire_api = "chat"
        """#
        let found = GatewayDiscovery.codexCandidates(text, source: "fixture")
        check(found.count == 2 && found.first?.isActive == true, "discover active provider first")
        check(found.first?.endpoint == "https://gateway.example/airoute/responses", "preserve enterprise base path without inventing v1")
        check(found.first?.model == "example-model" && found.last?.model == "", "model belongs to selected provider only")
        var config = AppConfiguration(); config.endpoint = found[0].endpoint
        let mappedResponses = try config.upstreamURL(for: "/v1/responses")
        check(mappedResponses.absoluteString == "https://gateway.example/airoute/responses", "Responses proxy preserves non-v1 upstream")
        let mappedChat = try config.upstreamURL(for: "/v1/chat/completions")
        check(mappedChat.path == "/airoute/chat/completions", "Chat mapping preserves non-v1 upstream")
        _ = try config.validated()
        let profile = text + "\n[profiles.work]\nmodel_provider = \"local\"\nmodel = \"profile-model\"\n"
        let selected = GatewayDiscovery.codexCandidates("profile = \"work\"\n" + profile, source: "fixture")
        check(selected.first?.provider == "local" && selected.first?.model == "profile-model", "active profile overrides root model and provider")
        let bad = ["https://user:password@example.com/v1", "https://example.com/v1?api_key=fixture", "https://example.com/v1#fixture", "file:///tmp/config", "https://example.com/%0a/v1"]
        for url in bad {
            check(GatewayDiscovery.candidate(baseURL: url, provider: "fixture", source: "fixture") == nil, "reject credential-bearing or invalid discovery URL")
        }
        let duplicate = text + "\n[model_providers.corp]\nbase_url = \"https://other.example/v1\"\n"
        check(!GatewayDiscovery.codexCandidates(duplicate, source: "fixture").contains { $0.provider == "corp" }, "ambiguous duplicate base URL not imported")
        let embedded = "instructions = \"\"\"\n[model_providers.fake]\nbase_url = \"https://fake.example/v1\"\n\"\"\"\n" + text
        check(GatewayDiscovery.codexCandidates(embedded, source: "fixture").count == 2, "multiline instruction content never becomes provider config")
        let env = GatewayDiscovery.environmentCandidates(["OPENAI_BASE_URL":"https://example.com/v1", "OPENAI_API_KEY":"fixture-secret", "OLLAMA_HOST":"127.0.0.1:11434"])
        check(env.count == 2 && env.last?.endpoint == "http://127.0.0.1:11434/api/chat", "allowlisted environment discovery and native Ollama endpoint")
        let encoded = try JSONEncoder().encode(found + env)
        let output = String(decoding: encoded, as: UTF8.self)
        check(!output.contains("fixture-secret") && !output.contains("private-token") && !output.contains("api_key"), "candidate model contains no authentication fields")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.toml")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let disk = GatewayDiscovery.readCodexConfig(at: file, source: "fixture")
        check(disk.count == 2, "bounded local file discovery")
        try String(repeating: "a", count: 1_048_577).write(to: file, atomically: true, encoding: .utf8)
        check(GatewayDiscovery.readCodexConfig(at: file, source: "fixture").isEmpty, "oversized discovery file refused")
    }
}
```

### script/build_and_run.sh

```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE="${1:-run}"
APP="$ROOT/dist/TokenStatMenu.app"
case "$MODE" in run|--build-only|--verify|--release|--universal|--logs|--telemetry|--debug) ;; *) echo "Usage: $0 [--build-only|--verify|--release|--universal|--logs|--telemetry|--debug]"; exit 2 ;; esac
pkill -x TokenStatMenu 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS"
# Native SwiftPM also works with Command Line Tools; no global xcode-select changes.
if [ "$MODE" = "--universal" ]; then
    for ARCH in arm64 x86_64; do
        swift build --build-system native --arch "$ARCH" --scratch-path ".build/$ARCH" -c release --product TokenStatMenu
    done
    ARM_DIR="$(swift build --build-system native --arch arm64 --scratch-path .build/arm64 -c release --show-bin-path)"
    INTEL_DIR="$(swift build --build-system native --arch x86_64 --scratch-path .build/x86_64 -c release --show-bin-path)"
    lipo -create "$ARM_DIR/TokenStatMenu" "$INTEL_DIR/TokenStatMenu" -output "$APP/Contents/MacOS/TokenStatMenu"
else
    CONFIG=debug
    if [ "$MODE" = "--release" ]; then CONFIG=release; fi
    swift build --build-system native -c "$CONFIG" --product TokenStatMenu
    BIN_DIR="$(swift build --build-system native -c "$CONFIG" --show-bin-path)"
    cp "$BIN_DIR/TokenStatMenu" "$APP/Contents/MacOS/TokenStatMenu"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
chmod 755 "$APP/Contents/MacOS/TokenStatMenu"
# Ad hoc signing is for a local development build, not a Developer ID / notarization claim.
codesign --force --sign - "$APP"
if [ "$MODE" = "--build-only" ] || [ "$MODE" = "--universal" ]; then echo "Built: $APP"; exit 0; fi
if [ "$MODE" = "--debug" ]; then exec lldb "$APP/Contents/MacOS/TokenStatMenu"; fi
open -n "$APP"
case "$MODE" in
    --verify) sleep 1; pgrep -x TokenStatMenu >/dev/null; echo "Process launched; inspect menu title to verify UI." ;;
    --logs|--telemetry) /usr/bin/log stream --info --predicate 'process == "TokenStatMenu"' ;;
esac
```

### script/test.sh

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift run --build-system native TokenStatCoreChecks
./script/build_and_run.sh --build-only
python3 script/integration.py
```

### script/mock_server.py

```python
#!/usr/bin/env python3
"""Deterministic local upstream. Test secrets only; no enterprise traffic."""
import datetime
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    quota_used = 850000

    def log_message(self, *args):
        pass

    def send_json(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/fixture/quota95":
            Handler.quota_used = 960000
            return self.send_json(200, {"ok": True})
        if self.path == "/usage":
            if self.headers.get("Authorization") != "Bearer integration-quota-key":
                return self.send_json(401, {"error": "wrong quota key"})
            return self.send_json(200, {"data": {"used_tokens": Handler.quota_used, "total_tokens": 1000000,
                "month": datetime.datetime.now().strftime("%Y-%m")}})
        self.send_json(404, {})

    def do_POST(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            if self.headers.get("Authorization") != "Bearer integration-upstream-key":
                return self.send_json(401, {"error": "wrong upstream key"})
            model = body.get("model", "")
            if model == "fail":
                return self.send_json(429, {"error": {"message": "rate limit"}})
            if model == "redirect":
                self.send_response(302)
                self.send_header("Location", "http://127.0.0.1:19877/must-not-follow")
                self.send_header("Content-Length", "0")
                return self.end_headers()
            if body.get("stream") is False:
                return self.send_json(200, {"choices": [{"message": {"content": "fixture reply"}}],
                    "usage": {"prompt_tokens": 100, "completion_tokens": 50}})
            if self.path == "/v1/chat/completions" and not body.get("stream_options", {}).get("include_usage"):
                return self.send_json(400, {"error": "include_usage was not forwarded"})
            native = self.path.startswith("/api/")
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson" if native else "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True

            def emit(obj):
                text = json.dumps(obj, ensure_ascii=False) if not isinstance(obj, str) else obj
                packet = ((text + "\n") if native else ("data: " + text + "\r\n\r\n")).encode()
                # Split inside UTF-8 and line boundaries; forward byte-for-byte.
                for i in range(0, len(packet), 11):
                    self.wfile.write(packet[i:i+11]); self.wfile.flush()

            if model == "malformed":
                emit("not-json"); return
            for _ in range(30 if model in ["slow", "cancel"] else 4):
                if native:
                    emit({"message": {"content": "你好 world "}, "done": False})
                elif self.path == "/v1/responses":
                    emit({"type": "response.output_text.delta", "delta": "你好 world "})
                else:
                    emit({"choices": [{"delta": {"content": "你好 world "}}]})
                time.sleep(0.15 if model in ["slow", "cancel"] else 0.025)
            if model == "incomplete":
                return
            if native:
                emit({"done": True, "prompt_eval_count": 100, "eval_count": 50,
                    "prompt_eval_duration": 500000000, "eval_duration": 2000000000})
            elif self.path == "/v1/responses":
                emit({"type": "response.completed", "response": {"usage": {"input_tokens": 100, "output_tokens": 50}}})
            else:
                emit({"choices": [], "usage": {"prompt_tokens": 100, "completion_tokens": 50}})
                emit("[DONE]")
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 19877), Handler).serve_forever()
```

### script/integration.py

```python
#!/usr/bin/env python3
"""Launches the real .app against a local fixture, with an isolated plist and test-only keys."""
import concurrent.futures
import http.client
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORK = ROOT / ".integration"
BASE = "http://127.0.0.1:19876"
LOCAL_KEY = "integration-local-key"


def fetch(path, obj=None, key=LOCAL_KEY):
    data = None if obj is None else json.dumps(obj).encode()
    request = urllib.request.Request(BASE + path, data=data,
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def snapshot():
    status, data = fetch("/tokenstat/status")
    assert status == 200
    return json.loads(data)


def body(model="fixture", stream=True):
    return {"model": model, "messages": [{"role": "user", "content": "integration prompt must not appear in logs"}], "stream": stream}


def wait_for(predicate, timeout=12):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            value = predicate()
            if value:
                return value
        except (OSError, ValueError, urllib.error.URLError):
            pass
        time.sleep(0.1)
    raise AssertionError("condition timed out")


def main():
    global WORK
    WORK.mkdir(exist_ok=True)
    WORK = pathlib.Path(tempfile.mkdtemp(prefix="run-", dir=WORK))
    (ROOT / ".integration/last-run.txt").write_text(str(WORK))
    config = {"endpoint": "http://127.0.0.1:19877/v1/chat/completions", "port": 19876,
        "usageURL": "http://127.0.0.1:19877/usage", "refreshSeconds": 15.0,
        "inputPrice": 1.0, "outputPrice": 2.0, "loggingEnabled": True}
    with (WORK / "config.plist").open("wb") as handle:
        plistlib.dump(config, handle)
    codex_home = WORK / "codex"
    codex_home.mkdir()
    (codex_home / "config.toml").write_text('model_provider = "fixture"\nmodel = "fixture-model"\n[model_providers.fixture]\nbase_url = "http://127.0.0.1:19877/v1"\nwire_api = "responses"\nexperimental_bearer_token = "fixture-auth-must-not-be-imported"\n')
    server = subprocess.Popen([sys.executable, str(ROOT / "script/mock_server.py")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["pkill", "-x", "TokenStatMenu"], capture_output=True)
    command = ["open", "-n", str(ROOT / "dist/TokenStatMenu.app"),
        "--env", "TOKENSTAT_LOCAL_KEY=" + LOCAL_KEY,
        "--env", "CODEX_HOME=" + str(codex_home),
        "--env", "TOKENSTAT_API_KEY=integration-upstream-key",
        "--env", "TOKENSTAT_USAGE_KEY=integration-quota-key",
        "--args", "--config", str(WORK / "config.plist"), "--show-panel", "--test-fixture",
        "--diagnostics-output", str(WORK / "ui-diagnostics.json")]
    subprocess.run(command, check=True)
    try:
        wait_for(lambda: fetch("/health")[0] == 200)
        diagnostic = WORK / "ui-diagnostics.json"
        ui = wait_for(lambda: (r if (r := json.loads(diagnostic.read_text())).get("quotaFraction") == 0.85 else None))
        assert ui["discoveredGateways"] == 1, ui
        assert "fixture-auth" not in diagnostic.read_text(), ui
        assert ui["quotaUsed"] == 850000 and ui["alert"] == "yellow", ui
        assert ui["title"] == "测试 T:—" and ui["statusItemVisible"], ui
        assert ui["isTestFixture"] and not ui["hasRequestData"], ui
        assert "模拟测试" in ui["dataNotice"], ui
        assert snapshot()["requests"] == 0, "startup must not manufacture usage"
        assert fetch("/tokenstat/status", key="bad")[0] == 401
        assert fetch("/v1/chat/completions", body(), key="bad")[0] == 401
        assert fetch("/unsupported", body())[0] == 400
        assert snapshot()["requests"] == 0, "rejected local requests are not upstream requests"
        for route in ["/v1/chat/completions", "/v1/responses", "/api/chat", "/api/generate"]:
            status, data = fetch(route, body())
            assert status == 200 and "你好" in data.decode(), route
        assert fetch("/v1/chat/completions", body(stream=False))[0] == 200
        assert snapshot()["input"] == 500 and snapshot()["output"] == 250, snapshot()
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
            jobs = [executor.submit(fetch, "/v1/chat/completions", body("slow")) for _ in range(3)]
            active = wait_for(lambda: (s if (s := snapshot())["active"] == 3 and s["outputTPS"] > 0 else None))
            assert active["estimatedRequests"] >= 3
            print("Live concurrent output TPS:", active["outputTPS"], flush=True)
            ui = wait_for(lambda: (r if (r := json.loads(diagnostic.read_text()))["active"] == 3 and r["title"].startswith("测试 T:≈") and r["title"] != "测试 T:≈0.0tok/s" else None))
            print("Actual AppKit menu title:", ui["title"], flush=True)
            for job in jobs:
                assert job.result()[0] == 200
        final = wait_for(lambda: (s if (s := snapshot())["active"] == 0 else None))
        assert final["input"] == 800 and final["output"] == 400, final
        assert abs(final["costUSD"] - 0.0016) < 1e-9
        assert final["outputTPS"] == 0
        for model, status in [("fail", 429), ("redirect", 302), ("incomplete", 200), ("malformed", 200)]:
            assert fetch("/v1/chat/completions", body(model))[0] == status
        failures = wait_for(lambda: (s if (s := snapshot())["failures"] == 4 else None))
        assert failures["requests"] == 12
        # Exercise inbound chunked HTTP as real clients such as SDK generators may use it.
        connection = http.client.HTTPConnection("127.0.0.1", 19876, timeout=20)
        data = json.dumps(body()).encode()
        connection.request("POST", "/v1/chat/completions", body=[data[:7], data[7:]],
            headers={"Authorization": "Bearer " + LOCAL_KEY, "Content-Type": "application/json"}, encode_chunked=True)
        response = connection.getresponse(); assert response.status == 200; response.read(); connection.close()
        final = wait_for(lambda: (s if (s := snapshot())["requests"] == 13 and s["active"] == 0 else None))
        assert final["failures"] == 4
        connection = http.client.HTTPConnection("127.0.0.1", 19876, timeout=20)
        connection.request("POST", "/v1/chat/completions", body=json.dumps(body("cancel")),
            headers={"Authorization": "Bearer " + LOCAL_KEY, "Content-Type": "application/json"})
        response = connection.getresponse(); response.read(100); response.close(); connection.close()
        cancelled = wait_for(lambda: (s if (s := snapshot())["active"] == 0 else None))
        assert cancelled["requests"] == 14 and cancelled["failures"] == 5, cancelled
        with urllib.request.urlopen("http://127.0.0.1:19877/fixture/quota95", timeout=2) as response:
            assert response.status == 200
        red = wait_for(lambda: (r if (r := json.loads(diagnostic.read_text())).get("alert") == "red" else None), timeout=20)
        assert red["quotaFraction"] == 0.96 and red["quotaUsed"] == 960000, red
        logs = WORK / "Logs/requests.jsonl"
        wait_for(lambda: logs.exists() and len(logs.read_text().splitlines()) >= 13)
        text = logs.read_text()
        for secret in ["integration prompt must not", "你好", LOCAL_KEY, "integration-upstream-key", "integration-quota-key"]:
            assert secret not in text, "logs must not contain bodies or secrets"
        records = [json.loads(line) for line in text.splitlines()]
        assert any(r["exact"] and r["input"] == 100 and r["output"] == 50 for r in records)
        print("PASS: real app, AppKit title, quota/yellow+red alerts, 4 routes, streaming/nonstreaming, 3 concurrent requests, usage correction, failures, cancellation, redirect refusal, chunked input, sanitized logs", flush=True)
        if "--keep-running" not in sys.argv:
            # A fresh normal launch must not inherit fixture quota or imply zero measured usage.
            subprocess.run(["pkill", "-x", "TokenStatMenu"], capture_output=True)
            normal_config = WORK / "normal.plist"
            with normal_config.open("wb") as handle:
                plistlib.dump({"port": 19876}, handle)
            normal_diagnostic = WORK / "normal-ui.json"
            normal_command = command.copy()
            normal_command.remove("--test-fixture")
            normal_command[normal_command.index(str(WORK / "config.plist"))] = str(normal_config)
            normal_command[normal_command.index(str(diagnostic))] = str(normal_diagnostic)
            subprocess.run(normal_command, check=True)
            normal = wait_for(lambda: json.loads(normal_diagnostic.read_text()))
            assert normal["title"] == "T:—" and not normal["isTestFixture"], normal
            assert not normal["hasRequestData"] and "未采集" in normal["dataNotice"], normal
            assert normal.get("quotaUsed") is None and normal["alert"] == "normal", normal
            print("PASS: fixture clearly labeled; normal startup has no inherited usage or quota", flush=True)
        (WORK / "result.json").write_text(json.dumps(cancelled, indent=2))
        if "--keep-running" in sys.argv:
            print("Fixture running for UI inspection. PID", server.pid, flush=True)
            return
    finally:
        if "--keep-running" not in sys.argv:
            subprocess.run(["pkill", "-x", "TokenStatMenu"], capture_output=True)
            server.terminate(); server.wait(timeout=5)


if __name__ == "__main__":
    main()
```

### script/generate_xcode_project.py

```python
#!/usr/bin/env python3
"""Generate a dependency-free native macOS .xcodeproj from the same Swift sources."""
import hashlib
from pathlib import Path

root = Path(__file__).resolve().parents[1]
objects = {}


def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def obj(name, body):
    objects[ident(name)] = body
    return ident(name)


def refs(values):
    return "(" + ", ".join(values) + ",)"


sources = []
groups = []
for folder in ["TokenStatCore", "TokenStatMenu"]:
    files = []
    for path in sorted((root / "Sources" / folder).glob("*.swift")):
        key = path.relative_to(root).as_posix()
        ref = obj("file:" + key, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{path.name}"; sourceTree = "<group>";')
        files.append(ref)
        sources.append(obj("build:" + key, f"isa = PBXBuildFile; fileRef = {ref};"))
    groups.append(obj("group:" + folder, f'isa = PBXGroup; children = {refs(files)}; path = "Sources/{folder}"; sourceTree = "<group>";'))
product = obj("product", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = TokenStatMenu.app; sourceTree = BUILT_PRODUCTS_DIR;')
products = obj("products", f'isa = PBXGroup; children = ({product},); name = Products; sourceTree = "<group>";')
resource_files = [obj("resource:" + n, f'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Resources/{n}"; sourceTree = "<group>";') for n in ["Info.plist", "config.example.plist"]]
main = obj("main", f'isa = PBXGroup; children = {refs(groups + resource_files + [products])}; sourceTree = "<group>";')
source_phase = obj("sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(sources)}; runOnlyForDeploymentPostprocessing = 0;")
framework_phase = obj("frameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
resource_phase = obj("resources", "isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
project_configs, target_configs = [], []
for mode in ["Debug", "Release"]:
    project_configs.append(obj("project-config:" + mode, f'isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ MACOSX_DEPLOYMENT_TARGET = 13.0; SDKROOT = macosx; CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0; }};'))
    optimization = "-Onone" if mode == "Debug" else "-O"
    target_configs.append(obj("target-config:" + mode, f'''isa = XCBuildConfiguration; name = {mode}; buildSettings = {{
        PRODUCT_NAME = TokenStatMenu;
        PRODUCT_BUNDLE_IDENTIFIER = com.tupig.TokenStatMenu;
        INFOPLIST_FILE = Resources/Info.plist;
        GENERATE_INFOPLIST_FILE = NO;
        CODE_SIGN_IDENTITY = "-";
        CODE_SIGN_STYLE = Manual;
        ENABLE_APP_SANDBOX = NO;
        ENABLE_HARDENED_RUNTIME = YES;
        SWIFT_OPTIMIZATION_LEVEL = "{optimization}";
        LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";
    }};'''))
project_list = obj("project-list", f"isa = XCConfigurationList; buildConfigurations = {refs(project_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
target_list = obj("target-list", f"isa = XCConfigurationList; buildConfigurations = {refs(target_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
target = obj("target", f'''isa = PBXNativeTarget; buildConfigurationList = {target_list};
    buildPhases = ({source_phase}, {framework_phase}, {resource_phase},); buildRules = (); dependencies = ();
    name = TokenStatMenu; productName = TokenStatMenu; productReference = {product}; productType = "com.apple.product-type.application";''')
project = obj("project", f'''isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }};
    buildConfigurationList = {project_list}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en;
    hasScannedForEncodings = 0; knownRegions = (en, Base, "zh-Hans",);
    mainGroup = {main}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},);''')
directory = root / "TokenStatMenu.xcodeproj"
directory.mkdir(exist_ok=True)
text = '// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'
text += "\n".join(f"{key} = {{ {value} }};" for key, value in objects.items())
text += f"\n}}; rootObject = {project}; }}\n"
(directory / "project.pbxproj").write_text(text)
print(directory)
```

### script/render_preview.py

```python
#!/usr/bin/env python3
"""Render fixture-only light/dark dashboards and settings using actual SwiftUI code."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
sources = sorted((root / "Sources").rglob("*.swift"))
sources = [str(p) for p in sources if p.name != "TokenStatMenuApp.swift"]
binary = root / ".build/preview-renderer"
binary.parent.mkdir(exist_ok=True)
subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-module-name", "TokenStatMenuPreview", *sources, str(root / "script/RenderPreview.swift"), "-o", str(binary)], check=True)
subprocess.run([str(binary), str(root / "dist/previews"), "--test-fixture"], check=True)
```

### script/RenderPreview.swift

```swift
import AppKit
import SwiftUI

/// Offline rendering of the actual SwiftUI views, not a screen capture.
@main struct RenderPreview {
    @MainActor static func main() throws {
        guard CommandLine.arguments.contains("--test-fixture"), CommandLine.arguments.count > 2 else { exit(2) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let model = AppModel(preview: true)
        model.panelVisible = true
        model.stats.requests = 12; model.stats.input = 64000; model.stats.output = 12000
        model.stats.active = 1; model.stats.outputTPS = 24.5; model.stats.inputWaitTPS = 3800
        model.stats.estimatedRequests = 1; model.stats.costUSD = 0.088
        model.config.inputPrice = 1; model.config.outputPrice = 2
        model.config.usageURL = "https://gateway.example/usage"
        let month = QuotaSnapshot.currentMonth()
        model.quota = try QuotaSnapshot.parse(Data("{\"data\":{\"used_tokens\":640000,\"total_tokens\":1000000,\"month\":\"\(month)\"}}".utf8), config: model.config)
        model.quotaError = ""
        model.gateways = [GatewayDiscovery.candidate(baseURL: "https://gateway.example/route", provider: "示例网关", source: "虚构本机配置", model: "example-model", isActive: true)!]
        model.discoveryStatus = "模拟候选 · 不读取实际配置"
        model.history = (0..<60).map { i in SpeedPoint(date: Date().addingTimeInterval(Double(i - 60)), value: 20 + sin(Double(i) * 0.3) * 6) }
        for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", .dark, .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            for settings in [false, true] {
                let content = DashboardView(model: model, settings: settings)
                    .environment(\.colorScheme, scheme)
                    .background(scheme == .dark ? Color(red: 0.13, green: 0.14, blue: 0.17) : Color(red: 0.96, green: 0.97, blue: 0.99))
                // NSHostingView also renders AppKit-backed ScrollView/TextField/Button,
                // which ImageRenderer intentionally omits. This window stays off screen.
                let bounds = NSRect(x: 0, y: 0, width: 460, height: 700)
                let host = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
                host.frame = bounds
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else { throw NSError(domain: "Preview", code: 1) }
                host.cacheDisplay(in: bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "Preview", code: 2) }
                window.close()
                try png.write(to: output.appendingPathComponent("\(name)-\(settings ? "settings" : "dashboard").png"))
            }
        }
        print("Rendered four offline fixture previews; no configuration, credentials or network accessed")
    }
}
```

### script/package_source.py

```python
#!/usr/bin/env python3
"""Generate the complete source document and export only reviewed project files."""
import argparse
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PUBLIC_FILES = [
    ".gitignore", ".github/workflows/build.yml", "Package.swift", "README.md", "LICENSE", "PRIVACY.md",
    "Sources/TokenStatCore/Configuration.swift", "Sources/TokenStatCore/GatewayDiscovery.swift",
    "Sources/TokenStatCore/HTTPDecoder.swift", "Sources/TokenStatCore/MetricsEngine.swift",
    "Sources/TokenStatCore/ProxyServer.swift", "Sources/TokenStatCore/Quota.swift",
    "Sources/TokenStatCore/RateWindow.swift", "Sources/TokenStatCore/StreamParser.swift",
    "Sources/TokenStatMenu/AppModel.swift", "Sources/TokenStatMenu/DashboardView.swift",
    "Sources/TokenStatMenu/QuotaClient.swift", "Sources/TokenStatMenu/SettingsView.swift",
    "Sources/TokenStatMenu/StatusBarController.swift", "Sources/TokenStatMenu/Storage.swift",
    "Sources/TokenStatMenu/TokenStatMenuApp.swift", "Sources/TokenStatMenu/PanelStyle.swift",
    "Resources/Info.plist", "Resources/config.example.plist", "TokenStatMenu.xcodeproj/project.pbxproj",
    "Tests/TokenStatCoreTests/CoreChecks.swift", "Tests/TokenStatCoreTests/GatewayDiscoveryChecks.swift",
    "script/build_and_run.sh", "script/test.sh", "script/mock_server.py", "script/integration.py",
    "script/generate_xcode_project.py", "script/render_preview.py", "script/RenderPreview.swift", "script/package_source.py", "script/check_public_content.py",
    "docs/DESIGN.md", "docs/IMPLEMENTATION.md", "docs/CONFIGURATION.md", "docs/VALIDATION.md", "docs/FULL_SOURCE.md",
]


def source_document():
    readme = (ROOT / "README.md").read_text()
    architecture = readme.split("## 整体架构\n", 1)[1].split("## 文件与职责", 1)[0]
    parts = ["# TokenStatMenu 完整源码\n\n## 项目整体架构\n", architecture, "\n## 分文件完整源码\n"]
    languages = {".swift": "swift", ".plist": "xml", ".pbxproj": "text", ".py": "python", ".sh": "bash", ".yml": "yaml"}
    for name in PUBLIC_FILES:
        path = ROOT / name
        if path.suffix not in languages:
            continue
        parts += [f"\n### {name}\n\n```{languages[path.suffix]}\n", path.read_text().rstrip(), "\n```\n"]
    parts += ["\n## 编译与使用\n\n", readme.split("## 构建与运行\n", 1)[1]]
    (ROOT / "docs/FULL_SOURCE.md").write_text("".join(parts))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--export", type=Path, help="Copy the allowlist into a new/empty publication directory")
    args = parser.parse_args()
    source_document()
    for name in PUBLIC_FILES:
        path = ROOT / name
        if path.is_symlink() or not path.is_file():
            raise SystemExit("Missing or symbolic-link publication file: " + name)
    if args.export:
        if args.export.exists() and any(args.export.iterdir()):
            raise SystemExit("Export directory must be empty")
        for name in PUBLIC_FILES:
            target = args.export / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
    output = ROOT / "dist/TokenStatMenu-source.zip"
    output.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for name in PUBLIC_FILES:
            archive.write(ROOT / name, "TokenStatMenu/" + name)
    print(f"Packaged {len(PUBLIC_FILES)} allowlisted files")


if __name__ == "__main__":
    main()
```

### script/check_public_content.py

```python
#!/usr/bin/env python3
"""Check publication file boundaries and common private data patterns locally.

This is a guardrail, not a substitute for reviewing the exact diff. Reports
locations/categories only, never the matched secret value. No network calls.
"""
import argparse
import re
import subprocess
from pathlib import Path
from package_source import PUBLIC_FILES, ROOT


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--git-index", action="store_true", help="Inspect exact staged blobs instead of working files")
    args = parser.parse_args()
    if args.git_index:
        names = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().strip("\0").split("\0")
    else:
        names = PUBLIC_FILES
    patterns = {
        "private key": r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
        "access token": r"\b(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{20,})",
        "personal absolute home path": "/" + r"(?:Users|home)/[A-Za-z0-9_.-]+/",
        "credential in URL": r"https?://[^\s/\"']+:[^\s/\"']+@",
        "sensitive query value": r"[?&](?:api_key|access_token|token|password|secret)=[^\s\"'<>]+",
    }
    # Synthetic fixtures intentionally include invalid credential URLs to test rejection.
    fixture_files = {"Tests/TokenStatCoreTests/GatewayDiscoveryChecks.swift", "docs/FULL_SOURCE.md"}
    failures = []
    for name in names:
        if name not in PUBLIC_FILES:
            failures.append((name, 0, "file not on publication allowlist")); continue
        if args.git_index:
            mode = subprocess.check_output(["git", "ls-files", "--stage", "--", name], cwd=ROOT).decode().split()[0]
            if mode not in ("100644", "100755"):
                failures.append((name, 0, "non-regular tracked file")); continue
            data = subprocess.check_output(["git", "show", ":" + name], cwd=ROOT)
        else:
            path = ROOT / name
            if path.is_symlink() or not path.is_file():
                failures.append((name, 0, "missing or symbolic-link file")); continue
            data = path.read_bytes()
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            failures.append((name, 0, "unexpected binary file")); continue
        for category, pattern in patterns.items():
            for match in re.finditer(pattern, text, re.IGNORECASE):
                value = match.group()
                if name in fixture_files and category in ("credential in URL", "sensitive query value"):
                    if value == "https://" + "user:password@" or value == "?" + "api_key=fixture":
                        continue
                failures.append((name, text.count("\n", 0, match.start()) + 1, category))
    for name, line, category in failures:
        print(f"FAIL {name}:{line}: {category}")
    if failures:
        raise SystemExit(1)
    print(f"PASS: {len(names)} publication files checked; no forbidden file or configured private-data pattern found")


if __name__ == "__main__":
    main()
```

## 编译与使用


### Xcode

1. 完成 Xcode 首次启动、许可与组件安装。
2. 打开 `TokenStatMenu.xcodeproj`，选择 **TokenStatMenu → My Mac**。
3. 按 ⌘B 编译，⌘R 运行。程序只出现于菜单栏，不会打开主窗口或 Dock 图标。
4. 项目默认本机 ad hoc 签名；向其他电脑正式分发时，使用你的 Developer ID 签名与公证。

`.xcodeproj` 和 Swift Package 编译同一份源码。新增源码后执行 `python3 script/generate_xcode_project.py` 可更新 Xcode 项目文件。

### 命令行（Command Line Tools 即可）

```bash
git clone https://github.com/Tupig/TokenStatMenu.git
cd TokenStatMenu
./script/build_and_run.sh                 # 构建 .app 并启动
./script/build_and_run.sh --build-only    # 仅生成 dist/TokenStatMenu.app
./script/build_and_run.sh --release       # 本机架构优化构建并启动
./script/build_and_run.sh --universal     # arm64 + x86_64 Release；只构建不启动
```

可将 `dist/TokenStatMenu.app` 拖到“应用程序”。开发脚本会先关闭同名进程再更新构建产物，避免覆盖正在执行的二进制。不会自动设置开机启动。

当前 Swift 6.4 对 `--build-system native` 有弃用提示；采用它是为了兼容这台机器已经可用的 Command Line Tools。项目不依赖该构建系统，Xcode 项目仍可独立编译。

## 首次配置与接入

1. 点击菜单栏 `T:—` → **设置**。
2. 设置页会自动发现本机 Codex 配置中的网关；核对来源后点“填入”。也可手动填写上游完整 Endpoint，例如 `https://你的网关/v1/chat/completions`；填写企业推理 API Key。Ollama 本机无需 Key。
3. 模型覆盖留空时使用客户端请求的 `model`；填写时会覆盖所有经过代理请求的模型。
4. 保存设置，回到面板，分别复制 **Base URL** 与 **本机令牌**。
5. 将调用方 Base URL 改成 `http://127.0.0.1:18765/v1`，调用方 API Key 使用本机令牌。企业真实 Key 保存在本 App 的钥匙串中。
6. 发起流式请求；菜单栏显示输出估算速度。请求结束后立即回到 `0.0`，累计数量以末尾 usage 校正。

示例（把 `本机令牌` 和 `模型名` 换成实际值）：

```bash
curl -N http://127.0.0.1:18765/v1/chat/completions \
  -H 'Authorization: Bearer 本机令牌' \
  -H 'Content-Type: application/json' \
  -d '{"model":"模型名","stream":true,"messages":[{"role":"user","content":"请介绍一下你自己"}]}'
```

支持的本机请求路径：

- `POST /v1/chat/completions`：OpenAI Chat SSE 或非流式 JSON。
- `POST /v1/responses`：Responses 文本、推理摘要、工具参数 delta 与嵌套 usage。
- `POST /api/chat`、`POST /api/generate`：Ollama 原生 NDJSON / JSON。
- `GET /health`：仅返回进程健康，不需要令牌。
- `GET /tokenstat/status`：需要本机令牌；返回累计与实时统计 JSON。

上游 URL 会保留 Endpoint 的前缀，再替换以上路由后缀。例如设置 `https://gateway.example/gateway/v1/chat/completions`，Responses 请求发往 `https://gateway.example/gateway/v1/responses`。不支持通用 CONNECT、WebSocket、未知路径、自动 SDK 模型枚举或 TLS 透明拦截。

Codex 如使用 Responses，需要通过其受支持的自定义 provider 配置将请求接入本机 `/v1`。企业客户端可能自行覆盖配置或使用额外认证，必须按该客户端接入方式处理。本项目没有更改你现在的 Codex 或企业网关配置。

## 关键计算口径

### SSE 与 Token 计数

HTTP 网络 chunk 与模型 token 不一一对应。`StreamParser` 保存未完整行的原始字节，按 LF/CRLF 提取行，多行 `data:` 合并，空行结束事件，忽略注释。中文 UTF-8 拆到不同网络回调也不会破坏字符。单事件限制约 2MB。

`UsageDecoder` 读取文本、推理文本和工具参数增量。无模型 tokenizer 时，ASCII 标量暂按 0.25 token、非 ASCII 按 1 token 估算；这是明确的启发式估算，不是精确 BPE。累计原始权重后再取整，避免“每个 chunk 至少算一个 token”的偏差。图像/音频等非文本输入不能靠文本准确估算。

Chat 的 `usage.prompt_tokens/completion_tokens`、Responses 的 `response.usage.input_tokens/output_tokens`、Ollama 的 `prompt_eval_count/eval_count` 到达后替换该请求累计值。重复 usage 不重复累加，reasoning 已含在上游输出 token 中时也不重复相加。没有 usage 的完成/失败请求保留估算标记。

OpenAI 兼容网关可能拒绝 `stream_options.include_usage`；可在设置关闭该开关。这会降低最终统计准确度，除非上游仍返回用量。

### token/s 滑动窗口

使用 `ProcessInfo.systemUptime` 避免系统时间回拨影响。输出估算增量进入 100ms 分桶，保留最近 5 秒：

`输出估算 tok/s = 最近 5 秒输出估算增量总和 ÷ 5`

启动最初不足 5 秒仍除以 5，因此读数渐进升高；这是固定窗口平均，非瞬时 token 间隔测速。并发请求的输出合计显示。末尾 usage 的校正差值不进入滑动窗口，避免结算时出现假峰值；没有活跃请求时标题归零。

输入没有逐块生成事件，面板显示 `输入 Token ÷ 从请求开始到首个输出片段的时间`，明确标记“推算”。等待首输出时使用已等待时间，实时显示的分母最低取 0.5 秒以避免启动瞬间产生极大值。它包含网络和排队，不能当作模型实际 prefill 速度。Ollama 返回 `prompt_eval_duration/eval_duration` 时，另显示上次服务端平均输入/输出速度（纳秒换算为秒）。

### 刷新、成本与配额

- 菜单栏 2Hz，只有标题或颜色变化时改 attributedTitle；网络回调不直接绘制 UI。
- 曲线 1Hz、最多 600 点；仅弹出面板可见时构建图表，不使用高频动画。
- 请求、网络、日志使用后台串行队列；统计引擎短锁保护并发，没有锁内 I/O。
- 输入/输出单价按 **USD/百万 Token** 保存；CNY 只是用手填汇率换算显示。每请求记录开始时单价，之后改价不会改写历史费用。
- 费用不是企业账单；缓存输入按普通输入价，失败请求缺失 usage 时也可能有估算费用。
- 企业配额来自独立接口；手填总量仅定义上限，没有接口就显示已用/剩余/使用率未知。
- 配额达到 80% 标题黄色、95% 红色，不发通知或弹窗；过期数据不驱动新告警。

## 本机网关自动发现与隐私

启动时及点击“重新扫描”时读取 `$CODEX_HOME/config.toml`（未设置则 `~/.codex/config.toml`），只提取 `model`、`model_provider`、`profile` 以及 provider 的 `base_url`、`wire_api`。支持常见的单行字符串 TOML 与活动 profile；不支持的复杂形式不猜测、不导入。配置文件限制 1MB，不做目录递归扫描。

也识别当前进程中的 `OPENAI_BASE_URL`、`OPENAI_MODEL`、`OLLAMA_HOST`；从 Finder 启动时不一定继承终端环境。不会执行 shell 配置文件。企业客户端只要把自定义 provider 写入上述 Codex 配置，就能通过同一机制被发现；不需要硬编码公司名称或网关域名。

发现结果仅在本机内存和设置页展示，不联网验证，不写入统计日志。点击“填入”后仍需保存；更换 Endpoint 会清空表单中的旧推理/配额密钥及旧用量 URL，避免将旧凭据发给新上游。带 URL 用户名、密码、查询参数或 fragment 的候选整条拒绝导入。认证文件、浏览器数据、其他应用钥匙串和企业后台数据库均不属于发现范围。

发现网关地址不等于认证成功，也不自动接管 Codex 流量。需要认证时，用户仍须通过设置提供自己有权使用的 API Key。项目自己的密钥保存在专用 Keychain 中。完整数据处理说明见 [PRIVACY.md](PRIVACY.md)。

企业月度接口通常与推理接口不同；本项目不会猜测计费 URL 或把金额/积分当作 Token。需配置企业文档确认的接口与字段，详见 [配置说明](docs/CONFIGURATION.md)。

## 验证与限制

```bash
./script/test.sh
# 只运行核心检查：
swift run --build-system native TokenStatCoreChecks
```

测试会关闭当前 TokenStatMenu，运行隔离本地配置，使用纯测试令牌；不会访问企业网关。测试通过 `--test-fixture` 参数显式启动，菜单栏加“测试”前缀，面板常显橙色“模拟测试”标记。正常启动尚无流量时显示“未采集”，累计量为 `—`；存在估算请求时累计量带 `≈`。默认结束后关闭测试 App 和 mock 服务。可用 `python3 script/integration.py --keep-running` 保留测试面板作检查，注意面板里都是模拟数据。

测试报告见 `docs/VALIDATION.md`。核心测试是可执行程序，避免这台 CLT 缺少 XCTest 模块导致无法执行。

常见情况：

- **标题一直 — 或 0**：先确认客户端请求确实发往本机代理，并使用本机令牌；没有请求不能显示吞吐量。
- **企业配额未知**：检查 URL、独立用量 Key、字段路径和月份；推理 API 的 Key 不一定能访问企业计费接口。
- **图标不见**：macOS 可能关闭菜单栏项目或因刘海/其他图标拥挤而隐藏，任何 App 都不能保证绕过系统布局。检查“系统设置 → 菜单栏”。从 Finder 再次打开应用会主动打开面板。
- **关闭面板即退出**：本项目持有 status item 和 app delegate，并显式禁止最后窗口关闭时退出。
- **内存/CPU**：使用原生框架、有限缓冲与低频刷新，不会无限保存回答文本；SwiftUI/Charts 仍有系统开销，不承诺所有机器固定内存值。
- **代理断开**：App 退出后代理端口停止，调用方需恢复原 Endpoint 才能直接访问上游。
- **Xcode 报许可错误**：手动首次打开 Xcode 完成其许可流程。本项目脚本不代替用户接受协议。

纯测试数据必须显式附加 `--test-fixture`，此参数仅标记来源，不会自行生成数据。调试可显式附加 `--show-panel` 和 `--diagnostics-output /tmp/tokenstat-status.json`，后者每秒输出实际 AppKit 标题、popover 状态和用量摘要，不含密钥/请求正文。正常运行没有诊断文件写入。

## 上游格式参考

- [OpenAI Chat API](https://developers.openai.com/api/reference/resources/chat)
- [OpenAI Responses 流事件](https://developers.openai.com/api/reference/resources/responses/streaming-events)
- [Ollama Chat API](https://docs.ollama.com/api/chat)
- [Apple NWListener](https://developer.apple.com/documentation/network/nwlistener)

## 开源

[MIT License](LICENSE)。欢迎提交 Issue 或 Pull Request；请使用虚构域名、模型名与脱敏数据重现问题，不提交真实企业配置或日志。

发布前执行 `python3 script/package_source.py` 重新生成完整源码与源码包，再执行 `python3 script/check_public_content.py` 检查发布清单。Git 提交前使用 `--git-index` 检查实际暂存内容，并人工审查差异；检查脚本不会连接外部服务。

## 界面设计参考

视觉布局参考 [codexU](https://github.com/shanggqm/codexU) 的紧凑圆角卡片、半透明材质与蓝紫色强调。TokenStatMenu 的界面组件独立用 SwiftUI 实现，未复制其源码、图标、截图或配色资源。

离线界面预览：`python3 script/render_preview.py`，在 `dist/previews` 生成浅色/深色概览与设置页图片。预览明确标记模拟数据，使用独立内存模型，不读取本机配置或 Keychain、不发网络请求。
