# TokenStatMenu 完整源码

## 项目整体架构

```mermaid
flowchart LR
    Local[本机 Codex 有界会话记录] --> Reader[LocalCodexUsageReader 数字快照]
    Reader --> Menu
    Reader --> Panel
    Hub[已登录的 Token Hub 额度界面] -->|一次辅助功能授权| AX[有界只读 AX 扫描 + 双读一致性]
    AX --> Panel
    AX --> Menu
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

本机记录模式与代理模式分别显示数据，不混合累计。本机模式默认尝试自动读取已登录 Token Hub 的额度界面；完成一次 macOS 辅助功能授权后，无需填写接口、密钥或字段。它读取的是界面快照，后台更新时间未提供，账号和组织归属也未经核验；这不是企业计费接口的实时查询。本机记录不提供逐 Token 的实时流，仍只能显示有证据的上轮均速。代理模式用于观测实际流式请求，因为应用无法凭空读取其他进程的 TLS 流；它不修改系统代理，也不自动修改 Codex 或企业客户端配置。代理统计只覆盖启动后经过它的请求。


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
      - name: Compile UI test target and run OS-independent checks
        run: |
          swift test --filter TokenStatUISnapshotTests.testCredentialAccountNamesAreURLAndPurposeBoundWithoutKeychainIO
          swift test --filter TokenStatUISnapshotTests.testImageMatcherDetectsDeliberateMismatchWithoutRecording
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
    dependencies: [.package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.6")],
    targets: [
        .target(name: "TokenStatCore"),
        .executableTarget(name: "TokenStatMenu", dependencies: ["TokenStatCore"]),
        .executableTarget(name: "TokenStatCoreChecks", dependencies: ["TokenStatCore"], path: "Tests/TokenStatCoreTests"),
        .testTarget(name: "TokenStatUITests", dependencies: ["TokenStatMenu", .product(name: "SnapshotTesting", package: "swift-snapshot-testing")], path: "Tests/TokenStatUITests", exclude: ["__Snapshots__"])
    ]
)
```

### Sources/TokenStatCore/Configuration.swift

```swift
import Foundation

public struct AppConfiguration: Codable, Equatable {
    public var dataSource = "localCodex"
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
    public var fiveHourUsedPercentPath = "data.five_hour.used_percent"
    public var fiveHourResetPath = "data.five_hour.resets_at"
    public var sevenDayUsedPercentPath = "data.seven_day.used_percent"
    public var sevenDayResetPath = "data.seven_day.resets_at"
    public var refreshSeconds = 60.0
    public var loggingEnabled = false
    public var historyEnabled = true
    /// Automatically reads the visible Token Hub quota panel in local Codex mode.
    public var tokenHubAutomaticReadingEnabled = true
    public init() {}
    private enum CodingKeys: String, CodingKey { case dataSource, endpoint, model, port, includeUsage, allowInsecureHTTP, inputPrice, outputPrice, currency, usdToCNY, monthlyLimit, usageURL, usedPath, limitPath, periodPath, fiveHourUsedPercentPath, fiveHourResetPath, sevenDayUsedPercentPath, sevenDayResetPath, refreshSeconds, loggingEnabled, historyEnabled, tokenHubAutomaticReadingEnabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dataSource = try c.decodeIfPresent(String.self, forKey: .dataSource) ?? ((c.contains(.endpoint) || c.contains(.usageURL)) ? "proxy" : "localCodex")
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? "http://127.0.0.1:11434/v1/chat/completions"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""; port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 18765
        includeUsage = try c.decodeIfPresent(Bool.self, forKey: .includeUsage) ?? true; allowInsecureHTTP = try c.decodeIfPresent(Bool.self, forKey: .allowInsecureHTTP) ?? false
        inputPrice = try c.decodeIfPresent(Double.self, forKey: .inputPrice) ?? 0; outputPrice = try c.decodeIfPresent(Double.self, forKey: .outputPrice) ?? 0
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? "USD"; usdToCNY = try c.decodeIfPresent(Double.self, forKey: .usdToCNY) ?? 7
        monthlyLimit = try c.decodeIfPresent(Double.self, forKey: .monthlyLimit) ?? 0; usageURL = try c.decodeIfPresent(String.self, forKey: .usageURL) ?? ""
        usedPath = try c.decodeIfPresent(String.self, forKey: .usedPath) ?? "data.used_tokens"; limitPath = try c.decodeIfPresent(String.self, forKey: .limitPath) ?? "data.total_tokens"
        periodPath = try c.decodeIfPresent(String.self, forKey: .periodPath) ?? "data.month"
        fiveHourUsedPercentPath = try c.decodeIfPresent(String.self, forKey: .fiveHourUsedPercentPath) ?? "data.five_hour.used_percent"
        fiveHourResetPath = try c.decodeIfPresent(String.self, forKey: .fiveHourResetPath) ?? "data.five_hour.resets_at"
        sevenDayUsedPercentPath = try c.decodeIfPresent(String.self, forKey: .sevenDayUsedPercentPath) ?? "data.seven_day.used_percent"
        sevenDayResetPath = try c.decodeIfPresent(String.self, forKey: .sevenDayResetPath) ?? "data.seven_day.resets_at"
        refreshSeconds = try c.decodeIfPresent(Double.self, forKey: .refreshSeconds) ?? 60
        loggingEnabled = try c.decodeIfPresent(Bool.self, forKey: .loggingEnabled) ?? false; historyEnabled = try c.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? true
        tokenHubAutomaticReadingEnabled = try c.decodeIfPresent(Bool.self, forKey: .tokenHubAutomaticReadingEnabled) ?? true
    }

    public func validated() throws -> AppConfiguration {
        guard ["localCodex", "proxy"].contains(dataSource) else { throw StatError.message("无效数据来源") }
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

### Sources/TokenStatCore/LocalCodexUsageReader.swift

```swift
import Foundation
import CoreFoundation
import Darwin
import CryptoKit

public struct LocalCodexSnapshot: Equatable {
    public let input: Int
    public let output: Int
    public let total: Int
    public let sessionCount: Int
    public let filesScanned: Int
    public let isLimited: Bool
    public let latestEventAt: Date?
    public let fiveHour: WindowQuota?
    public let sevenDay: WindowQuota?
    public let lastTurn: LocalTurnSummary?
    public let knownThreadCount: Int
    public let unknownThreadCount: Int
    public let unidentifiedFileCount: Int
    public let subagentCount: Int
    public let forkCount: Int
    public var hasCompleteAccounting: Bool {
        knownThreadCount > 0 && unknownThreadCount == 0 && unidentifiedFileCount == 0 && !isLimited
    }

    public init(input: Int, output: Int, total: Int, sessionCount: Int, filesScanned: Int,
                isLimited: Bool, latestEventAt: Date?, fiveHour: WindowQuota?, sevenDay: WindowQuota?,
                knownThreadCount: Int = 0, unknownThreadCount: Int = 0, unidentifiedFileCount: Int = 0,
                subagentCount: Int = 0, forkCount: Int = 0, lastTurn: LocalTurnSummary? = nil) {
        self.input = input; self.output = output; self.total = total; self.sessionCount = sessionCount
        self.filesScanned = filesScanned; self.isLimited = isLimited; self.latestEventAt = latestEventAt
        self.fiveHour = fiveHour; self.sevenDay = sevenDay; self.lastTurn = lastTurn
        self.knownThreadCount = knownThreadCount; self.unknownThreadCount = unknownThreadCount
        self.unidentifiedFileCount = unidentifiedFileCount; self.subagentCount = subagentCount; self.forkCount = forkCount
    }
}

public struct LocalTurnSummary: Equatable {
    public let outputTokens: Int
    public let durationSeconds: Double
    public let completedAt: Date
    public var outputTPS: Double { Double(outputTokens) / durationSeconds }
    public init(outputTokens: Int, durationSeconds: Double, completedAt: Date) {
        self.outputTokens = outputTokens; self.durationSeconds = durationSeconds; self.completedAt = completedAt
    }
}

/// Completion-relative, generation-aware schedule for local usage scans.
public struct LocalRefreshScheduler {
    private(set) public var generation = 0
    private var inFlight: Int?
    private var nextDue = Date.distantPast
    public init() {}
    public mutating func begin(now: Date) -> Int? {
        guard inFlight == nil, now >= nextDue else { return nil }
        inFlight = generation
        return generation
    }
    @discardableResult public mutating func complete(generation token: Int, now: Date) -> Bool {
        guard inFlight == token, generation == token else { return false }
        inFlight = nil; nextDue = now.addingTimeInterval(5)
        return true
    }
    @discardableResult public mutating func invalidate() -> Int {
        generation += 1; inFlight = nil; nextDue = .distantPast
        return generation
    }
}

/// Reads bounded Codex usage records; unknown identity or lineage stays unknown.
public enum LocalCodexUsageReader {
    private static let maxEntries = 5_000
    private static let maxFiles = 32
    private static let headLimit = 64 * 1024
    private static let tailLimit = 256 * 1024
    private static let byteLimit = 10 * 1024 * 1024
    private static let maxIdentityBytes = 128
    private static let isoFormatter = ISO8601DateFormatter()
    private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
    }()
    private static let uuidPattern = try! NSRegularExpression(pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

    private struct Candidate { let name: String; let modified: Date }
    fileprivate struct Record { let date: Date; let input: Int; let output: Int; let total: Int; let five: WindowQuota?; let seven: WindowQuota?; let isRate: Bool }
    fileprivate struct FileSignature: Hashable {
        let device: UInt64; let inode: UInt64; let size: Int64
        let mtimeSec: Int64; let mtimeNSec: Int64; let ctimeSec: Int64; let ctimeNSec: Int64
        init(_ st: stat) {
            device = UInt64(st.st_dev); inode = UInt64(st.st_ino); size = Int64(st.st_size)
            mtimeSec = Int64(st.st_mtimespec.tv_sec); mtimeNSec = Int64(st.st_mtimespec.tv_nsec)
            ctimeSec = Int64(st.st_ctimespec.tv_sec); ctimeNSec = Int64(st.st_ctimespec.tv_nsec)
        }
    }
    fileprivate struct ParsedEvent {
        let date: Date; let type: String; let turnID: String?; let duration: Double?
        let totalTokens: Int?; let outputTokens: Int?; let hasCumulativePayload: Bool
        let usage: Record?; let rate: Record?; let quotaUpdate: QuotaUpdate; let threadID: String?
        let rawOrdinal: Int; let ownSettingsMatch: Bool; let invalidLifecycleTimestamp: Bool
    }
    fileprivate enum QuotaUpdate { case unchanged, replace(Record), clear }
    private enum QuotaState { case absent, value(Record) }
    fileprivate enum Lineage { case root, subagent, fork, unknown }
    fileprivate struct FileSummary {
        let identity: String?; let lineage: Lineage; let isFork: Bool; let sourceKnownTop: Bool
        let contribution: Record?; let rate: Record?; let quotaDate: Date?; let turn: LocalTurnSummary?
        let latestEventAt: Date?; let tailLimited: Bool; let headComplete: Bool; let hasFutureTurn: Bool
        let contentHash: String?; let signature: FileSignature
    }
    fileprivate struct CachedFileSummary { let summary: FileSummary }
    public final class Cache {
        public struct Diagnostics: Equatable {
            public fileprivate(set) var bytesRead = 0; public fileprivate(set) var parsedFiles = 0
            public fileprivate(set) var cacheHits = 0; public fileprivate(set) var safeOpens = 0
        }
        public private(set) var diagnostics = Diagnostics()
        public var entryCount: Int { entries.count }
        fileprivate var entries: [FileSignature: CachedFileSummary] = [:]
        fileprivate var rootIdentity: FileSignature?
        fileprivate var beforePostReadValidation: (() -> Void)?
        public init() {}
        init(beforePostReadValidation: @escaping () -> Void) { self.beforePostReadValidation = beforePostReadValidation }
        fileprivate func resetDiagnostics() { diagnostics = Diagnostics() }
        fileprivate func opened() { diagnostics.safeOpens += 1 }
        fileprivate func hit() { diagnostics.cacheHits += 1 }
        fileprivate func read(_ count: Int) { diagnostics.bytesRead += count }
        fileprivate func parsed() { diagnostics.parsedFiles += 1 }
    }

    public static func defaultSessionsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let configured = environment["CODEX_HOME"], configured.hasPrefix("/") { return URL(fileURLWithPath: configured).appendingPathComponent("sessions") }
        return home.appendingPathComponent(".codex").appendingPathComponent("sessions")
    }
    public static func scan(directory: URL, now: Date = Date()) throws -> LocalCodexSnapshot { try scan(directory: directory, now: now, cache: nil) }

    public static func scan(directory: URL, now: Date = Date(), cache: Cache?) throws -> LocalCodexSnapshot {
        cache?.resetDiagnostics()
        func empty() -> LocalCodexSnapshot { LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0, filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil) }
        var st = stat()
        guard lstat(directory.path, &st) == 0 else { cache?.entries.removeAll(); cache?.rootIdentity = nil; return empty() }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { cache?.entries.removeAll(); cache?.rootIdentity = nil; return empty() }
        let rootFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { cache?.entries.removeAll(); cache?.rootIdentity = nil; return empty() }
        defer { close(rootFD) }
        var opened = stat()
        guard fstat(rootFD, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFDIR else { cache?.entries.removeAll(); cache?.rootIdentity = nil; return empty() }
        let rootSignature = FileSignature(opened)
        if cache?.rootIdentity != rootSignature { cache?.entries.removeAll(); cache?.rootIdentity = rootSignature }

        var candidates: [Candidate] = [], directories = [""]
        var discoveryLimited = false
        var entries = 0, limited = false
        while let relative = directories.first, entries < maxEntries {
            directories.removeFirst()
            let dfd = relative.isEmpty ? dup(rootFD) : openDirectoryRelative(rootFD, relative)
            guard dfd >= 0, let listing = fdopendir(dfd) else { if dfd >= 0 { close(dfd) }; continue }
            while entries < maxEntries, let item = readdir(listing) {
                let leaf = withUnsafePointer(to: &item.pointee.d_name) { ptr in ptr.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) } }
                if leaf == "." || leaf == ".." { continue }
                entries += 1
                let name = relative.isEmpty ? leaf : relative + "/" + leaf
                var fst = stat(); guard fstatat(dfd, leaf, &fst, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                if (fst.st_mode & S_IFMT) == S_IFDIR { directories.append(name); continue }
                guard (fst.st_mode & S_IFMT) == S_IFREG, name.lowercased().hasSuffix(".jsonl") else { continue }
                candidates.append(Candidate(name: name, modified: Date(timeIntervalSince1970: Double(fst.st_mtimespec.tv_sec))))
            }
            closedir(listing)
        }
        if entries >= maxEntries { limited = true; discoveryLimited = true }
        candidates.sort { $0.modified == $1.modified ? $0.name < $1.name : $0.modified > $1.modified }
        if candidates.count > maxFiles { candidates = Array(candidates.prefix(maxFiles)); limited = true; discoveryLimited = true }

        var usedBytes = 0, filesScanned = 0, unidentified = 0, unsafeCandidate = false, coverageLimited = false
        var summaries: [FileSummary] = [], liveSignatures = Set<FileSignature>()
        for candidate in candidates {
            let fd = openRelative(rootFD, candidate.name); guard fd >= 0 else { unsafeCandidate = true; continue }
            defer { close(fd) }
            cache?.opened()
            var fst = stat(); guard fstat(fd, &fst) == 0, (fst.st_mode & S_IFMT) == S_IFREG, fst.st_size >= 0 else { unsafeCandidate = true; continue }
            guard isContained(fd: fd, rootFD: rootFD) else { unsafeCandidate = true; continue }
            let signature = FileSignature(fst); liveSignatures.insert(signature)
            if let cache, let old = cache.entries.keys.first(where: { $0.device == signature.device && $0.inode == signature.inode && $0 != signature }) {
                let timestampChanged = old.mtimeSec != signature.mtimeSec || old.mtimeNSec != signature.mtimeNSec || old.ctimeSec != signature.ctimeSec || old.ctimeNSec != signature.ctimeNSec
                if timestampChanged { cache.entries = cache.entries.filter { $0.key.device != signature.device || $0.key.inode != signature.inode } }
            }
            if fst.st_size < 0 { unsafeCandidate = true; continue }
        if let cached = cache?.entries[signature] {
                cache?.hit()
                let cachedSummary = cached.summary
                let refreshed = FileSummary(identity: cachedSummary.identity, lineage: cachedSummary.lineage,
                    isFork: cachedSummary.isFork,
                    sourceKnownTop: cachedSummary.sourceKnownTop, contribution: cachedSummary.contribution,
                    rate: cachedSummary.rate,
                    quotaDate: cachedSummary.quotaDate, turn: cachedSummary.hasFutureTurn ? nil : cachedSummary.turn, latestEventAt: cachedSummary.latestEventAt,
                    tailLimited: cachedSummary.tailLimited, headComplete: cachedSummary.headComplete,
                    hasFutureTurn: cachedSummary.hasFutureTurn, contentHash: cachedSummary.contentHash, signature: cachedSummary.signature)
                summaries.append(refreshed); filesScanned += 1
                if cached.summary.tailLimited || !cached.summary.headComplete { limited = true; coverageLimited = true }
                if cached.summary.hasFutureTurn { cache?.entries.removeValue(forKey: signature); unsafeCandidate = true }
                let cachedSize = Int(fst.st_size)
                let cacheCost = min(cachedSize, headLimit) + max(0, min(tailLimit, cachedSize - headLimit))
                if usedBytes + cacheCost > byteLimit { limited = true; coverageLimited = true; continue }
                usedBytes += cacheCost
                continue
            }
        let size = Int(fst.st_size), headCount = min(size, headLimit)
            let tailCount = size > headLimit ? min(tailLimit, size - headCount) : 0
        let amount = headCount + tailCount
            if amount == 0 { unidentified += 1; filesScanned += 1; continue }
            guard amount > 0, usedBytes + amount <= byteLimit else { limited = true; coverageLimited = true; break }
            usedBytes += amount
            var bytes = Data(count: amount)
            let readCount: Int = bytes.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return 0 }
                let h = pread(fd, base, headCount, 0); guard h == headCount else { return max(0, h) }
                if tailCount > 0 { return h + max(0, pread(fd, base.advanced(by: headCount), tailCount, off_t(size - tailCount))) }
                return h
            }
            guard readCount == amount else { cache?.read(readCount); unidentified += 1; limited = true; unsafeCandidate = true; continue }
            bytes.count = readCount; cache?.read(readCount)
            cache?.beforePostReadValidation?()
            var after = stat(); guard fstat(fd, &after) == 0, FileSignature(after) == signature else { cache?.entries.removeValue(forKey: signature); unsafeCandidate = true; continue }
            cache?.parsed()
            let parsed = parseFile(bytes: bytes, size: size, now: now, signature: signature)
            filesScanned += 1
            if parsed.identity == nil { unidentified += 1 }
            if parsed.tailLimited || !parsed.headComplete { limited = true; coverageLimited = true }
            summaries.append(parsed)
            if let cache, parsed.identity != nil {
                cache.entries[signature] = CachedFileSummary(summary: parsed)
                if cache.entries.count > maxFiles { cache.entries.removeValue(forKey: cache.entries.keys.first!) }
            }
        }
        if let cache { cache.entries = cache.entries.filter { liveSignatures.contains($0.key) } }
        _ = discoveryLimited

        // Same inode is one physical history. Same ID is one logical thread only if whole bytes match.
        var physicalSeen = Set<FileSignature>()
        summaries = summaries.filter { physicalSeen.insert($0.signature).inserted }
        let allRates = summaries.compactMap { summary -> (Date, Record?)? in summary.quotaDate.map { ($0, summary.rate) } }
        let quotaWinner = allRates.enumerated().reduce(nil as (offset: Int, element: (Date, Record?))?) { best, current in
            guard let best else { return (current.offset, current.element) }
            return current.element.0 >= best.element.0 ? (current.offset, current.element) : best
        }?.element
        var grouped: [String: [FileSummary]] = [:]
        let unidentifiedCount = unidentified
        for summary in summaries {
            guard let identity = summary.identity else { continue }
            grouped[identity, default: []].append(summary)
        }
        var known: [Record] = [], unknownThreads = 0, topLevelCount = 0, subagentCount = 0, forkCount = 0
        var latestTurn: LocalTurnSummary?, latestEvent: Date?
        for (_, variants) in grouped {
            let hashes = variants.compactMap(\.contentHash)
            guard variants.count == 1 || hashes.count == variants.count && Set(hashes).count == 1,
                  variants.allSatisfy({ $0.lineage == variants[0].lineage && $0.isFork == variants[0].isFork }) else { unknownThreads += 1; continue }
            let summary = variants[0]
            if summary.lineage == .unknown { unknownThreads += 1 }
            else {
                if summary.sourceKnownTop && summary.lineage == .root { topLevelCount += 1 }
                if summary.lineage == .subagent { subagentCount += 1 }
                if summary.isFork { forkCount += 1 }
                if let contribution = summary.contribution { known.append(contribution) } else { unknownThreads += 1 }
            }
            if let turn = summary.turn, turn.completedAt <= now, latestTurn == nil || turn.completedAt > latestTurn!.completedAt { latestTurn = turn }
            if let event = summary.latestEventAt, latestEvent == nil || event > latestEvent! { latestEvent = event }
        }
        var input = 0, output = 0, total = 0
        for record in known {
            let (i, io) = input.addingReportingOverflow(record.input), (o, oo) = output.addingReportingOverflow(record.output), (t, ot) = total.addingReportingOverflow(record.total)
            guard !io && !oo && !ot else { throw StatError.message("本地用量汇总超出可表示范围") }
            input = i; output = o; total = t
        }
        let finalRate = quotaWinner?.1
        return LocalCodexSnapshot(input: input, output: output, total: total, sessionCount: topLevelCount,
            filesScanned: filesScanned, isLimited: limited || unsafeCandidate || coverageLimited, latestEventAt: latestEvent,
            fiveHour: finalRate?.five, sevenDay: finalRate?.seven, knownThreadCount: known.count,
            unknownThreadCount: unknownThreads, unidentifiedFileCount: unidentifiedCount,
            subagentCount: subagentCount, forkCount: forkCount, lastTurn: latestTurn)
    }

    private static func parseFile(bytes: Data, size: Int, now: Date, signature: FileSignature) -> FileSummary {
        let headLength = min(size, headLimit), tailLength = max(0, bytes.count - headLength)
        let head = bytes.prefix(headLength), tail = tailLength > 0 ? bytes.suffix(tailLength) : Data()
        let tailLimited = size > headLimit + tailLimit
        let wholeFileRead = size <= headLimit + tailLimit
        let headComplete = wholeFileRead || size <= headLimit || head.last == 10
        let headLines = wholeFileRead ? completeLines(Data(bytes), startsAtFileStart: true, endsAtFileEnd: size <= bytes.count && bytes.last == 10) : completeLines(Data(head), startsAtFileStart: true, endsAtFileEnd: false)
        let tailLines = !wholeFileRead && tailLength > 0 ? completeLines(Data(tail), startsAtFileStart: false, endsAtFileEnd: true) : []
        let headSlots = headLines.enumerated().map { parseLine($0.element, fallbackOrdinal: $0.offset) }
        let decodedHead = headSlots.compactMap { $0 }
        let physicalRecordCountHead = headLines.count
        let tailOrdinalBase = size > headLimit + tailLimit ? -1 : physicalRecordCountHead
        let tailSlots = tailLines.enumerated().map { parseLine($0.element, fallbackOrdinal: tailOrdinalBase < 0 ? -1 : tailOrdinalBase + $0.offset) }
        let decodedTail = tailSlots.compactMap { $0 }
        var decoded = tailLength > 0 ? decodedHead + decodedTail : decodedHead
        let continuousRead = wholeFileRead
        let incompleteTail = bytes.last != 10
            ? Data(bytes[(bytes.lastIndex(of: 10).map { bytes.index(after: $0) } ?? bytes.startIndex)...])
            : Data()
        let hasIncompleteTailFragment = !incompleteTail.isEmpty
        let identity: String?
        let firstPhysicalLine = completeLines(Data(bytes.prefix(headLength)), startsAtFileStart: true, endsAtFileEnd: size <= headLength).first
        if let first = firstPhysicalLine, !first.isEmpty, let object = try? JSONSerialization.jsonObject(with: Data(first)),
           let root = object as? [String: Any], root["type"] as? String == "session_meta",
           let id = (root["payload"] as? [String: Any])?["id"] as? String, let normalized = normalizeUUID(id) { identity = normalized }
        else { identity = nil }
        guard let identity else {
            return FileSummary(identity: nil, lineage: .unknown, isFork: false, sourceKnownTop: false, contribution: nil, rate: nil,
                quotaDate: nil, turn: nil, latestEventAt: nil, tailLimited: tailLimited, headComplete: headComplete, hasFutureTurn: false,
                contentHash: bytes.fullContentHashIfComplete(fileSize: size), signature: signature)
        }
        func remap(_ event: ParsedEvent) -> ParsedEvent {
            ParsedEvent(date: event.date, type: event.type, turnID: event.turnID, duration: event.duration,
                totalTokens: event.totalTokens, outputTokens: event.outputTokens, hasCumulativePayload: event.hasCumulativePayload,
                usage: event.usage, rate: event.rate, quotaUpdate: event.quotaUpdate, threadID: event.threadID,
                rawOrdinal: event.rawOrdinal, ownSettingsMatch: event.type == "thread_settings_applied" && event.threadID == identity,
                invalidLifecycleTimestamp: event.invalidLifecycleTimestamp)
        }
        let mappedHeadSlots = headSlots.map { $0.map(remap) }
        let mappedTailSlots = tailSlots.map { $0.map(remap) }
        decoded = (wholeFileRead ? mappedHeadSlots : mappedHeadSlots + mappedTailSlots).compactMap { $0 }
        guard let firstMetaLine = firstPhysicalLine else { return FileSummary(identity: nil, lineage: .unknown, isFork: false, sourceKnownTop: false, contribution: nil, rate: nil, quotaDate: nil, turn: nil, latestEventAt: nil, tailLimited: tailLimited, headComplete: headComplete, hasFutureTurn: false, contentHash: bytes.fullContentHashIfComplete(fileSize: size), signature: signature) }
        let metadata = (try? JSONSerialization.jsonObject(with: Data(firstMetaLine))) as? [String: Any]
        let payload = metadata?["payload"] as? [String: Any] ?? [:]
        let (source, sourceSubagentKind) = sessionSource(payload["source"])
        let threadSource = payload["thread_source"] as? String
        let sourceIsRootString = payload["source"] as? String == source && isTopRootSource(source)
        let subagent = isKnownSubagent(source: source, subagentKind: sourceSubagentKind, threadSource: threadSource, payload: payload)
        let parentMarkers = ["forked_from_id", "parent_thread_id", "history_base"].contains { payload[$0] != nil && !(payload[$0] is NSNull) }
        let hasHistoryStart = payload["subagent_history_start_ordinal"] != nil && !(payload["subagent_history_start_ordinal"] is NSNull)
        let hasUnresolvedSubagentMarker = !subagent && (
            payload["subagent"] != nil ||
            (payload["thread_source"] != nil && payload["thread_source"] as? String != "user")
                || ["agent_nickname", "agent_role", "agent_path"].contains { payload[$0] != nil }
        )
        let malformedLineage = hasMalformedLineage(payload)
        let hasHistoryBase = payload["history_base"] != nil && !(payload["history_base"] is NSNull)
        let inheritsHistory = parentMarkers || hasHistoryStart
        let sourceKnown = sourceIsRootString || subagent
        let lineage: Lineage = malformedLineage || hasUnresolvedSubagentMarker || !sourceKnown
            ? .unknown : (subagent ? .subagent : (inheritsHistory ? .fork : .root))
        let isFork = !malformedLineage && (parentMarkers || hasHistoryStart)
        let sourceKnownTop = sourceIsRootString && !subagent && !inheritsHistory
        let tokenEvents = decoded.filter { $0.type == "token_count" }
        let cumulativeTokenEvents = tokenEvents.filter(\.hasCumulativePayload)
        let validCounters = cumulativeTokenEvents.filter { $0.usage != nil }
        let lastToken = cumulativeTokenEvents.last
        let observedLineSegments = wholeFileRead ? [mappedHeadSlots] : [mappedHeadSlots, mappedTailSlots]
        let latestCounterSegment = observedLineSegments.lastIndex(where: { $0.contains(where: { $0?.hasCumulativePayload == true }) })
        let hasBadLineAfterLatestCounter: Bool = {
            guard let segmentIndex = latestCounterSegment, let lineIndex = observedLineSegments[segmentIndex].lastIndex(where: { $0?.hasCumulativePayload == true }) else { return false }
            return observedLineSegments[segmentIndex].dropFirst(lineIndex + 1).contains(where: { $0 == nil })
        }()
        let latestCounterInTail = !wholeFileRead && !mappedTailSlots.isEmpty && mappedTailSlots.contains(where: { $0?.hasCumulativePayload == true })
        let forkHasCompleteLines = wholeFileRead && mappedHeadSlots.allSatisfy { $0 != nil } && incompleteTail.isEmpty
        var contribution: Record? = nil
        if lineage == .root {
            if let lastToken, let usage = lastToken.usage,
               !cumulativeTokenEvents.contains(where: \.invalidLifecycleTimestamp), !hasIncompleteTailFragment,
               !hasBadLineAfterLatestCounter, (wholeFileRead || latestCounterInTail) { contribution = usage }
        } else if (lineage == .subagent || lineage == .fork), !hasHistoryBase, headComplete, !tailLimited,
                  continuousRead, forkHasCompleteLines, let delta = forkContribution(payload: payload, events: decoded) { contribution = delta }
        let rateEvents = tokenEvents.map { ($0.date, $0.quotaUpdate) }
        let resolvedQuota = resolveRate(rateEvents, now: now)
        let rate = resolvedQuota.record
        let turnSegments = observedLineSegments.flatMap { parsedSegments($0) }
        let turn = turnSegments.compactMap { completedTurns(in: $0, now: now) }.max(by: { $0.completedAt < $1.completedAt })
        let latestUsageDate = validCounters.last?.date
        return FileSummary(identity: identity, lineage: lineage, isFork: isFork, sourceKnownTop: sourceKnownTop,
            contribution: contribution, rate: rate, quotaDate: resolvedQuota.date, turn: turn, latestEventAt: latestUsageDate,
            tailLimited: tailLimited, headComplete: headComplete,
            hasFutureTurn: decoded.contains(where: { $0.type == "task_complete" && $0.date > now }),
            contentHash: bytes.fullContentHashIfComplete(fileSize: size), signature: signature)
    }

    private static func forkContribution(payload: [String: Any], events: [ParsedEvent]) -> Record? {
        let explicit = uint(payload["subagent_history_start_ordinal"])
        let settings = events.filter(\.ownSettingsMatch)
        let inferred = settings.first?.rawOrdinal
        if let explicit, let inferred, explicit != UInt64(inferred) { return nil }
        let boundary: Int
        if let explicit, explicit <= UInt64(Int.max) { boundary = Int(explicit) }
        else if payload["subagent_history_start_ordinal"] != nil && !(payload["subagent_history_start_ordinal"] is NSNull) { return nil }
        else if let inferred { boundary = inferred }
        else { return nil }
        // Ordinals are zero-based record positions. Ensure every record through final counter was read.
        guard boundary >= 0, events.contains(where: { $0.rawOrdinal == boundary }), events.allSatisfy({ $0.rawOrdinal >= 0 }) else { return nil }
        let before = events.filter { $0.rawOrdinal >= 0 && $0.rawOrdinal < boundary && $0.type == "token_count" && $0.hasCumulativePayload }
        let after = events.filter { $0.rawOrdinal >= boundary && $0.type == "token_count" && $0.hasCumulativePayload }
        guard let baseline = before.last?.usage, let final = after.last?.usage,
              after.allSatisfy({ $0.usage != nil }) else { return nil }
        let history = events.filter { $0.rawOrdinal >= 0 && $0.rawOrdinal < boundary && $0.type == "token_count" && $0.hasCumulativePayload }
        guard history.allSatisfy({ $0.usage != nil }) else { return nil }
        let sequence = history.compactMap(\.usage) + after.compactMap(\.usage)
        guard isMonotonic(sequence.map(\.input)), isMonotonic(sequence.map(\.output)), isMonotonic(sequence.map(\.total)) else { return nil }
        let i = final.input - baseline.input, o = final.output - baseline.output, t = final.total - baseline.total
        guard i >= 0, o >= 0, t >= 0 else { return nil }
        return Record(date: final.date, input: i, output: o, total: t, five: nil, seven: nil, isRate: false)
    }

    private static func parseLine(_ line: Data.SubSequence, fallbackOrdinal: Int) -> ParsedEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)), let root = object as? [String: Any],
              let type = root["type"] as? String else { return nil }
        let payload = root["payload"] as? [String: Any] ?? [:]
        let date = parseDate(root["timestamp"]) ?? .distantPast
        let eventType = type == "event_msg" ? (payload["type"] as? String ?? "") : type
        var usage: Record?, rate: Record?
        let info = payload["info"] as? [String: Any]
        let cumulativePresent = info?.keys.contains("total_token_usage") == true
        let cumulative = info?["total_token_usage"] as? [String: Any]
        if eventType == "token_count", let cumulative,
           let i = integer(cumulative["input_tokens"]), let o = integer(cumulative["output_tokens"]), let t = integer(cumulative["total_tokens"]) {
            usage = Record(date: date, input: i, output: o, total: t, five: nil, seven: nil, isRate: false)
        }
        let quota = eventType == "token_count" ? quotaUpdate(payload["rate_limits"], at: date) : .unchanged
        if case .replace(let r) = quota { rate = r }
        let duration: Double?
        if payload.keys.contains("duration_ms") {
            if let n = payload["duration_ms"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue >= 0 { duration = n.doubleValue }
            else { duration = .nan }
        } else { duration = nil }
        let ownID = normalizeUUID((payload["id"] as? String) ?? "")
        let eventThread = normalizeUUID((payload["thread_id"] as? String) ?? "")
        let invalidLifecycleTimestamp = ["task_started", "task_complete", "turn_aborted", "token_count"].contains(eventType) && parseDate(root["timestamp"]) == nil
        return ParsedEvent(date: date, type: eventType, turnID: payload["turn_id"] as? String,
            duration: duration, totalTokens: usage?.total, outputTokens: usage?.output,
            hasCumulativePayload: cumulativePresent, usage: usage, rate: rate, quotaUpdate: quota,
            threadID: eventThread, rawOrdinal: fallbackOrdinal,
            ownSettingsMatch: eventType == "thread_settings_applied" && ownID != nil && eventThread == ownID,
            invalidLifecycleTimestamp: invalidLifecycleTimestamp)
    }

    private static func completeLines(_ data: Data, startsAtFileStart: Bool, endsAtFileEnd: Bool) -> [Data.SubSequence] {
        guard !data.isEmpty else { return [] }
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if !startsAtFileStart { lines.removeFirst() }
        lines.removeLast()
        _ = endsAtFileEnd
        return lines
    }

    private static func parsedSegments(_ slots: [ParsedEvent?]) -> [[ParsedEvent]] {
        var segments: [[ParsedEvent]] = [], current: [ParsedEvent] = []
        for slot in slots {
            if let event = slot { current.append(event) }
            else if !current.isEmpty { segments.append(current); current.removeAll(keepingCapacity: true) }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    private static func quotaUpdate(_ value: Any?, at date: Date) -> QuotaUpdate {
        guard let value else { return .unchanged }
        guard !(value is NSNull), let object = value as? [String: Any] else { return .unchanged }
        if object.isEmpty { return .clear }
        guard object.keys.contains("primary") || object.keys.contains("secondary") else { return .unchanged }
        var windows: [WindowQuota] = []
        for key in ["primary", "secondary"] {
            guard let slot = object[key], !(slot is NSNull) else { continue }
            guard let item = slot as? [String: Any], let percent = number(item["used_percent"]), (0...100).contains(percent) else { return .unchanged }
            let duration: Int?
            if let raw = item["window_minutes"], !(raw is NSNull) { guard let n = integer(raw), n > 0 else { return .unchanged }; duration = n } else { duration = nil }
            let reset: Date?
            if let raw = item["resets_at"], !(raw is NSNull) { guard let seconds = integer(raw), let value = Double(exactly: seconds), value <= 253402300799 else { return .unchanged }; reset = Date(timeIntervalSince1970: value) } else { reset = nil }
            windows.append(WindowQuota(minutes: duration ?? 0, usedPercent: percent, resetsAt: reset, fetchedAt: date))
        }
        if windows.count == 2, windows[0].minutes > 0, windows[1].minutes > 0, windows[0].minutes == windows[1].minutes { return .unchanged }
        let five = windows.filter { $0.minutes == 300 }.only
        let seven = windows.filter { $0.minutes == 10080 }.only
        let record = Record(date: date, input: 0, output: 0, total: 0, five: five, seven: seven, isRate: true)
        return .replace(record)
    }

    private static func resolveRate(_ updates: [(Date, QuotaUpdate)], now: Date) -> (record: Record?, date: Date?) {
        var state = QuotaState.absent
        var latestDate: Date?
        for (date, update) in updates.enumerated().sorted(by: { lhs, rhs in lhs.element.0 == rhs.element.0 ? lhs.offset < rhs.offset : lhs.element.0 < rhs.element.0 }).map(\.element) {
            switch update {
            case .unchanged: break
            case .clear: state = .absent; latestDate = date
            case .replace(let record): state = .value(record); latestDate = date
            }
        }
        if case .value(let value) = state { return (value, latestDate) }
        return (nil, latestDate)
    }

    private static func completedTurns(in events: [ParsedEvent], now: Date) -> LocalTurnSummary? {
        var result: [LocalTurnSummary] = []
        for (startIndex, start) in events.enumerated() where start.type == "task_started" {
            guard let id = start.turnID, !id.isEmpty else { continue }
            var activeIDs: [String] = []
            for event in events[..<startIndex] {
                if event.type == "task_started", let activeID = event.turnID { activeIDs.append(activeID) }
                if event.type == "task_complete", let completedID = event.turnID,
                   let index = activeIDs.lastIndex(of: completedID) { activeIDs.remove(at: index) }
                if event.type == "turn_aborted" {
                    if let abortedID = event.turnID, let index = activeIDs.lastIndex(of: abortedID) { activeIDs.remove(at: index) }
                    else if event.turnID == nil { activeIDs.removeAll() }
                }
            }
            guard activeIDs.isEmpty else { continue }
            let completes = events.enumerated().filter { $0.element.type == "task_complete" && $0.element.turnID == id && $0.offset > startIndex }
            guard let (endIndex, complete) = completes.first else { continue }
            // Reused identifiers and overlapping turns make token attribution ambiguous.
            guard !events.enumerated().contains(where: { $0.offset > startIndex && $0.offset < endIndex && $0.element.type == "task_started" }) else { continue }
            guard !events.enumerated().contains(where: { $0.offset > startIndex && $0.offset < endIndex && $0.element.type == "task_complete" && $0.element.turnID != id }) else { continue }
            guard !events[startIndex..<endIndex].contains(where: { $0.type == "turn_aborted" && ($0.turnID == nil || $0.turnID == id) }) else { continue }
            guard !events[startIndex...endIndex].contains(where: \.invalidLifecycleTimestamp) else { continue }
            let intervalDates = events[startIndex...endIndex].map(\.date)
            guard zip(intervalDates, intervalDates.dropFirst()).allSatisfy({ $0 <= $1 }) else { continue }
            let earlierStarts = events[..<startIndex].filter { $0.type == "task_started" && $0.turnID == id }
            guard earlierStarts.isEmpty else { continue }
            guard !events.enumerated().contains(where: { $0.offset > endIndex && $0.element.type == "task_started" && $0.element.turnID == id }) else { continue }
            var durationMS: Double?
            if let duration = complete.duration { durationMS = duration }
            else { durationMS = complete.date.timeIntervalSince(start.date) * 1000 }
            guard let durationMS, durationMS.isFinite, durationMS >= 100 else { continue }
            let baselineEvents = events[..<startIndex].filter {
                $0.type == "token_count" && $0.hasCumulativePayload
            }
            guard let baseline = baselineEvents.last, !baseline.invalidLifecycleTimestamp,
                  baseline.date <= start.date, let baselineTotal = baseline.totalTokens,
                  let baselineOutput = baseline.outputTokens else { continue }
            let inTurn = events[(startIndex + 1)..<endIndex].filter { $0.type == "token_count" && $0.hasCumulativePayload }
            guard !inTurn.isEmpty, inTurn.allSatisfy({ !$0.invalidLifecycleTimestamp && $0.totalTokens != nil && $0.outputTokens != nil }) else { continue }
            let totals = inTurn.compactMap(\.totalTokens), outputs = inTurn.compactMap(\.outputTokens)
            guard let lastTotal = totals.last, lastTotal >= baselineTotal, totals.first! >= baselineTotal,
                  let lastOutput = outputs.last, lastOutput >= baselineOutput, outputs.first! >= baselineOutput,
                  zip(totals, totals.dropFirst()).allSatisfy({ $0 <= $1 }),
                  zip(outputs, outputs.dropFirst()).allSatisfy({ $0 <= $1 }) else { continue }
            let duration = complete.duration ?? complete.date.timeIntervalSince(start.date) * 1000
            guard duration.isFinite, duration >= 100 else { continue }
            let summary = LocalTurnSummary(outputTokens: lastOutput - baselineOutput,
                durationSeconds: duration / 1000, completedAt: complete.date)
            if complete.date <= now { result.append(summary) }
        }
        return result.max(by: { $0.completedAt < $1.completedAt })
    }

    private static func sessionSource(_ raw: Any?) -> (String?, String?) {
        guard let raw else { return (nil, nil) }
        if let value = raw as? String { return (value, nil) }
        guard let object = raw as? [String: Any], object.count == 1,
              let nested = object["subagent"] else { return ("<invalid>", nil) }
        if let kind = nested as? String, ["review", "compact", "memory_consolidation"].contains(kind) {
            return ("subagent_\(kind)", kind)
        }
        if let value = nested as? [String: Any], value.count == 1, let details = value["thread_spawn"] as? [String: Any],
           validThreadSpawn(details) { return ("subagent_thread_spawn", "thread_spawn") }
        return ("<invalid>", nil)
    }
    private static func isKnownSubagent(source: String?, subagentKind: String?, threadSource: String?, payload: [String: Any]) -> Bool {
        _ = source; _ = threadSource; _ = payload
        return ["review", "compact", "memory_consolidation", "thread_spawn"].contains(subagentKind ?? "")
    }
    private static func validThreadSpawn(_ object: [String: Any]) -> Bool {
        guard let parent = object["parent_thread_id"] as? String, normalizeUUID(parent) != nil,
              let depth = object["depth"] as? NSNumber, CFGetTypeID(depth) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: depth.objCType)), Int32(depth.stringValue) != nil else { return false }
        return true
    }
    private static func hasMalformedLineage(_ payload: [String: Any]) -> Bool {
        if payload["subagent"] != nil { return true }
        for key in ["forked_from_id", "parent_thread_id"] where payload[key] != nil && !(payload[key] is NSNull) {
            guard let value = payload[key] as? String, normalizeUUID(value) != nil else { return true }
        }
        if let raw = payload["subagent_history_start_ordinal"], !(raw is NSNull), uint(raw) == nil { return true }
        if let raw = payload["history_base"], !(raw is NSNull) {
            guard let base = raw as? [String: Any], let id = base["thread_id"] as? String,
                  normalizeUUID(id) != nil, uint(base["end_ordinal_exclusive"]) != nil,
                  uint(base["end_byte_offset"]) != nil else { return true }
        }
        if payload["source"] != nil, sessionSource(payload["source"]).0 == "<invalid>" { return true }
        return false
    }
    private static func isTopRootSource(_ source: String?) -> Bool { ["cli", "vscode", "exec", "mcp"].contains(source ?? "") }
    private static func normalizeUUID(_ value: String) -> String? {
        guard value.utf8.count <= maxIdentityBytes else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard uuidPattern.firstMatch(in: value, range: range) != nil, UUID(uuidString: value) != nil else { return nil }
        return value.lowercased()
    }
    private static func uint(_ value: Any?) -> UInt64? {
        guard let n = integer(value), let u = UInt64(exactly: n) else { return nil }; return u
    }
    private static func isMonotonic(_ values: [Int]) -> Bool { zip(values, values.dropFirst()).allSatisfy { $0 <= $1 } }
    private static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue >= 0 else { return nil }
        let decimal = n.decimalValue
        var rounded = Decimal()
        var copy = decimal
        NSDecimalRound(&rounded, &copy, 0, .plain)
        guard rounded == decimal else { return nil }
        let type = String(cString: n.objCType)
        guard let result = Int(n.stringValue), result >= 0 else { return nil }
        if ["f", "d"].contains(type), Double(result) != n.doubleValue { return nil }
        return result
    }
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }; return n.doubleValue
    }
    private static func parseDate(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        return fractionalISOFormatter.date(from: raw) ?? isoFormatter.date(from: raw)
    }
    private static func window(_ value: Any?, minutes: Int, now: Date, at date: Date) -> WindowQuota? {
        guard let object = value as? [String: Any], integer(object["window_minutes"]) == minutes,
              let percent = number(object["used_percent"]), (0...100).contains(percent) else { return nil }
        let reset = integer(object["resets_at"]).flatMap { Date(timeIntervalSince1970: Double($0)) }
        _ = now
        return WindowQuota(minutes: minutes, usedPercent: percent, resetsAt: reset, fetchedAt: date)
    }
    private static func completedTurns(in events: [ParsedEvent]) -> [LocalTurnSummary] { completedTurns(in: events, now: .distantFuture).map { [$0] } ?? [] }
    private static func openRelative(_ rootFD: Int32, _ path: String) -> Int32 {
        let parts = path.split(separator: "/").map(String.init); guard let leaf = parts.last else { return -1 }
        var current = dup(rootFD); guard current >= 0 else { return -1 }
        for component in parts.dropLast() {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW); close(current)
            guard next >= 0 else { return -1 }; current = next
        }
        let fd = openat(current, leaf, O_RDONLY | O_NOFOLLOW); close(current); return fd
    }
    private static func openDirectoryRelative(_ rootFD: Int32, _ path: String) -> Int32 {
        let parts = path.split(separator: "/").map(String.init); var current = dup(rootFD); guard current >= 0 else { return -1 }
        for component in parts { let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW); close(current); guard next >= 0 else { return -1 }; current = next }
        return current
    }
    private static func isContained(fd: Int32, rootFD: Int32) -> Bool {
        var pathBuffer = [CChar](repeating: 0, count: Int(PATH_MAX)); var rootBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let p = fcntl(fd, F_GETPATH, &pathBuffer), r = fcntl(rootFD, F_GETPATH, &rootBuffer)
        guard p == 0, r == 0 else { return false }
        let path = String(cString: pathBuffer), root = String(cString: rootBuffer)
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

private extension Data {
    func fullContentHashIfComplete(fileSize: Int) -> String? {
        guard count == fileSize else { return nil }
        return SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
private extension Array { var only: Element? { count == 1 ? first : nil } }
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

### Sources/TokenStatCore/WindowQuota.swift

```swift
import Foundation
import CoreFoundation

public struct WindowQuota: Codable, Equatable {
    public let minutes: Int
    public let usedPercent: Double
    public let resetsAt: Date?
    public let fetchedAt: Date
    public var remainingPercent: Double { max(0, 100 - usedPercent) }
    public func isFresh(at now: Date = Date(), refreshSeconds: Double) -> Bool {
        fetchedAt <= now && now.timeIntervalSince(fetchedAt) < max(120, refreshSeconds * 2)
            && (resetsAt.map { $0 > now } ?? true)
    }
}

/// Monthly and rolling-window quotas are independent facts; missing one must not
/// erase the others. No quota is inferred from local token/request counters.
public struct QuotaReport {
    public let monthly: QuotaSnapshot?
    public let monthlyMessage: String
    public let fiveHour: WindowQuota?
    public let sevenDay: WindowQuota?

    public static func parse(_ data: Data, config: AppConfiguration, now: Date = Date()) throws -> QuotaReport {
        let object = try JSONSerialization.jsonObject(with: data)
        var monthly: QuotaSnapshot?, monthlyMessage = ""
        do { monthly = try QuotaSnapshot.parse(data, config: config, now: now) }
        catch { monthlyMessage = "月度用量未提供，或月度字段 / 月份未匹配" }
        func value(_ path: String) -> Any? {
            guard !path.isEmpty else { return nil }
            return path.split(separator: ".").reduce(Optional(object)) { node, key in
                if let dict = node as? [String: Any] { return dict[String(key)] }
                if let array = node as? [Any], let i = Int(key), array.indices.contains(i) { return array[i] }
                return nil
            }
        }
        func configured(_ minutes: Int, percentPath: String, resetPath: String) -> WindowQuota? {
            if let raw = value(percentPath), !(raw is NSNull) {
                guard let percent = number(raw), (0...100).contains(percent) else { return nil }
                return WindowQuota(minutes: minutes, usedPercent: percent,
                    resetsAt: resetDate(value(resetPath)), fetchedAt: now)
            }
            // Also accept the published Codex rateLimits shape from this same configured
            // endpoint. Duration, not primary/secondary order, determines the window.
            let root = object as? [String: Any] ?? [:]
            let payload = root["result"] as? [String: Any] ?? root
            guard let limits = payload["rateLimits"] as? [String: Any] else { return nil }
            let matches = ["primary", "secondary"].compactMap { limits[$0] as? [String: Any] }
                .filter { number($0["windowDurationMins"]) == Double(minutes) }
            guard matches.count == 1, let window = matches.first,
                  let percent = number(window["usedPercent"]), (0...100).contains(percent) else { return nil }
            return WindowQuota(minutes: minutes, usedPercent: percent,
                resetsAt: resetDate(window["resetsAt"]), fetchedAt: now)
        }
        let five = configured(300, percentPath: config.fiveHourUsedPercentPath, resetPath: config.fiveHourResetPath)
        let seven = configured(10080, percentPath: config.sevenDayUsedPercentPath, resetPath: config.sevenDayResetPath)
        guard monthly != nil || five != nil || seven != nil else {
            throw StatError.message("接口未返回有效月度、5 小时或 7 天额度；请检查字段映射和单位")
        }
        return QuotaReport(monthly: monthly, monthlyMessage: monthlyMessage, fiveHour: five, sevenDay: seven)
    }
    private static func number(_ value: Any?) -> Double? {
        let result: Double?
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { result = n.doubleValue }
        else if let text = value as? String { result = Double(text) }
        else { return nil }
        guard let result, result.isFinite else { return nil }
        return result
    }
    private static func resetDate(_ value: Any?) -> Date? {
        // Numeric timestamps are Unix seconds, never guessed as milliseconds.
        if let seconds = number(value), seconds > 0, seconds < 100_000_000_000 {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
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

### Sources/TokenStatCore/TokenHubQuota.swift

```swift
import Foundation
import Darwin

public enum TokenHubTarget {
    public static let bundleID = "com.seasun.tokenhub.desktop"
}

public struct TokenHubIdentity: Equatable, Sendable {
    public let pid: pid_t
    public let bundleID: String
    public let executablePath: String

    public init(pid: pid_t, bundleID: String, executablePath: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.executablePath = URL(fileURLWithPath: executablePath).standardizedFileURL.path
    }
}

public enum TokenHubWindowKind: String, Equatable, Sendable { case fiveHour, sevenDay }

public struct TokenHubWindowQuota: Equatable, Sendable {
    public let kind: TokenHubWindowKind
    public let usedAmount: Decimal
    public let limitAmount: Decimal
    public let sourceSymbol: String
    public let usedPercent: Decimal
    public var remainingPercent: Decimal { Decimal(100) - usedPercent }
    public let resetDisplay: String

    public init(kind: TokenHubWindowKind, usedAmount: Decimal, limitAmount: Decimal,
                sourceSymbol: String, usedPercent: Decimal, resetDisplay: String) {
        self.kind = kind; self.usedAmount = usedAmount; self.limitAmount = limitAmount
        self.sourceSymbol = sourceSymbol; self.usedPercent = usedPercent; self.resetDisplay = resetDisplay
    }
}

public struct TokenHubMonthlyUsage: Equatable, Sendable {
    public let usedAmount: Decimal
    public let sourceSymbol: String
    public init(usedAmount: Decimal, sourceSymbol: String) {
        self.usedAmount = usedAmount; self.sourceSymbol = sourceSymbol
    }
}

public struct TokenHubQuotaSnapshot: Equatable, Sendable {
    public let identity: TokenHubIdentity
    public let fiveHour: TokenHubWindowQuota?
    public let sevenDay: TokenHubWindowQuota?
    public let monthly: TokenHubMonthlyUsage?
    public let observedAt: Date
    public init(identity: TokenHubIdentity, fiveHour: TokenHubWindowQuota?, sevenDay: TokenHubWindowQuota?,
                monthly: TokenHubMonthlyUsage?, observedAt: Date) {
        self.identity = identity; self.fiveHour = fiveHour; self.sevenDay = sevenDay
        self.monthly = monthly; self.observedAt = observedAt
    }
}

public enum TokenHubQuotaStatus: Equatable, Sendable {
    case disabled, permissionRequired, targetNotRunning, ambiguousTarget
    case quotaGroupUnavailable, unsupportedLayout, accessFailed, stale, connected
}

public enum TokenHubQuotaField: Equatable, Sendable { case fiveHour, sevenDay, monthly }

public enum TokenHubQuotaFailure: Error, Equatable, Sendable {
    case permissionMissing, noTarget, multipleTargets, identityChanged, elementPIDMismatch
    case axError, nodeBudgetExceeded, depthBudgetExceeded, childBudgetExceeded
    case textBudgetExceeded, timeBudgetExceeded, elementTimeout
    case quotaGroupMissing, duplicateQuotaGroup, duplicateWindow(TokenHubWindowKind)
    case duplicateMonthlyContainer, malformedPresentField(TokenHubQuotaField)
    case doubleReadMismatch, noQuotaFields
}

public struct TokenHubQuotaResult: Equatable, Sendable {
    public let status: TokenHubQuotaStatus
    public let snapshot: TokenHubQuotaSnapshot?
    public let failure: TokenHubQuotaFailure?
    public init(status: TokenHubQuotaStatus, snapshot: TokenHubQuotaSnapshot?, failure: TokenHubQuotaFailure?) {
        self.status = status; self.snapshot = snapshot; self.failure = failure
    }
}

public enum TokenHubRunMode: Equatable, Sendable { case localCodex, proxy }

public struct TokenHubQuotaObservation: Equatable, Sendable {
    public let permissionTrusted: Bool
    public let targets: [TokenHubIdentity]
    public let before: TokenHubIdentity?
    public let after: TokenHubIdentity?
    public let first: TokenHubQuotaPass
    public let second: TokenHubQuotaPass
    public let traversal: TokenHubTraversalSummary
    public let accessTrace: [TokenHubReadEvent]
    public init(permissionTrusted: Bool, targets: [TokenHubIdentity], before: TokenHubIdentity?, after: TokenHubIdentity?,
                first: TokenHubQuotaPass, second: TokenHubQuotaPass, traversal: TokenHubTraversalSummary,
                accessTrace: [TokenHubReadEvent]) {
        self.permissionTrusted = permissionTrusted; self.targets = targets; self.before = before; self.after = after
        self.first = first; self.second = second; self.traversal = traversal; self.accessTrace = accessTrace
    }
}

public struct TokenHubQuotaPass: Equatable, Sendable {
    public let rootIdentity: TokenHubIdentity
    public let quotaGroupCount: Int
    public let fiveHourMarkerSeen: Bool
    public let fiveHour: TokenHubWindowObservation?
    public let sevenDayMarkerSeen: Bool
    public let sevenDay: TokenHubWindowObservation?
    public let monthlyContainerCount: Int
    public let monthly: TokenHubMonthlyObservation?
    public init(rootIdentity: TokenHubIdentity, quotaGroupCount: Int, fiveHourMarkerSeen: Bool,
                fiveHour: TokenHubWindowObservation?, sevenDayMarkerSeen: Bool,
                sevenDay: TokenHubWindowObservation?, monthlyContainerCount: Int,
                monthly: TokenHubMonthlyObservation?) {
        self.rootIdentity = rootIdentity; self.quotaGroupCount = quotaGroupCount
        self.fiveHourMarkerSeen = fiveHourMarkerSeen; self.fiveHour = fiveHour
        self.sevenDayMarkerSeen = sevenDayMarkerSeen; self.sevenDay = sevenDay
        self.monthlyContainerCount = monthlyContainerCount; self.monthly = monthly
    }
}

public struct TokenHubWindowObservation: Equatable, Sendable {
    public let titleSeen: Bool
    public let usedPercentText: String?
    public let amountText: String?
    public let progressLabel: String?
    public let progressValue: Decimal?
    public let resetLabelSeen: Bool
    public let resetText: String?
    public init(titleSeen: Bool, usedPercentText: String?, amountText: String?, progressLabel: String?,
                progressValue: Decimal?, resetLabelSeen: Bool, resetText: String?) {
        self.titleSeen = titleSeen; self.usedPercentText = usedPercentText; self.amountText = amountText
        self.progressLabel = progressLabel; self.progressValue = progressValue
        self.resetLabelSeen = resetLabelSeen; self.resetText = resetText
    }
}

public struct TokenHubMonthlyObservation: Equatable, Sendable {
    public let amountText: String?
    public init(amountText: String?) { self.amountText = amountText }
}

public struct TokenHubTraversalSummary: Equatable, Sendable {
    public let nodeVisits: Int
    public let maximumDepth: Int
    public let maximumChildrenForAnyNode: Int
    public let longestStringCharacters: Int
    public let textCharacters: Int
    public let elapsed: TimeInterval
    public let slowestElementMessage: TimeInterval
    public init(nodeVisits: Int, maximumDepth: Int, maximumChildrenForAnyNode: Int,
                longestStringCharacters: Int, textCharacters: Int, elapsed: TimeInterval,
                slowestElementMessage: TimeInterval) {
        self.nodeVisits = nodeVisits; self.maximumDepth = maximumDepth
        self.maximumChildrenForAnyNode = maximumChildrenForAnyNode
        self.longestStringCharacters = longestStringCharacters; self.textCharacters = textCharacters
        self.elapsed = elapsed; self.slowestElementMessage = slowestElementMessage
    }
}

public enum TokenHubQuotaParser {
    public static func parse(_ observation: TokenHubQuotaObservation, now: Date,
                             refreshSeconds: TimeInterval) -> TokenHubQuotaResult {
        func fail(_ failure: TokenHubQuotaFailure, _ status: TokenHubQuotaStatus = .unsupportedLayout) -> TokenHubQuotaResult {
            TokenHubQuotaResult(status: status, snapshot: nil, failure: failure)
        }
        guard observation.permissionTrusted else { return fail(.permissionMissing, .permissionRequired) }
        guard observation.targets.count == 1 else {
            return observation.targets.isEmpty ? fail(.noTarget, .targetNotRunning) : fail(.multipleTargets, .ambiguousTarget)
        }
        let identity = observation.targets[0]
        guard identity.bundleID == TokenHubTarget.bundleID else { return fail(.noTarget, .targetNotRunning) }
        guard identity.bundleID == TokenHubTarget.bundleID,
              identity.pid > 0,
              identity.executablePath.hasPrefix("/"),
              identity.executablePath == URL(fileURLWithPath: identity.executablePath).standardizedFileURL.path,
              observation.before == identity, observation.after == identity,
              observation.first.rootIdentity == identity, observation.second.rootIdentity == identity else {
            return fail(.identityChanged, .accessFailed)
        }
        let limits = observation.traversal
        guard limits.nodeVisits >= 0, limits.maximumDepth >= 0, limits.maximumChildrenForAnyNode >= 0,
              limits.longestStringCharacters >= 0, limits.textCharacters >= 0,
              limits.elapsed.isFinite, limits.slowestElementMessage.isFinite else {
            return fail(.axError, .accessFailed)
        }
        if limits.nodeVisits > 512 { return fail(.nodeBudgetExceeded, .accessFailed) }
        if limits.maximumDepth > 16 { return fail(.depthBudgetExceeded, .accessFailed) }
        if limits.maximumChildrenForAnyNode > 64 { return fail(.childBudgetExceeded, .accessFailed) }
        if limits.longestStringCharacters > 256 || limits.textCharacters > 8192 { return fail(.textBudgetExceeded, .accessFailed) }
        if limits.elapsed > 3 { return fail(.timeBudgetExceeded, .accessFailed) }
        if limits.slowestElementMessage > 0.15 { return fail(.elementTimeout, .accessFailed) }
        guard observation.first.quotaGroupCount == 1, observation.second.quotaGroupCount == 1 else {
            let count = max(observation.first.quotaGroupCount, observation.second.quotaGroupCount)
            return fail(count == 0 ? .quotaGroupMissing : .duplicateQuotaGroup,
                        count == 0 ? .quotaGroupUnavailable : .unsupportedLayout)
        }
        func checkedWindow(_ kind: TokenHubWindowKind, marker: Bool,
                           value: TokenHubWindowObservation?) -> Result<TokenHubWindowQuota?, TokenHubQuotaFailure> {
            guard marker || value != nil else { return .success(nil) }
            guard let value,
                  value.titleSeen,
                  let percentText = value.usedPercentText,
                  let amountText = value.amountText,
                  let progressLabel = value.progressLabel,
                  let progress = value.progressValue,
                  value.resetLabelSeen,
                  let reset = value.resetText,
                  progressLabel == (kind == .fiveHour ? "5 小时限额已用比例" : "7 天限额已用比例") else {
                return .failure(.malformedPresentField(kind == .fiveHour ? .fiveHour : .sevenDay))
            }
            guard let textPercent = parsePercent(percentText), textPercent >= 0, textPercent <= 100,
                  progress >= 0, progress <= 100, abs(textPercent - progress) <= Decimal(string: "0.1")!,
                  let amount = parseAmountPair(amountText), amount.used >= 0, amount.limit > 0,
                  amount.used <= amount.limit,
                  let resetText = validReset(reset) else {
                return .failure(.malformedPresentField(kind == .fiveHour ? .fiveHour : .sevenDay))
            }
            return .success(TokenHubWindowQuota(kind: kind, usedAmount: amount.used, limitAmount: amount.limit,
                                                 sourceSymbol: amount.symbol, usedPercent: progress, resetDisplay: resetText))
        }
        typealias ParsedPass = (five: TokenHubWindowQuota?, seven: TokenHubWindowQuota?, monthly: TokenHubMonthlyUsage?)
        func parse(_ pass: TokenHubQuotaPass) -> Result<ParsedPass, TokenHubQuotaFailure> {
            if pass.monthlyContainerCount > 1 { return .failure(.duplicateMonthlyContainer) }
            if pass.monthlyContainerCount < 0 { return .failure(.axError) }
            let five: TokenHubWindowQuota?
            switch checkedWindow(.fiveHour, marker: pass.fiveHourMarkerSeen, value: pass.fiveHour) {
            case .success(let value): five = value
            case .failure(let failure): return .failure(failure)
            }
            let seven: TokenHubWindowQuota?
            switch checkedWindow(.sevenDay, marker: pass.sevenDayMarkerSeen, value: pass.sevenDay) {
            case .success(let value): seven = value
            case .failure(let failure): return .failure(failure)
            }
            var monthly: TokenHubMonthlyUsage?
            if pass.monthlyContainerCount == 1 {
                guard let raw = pass.monthly?.amountText, let amount = parseSingleAmount(raw) else {
                    return .failure(.malformedPresentField(.monthly))
                }
                monthly = TokenHubMonthlyUsage(usedAmount: amount.used, sourceSymbol: amount.symbol)
            } else if pass.monthly != nil {
                return .failure(.malformedPresentField(.monthly))
            }
            return .success((five, seven, monthly))
        }
        let first: ParsedPass
        switch parse(observation.first) {
        case .success(let value): first = value
        case .failure(let failure): return fail(failure)
        }
        let second: ParsedPass
        switch parse(observation.second) {
        case .success(let value): second = value
        case .failure(let failure): return fail(failure)
        }
        guard first.five == second.five, first.seven == second.seven, first.monthly == second.monthly else {
            return fail(.doubleReadMismatch)
        }
        let five = first.five, seven = first.seven, monthly = first.monthly
        guard five != nil || seven != nil || monthly != nil else { return fail(.noQuotaFields, .quotaGroupUnavailable) }
        return TokenHubQuotaResult(status: .connected,
            snapshot: TokenHubQuotaSnapshot(identity: identity, fiveHour: five, sevenDay: seven, monthly: monthly, observedAt: now),
            failure: nil)
    }

    private static func parsePercent(_ text: String) -> Decimal? {
        let pattern = #"^(?:(?:5 小时限额|7 天限额)\s+)?已使用\s*([0-9]+(?:\.[0-9]+)?)%$"#
        let regex = try? NSRegularExpression(pattern: pattern)
        guard let regex,
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(result.range(at: 1), in: text) else { return nil }
        let number = String(text[numberRange])
        return Decimal(string: number, locale: Locale(identifier: "en_US_POSIX"))
    }

    private struct ParsedAmount { let used: Decimal; let limit: Decimal; let symbol: String }
    private static func parseAmountPair(_ text: String) -> ParsedAmount? {
        let pattern = #"^\s*(\$)([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*/\s*\$(?:\s*)([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges == 4,
              let usedRange = Range(match.range(at: 2), in: text), let limitRange = Range(match.range(at: 3), in: text) else { return nil }
        guard let used = parseDecimalAmount(String(text[usedRange])), let limit = parseDecimalAmount(String(text[limitRange])) else { return nil }
        return ParsedAmount(used: used, limit: limit, symbol: "$")
    }
    private static func parseSingleAmount(_ text: String) -> ParsedAmount? {
        let pattern = #"^\s*(\$)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges == 3,
              let range = Range(match.range(at: 2), in: text), let value = parseDecimalAmount(String(text[range])) else { return nil }
        return ParsedAmount(used: value, limit: 0, symbol: "$")
    }
    private static func parseDecimalAmount(_ raw: String) -> Decimal? {
        let pieces = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { return nil }
        let integer = String(pieces[0])
        if integer.contains(",") {
            let groups = integer.split(separator: ",", omittingEmptySubsequences: false)
            guard let first = groups.first, (1...3).contains(first.count), first.allSatisfy(\.isNumber),
                  groups.dropFirst().allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isNumber) }) else { return nil }
        } else if !integer.allSatisfy(\.isNumber) { return nil }
        if pieces.count == 2, !(1...2).contains(pieces[1].count) { return nil }
        let normalized = raw.replacingOccurrences(of: ",", with: "")
        guard let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              !NSDecimalNumber(decimal: value).doubleValue.isNaN,
              value >= 0, value <= Decimal(string: "1000000000000000")! else { return nil }
        return value
    }
    private static func validReset(_ text: String) -> String? {
        let pattern = #"^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01]) ([01][0-9]|2[0-3]):[0-5][0-9]$"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let pieces = text[..<range.upperBound].split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" })
        guard pieces.count == 4, let month = Int(pieces[0]), let day = Int(pieces[1]) else { return nil }
        let maxDay: Int
        switch month { case 2: maxDay = 29; case 4, 6, 9, 11: maxDay = 30; default: maxDay = 31 }
        guard day <= maxDay else { return nil }
        return text
    }
}
```

### Sources/TokenStatCore/TokenHubAXScanning.swift

```swift
import Foundation

public typealias TokenHubNodeID = Int

public enum TokenHubAXRole: Equatable, Sendable {
    case application, window, group, staticText, progressIndicator
    case button, table, editableText, secureText, other(String)
}
public enum TokenHubGroupLabelKind: Equatable, Sendable { case description, title }

public protocol TokenHubBoundedTreeReading {
    func exactBundleTargets(bundleID: String) throws -> [TokenHubIdentity]
    func rootNode(for identity: TokenHubIdentity, timeout: TimeInterval) throws -> TokenHubNodeID
    func identity(of node: TokenHubNodeID, timeout: TimeInterval) throws -> TokenHubIdentity
    func role(of node: TokenHubNodeID, timeout: TimeInterval) throws -> TokenHubAXRole
    func groupLabel(of node: TokenHubNodeID, kind: TokenHubGroupLabelKind,
                    timeout: TimeInterval) throws -> String?
    func children(of node: TokenHubNodeID, maximum: Int, timeout: TimeInterval) throws -> TokenHubChildrenPage
    func staticText(of node: TokenHubNodeID, maximumCharacters: Int, timeout: TimeInterval) throws -> String?
    func progressLabel(of node: TokenHubNodeID, timeout: TimeInterval) throws -> String?
    func progressValue(of node: TokenHubNodeID, timeout: TimeInterval) throws -> Decimal?
}

public struct TokenHubChildrenPage: Equatable, Sendable {
    public let nodes: [TokenHubNodeID]
    public let isTruncated: Bool
    public init(nodes: [TokenHubNodeID], isTruncated: Bool) { self.nodes = nodes; self.isTruncated = isTruncated }
}

public protocol TokenHubQuotaScanning {
    func scan(now: Date, monotonicNow: () -> TimeInterval, permissionTrusted: Bool,
              refreshSeconds: TimeInterval, mode: TokenHubRunMode,
              generation: UInt64) -> TokenHubQuotaResult
}

public enum TokenHubReadEvent: Equatable, Sendable {
    case targets, root, identity(TokenHubNodeID), role(TokenHubNodeID)
    case groupDescription(TokenHubNodeID), groupTitle(TokenHubNodeID)
    case children(TokenHubNodeID), staticText(TokenHubNodeID)
    case progressLabel(TokenHubNodeID), progressValue(TokenHubNodeID)
}

public struct TokenHubQuotaScanner {
    public init() {}
    public func scan(using reader: any TokenHubBoundedTreeReading, now: Date,
                     monotonicNow: () -> TimeInterval, permissionTrusted: Bool,
                     refreshSeconds: TimeInterval, mode: TokenHubRunMode, generation: UInt64) -> TokenHubQuotaResult {
        var events: [TokenHubReadEvent] = []
        var visits = 0, maxDepth = 0, maxChildren = 0, longest = 0, textCount = 0
        var slowest: TimeInterval = 0
        let started = monotonicNow()
        func failure(_ value: TokenHubQuotaFailure, status: TokenHubQuotaStatus = .accessFailed) -> TokenHubQuotaResult {
            TokenHubQuotaResult(status: status, snapshot: nil, failure: value)
        }
        if mode != .localCodex { return TokenHubQuotaResult(status: .disabled, snapshot: nil, failure: nil) }
        guard permissionTrusted else { return failure(.permissionMissing, status: .permissionRequired) }
        func elapsed() -> TimeInterval { max(0, monotonicNow() - started) }
        func budgetCheck() throws {
            if elapsed() > 3 { throw ScanIssue.failure(.timeBudgetExceeded) }
        }
        func message<T>(_ node: TokenHubNodeID?, event: TokenHubReadEvent,
                        enforceSingleMessageLimit: Bool = true, _ body: () throws -> T) throws -> T {
            try budgetCheck()
            let t0 = monotonicNow()
            do {
                let result = try body()
                let duration = max(0, monotonicNow() - t0)
                if enforceSingleMessageLimit {
                    slowest = max(slowest, duration)
                    if duration > 0.15 { throw ScanIssue.failure(.elementTimeout) }
                }
                try budgetCheck()
                return result
            } catch let issue as ScanIssue { throw issue }
            catch { throw ScanIssue.failure(.axError) }
        }
        do {
            events.append(.targets)
            let targets = try reader.exactBundleTargets(bundleID: TokenHubTarget.bundleID)
            guard targets.count == 1 else {
                if targets.isEmpty { throw ScanIssue.failure(.noTarget) }
                throw ScanIssue.failure(.multipleTargets)
            }
            let selected = targets[0]
            guard selected.bundleID == TokenHubTarget.bundleID, selected.pid > 0,
                  selected.executablePath.hasPrefix("/"),
                  selected.executablePath == URL(fileURLWithPath: selected.executablePath).standardizedFileURL.path else {
                throw ScanIssue.failure(.identityChanged)
            }
            let before = selected
            events.append(.root)
            let root = try reader.rootNode(for: selected, timeout: 0.15)
            var nodeParent: [TokenHubNodeID: TokenHubNodeID] = [:]
            var found: [TokenHubNodeID] = []
            var foundDepth: [TokenHubNodeID: Int] = [:]
            var visitedOnPath = Set<TokenHubNodeID>()

            func visit(_ node: TokenHubNodeID, depth: Int) throws -> TokenHubAXRole {
                try budgetCheck()
                guard depth <= 16 else { throw ScanIssue.failure(.depthBudgetExceeded) }
                visits += 1
                if visits > 512 { throw ScanIssue.failure(.nodeBudgetExceeded) }
                maxDepth = max(maxDepth, depth)
                events.append(.identity(node))
                let identity = try message(node, event: .identity(node)) { try reader.identity(of: node, timeout: 0.15) }
                guard identity == selected else {
                    throw ScanIssue.failure(node == root ? .identityChanged : .elementPIDMismatch)
                }
                events.append(.role(node))
                let role = try message(node, event: .role(node)) { try reader.role(of: node, timeout: 0.15) }
                return role
            }
            func label(_ node: TokenHubNodeID, kind: TokenHubGroupLabelKind) throws -> String? {
                let event: TokenHubReadEvent = kind == .description ? .groupDescription(node) : .groupTitle(node)
                events.append(event)
                let value = try message(node, event: event) { try reader.groupLabel(of: node, kind: kind, timeout: 0.15) }
                try countText(value)
                return value
            }
            func countText(_ value: String?) throws {
                guard let value else { return }
                let count = value.count
                longest = max(longest, count)
                guard count <= 256 else { throw ScanIssue.failure(.textBudgetExceeded) }
                textCount += count
                guard textCount <= 8192 else { throw ScanIssue.failure(.textBudgetExceeded) }
            }
            func children(_ node: TokenHubNodeID) throws -> [TokenHubNodeID] {
                events.append(.children(node))
                // The native children operation performs separate bounded count and copy AX messages;
                // each receives a 0.15s timeout, while this wrapper enforces the shared 3s scan limit.
                let page = try message(node, event: .children(node), enforceSingleMessageLimit: false) {
                    try reader.children(of: node, maximum: 64, timeout: 0.15)
                }
                guard page.nodes.count <= 64 else { throw ScanIssue.failure(.childBudgetExceeded) }
                guard !page.isTruncated else { throw ScanIssue.failure(.childBudgetExceeded) }
                maxChildren = max(maxChildren, page.nodes.count)
                return page.nodes
            }
            func discover(_ node: TokenHubNodeID, depth: Int) throws {
                guard !visitedOnPath.contains(node) else { throw ScanIssue.failure(.axError) }
                visitedOnPath.insert(node); defer { visitedOnPath.remove(node) }
                let role = try visit(node, depth: depth)
                if role == .button || role == .table || role == .editableText || role == .secureText { return }
                if role == .group {
                    let description = try label(node, kind: .description)
                    let title = try label(node, kind: .title)
                    if description == "用量和限额" || title == "用量和限额" {
                        found.append(node); foundDepth[node] = depth
                    }
                }
                guard role == .application || role == .window || role == .group || role == .other("AXWebArea") || role == .other("AXScrollArea") else { return }
                for child in try children(node) { nodeParent[child] = node; try discover(child, depth: depth + 1) }
            }
            try discover(root, depth: 0)
            guard found.count == 1 else {
                if found.isEmpty { throw ScanIssue.failure(.quotaGroupMissing) }
                throw ScanIssue.failure(.duplicateQuotaGroup)
            }
            let quotaGroup = found[0]
            func readPass() throws -> TokenHubQuotaPass {
                var records: [(role: TokenHubAXRole, text: String?, progressLabel: String?, progress: Decimal?, node: Int)] = []
                var duplicateQuotaMarkers = 0
                var monthlyGroups = [TokenHubNodeID]()
                var inside = Set<TokenHubNodeID>()
                func read(_ node: TokenHubNodeID, depth: Int, isRoot: Bool = false) throws {
                    guard !inside.contains(node) else { throw ScanIssue.failure(.axError) }
                    inside.insert(node); defer { inside.remove(node) }
                    let role = try visit(node, depth: depth)
                    if role == .button || role == .table || role == .editableText || role == .secureText { return }
                    if role == .group && node != quotaGroup {
                        let d = try label(node, kind: .description)
                        let t = try label(node, kind: .title)
                        if d == "用量和限额" || t == "用量和限额" { duplicateQuotaMarkers += 1 }
                        if d == "月度用量" || t == "月度用量" { monthlyGroups.append(node) }
                    }
                    if role == .staticText {
                        events.append(.staticText(node))
                        let value = try message(node, event: .staticText(node)) { try reader.staticText(of: node, maximumCharacters: 256, timeout: 0.15) }
                        try countText(value)
                        records.append((role, value, nil, nil, node))
                    } else if role == .progressIndicator {
                        events.append(.progressLabel(node))
                        let progressLabel = try message(node, event: .progressLabel(node)) { try reader.progressLabel(of: node, timeout: 0.15) }
                        try countText(progressLabel)
                        let value: Decimal?
                        if progressLabel == "5 小时限额已用比例" || progressLabel == "7 天限额已用比例" {
                            events.append(.progressValue(node))
                            value = try message(node, event: .progressValue(node)) { try reader.progressValue(of: node, timeout: 0.15) }
                        } else { value = nil }
                        records.append((role, nil, progressLabel, value, node))
                    }
                    guard role == .application || role == .window || role == .group || role == .other("AXWebArea") || role == .other("AXScrollArea") else { return }
                    let childNodes = try children(node)
                    if depth == 16, !childNodes.isEmpty { throw ScanIssue.failure(.depthBudgetExceeded) }
                    for child in childNodes { nodeParent[child] = node; try read(child, depth: depth + 1) }
                }
                try read(quotaGroup, depth: foundDepth[quotaGroup] ?? 0, isRoot: true)
                if duplicateQuotaMarkers > 0 { throw ScanIssue.failure(.duplicateQuotaGroup) }
                let quotaGroups = found.count
                guard monthlyGroups.count <= 1 else { throw ScanIssue.failure(.duplicateMonthlyContainer) }
                var fiveMarkers = 0, sevenMarkers = 0
                var fiveProgressMarkers = 0, sevenProgressMarkers = 0
                var five: TokenHubWindowObservation?, seven: TokenHubWindowObservation?
                var monthly: TokenHubMonthlyObservation?
                func isWithinMonthly(_ node: Int) -> Bool {
                    var cursor: Int? = node
                    while let current = cursor {
                        if monthlyGroups.contains(current) { return true }
                        cursor = nodeParent[current]
                    }
                    return false
                }
                let titles = records.indices.filter { index in
                    guard records[index].role == .staticText, let text = records[index].text else { return false }
                    return text.hasPrefix("5 小时限额") || text.hasPrefix("7 天限额")
                }
                for (position, titleIndex) in titles.enumerated() {
                    let title = records[titleIndex].text!
                    let kind: TokenHubWindowKind = title.hasPrefix("5 小时限额") ? .fiveHour : .sevenDay
                    if kind == .fiveHour { fiveMarkers += 1 } else { sevenMarkers += 1 }
                    let nextWindow = titles.dropFirst(position + 1).first ?? records.count
                    let nextMonthly = records.indices.first { index in index > titleIndex && isWithinMonthly(records[index].node) } ?? records.count
                    let boundary = min(nextWindow, nextMonthly)
                    let range = (titleIndex + 1)..<boundary
                    let expectedProgress = kind == .fiveHour ? "5 小时限额已用比例" : "7 天限额已用比例"
                    let allAmountRows = range.filter { i in records[i].role == .staticText && records[i].text?.hasPrefix("$") == true }
                    let amounts = range.filter { i in
                        records[i].role == .staticText && records[i].text?.hasPrefix("$") == true && records[i].text?.contains("/") == true
                    }
                    let progress = range.filter { i in records[i].role == .progressIndicator && records[i].progressLabel == expectedProgress }
                    let resetLabels = range.filter { i in records[i].role == .staticText && records[i].text == "重置" }
                    let resetValues = range.filter { i in
                        guard records[i].role == .staticText, let value = records[i].text else { return false }
                        return value.range(of: #"^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01]) ([01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil
                    }
                    let unexpected = range.contains { i in
                        let record = records[i]
                        if record.role == .staticText, let text = record.text {
                            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
                            return !text.hasPrefix("$") && text != "额度" && text != "重置" && text != "时间" &&
                                text.range(of: #"^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01]) ([01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) == nil
                        }
                        if record.role == .progressIndicator { return record.progressLabel != expectedProgress && record.progressLabel != "重置进度" }
                        return false
                    }
                    if kind == .fiveHour { fiveProgressMarkers += progress.count } else { sevenProgressMarkers += progress.count }
                    // Require one ordered amount -> matching progress -> reset label -> reset value chain.
                    let validChains = amounts.filter { amount in
                        guard amounts.count == 1, progress.count == 1,
                              resetLabels.count == 1, resetValues.count == 1,
                              let p = progress.first, let r = resetLabels.first,
                              let v = resetValues.first else { return false }
                        return amount < p && p < r && r < v
                    }
                    if allAmountRows.count != amounts.count || amounts.count > 1 || progress.count > 1 || resetLabels.count > 1 || resetValues.count > 1 || validChains.count > 1 || unexpected {
                        throw ScanIssue.failure(.malformedPresentField(kind == .fiveHour ? .fiveHour : .sevenDay))
                    }
                    let amountIndex = validChains.first
                    let progressIndex = amountIndex.flatMap { a in progress.first(where: { $0 > a }) }
                    let resetIndex = progressIndex.flatMap { p in resetLabels.first(where: { $0 > p }) }
                    let resetValueIndex = resetIndex.flatMap { r in resetValues.first(where: { $0 > r }) }
                    let observation = TokenHubWindowObservation(titleSeen: true, usedPercentText: title,
                        amountText: amountIndex.flatMap { records[$0].text },
                        progressLabel: progressIndex.flatMap { records[$0].progressLabel },
                        progressValue: progressIndex.flatMap { records[$0].progress },
                        resetLabelSeen: resetIndex != nil, resetText: resetValueIndex.flatMap { records[$0].text })
                    if kind == .fiveHour { five = observation } else { seven = observation }
                }
                fiveProgressMarkers = records.filter { $0.role == .progressIndicator && $0.progressLabel == "5 小时限额已用比例" }.count
                sevenProgressMarkers = records.filter { $0.role == .progressIndicator && $0.progressLabel == "7 天限额已用比例" }.count
                if fiveMarkers > 1 || fiveProgressMarkers > 1 { throw ScanIssue.failure(.duplicateWindow(.fiveHour)) }
                if sevenMarkers > 1 || sevenProgressMarkers > 1 { throw ScanIssue.failure(.duplicateWindow(.sevenDay)) }
                if !monthlyGroups.isEmpty {
                    // Only extract amount text whose node is directly or indirectly under the unique monthly group.
                    let values = records.enumerated().compactMap { index, record -> String? in
                        guard record.role == .staticText, isWithinMonthly(record.node),
                              let text = record.text, text.hasPrefix("$") else { return nil }
                        return text
                    }
                    if values.count > 1 { throw ScanIssue.failure(.malformedPresentField(.monthly)) }
                    if let first = values.first { monthly = TokenHubMonthlyObservation(amountText: first) }
                }
                return TokenHubQuotaPass(rootIdentity: selected, quotaGroupCount: quotaGroups,
                    fiveHourMarkerSeen: fiveMarkers > 0 || fiveProgressMarkers > 0, fiveHour: five,
                    sevenDayMarkerSeen: sevenMarkers > 0 || sevenProgressMarkers > 0, sevenDay: seven,
                    monthlyContainerCount: monthlyGroups.count, monthly: monthly)
            }
            let first = try readPass()
            let second = try readPass()
            visits += 1
            if visits > 512 { throw ScanIssue.failure(.nodeBudgetExceeded) }
            events.append(.identity(root))
            let after = try message(root, event: .identity(root)) { try reader.identity(of: root, timeout: 0.15) }
            guard after == selected else { throw ScanIssue.failure(.identityChanged) }
            let observation = TokenHubQuotaObservation(permissionTrusted: true, targets: targets, before: before,
                after: after, first: first, second: second,
                traversal: TokenHubTraversalSummary(nodeVisits: visits, maximumDepth: maxDepth,
                    maximumChildrenForAnyNode: maxChildren, longestStringCharacters: longest,
                    textCharacters: textCount, elapsed: elapsed(), slowestElementMessage: slowest),
                accessTrace: events)
            return TokenHubQuotaParser.parse(observation, now: now, refreshSeconds: refreshSeconds)
        } catch let issue as ScanIssue {
            return failure(issue.failure, status: status(for: issue.failure))
        } catch {
            return failure(.axError)
        }
    }
}

private struct ScanIssue: Error { let failure: TokenHubQuotaFailure; static func failure(_ f: TokenHubQuotaFailure) -> Self { Self(failure: f) } }
private func status(for failure: TokenHubQuotaFailure) -> TokenHubQuotaStatus {
    switch failure {
    case .permissionMissing: .permissionRequired
    case .noTarget: .targetNotRunning
    case .multipleTargets: .ambiguousTarget
    case .quotaGroupMissing, .noQuotaFields: .quotaGroupUnavailable
    case .malformedPresentField, .duplicateQuotaGroup, .duplicateWindow, .duplicateMonthlyContainer, .doubleReadMismatch: .unsupportedLayout
    default: .accessFailed
    }
}
```

### Sources/TokenStatMenu/AppModel.swift

```swift
import AppKit
import Combine
#if SWIFT_PACKAGE
@preconcurrency import TokenStatCore
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
    private let isPreview: Bool
    @Published var config = AppConfiguration()
    @Published var stats = MetricsSnapshot()
    @Published var localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0, filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil, knownThreadCount: 0, unknownThreadCount: 0, unidentifiedFileCount: 0, subagentCount: 0, forkCount: 0)
    @Published var quota: QuotaSnapshot?
    @Published var fiveHourQuota: WindowQuota?
    @Published var sevenDayQuota: WindowQuota?
    @Published var quotaError = "未配置企业用量接口"
    @Published var proxyStatus = "启动中"
    @Published var message = ""
    @Published var history: [SpeedPoint] = []
    @Published var quotaLoading = false
    @Published private(set) var tokenHubQuotaSnapshot: TokenHubQuotaSnapshot?
    @Published private(set) var tokenHubQuotaStatus: TokenHubQuotaStatus = .targetNotRunning
    @Published private(set) var tokenHubQuotaFailure: TokenHubQuotaFailure?
    @Published var tokenHubAutomaticReadingEnabled = true
    var tokenHubScanner: TokenHubQuotaScanning = TokenHubAXReader()
    var tokenHubPermissionProvider: TokenHubPermissionProviding = TokenHubNativePermissionProvider()
    var tokenHubNow: () -> Date = Date.init
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
    private var localScan: DispatchWorkItem?
    private var localScanRunning = false
    private let tokenHubQueue = DispatchQueue(label: "TokenStatMenu.tokenHubAX", qos: .utility)
    private var tokenHubRefreshWork: DispatchWorkItem?
    private var tokenHubScanInFlight = false
    private var tokenHubWorkspaceObservers: [NSObjectProtocol] = []
    private var lastTokenHubPermissionCheck = Date.distantPast
    private var cachedTokenHubPermission = false
    private let localScanQueue = DispatchQueue(label: "TokenStatMenu.localCodexScan", qos: .utility)
    private var localCache = LocalCodexUsageReader.Cache()
    private var localRefreshScheduler = LocalRefreshScheduler()
    private var proxyWasStarted = false
    private var isShuttingDown = false
    private var generation = 0
    private var tokenHubGeneration: UInt64 = 0
    private var lastHistory = Date.distantPast
    private(set) var localKey = ""
    private var apiKey = ""
    private var usageKey = ""
    var onTick: (() -> Void)?

    init(preview: Bool = false) {
        isPreview = preview
        // Offline view rendering must never touch local configuration or credentials.
        if preview { proxyStatus = "模拟预览 · 无网络、无本机配置"; discoveryStatus = "离线预览"; return }
        logger.onError = { [weak self] error in Task { @MainActor in self?.message = error } }
        do {
            config = try ConfigStore.load()
            if config.dataSource == "proxy" {
                localKey = try KeychainStore.localToken()
                apiKey = try KeychainStore.resolve("upstream", environment: "TOKENSTAT_API_KEY", validatedURL: config.endpoint)
                usageKey = config.usageURL.isEmpty ? "" : try KeychainStore.resolve("usage", environment: "TOKENSTAT_USAGE_KEY", validatedURL: config.usageURL)
            }
            startServices()
        } catch { message = error.localizedDescription; proxyStatus = "未启动：检查设置" }
        installTokenHubWorkspaceObservers()
        // A single 2Hz main timer updates menu text. Network callbacks never redraw the UI.
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        timer?.tolerance = 0.1
        RunLoop.main.add(timer!, forMode: .common)
        if config.dataSource == "proxy" { discoverGateways() }
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
    func shutdown() {
        isShuttingDown = true; generation += 1; _ = localRefreshScheduler.invalidate()
        timer?.invalidate(); quotaLoop?.cancel(); quotaFetch?.cancel(); localScan?.cancel()
        tokenHubGeneration &+= 1
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        for observer in tokenHubWorkspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        tokenHubWorkspaceObservers.removeAll()
        tokenHubQuotaSnapshot = nil; tokenHubQuotaStatus = .disabled; tokenHubQuotaFailure = nil
        if proxyWasStarted { proxy.stop() }
    }
    func tick() {
        stats = engine.snapshot()
        let now = Date()
        if config.dataSource == "proxy", config.historyEnabled, now.timeIntervalSince(lastHistory) >= 1 {
            history.append(SpeedPoint(date: now, value: stats.outputTPS))
            history.removeAll { now.timeIntervalSince($0.date) > 600 }
            if history.count > 600 { history.removeFirst(history.count - 600) }
            lastHistory = now
        }
        if quota?.month != QuotaSnapshot.currentMonth(), quota != nil { quota = nil; quotaError = "已跨月，等待本月用量" }
        if tokenHubQuotaStatus == .connected, freshTokenHubQuota(at: now) == nil { tokenHubQuotaStatus = .stale }
        pollTokenHubPermissionIfDue()
        onTick?()
    }
    var freshQuota: QuotaSnapshot? {
        guard let quota, quota.month == QuotaSnapshot.currentMonth(), Date().timeIntervalSince(quota.fetchedAt) < max(120, config.refreshSeconds * 2) else { return nil }
        return quota
    }
    var currencyFactor: Double { config.currency == "CNY" ? config.usdToCNY : 1 }
    var currencySymbol: String { config.currency == "CNY" ? "¥" : "$" }
    var quotaSource: QuotaSource { config.dataSource == "localCodex" ? .localCodex : .enterprise }
    var hasRequestData: Bool { config.dataSource == "localCodex" ? localSnapshot.knownThreadCount > 0 : stats.requests > 0 }
    var dataNotice: String {
        if isTestFixture { return "模拟测试 · 以下速度、Token、费用和配额均非企业真实数据" }
        if config.dataSource == "localCodex" { return "本地 Codex 当前扫描范围记录小计 · 不代表账单或实时用量；账号与组织归属未核验" }
        return hasRequestData ? "本次启动 · 仅统计经过本机代理的请求" : "未采集到请求数据 · 尚未观测到客户端流量"
    }
    var title: String {
        if config.dataSource == "localCodex" {
            let rate = localSnapshot.lastTurn.map { String(format: "%.1ftok/s", $0.outputTPS) } ?? "—"
            let uncertainty = localSnapshot.unknownThreadCount + localSnapshot.unidentifiedFileCount
            let total = localSnapshot.hasCompleteAccounting ? "Σ\(formatCompactCount(localSnapshot.total))"
                : localSnapshot.knownThreadCount > 0 ? "小计\(formatCompactCount(localSnapshot.total)) · 未核验\(uncertainty)" : "Σ— · 未核验\(uncertainty)"
            let sessions = localSnapshot.hasCompleteAccounting ? " · \(localSnapshot.sessionCount)顶层对话" : ""
            let quotaSuffix = tokenHubMenuSuffix
            return (isTestFixture ? "测试 " : "") + "上轮均:\(rate) · \(total)\(sessions)\(quotaSuffix)"
        }
        let value = !hasRequestData ? "T:—" : stats.active > 0
            ? String(format: "T:≈%.1ftok/s", stats.outputTPS) : "T:0.0tok/s"
        let total = stats.requests > 0 ? formatCompactCount(stats.total) : "—"
        return (isTestFixture ? "测试 " : "") + "\(value) · Σ\(total) · 请求\(stats.requests)"
    }
    var menuTooltip: String {
        guard config.dataSource == "localCodex" else {
            return "\(dataNotice) · \(proxyStatus)\n5 小时额度：\(quotaDescription(fiveHourQuota, source: .enterprise))\n7 天额度：\(quotaDescription(sevenDayQuota, source: .enterprise))"
        }
        let turn = localSnapshot.lastTurn.map { String(format: "上轮记录均速：%.1f tok/s（完成于 %@）", $0.outputTPS, $0.completedAt.formatted()) } ?? "上轮记录均速：未知"
        let range = localSnapshot.latestEventAt.map { "最新记录：\($0.formatted())" } ?? "记录时间：未知"
        let coverage = "扫描范围最多32个物理文件；不是全部对话；每文件头64KiB与尾256KiB，总计10MiB；" + (localSnapshot.isLimited ? "本次达到扫描上限" : "本次安全检查 \(localSnapshot.filesScanned) 个物理文件")
        let input = localSnapshot.knownThreadCount > 0 ? formatCount(localSnapshot.input) : "未知"
        let output = localSnapshot.knownThreadCount > 0 ? formatCount(localSnapshot.output) : "未知"
        let amountLabel = localSnapshot.hasCompleteAccounting ? "本次扫描记录量" : "已核验记录小计"
        let total = localSnapshot.knownThreadCount > 0 ? formatCount(localSnapshot.total) : "未知"
        let hub = tokenHubTooltipDetail
        return "本地 Codex 当前扫描范围记录：输入 \(input) · 输出 \(output) · 总计 \(total) tokens（\(amountLabel) \(total) tokens）\n\(accountingDetail)\n\(coverage)；\(range)\n\(turn)；含工具、网络和等待；不是模型瞬时生成速度\n\(hub)\n5 小时额度：\(quotaDescription(fiveHourQuota, source: .localCodex))\n7 天额度：\(quotaDescription(sevenDayQuota, source: .localCodex))"
    }
    private var tokenHubMenuSuffix: String {
        guard let snapshot = freshTokenHubQuota(at: Date()) else { return "" }
        let windows = [snapshot.fiveHour.map { "5h剩 \(percentText($0.remainingPercent))%" },
                       snapshot.sevenDay.map { "7d剩 \(percentText($0.remainingPercent))%" }].compactMap { $0 }
        return windows.isEmpty ? "" : " · Hub \(windows.joined(separator: " / "))"
    }
    var menuTitleContainsTokenHubSuffix: Bool { !tokenHubMenuSuffix.isEmpty }
    var tokenHubPermissionGrantedForDiagnostics: Bool { cachedTokenHubPermission }
    var tokenHubPermissionRequiredForDiagnostics: Bool { tokenHubQuotaStatus == .permissionRequired }
    private var tokenHubTooltipDetail: String {
        let snapshot = freshTokenHubQuota(at: Date())
        let five = snapshot?.fiveHour.map { "界面显示剩余 \(percentText($0.remainingPercent))%（5 小时）" } ?? "5 小时未知"
        let seven = snapshot?.sevenDay.map { "界面显示剩余 \(percentText($0.remainingPercent))%（7 天）" } ?? "7 天未知"
        return "Token Hub 界面快照：\(five) · \(seven)；\(tokenHubQuotaStatusText)；后台更新时间未提供；币种未核验"
    }
    private func percentText(_ value: Decimal) -> String {
        TokenHubDecimalFormatter.string(value)
    }
    var tokenHubQuotaStatusText: String {
        switch tokenHubQuotaStatus {
        case .disabled: "自动读取已关闭"
        case .permissionRequired: "未授权辅助功能"
        case .targetNotRunning: "Token Hub 未运行"
        case .ambiguousTarget: "检测到多个 Token Hub 进程"
        case .quotaGroupUnavailable: "找不到用量和限额页"
        case .unsupportedLayout: "用量页面布局暂不支持"
        case .accessFailed: "辅助功能读取失败"
        case .stale: "界面快照已过期"
        case .connected: "已连接"
        }
    }
    private var accountingDetail: String {
        "已核验线程 \(localSnapshot.knownThreadCount) · 未核验线程 \(localSnapshot.unknownThreadCount) · 未识别文件 \(localSnapshot.unidentifiedFileCount) · 子代理 \(localSnapshot.subagentCount) · 分叉 \(localSnapshot.forkCount) · 顶层对话 \(localSnapshot.sessionCount)"
    }
    private func quotaDescription(_ quota: WindowQuota?, source: QuotaSource) -> String {
        let presentation = WindowQuotaCard.presentation(for: quota, refreshSeconds: config.refreshSeconds, source: source)
        guard let usedPercent = presentation.usedPercent else { return "\(presentation.sourceLabel) · \(presentation.statusLabel)" }
        let resetLabel = source == .localCodex || !presentation.isFresh ? "原重置时间" : "重置时间"
        let reset = presentation.resetsAt.map { "，\(resetLabel) \($0.formatted())" } ?? "，重置时间未知"
        let recorded = presentation.recordedAt.map { "，记录于 \($0.formatted())" } ?? ""
        return "\(presentation.sourceLabel) · \(presentation.statusLabel)，上游已用 \(String(format: "%.1f", usedPercent))%\(reset)\(recorded)"
    }
    private func formatCount(_ value: Int) -> String { value.formatted(.number) }
    private func formatCompactCount(_ value: Int) -> String { value.formatted(.number.notation(.compactName)) }
    var alertColor: NSColor {
        guard quotaSource == .enterprise else { return .labelColor }
        let windows = (quotaSource == .enterprise ? [fiveHourQuota, sevenDayQuota].compactMap { $0 } : [])
            .filter { $0.isFresh(refreshSeconds: config.refreshSeconds) }.map { $0.usedPercent / 100 }
        guard let ratio = (windows + [freshQuota?.fraction].compactMap { $0 }).max() else { return .labelColor }
        return ratio >= 0.95 ? .systemRed : ratio >= 0.8 ? .systemYellow : .labelColor
    }
    func credentials() -> (String, String) { (apiKey, usageKey) }
    static func configurationForApplying(_ draft: AppConfiguration,
                                         automaticReadingEnabled: Bool) -> AppConfiguration {
        var configuration = draft
        configuration.tokenHubAutomaticReadingEnabled = automaticReadingEnabled
        return configuration
    }
    func apply(_ newConfig: AppConfiguration, upstreamKey: String, quotaKey: String) -> Bool {
        guard stats.active == 0 else { message = "请求进行中，请等待完成后再修改代理配置"; return false }
        do {
            var savedConfig = Self.configurationForApplying(newConfig,
                automaticReadingEnabled: tokenHubAutomaticReadingEnabled)
            if newConfig.dataSource == "localCodex" {
                savedConfig.endpoint = config.endpoint; savedConfig.usageURL = config.usageURL
            }
            _ = try savedConfig.validated()
            if savedConfig.dataSource == "proxy" {
                let old = config
                let resolvedAPI = upstreamKey.isEmpty ? (savedConfig.endpoint == old.endpoint && !apiKey.isEmpty ? apiKey : try KeychainStore.read("upstream", validatedURL: savedConfig.endpoint)) : upstreamKey
                let resolvedUsage = quotaKey.isEmpty && !savedConfig.usageURL.isEmpty ? (savedConfig.usageURL == old.usageURL && !usageKey.isEmpty ? usageKey : try KeychainStore.read("usage", validatedURL: savedConfig.usageURL)) : quotaKey
                try KeychainStore.write("upstream", validatedURL: savedConfig.endpoint, value: resolvedAPI)
                if !savedConfig.usageURL.isEmpty { try KeychainStore.write("usage", validatedURL: savedConfig.usageURL, value: resolvedUsage) }
                if localKey.isEmpty { localKey = try KeychainStore.localToken() }
                apiKey = resolvedAPI; usageKey = resolvedUsage
            }
            try ConfigStore.save(savedConfig)
            config = savedConfig
            if !config.historyEnabled { history.removeAll() }
            message = "设置已保存"; startServices(); return true
        } catch { message = error.localizedDescription; return false }
    }
    func reload() {
        guard stats.active == 0 else { message = "请求进行中，暂不能重新加载"; return }
        do {
            let loaded = try ConfigStore.load()
            if loaded.dataSource == "proxy" {
                localKey = try KeychainStore.localToken()
                apiKey = try KeychainStore.resolve("upstream", environment: "TOKENSTAT_API_KEY", validatedURL: loaded.endpoint)
                usageKey = loaded.usageURL.isEmpty ? "" : try KeychainStore.resolve("usage", environment: "TOKENSTAT_USAGE_KEY", validatedURL: loaded.usageURL)
            } else { apiKey = ""; usageKey = ""; localKey = "" }
            config = loaded; message = "配置已重新加载"; startServices()
        }
        catch { message = error.localizedDescription }
    }
    private func startServices() {
        generation += 1; tokenHubGeneration &+= 1; quotaLoop?.cancel(); quotaFetch?.cancel(); quotaFetch = nil; quotaLoading = false
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        tokenHubQuotaSnapshot = nil; tokenHubQuotaFailure = nil
        tokenHubAutomaticReadingEnabled = config.tokenHubAutomaticReadingEnabled
        tokenHubQuotaStatus = config.dataSource == "localCodex" && tokenHubAutomaticReadingEnabled ? .targetNotRunning : .disabled
        lastTokenHubPermissionCheck = .distantPast; cachedTokenHubPermission = false
        _ = localRefreshScheduler.invalidate()
        localCache = LocalCodexUsageReader.Cache()
        localScan?.cancel(); localScan = nil
        resetQuotaState()
        if config.dataSource == "localCodex" {
            if proxyWasStarted { proxy.stop(); proxyWasStarted = false }
            proxyStatus = "本地模式 · 未启动代理"
            scheduleLocalScan(immediate: true)
            if tokenHubAutomaticReadingEnabled { scheduleTokenHubRefresh(after: 0) }
            return
        }
        proxy.onStatus = { [weak self] status in Task { @MainActor in self?.proxyStatus = status } }
        proxy.onRecord = { [weak self] record in Task { @MainActor in if self?.config.loggingEnabled == true { self?.logger.append(record) } } }
        proxy.start(config: config, apiKey: apiKey, localKey: localKey)
        proxyWasStarted = true
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
    /// Clears quota values at a source transition without performing I/O.
    func resetQuotaState() {
        quota = nil
        fiveHourQuota = nil
        sevenDayQuota = nil
        quotaLoading = false
        quotaError = quotaSource == .localCodex ? "本地会话记录不提供月度企业配额"
            : (config.usageURL.isEmpty ? "未配置企业用量接口，已用量未知" : "等待企业接口")
    }
    private func scheduleLocalScan(immediate: Bool = false) {
        localScan?.cancel()
        let version = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isShuttingDown, self.generation == version,
                      self.config.dataSource == "localCodex" else { return }
                guard !self.localScanRunning else { return }
                guard let scanGeneration = self.localRefreshScheduler.begin(now: Date()) else {
                    self.scheduleLocalScan(immediate: false); return
                }
                self.localScanRunning = true
                let directory = LocalCodexUsageReader.defaultSessionsDirectory()
                let cache = self.localCache
                self.localScanQueue.async {
                    let result = try? LocalCodexUsageReader.scan(directory: directory, now: Date(), cache: cache)
                    Task { @MainActor in
                        self.localScanRunning = false
                        guard self.generation == version, self.localRefreshScheduler.complete(generation: scanGeneration, now: Date()) else {
                            if self.config.dataSource == "localCodex", !self.isShuttingDown { self.scheduleLocalScan(immediate: true) }
                            return
                        }
                        if self.config.dataSource == "localCodex" {
                            if let result {
                                self.localSnapshot = result; self.fiveHourQuota = result.fiveHour; self.sevenDayQuota = result.sevenDay
                                self.quotaError = result.latestEventAt == nil ? "未发现有效本地用量记录" : "额度来自 Codex 会话事件，可能已过期"
                            } else {
                                self.localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0, filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil, knownThreadCount: 0, unknownThreadCount: 0, unidentifiedFileCount: 0, subagentCount: 0, forkCount: 0)
                                self.fiveHourQuota = nil; self.sevenDayQuota = nil; self.quotaError = "本地会话记录暂时无法读取"
                            }
                        }
                        if self.config.dataSource == "localCodex" { self.scheduleLocalScan() }
                    }
                }
            }
        }
        localScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 5), execute: work)
    }
    func refreshTokenHubQuota() {
        guard !isShuttingDown else { return }
        guard !isFixtureUsingNativeTokenHubReader else { return }
        guard config.dataSource == "localCodex", tokenHubAutomaticReadingEnabled else {
            invalidateTokenHubQuota(status: .disabled); tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
            return
        }
        checkTokenHubPermissionIfDue(scheduleIfGranted: false)
        guard cachedTokenHubPermission else { invalidateTokenHubQuota(status: .permissionRequired); return }
        guard !tokenHubScanInFlight else { return }
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        tokenHubScanInFlight = true
        let version = tokenHubGeneration, mode: TokenHubRunMode = .localCodex
        let now = tokenHubNow(), interval = config.refreshSeconds
        let scanner = tokenHubScanner
        let permission = cachedTokenHubPermission
        tokenHubQueue.async { [weak self] in
            let result = scanner.scan(now: now, monotonicNow: { ProcessInfo.processInfo.systemUptime },
                                      permissionTrusted: permission, refreshSeconds: interval,
                                      mode: mode, generation: version)
            Task { @MainActor in
                guard let self else { return }
                self.tokenHubScanInFlight = false
                guard !self.isShuttingDown, self.tokenHubGeneration == version,
                      self.config.dataSource == "localCodex", self.tokenHubAutomaticReadingEnabled,
                      self.cachedTokenHubPermission else {
                    if !self.isShuttingDown, self.config.dataSource == "localCodex",
                       self.tokenHubAutomaticReadingEnabled, self.cachedTokenHubPermission {
                        self.scheduleTokenHubRefresh(after: 0)
                    }
                    return
                }
                self.applyTokenHubQuotaResult(result, generation: version, mode: mode, now: self.tokenHubNow())
                self.scheduleTokenHubRefresh(after: self.config.refreshSeconds)
            }
        }
    }

    func setTokenHubAutomaticReadingEnabled(_ enabled: Bool) {
        guard tokenHubAutomaticReadingEnabled != enabled else { return }
        tokenHubAutomaticReadingEnabled = enabled
        tokenHubGeneration &+= 1
        config.tokenHubAutomaticReadingEnabled = enabled
        if !isPreview { try? ConfigStore.save(config) }
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        if enabled && config.dataSource == "localCodex" && !isShuttingDown {
            tokenHubQuotaStatus = .targetNotRunning; tokenHubQuotaFailure = nil
            lastTokenHubPermissionCheck = .distantPast
            scheduleTokenHubRefresh(after: 0)
        } else { invalidateTokenHubQuota(status: .disabled) }
    }

    func requestTokenHubAccessibilityAccess() {
        guard !isPreview, !isTestFixture, config.dataSource == "localCodex", tokenHubAutomaticReadingEnabled, !isShuttingDown else { return }
        tokenHubPermissionProvider.requestOnceAndOpenSystemSettings()
        lastTokenHubPermissionCheck = .distantPast
        checkTokenHubPermissionIfDue(scheduleIfGranted: false)
        if cachedTokenHubPermission { refreshTokenHubQuota() }
        else { invalidateTokenHubQuota(status: .permissionRequired) }
    }

    func invalidateTokenHubQuota(status: TokenHubQuotaStatus) {
        tokenHubGeneration &+= 1
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        tokenHubQuotaSnapshot = nil; tokenHubQuotaFailure = nil; tokenHubQuotaStatus = status
    }

    func applyTokenHubQuotaResult(_ result: TokenHubQuotaResult, generation resultGeneration: UInt64,
                                  mode: TokenHubRunMode, now: Date) {
        guard !isShuttingDown, tokenHubGeneration == resultGeneration, cachedTokenHubPermission,
              config.dataSource == "localCodex", mode == .localCodex,
              tokenHubAutomaticReadingEnabled else { return }
        if result.status == .connected, let snapshot = result.snapshot {
            if let previous = tokenHubQuotaSnapshot, previous.identity != snapshot.identity {
                tokenHubQuotaSnapshot = nil
            }
            tokenHubQuotaSnapshot = snapshot
            tokenHubQuotaStatus = snapshot.observedAt > now || now.timeIntervalSince(snapshot.observedAt) > max(120, config.refreshSeconds * 2)
                ? .stale : .connected
            tokenHubQuotaFailure = nil
        } else {
            tokenHubQuotaSnapshot = nil
            tokenHubQuotaStatus = result.status
            tokenHubQuotaFailure = result.failure
        }
    }

    func freshTokenHubQuota(at now: Date) -> TokenHubQuotaSnapshot? {
        guard config.dataSource == "localCodex", tokenHubAutomaticReadingEnabled,
              tokenHubQuotaStatus == .connected, let snapshot = tokenHubQuotaSnapshot,
              snapshot.observedAt <= now,
              now.timeIntervalSince(snapshot.observedAt) <= max(120, config.refreshSeconds * 2) else { return nil }
        return snapshot
    }

    private func checkTokenHubPermissionIfDue(scheduleIfGranted: Bool = true) {
        let now = tokenHubNow()
        guard now.timeIntervalSince(lastTokenHubPermissionCheck) >= 2 else { return }
        let old = cachedTokenHubPermission
        cachedTokenHubPermission = tokenHubPermissionProvider.isTrusted()
        lastTokenHubPermissionCheck = now
        if old && !cachedTokenHubPermission { invalidateTokenHubQuota(status: .permissionRequired) }
        if scheduleIfGranted && !old && cachedTokenHubPermission && config.dataSource == "localCodex" && tokenHubAutomaticReadingEnabled {
            scheduleTokenHubRefresh(after: 0)
        }
    }

    private func pollTokenHubPermissionIfDue() {
        guard config.dataSource == "localCodex", tokenHubAutomaticReadingEnabled, !isShuttingDown,
              !isFixtureUsingNativeTokenHubReader else { return }
        checkTokenHubPermissionIfDue()
    }

    private func scheduleTokenHubRefresh(after seconds: TimeInterval) {
        guard config.dataSource == "localCodex", tokenHubAutomaticReadingEnabled,
              !isShuttingDown, !tokenHubScanInFlight, !isFixtureUsingNativeTokenHubReader else { return }
        tokenHubRefreshWork?.cancel()
        let version = tokenHubGeneration
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.isShuttingDown, self.tokenHubGeneration == version,
                      self.config.dataSource == "localCodex", self.tokenHubAutomaticReadingEnabled else { return }
                self.refreshTokenHubQuota()
            }
        }
        tokenHubRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds), execute: work)
    }

    static func shouldSuppressNativeTokenHubRead(isTestFixture: Bool, scannerIsNative: Bool) -> Bool {
        isTestFixture && scannerIsNative
    }
    var isFixtureUsingNativeTokenHubReader: Bool {
        Self.shouldSuppressNativeTokenHubRead(isTestFixture: isTestFixture,
            scannerIsNative: tokenHubScanner is TokenHubAXReader)
    }

    private func installTokenHubWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier else { return }
                Task { @MainActor in
                    if name == NSWorkspace.didLaunchApplicationNotification {
                        self?.tokenHubApplicationDidLaunch(bundleIdentifier: bundleID)
                    } else {
                        self?.tokenHubApplicationDidTerminate(bundleIdentifier: bundleID)
                    }
                }
            }
            tokenHubWorkspaceObservers.append(observer)
        }
    }

    /// Metadata-only lifecycle seam; no AX values or target contents are read here.
    func tokenHubApplicationDidTerminate(bundleIdentifier: String) {
        guard bundleIdentifier == TokenHubTarget.bundleID, !isShuttingDown else { return }
        invalidateTokenHubQuota(status: config.dataSource == "localCodex" ? .targetNotRunning : .disabled)
    }

    /// Metadata-only lifecycle seam; a launch never makes an old snapshot current.
    func tokenHubApplicationDidLaunch(bundleIdentifier: String) {
        guard bundleIdentifier == TokenHubTarget.bundleID, !isShuttingDown else { return }
        invalidateTokenHubQuota(status: config.dataSource == "localCodex" && tokenHubAutomaticReadingEnabled
            ? .targetNotRunning : .disabled)
        guard config.dataSource == "localCodex", tokenHubAutomaticReadingEnabled,
              !isFixtureUsingNativeTokenHubReader else { return }
        checkTokenHubPermissionIfDue(scheduleIfGranted: false)
        guard cachedTokenHubPermission else {
            tokenHubQuotaStatus = .permissionRequired
            return
        }
        scheduleTokenHubRefresh(after: 0)
    }

    func refreshQuota() {
        guard config.dataSource == "proxy", !config.usageURL.isEmpty, !quotaLoading else { return }
        quotaLoading = true
        let config = config, key = usageKey, version = generation
        quotaFetch = Task { [weak self] in
            defer { if self?.generation == version { self?.quotaLoading = false } }
            do {
                let result = try await QuotaClient.fetch(config: config, key: key)
                guard !Task.isCancelled, self?.generation == version else { return }
                self?.quota = result.monthly; self?.quotaError = result.monthlyMessage
                self?.fiveHourQuota = result.fiveHour; self?.sevenDayQuota = result.sevenDay
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
            if model.isTestFixture || model.config.dataSource == "localCodex" || !model.hasRequestData {
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
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.config.dataSource == "localCodex" {
                            TokenHubQuotaCard(snapshot: model.freshTokenHubQuota(at: Date()), status: model.tokenHubQuotaStatusText,
                                enabled: model.tokenHubAutomaticReadingEnabled, refreshSeconds: model.config.refreshSeconds)
                            localUsageCard
                        } else { liveCard }
                        HStack(alignment: .top, spacing: 10) {
                            WindowQuotaCard(title: "5 小时额度", quota: model.fiveHourQuota,
                                color: PanelPalette.blue, refreshSeconds: model.config.refreshSeconds, source: model.quotaSource)
                            WindowQuotaCard(title: "7 天额度", quota: model.sevenDayQuota,
                                color: PanelPalette.violet, refreshSeconds: model.config.refreshSeconds, source: model.quotaSource)
                        }
                        if model.config.dataSource == "localCodex" {
                            localQuotaCard
                        } else { sessionCard; quotaCard }
                        if model.config.dataSource == "proxy", model.config.historyEnabled, model.panelVisible { historyCard }
                        if model.config.dataSource == "proxy" { costCard; requestCard; connectionCard }
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
                Text(settings ? "本机网关与偏好设置" : (model.config.dataSource == "localCodex" ? "本地 Codex · 历史记录" : "实时用量 · 本次启动"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { settings.toggle() } label: {
                Image(systemName: settings ? "chart.bar.xaxis" : "slider.horizontal.3")
                    .frame(width: 28, height: 28)
            }.buttonStyle(.borderless).foregroundStyle(.secondary).help(settings ? "返回概览" : "连接与设置")
                .accessibilityLabel(settings ? "返回概览" : "连接与设置")
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").frame(width: 24, height: 28)
            }.buttonStyle(.borderless).foregroundStyle(.secondary).help("退出 TokenStatMenu").accessibilityLabel("退出")
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
    private var localUsageCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                metric("已核验小计 · 输入 Token", localCount(model.localSnapshot.input))
                metric("已核验小计 · 输出 Token", localCount(model.localSnapshot.output))
                metric(model.localSnapshot.hasCompleteAccounting ? "本次扫描记录量 · Token" : "已核验记录小计 · 总 Token",
                    model.localSnapshot.knownThreadCount > 0 ? count(model.localSnapshot.total) : "未知")
                metric("已核验线程", "\(model.localSnapshot.knownThreadCount)")
                metric("未核验线程", "\(model.localSnapshot.unknownThreadCount)")
                metric("未识别物理文件", "\(model.localSnapshot.unidentifiedFileCount)")
                metric("已识别顶层对话", "\(model.localSnapshot.sessionCount)")
                metric("已识别子代理 / 分叉", "\(model.localSnapshot.subagentCount) / \(model.localSnapshot.forkCount)")
                metric("最近用量事件", model.localSnapshot.latestEventAt?.formatted(date: .abbreviated, time: .shortened) ?? "未发现")
                if let turn = model.localSnapshot.lastTurn {
                    metric("上轮记录均速", String(format: "%.1f tok/s", turn.outputTPS))
                    metric("上轮完成时间", turn.completedAt.formatted(date: .abbreviated, time: .shortened))
                } else {
                    metric("上轮记录均速", "未知")
                }
                Text("仅汇总本次扫描中可核算的记录，未核验项不计入小计。顶层对话数不包含子代理和分叉；这里不是完整历史或企业账单。上轮均速含工具、网络和等待，不是模型瞬时生成速度。\(model.localSnapshot.isLimited ? "已达到扫描范围限制。" : "")")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } label: { Label("本地记录用量", systemImage: "doc.text.magnifyingglass") }
    }
    private var localQuotaCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                metric("5 小时额度", localQuotaDescription(model.fiveHourQuota))
                metric("7 天额度", localQuotaDescription(model.sevenDayQuota))
                Text("本地记录额度始终只是历史参考，不论事件是否新鲜；不代表当前企业剩余额度，也不触发企业额度告警。保留源记录的已用比例、记录时间和原重置时间。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if let at = model.fiveHourQuota?.fetchedAt ?? model.sevenDayQuota?.fetchedAt { Text("额度事件时间：\(at.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        } label: { Label("本地额度快照", systemImage: "chart.bar") }
    }
    private func localQuotaDescription(_ quota: WindowQuota?) -> String {
        let state = WindowQuotaCard.presentation(for: quota, refreshSeconds: model.config.refreshSeconds, source: .localCodex)
        guard let percent = state.usedPercent else { return state.statusLabel }
        let reset = state.resetsAt.map { " · \($0.formatted(date: .abbreviated, time: .shortened))重置" } ?? " · 重置时间未知"
        let recorded = state.recordedAt.map { " · 记录于 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        return "\(state.sourceLabel) · \(state.statusLabel) · 上游已用 \(String(format: "%.1f", percent))%\(recorded)\(reset)"
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
    private func localCount(_ n: Int) -> String { model.localSnapshot.knownThreadCount == 0 ? "—" : count(n) }
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
    static func fetch(config: AppConfiguration, key: String) async throws -> QuotaReport {
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
        return try QuotaReport.parse(data, config: config)
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
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                Picker("用量来源", selection: $draft.dataSource) {
                    Text("本地 Codex 记录").tag("localCodex")
                    Text("本机代理与企业接口").tag("proxy")
                }.pickerStyle(.segmented)
                if draft.dataSource == "proxy" {
                    discoverySection
                    upstreamSection
                    priceSection
                    quotaSection
                } else {
                    tokenHubSection
                    Text("从 ~/.codex/sessions 的有限范围中读取当前扫描范围记录。依据记录中的来源与父子关系区分顶层对话、子代理和分叉；无法核验的记录单独标示，不把未知贡献当作零或完整总量。仅读取有界文件片段，不连接本机代理、不读取凭据或企业接口。切换到代理模式可恢复企业接口配置。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                otherSection
                HStack {
                    Button("保存并应用") { _ = model.apply(draft, upstreamKey: apiKey, quotaKey: quotaKey) }.buttonStyle(.borderedProminent)
                    Button("重新加载 plist") { model.reload(); draft = model.config }
                }
                Text(model.isTestFixture ? "配置：隔离模拟配置" : "配置：\(AppPaths.configURL.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(16)
        }
        .textFieldStyle(.roundedBorder)
        .onChange(of: draft.endpoint) { _ in apiKey = "" }
        .onChange(of: draft.usageURL) { _ in quotaKey = "" }
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
    private var tokenHubSection: some View {
        GroupBox("Token Hub 界面额度") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("自动读取当前额度面板", isOn: Binding(
                    get: { model.tokenHubAutomaticReadingEnabled },
                    set: { model.setTokenHubAutomaticReadingEnabled($0) }))
                Text("仅读取已运行 Token Hub 的可访问性界面文字和进度。需要 macOS 辅助功能授权；自动读取仅在本地 Codex 模式启用。原始界面值不写入诊断或日志。账号、组织、币种与后台更新时间均未核验。")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("请求辅助功能访问…") { model.requestTokenHubAccessibilityAccess() }
                        .disabled(model.isTestFixture || !model.tokenHubAutomaticReadingEnabled)
                    Text(model.tokenHubQuotaStatusText).font(.caption2).foregroundStyle(.secondary)
                }
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
        GroupBox("企业额度接口 · 月度 / 5 小时 / 7 天") {
            VStack(alignment: .leading, spacing: 8) {
                field("用量 GET URL（可留空）", text: $draft.usageURL)
                Text("用量接口 Bearer Key（独立于推理 Key）").font(.caption)
                SecureField("可留空；不自动复用上游密钥", text: $quotaKey)
                field("已用 Token 字段路径", text: $draft.usedPath)
                field("总配额字段路径（可留空）", text: $draft.limitPath)
                field("月份字段路径（yyyy-MM；留空信任接口本月语义）", text: $draft.periodPath)
                number("手动月度 Token 上限（0 = 接口值）", value: $draft.monthlyLimit)
                number("刷新秒数（15–3600）", value: $draft.refreshSeconds)
                Divider()
                field("5 小时已用百分比字段（0–100）", text: $draft.fiveHourUsedPercentPath)
                field("5 小时重置时间字段", text: $draft.fiveHourResetPath)
                field("7 天已用百分比字段（0–100）", text: $draft.sevenDayUsedPercentPath)
                field("7 天重置时间字段", text: $draft.sevenDayResetPath)
                Text("重置时间支持 Unix 秒或 ISO 8601。缺少窗口时显示未提供；不会从月度配额或本机 Token 推算。也可接收带明确窗口时长的 Codex rateLimits 格式。")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("月度已用量、总配额和手动月度上限必须使用 Token 数量，不能填金额或积分；窗口字段使用 0–100 的百分比。手动配额不会推算全企业已用量。达到 80% 黄色、95% 红色，仅改变菜单栏颜色。")
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
        item.button?.toolTip = model.menuTooltip
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
        if let window = popover.contentViewController?.view.window {
            window.makeKey()
            // Avoid a green default-button focus ring on open. Native keyboard
            // traversal still establishes and displays focus when the user tabs.
            window.makeFirstResponder(nil)
        }
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
            let fiveHourUsedPercent: Double?
            let sevenDayUsedPercent: Double?
            let quotaError: String
            let tokenHubSourceEnabled: Bool
            let tokenHubPermissionGranted: Bool
            let tokenHubPermissionRequired: Bool
            let tokenHubWindowPresent: Bool
            let tokenHubMenuSuffixPresent: Bool
            let alert: String
        }
        let appliedColor = (item.button?.attributedTitle.length ?? 0) > 0
            ? item.button?.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            : nil
        // The actual title can contain a live AX-derived percentage. Diagnostics retain only
        // the non-AX portion and readiness booleans; no AX content crosses this sink.
        let safeTitle = (item.button?.attributedTitle.string ?? "")
            .replacingOccurrences(of: #" · Hub .*?$"#, with: "", options: .regularExpression)
        let report = Report(isTestFixture: model.isTestFixture, hasRequestData: model.hasRequestData,
            dataNotice: model.dataNotice, discoveredGateways: model.gateways.count,
            title: safeTitle, popoverShown: popover.isShown,
            statusItemVisible: item.isVisible, active: model.stats.active,
            quotaUsed: model.quota?.used, quotaFraction: model.quota?.fraction,
            fiveHourUsedPercent: model.fiveHourQuota?.usedPercent, sevenDayUsedPercent: model.sevenDayQuota?.usedPercent,
            quotaError: model.quotaError,
            tokenHubSourceEnabled: model.config.dataSource == "localCodex" && model.tokenHubAutomaticReadingEnabled,
            tokenHubPermissionGranted: model.tokenHubPermissionGrantedForDiagnostics,
            tokenHubPermissionRequired: model.tokenHubPermissionRequiredForDiagnostics,
            tokenHubWindowPresent: model.tokenHubQuotaSnapshot?.fiveHour != nil || model.tokenHubQuotaSnapshot?.sevenDay != nil,
            tokenHubMenuSuffixPresent: model.menuTitleContainsTokenHubSuffix,
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
import CryptoKit
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
        let loaded = try PropertyListSerialization.propertyList(from: Data(contentsOf: AppPaths.configURL), format: nil)
        guard let values = loaded as? [String: Any] else { throw StatError.message("配置必须是 plist 字典") }
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
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
    static func accountName(_ purpose: String, validatedURL: String) throws -> String {
        guard ["upstream", "usage"].contains(purpose),
              let url = URL(string: validatedURL), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              ["https", "http"].contains(url.scheme ?? "") else { throw StatError.message("无效密钥绑定 URL") }
        let digest = SHA256.hash(data: Data(validatedURL.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(purpose)-\(digest)"
    }
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
    static func read(_ purpose: String, validatedURL: String) throws -> String {
        try read(try accountName(purpose, validatedURL: validatedURL))
    }
    static func write(_ purpose: String, validatedURL: String, value: String) throws {
        try write(try accountName(purpose, validatedURL: validatedURL), value: value)
    }
    static func resolve(_ purpose: String, environment: String, validatedURL: String) throws -> String {
        if let value = ProcessInfo.processInfo.environment[environment] { return value }
        return try read(purpose, validatedURL: validatedURL)
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
        if CommandLine.arguments.contains("--request-accessibility") {
            model.requestTokenHubAccessibilityAccess()
        }
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

### Sources/TokenStatMenu/WindowQuotaCard.swift

```swift
import SwiftUI
#if SWIFT_PACKAGE
import TokenStatCore
#endif

enum QuotaSource: Equatable {
    case localCodex
    case enterprise
}

struct WindowQuotaPresentation: Equatable {
    let sourceLabel: String
    let isFresh: Bool
    let usedPercent: Double?
    let resetsAt: Date?
    let recordedAt: Date?
    let statusLabel: String
}

struct WindowQuotaCard: View {
    let title: String
    let quota: WindowQuota?
    let color: Color
    let refreshSeconds: Double
    let source: QuotaSource
    static func presentation(for quota: WindowQuota?, at now: Date = Date(), refreshSeconds: Double,
                             source: QuotaSource = .enterprise) -> WindowQuotaPresentation {
        let sourceLabel = source == .localCodex ? "本地 Codex 历史快照 · 账号/组织未核验" : "已配置企业用量接口数据"
        guard let quota else {
            return WindowQuotaPresentation(sourceLabel: sourceLabel, isFresh: false, usedPercent: nil,
                resetsAt: nil, recordedAt: nil, statusLabel: source == .localCodex ? "本地历史额度未提供" : "企业额度未提供")
        }
        if source == .localCodex {
            let resetStatus: String
            if let reset = quota.resetsAt { resetStatus = reset <= now ? " · 重置已过期" : "" }
            else { resetStatus = " · 重置时间未知" }
            return WindowQuotaPresentation(sourceLabel: sourceLabel, isFresh: false, usedPercent: quota.usedPercent,
                resetsAt: quota.resetsAt, recordedAt: quota.fetchedAt,
                statusLabel: quota.fetchedAt > now ? "本地历史参考 · 异常时间戳" : "本地历史参考\(resetStatus)")
        }
        if quota.fetchedAt > now {
            return WindowQuotaPresentation(sourceLabel: sourceLabel, isFresh: false, usedPercent: quota.usedPercent,
                resetsAt: quota.resetsAt, recordedAt: quota.fetchedAt, statusLabel: "企业额度异常时间戳")
        }
        let fresh = quota.isFresh(at: now, refreshSeconds: refreshSeconds)
        let staleLabel: String
        if quota.resetsAt.map({ $0 <= now }) == true { staleLabel = "企业历史额度 · 已过期" }
        else { staleLabel = "企业历史额度" }
        return WindowQuotaPresentation(sourceLabel: sourceLabel, isFresh: fresh, usedPercent: quota.usedPercent,
            resetsAt: quota.resetsAt, recordedAt: quota.fetchedAt, statusLabel: fresh ? "企业当前额度" : staleLabel)
    }
    var body: some View {
        let presentation = Self.presentation(for: quota, refreshSeconds: refreshSeconds, source: source)
        let fresh = presentation.isFresh
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(source == .localCodex ? presentation.usedPercent.map { String(format: "%.1f%%", $0) } ?? "—"
                        : fresh ? String(format: "%.1f%%", quota!.remainingPercent) : "—")
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(fresh ? color : .secondary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                    if source == .localCodex, presentation.usedPercent != nil {
                        Text("历史已用").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else if fresh { Text("剩余").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                Text(presentation.sourceLabel)
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                if source == .enterprise {
                    GeometryReader { geometry in
                        Capsule().fill(color.opacity(0.12))
                        if fresh, let quota {
                            Capsule().fill(color).frame(width: geometry.size.width * quota.remainingPercent / 100)
                        }
                    }.frame(height: 5)
                }
                if let used = presentation.usedPercent {
                    Text(String(format: "上游已用 %.1f%%", used))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if !fresh {
                        Text(presentation.statusLabel + (source == .enterprise ? " · 等待刷新" : ""))
                            .foregroundStyle(source == .enterprise ? .orange : .secondary)
                    }
                    if let recordedAt = presentation.recordedAt {
                        Text("记录于 " + recordedAt.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                            .foregroundStyle(.secondary)
                    }
                    if let reset = presentation.resetsAt {
                        Text((fresh ? "重置于 " : "原重置时间 ") + reset.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                            .foregroundStyle(.secondary)
                    } else if fresh { Text("重置时间未提供").foregroundStyle(.secondary) }
                } else {
                    Text(presentation.statusLabel).foregroundStyle(.secondary)
                    Text("重置时间未知").foregroundStyle(.secondary)
                }
            }.font(.system(size: 9)).frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label(title, systemImage: "clock") }
    }
}
```

### Sources/TokenStatMenu/TokenHubAXReader.swift

```swift
import AppKit
import ApplicationServices
import Foundation
#if SWIFT_PACKAGE
import TokenStatCore
#endif

@MainActor
protocol TokenHubPermissionProviding {
    func isTrusted() -> Bool
    func requestOnceAndOpenSystemSettings()
}

/// Production boundary for one scan. AX objects live only in this instance's one scan call.
final class TokenHubAXReader: TokenHubQuotaScanning {
    private let tree = TokenHubNativeTreeReader()
    private let scanner = TokenHubQuotaScanner()

    func scan(now: Date, monotonicNow: () -> TimeInterval, permissionTrusted: Bool,
              refreshSeconds: TimeInterval, mode: TokenHubRunMode,
              generation: UInt64) -> TokenHubQuotaResult {
        tree.beginScan()
        defer { tree.endScan() }
        return scanner.scan(using: tree, now: now, monotonicNow: monotonicNow,
                            permissionTrusted: permissionTrusted, refreshSeconds: refreshSeconds,
                            mode: mode, generation: generation)
    }
}

@MainActor
final class TokenHubNativePermissionProvider: TokenHubPermissionProviding {
    private static var didRequestThisProcess = false
    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func requestOnceAndOpenSystemSettings() {
        if !Self.didRequestThisProcess {
            Self.didRequestThisProcess = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

private final class TokenHubNativeTreeReader: TokenHubBoundedTreeReading {
    private var nodes: [TokenHubNodeID: AXUIElement] = [:]
    private var roles: [TokenHubNodeID: TokenHubAXRole] = [:]
    private var nextID = 1
    private var candidates: [pid_t: NSRunningApplication] = [:]

    func beginScan() { nodes.removeAll(keepingCapacity: false); roles.removeAll(keepingCapacity: false); nextID = 1; candidates.removeAll(keepingCapacity: false) }
    func endScan() { nodes.removeAll(keepingCapacity: false); roles.removeAll(keepingCapacity: false); candidates.removeAll(keepingCapacity: false) }

    func exactBundleTargets(bundleID: String) throws -> [TokenHubIdentity] {
        guard bundleID == TokenHubTarget.bundleID else { return [] }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: TokenHubTarget.bundleID)
            .filter { !$0.isTerminated }
        candidates = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0) })
        let identities = apps.compactMap { self.identity(for: $0) }
        guard identities.count == apps.count else { throw TokenHubNativeReadError.identity }
        return identities
    }

    func rootNode(for identity: TokenHubIdentity, timeout: TimeInterval) throws -> TokenHubNodeID {
        guard let app = candidates[identity.pid], let current = self.identity(for: app), current == identity else {
            throw TokenHubNativeReadError.identity
        }
        let element = AXUIElementCreateApplication(identity.pid)
        return register(element)
    }

    func identity(of node: TokenHubNodeID, timeout: TimeInterval) throws -> TokenHubIdentity {
        let element = try element(for: node)
        var pid: pid_t = 0
        try prepare(element, timeout: timeout)
        guard AXUIElementGetPid(element, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid),
              let identity = identity(for: app) else { throw TokenHubNativeReadError.identity }
        return identity
    }

    func role(of node: TokenHubNodeID, timeout: TimeInterval) throws -> TokenHubAXRole {
        let element = try element(for: node)
        let raw = try copyAttribute(element, attribute: kAXRoleAttribute as CFString, timeout: timeout)
        guard let role = raw as? String else { throw TokenHubNativeReadError.attribute }
        let value: TokenHubAXRole
        switch role {
        case kAXApplicationRole as String: value = .application
        case kAXWindowRole as String: value = .window
        case kAXGroupRole as String: value = .group
        case kAXStaticTextRole as String: value = .staticText
        case kAXProgressIndicatorRole as String: value = .progressIndicator
        case kAXButtonRole as String, kAXRadioButtonRole as String, kAXCheckBoxRole as String,
             kAXPopUpButtonRole as String, kAXMenuButtonRole as String, "AXLink":
            value = .button
        case kAXTableRole as String, kAXOutlineRole as String, kAXListRole as String:
            value = .table
        case kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String:
            value = .editableText
        case "AXSecureTextField": value = .secureText
        default: value = .other(role)
        }
        roles[node] = value
        return value
    }

    func groupLabel(of node: TokenHubNodeID, kind: TokenHubGroupLabelKind,
                    timeout: TimeInterval) throws -> String? {
        guard roles[node] == .group else { throw TokenHubNativeReadError.attribute }
        let attribute = kind == .description ? kAXDescriptionAttribute as CFString : kAXTitleAttribute as CFString
        return try stringAttribute(node, attribute: attribute, maximumCharacters: 257, timeout: timeout)
    }

    func children(of node: TokenHubNodeID, maximum: Int, timeout: TimeInterval) throws -> TokenHubChildrenPage {
        guard maximum >= 0, maximum <= 64,
              roles[node] != .staticText, roles[node] != .progressIndicator else { throw TokenHubNativeReadError.attribute }
        let element = try element(for: node)
        var count: CFIndex = 0
        try prepare(element, timeout: timeout)
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success else {
            throw TokenHubNativeReadError.attribute
        }
        guard count <= maximum else { return TokenHubChildrenPage(nodes: [], isTruncated: true) }
        guard count > 0 else { return TokenHubChildrenPage(nodes: [], isTruncated: false) }
        var value: CFArray?
        try prepare(element, timeout: timeout)
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &value) == .success,
              let values = value as? [AXUIElement], values.count == count else { throw TokenHubNativeReadError.attribute }
        return TokenHubChildrenPage(nodes: values.map(register), isTruncated: false)
    }

    func staticText(of node: TokenHubNodeID, maximumCharacters: Int, timeout: TimeInterval) throws -> String? {
        guard roles[node] == .staticText else { throw TokenHubNativeReadError.attribute }
        return try stringAttribute(node, attribute: kAXValueAttribute as CFString, maximumCharacters: maximumCharacters + 1, timeout: timeout)
    }

    func progressLabel(of node: TokenHubNodeID, timeout: TimeInterval) throws -> String? {
        guard roles[node] == .progressIndicator else { throw TokenHubNativeReadError.attribute }
        return try stringAttribute(node, attribute: kAXDescriptionAttribute as CFString, maximumCharacters: 257, timeout: timeout)
    }

    func progressValue(of node: TokenHubNodeID, timeout: TimeInterval) throws -> Decimal? {
        guard roles[node] == .progressIndicator else { throw TokenHubNativeReadError.attribute }
        let element = try element(for: node)
        guard let value = try copyOptionalAttribute(element, attribute: kAXValueAttribute as CFString, timeout: timeout) else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
        guard let number = value as? NSNumber else { return nil }
        return Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX"))
    }

    private func identity(for app: NSRunningApplication) -> TokenHubIdentity? {
        guard !app.isTerminated, let bundleID = app.bundleIdentifier, let executable = app.executableURL?.standardizedFileURL.path else { return nil }
        return TokenHubIdentity(pid: app.processIdentifier, bundleID: bundleID, executablePath: executable)
    }
    private func register(_ element: AXUIElement) -> TokenHubNodeID {
        let id = nextID; nextID += 1; nodes[id] = element; return id
    }
    private func element(for node: TokenHubNodeID) throws -> AXUIElement {
        guard let element = nodes[node] else { throw TokenHubNativeReadError.missingNode }
        return element
    }
    private func prepare(_ element: AXUIElement, timeout: TimeInterval) throws {
        // Set timeout on this exact element before each AX message; never on the application root
        // as a substitute for an element-specific limit.
        guard AXUIElementSetMessagingTimeout(element, Float(timeout)) == .success else {
            throw TokenHubNativeReadError.timeout
        }
    }
    private func copyAttribute(_ element: AXUIElement, attribute: CFString, timeout: TimeInterval) throws -> AnyObject {
        try prepare(element, timeout: timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else { throw TokenHubNativeReadError.attribute }
        return value as AnyObject
    }
    private func stringAttribute(_ node: TokenHubNodeID, attribute: CFString,
                                 maximumCharacters: Int, timeout: TimeInterval) throws -> String? {
        guard let value = try copyOptionalAttribute(element(for: node), attribute: attribute, timeout: timeout),
              let raw = value as? String else { return nil }
        return String(raw.prefix(maximumCharacters))
    }
    private func copyOptionalAttribute(_ element: AXUIElement, attribute: CFString,
                                       timeout: TimeInterval) throws -> AnyObject? {
        try prepare(element, timeout: timeout)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &value)
        if status == .noValue || status == .attributeUnsupported { return nil }
        guard status == .success, let value else { throw TokenHubNativeReadError.attribute }
        return value as AnyObject
    }
}

private enum TokenHubNativeReadError: Error { case timeout, attribute, identity, missingNode }
```

### Sources/TokenStatMenu/TokenHubQuotaCard.swift

```swift
import SwiftUI
#if SWIFT_PACKAGE
import TokenStatCore
#endif

enum TokenHubDecimalFormatter {
    static func string(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}

@MainActor struct TokenHubQuotaCard: View {
    let snapshot: TokenHubQuotaSnapshot?
    let status: String
    let enabled: Bool
    let refreshSeconds: Double
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                Text("仅读取 Token Hub 界面显示；账号与组织未核验，币种未核验。与本机 Token 统计、企业 API 配额和费用分开。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Text("Token Hub 后台更新时间未提供。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                if let snapshot {
                    if let window = snapshot.fiveHour { row("5 小时", window.usedPercent, window.usedAmount, window.limitAmount, window.sourceSymbol, window.resetDisplay) }
                    if let window = snapshot.sevenDay { row("7 天", window.usedPercent, window.usedAmount, window.limitAmount, window.sourceSymbol, window.resetDisplay) }
                    if let monthly = snapshot.monthly {
                        HStack { Text("月度已用"); Spacer(); Text("\(monthly.sourceSymbol)\(amount(monthly.usedAmount))").monospacedDigit() }
                            .font(.system(size: 10))
                    }
                    Text("界面读取于 \(snapshot.observedAt.formatted(.dateTime.hour().minute()))；快照有效期 \(Int(max(120, refreshSeconds * 2))) 秒")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    Text(enabled ? status : "自动读取已关闭").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label("Token Hub 界面额度快照", systemImage: "window.ceiling") }
    }
    private func row(_ title: String, _ usedPercent: Decimal, _ used: Decimal, _ limit: Decimal, _ symbol: String, _ reset: String) -> some View {
        let remainingPercent = Decimal(100) - usedPercent
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer(minLength: 0)
            Text("剩余 \(TokenHubDecimalFormatter.string(remainingPercent))%")
                .fontWeight(.semibold).monospacedDigit()
            }
            HStack {
                Text("界面已用 \(TokenHubDecimalFormatter.string(usedPercent))% · \(symbol)\(amount(used)) / \(symbol)\(amount(limit))")
                    .monospacedDigit()
                Spacer(minLength: 0)
                Text("重置 \(reset)").foregroundStyle(.secondary)
            }
        }.font(.system(size: 10))
    }
    private func amount(_ value: Decimal) -> String { TokenHubDecimalFormatter.string(value) }
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
<plist version="1.0">
<dict>
	<key>endpoint</key>
	<string>http://127.0.0.1:11434/v1/chat/completions</string>
	<key>model</key>
	<string></string>
	<key>port</key>
	<integer>18765</integer>
	<key>includeUsage</key>
	<true/>
	<key>allowInsecureHTTP</key>
	<false/>
	<key>inputPrice</key>
	<real>0.0</real>
	<key>outputPrice</key>
	<real>0.0</real>
	<key>currency</key>
	<string>USD</string>
	<key>usdToCNY</key>
	<real>7.0</real>
	<key>monthlyLimit</key>
	<real>0.0</real>
	<key>usageURL</key>
	<string></string>
	<key>usedPath</key>
	<string>data.used_tokens</string>
	<key>limitPath</key>
	<string>data.total_tokens</string>
	<key>periodPath</key>
	<string>data.month</string>
	<key>refreshSeconds</key>
	<real>60.0</real>
	<key>loggingEnabled</key>
	<false/>
	<key>historyEnabled</key>
	<true/>
	<key>tokenHubAutomaticReadingEnabled</key>
	<true/>
	<key>fiveHourUsedPercentPath</key>
	<string>data.five_hour.used_percent</string>
	<key>fiveHourResetPath</key>
	<string>data.five_hour.resets_at</string>
	<key>sevenDayUsedPercentPath</key>
	<string>data.seven_day.used_percent</string>
	<key>sevenDayResetPath</key>
	<string>data.seven_day.resets_at</string>
</dict>
</plist>
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
967CB92DBAF3C5042457AF3F = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "LocalCodexUsageReader.swift"; sourceTree = "<group>"; };
2D299820E6AC3A52FFC40FC8 = { isa = PBXBuildFile; fileRef = 967CB92DBAF3C5042457AF3F; };
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
0C519B277D7405758007F620 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "TokenHubAXScanning.swift"; sourceTree = "<group>"; };
FE8BDDD173656D12A732897D = { isa = PBXBuildFile; fileRef = 0C519B277D7405758007F620; };
854D234B4ABC73F4622474C9 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "TokenHubQuota.swift"; sourceTree = "<group>"; };
EE000FBD14AA318AC3D38D79 = { isa = PBXBuildFile; fileRef = 854D234B4ABC73F4622474C9; };
52C5DE96C0BE6977037C956F = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "WindowQuota.swift"; sourceTree = "<group>"; };
D495B366C1D0E1A6672A9637 = { isa = PBXBuildFile; fileRef = 52C5DE96C0BE6977037C956F; };
AF7F4C7B765701F258FB7F4D = { isa = PBXGroup; children = (8E4403D07D4E24DF01F86E5D, 6060CB36BD32E4DE62121D71, 25DB8EC2672FE7C810B75A38, 967CB92DBAF3C5042457AF3F, 4C87C1C697E481BB11B23261, 99081DE7CEB5C9C7DAFEADA1, 4B0A93085460A2D4B5B2F8C2, A1B8AA05224B907A20995624, 951D8E55C70DA883B1E10A70, 0C519B277D7405758007F620, 854D234B4ABC73F4622474C9, 52C5DE96C0BE6977037C956F,); path = "Sources/TokenStatCore"; sourceTree = "<group>"; };
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
25AEEBE9806DD6E732A43A43 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "TokenHubAXReader.swift"; sourceTree = "<group>"; };
4BE492A2D95B99D7EAB5E1B2 = { isa = PBXBuildFile; fileRef = 25AEEBE9806DD6E732A43A43; };
F32057C12C25AA597CC2C1C9 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "TokenHubQuotaCard.swift"; sourceTree = "<group>"; };
3263F0161C5BC399111E323B = { isa = PBXBuildFile; fileRef = F32057C12C25AA597CC2C1C9; };
9215CF293A4FF1D70E77EC32 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "TokenStatMenuApp.swift"; sourceTree = "<group>"; };
B71BD30B9E5D41A06B13B456 = { isa = PBXBuildFile; fileRef = 9215CF293A4FF1D70E77EC32; };
414355FEF7F80FBFD58C7086 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "WindowQuotaCard.swift"; sourceTree = "<group>"; };
164B1DA057D49AA2DDF2EB36 = { isa = PBXBuildFile; fileRef = 414355FEF7F80FBFD58C7086; };
96BD6B98AF8DAF812B21484D = { isa = PBXGroup; children = (11043337019FA9BE53E5DEA5, B3117F547294E09EFEF92409, 1568C8A45BC98EBCCE9A8EA4, 54DC60746B43C432B61ADBD4, 7DBBE1964667520E74C4B575, 262E8C516B62E763FA6537BF, 3D39E548358F39784FDEFE9F, 25AEEBE9806DD6E732A43A43, F32057C12C25AA597CC2C1C9, 9215CF293A4FF1D70E77EC32, 414355FEF7F80FBFD58C7086,); path = "Sources/TokenStatMenu"; sourceTree = "<group>"; };
A8792157CB4F27FB949C035F = { isa = PBXFileReference; explicitFileType = wrapper.application; path = TokenStatMenu.app; sourceTree = BUILT_PRODUCTS_DIR; };
0A3E27B8CA818264D75C8D81 = { isa = PBXGroup; children = (A8792157CB4F27FB949C035F,); name = Products; sourceTree = "<group>"; };
9B987D631012EC23CDD96B6A = { isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Resources/Info.plist"; sourceTree = "<group>"; };
652E7FD0652728D9B3EF13DF = { isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Resources/config.example.plist"; sourceTree = "<group>"; };
0D6E4079E36703EBD37C0072 = { isa = PBXGroup; children = (AF7F4C7B765701F258FB7F4D, 96BD6B98AF8DAF812B21484D, 9B987D631012EC23CDD96B6A, 652E7FD0652728D9B3EF13DF, 0A3E27B8CA818264D75C8D81,); sourceTree = "<group>"; };
878A52FC5FF6A57D50B7B870 = { isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (6A3864C6E6DB561D02F46C35, 08BC9043587CC788D01C24E7, C6D71C6FAB45AC1E6B57A569, 2D299820E6AC3A52FFC40FC8, BACF14F65A3D26C56E4559AC, DDA47B3DEE61C34C2F297CF7, 49E56DE5EE1D3357BC99E0B5, E51281927C6E41F6B2F2A59B, 06CC516465ECBFB9656FCFE3, FE8BDDD173656D12A732897D, EE000FBD14AA318AC3D38D79, D495B366C1D0E1A6672A9637, 60476D6C0F010F89CDCF9332, BBE06DCD34D248AEC63DEFB1, 1C6C1E79E7D0D3008EFA0C51, 29DBAC87E7D2D08969C25259, DF47DB83567E12D94C90C186, 775730CD86C47FBDC9419E49, F2E25F94650242E3A64878B7, 4BE492A2D95B99D7EAB5E1B2, 3263F0161C5BC399111E323B, B71BD30B9E5D41A06B13B456, 164B1DA057D49AA2DDF2EB36,); runOnlyForDeploymentPostprocessing = 0; };
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
        try windowQuotaChecks()
        try localCodexUsageChecks()
        try hubChecks()
        try hubScannerChecks()
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

### Tests/TokenStatCoreTests/WindowQuotaChecks.swift

```swift
import Foundation
import TokenStatCore

extension CoreChecks {
    static func windowQuotaChecks() throws {
        let config = AppConfiguration(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let response = json("""
        {"data":{"five_hour":{"used_percent":25,"resets_at":1800003600},"seven_day":{"used_percent":70,"resets_at":"2027-01-17T08:00:00Z"}}}
        """)
        let report = try QuotaReport.parse(response, config: config, now: now)
        check(report.monthly == nil && report.fiveHour?.remainingPercent == 75, "5-hour quota independent of missing monthly fields")
        check(report.sevenDay?.usedPercent == 70 && report.sevenDay?.resetsAt != nil, "7-day quota and ISO reset timestamp")
        check(report.fiveHour?.isFresh(at: now.addingTimeInterval(30), refreshSeconds: 60) == true, "window fresh before reset")
        check(report.fiveHour?.isFresh(at: now.addingTimeInterval(121), refreshSeconds: 60) == false, "stale quota never drives current alerts")
        check(report.fiveHour?.isFresh(at: now.addingTimeInterval(4000), refreshSeconds: 3600) == false, "reset time expires quota even with long refresh interval")
        let codex = json("""
        {"rateLimits":{"primary":{"usedPercent":45,"windowDurationMins":10080,"resetsAt":1800007200},"secondary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1800003600}}}
        """)
        let normalized = try QuotaReport.parse(codex, config: config, now: now)
        check(normalized.fiveHour?.usedPercent == 10 && normalized.sevenDay?.usedPercent == 45, "classify Codex windows by duration, not primary/secondary position")
        let wrappedCodex = json("""
        {"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300},"secondary":{"usedPercent":60,"windowDurationMins":10080}}}}
        """)
        let wrapped = try QuotaReport.parse(wrappedCodex, config: config, now: now)
        check(wrapped.fiveHour?.usedPercent == 20 && wrapped.sevenDay?.usedPercent == 60, "classify duration-based windows under the result wrapper")
        let unknown = json("{\"rateLimits\":{\"primary\":{\"usedPercent\":10,\"windowDurationMins\":null}}}")
        do { _ = try QuotaReport.parse(unknown, config: config, now: now); check(false, "unknown duration must not become 5-hour quota") } catch { check(true, "unknown duration is not guessed") }
        var ambiguousConfig = config
        ambiguousConfig.sevenDayUsedPercentPath = "data.seven_day.used_percent"
        let ambiguous = json("""
        {"data":{"seven_day":{"used_percent":65}},"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300},"secondary":{"usedPercent":30,"windowDurationMins":300}}}
        """)
        let ambiguousReport = try QuotaReport.parse(ambiguous, config: ambiguousConfig, now: now)
        check(ambiguousReport.fiveHour == nil && ambiguousReport.sevenDay?.usedPercent == 65, "duplicate 5-hour duration stays unknown without discarding configured 7-day sibling")
        let partial = try QuotaReport.parse(json("{\"data\":{\"five_hour\":{\"used_percent\":0}}}"), config: config, now: now)
        check(partial.fiveHour?.remainingPercent == 100 && partial.fiveHour?.resetsAt == nil && partial.sevenDay == nil, "zero is valid, unknown reset and missing window stay unknown")
        let full = try QuotaReport.parse(json("{\"data\":{\"five_hour\":{\"used_percent\":100,\"resets_at\":1800003600}}}"), config: config, now: now)
        check(full.fiveHour?.usedPercent == 100 && full.fiveHour?.remainingPercent == 0, "100 percent is valid and means zero remaining")
        let percentage = try QuotaReport.parse(json("{\"data\":{\"five_hour\":{\"used_percent\":0.85}}}"), config: config, now: now)
        check(percentage.fiveHour?.remainingPercent == 99.15, "percentage fields never guessed as fractional ratios")
        for value in ["true", "-1", "101"] {
            do { _ = try QuotaReport.parse(json("{\"data\":{\"five_hour\":{\"used_percent\":\(value)}}}"), config: config, now: now); check(false, "invalid percent should fail") }
            catch { check(true, "invalid percent rejected") }
        }
        let invalidStringSibling = try QuotaReport.parse(json("{\"data\":{\"five_hour\":{\"used_percent\":\"not-a-number\"},\"seven_day\":{\"used_percent\":40}}}"), config: config, now: now)
        check(invalidStringSibling.fiveHour == nil && invalidStringSibling.sevenDay?.usedPercent == 40, "invalid string percentage does not erase valid sibling window")
        do {
            _ = try QuotaReport.parse(json("{\"data\":{\"five_hour\":{\"used_percent\":\"not-a-number\"}}}"), config: config, now: now)
            check(false, "invalid percentage string alone must not create a quota report")
        } catch { check(true, "invalid percentage string rejected") }
        let invalidReset = try QuotaReport.parse(json("{\"data\":{\"five_hour\":{\"used_percent\":20,\"resets_at\":\"not-an-ISO-date\"}}}"), config: config, now: now)
        check(invalidReset.fiveHour?.usedPercent == 20 && invalidReset.fiveHour?.resetsAt == nil, "invalid reset format preserves usage with unknown reset")
        let resetNow = try QuotaReport.parse(json("{\"data\":{\"five_hour\":{\"used_percent\":20,\"resets_at\":1800000000}}}"), config: config, now: now.addingTimeInterval(-1))
        check(resetNow.fiveHour?.isFresh(at: now.addingTimeInterval(-1), refreshSeconds: 3600) == true, "window remains fresh immediately before reset time")
        check(resetNow.fiveHour?.isFresh(at: now, refreshSeconds: 3600) == false, "reset time equal to now is expired")
        let milliseconds = try QuotaReport.parse(json("{\"data\":{\"five_hour\":{\"used_percent\":10,\"resets_at\":1800003600000}}}"), config: config, now: now)
        check(milliseconds.fiveHour?.resetsAt == nil, "milliseconds must not silently become a far-future seconds timestamp")
        var customPaths = config
        customPaths.fiveHourUsedPercentPath = "payload.windows.0.used"
        customPaths.fiveHourResetPath = "payload.windows.0.reset"
        let customPathReport = try QuotaReport.parse(json("{\"payload\":{\"windows\":[{\"used\":35,\"reset\":\"2027-01-15T08:00:00Z\"}]}}"), config: customPaths, now: now)
        check(customPathReport.fiveHour?.usedPercent == 35 && customPathReport.fiveHour?.resetsAt != nil, "configured paths support nested objects and array indices")
        let month = QuotaSnapshot.currentMonth(at: now)
        let monthly = try QuotaReport.parse(json("{\"data\":{\"used_tokens\":800,\"total_tokens\":1000,\"month\":\"\(month)\"}}"), config: config, now: now)
        check(monthly.monthly?.fraction == 0.8 && monthly.fiveHour == nil && monthly.sevenDay == nil, "monthly-only APIs remain supported without manufacturing windows")
    }
}
```

### Tests/TokenStatCoreTests/LocalCodexUsageChecks.swift

```swift
import CoreFoundation
import Foundation
@testable import TokenStatCore

extension CoreChecks {
    static func localCodexUsageChecks() throws {
        let now = Date(timeIntervalSince1970: 1_797_000_000)

        var refresh = LocalRefreshScheduler()
        let firstGeneration = refresh.begin(now: now)
        check(firstGeneration != nil && refresh.begin(now: now.addingTimeInterval(1)) == nil,
            "local scheduler allows one startup scan and never overlaps an in-flight scan")
        if let generation = firstGeneration {
            check(refresh.complete(generation: generation, now: now.addingTimeInterval(3)),
                "local scheduler accepts completion for the active generation")
            check(refresh.begin(now: now.addingTimeInterval(7.9)) == nil
                && refresh.begin(now: now.addingTimeInterval(8)) != nil,
                "next local scan is due five seconds after the prior scan completes")
        } else {
            check(false, "local scheduler accepts completion for the active generation")
            check(false, "next local scan is due five seconds after the prior scan completes")
        }
        var cancelledRefresh = LocalRefreshScheduler()
        let staleGeneration = cancelledRefresh.begin(now: now)
        _ = cancelledRefresh.invalidate()
        if let staleGeneration {
            check(!cancelledRefresh.complete(generation: staleGeneration, now: now.addingTimeInterval(10)),
                "mode/root invalidation rejects a late local scan result")
        } else {
            check(false, "mode/root invalidation rejects a late local scan result")
        }

        let aggregateRoot = try fixtureDirectory("aggregate")
        defer { try? FileManager.default.removeItem(at: aggregateRoot.deletingLastPathComponent()) }
        let firstID = "11111111-1111-4111-8111-111111111111"
        let secondID = "22222222-2222-4222-8222-222222222222"
        let firstEvents = try [
            tokenEvent(at: now.addingTimeInterval(-300), input: 20, output: 10, cached: 7, reasoning: 4),
            tokenEvent(at: now.addingTimeInterval(-200), input: 50, output: 20),
            tokenEvent(at: now.addingTimeInterval(-120), input: 2, output: 3, cached: 1, reasoning: 1)
        ]
        try writeSession(in: aggregateRoot, uuid: firstID, events: firstEvents, modified: now.addingTimeInterval(-100))
        try writeSession(in: aggregateRoot, uuid: secondID,
            events: [tokenEvent(at: now.addingTimeInterval(-60), input: 4, output: 6)], modified: now)
        let aggregate = try LocalCodexUsageReader.scan(directory: aggregateRoot, now: now)
        check(aggregate.input == 6 && aggregate.output == 9 && aggregate.total == 15,
            "local Codex totals use each session's last cumulative counter, including a lower reset value")
        check(aggregate.sessionCount == 2 && aggregate.latestEventAt == now.addingTimeInterval(-60),
            "local Codex reports metadata-backed top-level count and latest event timestamp")
        check(aggregate.knownThreadCount == 2 && aggregate.unknownThreadCount == 0
            && aggregate.unidentifiedFileCount == 0 && aggregate.hasCompleteAccounting,
            "two valid root metadata records produce complete accounting independently of session count")
        check(aggregate.input == 6 && aggregate.output == 9,
            "cached input and reasoning output subfields are not added twice")
        let rescanned = try LocalCodexUsageReader.scan(directory: aggregateRoot, now: now)
        check(rescanned.input == aggregate.input && rescanned.output == aggregate.output
            && rescanned.total == aggregate.total && rescanned.sessionCount == aggregate.sessionCount,
            "repeated local Codex scans replace the snapshot instead of accumulating it")
        let reflectedFields = Set(Mirror(reflecting: aggregate).children.compactMap(\.label))
        check(reflectedFields == Set(["input", "output", "total", "sessionCount", "filesScanned",
            "isLimited", "latestEventAt", "fiveHour", "sevenDay", "lastTurn", "knownThreadCount",
            "unknownThreadCount", "unidentifiedFileCount", "subagentCount", "forkCount"]),
            "local Codex snapshot reflection exposes only the bounded metadata fields")

        let exactZeroRoot = try fixtureDirectory("metadata-backed-exact-zero")
        try writeSession(in: exactZeroRoot, uuid: "12121212-1212-4212-8212-121212121213",
            events: [tokenEvent(at: now, input: 0, output: 0)], modified: now)
        let exactZero = try LocalCodexUsageReader.scan(directory: exactZeroRoot, now: now)
        check(exactZero.knownThreadCount == 1 && exactZero.hasCompleteAccounting
            && exactZero.total == 0,
            "a metadata-backed known zero is distinguishable from absence of any known thread")
        try? FileManager.default.removeItem(at: exactZeroRoot.deletingLastPathComponent())

        let noEvidenceRoot = try fixtureDirectory("no-accounting-evidence")
        let noEvidence = try LocalCodexUsageReader.scan(directory: noEvidenceRoot, now: now)
        check(noEvidence.knownThreadCount == 0 && noEvidence.unknownThreadCount == 0
            && noEvidence.unidentifiedFileCount == 0 && !noEvidence.hasCompleteAccounting,
            "no files is unknown coverage, not a complete exact zero")
        try? FileManager.default.removeItem(at: noEvidenceRoot.deletingLastPathComponent())

        let turnRoot = try fixtureDirectory("completed-turn")
        let turnID = "abababab-abab-4bab-8bab-aaaaaaaaaaaa"
        try writeSession(in: turnRoot, uuid: turnID, events: [
            turnTokenEvent(at: now.addingTimeInterval(-2), output: 100),
            turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "turn-1"),
            turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 140),
            turnBoundary(at: now, type: "task_complete", id: "turn-1", durationMS: 1000)
        ], modified: now)
        let completedTurn = try LocalCodexUsageReader.scan(directory: turnRoot, now: now)
        check(completedTurn.lastTurn?.outputTokens == 40
            && completedTurn.lastTurn?.durationSeconds == 1
            && completedTurn.lastTurn?.outputTPS == 40,
            "completed local turn speed uses last in-turn cumulative output delta over whole turn duration")
        if let turn = completedTurn.lastTurn {
            let fields = Mirror(reflecting: turn).children
            let turnFields = Set(fields.compactMap(\.label))
            check(turnFields == Set(["outputTokens", "durationSeconds", "completedAt"])
                && fields.allSatisfy { !($0.value is String) && !($0.value is URL) && !($0.value is Data) },
                "turn reflection exposes only narrow numeric and timestamp fields, with no identifier or path")
        } else {
            check(false, "turn reflection exposes only narrow numeric and timestamp fields, with no identifier or path")
        }
        try? FileManager.default.removeItem(at: turnRoot.deletingLastPathComponent())

        let equalTimestampRoot = try fixtureDirectory("equal-turn-timestamps")
        try writeSession(in: equalTimestampRoot, uuid: "acacacac-acac-4cac-8cac-aaaaaaaaaaaa", events: [
            turnTokenEvent(at: now.addingTimeInterval(-1), output: 3),
            turnBoundary(at: now, type: "task_started", id: "turn-equal"),
            turnTokenEvent(at: now, output: 8),
            turnBoundary(at: now, type: "task_complete", id: "turn-equal", durationMS: 100)
        ], modified: now)
        let equalTimestamps = try LocalCodexUsageReader.scan(directory: equalTimestampRoot, now: now)
        check(equalTimestamps.lastTurn?.outputTokens == 5
            && equalTimestamps.lastTurn?.durationSeconds == 0.1,
            "equal adjacent timestamps are valid in JSONL order when duration_ms establishes a valid turn")
        try? FileManager.default.removeItem(at: equalTimestampRoot.deletingLastPathComponent())

        let invalidDurationRoot = try fixtureDirectory("invalid-turn-duration")
        try writeSession(in: invalidDurationRoot, uuid: "adadadad-adad-4dad-8dad-aaaaaaaaaaaa", events: [
            turnTokenEvent(at: now.addingTimeInterval(-2), output: 3),
            turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "turn-bad"),
            turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 8),
            turnBoundary(at: now, type: "task_complete", id: "turn-bad", durationLiteral: "true")
        ], modified: now)
        let invalidDuration = try LocalCodexUsageReader.scan(directory: invalidDurationRoot, now: now)
        check(invalidDuration.lastTurn == nil,
            "present invalid duration_ms rejects a turn instead of falling back to timestamps")
        try? FileManager.default.removeItem(at: invalidDurationRoot.deletingLastPathComponent())

        let laterBaselineRoot = try fixtureDirectory("late-timestamp-baseline")
        try writeSession(in: laterBaselineRoot, uuid: "bebebebe-bebe-4ebe-8ebe-aaaaaaaaaaaa", events: [
            turnTokenEvent(at: now.addingTimeInterval(-3), output: 1),
            turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 2),
            turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "late-baseline"),
            turnTokenEvent(at: now.addingTimeInterval(-0.25), output: 3),
            turnBoundary(at: now, type: "task_complete", id: "late-baseline", durationMS: 1000)
        ], modified: now)
        let lateBaseline = try LocalCodexUsageReader.scan(directory: laterBaselineRoot, now: now)
        check(lateBaseline.lastTurn == nil,
            "reader cannot skip a later-recorded baseline whose timestamp is after start to use an earlier baseline")
        try? FileManager.default.removeItem(at: laterBaselineRoot.deletingLastPathComponent())

        let nestedTurnsRoot = try fixtureDirectory("outer-incomplete-inner-complete")
        try writeSession(in: nestedTurnsRoot, uuid: "bebebebe-bebe-4ebe-8ebe-bbbbbbbbbbbb", events: [
            turnTokenEvent(at: now.addingTimeInterval(-4), output: 1),
            turnBoundary(at: now.addingTimeInterval(-3), type: "task_started", id: "outer"),
            turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "inner"),
            turnTokenEvent(at: now.addingTimeInterval(-1), output: 4),
            turnBoundary(at: now, type: "task_complete", id: "inner", durationMS: 1000)
        ], modified: now)
        let nestedTurns = try LocalCodexUsageReader.scan(directory: nestedTurnsRoot, now: now)
        check(nestedTurns.lastTurn == nil,
            "an inner complete turn cannot be accepted while an outer overlapping turn remains open")
        try? FileManager.default.removeItem(at: nestedTurnsRoot.deletingLastPathComponent())

        let malformedExplicitRoot = try fixtureDirectory("malformed-explicit-usage")
        try writeSession(in: malformedExplicitRoot, uuid: "bfbfbfbf-bfbf-4bfb-8bfb-aaaaaaaaaaaa", events: [
            turnTokenEvent(at: now.addingTimeInterval(-2), output: 1),
            turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "bad-usage"),
            turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 2),
            rawTokenEvent(at: now.addingTimeInterval(-0.25), inputLiteral: "null", outputLiteral: "3"),
            turnBoundary(at: now, type: "task_complete", id: "bad-usage", durationMS: 1000)
        ], modified: now)
        let malformedExplicit = try LocalCodexUsageReader.scan(directory: malformedExplicitRoot, now: now)
        check(malformedExplicit.lastTurn == nil,
            "explicit null or malformed cumulative usage cannot be ignored after valid in-turn usage")
        try? FileManager.default.removeItem(at: malformedExplicitRoot.deletingLastPathComponent())

        var oversizedPrefix = Data(repeating: 0x78, count: 256 * 1024 + 32)
        oversizedPrefix.append(10)
        let tailCompleteRoot = try fixtureDirectory("tail-complete-turn")
        try writeSession(in: tailCompleteRoot, uuid: "babababa-baba-4bab-8bab-aaaaaaaaaaaa", events: [
            turnTokenEvent(at: now.addingTimeInterval(-2), output: 2),
            turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "tail"),
            turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 5),
            turnBoundary(at: now, type: "task_complete", id: "tail", durationMS: 1000)
        ], modified: now, prefix: oversizedPrefix)
        let tailComplete = try LocalCodexUsageReader.scan(directory: tailCompleteRoot, now: now)
        check(tailComplete.lastTurn?.outputTokens == 3,
            "a complete turn retained within the bounded tail remains eligible")
        try? FileManager.default.removeItem(at: tailCompleteRoot.deletingLastPathComponent())

        let tailMissingBaselineRoot = try fixtureDirectory("tail-missing-baseline")
        try writeSession(in: tailMissingBaselineRoot, uuid: "bcbabcbc-bcbc-4bcb-8bcb-aaaaaaaaaaaa", events: [
            turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "tail"),
            turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 5),
            turnBoundary(at: now, type: "task_complete", id: "tail", durationMS: 1000)
        ], modified: now, prefix: oversizedPrefix)
        let tailMissingBaseline = try LocalCodexUsageReader.scan(directory: tailMissingBaselineRoot, now: now)
        check(tailMissingBaseline.lastTurn == nil,
            "a truncated tail missing the cumulative baseline cannot produce turn speed")
        try? FileManager.default.removeItem(at: tailMissingBaselineRoot.deletingLastPathComponent())

        let fallbackRoot = try fixtureDirectory("turn-duration-fallback")
        try writeSession(in: fallbackRoot, uuid: "afafafaf-afaf-4faf-8faf-aaaaaaaaaaaa", events: [
            turnTokenEvent(at: now.addingTimeInterval(-1), output: 10),
            turnBoundary(at: now.addingTimeInterval(-0.5), type: "task_started", id: "turn-fallback"),
            turnTokenEvent(at: now.addingTimeInterval(-0.25), output: 30),
            turnBoundary(at: now, type: "task_complete", id: "turn-fallback")
        ], modified: now)
        let fallback = try LocalCodexUsageReader.scan(directory: fallbackRoot, now: now)
        check(fallback.lastTurn?.outputTokens == 20 && fallback.lastTurn?.durationSeconds == 0.5,
            "absent duration_ms falls back to start-to-completion event timestamp duration")
        try? FileManager.default.removeItem(at: fallbackRoot.deletingLastPathComponent())

        let activeAfterCompletionRoot = try fixtureDirectory("completed-before-active")
        try writeSession(in: activeAfterCompletionRoot, uuid: "baababaa-baba-4bab-8bab-aaaaaaaaaaaa", events: [
            turnTokenEvent(at: now.addingTimeInterval(-4), output: 10),
            turnBoundary(at: now.addingTimeInterval(-3), type: "task_started", id: "completed"),
            turnTokenEvent(at: now.addingTimeInterval(-2), output: 30),
            turnBoundary(at: now.addingTimeInterval(-1), type: "task_complete", id: "completed", durationMS: 2000),
            turnTokenEvent(at: now.addingTimeInterval(-0.9), output: 30),
            turnBoundary(at: now.addingTimeInterval(-0.8), type: "task_started", id: "latest"),
            turnTokenEvent(at: now.addingTimeInterval(-0.6), output: 50),
            turnBoundary(at: now.addingTimeInterval(-0.3), type: "task_complete", id: "latest", durationMS: 500),
            turnBoundary(at: now.addingTimeInterval(-0.2), type: "task_started", id: "still-active"),
            turnTokenEvent(at: now, output: 80)
        ], modified: now)
        let retainedCompleted = try LocalCodexUsageReader.scan(directory: activeAfterCompletionRoot, now: now)
        check(retainedCompleted.lastTurn?.outputTokens == 20 && retainedCompleted.lastTurn?.durationSeconds == 0.5,
            "the most recent completed turn wins, and a still-active turn does not replace it")
        try? FileManager.default.removeItem(at: activeAfterCompletionRoot.deletingLastPathComponent())

        let rejectedTurnCases: [(String, [Data])] = try [
            ("missing-baseline", [turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnTokenEvent(at: now, output: 2), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)]),
            ("invalid-explicit-baseline", [rawTokenEvent(at: now.addingTimeInterval(-2), inputLiteral: "0", outputLiteral: "-1"), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 2), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)]),
            ("invalid-later-in-turn-usage", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-0.75), output: 2), rawTokenEvent(at: now.addingTimeInterval(-0.5), inputLiteral: "0", outputLiteral: "-1"), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)]),
            ("missing-start", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1), turnTokenEvent(at: now.addingTimeInterval(-1), output: 2), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)]),
            ("missing-complete", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnTokenEvent(at: now, output: 2)]),
            ("missing-in-turn-usage", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)]),
            ("overlap", [turnTokenEvent(at: now.addingTimeInterval(-4), output: 1), turnBoundary(at: now.addingTimeInterval(-3), type: "task_started", id: "x"), turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "y"), turnTokenEvent(at: now.addingTimeInterval(-1), output: 2), turnBoundary(at: now.addingTimeInterval(-0.5), type: "task_complete", id: "x", durationMS: 2000), turnBoundary(at: now, type: "task_complete", id: "y", durationMS: 1000)]),
            ("reused-id", [turnTokenEvent(at: now.addingTimeInterval(-5), output: 1), turnBoundary(at: now.addingTimeInterval(-4), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-3), output: 2), turnBoundary(at: now.addingTimeInterval(-2), type: "task_complete", id: "x", durationMS: 1000), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnTokenEvent(at: now, output: 3), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)]),
            ("post-complete-usage", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000), turnTokenEvent(at: now, output: 4)]),
            ("mismatched-id", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 2), turnBoundary(at: now, type: "task_complete", id: "y", durationMS: 1000)]),
            ("missing-start-timestamp-with-duration", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1),
                turnBoundaryWithoutTimestamp(type: "task_started", id: "x"),
                turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 2),
                turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)]),
            ("missing-baseline-timestamp-with-duration", [turnTokenEventWithoutTimestamp(output: 1),
                turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"),
                turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 2),
                turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)]),
            ("aborted", [turnTokenEvent(at: now.addingTimeInterval(-3), output: 1), turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-1), output: 2), turnBoundary(at: now.addingTimeInterval(-0.5), type: "turn_aborted", id: "x"), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)]),
            ("future-complete", [turnTokenEvent(at: now.addingTimeInterval(-3), output: 1), turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-1), output: 2), turnBoundary(at: now.addingTimeInterval(1), type: "task_complete", id: "x", durationMS: 1000)]),
            ("timestamp-regression", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-1.5), output: 2), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)]),
            ("null-duration", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 2), turnBoundary(at: now, type: "task_complete", id: "x", durationLiteral: "null")]),
            ("negative-duration", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 2), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: -1)]),
            ("too-short-duration", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 2), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 99)]),
            ("rollback", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 10), turnBoundary(at: now.addingTimeInterval(-1.5), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-1), output: 15), turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 12), turnTokenEvent(at: now.addingTimeInterval(-0.25), output: 18), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)])
        ]
        for (label, events) in rejectedTurnCases {
            let root = try fixtureDirectory("turn-reject-\(label)")
            let uuid = UUID().uuidString.lowercased()
            try writeSession(in: root, uuid: uuid, events: events, modified: now)
            let result = try LocalCodexUsageReader.scan(directory: root, now: now)
            check(result.lastTurn == nil, "invalid turn evidence is rejected: \(label)")
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
        let duplicateCompletionRoot = try fixtureDirectory("duplicate-turn-completion")
        try writeSession(in: duplicateCompletionRoot, uuid: "bbabbbab-babb-4bab-8bab-aaaaaaaaaaaa", events: [
            turnTokenEvent(at: now.addingTimeInterval(-3), output: 1),
            turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "once"),
            turnTokenEvent(at: now.addingTimeInterval(-1), output: 2),
            turnBoundary(at: now.addingTimeInterval(-0.5), type: "task_complete", id: "once", durationMS: 1000),
            turnBoundary(at: now, type: "task_complete", id: "once", durationMS: 1000)
        ], modified: now)
        let duplicateCompletion = try LocalCodexUsageReader.scan(directory: duplicateCompletionRoot, now: now)
        check(duplicateCompletion.lastTurn?.outputTokens == 1,
            "duplicate completion does not double-count the same completed turn")
        try? FileManager.default.removeItem(at: duplicateCompletionRoot.deletingLastPathComponent())

        let cacheRoot = try fixtureDirectory("warm-cache")
        try writeSession(in: cacheRoot, uuid: "aeaeaeae-aeae-4eae-8eae-aaaaaaaaaaaa",
            events: [tokenEvent(at: now, input: 2, output: 3)], modified: now)
        let cache = LocalCodexUsageReader.Cache()
        _ = try LocalCodexUsageReader.scan(directory: cacheRoot, now: now, cache: cache)
        _ = try LocalCodexUsageReader.scan(directory: cacheRoot, now: now, cache: cache)
        let diagnostics = cache.diagnostics
        check(diagnostics.cacheHits == 1 && diagnostics.bytesRead == 0
            && diagnostics.parsedFiles == 0 && diagnostics.safeOpens == 1,
            "unchanged local session is safely reopened and served from numeric cache without reading or parsing bytes")
        let freshnessRoot = try fixtureDirectory("cache-quota-freshness")
        try writeSession(in: freshnessRoot, uuid: "c3c3c3c3-c3c3-4c3c-8c3c-aaaaaaaaaaaa", events: [
            tokenEvent(at: now, input: 1, output: 1,
                rateLimits: rateLimits(fiveHour: 20, sevenDay: nil, reset: now.addingTimeInterval(3600)))
        ], modified: now)
        let freshnessCache = LocalCodexUsageReader.Cache()
        let freshSnapshot = try LocalCodexUsageReader.scan(directory: freshnessRoot, now: now, cache: freshnessCache)
        let staleSnapshot = try LocalCodexUsageReader.scan(directory: freshnessRoot, now: now.addingTimeInterval(180), cache: freshnessCache)
        check(freshSnapshot.fiveHour?.isFresh(at: now, refreshSeconds: 60) == true
            && staleSnapshot.fiveHour?.isFresh(at: now.addingTimeInterval(180), refreshSeconds: 60) == false
            && freshnessCache.diagnostics.cacheHits == 1,
            "cache hit reevaluates quota freshness against the current scan time")
        try? FileManager.default.removeItem(at: freshnessRoot.deletingLastPathComponent())

        let futureOnRollbackRoot = try fixtureDirectory("cache-now-rollback")
        let futureCompletion = now.addingTimeInterval(10)
        try writeSession(in: futureOnRollbackRoot, uuid: "c5c5c5c5-c5c5-4c5c-8c5c-aaaaaaaaaaaa", events: [
            turnTokenEvent(at: now.addingTimeInterval(-2), output: 1),
            turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "future"),
            turnTokenEvent(at: now, output: 2),
            turnBoundary(at: futureCompletion, type: "task_complete", id: "future", durationMS: 1000)
        ], modified: now)
        let rollbackCache = LocalCodexUsageReader.Cache()
        _ = try LocalCodexUsageReader.scan(directory: futureOnRollbackRoot, now: futureCompletion.addingTimeInterval(1), cache: rollbackCache)
        let afterRollback = try LocalCodexUsageReader.scan(directory: futureOnRollbackRoot, now: now, cache: rollbackCache)
        check(afterRollback.lastTurn == nil && rollbackCache.diagnostics.cacheHits == 1,
            "warm numeric cache revalidates completion time when the scan clock moves backward")
        try? FileManager.default.removeItem(at: futureOnRollbackRoot.deletingLastPathComponent())
        let cachedPath = sessionURL(in: cacheRoot, uuid: "aeaeaeae-aeae-4eae-8eae-aaaaaaaaaaaa")
        var appended = try Data(contentsOf: cachedPath)
        appended.append(try tokenEvent(at: now, input: 3, output: 4)); appended.append(10)
        try appended.write(to: cachedPath)
        let changedCache = try LocalCodexUsageReader.scan(directory: cacheRoot, now: now, cache: cache)
        check(changedCache.input == 3 && changedCache.output == 4
            && cache.diagnostics.cacheHits == 0 && cache.diagnostics.bytesRead > 0,
            "appending to a cached local session invalidates its prior numeric summary")
        var sameSizeRewrite = try Data(contentsOf: cachedPath)
        // Keep the JSONL byte count stable while changing its numeric payload.
        let originalBytes = Data("\"input_tokens\":3".utf8)
        let rewrittenBytes = Data("\"input_tokens\":4".utf8)
        if let range = sameSizeRewrite.range(of: originalBytes) {
            sameSizeRewrite.replaceSubrange(range, with: rewrittenBytes)
        } else {
            check(false, "same-size cache rewrite fixture locates the input count")
        }
        let originalFileSize = try Data(contentsOf: cachedPath).count
        check(sameSizeRewrite.count == originalFileSize,
            "same-size cache rewrite fixture preserves byte count")
        try sameSizeRewrite.write(to: cachedPath)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(2)], ofItemAtPath: cachedPath.path)
        let rewrittenCache = try LocalCodexUsageReader.scan(directory: cacheRoot, now: now, cache: cache)
        check(rewrittenCache.input == 4 && rewrittenCache.output == 4 && cache.diagnostics.cacheHits == 0,
            "same-size rewrite with changed file metadata invalidates cached summary")
        var truncatedBytes = try Data(contentsOf: cachedPath)
        truncatedBytes.removeLast(min(10, truncatedBytes.count))
        try truncatedBytes.write(to: cachedPath)
        let truncatedCache = try LocalCodexUsageReader.scan(directory: cacheRoot, now: now, cache: cache)
        check(truncatedCache.input == 0 && truncatedCache.output == 0
            && truncatedCache.knownThreadCount == 0 && truncatedCache.unknownThreadCount == 1
            && !truncatedCache.hasCompleteAccounting
            && cache.diagnostics.cacheHits == 0 && cache.diagnostics.bytesRead > 0,
            "truncating a cached latest cumulative line reparses and makes the thread unknown")
        let otherRoot = try fixtureDirectory("cache-other-root")
        try writeSession(in: otherRoot, uuid: "aeaeaeae-aeae-4eae-8eae-aaaaaaaaaaaa",
            events: [tokenEvent(at: now, input: 9, output: 9)], modified: now)
        let rootIsolated = try LocalCodexUsageReader.scan(directory: otherRoot, now: now, cache: cache)
        check(rootIsolated.input == 9 && rootIsolated.output == 9
            && cache.diagnostics.cacheHits == 0 && cache.entryCount <= 32,
            "same UUID, size and mtime under another root do not hit prior root's cache")
        try? FileManager.default.removeItem(at: otherRoot.deletingLastPathComponent())
        let sameRootA = try fixtureDirectory("same-identity-root-a")
        let sameRootB = try fixtureDirectory("same-identity-root-b")
        let sharedUUID = "c1c1c1c1-c1c1-4c1c-8c1c-aaaaaaaaaaaa"
        try writeSession(in: sameRootA, uuid: sharedUUID,
            events: [tokenEvent(at: now, input: 5, output: 6)], modified: now)
        try writeSession(in: sameRootB, uuid: sharedUUID,
            events: [tokenEvent(at: now, input: 7, output: 8)], modified: now)
        let rootProofCache = LocalCodexUsageReader.Cache()
        _ = try LocalCodexUsageReader.scan(directory: sameRootA, now: now, cache: rootProofCache)
        let rootProofResult = try LocalCodexUsageReader.scan(directory: sameRootB, now: now, cache: rootProofCache)
        check(rootProofResult.input == 7 && rootProofResult.output == 8
            && rootProofCache.diagnostics.cacheHits == 0,
            "identical UUID, byte size and modification time remain isolated by root identity")
        try? FileManager.default.removeItem(at: sameRootA.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: sameRootB.deletingLastPathComponent())
        let inodeRoot = try fixtureDirectory("inode-replacement")
        let inodeUUID = "c2c2c2c2-c2c2-4c2c-8c2c-aaaaaaaaaaaa"
        try writeSession(in: inodeRoot, uuid: inodeUUID,
            events: [tokenEvent(at: now, input: 1, output: 2)], modified: now)
        let inodeCache = LocalCodexUsageReader.Cache()
        _ = try LocalCodexUsageReader.scan(directory: inodeRoot, now: now, cache: inodeCache)
        try Data("replacement".utf8).write(to: sessionURL(in: inodeRoot, uuid: inodeUUID), options: .atomic)
        let inodeReplaced = try LocalCodexUsageReader.scan(directory: inodeRoot, now: now, cache: inodeCache)
        check(inodeReplaced.input == 0 && inodeCache.diagnostics.cacheHits == 0,
            "atomic same-path replacement invalidates cached descriptor identity")
        try? FileManager.default.removeItem(at: inodeRoot.deletingLastPathComponent())
        let isolatedCache = LocalCodexUsageReader.Cache()
        _ = try LocalCodexUsageReader.scan(directory: cacheRoot, now: now, cache: isolatedCache)
        check(isolatedCache.entryCount == 1 && cache.entryCount == 1,
            "reader cache instances isolate roots and retain only bounded numeric summaries")
        _ = try LocalCodexUsageReader.scan(directory: cacheRoot, now: now, cache: cache)
        try FileManager.default.removeItem(at: cachedPath)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-cache-outside-\(UUID().uuidString).jsonl")
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: cachedPath, withDestinationURL: outside)
        let replacedBySymlink = try LocalCodexUsageReader.scan(directory: cacheRoot, now: now, cache: cache)
        check(replacedBySymlink.input == 0 && replacedBySymlink.output == 0,
            "deleted cached file replaced by symlink is not served from stale cache")
        try? FileManager.default.removeItem(at: outside)
        try? FileManager.default.removeItem(at: cacheRoot.deletingLastPathComponent())

        let cappedCacheRoot = try fixtureDirectory("cache-cap")
        for index in 0..<33 {
            let uuid = String(format: "bcbcbcbc-bcbc-4bcb-8bcb-%012d", index + 1)
            try writeSession(in: cappedCacheRoot, uuid: uuid,
                events: [tokenEvent(at: now, input: 1, output: 1)], modified: now.addingTimeInterval(Double(index)))
        }
        let cappedCache = LocalCodexUsageReader.Cache()
        _ = try LocalCodexUsageReader.scan(directory: cappedCacheRoot, now: now, cache: cappedCache)
        check(cappedCache.entryCount <= 32, "per-reader numeric cache retains at most 32 summaries")
        try? FileManager.default.removeItem(at: cappedCacheRoot.deletingLastPathComponent())

        let raceRoot = try fixtureDirectory("metadata-race")
        let racedURL = sessionURL(in: raceRoot, uuid: "bdcdbdcd-bdcd-4bcd-8bcd-aaaaaaaaaaaa")
        try writeSession(in: raceRoot, uuid: "bdcdbdcd-bdcd-4bcd-8bcd-aaaaaaaaaaaa",
            events: [tokenEvent(at: now, input: 100, output: 100)], modified: now)
        try writeSession(in: raceRoot, uuid: "bebdbebd-bebd-4beb-8beb-aaaaaaaaaaaa",
            events: [tokenEvent(at: now, input: 7, output: 8)], modified: now)
        var raced = false
        let raceCache = LocalCodexUsageReader.Cache(beforePostReadValidation: {
            guard !raced else { return }
            raced = true
            try? Data("replacement".utf8).write(to: racedURL)
        })
        let raceResult = try LocalCodexUsageReader.scan(directory: raceRoot, now: now, cache: raceCache)
        check(raceResult.input == 7 && raceResult.output == 8,
            "metadata change during read drops only that file while retaining other safe file results")
        try? FileManager.default.removeItem(at: raceRoot.deletingLastPathComponent())

        let duplicateRoot = try fixtureDirectory("duplicate")
        let duplicateID = "abc33333-3333-4333-8333-333333333333"
        try writeSession(in: duplicateRoot, uuid: duplicateID,
            events: [tokenEvent(at: now.addingTimeInterval(-30), input: 1, output: 1)], modified: now.addingTimeInterval(-20))
        let lowercaseFixture = sessionURL(in: duplicateRoot, uuid: duplicateID)
        try FileManager.default.moveItem(at: lowercaseFixture,
            to: duplicateRoot.appendingPathComponent("rollout-primary-\(duplicateID).jsonl"))
        try writeSession(in: duplicateRoot, uuid: duplicateID.uppercased(),
            events: [tokenEvent(at: now.addingTimeInterval(-10), input: 8, output: 9)], modified: now,
            metadataID: duplicateID.uppercased())
        let uppercaseFixture = sessionURL(in: duplicateRoot, uuid: duplicateID.uppercased())
        try FileManager.default.moveItem(at: uppercaseFixture,
            to: duplicateRoot.appendingPathComponent("rollout-alias-\(duplicateID.uppercased()).jsonl"))
        let duplicate = try LocalCodexUsageReader.scan(directory: duplicateRoot, now: now)
        check(duplicate.sessionCount == 0 && duplicate.knownThreadCount == 0
            && duplicate.unknownThreadCount == 1 && !duplicate.hasCompleteAccounting,
            "same metadata UUID with non-identical rollouts is an unknown conflict group, never an mtime winner")
        try? FileManager.default.removeItem(at: duplicateRoot.deletingLastPathComponent())

        let identicalRoot = try fixtureDirectory("byte-identical-rollout-copy")
        let identicalID = "abab2222-2222-4222-8222-222222222222"
        try writeSession(in: identicalRoot, uuid: identicalID,
            events: [tokenEvent(at: now, input: 8, output: 9)], modified: now)
        let original = sessionURL(in: identicalRoot, uuid: identicalID)
        let copy = identicalRoot.appendingPathComponent("rollout-copy-ffffffff-ffff-4fff-8fff-ffffffffffff.jsonl")
        try FileManager.default.copyItem(at: original, to: copy)
        let identical = try LocalCodexUsageReader.scan(directory: identicalRoot, now: now)
        check(identical.knownThreadCount == 1 && identical.unknownThreadCount == 0
            && identical.input == 8 && identical.output == 9,
            "complete byte-identical physical rollouts collapse to one known logical thread")
        let hardlink = identicalRoot.appendingPathComponent("rollout-hardlink.jsonl")
        try FileManager.default.linkItem(at: original, to: hardlink)
        let hardlinked = try LocalCodexUsageReader.scan(directory: identicalRoot, now: now)
        check(hardlinked.knownThreadCount == 1 && hardlinked.unknownThreadCount == 0
            && hardlinked.input == 8 && hardlinked.output == 9,
            "hardlinked physical paths collapse by inode identity")
        try? FileManager.default.removeItem(at: identicalRoot.deletingLastPathComponent())

        let unprovenDuplicateRoot = try fixtureDirectory("duplicate-unproven-middle")
        let unprovenID = "abab2323-2323-4323-8323-232323232323"
        var firstMiddle = Data(repeating: 0x61, count: 400 * 1024)
        var secondMiddle = firstMiddle
        secondMiddle.replaceSubrange(100 * 1024..<100 * 1024 + 1, with: [0x62])
        firstMiddle.append(10)
        secondMiddle.append(10)
        let unprovenSecondName = "rollout-copy-\(unprovenID).jsonl"
        let unprovenFirstName = "rollout-primary-\(unprovenID).jsonl"
        try writeSession(in: unprovenDuplicateRoot, uuid: unprovenID,
            events: [tokenEvent(at: now, input: 8, output: 9)], modified: now,
            prefix: firstMiddle)
        try FileManager.default.moveItem(at: sessionURL(in: unprovenDuplicateRoot, uuid: unprovenID),
            to: unprovenDuplicateRoot.appendingPathComponent(unprovenFirstName))
        try writeSession(in: unprovenDuplicateRoot, uuid: unprovenID.uppercased(),
            events: [tokenEvent(at: now, input: 8, output: 9)], modified: now,
            prefix: secondMiddle, metadataID: unprovenID)
        try FileManager.default.moveItem(at: sessionURL(in: unprovenDuplicateRoot, uuid: unprovenID.uppercased()),
            to: unprovenDuplicateRoot.appendingPathComponent(unprovenSecondName))
        let unprovenDuplicate = try LocalCodexUsageReader.scan(directory: unprovenDuplicateRoot, now: now)
        check(unprovenDuplicate.knownThreadCount == 0 && unprovenDuplicate.unknownThreadCount == 1,
            "matching bounded head and tail cannot prove whole-file identity when middle bytes differ")
        try? FileManager.default.removeItem(at: unprovenDuplicateRoot.deletingLastPathComponent())

        let identityRoot = try fixtureDirectory("metadata-identity-and-classification")
        let identities = [
            ("15151515-1515-4515-8515-151515151515", "cli" as Any?),
            ("16161616-1616-4616-8616-161616161616", "vscode" as Any?),
            ("17171717-1717-4717-8717-171717171717", "exec" as Any?),
            ("18181818-1818-4818-8818-181818181818", "mcp" as Any?)
        ]
        for item in identities {
            try writeSession(in: identityRoot, uuid: item.0,
                events: [tokenEvent(at: now, input: 1, output: 2)], modified: now,
                metadataSource: item.1)
        }
        let laterAncestorID = "19191919-1919-4919-8919-191919191919"
        let childID = "20202020-2020-4020-8020-202020202020"
        let ancestorMeta = sessionMetadata(id: laterAncestorID, source: "cli")
        try writeSession(in: identityRoot, uuid: "21212121-2121-4121-8121-212121212121",
            events: [ancestorMeta, tokenEvent(at: now, input: 3, output: 4)], modified: now,
            metadataID: childID, metadataSource: ["subagent": "review"],
            metadataFields: ["parent_thread_id": firstID])
        let unidentifiedMetadata = try fixtureDirectory("metadata-unidentified-files")
        try writeSession(in: unidentifiedMetadata, uuid: "22222222-2222-4222-8222-222222222222",
            events: [tokenEvent(at: now, input: 9, output: 9)], modified: now,
            metadata: sessionMetadata(id: nil, source: "cli"))
        try writeSession(in: unidentifiedMetadata, uuid: "23232323-2323-4323-8323-232323232323",
            events: [tokenEvent(at: now, input: 8, output: 8)], modified: now,
            metadata: tokenEvent(at: now, input: 0, output: 0))
        try writeSession(in: unidentifiedMetadata, uuid: "24242424-2424-4424-8424-242424242424",
            events: [tokenEvent(at: now, input: 7, output: 7)], modified: now,
            metadataID: "not-a-uuid", metadataSource: "cli")
        try writeSession(in: unidentifiedMetadata, uuid: "25252525-2525-4525-8525-252525252525",
            events: [tokenEvent(at: now, input: 6, output: 6)], modified: now,
            metadataSource: "futureSource")
        try writeSession(in: unidentifiedMetadata, uuid: "26262626-2626-4626-8626-262626262626",
            events: [tokenEvent(at: now, input: 5, output: 5)], modified: now, metadataSource: nil)
        try writeSession(in: unidentifiedMetadata, uuid: "27272727-2727-4727-8727-272727272727",
            events: [tokenEvent(at: now, input: 4, output: 4)], modified: now,
            metadataSource: ["custom": ["name": "fixture"]])
        try writeSession(in: unidentifiedMetadata, uuid: "28282828-2828-4828-8828-282828282828",
            events: [tokenEvent(at: now, input: 3, output: 3)], modified: now,
            metadataSource: ["internal": "fixture"])
        try writeSession(in: unidentifiedMetadata, uuid: "29292929-2929-4929-8929-292929292929",
            events: [tokenEvent(at: now, input: 2, output: 2)], modified: now,
            metadataSource: ["subagent": "unsupported_kind"])
        let classified = try LocalCodexUsageReader.scan(directory: identityRoot, now: now)
        let unclassified = try LocalCodexUsageReader.scan(directory: unidentifiedMetadata, now: now)
        check(classified.knownThreadCount == 4 && classified.subagentCount == 1
            && classified.sessionCount == 4 && classified.input == 4 && classified.output == 8
            && classified.unknownThreadCount == 1,
            "recognized child source without a provable fork baseline remains unknown while first metadata identity is retained")
        check(unclassified.knownThreadCount == 0 && unclassified.unknownThreadCount == 5
            && unclassified.unidentifiedFileCount == 3
            && unclassified.sessionCount == 0 && !unclassified.hasCompleteAccounting,
            "missing, invalid, non-first, and unknown-source metadata never falls back to filename identity or root classification")
        let optionalSubagentRoot = try fixtureDirectory("subagent-optional-display-metadata")
        let optionalSubagentID = "2d2d2d2d-2d2d-4d2d-8d2d-2d2d2d2d2d2d"
        try writeSession(in: optionalSubagentRoot, uuid: optionalSubagentID,
            events: [tokenEvent(at: now, input: 4, output: 5)], modified: now,
            metadataID: optionalSubagentID, metadataSource: ["subagent": "review"],
            metadataFields: ["agent_nickname": "Synthetic Reviewer", "agent_role": "review"])
        let optionalSubagent = try LocalCodexUsageReader.scan(directory: optionalSubagentRoot, now: now)
        check(optionalSubagent.knownThreadCount == 0 && optionalSubagent.unknownThreadCount == 1
            && optionalSubagent.subagentCount == 1 && optionalSubagent.sessionCount == 0
            && optionalSubagent.input == 0 && optionalSubagent.output == 0,
            "recognized child classification with optional display metadata remains a subagent while missing lineage baseline is unknown")
        try? FileManager.default.removeItem(at: optionalSubagentRoot.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: identityRoot.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: unidentifiedMetadata.deletingLastPathComponent())

        let strictSourceCases: [(String, Any)] = [
            ("uppercase root source", "CLI"),
            ("subagent-like root string", "subagent_review"),
            ("internal-like root string", "internal_guardian"),
            ("object root source", ["cli": true]),
            ("invalid nested parent UUID", ["subagent": ["thread_spawn": ["parent_thread_id": "badUUID", "depth": 1]]]),
            ("boolean nested depth", ["subagent": ["thread_spawn": ["parent_thread_id": firstID, "depth": true]]]),
            ("overflow nested depth", ["subagent": ["thread_spawn": ["parent_thread_id": firstID, "depth": 2_147_483_648]]]),
            ("uint64 maximum nested depth", ["subagent": ["thread_spawn": ["parent_thread_id": firstID, "depth": NSNumber(value: UInt64.max)]]])
        ]
        for (index, testCase) in strictSourceCases.enumerated() {
            let strictSourceRoot = try fixtureDirectory("strict-source-\(index)")
            let id = String(format: "2c2c2c2c-2c2c-4c2c-8c2c-%012d", index + 1)
            try writeSession(in: strictSourceRoot, uuid: id,
                events: [tokenEvent(at: now, input: 4, output: 5)], modified: now,
                metadataID: id, metadataSource: testCase.1)
            let strictSource = try LocalCodexUsageReader.scan(directory: strictSourceRoot, now: now)
            check(strictSource.knownThreadCount == 0 && strictSource.unknownThreadCount == 1
                && strictSource.sessionCount == 0 && strictSource.subagentCount == 0,
                "strict metadata source rejects \(testCase.0) instead of classifying a root")
            try? FileManager.default.removeItem(at: strictSourceRoot.deletingLastPathComponent())
        }

        let lateMetadataRoot = try fixtureDirectory("metadata-after-head-limit")
        let lateMetadataRecord = sessionMetadata(id: "2a2a2a2a-2a2a-4a2a-8a2a-2a2a2a2a2a2a", source: "cli")
        var firstCompleteRecord = Data("{\"type\":\"unrelated\",\"padding\":\"".utf8)
        firstCompleteRecord.append(Data(repeating: 0x61, count: 70 * 1024))
        firstCompleteRecord.append(Data("\"}\n".utf8))
        var oversizedMetadata = lateMetadataRecord
        oversizedMetadata.append(10)
        firstCompleteRecord.append(oversizedMetadata)
        try writeSession(in: lateMetadataRoot, uuid: "2a2a2a2a-2a2a-4a2a-8a2a-2a2a2a2a2a2a",
            events: [tokenEvent(at: now, input: 1, output: 1)], modified: now,
            metadata: firstCompleteRecord)
        let lateMetadataSnapshot = try LocalCodexUsageReader.scan(directory: lateMetadataRoot, now: now)
        check(lateMetadataSnapshot.unidentifiedFileCount == 1 && lateMetadataSnapshot.knownThreadCount == 0,
            "first metadata outside the bounded head cannot establish identity by later search")
        try? FileManager.default.removeItem(at: lateMetadataRoot.deletingLastPathComponent())

        for (label, firstRecord) in [("blank", Data(" \n".utf8)),
                                     ("non-meta", try tokenEvent(at: now, input: 0, output: 0))] {
            let firstRecordRoot = try fixtureDirectory("first-record-\(label)")
            try writeSession(in: firstRecordRoot, uuid: "2b2b2b2b-2b2b-4b2b-8b2b-2b2b2b2b2b2b",
                events: [tokenEvent(at: now, input: 1, output: 1)], modified: now,
                metadata: firstRecord)
            let firstRecordSnapshot = try LocalCodexUsageReader.scan(directory: firstRecordRoot, now: now)
            check(firstRecordSnapshot.unidentifiedFileCount == 1 && firstRecordSnapshot.knownThreadCount == 0,
                "\(label) first complete physical record is not skipped to recover a later metadata identity")
            try? FileManager.default.removeItem(at: firstRecordRoot.deletingLastPathComponent())
        }

        let forkRoot = try fixtureDirectory("fork-explicit-boundary")
        let parentID = "30303030-3030-4030-8030-303030303030"
        let forkID = "31313131-3131-4131-8131-313131313131"
        try writeSession(in: forkRoot, uuid: parentID,
            events: [tokenEvent(at: now.addingTimeInterval(-5), input: 100, output: 50)], modified: now,
            metadataSource: "cli")
        let spawnSource: [String: Any] = ["subagent": ["thread_spawn": ["parent_thread_id": parentID, "depth": 1]]]
        try writeSession(in: forkRoot, uuid: forkID, events: [
            tokenEvent(at: now.addingTimeInterval(-4), input: 100, output: 50), // ordinal 1: inherited
            ordinaryEvent(at: now.addingTimeInterval(-3), type: "user_message"), // ordinal 2
            tokenEvent(at: now.addingTimeInterval(-2), input: 110, output: 55), // ordinal 3: exclusive boundary is first own record
            tokenEvent(at: now.addingTimeInterval(-1), input: 120, output: 60), // ordinal 4: child continues
            sessionMetadata(id: parentID, source: "cli"), // copied ancestor must not replace ordinal-0 child identity
            tokenEvent(at: now, input: 130, output: 65)
        ], modified: now, metadataID: forkID, metadataSource: spawnSource,
            metadataFields: ["parent_thread_id": parentID, "subagent_history_start_ordinal": 3])
        let forked = try LocalCodexUsageReader.scan(directory: forkRoot, now: now)
        check(forked.input == 130 && forked.output == 65 && forked.total == 195
            && forked.knownThreadCount == 2 && forked.subagentCount == 1 && forked.forkCount == 1
            && forked.sessionCount == 1 && forked.hasCompleteAccounting,
            "parent plus explicit copied-fork delta excludes inherited baseline once and preserves first metadata identity")
        try? FileManager.default.removeItem(at: forkRoot.deletingLastPathComponent())

        let settingsForkRoot = try fixtureDirectory("fork-thread-settings-boundary")
        let settingsForkID = "32323232-3232-4232-8232-323232323232"
        let settingsBoundary = try threadSettingsApplied(at: now.addingTimeInterval(-2), threadID: settingsForkID)
        try writeSession(in: settingsForkRoot, uuid: settingsForkID, events: [
            tokenEvent(at: now.addingTimeInterval(-3), input: 40, output: 20), // baseline before boundary
            settingsBoundary, // own thread boundary
            tokenEvent(at: now.addingTimeInterval(-1), input: 55, output: 30),
            tokenEvent(at: now, input: 60, output: 32)
        ], modified: now, metadataID: settingsForkID, metadataSource: spawnSource,
            metadataFields: ["parent_thread_id": parentID])
        let settingsFork = try LocalCodexUsageReader.scan(directory: settingsForkRoot, now: now)
        check(settingsFork.input == 20 && settingsFork.output == 12 && settingsFork.total == 32
            && settingsFork.knownThreadCount == 1 && settingsFork.subagentCount == 1
            && settingsFork.forkCount == 1 && settingsFork.sessionCount == 0,
            "thread_settings_applied boundary matches current thread and counts only post-baseline delta")
        try? FileManager.default.removeItem(at: settingsForkRoot.deletingLastPathComponent())

        let quotaOnlyForkRoot = try fixtureDirectory("fork-quota-only-token-event")
        let quotaOnlyForkID = "32323232-3232-4232-8232-323232323233"
        let forkQuotaLimits: [String: Any] = ["primary": ["used_percent": 45, "window_minutes": 300]]
        try writeSession(in: quotaOnlyForkRoot, uuid: quotaOnlyForkID, events: [
            tokenEvent(at: now.addingTimeInterval(-4), input: 100, output: 50),
            ordinaryEvent(at: now.addingTimeInterval(-3), type: "user_message"),
            tokenEvent(at: now.addingTimeInterval(-2), input: 110, output: 55),
            quotaOnlyEvent(at: now.addingTimeInterval(-1), rateLimits: forkQuotaLimits),
            tokenEvent(at: now, input: 120, output: 60)
        ], modified: now, metadataID: quotaOnlyForkID, metadataSource: "cli",
            metadataFields: ["parent_thread_id": parentID, "subagent_history_start_ordinal": 2])
        let quotaOnlyFork = try LocalCodexUsageReader.scan(directory: quotaOnlyForkRoot, now: now)
        check(quotaOnlyFork.input == 20 && quotaOnlyFork.output == 10 && quotaOnlyFork.total == 30
            && quotaOnlyFork.knownThreadCount == 1 && quotaOnlyFork.unknownThreadCount == 0
            && quotaOnlyFork.forkCount == 1 && quotaOnlyFork.sessionCount == 0
            && quotaOnlyFork.fiveHour?.usedPercent == 45,
            "quota-only token_count between cumulative fork counters does not poison the child delta")
        try? FileManager.default.removeItem(at: quotaOnlyForkRoot.deletingLastPathComponent())

        let resumeSettingsRoot = try fixtureDirectory("fork-resume-settings")
        let resumeID = "33333333-3333-4333-8333-333333333334"
        try writeSession(in: resumeSettingsRoot, uuid: resumeID, events: [
            tokenEvent(at: now.addingTimeInterval(-4), input: 40, output: 20),
            threadSettingsApplied(at: now.addingTimeInterval(-3), threadID: resumeID),
            tokenEvent(at: now.addingTimeInterval(-2), input: 55, output: 30),
            threadSettingsApplied(at: now.addingTimeInterval(-1), threadID: resumeID), // resume is not a new boundary
            tokenEvent(at: now, input: 60, output: 32)
        ], modified: now, metadataID: resumeID, metadataSource: spawnSource,
            metadataFields: ["parent_thread_id": parentID])
        let resumedSettingsFork = try LocalCodexUsageReader.scan(directory: resumeSettingsRoot, now: now)
        check(resumedSettingsFork.input == 20 && resumedSettingsFork.output == 12
            && resumedSettingsFork.knownThreadCount == 1 && resumedSettingsFork.unknownThreadCount == 0,
            "later matching resume settings do not invalidate the first own initialization boundary")
        try? FileManager.default.removeItem(at: resumeSettingsRoot.deletingLastPathComponent())

        let wrongSettingsRoot = try fixtureDirectory("fork-wrong-settings-thread")
        let wrongSettingsID = "33333333-3333-4333-8333-333333333335"
        try writeSession(in: wrongSettingsRoot, uuid: wrongSettingsID, events: [
            tokenEvent(at: now.addingTimeInterval(-3), input: 40, output: 20),
            threadSettingsApplied(at: now.addingTimeInterval(-2), threadID: parentID),
            tokenEvent(at: now.addingTimeInterval(-1), input: 55, output: 30),
            threadSettingsApplied(at: now, threadID: wrongSettingsID),
            tokenEvent(at: now.addingTimeInterval(1), input: 60, output: 32)
        ], modified: now, metadataID: wrongSettingsID, metadataSource: spawnSource,
            metadataFields: ["parent_thread_id": parentID])
        let wrongSettingsFork = try LocalCodexUsageReader.scan(directory: wrongSettingsRoot, now: now)
        check(wrongSettingsFork.input == 5 && wrongSettingsFork.output == 2
            && wrongSettingsFork.knownThreadCount == 1,
            "thread settings for another thread are ignored and preceding cumulative usage remains the baseline")
        try? FileManager.default.removeItem(at: wrongSettingsRoot.deletingLastPathComponent())

        let contradictoryBoundaryRoot = try fixtureDirectory("fork-contradictory-boundary")
        let contradictoryID = "33333333-3333-4333-8333-333333333336"
        try writeSession(in: contradictoryBoundaryRoot, uuid: contradictoryID, events: [
            tokenEvent(at: now.addingTimeInterval(-3), input: 40, output: 20),
            threadSettingsApplied(at: now.addingTimeInterval(-2), threadID: contradictoryID),
            tokenEvent(at: now.addingTimeInterval(-1), input: 55, output: 30),
            tokenEvent(at: now, input: 60, output: 32)
        ], modified: now, metadataID: contradictoryID, metadataSource: spawnSource,
            metadataFields: ["parent_thread_id": parentID, "subagent_history_start_ordinal": 3])
        let contradictoryBoundary = try LocalCodexUsageReader.scan(directory: contradictoryBoundaryRoot, now: now)
        check(contradictoryBoundary.knownThreadCount == 0 && contradictoryBoundary.unknownThreadCount == 1,
            "explicit ordinal and first matching own settings boundary disagreement makes the fork unknown")
        try? FileManager.default.removeItem(at: contradictoryBoundaryRoot.deletingLastPathComponent())

        let gapForkRoot = try fixtureDirectory("fork-unobserved-middle-gap")
        let gapForkID = "34343434-3434-4434-8434-343434343434"
        var gapPrefix = Data()
        gapPrefix.append(try ordinaryEvent(at: now.addingTimeInterval(-10), type: "user_message")) // ordinal 1
        gapPrefix.append(10)
        gapPrefix.append(try tokenEvent(at: now.addingTimeInterval(-9), input: 100, output: 50)) // ordinal 2 baseline
        gapPrefix.append(10)
        gapPrefix.append(try tokenEvent(at: now.addingTimeInterval(-8.5), input: 101, output: 51)) // ordinal 3 first own record
        gapPrefix.append(10)
        for index in 0..<5_000 {
            gapPrefix.append(try tokenEvent(at: now.addingTimeInterval(-8 + Double(index) / 10_000),
                input: 102 + index, output: 52 + index))
            gapPrefix.append(10)
        }
        try writeSession(in: gapForkRoot, uuid: gapForkID,
            events: [tokenEvent(at: now, input: 5_101, output: 5_051)], modified: now,
            prefix: gapPrefix, metadataID: gapForkID, metadataSource: spawnSource,
            metadataFields: ["parent_thread_id": parentID, "subagent_history_start_ordinal": 3])
        let gapFork = try LocalCodexUsageReader.scan(directory: gapForkRoot, now: now)
        check(gapFork.knownThreadCount == 0 && gapFork.unknownThreadCount == 1
            && gapFork.isLimited && !gapFork.hasCompleteAccounting,
            "fork contribution is unknown when bounded head/tail reads leave an unobserved cumulative gap")
        try? FileManager.default.removeItem(at: gapForkRoot.deletingLastPathComponent())

        let invalidForkEvidence: [(String, [Data])] = try [
            ("missing", [ordinaryEvent(at: now.addingTimeInterval(-2), type: "user_message"),
                ordinaryEvent(at: now.addingTimeInterval(-1), type: "assistant_reasoning"),
                tokenEvent(at: now, input: 55, output: 65)]),
            ("input rollback", [tokenEvent(at: now.addingTimeInterval(-3), input: 40, output: 20),
                tokenEvent(at: now.addingTimeInterval(-1), input: 39, output: 21),
                tokenEvent(at: now, input: 45, output: 25)]),
            ("output rollback", [tokenEvent(at: now.addingTimeInterval(-3), input: 40, output: 20),
                tokenEvent(at: now.addingTimeInterval(-1), input: 41, output: 19),
                tokenEvent(at: now, input: 45, output: 25)]),
            ("input missing", [tokenEvent(at: now.addingTimeInterval(-3), input: 40, output: 20),
                rawTokenEvent(at: now.addingTimeInterval(-1), inputLiteral: "null", outputLiteral: "21", totalLiteral: "42"),
                tokenEvent(at: now, input: 45, output: 25)]),
            ("output missing", [tokenEvent(at: now.addingTimeInterval(-3), input: 40, output: 20),
                rawTokenEvent(at: now.addingTimeInterval(-1), inputLiteral: "41", outputLiteral: "null", totalLiteral: "42"),
                tokenEvent(at: now, input: 45, output: 25)]),
            ("total missing", [tokenEvent(at: now.addingTimeInterval(-3), input: 40, output: 20),
                rawTokenEvent(at: now.addingTimeInterval(-1), inputLiteral: "41", outputLiteral: "21", totalLiteral: "null"),
                tokenEvent(at: now, input: 45, output: 25)]),
            ("total rollback", [tokenEvent(at: now.addingTimeInterval(-3), input: 40, output: 20),
                rawTokenEvent(at: now.addingTimeInterval(-1), inputLiteral: "41", outputLiteral: "21", totalLiteral: "1"),
                tokenEvent(at: now, input: 45, output: 25)])
        ]
        for (label, records) in invalidForkEvidence {
            let missingBaselineRoot = try fixtureDirectory("fork-invalid-baseline-\(label)")
            let missingBaselineID = "35353535-3535-4535-8535-353535353535"
            try writeSession(in: missingBaselineRoot, uuid: missingBaselineID, events: records, modified: now,
                metadataID: missingBaselineID, metadataSource: spawnSource,
                metadataFields: ["parent_thread_id": parentID, "subagent_history_start_ordinal": 3])
            let missingBaseline = try LocalCodexUsageReader.scan(directory: missingBaselineRoot, now: now)
            check(missingBaseline.knownThreadCount == 0 && missingBaseline.unknownThreadCount == 1
                && missingBaseline.input == 0,
                "fork with \(label) baseline evidence is unknown, not a guessed contribution")
            try? FileManager.default.removeItem(at: missingBaselineRoot.deletingLastPathComponent())
        }

        let quotaUpdateRoot = try fixtureDirectory("quota-update-contract")
        let quotaTime = now.addingTimeInterval(-30)
        let validLimits: [String: Any] = [
            "primary": ["used_percent": 25, "window_minutes": 300, "resets_at": Int(now.timeIntervalSince1970) + 3600],
            "secondary": ["used_percent": 70, "window_minutes": 10080, "resets_at": Int(now.timeIntervalSince1970) + 7200]
        ]
        let duplicateDurations: [String: Any] = [
            "primary": ["used_percent": 10, "window_minutes": 300],
            "secondary": ["used_percent": 90, "window_minutes": 300]
        ]
        try writeSession(in: quotaUpdateRoot, uuid: "36363636-3636-4636-8636-363636363636", events: [
            tokenEvent(at: quotaTime, input: 1, output: 1, rateLimits: validLimits)
        ], modified: now)
        func appendQuotaFixture(_ suffix: Int, _ timestamp: Date, _ value: Any?) throws -> LocalCodexSnapshot {
            let uuid = String(format: "37373737-3737-4737-8737-%012d", suffix)
            try writeSession(in: quotaUpdateRoot, uuid: uuid, events: [
                tokenEvent(at: timestamp, input: suffix, output: suffix, rateLimits: value)
            ], modified: now, metadataID: uuid)
            return try LocalCodexUsageReader.scan(directory: quotaUpdateRoot, now: now)
        }
        let preservedCases: [(String, Any?)] = [
            ("missing", nil), ("null", NSNull()), ("non-object", "not-an-object"),
            ("unrelated", ["other": ["used_percent": 99]]),
            ("boolean percent", ["primary": ["used_percent": true, "window_minutes": 300]]),
            ("out-of-range percent", ["primary": ["used_percent": 101, "window_minutes": 300]]),
            ("boolean duration", ["primary": ["used_percent": 40, "window_minutes": true]]),
            ("duplicate duration", duplicateDurations),
            ("negative reset", ["primary": ["used_percent": 40, "window_minutes": 300, "resets_at": -1]]),
            ("fractional reset", ["primary": ["used_percent": 40, "window_minutes": 300, "resets_at": 1.5]]),
            ("null slot", ["primary": NSNull(), "secondary": NSNull()]),
            ("non-object slot", ["primary": "invalid"]),
            ("missing used percent", ["primary": ["window_minutes": 300]])
        ]
        var quotaCheckIndex = 0
        for (label, value) in preservedCases {
            if label == "null slot" {
                quotaCheckIndex += 1
                let clearID = String(format: "37373737-3737-4737-8737-%012d", quotaCheckIndex)
                try writeSession(in: quotaUpdateRoot, uuid: clearID, events: [
                    tokenEvent(at: quotaTime.addingTimeInterval(Double(quotaCheckIndex)), input: 1, output: 1,
                        rateLimits: [:])
                ], modified: now, metadataID: clearID)
                let cleared = try LocalCodexUsageReader.scan(directory: quotaUpdateRoot, now: now)
                check(cleared.fiveHour == nil && cleared.sevenDay == nil,
                    "valid empty object clears quota before nullable-window case")
                quotaCheckIndex += 1
                let restoreID = String(format: "37373737-3737-4737-8737-%012d", quotaCheckIndex)
                try writeSession(in: quotaUpdateRoot, uuid: restoreID, events: [
                    tokenEvent(at: quotaTime.addingTimeInterval(Double(quotaCheckIndex)), input: 1, output: 1,
                        rateLimits: validLimits)
                ], modified: now, metadataID: restoreID)
                quotaCheckIndex += 1
                let nullSlotsID = String(format: "37373737-3737-4737-8737-%012d", quotaCheckIndex)
                try writeSession(in: quotaUpdateRoot, uuid: nullSlotsID, events: [
                    tokenEvent(at: quotaTime.addingTimeInterval(Double(quotaCheckIndex)), input: 1, output: 1,
                        rateLimits: ["primary": NSNull(), "secondary": NSNull()])
                ], modified: now, metadataID: nullSlotsID)
                let nullSlots = try LocalCodexUsageReader.scan(directory: quotaUpdateRoot, now: now)
                check(nullSlots.fiveHour == nil && nullSlots.sevenDay == nil,
                    "valid null windows replace the prior snapshot with an empty snapshot")
                quotaCheckIndex += 1
                let nullRestoreID = String(format: "37373737-3737-4737-8737-%012d", quotaCheckIndex)
                try writeSession(in: quotaUpdateRoot, uuid: nullRestoreID, events: [
                    tokenEvent(at: quotaTime.addingTimeInterval(Double(quotaCheckIndex)), input: 1, output: 1,
                        rateLimits: validLimits)
                ], modified: now, metadataID: nullRestoreID)
                quotaCheckIndex += 1
                continue
            }
            quotaCheckIndex += 1
            let before = try LocalCodexUsageReader.scan(directory: quotaUpdateRoot, now: now)
            check(before.fiveHour?.usedPercent == 25 && before.sevenDay?.usedPercent == 70,
                "known quota snapshot restored before \(label) case")
            let snapshot = try appendQuotaFixture(quotaCheckIndex,
                quotaTime.addingTimeInterval(Double(quotaCheckIndex)), value)
            check(snapshot.fiveHour?.usedPercent == 25 && snapshot.sevenDay?.usedPercent == 70,
                "\(label) quota update preserves previous valid snapshot")
        }
        quotaCheckIndex += 1
        let replacementTime = quotaTime.addingTimeInterval(Double(quotaCheckIndex))
        let replacementFixture = String(format: "37373737-3737-4737-8737-%012d", quotaCheckIndex)
        try writeSession(in: quotaUpdateRoot, uuid: replacementFixture, events: [
            tokenEvent(at: replacementTime, input: 8, output: 8,
                rateLimits: ["primary": ["used_percent": 35, "window_minutes": 300, "resets_at": NSNull()]])
        ], modified: now, metadataID: replacementFixture)
        let wholeReplacement = try LocalCodexUsageReader.scan(directory: quotaUpdateRoot, now: now)
        check(wholeReplacement.fiveHour?.usedPercent == 35 && wholeReplacement.fiveHour?.resetsAt == nil
            && wholeReplacement.sevenDay == nil,
            "valid partial quota object replaces its sibling instead of merging windows across events")
        quotaCheckIndex += 1
        let unsupportedTime = quotaTime.addingTimeInterval(Double(quotaCheckIndex))
        let unsupportedFixture = String(format: "37373737-3737-4737-8737-%012d", quotaCheckIndex)
        try writeSession(in: quotaUpdateRoot, uuid: unsupportedFixture, events: [
            tokenEvent(at: unsupportedTime, input: 9, output: 9,
                rateLimits: ["primary": ["used_percent": 45]])
        ], modified: now, metadataID: unsupportedFixture)
        let unsupportedDuration = try LocalCodexUsageReader.scan(directory: quotaUpdateRoot, now: now)
        check(unsupportedDuration.fiveHour == nil && unsupportedDuration.sevenDay == nil,
            "valid window lacking optional duration replaces snapshot but cannot map to a supported bucket")
        quotaCheckIndex += 1
        let epochTime = quotaTime.addingTimeInterval(Double(quotaCheckIndex))
        let epochFixture = String(format: "37373737-3737-4737-8737-%012d", quotaCheckIndex)
        try writeSession(in: quotaUpdateRoot, uuid: epochFixture, events: [
            tokenEvent(at: epochTime, input: 10, output: 10,
                rateLimits: ["primary": ["used_percent": 45, "window_minutes": 300, "resets_at": 0]])
        ], modified: now, metadataID: epochFixture)
        let epochReset = try LocalCodexUsageReader.scan(directory: quotaUpdateRoot, now: now)
        check(epochReset.fiveHour?.resetsAt == Date(timeIntervalSince1970: 0)
            && epochReset.fiveHour?.isFresh(at: now, refreshSeconds: 60) == false,
            "nonnegative integer epoch reset is retained as historical time, not current quota")
        quotaCheckIndex += 1
        let clearTime = quotaTime.addingTimeInterval(Double(quotaCheckIndex))
        let clearFixture = String(format: "37373737-3737-4737-8737-%012d", quotaCheckIndex)
        try writeSession(in: quotaUpdateRoot, uuid: clearFixture, events: [
            tokenEvent(at: clearTime, input: 11, output: 11, rateLimits: [:])
        ], modified: now, metadataID: clearFixture)
        let explicitlyCleared = try LocalCodexUsageReader.scan(directory: quotaUpdateRoot, now: now)
        check(explicitlyCleared.fiveHour == nil && explicitlyCleared.sevenDay == nil,
            "explicit valid empty quota object clears prior snapshot")
        try? FileManager.default.removeItem(at: quotaUpdateRoot.deletingLastPathComponent())

        let quotaOnlyRoot = try fixtureDirectory("quota-only-event-does-not-clear-usage")
        let quotaOnlyID = "40404040-4040-4040-8040-404040404041"
        try writeSession(in: quotaOnlyRoot, uuid: quotaOnlyID, events: [
            tokenEvent(at: now.addingTimeInterval(-1), input: 20, output: 10),
            quotaOnlyEvent(at: now, rateLimits: validLimits)
        ], modified: now)
        let quotaOnly = try LocalCodexUsageReader.scan(directory: quotaOnlyRoot, now: now)
        check(quotaOnly.input == 20 && quotaOnly.output == 10 && quotaOnly.total == 30
            && quotaOnly.knownThreadCount == 1 && quotaOnly.unknownThreadCount == 0
            && quotaOnly.fiveHour?.usedPercent == 25 && quotaOnly.sevenDay?.usedPercent == 70,
            "quota update without cumulative usage preserves the thread's last valid token counters")
        try? FileManager.default.removeItem(at: quotaOnlyRoot.deletingLastPathComponent())

        let unknownSourceForkRoot = try fixtureDirectory("unknown-source-fork-not-root")
        let unknownSourceForkID = "40404040-4040-4040-8040-404040404042"
        try writeSession(in: unknownSourceForkRoot, uuid: unknownSourceForkID, events: [
            tokenEvent(at: now.addingTimeInterval(-2), input: 10, output: 5),
            ordinaryEvent(at: now.addingTimeInterval(-1), type: "user_message"),
            tokenEvent(at: now, input: 12, output: 6)
        ], modified: now, metadataID: unknownSourceForkID, metadataSource: nil,
            metadataFields: ["parent_thread_id": parentID, "subagent_history_start_ordinal": 2])
        let unknownSourceFork = try LocalCodexUsageReader.scan(directory: unknownSourceForkRoot, now: now)
        check(unknownSourceFork.knownThreadCount == 0 && unknownSourceFork.unknownThreadCount == 1
            && unknownSourceFork.sessionCount == 0 && unknownSourceFork.subagentCount == 0
            && unknownSourceFork.input == 0,
            "unknown source with otherwise valid fork baseline remains unknown and cannot become a root")
        try? FileManager.default.removeItem(at: unknownSourceForkRoot.deletingLastPathComponent())

        let cliDisplayRoot = try fixtureDirectory("cli-display-metadata-not-subagent")
        let cliDisplayID = "40404040-4040-4040-8040-404040404043"
        try writeSession(in: cliDisplayRoot, uuid: cliDisplayID,
            events: [tokenEvent(at: now, input: 3, output: 4)], modified: now,
            metadataID: cliDisplayID, metadataSource: "cli",
            metadataFields: ["agent_nickname": "Synthetic CLI", "agent_role": "review", "thread_source": "user"])
        let cliDisplay = try LocalCodexUsageReader.scan(directory: cliDisplayRoot, now: now)
        check(cliDisplay.knownThreadCount == 0 && cliDisplay.unknownThreadCount == 1
            && cliDisplay.sessionCount == 0 && cliDisplay.subagentCount == 0
            && cliDisplay.input == 0 && cliDisplay.output == 0,
            "CLI source with child display metadata is unknown rather than a trusted root or a subagent")
        try? FileManager.default.removeItem(at: cliDisplayRoot.deletingLastPathComponent())

        let nonUserChildRoot = try fixtureDirectory("subagent-nonuser-thread-source")
        let nonUserChildID = "40404040-4040-4040-8040-404040404044"
        try writeSession(in: nonUserChildRoot, uuid: nonUserChildID,
            events: [tokenEvent(at: now, input: 6, output: 4)], modified: now,
            metadataID: nonUserChildID, metadataSource: ["subagent": "review"],
            metadataFields: ["thread_source": "automation", "agent_role": "review"])
        let nonUserChild = try LocalCodexUsageReader.scan(directory: nonUserChildRoot, now: now)
        check(nonUserChild.knownThreadCount == 0 && nonUserChild.unknownThreadCount == 1
            && nonUserChild.sessionCount == 0 && nonUserChild.subagentCount == 1
            && nonUserChild.input == 0 && nonUserChild.output == 0,
            "recognized subagent source with non-user thread_source remains classified as child while missing baseline is unknown")
        try? FileManager.default.removeItem(at: nonUserChildRoot.deletingLastPathComponent())

        for (label, historyBase) in [
            ("integer", 123 as Any), ("object", ["ordinal": 5] as Any),
            ("schema-valid reference", ["thread_id": parentID, "end_ordinal_exclusive": 4,
                                        "end_byte_offset": 1024] as Any)
        ] {
            let unknownLineageRoot = try fixtureDirectory("unknown-parent-lineage-\(label)")
            try writeSession(in: unknownLineageRoot, uuid: "33333333-3333-4333-8333-333333333333",
                events: [tokenEvent(at: now, input: 55, output: 66)], modified: now,
                metadataFields: ["history_base": historyBase])
            let unknownLineage = try LocalCodexUsageReader.scan(directory: unknownLineageRoot, now: now)
            check(unknownLineage.knownThreadCount == 0 && unknownLineage.unknownThreadCount == 1
                && unknownLineage.input == 0 && !unknownLineage.hasCompleteAccounting,
                "Referenced/history_base \(label) lineage is unknown without cross-file subtraction")
            try? FileManager.default.removeItem(at: unknownLineageRoot.deletingLastPathComponent())
        }

        let referencedSubagentRoot = try fixtureDirectory("referenced-history-classifies-child")
        let referencedSubagentID = "33333333-3333-4333-8333-333333333339"
        try writeSession(in: referencedSubagentRoot, uuid: referencedSubagentID,
            events: [tokenEvent(at: now, input: 55, output: 66)], modified: now,
            metadataID: referencedSubagentID, metadataSource: ["subagent": "review"],
            metadataFields: ["history_base": ["thread_id": parentID,
                "end_ordinal_exclusive": 4, "end_byte_offset": 1024]])
        let referencedSubagent = try LocalCodexUsageReader.scan(directory: referencedSubagentRoot, now: now)
        check(referencedSubagent.knownThreadCount == 0 && referencedSubagent.unknownThreadCount == 1
            && referencedSubagent.subagentCount == 1 && referencedSubagent.sessionCount == 0
            && referencedSubagent.input == 0,
            "trusted source plus history_base classifies child while its unsupported contribution remains unknown")
        try? FileManager.default.removeItem(at: referencedSubagentRoot.deletingLastPathComponent())

        let cliForkRoot = try fixtureDirectory("cli-with-fork-marker")
        let cliForkID = "33333333-3333-4333-8333-333333333337"
        try writeSession(in: cliForkRoot, uuid: cliForkID, events: [
            tokenEvent(at: now.addingTimeInterval(-3), input: 100, output: 50), // inherited baseline
            ordinaryEvent(at: now.addingTimeInterval(-2), type: "user_message"), // explicit ordinal 2 boundary
            tokenEvent(at: now.addingTimeInterval(-1), input: 110, output: 55), // first own usage
            tokenEvent(at: now, input: 120, output: 60)
        ], modified: now, metadataID: cliForkID, metadataSource: "cli",
            metadataFields: ["forked_from_id": parentID, "parent_thread_id": parentID,
                             "subagent_history_start_ordinal": 2])
        let cliFork = try LocalCodexUsageReader.scan(directory: cliForkRoot, now: now)
        check(cliFork.input == 20 && cliFork.output == 10 && cliFork.total == 30
            && cliFork.sessionCount == 0 && cliFork.forkCount == 1 && cliFork.knownThreadCount == 1,
            "cli source plus proven parent/fork markers contributes only its delta, never root full cumulative")
        try? FileManager.default.removeItem(at: cliForkRoot.deletingLastPathComponent())

        let cliForkMissingBaselineRoot = try fixtureDirectory("cli-fork-missing-baseline")
        let cliForkMissingID = "33333333-3333-4333-8333-333333333338"
        try writeSession(in: cliForkMissingBaselineRoot, uuid: cliForkMissingID, events: [
            ordinaryEvent(at: now.addingTimeInterval(-2), type: "user_message"),
            tokenEvent(at: now.addingTimeInterval(-1), input: 110, output: 55),
            tokenEvent(at: now, input: 120, output: 60)
        ], modified: now, metadataID: cliForkMissingID, metadataSource: "cli",
            metadataFields: ["forked_from_id": parentID, "parent_thread_id": parentID,
                             "subagent_history_start_ordinal": 2])
        let cliForkMissingBaseline = try LocalCodexUsageReader.scan(directory: cliForkMissingBaselineRoot, now: now)
        check(cliForkMissingBaseline.knownThreadCount == 0 && cliForkMissingBaseline.unknownThreadCount == 1
            && cliForkMissingBaseline.sessionCount == 0 && cliForkMissingBaseline.input == 0,
            "cli source cannot override a valid fork marker when its required baseline is missing")
        try? FileManager.default.removeItem(at: cliForkMissingBaselineRoot.deletingLastPathComponent())

        let illegalLineageRoot = try fixtureDirectory("illegal-lineage-not-root")
        for (index, fields) in [
            ["forked_from_id": "parent"], ["parent_thread_id": "parent"],
            ["subagent": "unknown"], ["subagent_history_start_ordinal": -1]
        ].enumerated() {
            let id = String(format: "33333333-3333-4333-8333-%012d", index + 10)
            try writeSession(in: illegalLineageRoot, uuid: id,
                events: [tokenEvent(at: now, input: 55, output: 66)], modified: now,
                metadataID: id, metadataFields: fields)
        }
        let illegalLineage = try LocalCodexUsageReader.scan(directory: illegalLineageRoot, now: now)
        check(illegalLineage.knownThreadCount == 0 && illegalLineage.unknownThreadCount == 4
            && illegalLineage.sessionCount == 0 && !illegalLineage.hasCompleteAccounting,
            "invalid parent, fork, source, and ordinal markers cannot silently classify as roots")
        try? FileManager.default.removeItem(at: illegalLineageRoot.deletingLastPathComponent())

        let corruptLatestRoot = try fixtureDirectory("root-corrupt-latest-counter")
        let corruptID = "41414141-4141-4141-8141-414141414141"
        try writeSession(in: corruptLatestRoot, uuid: corruptID, events: [
            tokenEvent(at: now.addingTimeInterval(-1), input: 50, output: 60),
            rawTokenEvent(at: now, inputLiteral: "true", outputLiteral: "70")
        ], modified: now)
        let corruptLatest = try LocalCodexUsageReader.scan(directory: corruptLatestRoot, now: now)
        check(corruptLatest.knownThreadCount == 0 && corruptLatest.unknownThreadCount == 1
            && corruptLatest.input == 0 && corruptLatest.output == 0,
            "malformed latest cumulative record makes root contribution unknown instead of reverting")
        try? FileManager.default.removeItem(at: corruptLatestRoot.deletingLastPathComponent())

        let invalidRoot = try fixtureDirectory("invalid-counts")
        let validID = "44444444-4444-4444-8444-444444444444"
        try writeSession(in: invalidRoot, uuid: validID,
            events: [tokenEvent(at: now, input: 5, output: 7)], modified: now)
        let invalidLiterals = ["-1", "1.5", "true", "9223372036854775808", "1e999"]
        for (index, literal) in invalidLiterals.enumerated() {
            let uuid = String(format: "55555555-5555-4555-8555-%012d", index + 1)
            try writeSession(in: invalidRoot, uuid: uuid,
                events: [rawTokenEvent(at: now, inputLiteral: literal, outputLiteral: "1")], modified: now)
        }
        let invalid = try LocalCodexUsageReader.scan(directory: invalidRoot, now: now)
        check(invalid.input == 5 && invalid.output == 7 && invalid.sessionCount == 6
            && invalid.knownThreadCount == 1 && invalid.unknownThreadCount == 5
            && !invalid.hasCompleteAccounting,
            "negative, fractional, boolean, overflowing and non-finite counters are unknown without invalidating known subtotal")
        try? FileManager.default.removeItem(at: invalidRoot.deletingLastPathComponent())

        let exactRoot = try fixtureDirectory("exact-large-integer")
        try writeSession(in: exactRoot, uuid: "14141414-1414-4414-8414-141414141414",
            events: [rawTokenEvent(at: now, inputLiteral: "9007199254740993", outputLiteral: "0")], modified: now)
        let exactLarge = try LocalCodexUsageReader.scan(directory: exactRoot, now: now)
        check(exactLarge.input == 9_007_199_254_740_993,
            "large JSON integer above 2^53 is parsed without floating point rounding")
        try? FileManager.default.removeItem(at: exactRoot.deletingLastPathComponent())

        let truncatedRoot = try fixtureDirectory("truncated-tail")
        let longPrefix = Data(repeating: 0x78, count: 256 * 1024 + 32)
        let complete = try tokenEvent(at: now, input: 12, output: 13)
        var paddedPrefix = longPrefix
        paddedPrefix.append(10)
        try writeSession(in: truncatedRoot, uuid: "66666666-6666-4666-8666-666666666666",
            events: [complete], modified: now, prefix: paddedPrefix, suffix: Data("{\"partial\":".utf8))
        let truncated = try LocalCodexUsageReader.scan(directory: truncatedRoot, now: now)
        check(truncated.knownThreadCount == 0 && truncated.unknownThreadCount == 1
            && truncated.input == 0 && truncated.output == 0 && !truncated.hasCompleteAccounting,
            "a nonempty incomplete final physical record makes the latest thread contribution unknown")
        try? FileManager.default.removeItem(at: truncatedRoot.deletingLastPathComponent())

        let quotaRoot = try fixtureDirectory("quota-snapshots")
        let oldTime = now.addingTimeInterval(-600), latestTime = now.addingTimeInterval(-60)
        try writeSession(in: quotaRoot, uuid: "77777777-7777-4777-8777-777777777777",
            events: [tokenEvent(at: oldTime, input: 1, output: 1,
                rateLimits: rateLimits(fiveHour: 10, sevenDay: 20, reset: now.addingTimeInterval(3600)))],
            modified: now)
        try writeSession(in: quotaRoot, uuid: "88888888-8888-4888-8888-888888888888",
            events: [tokenEvent(at: latestTime, input: 2, output: 2,
                rateLimits: rateLimits(fiveHour: 30, sevenDay: 40, reset: now.addingTimeInterval(7200)))],
            modified: now.addingTimeInterval(-500))
        let quotaSnapshot = try LocalCodexUsageReader.scan(directory: quotaRoot, now: now)
        check(quotaSnapshot.latestEventAt == latestTime && quotaSnapshot.fiveHour?.usedPercent == 30
            && quotaSnapshot.sevenDay?.usedPercent == 40,
            "quota windows come from one latest event timestamp, not file modification order")
        check(quotaSnapshot.fiveHour?.fetchedAt == latestTime && quotaSnapshot.sevenDay?.fetchedAt == latestTime,
            "local quota freshness preserves the source event timestamp")
        try? FileManager.default.removeItem(at: quotaRoot.deletingLastPathComponent())

        let reverseQuotaRoot = try fixtureDirectory("quota-event-timestamps")
        try writeSession(in: reverseQuotaRoot, uuid: "c4c4c4c4-c4c4-4c4c-8c4c-aaaaaaaaaaaa", events: [
            tokenEvent(at: now.addingTimeInterval(-10), input: 1, output: 1,
                rateLimits: rateLimits(fiveHour: 61, sevenDay: 71, reset: now.addingTimeInterval(3600))),
            tokenEvent(at: now.addingTimeInterval(-20), input: 1, output: 1,
                rateLimits: rateLimits(fiveHour: 11, sevenDay: 21, reset: now.addingTimeInterval(3600)))
        ], modified: now)
        let reverseQuota = try LocalCodexUsageReader.scan(directory: reverseQuotaRoot, now: now)
        check(reverseQuota.fiveHour?.usedPercent == 61 && reverseQuota.sevenDay?.usedPercent == 71,
            "older timestamp appearing later in the file cannot replace the newest quota snapshot")
        try? FileManager.default.removeItem(at: reverseQuotaRoot.deletingLastPathComponent())

        let equalQuotaRoot = try fixtureDirectory("quota-equal-timestamp-clear")
        let equalQuotaTime = now.addingTimeInterval(-10)
        try writeSession(in: equalQuotaRoot, uuid: "c6c6c6c6-c6c6-4c6c-8c6c-aaaaaaaaaaaa", events: [
            tokenEvent(at: equalQuotaTime, input: 1, output: 1,
                rateLimits: rateLimits(fiveHour: 61, sevenDay: 71, reset: now.addingTimeInterval(3600))),
            tokenEvent(at: equalQuotaTime, input: 1, output: 1, rateLimits: [:])
        ], modified: now)
        let equalQuota = try LocalCodexUsageReader.scan(directory: equalQuotaRoot, now: now)
        check(equalQuota.fiveHour == nil && equalQuota.sevenDay == nil,
            "same-timestamp explicit empty rate_limits object clears older quota data")
        try? FileManager.default.removeItem(at: equalQuotaRoot.deletingLastPathComponent())

        let missingWindowRoot = try fixtureDirectory("missing-window")
        try writeSession(in: missingWindowRoot, uuid: "99999999-9999-4999-8999-999999999999",
            events: [tokenEvent(at: now.addingTimeInterval(-40), input: 1, output: 1,
                rateLimits: rateLimits(fiveHour: 25, sevenDay: nil, reset: now.addingTimeInterval(3600)))],
            modified: now)
        try writeSession(in: missingWindowRoot, uuid: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaab",
            events: [tokenEvent(at: now.addingTimeInterval(-20), input: 1, output: 1,
                rateLimits: rateLimits(fiveHour: nil, sevenDay: 55, reset: now.addingTimeInterval(3600)))], modified: now)
        let missingWindow = try LocalCodexUsageReader.scan(directory: missingWindowRoot, now: now)
        check(missingWindow.fiveHour == nil && missingWindow.sevenDay?.usedPercent == 55,
            "missing 5-hour quota stays unknown without combining another event")
        try? FileManager.default.removeItem(at: missingWindowRoot.deletingLastPathComponent())

        let clearedWindowRoot = try fixtureDirectory("cleared-window")
        try writeSession(in: clearedWindowRoot, uuid: "12121212-1212-4212-8212-121212121212",
            events: [tokenEvent(at: now.addingTimeInterval(-60), input: 1, output: 1,
                rateLimits: rateLimits(fiveHour: 45, sevenDay: 65, reset: now.addingTimeInterval(3600)))], modified: now)
        try writeSession(in: clearedWindowRoot, uuid: "13131313-1313-4313-8313-131313131313",
            events: [tokenEvent(at: now.addingTimeInterval(-10), input: 1, output: 1, rateLimits: [:])], modified: now)
        let clearedWindow = try LocalCodexUsageReader.scan(directory: clearedWindowRoot, now: now)
        check(clearedWindow.fiveHour == nil && clearedWindow.sevenDay == nil,
            "newest event with empty rate_limits clears older quota snapshot")
        try? FileManager.default.removeItem(at: clearedWindowRoot.deletingLastPathComponent())

        let futureRoot = try fixtureDirectory("future-event")
        let future = now.addingTimeInterval(3600)
        try writeSession(in: futureRoot, uuid: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            events: [tokenEvent(at: future, input: 1, output: 1,
                rateLimits: rateLimits(fiveHour: 25, sevenDay: 35, reset: future.addingTimeInterval(3600)))], modified: now)
        let futureSnapshot = try LocalCodexUsageReader.scan(directory: futureRoot, now: now)
        check(futureSnapshot.latestEventAt == future
            && futureSnapshot.fiveHour?.isFresh(at: now, refreshSeconds: 60) == false,
            "future-dated local quota retains its timestamp but is not treated as current")
        try? FileManager.default.removeItem(at: futureRoot.deletingLastPathComponent())

        let symlinkRoot = try fixtureDirectory("symlink-root")
        let outsideRoot = try fixtureDirectory("symlink-outside")
        try writeSession(in: outsideRoot, uuid: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            events: [tokenEvent(at: now, input: 100, output: 200)], modified: now)
        let target = sessionURL(in: outsideRoot, uuid: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        try FileManager.default.createSymbolicLink(at: sessionURL(in: symlinkRoot, uuid: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"),
            withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: symlinkRoot.appendingPathComponent("linked-directory"),
            withDestinationURL: outsideRoot)
        let symlink = try LocalCodexUsageReader.scan(directory: symlinkRoot, now: now)
        check(symlink.input == 0 && symlink.output == 0 && symlink.sessionCount == 0,
            "file and directory symlinks outside the sessions root are not followed")
        try? FileManager.default.removeItem(at: symlinkRoot.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: outsideRoot.deletingLastPathComponent())

        let missingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-missing-\(UUID().uuidString)")
        let empty = try LocalCodexUsageReader.scan(directory: missingRoot, now: now)
        check(empty.input == 0 && empty.output == 0 && empty.total == 0 && empty.sessionCount == 0
            && empty.latestEventAt == nil,
            "missing sessions root returns an empty snapshot")

        let nestedRoot = try fixtureDirectory("nested-sessions")
        let nestedID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        try writeSession(in: nestedRoot, uuid: nestedID,
            events: [tokenEvent(at: now, input: 17, output: 19)], modified: now)
        let nestedDirectory = nestedRoot.appendingPathComponent("2026/10/17", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: sessionURL(in: nestedRoot, uuid: nestedID),
            to: nestedDirectory.appendingPathComponent("rollout-fixture-\(nestedID).jsonl"))
        let nested = try LocalCodexUsageReader.scan(directory: nestedRoot, now: now)
        check(nested.input == 17 && nested.output == 19 && nested.sessionCount == 1,
            "nested Codex YYYY/MM/DD session files are discovered")
        try? FileManager.default.removeItem(at: nestedRoot.deletingLastPathComponent())

        let overflowRoot = try fixtureDirectory("aggregate-overflow")
        try writeSession(in: overflowRoot, uuid: "ffffffff-ffff-4fff-8fff-ffffffffffff",
            events: [rawTokenEvent(at: now, inputLiteral: String(Int.max), outputLiteral: "0")], modified: now)
        try writeSession(in: overflowRoot, uuid: "abababab-abab-4bab-8bab-abababababab",
            events: [rawTokenEvent(at: now, inputLiteral: "1", outputLiteral: "0")], modified: now)
        do {
            _ = try LocalCodexUsageReader.scan(directory: overflowRoot, now: now)
            check(false, "aggregate Int overflow is rejected")
        } catch {
            check(true, "aggregate Int overflow is rejected")
        }
        try? FileManager.default.removeItem(at: overflowRoot.deletingLastPathComponent())

        let boundedRoot = try fixtureDirectory("bounded-sessions")
        var pad = Data(repeating: 0x78, count: 256 * 1024 + 8)
        pad.append(10)
        for index in 0..<33 {
            let uuid = String(format: "dddddddd-dddd-4ddd-8ddd-%012d", index + 1)
            try writeSession(in: boundedRoot, uuid: uuid,
                events: [tokenEvent(at: now, input: 1, output: 1)],
                modified: now.addingTimeInterval(Double(index)), prefix: pad)
        }
        let boundedCache = LocalCodexUsageReader.Cache()
        let bounded = try LocalCodexUsageReader.scan(directory: boundedRoot, now: now, cache: boundedCache)
        check(bounded.sessionCount == 32 && bounded.knownThreadCount == 32 && bounded.isLimited
            && !bounded.hasCompleteAccounting,
            "scan selects at most 32 metadata-classified roots and marks bounded coverage incomplete")
        let warmBounded = try LocalCodexUsageReader.scan(directory: boundedRoot, now: now, cache: boundedCache)
        check(boundedCache.diagnostics.cacheHits == 32 && boundedCache.diagnostics.bytesRead == 0
            && boundedCache.entryCount == 32 && warmBounded.isLimited,
            "warm cache hits all 32 retained file summaries without content reads and preserves limitation")
        try? FileManager.default.removeItem(at: boundedRoot.deletingLastPathComponent())

        let readBudgetRoot = try fixtureDirectory("head-tail-10mib-budget")
        var largePadding = Data(repeating: 0x78, count: 400 * 1024)
        largePadding.append(10)
        for index in 0..<32 {
            let uuid = String(format: "45454545-4545-4545-8545-%012d", index + 1)
            try writeSession(in: readBudgetRoot, uuid: uuid,
                events: [tokenEvent(at: now, input: 2, output: 3)], modified: now,
                prefix: largePadding)
        }
        let budgetCache = LocalCodexUsageReader.Cache()
        let budgetSnapshot = try LocalCodexUsageReader.scan(directory: readBudgetRoot, now: now, cache: budgetCache)
        check(budgetCache.diagnostics.bytesRead <= 10 * 1024 * 1024
            && budgetCache.diagnostics.bytesRead > 8 * 1024 * 1024
            && budgetSnapshot.knownThreadCount == 32 && budgetSnapshot.isLimited
            && !budgetSnapshot.hasCompleteAccounting,
            "32 files read only within aggregate 10 MiB head+tail budget and cannot claim complete totals")
        try? FileManager.default.removeItem(at: readBudgetRoot.deletingLastPathComponent())

        let continuousBoundaryRoot = try fixtureDirectory("continuous-records-cross-head-boundary")
        let continuousID = "46464646-4646-4646-8646-464646464646"
        let oneRecord = try ordinaryEvent(at: now.addingTimeInterval(-2), type: "user_message")
        var continuousPrefix = Data()
        continuousPrefix.append(try tokenEvent(at: now.addingTimeInterval(-3), input: 4, output: 2))
        continuousPrefix.append(10)
        continuousPrefix.append(try ordinaryEvent(at: now.addingTimeInterval(-2.5), type: "user_message"))
        continuousPrefix.append(10)
        while continuousPrefix.count < 70 * 1024 {
            continuousPrefix.append(oneRecord)
            continuousPrefix.append(10)
        }
        try writeSession(in: continuousBoundaryRoot, uuid: continuousID,
            events: [tokenEvent(at: now, input: 10, output: 5)], modified: now,
            prefix: continuousPrefix, metadataID: continuousID,
            metadataFields: ["parent_thread_id": parentID, "subagent_history_start_ordinal": 2])
        let continuousFileBytes = try Data(contentsOf: sessionURL(in: continuousBoundaryRoot, uuid: continuousID))
        check(continuousFileBytes[64 * 1024 - 1] != 10,
            "continuous boundary fixture places the actual file head cutoff inside a complete JSON record")
        let continuousBoundary = try LocalCodexUsageReader.scan(directory: continuousBoundaryRoot, now: now)
        check(!continuousBoundary.isLimited && continuousBoundary.input == 6
            && continuousBoundary.output == 3 && continuousBoundary.total == 9
            && continuousBoundary.knownThreadCount == 1 && continuousBoundary.unknownThreadCount == 0,
            "a fully retained 64-320KiB file with valid records crossing the head boundary is not a read gap")
        try? FileManager.default.removeItem(at: continuousBoundaryRoot.deletingLastPathComponent())

        let emptyThenValidRoot = try fixtureDirectory("empty-file-does-not-stop-scan")
        let emptyFirstPath = emptyThenValidRoot.appendingPathComponent("rollout-empty-00000000-0000-4000-8000-000000000000.jsonl")
        try Data().write(to: emptyFirstPath)
        try writeSession(in: emptyThenValidRoot, uuid: "47474747-4747-4747-8747-474747474747",
            events: [tokenEvent(at: now, input: 7, output: 9)], modified: now)
        let emptyThenValid = try LocalCodexUsageReader.scan(directory: emptyThenValidRoot, now: now)
        check(emptyThenValid.knownThreadCount == 1 && emptyThenValid.input == 7 && emptyThenValid.output == 9
            && emptyThenValid.unidentifiedFileCount == 1 && emptyThenValid.sessionCount == 1,
            "an empty invalid file does not prevent discovery and accounting of a later valid file")
        try? FileManager.default.removeItem(at: emptyThenValidRoot.deletingLastPathComponent())

        let entryRoot = try fixtureDirectory("bounded-entries")
        for _ in 0..<5001 {
            let name = "rollout-fixture-\(UUID().uuidString).jsonl"
            try Data().write(to: entryRoot.appendingPathComponent(name))
        }
        let entryBound = try LocalCodexUsageReader.scan(directory: entryRoot, now: now)
        check(entryBound.isLimited && entryBound.filesScanned <= 5000,
            "directory enumeration beyond 5000 entries is bounded and reported")
        try? FileManager.default.removeItem(at: entryRoot.deletingLastPathComponent())

        let defaultConfiguration = AppConfiguration()
        check(defaultConfiguration.dataSource == "localCodex", "fresh desktop configuration defaults to local Codex data")
        let syntheticHome = FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-home-\(UUID().uuidString)")
        let syntheticCodex = FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-codex-\(UUID().uuidString)")
        let defaultLocalDirectory = LocalCodexUsageReader.defaultSessionsDirectory(environment: [:], home: syntheticHome)
        let overrideLocalDirectory = LocalCodexUsageReader.defaultSessionsDirectory(environment: ["CODEX_HOME": syntheticCodex.path], home: syntheticHome)
        check(defaultLocalDirectory.standardizedFileURL.path == syntheticHome.appendingPathComponent(".codex/sessions").standardizedFileURL.path
            && overrideLocalDirectory.standardizedFileURL.path == syntheticCodex.appendingPathComponent("sessions").standardizedFileURL.path,
            "local source resolves only the synthetic home or explicit absolute CODEX_HOME sessions path")
        let legacyPlist: [String: Any] = ["endpoint": "https://gateway.example/v1/chat/completions",
            "usageURL": "https://gateway.example/usage", "port": 18888]
        let legacyData = try PropertyListSerialization.data(fromPropertyList: legacyPlist, format: .xml, options: 0)
        let legacy = try PropertyListDecoder().decode(AppConfiguration.self, from: legacyData)
        check(legacy.dataSource == "proxy", "legacy explicit proxy configuration without source preserves proxy mode")
    }

    private static func fixtureDirectory(_ label: String) throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-\(label)-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func sessionURL(in directory: URL, uuid: String) -> URL {
        directory.appendingPathComponent("rollout-fixture-\(uuid).jsonl")
    }

    private static func writeSession(in directory: URL, uuid: String, events: [Data], modified: Date,
                                     prefix: Data = Data(), suffix: Data = Data(),
                                     metadataID: String? = nil, metadataSource: Any? = "cli",
                                     metadataFields: [String: Any] = [:], metadata: Data? = nil) throws {
        var data = metadata ?? sessionMetadata(id: metadataID ?? uuid, source: metadataSource, fields: metadataFields)
        if !data.isEmpty { data.append(10) }
        data.append(prefix)
        for event in events { data.append(event); data.append(10) }
        data.append(suffix)
        let url = sessionURL(in: directory, uuid: uuid)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private static func tokenEvent(at timestamp: Date, input: Int, output: Int, cached: Int = 0,
                                   reasoning: Int = 0, rateLimits: Any? = nil) throws -> Data {
        var usage: [String: Any] = ["input_tokens": input, "output_tokens": output, "total_tokens": input + output]
        if cached > 0 { usage["cached_input_tokens"] = cached }
        if reasoning > 0 { usage["reasoning_output_tokens"] = reasoning }
        let info: [String: Any] = ["total_token_usage": usage]
        var payload: [String: Any] = ["type": "token_count", "info": info]
        if let rateLimits { payload["rate_limits"] = rateLimits }
        let event: [String: Any] = ["timestamp": iso(timestamp), "type": "event_msg", "payload": payload]
        return try JSONSerialization.data(withJSONObject: event)
    }

    private static func quotaOnlyEvent(at timestamp: Date, rateLimits: Any) throws -> Data {
        let event: [String: Any] = ["timestamp": iso(timestamp), "type": "event_msg",
            "payload": ["type": "token_count", "info": [:], "rate_limits": rateLimits]]
        return try JSONSerialization.data(withJSONObject: event)
    }

    private static func ordinaryEvent(at timestamp: Date, type: String) throws -> Data {
        let event: [String: Any] = ["timestamp": iso(timestamp), "type": "event_msg",
            "payload": ["type": type]]
        return try JSONSerialization.data(withJSONObject: event)
    }

    private static func threadSettingsApplied(at timestamp: Date, threadID: String) throws -> Data {
        let event: [String: Any] = ["timestamp": iso(timestamp), "type": "event_msg",
            "payload": ["type": "thread_settings_applied", "thread_id": threadID,
                        "thread_settings": ["model": "synthetic"]]]
        return try JSONSerialization.data(withJSONObject: event)
    }

    private static func sessionMetadata(id: String?, source: Any?, fields: [String: Any] = [:]) -> Data {
        var payload = fields
        if let id { payload["id"] = id }
        if let source { payload["source"] = source }
        let object: [String: Any] = ["type": "session_meta", "payload": payload]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func rawTokenEvent(at timestamp: Date, inputLiteral: String, outputLiteral: String,
                                     totalLiteral: String? = nil) -> Data {
        let time = iso(timestamp)
        let totalJSON = totalLiteral ?? "1"
        return Data("{\"timestamp\":\"\(time)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(inputLiteral),\"output_tokens\":\(outputLiteral),\"total_tokens\":\(totalJSON)}}}}".utf8)
    }

    private static func turnTokenEvent(at timestamp: Date, output: Int) throws -> Data {
        let event: [String: Any] = ["timestamp": iso(timestamp), "type": "event_msg",
            "payload": ["type": "token_count", "info": ["total_token_usage": [
                "input_tokens": 0, "output_tokens": output, "total_tokens": output]]]]
        return try JSONSerialization.data(withJSONObject: event)
    }

    private static func turnTokenEventWithoutTimestamp(output: Int) throws -> Data {
        let event: [String: Any] = ["type": "event_msg",
            "payload": ["type": "token_count", "info": ["total_token_usage": [
                "input_tokens": 0, "output_tokens": output, "total_tokens": output]]]]
        return try JSONSerialization.data(withJSONObject: event)
    }

    private static func turnBoundary(at timestamp: Date, type: String, id: String,
                                     durationMS: Int? = nil, durationLiteral: String? = nil) throws -> Data {
        var payload: [String: Any] = ["type": type, "turn_id": id]
        if let durationMS { payload["duration_ms"] = durationMS }
        if durationLiteral == "true" { payload["duration_ms"] = true }
        else if durationLiteral == "null" { payload["duration_ms"] = NSNull() }
        else if let durationLiteral { payload["duration_ms"] = durationLiteral }
        let event: [String: Any] = ["timestamp": iso(timestamp), "type": "event_msg", "payload": payload]
        return try JSONSerialization.data(withJSONObject: event)
    }

    private static func turnBoundaryWithoutTimestamp(type: String, id: String) throws -> Data {
        let event: [String: Any] = ["type": "event_msg",
            "payload": ["type": type, "turn_id": id]]
        return try JSONSerialization.data(withJSONObject: event)
    }

    private static func rateLimits(fiveHour: Int?, sevenDay: Int?, reset: Date) -> [String: Any] {
        var value: [String: Any] = [:]
        if let fiveHour { value["primary"] = ["used_percent": fiveHour, "window_minutes": 300, "resets_at": reset.timeIntervalSince1970] }
        if let sevenDay { value["secondary"] = ["used_percent": sevenDay, "window_minutes": 10080, "resets_at": reset.timeIntervalSince1970] }
        return value
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
```

### Tests/TokenStatUITests/TokenStatUISnapshotTests.swift

```swift
import AppKit
import SnapshotTesting
import SwiftUI
import XCTest
import TokenStatCore
@testable import TokenStatMenu

@MainActor
final class TokenStatUISnapshotTests: XCTestCase {
    func testDashboardLightAndDark() {
        assertDashboard(_appearance: .aqua, name: "dashboard-light")
        assertDashboard(_appearance: .darkAqua, name: "dashboard-dark")
    }

    func testSettingsLightAndDark() {
        assertDashboard(_appearance: .aqua, settings: true, name: "settings-light")
        assertDashboard(_appearance: .darkAqua, settings: true, name: "settings-dark")
    }

    func testLocalStatusTitleUsesCompletedTurnAndRecordedSessionTotal() throws {
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        model.localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0,
            filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
            knownThreadCount: 0, unknownThreadCount: 0, unidentifiedFileCount: 0,
            subagentCount: 0, forkCount: 0)
        XCTAssertTrue(model.title.contains("上轮均:—"))
        model.localSnapshot = LocalCodexSnapshot(input: 125, output: 300, total: 425,
            sessionCount: 2, filesScanned: 2, isLimited: false,
            latestEventAt: Date(timeIntervalSince1970: 1_797_000_000), fiveHour: nil, sevenDay: nil,
            knownThreadCount: 2, unknownThreadCount: 0, unidentifiedFileCount: 0,
            subagentCount: 0, forkCount: 0,
            lastTurn: LocalTurnSummary(outputTokens: 75, durationSeconds: 5,
                completedAt: Date(timeIntervalSince1970: 1_797_000_000)))
        XCTAssertEqual(model.title, "上轮均:15.0tok/s · Σ425 · 2顶层对话")
        XCTAssertTrue(model.dataNotice.contains("当前扫描范围记录小计"))
        XCTAssertTrue(model.menuTooltip.contains("425"))
        XCTAssertTrue(model.menuTooltip.contains("顶层对话 2"))
        XCTAssertTrue(model.menuTooltip.contains("含工具、网络和等待"))
        XCTAssertTrue(model.menuTooltip.contains("5 小时"))
        XCTAssertTrue(model.menuTooltip.contains("7 天"))
        XCTAssertTrue(model.menuTooltip.contains("32"), "tooltip should describe the bounded session/file coverage")
        model.localSnapshot = LocalCodexSnapshot(input: 1_234_200, output: 367, total: 1_234_567,
            sessionCount: 2, filesScanned: 2, isLimited: false,
            latestEventAt: Date(timeIntervalSince1970: 1_797_000_000), fiveHour: nil, sevenDay: nil,
            knownThreadCount: 2, unknownThreadCount: 0, unidentifiedFileCount: 0,
            subagentCount: 0, forkCount: 0,
            lastTurn: LocalTurnSummary(outputTokens: 75, durationSeconds: 5,
                completedAt: Date(timeIntervalSince1970: 1_797_000_000)))
        let fullTotal = 1_234_567.formatted(.number)
        XCTAssertTrue(model.title.hasPrefix("上轮均:15.0tok/s · Σ"))
        XCTAssertFalse(model.title.contains("Σ" + fullTotal), "status title should compact large totals")
        XCTAssertTrue(model.menuTooltip.contains(fullTotal), "tooltip should retain the full cumulative total")
        let futureQuotaData = try JSONSerialization.data(withJSONObject: ["result": ["rateLimits": [
            "primary": ["usedPercent": 88, "windowDurationMins": 300,
                        "resetsAt": Date().addingTimeInterval(7200).timeIntervalSince1970]
        ]]])
        model.fiveHourQuota = try QuotaReport.parse(futureQuotaData, config: AppConfiguration(),
            now: Date().addingTimeInterval(3600)).fiveHour
        XCTAssertTrue(model.menuTooltip.contains("异常时间戳"), "tooltip should label future quota data anomalous")
    }

    func testC12LocalAccountingUINeverLabelsPartialSubtotalAsComplete() {
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        model.config.dataSource = "localCodex"
        let known = LocalCodexSnapshot(input: 30, output: 20, total: 50, sessionCount: 1,
            filesScanned: 2, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
            knownThreadCount: 1, unknownThreadCount: 2, unidentifiedFileCount: 1,
            subagentCount: 0, forkCount: 0)
        XCTAssertFalse(known.hasCompleteAccounting)
        model.localSnapshot = known
        XCTAssertTrue(model.title.contains("小计50"))
        XCTAssertTrue(model.title.contains("未核验3"))
        XCTAssertFalse(model.title.contains("Σ50"))
        XCTAssertTrue(model.menuTooltip.contains("输入 30"))
        XCTAssertTrue(model.menuTooltip.contains("输出 20"))
        XCTAssertTrue(model.menuTooltip.contains("总计 50"))
        XCTAssertTrue(model.menuTooltip.contains("未核验线程 2"))
        XCTAssertTrue(model.menuTooltip.contains("未识别文件 1"))
        XCTAssertFalse(model.menuTooltip.contains("本次扫描记录量 50"))

        model.localSnapshot = LocalCodexSnapshot(input: 8, output: 2, total: 10, sessionCount: 0,
            filesScanned: 1, isLimited: true, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
            knownThreadCount: 1, unknownThreadCount: 0, unidentifiedFileCount: 0,
            subagentCount: 0, forkCount: 0)
        XCTAssertFalse(model.localSnapshot.hasCompleteAccounting, "a scan limit prevents complete accounting")
        XCTAssertTrue(model.title.contains("小计10"))
        XCTAssertFalse(model.title.contains("Σ10"))

        model.localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0,
            filesScanned: 2, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
            knownThreadCount: 0, unknownThreadCount: 0, unidentifiedFileCount: 2,
            subagentCount: 0, forkCount: 0)
        XCTAssertTrue(model.title.contains("Σ—"), "without any known thread, zero is unknown rather than an exact total")

        model.localSnapshot = LocalCodexSnapshot(input: 30, output: 20, total: 50, sessionCount: 1,
            filesScanned: 1, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
            knownThreadCount: 1, unknownThreadCount: 0, unidentifiedFileCount: 0,
            subagentCount: 0, forkCount: 0)
        XCTAssertTrue(model.localSnapshot.hasCompleteAccounting)
        XCTAssertTrue(model.title.contains("Σ50"), "complete metadata-backed accounting may show exact total")
        XCTAssertTrue(model.menuTooltip.contains("本次扫描记录量 50"))
    }

    func testC12AccountingDashboardExportsSyntheticReviewRenders() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("TokenStatMenu-C12-review", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scenarios: [(String, LocalCodexSnapshot)] = [
            ("known-subagent-no-top-level", LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0,
                filesScanned: 1, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
                knownThreadCount: 1, unknownThreadCount: 0, unidentifiedFileCount: 0, subagentCount: 1, forkCount: 1)),
            ("partial-accounting", LocalCodexSnapshot(input: 30, output: 20, total: 50, sessionCount: 1,
                filesScanned: 4, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
                knownThreadCount: 1, unknownThreadCount: 2, unidentifiedFileCount: 1, subagentCount: 0, forkCount: 0)),
            ("zero-known-threads", LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0,
                filesScanned: 2, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
                knownThreadCount: 0, unknownThreadCount: 2, unidentifiedFileCount: 0, subagentCount: 0, forkCount: 0))
        ]
        var paths: [String] = []
        for (scenario, snapshot) in scenarios {
            let model = AppModel(preview: true)
            model.config.dataSource = "localCodex"
            model.localSnapshot = snapshot
            for (scheme, appearance) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
                let content = DashboardView(model: model)
                    .environment(\.colorScheme, scheme)
                    .frame(width: 460, height: 700)
                    .background(scheme == .dark ? Color(red: 0.13, green: 0.14, blue: 0.17) : Color(red: 0.96, green: 0.97, blue: 0.99))
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
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else {
                    throw NSError(domain: "C12DashboardRender", code: 1)
                }
                host.cacheDisplay(in: bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "C12DashboardRender", code: 2)
                }
                let name = "\(scenario)-\(scheme == .dark ? "dark" : "light").png"
                let url = output.appendingPathComponent(name)
                try png.write(to: url)
                XCTAssertGreaterThan(try Data(contentsOf: url).count, 0)
                paths.append(url.path)
                window.close()
            }
            model.shutdown()
        }
        print("C12 synthetic accounting Dashboard renders: \(paths.joined(separator: ", "))")
    }

    func testEnterpriseQuotaAlertsUseOnlyFreshIndependentWindows() throws {
        let now = Date()
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        model.config.dataSource = "proxy"
        func quota(five: Double?, seven: Double?, fetchedAt: Date, reset: Date) throws -> QuotaReport {
            var limits: [String: Any] = [:]
            if let five { limits["primary"] = ["usedPercent": five, "windowDurationMins": 300, "resetsAt": reset.timeIntervalSince1970] }
            if let seven { limits["secondary"] = ["usedPercent": seven, "windowDurationMins": 10080, "resetsAt": reset.timeIntervalSince1970] }
            let object: [String: Any] = ["result": ["rateLimits": limits]]
            return try QuotaReport.parse(JSONSerialization.data(withJSONObject: object), config: AppConfiguration(), now: fetchedAt)
        }
        let fresh = try quota(five: 96, seven: 20, fetchedAt: now, reset: now.addingTimeInterval(3600))
        model.fiveHourQuota = fresh.fiveHour
        model.sevenDayQuota = fresh.sevenDay
        XCTAssertEqual(model.alertColor, .systemRed)

        let stale = try quota(five: 99, seven: 20, fetchedAt: now.addingTimeInterval(-3600), reset: now.addingTimeInterval(3600))
        model.fiveHourQuota = stale.fiveHour
        model.sevenDayQuota = fresh.sevenDay
        XCTAssertEqual(model.alertColor, .labelColor, "stale 5-hour quota must not override its fresh 7-day sibling")

        let freshSevenDay = try quota(five: 20, seven: 96, fetchedAt: now, reset: now.addingTimeInterval(3600))
        model.fiveHourQuota = stale.fiveHour
        model.sevenDayQuota = freshSevenDay.sevenDay
        XCTAssertEqual(model.alertColor, .systemRed, "fresh 7-day alert remains active when the 5-hour sibling is stale")

        let future = try quota(five: 99, seven: nil, fetchedAt: now.addingTimeInterval(3600), reset: now.addingTimeInterval(7200))
        model.fiveHourQuota = future.fiveHour
        model.sevenDayQuota = nil
        XCTAssertEqual(model.alertColor, .labelColor, "future-dated quota must not contribute to current alerts")

        let resetExpired = try quota(five: 99, seven: nil, fetchedAt: now, reset: now.addingTimeInterval(-1))
        model.fiveHourQuota = resetExpired.fiveHour
        model.sevenDayQuota = nil
        XCTAssertEqual(model.alertColor, .labelColor, "reset-expired quota must not contribute to current alerts")
    }

    func testC11LocalQuotaSnapshotsNeverBecomeEnterpriseCurrentOrAlerts() throws {
        let now = Date()
        let monthlyData = try JSONSerialization.data(withJSONObject: ["data": [
            "used_tokens": 123, "total_tokens": 1234
        ]])
        var monthlyConfig = AppConfiguration()
        monthlyConfig.periodPath = ""
        let monthlyFixture = try QuotaSnapshot.parse(monthlyData, config: monthlyConfig, now: now)
        func quota(five: Double?, seven: Double?, fetchedAt: Date, reset: Date) throws -> QuotaReport {
            var limits: [String: Any] = [:]
            if let five { limits["primary"] = ["usedPercent": five, "windowDurationMins": 300, "resetsAt": reset.timeIntervalSince1970] }
            if let seven { limits["secondary"] = ["usedPercent": seven, "windowDurationMins": 10080, "resetsAt": reset.timeIntervalSince1970] }
            return try QuotaReport.parse(JSONSerialization.data(withJSONObject: ["result": ["rateLimits": limits]]),
                config: AppConfiguration(), now: fetchedAt)
        }

        let local = AppModel(preview: true)
        defer { local.shutdown() }
        local.config.dataSource = "localCodex"
        let recentLocal = try quota(five: 99, seven: 98, fetchedAt: now, reset: now.addingTimeInterval(3600))
        local.fiveHourQuota = recentLocal.fiveHour
        local.sevenDayQuota = recentLocal.sevenDay
        let highMonthlyData = try JSONSerialization.data(withJSONObject: ["data": [
            "used_tokens": 1234, "total_tokens": 1234
        ]])
        local.quota = try QuotaSnapshot.parse(highMonthlyData, config: monthlyConfig, now: now)
        XCTAssertEqual(local.quotaSource, .localCodex)
        for value in [recentLocal.fiveHour, recentLocal.sevenDay].compactMap({ $0 }) {
            let card = WindowQuotaCard.presentation(for: value, at: now, refreshSeconds: 60, source: .localCodex)
            XCTAssertFalse(card.isFresh, "a recent local snapshot is never an enterprise-current allowance")
            XCTAssertTrue(card.sourceLabel.contains("本地"))
            XCTAssertTrue(card.statusLabel.contains("本地"))
            XCTAssertFalse(card.statusLabel.contains("当前企业"))
            XCTAssertEqual(card.usedPercent, value.usedPercent)
            XCTAssertEqual(card.resetsAt, value.resetsAt)
            XCTAssertEqual(card.recordedAt, value.fetchedAt)
        }
        XCTAssertEqual(local.alertColor, .labelColor, "local rolling snapshots and a high monthly quota never drive enterprise alerts")
        XCTAssertTrue(local.menuTooltip.contains("5 小时额度：本地"))
        XCTAssertTrue(local.menuTooltip.contains("7 天额度：本地"))
        XCTAssertFalse(local.menuTooltip.contains("当前企业"))
        XCTAssertTrue(local.menuTooltip.contains("99.0%"), "local tooltip retains the original percentage")
        XCTAssertTrue(local.menuTooltip.contains("重置"), "local tooltip includes the reset time when present")

        for (window, percent) in [(300, 77.0), (10080, 78.0)] {
            let stale = try quota(five: window == 300 ? percent : nil, seven: window == 10080 ? percent : nil,
                fetchedAt: now.addingTimeInterval(-3600), reset: now.addingTimeInterval(3600))
            let value = window == 300 ? stale.fiveHour : stale.sevenDay
            let card = WindowQuotaCard.presentation(for: value, at: now, refreshSeconds: 60, source: .localCodex)
            XCTAssertFalse(card.isFresh, "stale local \(window)-minute window is never current")
            XCTAssertEqual(card.usedPercent, percent)
            XCTAssertEqual(card.resetsAt, value?.resetsAt)
            XCTAssertTrue(card.statusLabel.contains("本地"))
            XCTAssertTrue(card.statusLabel.contains("历史"))
            XCTAssertEqual(card.recordedAt, value?.fetchedAt)

            let future = try quota(five: window == 300 ? percent : nil, seven: window == 10080 ? percent : nil,
                fetchedAt: now.addingTimeInterval(600), reset: now.addingTimeInterval(3600))
            let futureValue = window == 300 ? future.fiveHour : future.sevenDay
            let futureCard = WindowQuotaCard.presentation(for: futureValue, at: now, refreshSeconds: 60, source: .localCodex)
            XCTAssertTrue(futureCard.statusLabel.contains("本地"))
            XCTAssertTrue(futureCard.statusLabel.contains("异常"))
            XCTAssertEqual(futureCard.usedPercent, percent)

            let expired = try quota(five: window == 300 ? percent : nil, seven: window == 10080 ? percent : nil,
                fetchedAt: now, reset: now.addingTimeInterval(-1))
            let expiredValue = window == 300 ? expired.fiveHour : expired.sevenDay
            let expiredCard = WindowQuotaCard.presentation(for: expiredValue, at: now, refreshSeconds: 60, source: .localCodex)
            XCTAssertTrue(expiredCard.statusLabel.contains("本地"))
            XCTAssertTrue(expiredCard.statusLabel.contains("重置已过"))
            XCTAssertEqual(expiredCard.usedPercent, percent)
            XCTAssertEqual(expiredCard.resetsAt, expiredValue?.resetsAt)

            let missingResetData = try JSONSerialization.data(withJSONObject: ["result": ["rateLimits": [
                "primary": ["usedPercent": percent, "windowDurationMins": 300],
                "secondary": ["usedPercent": percent, "windowDurationMins": 10080]
            ]]])
            let missingReset = try QuotaReport.parse(missingResetData, config: AppConfiguration(), now: now)
            let missingResetValue = window == 300 ? missingReset.fiveHour : missingReset.sevenDay
            let missingResetCard = WindowQuotaCard.presentation(for: missingResetValue, at: now,
                refreshSeconds: 60, source: .localCodex)
            XCTAssertEqual(missingResetCard.usedPercent, percent)
            XCTAssertNil(missingResetCard.resetsAt)
            XCTAssertTrue(missingResetCard.statusLabel.contains("本地"))
            XCTAssertTrue(missingResetCard.statusLabel.contains("未知"))

            let missingCard = WindowQuotaCard.presentation(for: nil, at: now, refreshSeconds: 60, source: .localCodex)
            XCTAssertTrue(missingCard.statusLabel.contains("本地"))
            XCTAssertTrue(missingCard.statusLabel.contains("未提供"))
        }

        let enterprise = AppModel(preview: true)
        defer { enterprise.shutdown() }
        enterprise.config.dataSource = "proxy"
        let currentEnterprise = try quota(five: 96, seven: 20, fetchedAt: now, reset: now.addingTimeInterval(3600))
        enterprise.fiveHourQuota = currentEnterprise.fiveHour
        enterprise.sevenDayQuota = currentEnterprise.sevenDay
        XCTAssertTrue(enterprise.menuTooltip.contains("企业"), "proxy tooltip identifies its quota source")
        XCTAssertTrue(enterprise.menuTooltip.contains("96.0%"), "proxy tooltip retains the original percentage")
        XCTAssertTrue(enterprise.menuTooltip.contains("重置"), "proxy tooltip includes the reset time")
        XCTAssertEqual(enterprise.quotaSource, .enterprise)
        let enterpriseCard = WindowQuotaCard.presentation(for: try XCTUnwrap(currentEnterprise.fiveHour), at: now,
            refreshSeconds: 60, source: .enterprise)
        XCTAssertTrue(enterpriseCard.isFresh)
        XCTAssertTrue(enterpriseCard.sourceLabel.contains("企业"))
        XCTAssertTrue(enterpriseCard.statusLabel.contains("企业"))
        XCTAssertEqual(enterprise.alertColor, .systemRed, "configured enterprise fresh-window alerts remain unchanged")

        let staleEnterprise = try quota(five: 99, seven: 20, fetchedAt: now.addingTimeInterval(-3600), reset: now.addingTimeInterval(3600))
        enterprise.fiveHourQuota = staleEnterprise.fiveHour
        enterprise.sevenDayQuota = currentEnterprise.sevenDay
        let staleEnterpriseCard = WindowQuotaCard.presentation(for: try XCTUnwrap(staleEnterprise.fiveHour), at: now,
            refreshSeconds: 60, source: .enterprise)
        XCTAssertFalse(staleEnterpriseCard.isFresh)
        XCTAssertTrue(staleEnterpriseCard.statusLabel.contains("企业"))
        XCTAssertEqual(staleEnterpriseCard.usedPercent, 99)
        XCTAssertEqual(enterprise.alertColor, .labelColor, "stale enterprise 5-hour data remains excluded beside fresh 7-day data")

        enterprise.fiveHourQuota = nil
        enterprise.sevenDayQuota = nil
        enterprise.quota = monthlyFixture
        enterprise.quotaLoading = true
        enterprise.resetQuotaState()
        XCTAssertNil(enterprise.quota)
        XCTAssertNil(enterprise.fiveHourQuota)
        XCTAssertNil(enterprise.sevenDayQuota)
        XCTAssertFalse(enterprise.quotaLoading)

        let switching = AppModel(preview: true)
        defer { switching.shutdown() }
        switching.config.dataSource = "localCodex"
        switching.quota = monthlyFixture
        switching.quotaLoading = true
        switching.fiveHourQuota = recentLocal.fiveHour
        switching.sevenDayQuota = recentLocal.sevenDay
        switching.resetQuotaState()
        XCTAssertNil(switching.fiveHourQuota)
        XCTAssertNil(switching.sevenDayQuota)
        XCTAssertNil(switching.quota)
        switching.config.dataSource = "proxy"
        switching.quota = monthlyFixture
        switching.quotaLoading = true
        switching.fiveHourQuota = currentEnterprise.fiveHour
        switching.sevenDayQuota = currentEnterprise.sevenDay
        switching.resetQuotaState()
        XCTAssertNil(switching.fiveHourQuota)
        XCTAssertNil(switching.sevenDayQuota)
        XCTAssertNil(switching.quota)
        XCTAssertFalse(switching.quotaLoading)
        XCTAssertEqual(switching.alertColor, .labelColor)
        XCTAssertFalse(switching.menuTooltip.contains("本地额度快照"))
        switching.sevenDayQuota = currentEnterprise.sevenDay
        XCTAssertNil(switching.fiveHourQuota, "injecting only the new 7-day source window leaves its missing 5-hour sibling missing")
        XCTAssertNotNil(switching.sevenDayQuota)
        switching.quota = monthlyFixture
        switching.quotaLoading = true
        switching.config.dataSource = "localCodex"
        switching.resetQuotaState()
        XCTAssertNil(switching.fiveHourQuota)
        XCTAssertNil(switching.sevenDayQuota)
        XCTAssertNil(switching.quota)
        XCTAssertFalse(switching.quotaLoading)
        switching.fiveHourQuota = recentLocal.fiveHour
        XCTAssertNotNil(switching.fiveHourQuota)
        XCTAssertNil(switching.sevenDayQuota, "injecting only the new 5-hour source window leaves its missing 7-day sibling missing")
        XCTAssertEqual(switching.alertColor, .labelColor)
    }

    func testC11QuotaCardRenderExportsLocalAndEnterpriseSyntheticExamples() throws {
        let now = Date()
        func quota(_ minutes: Int, _ percent: Double, hasReset: Bool = true) throws -> WindowQuota {
            var limit: [String: Any] = ["usedPercent": percent, "windowDurationMins": minutes]
            if hasReset { limit["resetsAt"] = now.addingTimeInterval(3600).timeIntervalSince1970 }
            let key = minutes == 300 ? "primary" : "secondary"
            let data = try JSONSerialization.data(withJSONObject: ["result": ["rateLimits": [key: limit]]])
            let report = try QuotaReport.parse(data, config: AppConfiguration(), now: now)
            return try XCTUnwrap(minutes == 300 ? report.fiveHour : report.sevenDay)
        }
        let artifactDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("TokenStatMenu-C11-review", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        var paths: [String] = []
        for (source, sourceName) in [(QuotaSource.localCodex, "local-codex"), (.enterprise, "enterprise")] {
            for (appearance, appearanceName) in [(NSAppearance.Name.aqua, "aqua"), (.darkAqua, "dark-aqua")] {
                let url = artifactDirectory.appendingPathComponent("\(sourceName)-\(appearanceName).png")
                try renderQuotaCard(try quota(300, 97), source: source, appearance: appearance).write(to: url)
                XCTAssertGreaterThan(try Data(contentsOf: url).count, 0)
                paths.append(url.path)
            }
        }
        let pairedURL = artifactDirectory.appendingPathComponent("local-5h-missing-7d-present.png")
        try renderQuotaCard(try quota(10080, 42, hasReset: false), source: .localCodex, appearance: .aqua,
            missingFiveHour: true).write(to: pairedURL)
        XCTAssertGreaterThan(try Data(contentsOf: pairedURL).count, 0)
        paths.append(pairedURL.path)
        print("C11 synthetic quota card renders: \(paths.joined(separator: ", "))")
    }

    func testHistoricalQuotaPresentationPreservesOriginalSourceValues() throws {
        let now = Date(timeIntervalSince1970: 1_797_000_000)
        let data = try JSONSerialization.data(withJSONObject: ["result": ["rateLimits": [
            "primary": ["usedPercent": 73, "windowDurationMins": 300,
                        "resetsAt": now.addingTimeInterval(-120).timeIntervalSince1970]
        ]]])
        let parsed = try QuotaReport.parse(data, config: AppConfiguration(), now: now.addingTimeInterval(-3600))
        let historic = try XCTUnwrap(parsed.fiveHour)
        let viewState = WindowQuotaCard.presentation(for: historic, at: now, refreshSeconds: 60)
        XCTAssertFalse(viewState.isFresh)
        XCTAssertEqual(viewState.usedPercent, 73)
        XCTAssertEqual(viewState.resetsAt, historic.resetsAt)
        XCTAssertTrue(viewState.statusLabel.contains("历史"))
        XCTAssertTrue(viewState.statusLabel.contains("已过期"))

        let freshData = try JSONSerialization.data(withJSONObject: ["result": ["rateLimits": [
            "primary": ["usedPercent": 73, "windowDurationMins": 300,
                        "resetsAt": now.addingTimeInterval(7200).timeIntervalSince1970]
        ]]])
        let freshReport = try QuotaReport.parse(freshData, config: AppConfiguration(), now: now)
        let fresh = WindowQuotaCard.presentation(for: try XCTUnwrap(freshReport.fiveHour), at: now, refreshSeconds: 60)
        XCTAssertTrue(fresh.isFresh)
        XCTAssertTrue(fresh.statusLabel.contains("当前"))
        let futureReport = try QuotaReport.parse(freshData, config: AppConfiguration(), now: now.addingTimeInterval(3600))
        let future = WindowQuotaCard.presentation(for: try XCTUnwrap(futureReport.fiveHour), at: now, refreshSeconds: 60)
        XCTAssertFalse(future.isFresh)
        XCTAssertTrue(future.statusLabel.contains("异常"))
        let staleReport = try QuotaReport.parse(freshData, config: AppConfiguration(), now: now.addingTimeInterval(-3600))
        let stale = WindowQuotaCard.presentation(for: try XCTUnwrap(staleReport.fiveHour), at: now, refreshSeconds: 60)
        XCTAssertFalse(stale.isFresh)
        XCTAssertEqual(stale.usedPercent, 73)
        XCTAssertEqual(stale.resetsAt, freshReport.fiveHour?.resetsAt)
        XCTAssertTrue(stale.statusLabel.contains("历史"))
        XCTAssertFalse(stale.statusLabel.contains("已过期"))
        let absent = WindowQuotaCard.presentation(for: nil, at: now, refreshSeconds: 60)
        XCTAssertFalse(absent.isFresh)
        XCTAssertNil(absent.usedPercent)
        XCTAssertTrue(absent.statusLabel.contains("未提供"))
    }

    func testImageMatcherDetectsDeliberateMismatchWithoutRecording() {
        let reference = solidImage(.white)
        let unchanged = solidImage(.white)
        let changed = solidImage(.black)
        XCTAssertNil(Snapshotting<NSImage, NSImage>.image.diffing.diffV2(reference, unchanged))
        XCTAssertNotNil(Snapshotting<NSImage, NSImage>.image.diffing.diffV2(reference, changed))
    }

    func testCredentialAccountNamesAreURLAndPurposeBoundWithoutKeychainIO() throws {
        let urlA = "https://gateway-a.example/v1/chat/completions"
        let urlB = "https://gateway-b.example/v1/chat/completions"
        let stableA = try KeychainStore.accountName("upstream", validatedURL: urlA)
        XCTAssertEqual(stableA, try KeychainStore.accountName("upstream", validatedURL: urlA))
        XCTAssertNotEqual(stableA, try KeychainStore.accountName("upstream", validatedURL: urlB))
        XCTAssertNotEqual(stableA, try KeychainStore.accountName("usage", validatedURL: urlA))
    }

    private func solidImage(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 24, height: 24)).fill()
        image.unlockFocus()
        return image
    }

    private func renderQuotaCard(_ quota: WindowQuota, source: QuotaSource, appearance: NSAppearance.Name,
                                 missingFiveHour: Bool = false) throws -> Data {
        let card = Group {
            if missingFiveHour {
                VStack {
                    WindowQuotaCard(title: "5 小时额度", quota: nil, color: .blue, refreshSeconds: 60, source: source)
                    WindowQuotaCard(title: "7 天额度", quota: quota, color: .blue, refreshSeconds: 60, source: source)
                }
            } else {
                WindowQuotaCard(title: quota.minutes == 300 ? "5 小时额度" : "7 天额度", quota: quota,
                    color: .blue, refreshSeconds: 60, source: source)
            }
        }
        let dark = appearance == .darkAqua
        let root = card
            .environment(\.colorScheme, dark ? .dark : .light)
            .padding(16)
            .frame(width: 300, height: 300, alignment: .topLeading)
            .background(dark ? Color(red: 0.13, green: 0.14, blue: 0.17) : Color(red: 0.96, green: 0.97, blue: 0.99))
        let bounds = NSRect(x: 0, y: 0, width: 300, height: 300)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = bounds
        hostingView.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        window.displayIfNeeded()
        hostingView.needsDisplay = true
        hostingView.layoutSubtreeIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw NSError(domain: "C11QuotaCardRender", code: 1)
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "C11QuotaCardRender", code: 2)
        }
        return png
    }

    private func assertDashboard(_appearance appearance: NSAppearance.Name, settings: Bool = false, name: String,
                                 file: StaticString = #filePath, testName: String = #function, line: UInt = #line) {
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        let root = DashboardView(model: model, settings: settings)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 460, height: 700)
        hostingView.appearance = NSAppearance(named: appearance)
        let toolbarCrop = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 66))
        toolbarCrop.wantsLayer = true
        hostingView.frame.origin.y = -634
        toolbarCrop.addSubview(hostingView)
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: toolbarCrop.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = toolbarCrop
        window.appearance = NSAppearance(named: appearance)
        window.displayIfNeeded()
        toolbarCrop.layoutSubtreeIfNeeded()
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["TOKENSTAT_RECORD_SNAPSHOTS"] == "1" ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: toolbarCrop, as: .image, named: name, record: recordMode,
                           file: file, testName: testName, line: line)
        }
        window.orderOut(nil)
    }
}
```

### Tests/TokenStatCoreTests/TokenHubQuotaChecks.swift

```swift
import Foundation
import TokenStatCore

// W1 synthetic-only C13 checks. These compile against the frozen BP08 interface after
// delivery adds the public fixture initializers recorded in this file; no AX permission or
// native reader is used by parser cases.
extension CoreChecks {
    static let hubIdentity = TokenHubIdentity(pid: 421, bundleID: TokenHubTarget.bundleID,
                                               executablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture")

    static func hubWindow(_ kind: TokenHubWindowKind = .fiveHour,
                          titleSeen: Bool = true,
                          percentText: String? = "已使用 37.5%",
                          amount: String? = "$3.75 / $10.00",
                          progressLabel: String? = nil,
                          includeExpectedProgressLabel: Bool = true,
                          progress: Decimal? = Decimal(string: "37.5"),
                          resetSeen: Bool = true,
                          reset: String? = "02-29 23:59") -> TokenHubWindowObservation {
        TokenHubWindowObservation(titleSeen: titleSeen,
            usedPercentText: percentText,
            amountText: amount,
            progressLabel: progressLabel ?? (includeExpectedProgressLabel
                ? (kind == .fiveHour ? "5 小时限额已用比例" : "7 天限额已用比例") : nil),
            progressValue: progress,
            resetLabelSeen: resetSeen,
            resetText: reset)
    }

    static func hubPass(five: TokenHubWindowObservation? = nil,
                        fiveMarker: Bool = false,
                        seven: TokenHubWindowObservation? = nil,
                        sevenMarker: Bool = false,
                        monthlyCount: Int = 0,
                        monthly: TokenHubMonthlyObservation? = nil,
                        groupCount: Int = 1,
                        identity: TokenHubIdentity = hubIdentity) -> TokenHubQuotaPass {
        TokenHubQuotaPass(rootIdentity: identity, quotaGroupCount: groupCount,
            fiveHourMarkerSeen: fiveMarker, fiveHour: five,
            sevenDayMarkerSeen: sevenMarker, sevenDay: seven,
            monthlyContainerCount: monthlyCount, monthly: monthly)
    }

    static func hubSummary(visits: Int = 150, depth: Int = 8, children: Int = 12,
                           longest: Int = 100, text: Int = 600, elapsed: TimeInterval = 0.2,
                           slowest: TimeInterval = 0.01) -> TokenHubTraversalSummary {
        TokenHubTraversalSummary(nodeVisits: visits, maximumDepth: depth,
            maximumChildrenForAnyNode: children, longestStringCharacters: longest,
            textCharacters: text, elapsed: elapsed, slowestElementMessage: slowest)
    }

    static func hubObservation(first: TokenHubQuotaPass? = nil,
                               second: TokenHubQuotaPass? = nil,
                               summary: TokenHubTraversalSummary = hubSummary(),
                               trusted: Bool = true,
                               targets: [TokenHubIdentity] = [hubIdentity],
                               before: TokenHubIdentity? = hubIdentity,
                               after: TokenHubIdentity? = hubIdentity,
                               trace: [TokenHubReadEvent] = []) -> TokenHubQuotaObservation {
        TokenHubQuotaObservation(permissionTrusted: trusted, targets: targets,
            before: before, after: after,
            first: first ?? hubPass(five: hubWindow(), fiveMarker: true),
            second: second ?? hubPass(five: hubWindow(), fiveMarker: true),
            traversal: summary, accessTrace: trace)
    }

    static func hubParse(_ observation: TokenHubQuotaObservation,
                         now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> TokenHubQuotaResult {
        TokenHubQuotaParser.parse(observation, now: now, refreshSeconds: 60)
    }

    static func hubChecks() throws {
        let valid = hubParse(hubObservation())
        check(valid.status == .connected && valid.snapshot != nil, "synthetic valid Hub snapshot accepted")
        check(valid.snapshot?.fiveHour?.usedAmount == Decimal(string: "3.75") &&
              valid.snapshot?.fiveHour?.limitAmount == Decimal(10), "amounts parsed as Decimal")
        check(valid.snapshot?.fiveHour?.sourceSymbol == "$" &&
              valid.snapshot?.fiveHour?.usedPercent == Decimal(string: "37.5") &&
              valid.snapshot?.fiveHour?.remainingPercent == Decimal(string: "62.5"),
              "currency symbol retained and validated progress derives interface remaining")
        check(valid.snapshot?.fiveHour?.resetDisplay == "02-29 23:59",
              "leap-day reset text preserved without year inference")

        let seven = hubWindow(.sevenDay, percentText: "已使用 37.5%", amount: "$3.75 / $10.00")
        let both = hubParse(hubObservation(first: hubPass(five: hubWindow(), fiveMarker: true,
                                                           seven: seven, sevenMarker: true),
                                          second: hubPass(five: hubWindow(), fiveMarker: true,
                                                           seven: seven, sevenMarker: true)))
        check(both.status == .connected && both.snapshot?.fiveHour != nil && both.snapshot?.sevenDay != nil,
              "5h and 7d are independently represented in one atomic snapshot")

        let monthOnly = TokenHubMonthlyObservation(amountText: "$4.25")
        let monthly = hubParse(hubObservation(first: hubPass(monthlyCount: 1, monthly: monthOnly),
                                              second: hubPass(monthlyCount: 1, monthly: monthOnly)))
        check(monthly.status == .connected && monthly.snapshot?.monthly?.usedAmount == Decimal(string: "4.25"),
              "monthly used amount accepted")
        check(monthly.snapshot?.monthly != nil, "monthly model contains only used amount; no fabricated limit")

        let missingSeven = hubParse(hubObservation(first: hubPass(five: hubWindow(), fiveMarker: true),
                                                   second: hubPass(five: hubWindow(), fiveMarker: true)))
        check(missingSeven.status == .connected && missingSeven.snapshot?.sevenDay == nil,
              "wholly absent 7d group accepted as unknown")
        let brokenPartner = hubPass(five: hubWindow(amount: nil), fiveMarker: true)
        let malformed = hubParse(hubObservation(first: brokenPartner, second: brokenPartner))
        check(malformed.snapshot == nil && malformed.failure == .malformedPresentField(.fiveHour),
              "present 5h marker with missing amount rejects whole refresh")
        let validSeven = hubWindow(.sevenDay)
        let progressOnlyFive = hubPass(fiveMarker: true, seven: validSeven, sevenMarker: true)
        let progressOnlyResult = hubParse(hubObservation(first: progressOnlyFive, second: progressOnlyFive))
        check(progressOnlyResult.snapshot == nil &&
              progressOnlyResult.failure == .malformedPresentField(.fiveHour),
              "5h progress-only marker with valid 7d sibling rejects whole snapshot")
        let missingFiveReset = hubPass(five: hubWindow(reset: nil), fiveMarker: true,
                                       seven: validSeven, sevenMarker: true)
        let missingFiveResetResult = hubParse(hubObservation(first: missingFiveReset,
                                                              second: missingFiveReset))
        check(missingFiveResetResult.snapshot == nil &&
              missingFiveResetResult.failure == .malformedPresentField(.fiveHour),
              "missing 5h reset cannot borrow valid 7d reset")
        let brokenMonthly = hubParse(hubObservation(first: hubPass(monthlyCount: 1),
                                                    second: hubPass(monthlyCount: 1)))
        check(brokenMonthly.snapshot == nil && brokenMonthly.failure == .malformedPresentField(.monthly),
              "present monthly container without amount rejects whole refresh")
        let partialPartnerCases = [
            hubWindow(titleSeen: false), hubWindow(percentText: nil),
            hubWindow(includeExpectedProgressLabel: false), hubWindow(progress: nil),
            hubWindow(resetSeen: false), hubWindow(reset: nil), hubWindow(amount: nil)
        ]
        for partial in partialPartnerCases {
            let pass = hubPass(five: partial, fiveMarker: true)
            check(hubParse(hubObservation(first: pass, second: pass)).snapshot == nil,
                  "each missing required 5h partner rejects a marked-present window")
        }
        let malformedWithValidSibling = hubPass(five: hubWindow(amount: "$NaN / $10"), fiveMarker: true,
                                                seven: seven, sevenMarker: true)
        let siblingRejected = hubParse(hubObservation(first: malformedWithValidSibling,
                                                      second: malformedWithValidSibling))
        check(siblingRejected.snapshot == nil,
              "malformed 5h rejects entire refresh despite valid 7d sibling")
        let duplicateGroupPass = hubPass(five: hubWindow(), fiveMarker: true, groupCount: 2)
        check(hubParse(hubObservation(first: duplicateGroupPass, second: duplicateGroupPass)).snapshot == nil,
              "duplicate quota container rejects whole read")
        let duplicateMonthPass = hubPass(five: hubWindow(), fiveMarker: true,
                                         monthlyCount: 2, monthly: monthOnly)
        check(hubParse(hubObservation(first: duplicateMonthPass, second: duplicateMonthPass)).snapshot == nil,
              "duplicate monthly container rejects whole read")
        let noFieldsPass = hubPass()
        let noFields = hubParse(hubObservation(first: noFieldsPass, second: noFieldsPass))
        check(noFields.snapshot == nil && noFields.failure == .noQuotaFields,
              "all wholly absent quota fields report unavailable")

        let invalidWindows: [(TokenHubWindowObservation, String)] = [
            (hubWindow(amount: "$-1 / $10"), "negative amount"),
            (hubWindow(amount: "$1.001 / $10"), "too many decimal places"),
            (hubWindow(amount: "$1,00 / $10"), "invalid grouping"),
            (hubWindow(amount: "¥1.00 / $10.00"), "unsupported or mixed currency symbol"),
            (hubWindow(amount: "$1e999 / $10"), "exponent amount format"),
            (hubWindow(amount: "$1 / $0"), "zero limit"),
            (hubWindow(amount: "$11 / $10"), "used above limit"),
            (hubWindow(percentText: "已使用 101%"), "text percentage out of range"),
            (hubWindow(progress: Decimal(1000)), "progress out of range"),
            (hubWindow(percentText: "已使用 40%", progress: Decimal(37)), "text and progress disagree"),
            (hubWindow(reset: "02-30 23:59"), "invalid reset date"),
            (hubWindow(reset: "2026-02-29T23:59Z"), "reset is not source short text"),
            (hubWindow(progressLabel: "wrong label"), "unexpected progress label")
        ]
        for (window, label) in invalidWindows {
            let pass = hubPass(five: window, fiveMarker: true)
            let result = hubParse(hubObservation(first: pass, second: pass))
            check(result.snapshot == nil && result.failure == .malformedPresentField(.fiveHour),
                  "malformed present field rejects entire snapshot: \(label)")
        }

        let maxAmount = hubWindow(amount: "$999,999,999,999,999.99 / $1,000,000,000,000,000.00")
        let maxPass = hubPass(five: maxAmount, fiveMarker: true)
        check(hubParse(hubObservation(first: maxPass, second: maxPass)).status == .connected,
              "maximum supported Decimal amount and valid grouping accepted")
        let overMax = hubWindow(amount: "$1,000,000,000,000,000.01 / $1,000,000,000,000,000.02")
        let overPass = hubPass(five: overMax, fiveMarker: true)
        check(hubParse(hubObservation(first: overPass, second: overPass)).snapshot == nil,
              "amount beyond maximum rejected")

        let changed = hubPass(five: hubWindow(percentText: "已使用 38%", progress: Decimal(38)), fiveMarker: true)
        let mismatch = hubParse(hubObservation(first: hubPass(five: hubWindow(), fiveMarker: true), second: changed))
        check(mismatch.snapshot == nil && mismatch.failure == .doubleReadMismatch,
              "two complete passes must normalize identically")

        let firstEquivalent = hubPass(five: hubWindow(percentText: "已使用 37.5%",
            amount: "$1.00 / $10.00", progress: Decimal(string: "37.5")), fiveMarker: true)
        let secondEquivalent = hubPass(five: hubWindow(percentText: "已使用 37.50%",
            amount: "$1 / $10", progress: Decimal(string: "37.50")), fiveMarker: true)
        let normalizedEqual = hubParse(hubObservation(first: firstEquivalent, second: secondEquivalent))
        check(normalizedEqual.status == .connected &&
              normalizedEqual.snapshot?.fiveHour?.usedAmount == Decimal(1) &&
              normalizedEqual.snapshot?.fiveHour?.limitAmount == Decimal(10) &&
              normalizedEqual.snapshot?.fiveHour?.usedPercent == Decimal(string: "37.5"),
              "two valid passes with equivalent Decimal values and presentation precision normalize equally")

        let actuallyChanged = hubPass(five: hubWindow(percentText: "已使用 37.5%",
            amount: "$1.01 / $10.00", progress: Decimal(string: "37.5")), fiveMarker: true)
        let changedAmount = hubParse(hubObservation(first: firstEquivalent, second: actuallyChanged))
        check(changedAmount.snapshot == nil && changedAmount.failure == .doubleReadMismatch,
              "two valid passes with a materially changed amount are rejected")
        let invalidSecond = hubPass(five: hubWindow(percentText: "已使用 37.5%",
            amount: "$1.000 / $10.00", progress: Decimal(string: "37.5")), fiveMarker: true)
        let invalidNormalized = hubParse(hubObservation(first: firstEquivalent, second: invalidSecond))
        check(invalidNormalized.snapshot == nil,
              "an invalid second pass cannot normalize equal to a valid first pass")

        let wrong = TokenHubIdentity(pid: 422, bundleID: TokenHubTarget.bundleID,
                                     executablePath: hubIdentity.executablePath)
        let wrongPass = hubPass(five: hubWindow(), fiveMarker: true, identity: wrong)
        let identityResult = hubParse(hubObservation(first: wrongPass, second: wrongPass))
        check(identityResult.snapshot == nil, "root identity mismatch rejects snapshot")
        let revoked = hubParse(hubObservation(trusted: false))
        check(revoked.snapshot == nil && revoked.failure == .permissionMissing,
              "pure observation with denied trust has no snapshot")
        let multiple = hubParse(hubObservation(targets: [hubIdentity, wrong]))
        check(multiple.snapshot == nil && multiple.failure == .multipleTargets,
              "multiple matching process candidates fail closed")
        let otherBundle = TokenHubIdentity(pid: 421, bundleID: "untrusted.fixture.app",
                                           executablePath: hubIdentity.executablePath)
        let noTarget = hubParse(hubObservation(targets: [otherBundle]))
        check(noTarget.snapshot == nil && noTarget.failure == .noTarget,
              "wrong bundle is not treated as an eligible target")
        let otherPath = TokenHubIdentity(pid: 421, bundleID: TokenHubTarget.bundleID,
                                         executablePath: "/tmp/replaced/Hub")
        let replacedPath = hubParse(hubObservation(after: otherPath))
        check(replacedPath.snapshot == nil && replacedPath.failure == .identityChanged,
              "normalized executable path change invalidates read")
        let edgeTolerance = hubWindow(percentText: "已使用 37.6%", progress: Decimal(string: "37.5"))
        let edgePass = hubPass(five: edgeTolerance, fiveMarker: true)
        check(hubParse(hubObservation(first: edgePass, second: edgePass)).status == .connected,
              "text/progress percentage difference exactly 0.1 is accepted")
        let beyondTolerance = hubWindow(percentText: "已使用 37.7%", progress: Decimal(string: "37.5"))
        let beyondPass = hubPass(five: beyondTolerance, fiveMarker: true)
        check(hubParse(hubObservation(first: beyondPass, second: beyondPass)).snapshot == nil,
              "text/progress percentage difference above 0.1 is rejected")

        let exactBounds: [(TokenHubTraversalSummary, String)] = [
            (hubSummary(visits: 512), "512 cumulative visits"),
            (hubSummary(depth: 16), "depth 16"),
            (hubSummary(children: 64), "64 children"),
            (hubSummary(longest: 256), "256 character string"),
            (hubSummary(text: 8192), "8192 aggregate characters"),
            (hubSummary(elapsed: 3.0), "3 seconds total"),
            (hubSummary(slowest: 0.15), "0.15 seconds element message")
        ]
        for (summary, label) in exactBounds {
            check(hubParse(hubObservation(summary: summary)).status == .connected,
                  "exact R15 budget boundary accepted: \(label)")
        }
        let exceededBounds: [(TokenHubTraversalSummary, String, TokenHubQuotaFailure)] = [
            (hubSummary(visits: 513), "513 cumulative visits", .nodeBudgetExceeded),
            (hubSummary(depth: 17), "depth 17", .depthBudgetExceeded),
            (hubSummary(children: 65), "65 children", .childBudgetExceeded),
            (hubSummary(longest: 257), "257 character string", .textBudgetExceeded),
            (hubSummary(text: 8193), "8193 aggregate characters", .textBudgetExceeded),
            (hubSummary(elapsed: 3.001), "over 3 seconds total", .timeBudgetExceeded),
            (hubSummary(slowest: 0.151), "over 0.15 seconds element message", .elementTimeout)
        ]
        for (summary, label, failure) in exceededBounds {
            let result = hubParse(hubObservation(summary: summary))
            check(result.snapshot == nil && result.failure == failure,
                  "over-budget input fails entire refresh: \(label)")
        }

        let forbiddenTrace: [TokenHubReadEvent] = [
            .targets, .root, .identity(1), .role(1), .groupDescription(2), .groupTitle(2),
            .children(2), .staticText(3), .progressLabel(4), .progressValue(4)
        ]
        let allowedTrace = hubParse(hubObservation(trace: forbiddenTrace))
        check(allowedTrace.status == .connected, "synthetic allowlisted read trace accepted")
        // The event enum intentionally has no arbitrary-attribute, window-title, URL,
        // input/secure-value, action, or global traversal case; compiler-enforced surface.
    }
}

// Recording synthetic tree used by scanner-path checks. Node ids and values are invented;
// the reader cannot access ApplicationServices or the desktop session.
private struct HubFixtureNode {
    var role: TokenHubAXRole
    var identity: TokenHubIdentity
    var label: String?
    var children: [Int] = []
    var text: String?
    var progressLabel: String?
    var progress: Decimal?
    var truncated = false
    var failsChildren = false
}

private final class HubRecordingReader: TokenHubBoundedTreeReading {
    var nodes: [Int: HubFixtureNode]
    var events: [TokenHubReadEvent] = []
    var valueReadsBeforeQuotaGroup = false
    var quotaGroupWasIdentified = false
    var messageDuration: TimeInterval = 0
    private(set) var readTextCharacterCount = 0
    private var paddingPass = 0
    private var paddingValues: [Int: (String, String)] = [:]
    let selected = CoreChecks.hubIdentity
    let targetList: [TokenHubIdentity]

    init(nodes: [Int: HubFixtureNode], targets: [TokenHubIdentity]? = nil) {
        self.nodes = nodes
        targetList = targets ?? [CoreChecks.hubIdentity]
    }
    private func enforce(_ timeout: TimeInterval) throws {
        if messageDuration > timeout { throw NSError(domain: "HubFixtureTimeout", code: 124) }
    }
    func exactBundleTargets(bundleID: String) throws -> [TokenHubIdentity] {
        events.append(.targets)
        return targetList.filter { $0.bundleID == bundleID }
    }
    func rootNode(for identity: TokenHubIdentity, timeout: TimeInterval) throws -> Int {
        try enforce(timeout)
        events.append(.root); return 1
    }
    func identity(of node: Int, timeout: TimeInterval) throws -> TokenHubIdentity {
        try enforce(timeout)
        events.append(.identity(node)); return nodes[node]?.identity ?? selected
    }
    func role(of node: Int, timeout: TimeInterval) throws -> TokenHubAXRole {
        try enforce(timeout)
        events.append(.role(node)); return nodes[node]?.role ?? .other("missing")
    }
    func groupLabel(of node: Int, kind: TokenHubGroupLabelKind, timeout: TimeInterval) throws -> String? {
        try enforce(timeout)
        events.append(kind == .description ? .groupDescription(node) : .groupTitle(node))
        let value = nodes[node]?.label
        readTextCharacterCount += value?.count ?? 0
        if value == "用量和限额" { quotaGroupWasIdentified = true }
        return value
    }
    func children(of node: Int, maximum: Int, timeout: TimeInterval) throws -> TokenHubChildrenPage {
        try enforce(timeout)
        events.append(.children(node))
        guard let value = nodes[node] else { throw NSError(domain: "HubFixture", code: 1) }
        if value.failsChildren { throw NSError(domain: "HubFixture", code: 2) }
        return TokenHubChildrenPage(nodes: Array(value.children.prefix(maximum)),
                                    isTruncated: value.truncated || value.children.count > maximum)
    }
    func staticText(of node: Int, maximumCharacters: Int, timeout: TimeInterval) throws -> String? {
        try enforce(timeout)
        events.append(.staticText(node))
        if !quotaGroupWasIdentified { valueReadsBeforeQuotaGroup = true }
        if node == 3 { paddingPass += 1 }
        let value: String?
        if let pair = paddingValues[node] { value = paddingPass <= 1 ? pair.0 : pair.1 }
        else { value = nodes[node]?.text }
        readTextCharacterCount += value?.count ?? 0
        return value
    }
    func progressLabel(of node: Int, timeout: TimeInterval) throws -> String? {
        try enforce(timeout)
        events.append(.progressLabel(node)); let value = nodes[node]?.progressLabel
        readTextCharacterCount += value?.count ?? 0; return value
    }
    func progressValue(of node: Int, timeout: TimeInterval) throws -> Decimal? {
        try enforce(timeout)
        events.append(.progressValue(node)); return nodes[node]?.progress
    }

    static func valid() -> HubRecordingReader {
        let id = CoreChecks.hubIdentity
        var tree: [Int: HubFixtureNode] = [:]
        tree[1] = HubFixtureNode(role: .application, identity: id, children: [20, 90, 91])
        tree[20] = HubFixtureNode(role: .other("AXScrollArea"), identity: id, children: [21])
        tree[21] = HubFixtureNode(role: .other("AXWebArea"), identity: id, children: [2])
        tree[2] = HubFixtureNode(role: .group, identity: id, label: "用量和限额",
                                 children: [3, 4, 5, 6, 7, 8, 9, 10])
        tree[3] = HubFixtureNode(role: .staticText, identity: id, text: "5 小时限额 已使用 37.5%")
        tree[4] = HubFixtureNode(role: .staticText, identity: id, text: "$3.75 / $10.00")
        tree[5] = HubFixtureNode(role: .staticText, identity: id, text: "额度")
        tree[6] = HubFixtureNode(role: .progressIndicator, identity: id,
                                 progressLabel: "5 小时限额已用比例", progress: Decimal(string: "37.5"))
        tree[7] = HubFixtureNode(role: .staticText, identity: id, text: "重置")
        tree[8] = HubFixtureNode(role: .staticText, identity: id, text: "02-29 23:59")
        tree[9] = HubFixtureNode(role: .staticText, identity: id, text: "时间")
        tree[10] = HubFixtureNode(role: .progressIndicator, identity: id,
                                 progressLabel: "重置进度", progress: Decimal(99))
        tree[90] = HubFixtureNode(role: .staticText, identity: id, text: "outside quota poison")
        tree[91] = HubFixtureNode(role: .button, identity: id, children: [92])
        tree[92] = HubFixtureNode(role: .secureText, identity: id, text: "must-never-be-read")
        return HubRecordingReader(nodes: tree)
    }

    func addUnrelatedGroups(_ childCounts: [Int]) {
        var root = nodes[1]!
        var nextID = 1_000
        for count in childCounts {
            let groupID = nextID; nextID += 1
            var children: [Int] = []
            for _ in 0..<count {
                let childID = nextID; nextID += 1; children.append(childID)
                nodes[childID] = HubFixtureNode(role: .button, identity: selected)
            }
            nodes[groupID] = HubFixtureNode(role: .group, identity: selected, children: children)
            root.children.append(groupID)
        }
        nodes[1] = root
    }

    func addGroupChain(toDepth targetDepth: Int) {
        var root = nodes[1]!
        let firstID = 3_000
        root.children.append(firstID)
        nodes[1] = root
        var current = firstID
        for depth in 1...targetDepth {
            let child = depth == targetDepth ? nil : current + 1
            nodes[current] = HubFixtureNode(role: .group, identity: selected,
                children: child.map { [$0] } ?? [])
            if let child { current = child }
        }
    }

    func addLabelGroup(length: Int) {
        var root = nodes[1]!
        let groupID = 4_000
        root.children.append(groupID)
        nodes[1] = root
        nodes[groupID] = HubFixtureNode(role: .group, identity: selected,
            label: String(repeating: "x", count: length))
    }

    func addQuotaPadding(firstPassCharacters: Int, secondPassCharacters: Int) {
        var group = nodes[2]!
        var nextID = 6_000
        func chunks(_ count: Int) -> [String] {
            var remainder = count, result: [String] = []
            while remainder > 0 {
                let size = min(256, remainder)
                result.append(String(repeating: " ", count: size)); remainder -= size
            }
            return result
        }
        let first = chunks(firstPassCharacters), second = chunks(secondPassCharacters)
        for index in 0..<max(first.count, second.count) {
            let id = nextID; nextID += 1; group.children.append(id)
            nodes[id] = HubFixtureNode(role: .staticText, identity: selected)
            paddingValues[id] = (index < first.count ? first[index] : "",
                                 index < second.count ? second[index] : "")
        }
        nodes[2] = group
    }

    func addMonthlyGroup(amounts: [String]) {
        var quotaGroup = nodes[2]!
        let groupID = 7_000
        var children: [Int] = []
        for (index, amount) in amounts.enumerated() {
            let nodeID = 7_001 + index; children.append(nodeID)
            nodes[nodeID] = HubFixtureNode(role: .staticText, identity: selected, text: amount)
        }
        nodes[groupID] = HubFixtureNode(role: .group, identity: selected,
            label: "月度用量", children: children)
        quotaGroup.children.append(groupID); nodes[2] = quotaGroup
    }

    func addSevenDayWindow(reset: String? = "03-01 01:00") {
        var quotaGroup = nodes[2]!
        let values: [(Int, HubFixtureNode)] = [
            (110, HubFixtureNode(role: .staticText, identity: selected, text: "7 天限额 已使用 40%")),
            (111, HubFixtureNode(role: .staticText, identity: selected, text: "$4.00 / $10.00")),
            (112, HubFixtureNode(role: .staticText, identity: selected, text: "额度")),
            (113, HubFixtureNode(role: .progressIndicator, identity: selected,
                progressLabel: "7 天限额已用比例", progress: Decimal(40))),
            (114, HubFixtureNode(role: .staticText, identity: selected, text: "重置")),
            (115, HubFixtureNode(role: .staticText, identity: selected, text: reset)),
            (116, HubFixtureNode(role: .staticText, identity: selected, text: "时间"))
        ]
        for (id, node) in values { nodes[id] = node; quotaGroup.children.append(id) }
        nodes[2] = quotaGroup
    }
}

extension CoreChecks {
    static func hubScannerChecks() throws {
        let reader = HubRecordingReader.valid()
        let result = TokenHubQuotaScanner().scan(using: reader, now: Date(timeIntervalSince1970: 1_800_000_000),
            monotonicNow: { 10 }, permissionTrusted: true, refreshSeconds: 60,
            mode: .localCodex, generation: 1)
        check(result.status == .connected && result.snapshot != nil, "bounded synthetic tree scan succeeds")
        check(!reader.valueReadsBeforeQuotaGroup, "scanner does not read leaf content before unique container discovery")
        check(!reader.events.contains(.staticText(90)), "scanner never reads unrelated text outside quota group")
        check(!reader.events.contains(.staticText(92)), "scanner never descends into button/secure-field subtree")
        check(!reader.events.contains(.progressValue(10)), "reset-progress value is never treated as quota")
        check(reader.events.contains(.children(20)) && reader.events.contains(.children(21)),
              "scanner safely traverses AXScrollArea and AXWebArea ancestors")
        check(reader.events.filter { if case .staticText = $0 { return true }; return false }.count == 12,
              "two passes read six supported static-text fields, including the decorative quota label")
        check(reader.events.filter { if case .progressValue = $0 { return true }; return false }.count == 2,
              "two passes read the approved progress value only")
        let deniedReader = HubRecordingReader.valid()
        let denied = TokenHubQuotaScanner().scan(using: deniedReader, now: Date(timeIntervalSince1970: 1_800_000_000),
            monotonicNow: { 10 }, permissionTrusted: false, refreshSeconds: 60,
            mode: .localCodex, generation: 2)
        check(denied.snapshot == nil && denied.failure == .permissionMissing,
              "scanner accepts injected trust boolean without requesting OS permission")
        check(deniedReader.events.isEmpty, "denied trust performs no target/tree operations")
        let proxyReader = HubRecordingReader.valid()
        let proxy = TokenHubQuotaScanner().scan(using: proxyReader, now: Date(timeIntervalSince1970: 1_800_000_000),
            monotonicNow: { 10 }, permissionTrusted: true, refreshSeconds: 60,
            mode: .proxy, generation: 3)
        check(proxy.snapshot == nil, "proxy mode never selects the AX source")
        check(proxyReader.events.isEmpty, "proxy mode performs no AX target/tree operations")

        let wrongBundle = TokenHubIdentity(pid: 421, bundleID: "other.fixture.bundle",
                                           executablePath: CoreChecks.hubIdentity.executablePath)
        let noTargetReader = HubRecordingReader(nodes: HubRecordingReader.valid().nodes, targets: [wrongBundle])
        let noTarget = TokenHubQuotaScanner().scan(using: noTargetReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 4)
        check(noTarget.failure == .noTarget && noTargetReader.events == [.targets],
              "wrong-bundle target fails before reading an AX root")

        let changedReader = HubRecordingReader.valid()
        var wrongNode = changedReader.nodes[4]!
        wrongNode.identity = TokenHubIdentity(pid: 999, bundleID: CoreChecks.hubIdentity.bundleID,
                                               executablePath: CoreChecks.hubIdentity.executablePath)
        changedReader.nodes[4] = wrongNode
        let changedResult = TokenHubQuotaScanner().scan(using: changedReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 5)
        check(changedResult.failure == .elementPIDMismatch && changedResult.snapshot == nil,
              "every visited node is checked against selected PID")

        let truncatedReader = HubRecordingReader.valid()
        var truncatedRoot = truncatedReader.nodes[1]!; truncatedRoot.truncated = true
        truncatedReader.nodes[1] = truncatedRoot
        check(TokenHubQuotaScanner().scan(using: truncatedReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 6).snapshot == nil,
            "truncated children page rejects whole refresh")

        let errorReader = HubRecordingReader.valid()
        var errorRoot = errorReader.nodes[1]!; errorRoot.failsChildren = true
        errorReader.nodes[1] = errorRoot
        check(TokenHubQuotaScanner().scan(using: errorReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 7).snapshot == nil,
            "children API error rejects whole refresh")
        let timeoutReader = HubRecordingReader.valid(); timeoutReader.messageDuration = 0.151
        let timeoutResult = TokenHubQuotaScanner().scan(using: timeoutReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8)
        check(timeoutResult.snapshot == nil, "element message exceeding 0.15s fails closed")
        let exactMessageReader = HubRecordingReader.valid(); exactMessageReader.messageDuration = 0.15
        check(TokenHubQuotaScanner().scan(using: exactMessageReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8).status == .connected,
            "scanner permits an element message exactly at 0.15 seconds")

        let exactChildrenReader = HubRecordingReader.valid()
        var rootAtChildLimit = exactChildrenReader.nodes[1]!
        rootAtChildLimit.children = [2]
        for id in 5_000..<5_063 {
            rootAtChildLimit.children.append(id)
            exactChildrenReader.nodes[id] = HubFixtureNode(role: .group,
                identity: CoreChecks.hubIdentity)
        }
        exactChildrenReader.nodes[1] = rootAtChildLimit
        check(TokenHubQuotaScanner().scan(using: exactChildrenReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8).status == .connected,
            "scanner accepts exactly 64 children for one node")
        let overChildrenReader = HubRecordingReader.valid()
        var rootOverChildLimit = overChildrenReader.nodes[1]!
        for id in 5_000..<5_062 {
            rootOverChildLimit.children.append(id)
            overChildrenReader.nodes[id] = HubFixtureNode(role: .group,
                identity: CoreChecks.hubIdentity)
        }
        overChildrenReader.nodes[1] = rootOverChildLimit
        let overChildren = TokenHubQuotaScanner().scan(using: overChildrenReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8)
        check(overChildren.snapshot == nil, "scanner fails closed when root has 65 children")

        let depth16Reader = HubRecordingReader.valid(); depth16Reader.addGroupChain(toDepth: 16)
        check(TokenHubQuotaScanner().scan(using: depth16Reader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8).status == .connected,
            "scanner accepts traversal reaching exact depth 16")
        let depth17Reader = HubRecordingReader.valid(); depth17Reader.addGroupChain(toDepth: 17)
        let depth17 = TokenHubQuotaScanner().scan(using: depth17Reader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8)
        check(depth17.snapshot == nil, "scanner rejects traversal beyond depth 16")

        let label256Reader = HubRecordingReader.valid(); label256Reader.addLabelGroup(length: 256)
        check(TokenHubQuotaScanner().scan(using: label256Reader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8).status == .connected,
            "scanner accepts a 256-character non-quota container label")
        let label257Reader = HubRecordingReader.valid(); label257Reader.addLabelGroup(length: 257)
        check(TokenHubQuotaScanner().scan(using: label257Reader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8).snapshot == nil,
            "scanner rejects a 257-character string")

        let charCalibrationReader = HubRecordingReader.valid()
        _ = TokenHubQuotaScanner().scan(using: charCalibrationReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8)
        let baseAggregateCharacters = charCalibrationReader.readTextCharacterCount
        let charsToAdd = 8192 - baseAggregateCharacters
        let exactTextReader = HubRecordingReader.valid()
        exactTextReader.addQuotaPadding(firstPassCharacters: charsToAdd / 2,
                                        secondPassCharacters: charsToAdd - charsToAdd / 2)
        let exactText = TokenHubQuotaScanner().scan(using: exactTextReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8)
        check(exactText.status == .connected && exactTextReader.readTextCharacterCount == 8192,
              "scanner accepts exactly 8192 aggregate characters across discovery and both reads")
        let overTextReader = HubRecordingReader.valid()
        overTextReader.addQuotaPadding(firstPassCharacters: charsToAdd / 2,
                                       secondPassCharacters: charsToAdd - charsToAdd / 2 + 1)
        let overText = TokenHubQuotaScanner().scan(using: overTextReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8)
        check(overText.snapshot == nil && overText.failure == .textBudgetExceeded &&
              overTextReader.readTextCharacterCount <= 8193,
              "scanner fails closed at the 8193rd aggregate character")

        let duplicateReader = HubRecordingReader.valid()
        var duplicateRoot = duplicateReader.nodes[1]!
        var duplicate = duplicateReader.nodes[2]!; duplicateReader.nodes[93] = duplicate
        duplicateRoot.children.append(93); duplicateReader.nodes[1] = duplicateRoot
        let duplicateResult = TokenHubQuotaScanner().scan(using: duplicateReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8)
        check(duplicateResult.failure == .duplicateQuotaGroup && duplicateReader.events.filter {
            if case .staticText = $0 { return true }; if case .progressValue = $0 { return true }; return false
        }.isEmpty, "duplicate quota containers discovered before any leaf value read")

        let duplicateWindowReader = HubRecordingReader.valid()
        var duplicateWindowGroup = duplicateWindowReader.nodes[2]!
        duplicateWindowGroup.children.append(94)
        duplicateWindowReader.nodes[2] = duplicateWindowGroup
        duplicateWindowReader.nodes[94] = HubFixtureNode(role: .staticText,
            identity: CoreChecks.hubIdentity, text: "5 小时限额 已使用 37.5%")
        let duplicateWindow = TokenHubQuotaScanner().scan(using: duplicateWindowReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 9)
        check(duplicateWindow.failure == .duplicateWindow(.fiveHour) && duplicateWindow.snapshot == nil,
              "duplicate window marker rejects scanner result")

        let duplicateAmountReader = HubRecordingReader.valid()
        var amountGroup = duplicateAmountReader.nodes[2]!
        amountGroup.children.append(95)
        duplicateAmountReader.nodes[2] = amountGroup
        duplicateAmountReader.nodes[95] = HubFixtureNode(role: .staticText,
            identity: CoreChecks.hubIdentity, text: "$3.75 / $10.00")
        let duplicateAmount = TokenHubQuotaScanner().scan(using: duplicateAmountReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 9)
        check(duplicateAmount.snapshot == nil &&
              duplicateAmount.failure == .malformedPresentField(.fiveHour),
              "duplicate 5h amount rows reject whole scanner result")

        let bothWindowsReader = HubRecordingReader.valid(); bothWindowsReader.addSevenDayWindow()
        let bothWindows = TokenHubQuotaScanner().scan(using: bothWindowsReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 9)
        check(bothWindows.status == .connected && bothWindows.snapshot?.fiveHour != nil &&
              bothWindows.snapshot?.sevenDay != nil,
              "scanner accepts valid 5h and 7d sibling windows atomically")

        for brokenReset in [nil, "02-30 23:59"] {
            let resetReader = HubRecordingReader.valid()
            resetReader.addSevenDayWindow()
            var missingOrMalformed = resetReader.nodes[8]!
            missingOrMalformed.text = brokenReset
            resetReader.nodes[8] = missingOrMalformed
            let resetResult = TokenHubQuotaScanner().scan(using: resetReader,
                now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
                permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 9)
            check(resetResult.snapshot == nil &&
                  resetResult.failure == .malformedPresentField(.fiveHour),
                  "5h reset missing or malformed cannot borrow valid 7d reset")
        }

        let validMonthlyReader = HubRecordingReader.valid(); validMonthlyReader.addMonthlyGroup(amounts: ["$4.25"])
        let validMonthlyScan = TokenHubQuotaScanner().scan(using: validMonthlyReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 9)
        check(validMonthlyScan.status == .connected && validMonthlyScan.snapshot?.monthly?.usedAmount == Decimal(string: "4.25"),
              "scanner accepts monthly used-only amount in its unique container")
        let duplicateMonthlyReader = HubRecordingReader.valid()
        duplicateMonthlyReader.addMonthlyGroup(amounts: ["$4.25", "$7.00"])
        let duplicateMonthlyScan = TokenHubQuotaScanner().scan(using: duplicateMonthlyReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 9)
        check(duplicateMonthlyScan.snapshot == nil &&
              duplicateMonthlyScan.failure == .malformedPresentField(.monthly),
              "multiple monthly amount rows reject the entire scanner result")

        let replacedRootReader = HubRecordingReader.valid()
        var replacedRoot = replacedRootReader.nodes[1]!
        replacedRoot.identity = TokenHubIdentity(pid: 421, bundleID: CoreChecks.hubIdentity.bundleID,
            executablePath: "/Applications/Replaced.app/Contents/MacOS/Hub")
        replacedRootReader.nodes[1] = replacedRoot
        let replacedRootResult = TokenHubQuotaScanner().scan(using: replacedRootReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 9)
        check(replacedRootResult.failure == .identityChanged && replacedRootResult.snapshot == nil,
              "target replacement during scan rejects result")

        // Calibrate filler groups from the baseline trace, then exercise the *scanner's*
        // shared node-visit budget across discovery and both reads (including revisits).
        let baselineReader = HubRecordingReader.valid()
        _ = TokenHubQuotaScanner().scan(using: baselineReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 9)
        let baselineVisits = baselineReader.events.reduce(0) { total, event in
            if case .identity = event { return total + 1 }; return total
        }
        func padding(for target: Int) -> [Int]? {
            let delta = target - baselineVisits
            guard delta >= 1 else { return nil }
            let groupCount = min(8, delta)
            let childCount = delta - groupCount
            guard childCount <= groupCount * 64 else { return nil }
            var remainder = childCount
            return (0..<groupCount).map { _ in
                let value = min(64, remainder); remainder -= value; return value
            }
        }
        if let exactPadding = padding(for: 512) {
            let exactReader = HubRecordingReader.valid(); exactReader.addUnrelatedGroups(exactPadding)
            let exactResult = TokenHubQuotaScanner().scan(using: exactReader,
                now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
                permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 10)
            check(exactResult.status == .connected, "scanner permits exactly 512 cumulative node visits")
        } else { check(false, "fixture can construct exact 512 cumulative visits") }
        if let overPadding = padding(for: 513) {
            let overReader = HubRecordingReader.valid(); overReader.addUnrelatedGroups(overPadding)
            let overResult = TokenHubQuotaScanner().scan(using: overReader,
                now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
                permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 11)
            check(overResult.failure == .nodeBudgetExceeded && overResult.snapshot == nil,
                  "scanner rejects the 513th cumulative visit")
        } else { check(false, "fixture can construct 513 cumulative visits") }

        var calibrationClockCalls = 0
        _ = TokenHubQuotaScanner().scan(using: HubRecordingReader.valid(),
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: {
                calibrationClockCalls += 1; return 10
            }, permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 12)
        let clockIntervals = max(1, calibrationClockCalls - 1)
        var exactClockCalls = 0
        let exactTime = TokenHubQuotaScanner().scan(using: HubRecordingReader.valid(),
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: {
                exactClockCalls += 1
                return 10 + 3 * Double(exactClockCalls - 1) / Double(clockIntervals)
            }, permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 12)
        check(exactTime.status == .connected, "scanner permits exactly 3 seconds shared elapsed time")

        var overClockCalls = 0
        let overTime = TokenHubQuotaScanner().scan(using: HubRecordingReader.valid(),
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: {
                overClockCalls += 1
                return 10 + 3.001 * Double(overClockCalls - 1) / Double(clockIntervals)
            }, permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 12)
        check(overTime.failure == .timeBudgetExceeded && overTime.snapshot == nil,
              "scanner uses injected monotonic clock and rejects over 3 seconds")
    }
}
```

### Tests/TokenStatUITests/TokenHubQuotaStateTests.swift

```swift
import AppKit
import SwiftUI
import XCTest
import TokenStatCore
@testable import TokenStatMenu

private final class HubTestScanner: TokenHubQuotaScanning {
    private let lock = NSLock()
    private var storedResult: TokenHubQuotaResult
    var nextResult: TokenHubQuotaResult {
        get { lock.lock(); defer { lock.unlock() }; return storedResult }
        set { lock.lock(); storedResult = newValue; lock.unlock() }
    }
    var started: (() -> Void)?
    var beforeReturn: (() -> Void)?
    private var activeCount = 0
    private(set) var maximumConcurrent = 0
    private(set) var calls = 0
    init(result: TokenHubQuotaResult) { storedResult = result }

    func scan(now: Date, monotonicNow: () -> TimeInterval, permissionTrusted: Bool,
              refreshSeconds: TimeInterval, mode: TokenHubRunMode,
              generation: UInt64) -> TokenHubQuotaResult {
        lock.lock(); calls += 1; activeCount += 1
        maximumConcurrent = max(maximumConcurrent, activeCount)
        let result = storedResult
        lock.unlock()
        started?(); beforeReturn?()
        lock.lock(); activeCount -= 1; lock.unlock()
        return result
    }
}

private final class HubTestPermission: TokenHubPermissionProviding {
    var trusted = true
    private(set) var requests = 0
    func isTrusted() -> Bool { trusted }
    func requestOnceAndOpenSystemSettings() { requests += 1 }
}

private final class HubManualClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
final class TokenHubQuotaStateTests: XCTestCase {
    private let identity = TokenHubIdentity(pid: 924, bundleID: TokenHubTarget.bundleID,
        executablePath: "/Applications/Synthetic Hub.app/Contents/MacOS/Hub")

    private func result(now: Date) -> TokenHubQuotaResult {
        let window = TokenHubWindowObservation(titleSeen: true,
            usedPercentText: "已使用 37.5%", amountText: "$3.75 / $10.00",
            progressLabel: "5 小时限额已用比例", progressValue: Decimal(string: "37.5")!,
            resetLabelSeen: true, resetText: "02-29 23:59")
        let seven = TokenHubWindowObservation(titleSeen: true,
            usedPercentText: "已使用 40%", amountText: "$4.00 / $10.00",
            progressLabel: "7 天限额已用比例", progressValue: Decimal(40),
            resetLabelSeen: true, resetText: "03-01 01:00")
        let pass = TokenHubQuotaPass(rootIdentity: identity, quotaGroupCount: 1,
            fiveHourMarkerSeen: true, fiveHour: window, sevenDayMarkerSeen: true,
            sevenDay: seven, monthlyContainerCount: 1,
            monthly: TokenHubMonthlyObservation(amountText: "$12.50"))
        let observation = TokenHubQuotaObservation(permissionTrusted: true, targets: [identity],
            before: identity, after: identity, first: pass, second: pass,
            traversal: TokenHubTraversalSummary(nodeVisits: 30, maximumDepth: 5,
                maximumChildrenForAnyNode: 8, longestStringCharacters: 30,
                textCharacters: 100, elapsed: 0.1, slowestElementMessage: 0.01), accessTrace: [])
        return TokenHubQuotaParser.parse(observation, now: now, refreshSeconds: 60)
    }

    private func configuredModel(_ value: TokenHubQuotaResult, clock: HubManualClock)
        -> (AppModel, HubTestScanner, HubTestPermission) {
        let model = AppModel(preview: true)
        model.config.dataSource = "localCodex"
        model.config.refreshSeconds = 60
        model.tokenHubAutomaticReadingEnabled = true
        model.tokenHubNow = { clock.now }
        let scanner = HubTestScanner(result: value)
        let permission = HubTestPermission()
        model.tokenHubScanner = scanner
        model.tokenHubPermissionProvider = permission
        return (model, scanner, permission)
    }

    private func refresh(_ model: AppModel, scanner: HubTestScanner) async {
        let completed = expectation(description: "synthetic scanner completed")
        scanner.started = { completed.fulfill() }
        model.refreshTokenHubQuota()
        await fulfillment(of: [completed], timeout: 2)
        for _ in 0..<100 {
            if model.tokenHubQuotaStatus == .connected && model.tokenHubQuotaSnapshot != nil { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("AppModel did not apply the completed synthetic scan")
    }

    private func settle(_ model: AppModel, status: TokenHubQuotaStatus) async {
        for _ in 0..<100 {
            if model.tokenHubQuotaStatus == status { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("AppModel did not reach expected state \(status)")
    }

    func testFixtureSuppressesOnlyNativeScannerAndSettingsMergeKeepsLiveToggle() {
        XCTAssertTrue(AppModel.shouldSuppressNativeTokenHubRead(isTestFixture: true, scannerIsNative: true))
        XCTAssertFalse(AppModel.shouldSuppressNativeTokenHubRead(isTestFixture: true, scannerIsNative: false),
                       "fixture mode must retain synthetic scanner injection for deterministic state tests")
        XCTAssertFalse(AppModel.shouldSuppressNativeTokenHubRead(isTestFixture: false, scannerIsNative: true))

        let model = AppModel(preview: true)
        defer { model.shutdown() }
        model.config.dataSource = "localCodex"
        model.tokenHubAutomaticReadingEnabled = false
        let scanner = HubTestScanner(result: TokenHubQuotaResult(status: .targetNotRunning, snapshot: nil, failure: nil))
        model.tokenHubScanner = scanner

        var staleEnabledDraft = AppConfiguration()
        staleEnabledDraft.model = "saved-other-setting"
        staleEnabledDraft.tokenHubAutomaticReadingEnabled = true
        let savedDisabled = AppModel.configurationForApplying(staleEnabledDraft, automaticReadingEnabled: false)
        XCTAssertFalse(savedDisabled.tokenHubAutomaticReadingEnabled,
                       "a stale enabled draft cannot overwrite a newer off toggle")
        XCTAssertEqual(savedDisabled.model, "saved-other-setting", "saving another field remains effective")
        XCTAssertEqual(scanner.calls, 0, "disabled merge is pure and cannot schedule a synthetic or native scan")

        model.tokenHubAutomaticReadingEnabled = true
        var staleDisabledDraft = AppConfiguration()
        staleDisabledDraft.model = "second-saved-setting"
        staleDisabledDraft.tokenHubAutomaticReadingEnabled = false
        let savedEnabled = AppModel.configurationForApplying(staleDisabledDraft, automaticReadingEnabled: true)
        XCTAssertTrue(savedEnabled.tokenHubAutomaticReadingEnabled,
                      "a stale disabled draft cannot overwrite a newer on toggle")
        XCTAssertEqual(savedEnabled.model, "second-saved-setting", "the second unrelated setting is preserved")
        XCTAssertEqual(scanner.calls, 0, "configuration reconciliation itself performs no scan")
    }

    func testHubSnapshotFreshnessAndTokenAccountingIsolation() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = HubManualClock(now)
        let (model, scanner, _) = configuredModel(result(now: now), clock: clock)
        defer { model.shutdown() }
        let before = model.stats
        await refresh(model, scanner: scanner)
        XCTAssertEqual(model.tokenHubQuotaSnapshot?.identity, identity)
        XCTAssertNotNil(model.freshTokenHubQuota(at: now))
        XCTAssertEqual(model.stats.total, before.total, "monetary quota cannot alter token totals")
        XCTAssertEqual(model.stats.input, before.input)
        XCTAssertEqual(model.stats.output, before.output)
        XCTAssertNil(model.freshTokenHubQuota(at: now.addingTimeInterval(121)),
                     "snapshot expires after max(120s, refresh interval × 2)")
        XCTAssertNil(model.freshTokenHubQuota(at: now.addingTimeInterval(-1)),
                     "future local observation is not current")
    }

    func testDisablePermissionLossAndProxyModeClearSnapshot() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = HubManualClock(now)
        let (model, scanner, permission) = configuredModel(result(now: now), clock: clock)
        defer { model.shutdown() }
        await refresh(model, scanner: scanner)
        XCTAssertNotNil(model.tokenHubQuotaSnapshot)
        model.setTokenHubAutomaticReadingEnabled(false)
        XCTAssertNil(model.tokenHubQuotaSnapshot, "disable clears displayed snapshot synchronously")

        model.setTokenHubAutomaticReadingEnabled(true)
        scanner.nextResult = result(now: now)
        await refresh(model, scanner: scanner)
        clock.now = clock.now.addingTimeInterval(2.1)
        permission.trusted = false
        model.refreshTokenHubQuota()
        await settle(model, status: .permissionRequired)
        XCTAssertNil(model.tokenHubQuotaSnapshot, "permission loss clears snapshot")

        clock.now = clock.now.addingTimeInterval(2.1)
        permission.trusted = true
        await refresh(model, scanner: scanner)
        model.config.dataSource = "proxy"
        model.refreshTokenHubQuota()
        await settle(model, status: .disabled)
        XCTAssertNil(model.tokenHubQuotaSnapshot, "proxy mode cannot retain or select AX quota")
        XCTAssertEqual(permission.requests, 0, "normal tests and refresh never request OS trust")
    }

    func testPanelAndMenuExposeSourceAndCurrencyCaveatsWithoutAmountsInDiagnostics() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (model, scanner, _) = configuredModel(result(now: now), clock: HubManualClock(now))
        defer { model.shutdown() }
        await refresh(model, scanner: scanner)
        let text = model.menuTooltip + " " + model.dataNotice
        XCTAssertTrue(text.contains("Token Hub 界面快照"))
        XCTAssertTrue(text.contains("后台更新时间未提供"))
        XCTAssertTrue(text.contains("币种未核验"))
        XCTAssertFalse(model.message.contains("3.75"), "raw quota amount must not enter diagnostics")
        XCTAssertFalse(model.message.contains("37.5"), "raw percentage must not enter diagnostics")
    }

    func testTokenHubDecimalDisplayPreservesFractionsAtModelAndCardCallsites() async {
        let now = Date()
        let (model, scanner, _) = configuredModel(result(now: now), clock: HubManualClock(now))
        defer { model.shutdown() }
        await refresh(model, scanner: scanner)
        XCTAssertTrue(model.title.contains("5h剩 62.5%"), "the actual menu title must retain a fractional remaining percent")
        XCTAssertTrue(model.menuTooltip.contains("界面显示剩余 62.5%"), "the actual tooltip must retain a fractional remaining percent")

        let snapshot = try! XCTUnwrap(model.tokenHubQuotaSnapshot)
        XCTAssertEqual(TokenHubDecimalFormatter.string(snapshot.fiveHour!.usedAmount), "3.75",
                       "the card amount formatter must not round a window amount to an integer")
        XCTAssertEqual(TokenHubDecimalFormatter.string(snapshot.monthly!.usedAmount), "12.5",
                       "the card amount formatter must preserve monthly fractional value")
        XCTAssertEqual(TokenHubDecimalFormatter.string(Decimal(string: "0.01")!), "0.01",
                       "the shared amount/percentage formatter must retain small fractional values")
    }

    func testFailedScanClearsSnapshotAndShutdownRejectsLateResult() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (model, scanner, _) = configuredModel(result(now: now), clock: HubManualClock(now))
        defer { model.shutdown() }
        await refresh(model, scanner: scanner)
        XCTAssertNotNil(model.tokenHubQuotaSnapshot)

        scanner.nextResult = TokenHubQuotaResult(status: .accessFailed, snapshot: nil, failure: .axError)
        let failed = expectation(description: "failed synthetic scanner completed")
        scanner.started = { failed.fulfill() }
        model.refreshTokenHubQuota()
        await fulfillment(of: [failed], timeout: 2)
        await settle(model, status: .accessFailed)
        XCTAssertNil(model.tokenHubQuotaSnapshot, "failed scan clears prior snapshot")

        scanner.nextResult = result(now: now)
        let started = expectation(description: "late scan started")
        let release = DispatchSemaphore(value: 0)
        scanner.started = { started.fulfill() }
        scanner.beforeReturn = { release.wait() }
        model.refreshTokenHubQuota()
        await fulfillment(of: [started], timeout: 2)
        model.shutdown()
        release.signal()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(model.tokenHubQuotaSnapshot, "shutdown rejects a late scanner completion")
    }

    func testSingleInflightRefreshNeverOverlaps() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (model, scanner, _) = configuredModel(result(now: now), clock: HubManualClock(now))
        defer { model.shutdown() }
        let started = expectation(description: "one scan started")
        let release = DispatchSemaphore(value: 0)
        scanner.started = { started.fulfill() }
        scanner.beforeReturn = { release.wait() }
        model.refreshTokenHubQuota()
        await fulfillment(of: [started], timeout: 2)
        model.refreshTokenHubQuota()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(scanner.calls, 1, "a second refresh cannot overlap an in-flight scan")
        release.signal()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(scanner.maximumConcurrent, 1)
    }

    func testMetadataLifecycleEventsInvalidateOldGenerationAndGateRelaunch() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (model, scanner, permission) = configuredModel(result(now: now), clock: HubManualClock(now))
        defer { model.shutdown() }
        await refresh(model, scanner: scanner)
        let initial = try! XCTUnwrap(model.tokenHubQuotaSnapshot)

        model.tokenHubApplicationDidTerminate(bundleIdentifier: "unrelated.fixture.app")
        model.tokenHubApplicationDidLaunch(bundleIdentifier: "unrelated.fixture.app")
        XCTAssertEqual(model.tokenHubQuotaSnapshot, initial, "unrelated app metadata cannot invalidate the selected target")

        let blocked = expectation(description: "old generation scan started")
        let release = DispatchSemaphore(value: 0)
        scanner.started = { blocked.fulfill() }
        scanner.beforeReturn = { release.wait() }
        model.refreshTokenHubQuota()
        await fulfillment(of: [blocked], timeout: 2)

        model.tokenHubApplicationDidTerminate(bundleIdentifier: TokenHubTarget.bundleID)
        XCTAssertNil(model.tokenHubQuotaSnapshot, "selected target exit clears its interface snapshot synchronously")
        XCTAssertEqual(model.tokenHubQuotaStatus, .targetNotRunning)
        model.tokenHubApplicationDidLaunch(bundleIdentifier: TokenHubTarget.bundleID)
        XCTAssertNil(model.tokenHubQuotaSnapshot, "launch metadata alone cannot make an old snapshot current")
        XCTAssertEqual(model.tokenHubQuotaStatus, .targetNotRunning)

        scanner.nextResult = TokenHubQuotaResult(status: .accessFailed, snapshot: nil, failure: .axError)
        scanner.started = nil
        scanner.beforeReturn = nil
        release.signal()
        await settle(model, status: .accessFailed)
        XCTAssertNil(model.tokenHubQuotaSnapshot, "blocked pre-exit success cannot repopulate after target relaunch")
        XCTAssertEqual(scanner.calls, 3, "relaunch performs a new read after the blocked generation exits")
        XCTAssertEqual(permission.requests, 0, "metadata lifecycle handling never requests OS trust")

        model.setTokenHubAutomaticReadingEnabled(false)
        let callsBeforeDisabledLaunch = scanner.calls
        model.tokenHubApplicationDidLaunch(bundleIdentifier: TokenHubTarget.bundleID)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.tokenHubQuotaStatus, .disabled)
        XCTAssertEqual(scanner.calls, callsBeforeDisabledLaunch, "disabled mode does not scan on target launch")

        let (untrustedModel, untrustedScanner, untrustedPermission) = configuredModel(
            result(now: now), clock: HubManualClock(now))
        defer { untrustedModel.shutdown() }
        untrustedPermission.trusted = false
        untrustedModel.tokenHubApplicationDidLaunch(bundleIdentifier: TokenHubTarget.bundleID)
        XCTAssertEqual(untrustedModel.tokenHubQuotaStatus, .permissionRequired)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(untrustedScanner.calls, 0, "untrusted target launch does not schedule a scan")
        XCTAssertEqual(untrustedPermission.requests, 0, "untrusted lifecycle event does not request trust")
    }

    func testDashboardRendersSyntheticHubQuotaCardOffline() async throws {
        let now = Date()
        let (model, scanner, permission) = configuredModel(result(now: now), clock: HubManualClock(now))
        defer { model.shutdown() }
        await refresh(model, scanner: scanner)
        XCTAssertEqual(permission.requests, 0, "synthetic dashboard render never requests OS trust")

        let bounds = NSRect(x: 0, y: 0, width: 460, height: 700)
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/c13-render", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua),
                                             ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua)] {
            let root = DashboardView(model: model)
                .environment(\.colorScheme, scheme)
                .frame(width: 460, height: 700)
            let hostingView = NSHostingView(rootView: root)
            hostingView.frame = bounds
            let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hostingView
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.displayIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: bounds) else {
                window.close(); XCTFail("synthetic Hub dashboard bitmap should be available"); return
            }
            hostingView.cacheDisplay(in: bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
            let pixelScale = Int(window.backingScaleFactor.rounded())
            XCTAssertEqual(decoded.pixelsWide, 460 * pixelScale)
            XCTAssertEqual(decoded.pixelsHigh, 700 * pixelScale)
            XCTAssertGreaterThan(png.count, 0)
            try png.write(to: output.appendingPathComponent("synthetic-tokenhub-\(name).png"))
            window.close()
        }

        let cardBounds = NSRect(x: 0, y: 0, width: 460, height: 280)
        for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua),
                                             ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua)] {
            let card = TokenHubQuotaCard(snapshot: model.tokenHubQuotaSnapshot,
                status: model.tokenHubQuotaStatusText, enabled: true, refreshSeconds: 60)
                .environment(\.colorScheme, scheme)
                .frame(width: 460, height: 280, alignment: .topLeading)
                .groupBoxStyle(PanelCardStyle())
            let hostingView = NSHostingView(rootView: card)
            hostingView.frame = cardBounds
            let window = NSWindow(contentRect: cardBounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hostingView
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.displayIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: cardBounds) else {
                window.close(); XCTFail("synthetic full-card bitmap should be available"); return
            }
            hostingView.cacheDisplay(in: cardBounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
            let pixelScale = Int(window.backingScaleFactor.rounded())
            XCTAssertEqual(decoded.pixelsWide, 460 * pixelScale)
            XCTAssertEqual(decoded.pixelsHigh, 280 * pixelScale)
            XCTAssertGreaterThan(png.count, 0)
            try png.write(to: output.appendingPathComponent("synthetic-tokenhub-full-card-\(name).png"))
            window.close()
        }
        print("Synthetic Token Hub dashboard renders: \(output.path)/synthetic-tokenhub-light.png and synthetic-tokenhub-dark.png")
        print("Synthetic full-card renders: \(output.path)/synthetic-tokenhub-full-card-light.png and synthetic-tokenhub-full-card-dark.png")
        XCTAssertTrue(model.menuTooltip.contains("界面显示剩余"))
        XCTAssertTrue(model.menuTooltip.contains("币种未核验"))
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
                "month": datetime.datetime.now().strftime("%Y-%m"),
                "five_hour": {"used_percent": 25, "resets_at": int(time.time()) + 3600},
                "seven_day": {"used_percent": 70, "resets_at": int(time.time()) + 86400}}})
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
import socket
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
    config = {"dataSource": "proxy", "endpoint": "http://127.0.0.1:19877/v1/chat/completions", "port": 19876,
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
        assert ui["fiveHourUsedPercent"] == 25 and ui["sevenDayUsedPercent"] == 70, ui
        assert ui["quotaUsed"] == 850000 and ui["alert"] == "yellow", ui
        assert ui["title"] == "测试 T:— · Σ— · 请求0" and ui["statusItemVisible"], ui
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
            def live_title(value):
                title = value.get("title", "")
                if value.get("active") != 3 or not title.startswith("测试 T:≈") or "tok/s" not in title or "Σ" not in title:
                    return None
                speed = title.split("≈", 1)[1].split("tok/s", 1)[0]
                try:
                    return value if float(speed) > 0 else None
                except ValueError:
                    return None
            ui = wait_for(lambda: (r if (r := json.loads(diagnostic.read_text())) and live_title(r) else None))
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
                plistlib.dump({"port": 19876, "dataSource": "proxy"}, handle)
            normal_diagnostic = WORK / "normal-ui.json"
            normal_command = command.copy()
            normal_command.remove("--test-fixture")
            normal_command[normal_command.index(str(WORK / "config.plist"))] = str(normal_config)
            normal_command[normal_command.index(str(diagnostic))] = str(normal_diagnostic)
            subprocess.run(normal_command, check=True)
            normal = wait_for(lambda: json.loads(normal_diagnostic.read_text()))
            assert normal["title"] == "T:— · Σ— · 请求0" and not normal["isTestFixture"], normal
            assert not normal["hasRequestData"] and "未采集" in normal["dataNotice"], normal
            assert normal.get("fiveHourUsedPercent") is None and normal.get("sevenDayUsedPercent") is None, normal
            assert normal.get("quotaUsed") is None and normal["alert"] == "normal", normal
            print("PASS: fixture clearly labeled; normal startup has no inherited usage or quota", flush=True)

            # Local-source startup uses an isolated CODEX_HOME fixture and never resolves proxy credentials.
            subprocess.run(["pkill", "-x", "TokenStatMenu"], capture_output=True)
            local_home = WORK / "local-codex"
            session_dir = local_home / "sessions" / "2026" / "10" / "17"
            session_dir.mkdir(parents=True)
            session_meta = {"type": "session_meta", "payload": {
                "id": "12345678-1234-4234-8234-123456789abc", "source": "cli"}}
            event = {"timestamp": "2026-10-17T03:00:00Z", "type": "event_msg", "payload": {
                "type": "token_count", "info": {"total_token_usage": {
                    "input_tokens": 23, "output_tokens": 7, "total_tokens": 30}}, "rate_limits": {}}}
            (session_dir / "rollout-fixture-12345678-1234-4234-8234-123456789abc.jsonl").write_text(
                json.dumps(session_meta) + "\n" + json.dumps(event) + "\n")
            local_config = WORK / "local.plist"
            with local_config.open("wb") as handle:
                plistlib.dump({"port": 19879, "dataSource": "localCodex"}, handle)
            local_diagnostic = WORK / "local-ui.json"
            local_command = ["open", "-n", str(ROOT / "dist/TokenStatMenu.app"),
                "--env", "CODEX_HOME=" + str(local_home), "--args", "--config", str(local_config),
                "--test-fixture", "--disable-discovery", "--diagnostics-output", str(local_diagnostic)]
            subprocess.run(local_command, check=True)
            local = wait_for(lambda: (r if (r := json.loads(local_diagnostic.read_text())).get("hasRequestData") else None))
            assert local["title"] == "测试 上轮均:— · Σ30 · 1顶层对话" and local["isTestFixture"], local
            assert "模拟测试" in local["dataNotice"], local
            assert not local["tokenHubPermissionGranted"] and not local["tokenHubPermissionRequired"], local
            assert (local.get("quotaUsed") is None and local.get("fiveHourUsedPercent") is None
                and local.get("sevenDayUsedPercent") is None), local
            with socket.socket() as probe:
                probe.settimeout(0.5)
                assert probe.connect_ex(("127.0.0.1", 19879)) != 0, "local source must not start the proxy listener"
            print("PASS: synthetic nested local Codex startup is ready without proxy listener or inherited quota", flush=True)
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
import sys

root = Path(__file__).resolve().parents[1]
sources = sorted((root / "Sources").rglob("*.swift"))
sources = [str(p) for p in sources if p.name != "TokenStatMenuApp.swift"]
binary = root / ".build/preview-renderer"
binary.parent.mkdir(exist_ok=True)
subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-module-name", "TokenStatMenuPreview", *sources, str(root / "script/RenderPreview.swift"), "-o", str(binary)], check=True)
if "--focus-diagnostic" in sys.argv:
    subprocess.run([str(binary), str(root / "dist/focus-previews"), "--test-fixture", "--focus-diagnostic"], check=True)
else:
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
        model.config.dataSource = "proxy"
        model.panelVisible = true
        model.stats.requests = 12; model.stats.input = 64000; model.stats.output = 12000
        model.stats.active = 1; model.stats.outputTPS = 24.5; model.stats.inputWaitTPS = 3800
        model.stats.estimatedRequests = 1; model.stats.costUSD = 0.088
        model.config.inputPrice = 1; model.config.outputPrice = 2
        model.config.usageURL = "https://gateway.example/usage"
        let month = QuotaSnapshot.currentMonth()
        model.quota = try QuotaSnapshot.parse(Data("{\"data\":{\"used_tokens\":640000,\"total_tokens\":1000000,\"month\":\"\(month)\"}}".utf8), config: model.config)
        model.quotaError = ""
        let windows = try QuotaReport.parse(JSONSerialization.data(withJSONObject: ["data": [
            "five_hour": ["used_percent": 25, "resets_at": Date().addingTimeInterval(7200).timeIntervalSince1970],
            "seven_day": ["used_percent": 70, "resets_at": Date().addingTimeInterval(172800).timeIntervalSince1970]
        ]]), config: model.config)
        model.fiveHourQuota = windows.fiveHour; model.sevenDayQuota = windows.sevenDay
        model.gateways = [GatewayDiscovery.candidate(baseURL: "https://gateway.example/route", provider: "示例网关", source: "虚构本机配置", model: "example-model", isActive: true)!]
        model.discoveryStatus = "模拟候选 · 不读取实际配置"
        model.history = (0..<60).map { i in SpeedPoint(date: Date().addingTimeInterval(Double(i - 60)), value: 20 + sin(Double(i) * 0.3) * 6) }
        if CommandLine.arguments.contains("--focus-diagnostic") {
            try renderFocusedPopovers(model, to: output)
            return
        }
        let normalWindows = (model.fiveHourQuota, model.sevenDayQuota)
        for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", .dark, .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            model.fiveHourQuota = normalWindows.0; model.sevenDayQuota = normalWindows.1
            for settings in [false, true] {
                try render(model, settings: settings, scheme: scheme, appearance: appearance,
                    name: "\(name)-\(settings ? "settings" : "dashboard")", to: output)
            }

            model.fiveHourQuota = nil; model.sevenDayQuota = nil
            try render(model, settings: false, scheme: scheme, appearance: appearance,
                name: "\(name)-dashboard-quota-missing", to: output)

            let staleNow = Date().addingTimeInterval(-1000)
            let staleWindows = try QuotaReport.parse(JSONSerialization.data(withJSONObject: ["data": [
                "five_hour": ["used_percent": 25, "resets_at": Date().addingTimeInterval(3600).timeIntervalSince1970],
                "seven_day": ["used_percent": 70, "resets_at": Date().addingTimeInterval(86400).timeIntervalSince1970]
            ]]), config: model.config, now: staleNow)
            model.fiveHourQuota = staleWindows.fiveHour; model.sevenDayQuota = staleWindows.sevenDay
            try render(model, settings: false, scheme: scheme, appearance: appearance,
                name: "\(name)-dashboard-quota-expired", to: output)
        }
        model.config.dataSource = "localCodex"
        model.localSnapshot = LocalCodexSnapshot(input: 12_345, output: 6_789, total: 19_134,
            sessionCount: 3, filesScanned: 3, isLimited: false, latestEventAt: Date(),
            fiveHour: normalWindows.0, sevenDay: normalWindows.1)
        for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", .dark, .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            try render(model, settings: false, scheme: scheme, appearance: appearance,
                name: "local-codex-\(name)-dashboard", to: output)
        }
        print("Rendered proxy and populated local Codex views from offline synthetic fixtures; no configuration, credentials or network accessed")
    }

    @MainActor private static func render(_ model: AppModel, settings: Bool, scheme: ColorScheme,
                                          appearance: NSAppearance.Name, name: String, to output: URL) throws {
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
        if settings { verifySettingsScroll(in: host, panelWidth: bounds.width) }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else { throw NSError(domain: "Preview", code: 1) }
        host.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "Preview", code: 2) }
        window.close()
        try png.write(to: output.appendingPathComponent("\(name).png"))
    }

    @MainActor private static func verifySettingsScroll(in host: NSView, panelWidth: CGFloat) {
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let candidates = descendants(host).compactMap { $0 as? NSScrollView }.filter { scroll in
            guard let document = scroll.documentView else { return false }
            return scroll.frame.width >= panelWidth * 0.8
                && document.bounds.height > scroll.contentView.bounds.height + 1
        }
        guard let scroll = candidates.max(by: { $0.frame.width < $1.frame.width }),
              let document = scroll.documentView else {
            print("UNVERIFIED settings scroll: no wide native NSScrollView with vertical overflow was exposed")
            return
        }

        let clip = scroll.contentView
        let originalOrigin = clip.bounds.origin
        let originalVisible = scroll.documentVisibleRect
        let viewportSize = clip.bounds.size
        let documentSize = document.bounds.size
        let targetY: CGFloat = document.isFlipped
            ? max(document.bounds.minY, document.bounds.maxY - viewportSize.height)
            : document.bounds.minY
        clip.scroll(to: NSPoint(x: originalOrigin.x, y: targetY))
        scroll.reflectScrolledClipView(clip)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()

        let bottomVisible = scroll.documentVisibleRect
        let reachedBottom = document.isFlipped
            ? bottomVisible.maxY >= document.bounds.maxY - 1
            : bottomVisible.minY <= document.bounds.minY + 1
        let moved = abs(bottomVisible.origin.y - originalVisible.origin.y) > 1

        clip.scroll(to: originalOrigin)
        scroll.reflectScrolledClipView(clip)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        let restoredVisible = scroll.documentVisibleRect
        let restored = abs(restoredVisible.origin.y - originalVisible.origin.y) <= 1
            && abs(restoredVisible.origin.x - originalVisible.origin.x) <= 1
        print(String(format: "Settings scroll: viewport %.1f×%.1f, document %.1f×%.1f, moved=%@, bottomReached=%@, restoredTop=%@",
            viewportSize.width, viewportSize.height, documentSize.width, documentSize.height,
            moved ? "yes" : "no", reachedBottom ? "yes" : "no", restored ? "yes" : "no"))
        guard moved && reachedBottom && restored else {
            fatalError("Settings scroll did not reach the bottom and restore its original position")
        }
    }

    @MainActor private static func renderFocusedPopovers(_ model: AppModel, to output: URL) throws {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let anchorWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 48, height: 32),
                styleMask: [.titled], backing: .buffered, defer: false)
            anchorWindow.isReleasedWhenClosed = false
            anchorWindow.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            let anchor = NSButton(frame: NSRect(x: 8, y: 6, width: 32, height: 20))
            anchor.title = "Fixture"
            anchorWindow.contentView = anchor
            anchorWindow.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))

            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentSize = NSSize(width: 460, height: 700)
            popover.contentViewController = NSHostingController(rootView:
                DashboardView(model: model).environment(\.colorScheme, name == "dark" ? .dark : .light))
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))

            guard let popoverWindow = popover.contentViewController?.view.window,
                  let contentView = popover.contentViewController?.view else {
                print("UNVERIFIED \(name) popover focus: no NSPopover window was exposed")
                anchorWindow.close()
                continue
            }
            let views = descendants(of: contentView)
            let settingsButton = views.compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel()?.contains("连接与设置") == true
            }
            let responder = popoverWindow.firstResponder
            let responderLabel = (responder as? NSView)?.accessibilityLabel() ?? "<unavailable>"
            let settingsFocused = settingsButton.map { responder === $0 } ?? false
            let focusRing = settingsButton.map { String(describing: $0.focusRingType) } ?? "unavailable"
            print("Focus diagnostic \(name): appActive=\(NSApp.isActive), anchorKey=\(anchorWindow.isKeyWindow), keyWindow=\(popoverWindow.isKeyWindow), firstResponder=\(String(describing: type(of: responder))), responderLabel=\(responderLabel), settingsButtonFound=\(settingsButton != nil), settingsButtonFirstResponder=\(settingsFocused), focusRing=\(focusRing)")

            let bounds = contentView.bounds
            contentView.layoutSubtreeIfNeeded()
            guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else { throw NSError(domain: "FocusPreview", code: 1) }
            contentView.cacheDisplay(in: bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "FocusPreview", code: 2) }
            try png.write(to: output.appendingPathComponent("\(name)-focused-popover.png"))
            popover.performClose(nil)
            anchorWindow.close()
        }
        print("Rendered natural key-window NSPopover focus diagnostics from simulated fixtures only; first responder was not forced")
    }

    @MainActor private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
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
    ".gitignore", ".github/workflows/build.yml", "Package.swift", "Package.resolved", "README.md", "LICENSE", "PRIVACY.md",
    "Sources/TokenStatCore/Configuration.swift", "Sources/TokenStatCore/GatewayDiscovery.swift",
    "Sources/TokenStatCore/HTTPDecoder.swift", "Sources/TokenStatCore/LocalCodexUsageReader.swift", "Sources/TokenStatCore/MetricsEngine.swift",
    "Sources/TokenStatCore/ProxyServer.swift", "Sources/TokenStatCore/Quota.swift",
    "Sources/TokenStatCore/WindowQuota.swift", "Sources/TokenStatCore/RateWindow.swift", "Sources/TokenStatCore/StreamParser.swift",
    "Sources/TokenStatCore/TokenHubQuota.swift", "Sources/TokenStatCore/TokenHubAXScanning.swift",
    "Sources/TokenStatMenu/AppModel.swift", "Sources/TokenStatMenu/DashboardView.swift",
    "Sources/TokenStatMenu/QuotaClient.swift", "Sources/TokenStatMenu/SettingsView.swift",
    "Sources/TokenStatMenu/StatusBarController.swift", "Sources/TokenStatMenu/Storage.swift",
    "Sources/TokenStatMenu/TokenStatMenuApp.swift", "Sources/TokenStatMenu/PanelStyle.swift", "Sources/TokenStatMenu/WindowQuotaCard.swift", "Sources/TokenStatMenu/TokenHubAXReader.swift", "Sources/TokenStatMenu/TokenHubQuotaCard.swift",
    "Resources/Info.plist", "Resources/config.example.plist", "TokenStatMenu.xcodeproj/project.pbxproj",
    "Tests/TokenStatCoreTests/CoreChecks.swift", "Tests/TokenStatCoreTests/GatewayDiscoveryChecks.swift", "Tests/TokenStatCoreTests/WindowQuotaChecks.swift", "Tests/TokenStatCoreTests/LocalCodexUsageChecks.swift",
    "Tests/TokenStatUITests/TokenStatUISnapshotTests.swift", "Tests/TokenStatCoreTests/TokenHubQuotaChecks.swift", "Tests/TokenStatUITests/TokenHubQuotaStateTests.swift",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testDashboardLightAndDark.dashboard-light.png",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testDashboardLightAndDark.dashboard-dark.png",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testSettingsLightAndDark.settings-light.png",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testSettingsLightAndDark.settings-dark.png",
    "script/build_and_run.sh", "script/test.sh", "script/mock_server.py", "script/integration.py",
    "script/generate_xcode_project.py", "script/render_preview.py", "script/RenderPreview.swift", "script/package_source.py", "script/check_public_content.py",
    "docs/DESIGN.md", "docs/IMPLEMENTATION.md", "docs/CONFIGURATION.md", "docs/VALIDATION.md", "docs/UI_TESTING.md", "docs/FULL_SOURCE.md",
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

SYNTHETIC_PNG_SHA256 = {
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testDashboardLightAndDark.dashboard-light.png": "e03aa7d784ce5d11b8994b99fa781e560e68c51764ab80396c6bfa91c9f848d0",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testDashboardLightAndDark.dashboard-dark.png": "0713582fbfbeafd295fec11f9f062d929b03aa24ece2c625fb6213af51e3eb79",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testSettingsLightAndDark.settings-light.png": "ead37da0bb4717d1cd62c040218cf82a0aef02147874ebce0865d325194b32a3",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testSettingsLightAndDark.settings-dark.png": "49dad314d7714198f49031f9c47714f5ad7a87bd88595edea1713d0003ee372a",
}


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
        if name in SYNTHETIC_PNG_SHA256:
            import hashlib
            if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                failures.append((name, 0, "reviewed synthetic PNG signature mismatch")); continue
            if hashlib.sha256(data).hexdigest() != SYNTHETIC_PNG_SHA256[name]:
                failures.append((name, 0, "reviewed synthetic PNG hash mismatch")); continue
            continue
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

首次启动默认使用本机 Codex 记录：每次后台扫描完成后等待 5 秒再扫描，未变化文件仅校验元数据并复用内存中的数值摘要，只枚举已知 sessions 目录内最多 5,000 个目录项，在枚举范围按修改时间排序选取最多 32 个物理文件；不是整个账户最新 32 个对话的保证。每文件读取头部最多 64 KiB 与尾部最多 256 KiB，重叠不重复读取，单次总量最多 10 MiB。没有有效计量事件时显示未知，不把缺失当作零。未配置的新安装使用本机来源；已有明确代理配置保持代理模式。

### 自动读取 Token Hub 额度

1. 将编译好的 App 放在固定位置，例如 `~/Applications/TokenStatMenu.app`，打开并保持本机 Codex 来源。
2. 在 Token Hub 中正常登录，并使“用量和限额”区域可访问。TokenStatMenu 不操作登录、刷新、滚动或切换页面。
3. 点击 App 提供的辅助功能授权入口，在 **系统设置 → 隐私与安全性 → 辅助功能** 中开启 **TokenStatMenu**。正常启动不会自动弹出权限请求。
4. 授权后自动检测目标并按刷新间隔读取；无需填写 API Endpoint、API Key、模型或 JSON 字段。可以在设置中关闭自动读取。

面板明确标记“Token Hub 界面快照”，显示本地读取时间和“后台更新时间未提供”。5 小时和 7 天的“界面显示剩余”来自各自的已用百分比，菜单栏追加可用窗口的简写；重置时间保留来源的 `MM-dd HH:mm`，不猜年份、时区或倒计时。金额保留 `$` 符号并标记“币种未核验”，不换算为 Token、Token 成本或 USD/CNY；月度只显示来源提供的已用金额，未提供的上限和剩余保持未知。这些界面快照不触发企业用量颜色告警。

关闭自动读取、切换来源、撤销权限、应用退出、读取失败或结构不支持时，旧快照会清空；不会用历史记录或另一个窗口补齐缺失值。连续两遍读取的规范化结果一致才接受。刷新在后台串行执行，一次最多 512 次节点访问、深度 16、每节点 64 个孩子、单文本 256 字符、总文本 8192 字符及整轮 3 秒，不累积任务。

辅助功能授权属于 macOS 对当前应用的许可，需要你完成一次系统开关。此项目默认 ad hoc 签名，更新构建后系统可能要求重新授权；保持安装路径固定也不能保证永久授权。应用不会修改 TCC 数据库、自动授权或读取其他应用的保存凭据。

以下步骤用于需要流式速度估算的**代理模式**，先在设置中切换数据来源：

1. 点击菜单栏统计文字 → **设置**。
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

### 本机记录身份与计量范围

- 逻辑线程身份来自文件第一条完整 `session_meta.payload.id`，不使用文件名尾部 UUID：同一线程的不同 rollout 文件可能有不同文件名。祖先 metadata 不覆盖首条身份。
- 同 inode 或能在预算内证明全文一致的副本只计一次；同一线程存在内容冲突或无法完整比较的版本时，整组标为未核算，不按修改时间猜哪份正确。
- 根线程使用最后有效累计作为来源记录量。它可能受上游上下文处理影响，不是企业计费流水。最后明确累计损坏时不会偷偷采用旧值。
- 复制式分叉只在初始化边界、继承基线及最终累计间的记录完整连续时，逐项计算输入、输出、总量的差。缺失、回退、越界或中间未读取时标为未核算。引用式父历史目前未核算，不减去父线程当前总量，也不把子线程继承量重复加入。
- 小计保留可核算线程的值，未知项不会当作零。达到扫描上限时也不显示成完整 `Σ`。这些限制会导致无法提供完整历史总量，界面会如实说明。
- `rate_limits` 缺失或为 `null` 表示没有新的额度证据，不清除已读范围内的历史快照；合法显式空对象 `{}` 清除，合法非空窗口对象整体替换，不补接其他事件的窗口。异常对象被拒绝。本地记录没有提供的 5 小时窗口仍是未知。

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
- 月度映射字段 `usedPath` / `limitPath` 是 Token 数量；5 小时与 7 天映射字段分别是 0–100 的 `used_percent`，重置时间可用 Unix 秒或 ISO 8601。也接受同一接口中的 Codex `rateLimits` 格式，并按 300 / 10080 分钟识别窗口；窗口缺失或过期时显示未提供/过期，不从月度配额或本机 Token 推算。详见 [配置说明](docs/CONFIGURATION.md)。
- 仅配置接口提供且仍有效的配额达到 80% 时标题黄色、95% 红色，不发通知或弹窗；本地历史快照、过期或异常时间数据不驱动企业额度告警。

## 本机网关自动发现与隐私

本机记录模式仅扫描 `$CODEX_HOME/sessions`（未设置则 `~/.codex/sessions`）。扫描有文件数、枚举数和字节上限，拒绝符号链接；只保留计量数值、时间及扫描状态。会话文件可能含有正文，因此有界读取头部与尾部会短暂接触这些字节，但不会保留、导出或上传正文。仅在内存缓存受限的身份/摘要与计量数值，以验证去重和读取变化；这些标识不进入公开快照或日志。本机模式不读取认证文件或钥匙串，也不启动代理或访问配额接口。

代理模式的网关发现会在启动时及点击“重新扫描”时读取 `$CODEX_HOME/config.toml`（未设置则 `~/.codex/config.toml`），只提取 `model`、`model_provider`、`profile` 以及 provider 的 `base_url`、`wire_api`。支持常见的单行字符串 TOML 与活动 profile；不支持的复杂形式不猜测、不导入。配置文件限制 1MB，不做目录递归扫描。

也识别当前进程中的 `OPENAI_BASE_URL`、`OPENAI_MODEL`、`OLLAMA_HOST`；从 Finder 启动时不一定继承终端环境。不会执行 shell 配置文件。企业客户端只要把自定义 provider 写入上述 Codex 配置，就能通过同一机制被发现；不需要硬编码公司名称或网关域名。

发现结果仅在本机内存和设置页展示，不联网验证，不写入统计日志。点击“填入”后仍需保存；更换 Endpoint 会清空表单中的旧推理/配额密钥及旧用量 URL，避免将旧凭据发给新上游。带 URL 用户名、密码、查询参数或 fragment 的候选整条拒绝导入。认证文件、浏览器数据、其他应用钥匙串和企业后台数据库均不属于发现范围。

发现网关地址不等于认证成功，也不自动接管 Codex 流量。需要认证时，用户仍须通过设置提供自己有权使用的 API Key。项目自己的密钥保存在专用 Keychain 中，并按用途与完整接口 URL 分别绑定；更换接口不会自动复用其他地址的密钥。旧版未绑定地址的密钥不会自动迁移，代理模式需要重新填写；本机记录模式不需要密钥。完整数据处理说明见 [PRIVACY.md](PRIVACY.md)。

企业月度接口通常与推理接口不同；本项目不会猜测计费 URL 或把金额/积分当作 Token。需配置企业文档确认的接口与字段，详见 [配置说明](docs/CONFIGURATION.md)。

## 验证与限制

```bash
./script/test.sh
# 只运行核心检查：
swift run --build-system native TokenStatCoreChecks
```

测试会关闭当前 TokenStatMenu，运行隔离本地配置，使用纯测试令牌；不会访问企业网关。测试通过 `--test-fixture` 参数显式启动，菜单栏加“测试”前缀，面板常显橙色“模拟测试”标记。正常启动尚无流量时显示“未采集”，累计量为 `—`；存在估算请求时累计量带 `≈`。默认结束后关闭测试 App 和 mock 服务。可用 `python3 script/integration.py --keep-running` 保留测试面板作检查，注意面板里都是模拟数据。

测试报告见 `docs/VALIDATION.md`。核心测试是可执行程序，保留仅使用 Command Line Tools 的运行方式。

### UI 视觉回归

已接入 [SnapshotTesting](https://github.com/pointfreeco/swift-snapshot-testing) 1.19.6（MIT），版本和传递依赖记录在 `Package.resolved`。它只属于 SwiftPM 测试目标，正式菜单栏 App 不链接测试库。使用完整 Xcode 运行：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TokenStatUISnapshotTests
```

测试比较真实 SwiftUI 工具栏的浅色、深色及设置状态，共四张已审查的合成参考图。正常测试禁止录制，缺图或图像变化即失败；参考图更新命令见 [UI 测试说明](docs/UI_TESTING.md)。像素参考图要求一致的 macOS 与显示缩放环境；CI 运行不依赖系统外观的校验，桌面视觉比较单独执行。图像快照不等于实际弹出面板的键盘焦点、点击或辅助功能验收。

常见情况：

- **均速一直 —**：本机模式需要在同一有界尾部中找到开始前累计、匹配的轮次开始、轮内用量更新与正常完成。缺少其中任何一项时不计算；历史导入量和扫描间隔不会用来伪造速度。代理模式需确认请求确实经过本机代理并使用本机令牌。
- **5 小时没有数据**：先查看 Token Hub 自动读取的状态：是否已授权、目标是否运行、额度区域是否可访问、界面结构是否支持。界面没有提供的窗口不会从 7 天推算。本地记录中的历史额度仍单独展示；它不是当前企业额度。代理模式则需要接口实际提供独立窗口。
- **企业配额未知**：Token Hub 自动读取只反映可访问界面，后台更新时间及账号归属未经核验；状态异常时显示原因并清空旧值。代理来源需检查用量 URL、独立 Key、字段路径和月份；其月度字段按 Token 解释，不能填写金额字段。独立的 Token Hub 月度卡按来源金额展示，不混入 Token 配额。
- **图标不见**：macOS 可能关闭菜单栏项目或因刘海/其他图标拥挤而隐藏，任何 App 都不能保证绕过系统布局。检查“系统设置 → 菜单栏”。从 Finder 再次打开应用会主动打开面板。
- **关闭面板即退出**：本项目持有 status item 和 app delegate，并显式禁止最后窗口关闭时退出。
- **内存/CPU**：使用原生框架、有限缓冲与低频刷新，不会无限保存回答文本；SwiftUI/Charts 仍有系统开销，不承诺所有机器固定内存值。
- **代理断开**：App 退出后代理端口停止，调用方需恢复原 Endpoint 才能直接访问上游。
- **Xcode 报许可错误**：手动首次打开 Xcode 完成其许可流程。本项目脚本不代替用户接受协议。

纯测试数据必须显式附加 `--test-fixture`，此参数标记模拟来源并隔离原生 Token Hub 读取，不会自行生成数据。调试可显式附加 `--show-panel` 和 `--diagnostics-output /tmp/tokenstat-status.json`，后者每秒输出本地诊断状态和用量摘要，不含密钥/请求正文；Token Hub 界面额度值及带额度数值的菜单后缀不进入诊断，只保留连接或字段是否可用的布尔信息。正常运行没有诊断文件写入。

## 上游格式参考

- [OpenAI Chat API](https://developers.openai.com/api/reference/resources/chat)
- [OpenAI Responses 流事件](https://developers.openai.com/api/reference/resources/responses/streaming-events)
- [Ollama Chat API](https://docs.ollama.com/api/chat)
- [Apple NWListener](https://developer.apple.com/documentation/network/nwlistener)

## 开源

[MIT License](LICENSE)。发现的问题应建立 GitHub Issue，并用虚构域名、模型名与脱敏数据描述复现步骤；Issue 应链接对应修复与验证结果。请勿提交真实企业配置、凭据或日志。欢迎提交 Pull Request。

发布前执行 `python3 script/package_source.py` 重新生成完整源码与源码包，再执行 `python3 script/check_public_content.py` 检查发布清单。Git 提交前使用 `--git-index` 检查实际暂存内容，并人工审查差异；检查脚本不会连接外部服务。

## 界面设计参考

视觉布局参考 [codexU](https://github.com/shanggqm/codexU) 的紧凑圆角卡片、半透明材质与蓝紫色强调。TokenStatMenu 的界面组件独立用 SwiftUI 实现，未复制其源码、图标、截图或配色资源。

离线界面预览：`python3 script/render_preview.py`，在 `dist/previews` 生成浅色/深色概览与设置页图片。预览明确标记模拟数据，使用独立内存模型，不读取本机配置或 Keychain、不发网络请求。
