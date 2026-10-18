# TokenStatMenu 完整源码

## 项目整体架构

```text
AppKit NSStatusItem + NSPopover
  └─ AppModel：专用启动、来源状态、可选偏好与后台调度
      ├─ Token Hub 只读会话交换 → 5 小时／7 天／月度后台额度
      ├─ 当前 provider 与 Hub origin 匹配 → 有界本地 Codex 记录扫描
      │   └─ Token 小计、线程分类、活动速率估算、完整轮次均速
      └─ 已有系统信任下的可选 AX 兼容读取 → 独立界面快照
SwiftUI：概览、数据来源、偏好设置
```

后台额度、界面快照与本地记录各自保留来源语义。后台直接读取不受可选 AX 开关影响；目标退出或身份变化会失效旧结果，重新运行后再识别并读取。正式运行不启动旧代理、不改 Hub／Codex 连接配置，也不调用任意用户填写的企业 URL。

来源流程、计量边界、刷新时效与安全失败条件见 [设计说明](DESIGN.md)。


## 分文件完整源码

### .github/workflows/ci.yml

```yaml
name: macOS CI and release
on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request: {}
permissions:
  contents: read
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: false
jobs:
  build:
    runs-on: macos-15
    env:
      DEVELOPER_DIR: /Applications/Xcode.app/Contents/Developer
      RELEASE_TAG: ${{ github.ref_name }}
      RELEASE_COMMIT: ${{ github.sha }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1 (Node 24)
        with:
          persist-credentials: false
          fetch-depth: 0
      - name: Validate tag, version, source commit and main ancestry
        if: ${{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}
        run: |
          python3 -B script/release_assets.py preflight --tag "$RELEASE_TAG" --commit "$RELEASE_COMMIT"
          echo "RELEASE_VERSION=${RELEASE_TAG#v}" >> "$GITHUB_ENV"
      - name: Documentation links and synthetic checker fixtures
        run: python3 -B script/check_docs.py --self-test
      - name: Public content guardrail
        run: python3 -B script/check_public_content.py --git-index
      - name: Release contract and private native fixtures
        run: python3 -B script/test_release_assets.py
      - name: Core and gateway discovery checks
        run: swift run --force-resolved-versions TokenStatCoreChecks
      - name: Compile UI test target and run OS-independent checks
        run: |
          swift test --force-resolved-versions --filter TokenStatUISnapshotTests.testCredentialAccountNamesAreURLAndPurposeBoundWithoutKeychainIO
          swift test --force-resolved-versions --filter TokenStatUISnapshotTests.testImageMatcherDetectsDeliberateMismatchWithoutRecording
      - name: Native Xcode build
        run: xcodebuild -project TokenStatMenu.xcodeproj -scheme TokenStatMenu -configuration Release -derivedDataPath /tmp/TokenStatMenu-CI CODE_SIGNING_ALLOWED=NO build
      - name: Require unchanged committed dependency lock
        run: git diff --exit-code -- Package.resolved
      - name: Build and ad hoc sign Universal app without launching
        if: ${{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}
        run: ./script/build_and_run.sh --universal
      - name: Export reviewed source and require committed generated document
        if: ${{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}
        run: |
          python3 -B script/package_source.py
          git diff --exit-code
      - name: Package exactly five assets with native checks
        if: ${{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}
        run: python3 -B script/release_assets.py package --tag "$RELEASE_TAG" --commit "$RELEASE_COMMIT" --app dist/TokenStatMenu.app --source dist/TokenStatMenu-source.zip --directory dist/release
      - name: Verify asset identities, payloads and checksums
        if: ${{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}
        run: python3 -B script/release_assets.py verify --tag "$RELEASE_TAG" --commit "$RELEASE_COMMIT" --directory dist/release
      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2 (Node 24)
        if: ${{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}
        with:
          name: tokenstatmenu-release
          if-no-files-found: error
          path: |
            dist/release/TokenStatMenu-${{ env.RELEASE_VERSION }}-universal.zip
            dist/release/TokenStatMenu-${{ env.RELEASE_VERSION }}-source.zip
            dist/release/TokenStatMenu-${{ env.RELEASE_VERSION }}-universal.dmg
            dist/release/release-manifest.json
            dist/release/SHA256SUMS
  publish:
    runs-on: macos-15
    needs: build
    if: ${{ github.repository == 'Tupig/TokenStatMenu' && github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}
    permissions:
      contents: write
    env:
      RELEASE_TAG: ${{ github.ref_name }}
      RELEASE_COMMIT: ${{ github.sha }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1 (Node 24)
        with:
          persist-credentials: false
          fetch-depth: 0
          ref: ${{ github.sha }}
      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2 (Node 24)
        with:
          name: tokenstatmenu-release
          path: dist/release
      - name: Verify downloaded assets against this source before writes
        run: python3 -B script/release_assets.py verify --tag "$RELEASE_TAG" --commit "$RELEASE_COMMIT" --directory dist/release
      - name: Resume matching draft, verify remote bytes and publish
        env:
          GH_TOKEN: ${{ github.token }}
        run: python3 -B script/release_assets.py publish --tag "$RELEASE_TAG" --commit "$RELEASE_COMMIT" --directory dist/release
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

    /// Returns the selected Codex provider and the credential-free origin of
    /// its configured endpoint. Only the origin is used for Seasun route
    /// verification; paths, query strings, and credentials are discarded.
    public static func activeCodexProvider(at url: URL) -> (provider: String, origin: String)? {
        guard let active = readCodexConfig(at: url, source: "local").first(where: \.isActive),
              let origin = originKey(active.endpoint) else { return nil }
        return (active.provider, origin)
    }

    public static func originKey(_ raw: String) -> String? {
        guard let url = URL(string: raw) else { return nil }
        return originKey(url)
    }

    public static func originKey(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !host.contains(":") else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65_535).contains(port) else { return nil }
        return "\(scheme)://\(host):\(port)"
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

public struct LocalCodexSnapshot: Equatable, Sendable {
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
    public let liveTurn: LocalLiveTurnSummary?
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
                subagentCount: Int = 0, forkCount: Int = 0, lastTurn: LocalTurnSummary? = nil,
                liveTurn: LocalLiveTurnSummary? = nil) {
        self.input = input; self.output = output; self.total = total; self.sessionCount = sessionCount
        self.filesScanned = filesScanned; self.isLimited = isLimited; self.latestEventAt = latestEventAt
        self.fiveHour = fiveHour; self.sevenDay = sevenDay; self.lastTurn = lastTurn; self.liveTurn = liveTurn
        self.knownThreadCount = knownThreadCount; self.unknownThreadCount = unknownThreadCount
        self.unidentifiedFileCount = unidentifiedFileCount; self.subagentCount = subagentCount; self.forkCount = forkCount
    }
}

public struct LocalTurnSummary: Equatable, Sendable {
    public let outputTokens: Int
    public let durationSeconds: Double
    public let completedAt: Date
    public var outputTPS: Double { Double(outputTokens) / durationSeconds }
    public init(outputTokens: Int, durationSeconds: Double, completedAt: Date) {
        self.outputTokens = outputTokens; self.durationSeconds = durationSeconds; self.completedAt = completedAt
    }
}

/// A short-lived estimate derived from two recent cumulative `token_count`
/// events while a Codex task is still active. It expires quickly when the
/// rollout stops advancing and is kept separate from completed-turn averages.
public struct LocalLiveTurnSummary: Equatable, Sendable {
    public let inputTPS: Double
    public let outputTPS: Double
    public let observedAt: Date

    public init(inputTPS: Double, outputTPS: Double, observedAt: Date) {
        self.inputTPS = inputTPS; self.outputTPS = outputTPS; self.observedAt = observedAt
    }
}

/// A verified association between the active Codex provider and Seasun Token
/// Hub. The origin is proved by the caller and is not retained in public state.
public struct LocalCodexRouteContext: Equatable, Sendable {
    public let provider: String?
    public let isVerified: Bool
    fileprivate let fingerprint: String

    public static let unverified = LocalCodexRouteContext(provider: nil, isVerified: false,
        fingerprint: "unverified")

    public static func verified(provider: String, origin: String) -> LocalCodexRouteContext {
        let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOrigin = origin.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedProvider.isEmpty, !normalizedOrigin.isEmpty,
              normalizedOrigin.hasPrefix("https://") else { return .unverified }
        return LocalCodexRouteContext(provider: normalizedProvider, isVerified: true,
            fingerprint: "verified|\(normalizedProvider)|\(normalizedOrigin)")
    }

    fileprivate init(provider: String?, isVerified: Bool, fingerprint: String) {
        self.provider = provider; self.isVerified = isVerified; self.fingerprint = fingerprint
    }

    fileprivate func accepts(_ modelProvider: String?) -> Bool {
        guard isVerified, let provider, let modelProvider else { return false }
        return provider == modelProvider
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
        let live: LocalLiveTurnSummary?
        let latestEventAt: Date?; let tailLimited: Bool; let headComplete: Bool; let hasFutureTurn: Bool
        let contentHash: String?; let signature: FileSignature
    }
    fileprivate struct CachedFileSummary { let summary: FileSummary; let evaluatedAt: Date }
    public final class Cache {
        public struct Diagnostics: Equatable, Sendable {
            public fileprivate(set) var bytesRead = 0; public fileprivate(set) var parsedFiles = 0
            public fileprivate(set) var cacheHits = 0; public fileprivate(set) var safeOpens = 0
        }
        public private(set) var diagnostics = Diagnostics()
        public var entryCount: Int { entries.count }
        fileprivate var entries: [FileSignature: CachedFileSummary] = [:]
        fileprivate var rootIdentity: FileSignature?
        fileprivate var routeFingerprint: String?
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
    public static func defaultConfigURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let configured = environment["CODEX_HOME"], configured.hasPrefix("/") {
            return URL(fileURLWithPath: configured).appendingPathComponent("config.toml")
        }
        return home.appendingPathComponent(".codex").appendingPathComponent("config.toml")
    }
    public static func scan(directory: URL, now: Date = Date()) throws -> LocalCodexSnapshot { try scan(directory: directory, now: now, cache: nil) }
    public static func scan(directory: URL, now: Date = Date(),
                            routeContext: LocalCodexRouteContext?) throws -> LocalCodexSnapshot {
        try scan(directory: directory, now: now, cache: nil, routeContext: routeContext)
    }

    public static func scan(directory: URL, now: Date = Date(), cache: Cache?,
                            routeContext: LocalCodexRouteContext? = nil) throws -> LocalCodexSnapshot {
        cache?.resetDiagnostics()
        func empty() -> LocalCodexSnapshot { LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0, filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil) }
        if let cache, cache.routeFingerprint != routeContext?.fingerprint {
            cache.entries.removeAll(); cache.routeFingerprint = routeContext?.fingerprint
        }
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
            // A clock rollback can turn previously current evidence into future
            // evidence. Reparse it rather than reusing a time-dependent result.
            if let cached = cache?.entries[signature], now >= cached.evaluatedAt {
                cache?.hit()
                let cachedSummary = cached.summary
                let cachedLive: LocalLiveTurnSummary? = cachedSummary.live.flatMap { live in
                    guard live.observedAt <= now, now.timeIntervalSince(live.observedAt) <= 15 else { return nil }
                    return live
                }
                let refreshed = FileSummary(identity: cachedSummary.identity, lineage: cachedSummary.lineage,
                    isFork: cachedSummary.isFork,
                    sourceKnownTop: cachedSummary.sourceKnownTop, contribution: cachedSummary.contribution,
                    rate: cachedSummary.rate,
                    quotaDate: cachedSummary.quotaDate, turn: cachedSummary.hasFutureTurn ? nil : cachedSummary.turn, live: cachedLive, latestEventAt: cachedSummary.latestEventAt,
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
            let parsed = parseFile(bytes: bytes, size: size, now: now, signature: signature,
                                   routeContext: routeContext)
            filesScanned += 1
            if parsed.identity == nil { unidentified += 1 }
            if parsed.tailLimited || !parsed.headComplete { limited = true; coverageLimited = true }
            summaries.append(parsed)
            if let cache, parsed.identity != nil, !parsed.hasFutureTurn {
                cache.entries[signature] = CachedFileSummary(summary: parsed, evaluatedAt: now)
                if cache.entries.count > maxFiles { cache.entries.removeValue(forKey: cache.entries.keys.first!) }
            } else {
                // Future lifecycle/counter evidence must be rejudged as time
                // catches up, including when the file itself remains unchanged.
                cache?.entries.removeValue(forKey: signature)
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
        var liveInputTPS = 0.0, liveOutputTPS = 0.0, latestLiveAt: Date?
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
            if let live = summary.live, live.observedAt <= now {
                liveInputTPS += live.inputTPS; liveOutputTPS += live.outputTPS
                // The aggregate expires when its oldest included component
                // expires; a newer session cannot extend an older one's rate.
                if latestLiveAt == nil || live.observedAt < latestLiveAt! { latestLiveAt = live.observedAt }
            }
        }
        var input = 0, output = 0, total = 0
        for record in known {
            let (i, io) = input.addingReportingOverflow(record.input), (o, oo) = output.addingReportingOverflow(record.output), (t, ot) = total.addingReportingOverflow(record.total)
            guard !io && !oo && !ot else { throw StatError.message("本地用量汇总超出可表示范围") }
            input = i; output = o; total = t
        }
        let finalRate = quotaWinner?.1
        let liveTurn = latestLiveAt.map { LocalLiveTurnSummary(inputTPS: liveInputTPS,
            outputTPS: liveOutputTPS, observedAt: $0) }
        return LocalCodexSnapshot(input: input, output: output, total: total, sessionCount: topLevelCount,
            filesScanned: filesScanned, isLimited: limited || unsafeCandidate || coverageLimited, latestEventAt: latestEvent,
            fiveHour: finalRate?.five, sevenDay: finalRate?.seven, knownThreadCount: known.count,
            unknownThreadCount: unknownThreads, unidentifiedFileCount: unidentifiedCount,
            subagentCount: subagentCount, forkCount: forkCount, lastTurn: latestTurn, liveTurn: liveTurn)
    }

    private static func parseFile(bytes: Data, size: Int, now: Date, signature: FileSignature,
                                 routeContext: LocalCodexRouteContext?) -> FileSummary {
        let headLength = min(size, headLimit), tailLength = max(0, bytes.count - headLength)
        let head = bytes.prefix(headLength), tail = tailLength > 0 ? bytes.suffix(tailLength) : Data()
        let tailLimited = size > headLimit + tailLimit
        let wholeFileRead = size <= headLimit + tailLimit
        let headComplete = wholeFileRead || size <= headLimit || head.last == 10
        // `endsAtFileEnd` means the bounded read reached EOF; it does not mean
        // that EOF was terminated by a newline. A final non-empty segment is a
        // candidate complete record when the bytes cover the whole file. The
        // parser below decides whether malformed JSON makes it a continuity
        // barrier.
        let headLines = wholeFileRead ? completeLines(Data(bytes), startsAtFileStart: true, endsAtFileEnd: size <= bytes.count) : completeLines(Data(head), startsAtFileStart: true, endsAtFileEnd: false)
        let tailLines = !wholeFileRead && tailLength > 0 ? completeLines(Data(tail), startsAtFileStart: false, endsAtFileEnd: true) : []
        let headSlots = headLines.enumerated().map { parseLine($0.element, fallbackOrdinal: $0.offset) }
        let decodedHead = headSlots.compactMap { $0 }
        let physicalRecordCountHead = headLines.count
        let tailOrdinalBase = size > headLimit + tailLimit ? -1 : physicalRecordCountHead
        let tailSlots = tailLines.enumerated().map { parseLine($0.element, fallbackOrdinal: tailOrdinalBase < 0 ? -1 : tailOrdinalBase + $0.offset) }
        let decodedTail = tailSlots.compactMap { $0 }
        var decoded = tailLength > 0 ? decodedHead + decodedTail : decodedHead
        let continuousRead = wholeFileRead
        let finalLineWithoutLF: Data.SubSequence? = bytes.last == 10 ? nil :
            bytes[(bytes.lastIndex(of: 10).map { bytes.index(after: $0) } ?? bytes.startIndex)...]
        // A no-final-LF line is complete when it parsed as a valid JSON event.
        // Keep malformed fragments as continuity barriers so they cannot make
        // a bounded history look complete.
        let hasIncompleteTailFragment: Bool = {
            guard let finalLineWithoutLF else { return false }
            return parseLine(finalLineWithoutLF, fallbackOrdinal: -1) == nil
        }()
        let identity: String?
        let firstPhysicalLine = completeLines(Data(bytes.prefix(headLength)), startsAtFileStart: true, endsAtFileEnd: size <= headLength).first
        if let first = firstPhysicalLine, !first.isEmpty, let object = try? JSONSerialization.jsonObject(with: Data(first)),
           let root = object as? [String: Any], root["type"] as? String == "session_meta",
           let id = (root["payload"] as? [String: Any])?["id"] as? String, let normalized = normalizeUUID(id) { identity = normalized }
        else { identity = nil }
        guard let identity else {
            return FileSummary(identity: nil, lineage: .unknown, isFork: false, sourceKnownTop: false, contribution: nil, rate: nil,
                quotaDate: nil, turn: nil, live: nil, latestEventAt: nil, tailLimited: tailLimited, headComplete: headComplete, hasFutureTurn: false,
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
        guard let firstMetaLine = firstPhysicalLine else { return FileSummary(identity: nil, lineage: .unknown, isFork: false, sourceKnownTop: false, contribution: nil, rate: nil, quotaDate: nil, turn: nil, live: nil, latestEventAt: nil, tailLimited: tailLimited, headComplete: headComplete, hasFutureTurn: false, contentHash: bytes.fullContentHashIfComplete(fileSize: size), signature: signature) }
        let metadata = (try? JSONSerialization.jsonObject(with: Data(firstMetaLine))) as? [String: Any]
        let payload = metadata?["payload"] as? [String: Any] ?? [:]
        if let routeContext, !routeContext.accepts(payload["model_provider"] as? String) {
            return FileSummary(identity: nil, lineage: .unknown, isFork: false, sourceKnownTop: false,
                contribution: nil, rate: nil, quotaDate: nil, turn: nil, live: nil, latestEventAt: nil,
                tailLimited: tailLimited, headComplete: headComplete, hasFutureTurn: false,
                contentHash: bytes.fullContentHashIfComplete(fileSize: size), signature: signature)
        }
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
        let hasFutureCounter = cumulativeTokenEvents.contains { $0.date > now }
        let lastToken = cumulativeTokenEvents.last
        let observedLineSegments = wholeFileRead ? [mappedHeadSlots] : [mappedHeadSlots, mappedTailSlots]
        let latestCounterSegment = observedLineSegments.lastIndex(where: { $0.contains(where: { $0?.hasCumulativePayload == true }) })
        let hasBadLineAfterLatestCounter: Bool = {
            guard let segmentIndex = latestCounterSegment, let lineIndex = observedLineSegments[segmentIndex].lastIndex(where: { $0?.hasCumulativePayload == true }) else { return false }
            return observedLineSegments[segmentIndex].dropFirst(lineIndex + 1).contains(where: { $0 == nil })
        }()
        let latestCounterInTail = !wholeFileRead && !mappedTailSlots.isEmpty && mappedTailSlots.contains(where: { $0?.hasCumulativePayload == true })
        let forkHasCompleteLines = wholeFileRead && mappedHeadSlots.allSatisfy { $0 != nil } && !hasIncompleteTailFragment
        var contribution: Record? = nil
        if lineage == .root {
            if let lastToken, let usage = lastToken.usage,
               validCumulativeSequence(cumulativeTokenEvents, now: now), !hasFutureCounter,
               !hasIncompleteTailFragment, !hasBadLineAfterLatestCounter,
               (wholeFileRead || latestCounterInTail) { contribution = usage }
        } else if (lineage == .subagent || lineage == .fork), !hasHistoryBase, !hasFutureCounter, headComplete, !tailLimited,
                  continuousRead, forkHasCompleteLines, let delta = forkContribution(payload: payload, events: decoded) { contribution = delta }
        let rateEvents = tokenEvents.map { ($0.date, $0.quotaUpdate) }
        let resolvedQuota = resolveRate(rateEvents, now: now)
        let rate = resolvedQuota.record
        let turnSegments = observedLineSegments.flatMap { parsedSegments($0) }
        let turn = turnSegments.compactMap { completedTurns(in: $0, now: now) }.max(by: { $0.completedAt < $1.completedAt })
        // Live lifecycle evidence must be in the final continuous segment. A
        // corrupt record, unread middle, or incomplete tail cannot be bridged.
        let live: LocalLiveTurnSummary?
        if !hasIncompleteTailFragment, let finalSlots = observedLineSegments.last,
           finalSlots.last.flatMap({ $0 }) != nil,
           let finalSegment = parsedSegments(finalSlots).last {
            live = liveTurn(in: finalSegment, now: now)
        } else { live = nil }
        let latestUsageDate = validCounters.last?.date
        return FileSummary(identity: identity, lineage: lineage, isFork: isFork, sourceKnownTop: sourceKnownTop,
            contribution: contribution, rate: rate, quotaDate: resolvedQuota.date, turn: turn, live: live, latestEventAt: latestUsageDate,
            tailLimited: tailLimited, headComplete: headComplete,
            hasFutureTurn: decoded.contains(where: { ["task_started", "task_complete", "turn_aborted", "token_count"].contains($0.type) && $0.date > now }),
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
        // A malformed event envelope is a continuity barrier, just like broken
        // JSON; otherwise it could silently hide a lifecycle boundary.
        if type == "event_msg" {
            guard let kind = payload["type"] as? String, !kind.isEmpty else { return nil }
        }
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
        // A trailing LF creates an empty terminator; a nonempty final segment
        // is complete only when this read reached EOF. For head chunks that do
        // not reach EOF, retain only newline-terminated records.
        if let last = lines.last, last.isEmpty || !endsAtFileEnd { lines.removeLast() }
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

    /// Derive a short-lived output/input rate only from a still-open task and
    /// two monotonic cumulative counters. A missing or stale tail is unknown.
    private static func liveTurn(in events: [ParsedEvent], now: Date) -> LocalLiveTurnSummary? {
        let freshnessLimit: TimeInterval = 15
        var activeID: String?
        var openIDs: [String: Int] = [:], seenIDs = Set<String>()
        var ambiguous = false
        var lastDate: Date?
        var counters: [Record] = []
        for event in events {
            let validTime = !event.invalidLifecycleTimestamp && event.date <= now
            switch event.type {
            case "task_started":
                let id = event.turnID ?? ""
                let unique = seenIDs.insert(id).inserted
                if openIDs.isEmpty {
                    activeID = id.isEmpty ? nil : id
                    ambiguous = id.isEmpty || !unique || !validTime
                    lastDate = event.date
                    counters.removeAll(keepingCapacity: true)
                } else {
                    // Keep all open IDs so closing one overlapping task cannot
                    // make the other task appear independently attributable.
                    ambiguous = true
                }
                openIDs[id, default: 0] += 1
            case "task_complete", "turn_aborted":
                if !validTime || lastDate.map({ event.date < $0 }) == true { ambiguous = true }
                if let id = event.turnID, let count = openIDs[id] {
                    if count == 1 { openIDs.removeValue(forKey: id) } else { openIDs[id] = count - 1 }
                } else if event.turnID == nil, event.type == "turn_aborted" {
                    openIDs.removeAll()
                } else { ambiguous = true }
                if openIDs.isEmpty {
                    activeID = nil; lastDate = nil
                    counters.removeAll(keepingCapacity: true)
                }
            case "token_count":
                guard activeID != nil else { continue }
                if !validTime || lastDate.map({ event.date < $0 }) == true { ambiguous = true }
                lastDate = event.date
                guard event.hasCumulativePayload else { continue }
                guard let usage = event.usage else { ambiguous = true; continue }
                if let previous = counters.last,
                   usage.input < previous.input || usage.output < previous.output || usage.total < previous.total {
                    ambiguous = true
                }
                // Keep just the last pair after validating every observed
                // counter, so a prior reset cannot be hidden by two good ones.
                if counters.count == 2 { counters.removeFirst() }
                counters.append(usage)
            default: break
            }
        }
        guard activeID != nil, !ambiguous, openIDs.count == 1,
              let latest = counters.last, let previous = counters.dropLast().last,
              now.timeIntervalSince(latest.date) <= freshnessLimit else { return nil }
        let elapsed = latest.date.timeIntervalSince(previous.date)
        guard elapsed > 0 else { return nil }
        return LocalLiveTurnSummary(inputTPS: Double(latest.input - previous.input) / elapsed,
            outputTPS: Double(latest.output - previous.output) / elapsed,
            observedAt: latest.date)
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
    /// Validate one physical root's cumulative evidence before publishing its
    /// final counter. JSONL order is authoritative when timestamps are equal;
    /// strict reversals, future/invalid lifecycle timestamps, counter resets,
    /// and totals smaller than input+output make the whole thread unknown.
    private static func validCumulativeSequence(_ events: [ParsedEvent], now: Date) -> Bool {
        guard !events.isEmpty else { return false }
        var previousDate: Date?
        var previous: Record?
        for event in events {
            guard event.hasCumulativePayload, let usage = event.usage,
                  !event.invalidLifecycleTimestamp, usage.date <= now else { return false }
            if let previousDate, usage.date < previousDate { return false }
            if let previous,
               usage.input < previous.input || usage.output < previous.output || usage.total < previous.total {
                return false
            }
            let (minimumTotal, overflow) = usage.input.addingReportingOverflow(usage.output)
            guard !overflow, usage.total >= minimumTotal else { return false }
            previousDate = usage.date
            previous = usage
        }
        return true
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

public struct WindowQuota: Codable, Equatable, Sendable {
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
    /// Source reset timestamp, when the direct endpoint supplied one. AX
    /// display-only rows leave this nil rather than guessing a date.
    public let resetAt: Date?

    public init(kind: TokenHubWindowKind, usedAmount: Decimal, limitAmount: Decimal,
                sourceSymbol: String, usedPercent: Decimal, resetDisplay: String,
                resetAt: Date? = nil) {
        self.kind = kind; self.usedAmount = usedAmount; self.limitAmount = limitAmount
        self.sourceSymbol = sourceSymbol; self.usedPercent = usedPercent; self.resetDisplay = resetDisplay
        self.resetAt = resetAt
    }
}

public struct TokenHubMonthlyUsage: Equatable, Sendable {
    public let usedAmount: Decimal
    public let sourceSymbol: String
    /// Monthly total is optional because some enterprise responses expose
    /// usage without a quota. Derived values stay unknown in that case.
    public let limitAmount: Decimal?
    public var remainingAmount: Decimal? {
        guard let limitAmount, limitAmount > 0, usedAmount >= 0, usedAmount <= limitAmount else { return nil }
        return limitAmount - usedAmount
    }
    public var usedPercent: Decimal? {
        guard let limitAmount, limitAmount > 0, usedAmount >= 0, usedAmount <= limitAmount else { return nil }
        return (usedAmount / limitAmount) * Decimal(100)
    }
    public init(usedAmount: Decimal, sourceSymbol: String, limitAmount: Decimal? = nil) {
        self.usedAmount = usedAmount; self.sourceSymbol = sourceSymbol; self.limitAmount = limitAmount
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

### Sources/TokenStatCore/TokenHubDirectQuota.swift

```swift
import Foundation
import SQLite3
import CoreFoundation
import Darwin

/// Failures from the direct Seasun Token Hub path intentionally carry no
/// response body, URL, account, or credential.  They are safe to surface in
/// diagnostics and logs.
public enum TokenHubDirectQuotaFailure: Error, Equatable, Sendable {
    case endpointRejected
    case identityChanged
    case credentialExpired
    case connectionUnavailable
    case connectionMalformed
    case databaseUnsafe
    case sessionUnavailable
    case exchangeFailed
    case redirectMissing
    case accessTokenMissing
    case responseTooLarge
    case httpStatus(Int)
    case transportFailed
    case malformedResponse
    case noRecognizedWindows
    case duplicateWindow(TokenHubWindowKind)
    case duplicateMonthly
}

/// The direct endpoint is derived from Token Hub's read-only connection
/// settings.  It accepts only HTTPS, credential-free URLs and can require the
/// AI Manager and SSO hosts to share the same organization suffix.  No host
/// name is embedded in the public source tree.
public struct TokenHubDirectQuotaEndpoint: Equatable, Sendable {
    public let url: URL

    public init(baseURL: URL, organizationURL: URL) throws {
        guard baseURL.scheme?.lowercased() == "https",
              let host = baseURL.host, !host.isEmpty,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil,
              baseURL.port == nil || baseURL.port == 443,
              !baseURL.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !baseURL.path.split(separator: "/").contains(".."),
              !Self.isIPAddress(host),
              organizationURL.scheme?.lowercased() == "https",
              organizationURL.user == nil, organizationURL.password == nil,
              organizationURL.query == nil, organizationURL.fragment == nil,
              organizationURL.port == nil || organizationURL.port == 443,
              Self.sameOrganization(baseURL, organizationURL) else {
            throw TokenHubDirectQuotaFailure.endpointRejected
        }
        let prefix = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = prefix.isEmpty ? Self.quotaPath : "/\(prefix)\(Self.quotaPath)"
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw TokenHubDirectQuotaFailure.endpointRejected
        }
        components.path = path
        components.query = nil; components.fragment = nil
        guard let normalized = components.url else { throw TokenHubDirectQuotaFailure.endpointRejected }
        self.url = normalized
    }

    public static let quotaPath = "/api/v1/auth/me/quota-usage"

    public static func sameOrganization(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = lhs.host?.lowercased(), let right = rhs.host?.lowercased(),
              !isIPAddress(left), !isIPAddress(right),
              let leftDomain = registrableDomain(left),
              let rightDomain = registrableDomain(right) else { return false }
        return leftDomain == rightDomain
    }

    /// This compatibility heuristic recognizes only the suffixes listed below;
    /// it is not a complete Public Suffix List or a redirect trust boundary.
    /// Callback Locations must match the original verified origin exactly.
    private static let multiLabelPublicSuffixes: Set<String> = [
        "ac.uk", "co.uk", "gov.uk", "org.uk",
        "com.au", "net.au", "org.au",
        "co.jp", "ne.jp", "com.br", "com.cn", "com.hk", "com.mx",
        "com.sg", "com.tr", "com.tw", "co.kr", "co.nz", "co.za"
    ]

    private static func registrableDomain(_ host: String) -> String? {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let suffixLabelCount = multiLabelPublicSuffixes.contains(lastTwo) ? 2 : 1
        guard labels.count > suffixLabelCount else { return nil }
        return labels.suffix(suffixLabelCount + 1).joined(separator: ".")
    }

    private static func isIPAddress(_ host: String) -> Bool {
        host.range(of: #"^[0-9.]+$"#, options: .regularExpression) != nil || host.contains(":")
    }
}

private enum TokenHubTimestamp {
    static func dateFromNumeric(_ value: Any?) -> Date? {
        let seconds: Double?
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            seconds = n.doubleValue
        } else if let text = value as? String {
            seconds = Double(text)
        } else { seconds = nil }
        guard let seconds, seconds.isFinite, seconds > 0, seconds < 100_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// Reads only the connection and session fields owned by Token Hub. SQLite is
/// opened read-only and queried with fixed keys; no other rows are retained.
public enum TokenHubConnectionDiscovery {
    public static func defaultDatabaseURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".seasun-token-hub", isDirectory: true).appendingPathComponent("tokenhub.db")
    }

    public static func readAIManagerBaseURL(at url: URL) throws -> URL {
        guard let database = try? openDatabase(at: url) else { throw TokenHubDirectQuotaFailure.connectionUnavailable }
        let db = database.handle
        defer { sqlite3_close(db) }
        guard let values = try readSetting(db: db, key: "client.connection"),
              let base = values["aiManagerBaseUrl"] as? String,
              let result = URL(string: base) else { throw TokenHubDirectQuotaFailure.connectionMalformed }
        return result
    }

    public static func readDefaultAIManagerBaseURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let url = defaultDatabaseURL(home: home)
        let expected = home.appendingPathComponent(".seasun-token-hub", isDirectory: true).appendingPathComponent("tokenhub.db")
        guard url.standardizedFileURL == expected.standardizedFileURL,
              url.resolvingSymlinksInPath() == url.standardizedFileURL else {
            throw TokenHubDirectQuotaFailure.databaseUnsafe
        }
        return try readAIManagerBaseURL(at: url)
    }

    /// Reads only the credential-free connection origins used to prove that
    /// the active Codex provider is managed by this Token Hub installation.
    /// The SSO session row is never touched by this discovery call.
    public static func readDefaultConnectionBaseURLs(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [URL] {
        let url = defaultDatabaseURL(home: home)
        let expected = home.appendingPathComponent(".seasun-token-hub", isDirectory: true).appendingPathComponent("tokenhub.db")
        guard url.standardizedFileURL == expected.standardizedFileURL,
              url.resolvingSymlinksInPath() == url.standardizedFileURL else {
            throw TokenHubDirectQuotaFailure.databaseUnsafe
        }
        let database = try openDatabase(at: url)
        let db = database.handle
        defer { sqlite3_close(db) }
        guard let connection = try readSetting(db: db, key: "client.connection") else {
            throw TokenHubDirectQuotaFailure.connectionMalformed
        }
        let fields = ["aiManagerBaseUrl", "aitsBaseUrl"]
        let urls = fields.compactMap { key -> URL? in
            guard let raw = connection[key] as? String, let value = URL(string: raw) else { return nil }
            return value
        }
        guard urls.count == fields.count else { throw TokenHubDirectQuotaFailure.connectionMalformed }
        return urls
    }

    fileprivate static func readDefaultStoredSettings(home: URL, now: Date = Date()) throws -> TokenHubStoredSettings {
        let url = defaultDatabaseURL(home: home)
        let expected = home.appendingPathComponent(".seasun-token-hub", isDirectory: true).appendingPathComponent("tokenhub.db")
        guard url.standardizedFileURL == expected.standardizedFileURL,
              url.resolvingSymlinksInPath() == url.standardizedFileURL else {
            throw TokenHubDirectQuotaFailure.databaseUnsafe
        }
        let database = try openDatabase(at: url)
        let db = database.handle
        defer { sqlite3_close(db) }
        guard let connection = try readSetting(db: db, key: "client.connection"),
              let aiString = connection["aiManagerBaseUrl"] as? String,
              let ssoString = connection["ssoBaseUrl"] as? String,
              let ai = URL(string: aiString), let sso = URL(string: ssoString) else {
            throw TokenHubDirectQuotaFailure.connectionMalformed
        }
        guard let session = try readSetting(db: db, key: "seasun_sso_session"),
              let token = session["token"] as? String,
              let verifySign = session["verifySign"] as? String,
              let channel = session["channel"] as? String,
              let tokenType = session["tokenType"] as? String,
              let expiresAt = sessionExpiry(session["expiresAt"]),
              [token, verifySign, channel, tokenType].allSatisfy({ !$0.isEmpty && $0.count <= 16_384 }) else {
            throw TokenHubDirectQuotaFailure.sessionUnavailable
        }
        guard expiresAt.timeIntervalSince(now) > 30 else { throw TokenHubDirectQuotaFailure.credentialExpired }
        return TokenHubStoredSettings(databaseIdentity: database.identity, aiManagerBaseURL: ai, ssoBaseURL: sso,
                                      session: TokenHubStoredSession(token: token, verifySign: verifySign,
                                                                      channel: channel, tokenType: tokenType,
                                                                      expiresAt: expiresAt))
    }

    private static func openDatabase(at url: URL) throws -> (handle: OpaquePointer, identity: TokenHubDatabaseIdentity) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path),
              let attributes = try? manager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 64 * 1_048_576 else {
            throw TokenHubDirectQuotaFailure.connectionUnavailable
        }
        if let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o022 != 0 {
            throw TokenHubDirectQuotaFailure.databaseUnsafe
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw TokenHubDirectQuotaFailure.databaseUnsafe }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o022) == 0 else {
            throw TokenHubDirectQuotaFailure.databaseUnsafe
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.standardizedFileURL.path, &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            throw TokenHubDirectQuotaFailure.connectionUnavailable
        }
        var pathInfo = stat()
        guard stat(url.path, &pathInfo) == 0, pathInfo.st_dev == info.st_dev,
              pathInfo.st_ino == info.st_ino else {
            sqlite3_close(db)
            throw TokenHubDirectQuotaFailure.databaseUnsafe
        }
        // Carry the identity verified against the actual open descriptor into
        // the request transaction. Equal JSON from a replacement inode is not
        // the same trusted local database.
        return (db, TokenHubDatabaseIdentity(device: info.st_dev, inode: info.st_ino))
    }

    private static func sessionExpiry(_ value: Any?) -> Date? {
        let raw: Double?
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { raw = n.doubleValue }
        else if let text = value as? String { raw = Double(text) }
        else { raw = nil }
        guard let raw, raw.isFinite, raw >= 100_000_000_000, raw < 100_000_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: raw / 1000)
    }

    private static func readSetting(db: OpaquePointer, key: String) throws -> [String: Any]? {
        var statement: OpaquePointer?
        let sql = "SELECT value_json FROM client_settings WHERE key = ?1 LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw TokenHubDirectQuotaFailure.connectionUnavailable
        }
        defer { sqlite3_finalize(statement) }
        let bindResult = key.withCString { sqlite3_bind_text(statement, 1, $0, -1, nil) }
        guard bindResult == SQLITE_OK else {
            throw TokenHubDirectQuotaFailure.connectionUnavailable
        }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let pointer = sqlite3_column_text(statement, 0),
              sqlite3_column_bytes(statement, 0) <= 64 * 1024 else { return nil }
        let raw = String(cString: pointer)
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let values = object as? [String: Any] else { return nil }
        return values
    }
}

fileprivate struct TokenHubStoredSession: Equatable {
    let token: String
    let verifySign: String
    let channel: String
    let tokenType: String
    let expiresAt: Date
}

fileprivate struct TokenHubDatabaseIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

fileprivate struct TokenHubStoredSettings: Equatable {
    let databaseIdentity: TokenHubDatabaseIdentity
    let aiManagerBaseURL: URL
    let ssoBaseURL: URL
    let session: TokenHubStoredSession
}

public struct TokenHubDirectQuotaHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data
    public init(statusCode: Int, data: Data) { self.statusCode = statusCode; self.data = data }
}

/// A small injectable client keeps network access out of parsing tests and
/// lets the app hold the exchanged access token only for this refresh.
public struct TokenHubDirectQuotaClient: Sendable {
    public typealias Request = @Sendable (URL, String) async throws -> TokenHubDirectQuotaHTTPResponse
    public typealias CallbackRequest = @Sendable (URL) async throws -> String
    private let request: Request
    private let callbackRequest: CallbackRequest

    public init(request: Request? = nil, callbackRequest: CallbackRequest? = nil) {
        self.request = request ?? { url, bearer in
            try await TokenHubDirectQuotaClient.liveRequest(url: url, bearer: bearer)
        }
        self.callbackRequest = callbackRequest ?? { url in
            try await TokenHubDirectQuotaClient.liveCallbackRequest(url: url)
        }
    }

    public func fetch(identity: TokenHubIdentity, now: Date = Date(),
                      home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> TokenHubQuotaSnapshot {
        let settings = try TokenHubConnectionDiscovery.readDefaultStoredSettings(home: home, now: now)
        let endpoint = try TokenHubDirectQuotaEndpoint(baseURL: settings.aiManagerBaseURL,
                                                       organizationURL: settings.ssoBaseURL)
        let callbackURL = try Self.callbackURL(baseURL: settings.aiManagerBaseURL, session: settings.session)
        var access: String
        do { access = try await callbackRequest(callbackURL) }
        catch let error as TokenHubDirectQuotaFailure { throw error }
        catch { throw TokenHubDirectQuotaFailure.exchangeFailed }
        try Self.requireUnchangedSettings(settings, home: home, now: now)
        var response = try await quotaResponse(endpoint: endpoint.url, access: access)
        // Token Hub's own business flow refreshes the broker token once after
        // a 401. Never retry other statuses and never persist the new token.
        if response.statusCode == 401 {
            // Re-read once before the second exchange. If the Hub session or
            // endpoints changed, let the next refresh start a new transaction
            // rather than combine data from two identities in this one.
            let refreshed = try TokenHubConnectionDiscovery.readDefaultStoredSettings(home: home, now: now)
            guard refreshed == settings else { throw TokenHubDirectQuotaFailure.identityChanged }
            let refreshedCallbackURL = try Self.callbackURL(baseURL: refreshed.aiManagerBaseURL, session: refreshed.session)
            do { access = try await callbackRequest(refreshedCallbackURL) }
            catch let error as TokenHubDirectQuotaFailure { throw error }
            catch { throw TokenHubDirectQuotaFailure.exchangeFailed }
            try Self.requireUnchangedSettings(settings, home: home, now: now)
            response = try await quotaResponse(endpoint: endpoint.url, access: access)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw TokenHubDirectQuotaFailure.httpStatus(response.statusCode)
        }
        guard response.data.count <= 1_048_576 else { throw TokenHubDirectQuotaFailure.responseTooLarge }
        try Self.requireUnchangedSettings(settings, home: home, now: now)
        return try TokenHubDirectQuotaDecoder.decode(response.data, identity: identity, now: now)
    }

    private static func requireUnchangedSettings(_ expected: TokenHubStoredSettings, home: URL, now: Date) throws {
        let latest = try TokenHubConnectionDiscovery.readDefaultStoredSettings(home: home, now: now)
        guard latest == expected else { throw TokenHubDirectQuotaFailure.identityChanged }
    }

    private func quotaResponse(endpoint: URL, access: String) async throws -> TokenHubDirectQuotaHTTPResponse {
        do { return try await request(endpoint, access) }
        catch let error as TokenHubDirectQuotaFailure { throw error }
        catch { throw TokenHubDirectQuotaFailure.transportFailed }
    }

    private static func callbackURL(baseURL: URL, session: TokenHubStoredSession) throws -> URL {
        guard baseURL.scheme?.lowercased() == "https", baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw TokenHubDirectQuotaFailure.endpointRejected
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let prefix = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = prefix.isEmpty ? "/api/v1/auth/it-sso/callback" : "/\(prefix)/api/v1/auth/it-sso/callback"
        components?.queryItems = [
            URLQueryItem(name: "token", value: session.token),
            URLQueryItem(name: "verifySign", value: session.verifySign),
            URLQueryItem(name: "redirect", value: "/me/api-key"),
            URLQueryItem(name: "sourceChannel", value: session.channel),
            URLQueryItem(name: "sourceTokenType", value: session.tokenType)
        ]
        guard let url = components?.url else { throw TokenHubDirectQuotaFailure.endpointRejected }
        return url
    }

    private static func liveRequest(url: URL, bearer: String) async throws -> TokenHubDirectQuotaHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let delegate = TokenHubRedirectBlocker(host: url.host?.lowercased())
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TokenHubDirectQuotaFailure.transportFailed }
        guard http.url?.host?.lowercased() == url.host?.lowercased() else {
            throw TokenHubDirectQuotaFailure.endpointRejected
        }
        return TokenHubDirectQuotaHTTPResponse(statusCode: http.statusCode, data: data)
    }

    private static func liveCallbackRequest(url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.httpShouldHandleCookies = false
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let delegate = TokenHubRedirectCapture()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do { _ = try await session.data(for: request) }
        catch {
            guard delegate.location != nil else { throw TokenHubDirectQuotaFailure.exchangeFailed }
        }
        guard let location = delegate.location else { throw TokenHubDirectQuotaFailure.redirectMissing }
        return try accessToken(fromCallbackLocation: location, callbackURL: url)
    }

    /// Decodes a captured Location without navigating to it. Keeping this pure
    /// makes the redirect trust boundary testable without a session or network.
    public static func accessToken(fromCallbackLocation location: String, callbackURL: URL) throws -> String {
        // The Location carries a bearer token. A common organization suffix is
        // insufficient: do not accept even a sibling host, query, userinfo, or
        // nondefault port. No request is sent to this URL.
        guard location.utf8.count <= 65_536,
              !location.unicodeScalars.contains(where: { $0.properties.isWhitespace || CharacterSet.controlCharacters.contains($0) }),
              callbackURL.scheme?.lowercased() == "https",
              callbackURL.user == nil, callbackURL.password == nil,
              callbackURL.port == nil || callbackURL.port == 443,
              let originalHost = callbackURL.host?.lowercased(), !originalHost.isEmpty,
              let locationURL = URL(string: location),
              let components = URLComponents(url: locationURL, resolvingAgainstBaseURL: false),
              locationURL.scheme?.lowercased() == "https",
              locationURL.host?.lowercased() == originalHost,
              locationURL.port == nil || locationURL.port == 443,
              locationURL.user == nil, locationURL.password == nil,
              components.query == nil,
              let expectedPath = Self.expectedCallbackLocationPath(for: callbackURL),
              components.percentEncodedPath == expectedPath,
              let fragment = components.percentEncodedFragment,
              let fragmentComponents = URLComponents(string: "https://local.invalid/?\(fragment)"),
              fragmentComponents.fragment == nil,
              let items = fragmentComponents.queryItems else {
            throw TokenHubDirectQuotaFailure.accessTokenMissing
        }
        let tokens = items.filter { $0.name == "access_token" }
        let redirects = items.filter { $0.name == "redirect" }
        guard tokens.count == 1, redirects.count <= 1,
              redirects.first.map({ $0.value == "/me/api-key" }) ?? true,
              let token = tokens.first?.value, !token.isEmpty, token.count <= 16_384,
              token.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0) }) else {
            throw TokenHubDirectQuotaFailure.accessTokenMissing
        }
        return token
    }

    private static func expectedCallbackLocationPath(for callbackURL: URL) -> String? {
        let suffix = "/api/v1/auth/it-sso/callback"
        guard let path = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              path.hasSuffix(suffix) else { return nil }
        let prefix = String(path.dropLast(suffix.count))
        return (prefix == "/" ? "" : prefix) + "/auth/it/callback"
    }

}

private final class TokenHubRedirectBlocker: NSObject, URLSessionTaskDelegate {
    let host: String?
    init(host: String?) { self.host = host }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.host?.lowercased() == host else { completionHandler(nil); return }
        completionHandler(nil)
    }
}

private final class TokenHubRedirectCapture: NSObject, URLSessionTaskDelegate {
    var location: String?
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        location = response.value(forHTTPHeaderField: "Location")
        completionHandler(nil)
    }
}

/// Decodes the response returned by `/api/v1/auth/me/quota-usage` without
/// guessing from local token counters.  The endpoint's `kind` is required to
/// identify a window; unknown kinds are ignored and never assigned to a known
/// 5-hour or 7-day slot.
public enum TokenHubDirectQuotaDecoder {
    public static func decode(_ data: Data, identity: TokenHubIdentity, now: Date = Date(),
                              timeZone: TimeZone = .current) throws -> TokenHubQuotaSnapshot {
        guard data.count <= 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = root as? [String: Any] else {
            throw TokenHubDirectQuotaFailure.malformedResponse
        }
        // Current Token Hub responses wrap usage in `data`; accepting the
        // equivalent root shape keeps this decoder forward-compatible with the
        // unwrapped response used by older gateway deployments.
        let dataObject = (object["data"] as? [String: Any]) ?? object
        guard let currency = (dataObject["currency"] as? String) ?? (object["currency"] as? String),
              let windows = (dataObject["windows"] as? [[String: Any]]) ?? (object["windows"] as? [[String: Any]]) else {
            throw TokenHubDirectQuotaFailure.malformedResponse
        }
        let symbol = displaySymbol(currency)
        let fallbackResetRaw = dataObject["reset_at"] ?? object["reset_at"]
        if let fallbackResetRaw, !(fallbackResetRaw is NSNull), date(fallbackResetRaw) == nil {
            throw TokenHubDirectQuotaFailure.malformedResponse
        }
        let fallbackReset = date(fallbackResetRaw)
        var five: TokenHubWindowQuota?
        var seven: TokenHubWindowQuota?
        var monthly: TokenHubMonthlyUsage?
        for window in windows {
            guard let kind = windowKind(window["kind"] as? String) else {
                if monthlyKind(window["kind"] as? String) {
                    guard monthly == nil else { throw TokenHubDirectQuotaFailure.duplicateMonthly }
                    guard let used = decimal(window["used_amount"]), used >= 0 else {
                        throw TokenHubDirectQuotaFailure.malformedResponse
                    }
                    let monthlyLimit: Decimal?
                    if let rawLimit = window["quota_amount"], !(rawLimit is NSNull) {
                        guard let limit = decimal(rawLimit), limit > 0, used <= limit else {
                            throw TokenHubDirectQuotaFailure.malformedResponse
                        }
                        monthlyLimit = limit
                    } else {
                        monthlyLimit = nil
                    }
                    monthly = TokenHubMonthlyUsage(usedAmount: used, sourceSymbol: symbol, limitAmount: monthlyLimit)
                }
                continue
            }
            if kind == .fiveHour, five != nil { throw TokenHubDirectQuotaFailure.duplicateWindow(kind) }
            if kind == .sevenDay, seven != nil { throw TokenHubDirectQuotaFailure.duplicateWindow(kind) }
            guard let limit = decimal(window["quota_amount"]),
                  let used = decimal(window["used_amount"]),
                  limit > 0, used >= 0, used <= limit else {
                throw TokenHubDirectQuotaFailure.malformedResponse
            }
            let percent = (used / limit) * Decimal(100)
            guard percent >= 0, percent <= Decimal(100) else {
                throw TokenHubDirectQuotaFailure.malformedResponse
            }
            let rawStart = window["period_start"]
            let rawEnd = window["period_end"]
            if let rawStart, !(rawStart is NSNull), date(rawStart) == nil {
                throw TokenHubDirectQuotaFailure.malformedResponse
            }
            if let rawEnd, !(rawEnd is NSNull), date(rawEnd) == nil {
                throw TokenHubDirectQuotaFailure.malformedResponse
            }
            if let start = date(rawStart), let end = date(rawEnd), end <= start {
                throw TokenHubDirectQuotaFailure.malformedResponse
            }
            let resetAt = date(rawEnd) ?? fallbackReset
            let reset = resetAt.map { format($0, timeZone: timeZone) } ?? "未知"
            let quota = TokenHubWindowQuota(kind: kind, usedAmount: used, limitAmount: limit,
                                             sourceSymbol: symbol, usedPercent: percent, resetDisplay: reset,
                                             resetAt: resetAt)
            if kind == .fiveHour { five = quota } else { seven = quota }
        }
        guard five != nil || seven != nil || monthly != nil else { throw TokenHubDirectQuotaFailure.noRecognizedWindows }
        return TokenHubQuotaSnapshot(identity: identity, fiveHour: five, sevenDay: seven,
                                     monthly: monthly, observedAt: now)
    }

    private static func windowKind(_ raw: String?) -> TokenHubWindowKind? {
        guard let raw else { return nil }
        let normalized = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        switch normalized {
        case "5h", "5hour", "5hours", "fivehour", "fivehours", "fixed5h": return .fiveHour
        case "7d", "7day", "7days", "sevenday", "sevendays", "fixed7d": return .sevenDay
        default: return nil
        }
    }

    private static func monthlyKind(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let normalized = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        return ["month", "monthly", "30d", "calendarmonth", "usermonth"].contains(normalized)
    }

    private static func decimal(_ value: Any?) -> Decimal? {
        let raw: String
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { raw = n.stringValue }
        else if let text = value as? String { raw = text }
        else { return nil }
        // Decimal(string:) accepts numeric prefixes, whitespace and even some
        // incomplete forms. Require a bounded, complete JSON-number spelling
        // before conversion; anchors reject trailing newlines as well as junk.
        guard raw.utf8.count <= 128,
              raw.range(of: #"\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z"#,
                        options: .regularExpression) != nil else { return nil }
        // Decimal can silently discard low-order significant digits. Bound
        // the original string's meaningful mantissa to a conservative 38
        // digits; leading/trailing zeroes do not change its numeric value.
        // Native JSON numbers may already be normalized by JSONSerialization.
        let digits = raw.utf8.prefix { $0 != 69 && $0 != 101 }.filter { (48...57).contains($0) }
        let significantDigits = digits.drop(while: { $0 == 48 }).reversed().drop(while: { $0 == 48 }).count
        guard significantDigits <= 38,
              let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")), value.isFinite,
              value >= 0, value <= Decimal(string: "1000000000000000000")! else { return nil }
        return value
    }

    private static func date(_ value: Any?) -> Date? {
        if let date = TokenHubTimestamp.dateFromNumeric(value) { return date }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }

    private static func displaySymbol(_ currency: String) -> String {
        switch currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "USD", "$": return "$"
        case "CNY", "RMB", "¥": return "¥"
        case "EUR", "€": return "€"
        case "GBP", "£": return "£"
        case "JPY", "JP¥": return "¥"
        default: return "¤"
        }
    }

    private static func format(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

private extension Data {
    init?(base64URL value: String) {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
}
```

### Sources/TokenStatMenu/AppModel.swift

```swift
import AppKit
import Combine
import CoreFoundation
#if SWIFT_PACKAGE
@preconcurrency import TokenStatCore
#endif

struct SpeedPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

struct SeasunPreferences: Equatable {
    var refreshSeconds: TimeInterval = 60
    var tokenHubCompatibilityReadEnabled = true

    var normalized: SeasunPreferences {
        SeasunPreferences(refreshSeconds: refreshSeconds.isFinite && (15...3600).contains(refreshSeconds) ? refreshSeconds : 60,
                          tokenHubCompatibilityReadEnabled: tokenHubCompatibilityReadEnabled)
    }

    init(refreshSeconds: TimeInterval = 60, tokenHubCompatibilityReadEnabled: Bool = true) {
        self.refreshSeconds = refreshSeconds
        self.tokenHubCompatibilityReadEnabled = tokenHubCompatibilityReadEnabled
    }

    static func decode(_ data: Data?) -> SeasunPreferences {
        guard let data,
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let values = root as? [String: Any] else { return SeasunPreferences() }

        let refresh: TimeInterval
        if let number = values["refreshSeconds"] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
           (15...3600).contains(number.doubleValue) {
            refresh = number.doubleValue
        } else { refresh = 60 }

        let compatibility: Bool
        if let current = values["tokenHubCompatibilityReadEnabled"] {
            compatibility = Self.boolean(current) ?? true
        } else {
            compatibility = Self.boolean(values["tokenHubAutomaticReadingEnabled"]) ?? true
        }
        return SeasunPreferences(refreshSeconds: refresh,
                                 tokenHubCompatibilityReadEnabled: compatibility)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

struct AppModelStartupDependencies {
    let loadPreferences: @MainActor () throws -> Data?
    let savePreferences: @MainActor (SeasunPreferences) throws -> Void
    let shouldStartBackgroundServices: @MainActor () -> Bool

    static var production: AppModelStartupDependencies {
        AppModelStartupDependencies(
            loadPreferences: { try ConfigStore.loadPreferences(at: AppPaths.configURL) },
            savePreferences: { try ConfigStore.savePreferences($0) },
            shouldStartBackgroundServices: { !CommandLine.arguments.contains("--disable-background-services") })
    }
}

/// The only direct-quota value allowed to cross the worker boundary.  It
/// deliberately contains no process identity, URL, database path, session,
/// bearer token, or response body.  The worker validates the target identity
/// before and after the request and returns only these displayable facts.
struct DirectQuotaTransportSnapshot: Sendable {
    let fiveHour: TokenHubWindowQuota?
    let sevenDay: TokenHubWindowQuota?
    let monthly: TokenHubMonthlyUsage?
    let observedAt: Date

    func materializedSnapshot() -> TokenHubQuotaSnapshot {
        // The model keeps the historical snapshot shape for compatibility with
        // synthetic tests. Production never exposes the real PID or executable
        // path; worker-side identity checks already completed this transaction.
        // Keep the legacy snapshot shape for UI/tests, but never carry the
        // worker's real PID or executable path across the actor boundary.
        let sanitizedIdentity = TokenHubIdentity(pid: 0, bundleID: TokenHubTarget.bundleID,
                                                  executablePath: "sanitized")
        return TokenHubQuotaSnapshot(identity: sanitizedIdentity, fiveHour: fiveHour,
                                     sevenDay: sevenDay, monthly: monthly,
                                     observedAt: observedAt)
    }

    init(snapshot: TokenHubQuotaSnapshot) {
        fiveHour = snapshot.fiveHour; sevenDay = snapshot.sevenDay
        monthly = snapshot.monthly; observedAt = snapshot.observedAt
    }
}

/// Owns process discovery, settings/SQLite reads and the authenticated direct
/// fetch away from the main actor. No identity or credential leaves this actor.
private actor TokenHubDirectQuotaWorker {
    private let client = TokenHubDirectQuotaClient()

    func fetch(now: Date) async throws -> DirectQuotaTransportSnapshot {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: TokenHubTarget.bundleID)
            .filter { !$0.isTerminated }
        guard !applications.isEmpty else { throw TokenHubQuotaFailure.noTarget }
        guard applications.count == 1, let app = applications.first,
              let executable = app.executableURL?.standardizedFileURL.path,
              let bundle = app.bundleIdentifier else {
            throw applications.count > 1 ? TokenHubQuotaFailure.multipleTargets : TokenHubQuotaFailure.identityChanged
        }
        let identity = TokenHubIdentity(pid: app.processIdentifier, bundleID: bundle, executablePath: executable)
        let snapshot = try await client.fetch(identity: identity, now: now)
        try Task.checkCancellation()
        // TokenHubDirectQuotaClient revalidates its settings/database identity
        // around the network exchange. Do not return the target identity.
        return DirectQuotaTransportSnapshot(snapshot: snapshot)
    }
}

/// Keep external process discovery and authenticated I/O outside lifecycle
/// handling. Explicit injection also lets previews exercise the direct path
/// using entirely synthetic identities and responses.
struct TokenHubDirectQuotaDependencies {
    let discoverTarget: () throws -> TokenHubIdentity
    let identityIsCurrent: (TokenHubIdentity) -> Bool
    let fetch: (TokenHubIdentity, Date) async throws -> TokenHubQuotaSnapshot
    /// Production uses this worker closure. The three actor-isolated closures
    /// remain as a compatibility seam for synthetic tests only.
    let workerFetch: (@Sendable (Date) async throws -> DirectQuotaTransportSnapshot)?

    init(discoverTarget: @escaping () throws -> TokenHubIdentity,
         identityIsCurrent: @escaping (TokenHubIdentity) -> Bool,
         fetch: @escaping (TokenHubIdentity, Date) async throws -> TokenHubQuotaSnapshot,
         workerFetch: (@Sendable (Date) async throws -> DirectQuotaTransportSnapshot)? = nil) {
        self.discoverTarget = discoverTarget
        self.identityIsCurrent = identityIsCurrent
        self.fetch = fetch
        self.workerFetch = workerFetch
    }

    static var production: TokenHubDirectQuotaDependencies {
        let worker = TokenHubDirectQuotaWorker()
        // These compatibility closures are intentionally inert in production;
        // all discovery/settings/network work is owned by the actor above.
        return TokenHubDirectQuotaDependencies(discoverTarget: { throw TokenHubQuotaFailure.noTarget },
            identityIsCurrent: { _ in false },
            fetch: { _, _ in throw TokenHubDirectQuotaFailure.transportFailed },
            workerFetch: { now in try await worker.fetch(now: now) })
    }
}

/// Owns the non-Sendable mutable cache on one checked executor. Only numeric
/// value snapshots cross back to the main actor; no cache reference escapes.
actor LocalCodexScanWorker {
    struct Result: Sendable {
        let snapshot: LocalCodexSnapshot
        let diagnostics: LocalCodexUsageReader.Cache.Diagnostics
    }

    private var cache = LocalCodexUsageReader.Cache()
    private var cacheGeneration: Int?

    func scan(directory: URL, now: Date, generation: Int,
              routeContext: LocalCodexRouteContext?) throws -> Result {
        // This method has no suspension point while the cache is in use:
        // actor isolation serializes complete reads, including invalidation.
        if cacheGeneration != generation {
            cache = LocalCodexUsageReader.Cache()
            cacheGeneration = generation
        }
        let snapshot = try LocalCodexUsageReader.scan(directory: directory, now: now,
                                                       cache: cache, routeContext: routeContext)
        return Result(snapshot: snapshot, diagnostics: cache.diagnostics)
    }

    /// Production discovery stays inside the same worker as file scanning so
    /// session paths and route origins never cross back through the main actor.
    func scanDefault(now: Date, generation: Int) throws -> Result {
        let directory = LocalCodexUsageReader.defaultSessionsDirectory()
        let routeContext = AppModel.seasunRouteContext()
        return try scan(directory: directory, now: now, generation: generation, routeContext: routeContext)
    }
}

/// Resolve the same permitted inputs on the main actor, then run bounded file
/// I/O in the cache owner. Injection replaces external I/O in lifecycle checks.
struct LocalCodexScanDependencies {
    struct Inputs: Sendable {
        let directory: URL
        let routeContext: LocalCodexRouteContext
    }
    /// Legacy injected seams are optional so production can expose only the
    /// worker-owned `scanDefault` path. Keeping these seams available for
    /// synthetic tests does not make a real sessions URL cross the actor
    /// boundary in the production configuration.
    let resolveInputs: (@MainActor () -> (directory: URL, routeContext: LocalCodexRouteContext))?
    let scan: (@Sendable (URL, Date, Int, LocalCodexRouteContext) async throws -> LocalCodexScanWorker.Result)?
    let scanDefault: (@Sendable (Date, Int) async throws -> LocalCodexScanWorker.Result)?

    init(resolveInputs: @escaping @MainActor () -> (directory: URL, routeContext: LocalCodexRouteContext),
         scan: @escaping @Sendable (URL, Date, Int, LocalCodexRouteContext) async throws -> LocalCodexScanWorker.Result,
         scanDefault: (@Sendable (Date, Int) async throws -> LocalCodexScanWorker.Result)? = nil) {
        self.resolveInputs = resolveInputs
        self.scan = scan
        self.scanDefault = scanDefault
    }

    private init(resolveInputs: (@MainActor () -> (directory: URL, routeContext: LocalCodexRouteContext))?,
                 scan: (@Sendable (URL, Date, Int, LocalCodexRouteContext) async throws -> LocalCodexScanWorker.Result)?,
                 scanDefault: (@Sendable (Date, Int) async throws -> LocalCodexScanWorker.Result)?) {
        self.resolveInputs = resolveInputs
        self.scan = scan
        self.scanDefault = scanDefault
    }

    @MainActor static var production: LocalCodexScanDependencies {
        let worker = LocalCodexScanWorker()
        // Do not retain a production closure that resolves the real sessions
        // URL on the main actor. Discovery and route reading remain inside the
        // same worker that owns the cache and performs the bounded file scan.
        return LocalCodexScanDependencies(resolveInputs: nil, scan: nil,
            scanDefault: { now, generation in try await worker.scanDefault(now: now, generation: generation) })
    }
}

struct BackgroundServiceResources: Equatable, Encodable {
    let timerCount: Int
    let workspaceObserverCount: Int
    let localScanQueuedCount: Int
    let axRefreshScheduledCount: Int
    let axScanInFlightCount: Int
}

/// A model-captured time used by one refresh request. Capturing this before a
/// delayed work item is enqueued keeps local/direct workers from consulting
/// independent wall clocks after the scheduling delay.
private struct RefreshObservationContext: Sendable, Equatable {
    let observationNow: Date
}

/// Clock-derived presentation changes are distinct from new measurements.
/// Comparing these cheap booleans keeps the half-second menu cadence without
/// formatting dates or invalidating every SwiftUI view when nothing changed.
struct PresentationTimeState: Equatable {
    struct Window: Equatable {
        let futureObservation: Bool
        let fresh: Bool
        let resetPassed: Bool
    }
    let localLive: Bool
    let tokenHubFresh: Bool
    let monthlyFresh: Bool
    let fiveHour: Window?
    let sevenDay: Window?
}

@MainActor final class AppModel: ObservableObject {
    // Explicit launch-only flag: fixtures never masquerade as enterprise measurements.
    let isTestFixture = CommandLine.arguments.contains("--test-fixture")
    private let isPreview: Bool
    private let startup: AppModelStartupDependencies
    private let directQuota: TokenHubDirectQuotaDependencies
    private let tokenHubAXSource: TokenHubAXSource
    private let usesDirectQuotaSource: Bool
    private(set) var backgroundServicesStarted = false
    private(set) var permissionPromptRequested = false
    @Published private(set) var preferences = SeasunPreferences() {
        didSet { capturePresentationTimeBaseline() }
    }
    @Published var config = AppConfiguration() {
        didSet {
            if oldValue.dataSource != config.dataSource {
                history.removeAll(keepingCapacity: true)
                lastHistorySampleAt = .distantPast
            }
            capturePresentationTimeBaseline()
        }
    }
    @Published var stats = MetricsSnapshot()
    @Published var localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0, filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil, knownThreadCount: 0, unknownThreadCount: 0, unidentifiedFileCount: 0, subagentCount: 0, forkCount: 0) {
        didSet { capturePresentationTimeBaseline() }
    }
    @Published var quota: QuotaSnapshot? {
        didSet { capturePresentationTimeBaseline() }
    }
    @Published var fiveHourQuota: WindowQuota? {
        didSet { capturePresentationTimeBaseline() }
    }
    @Published var sevenDayQuota: WindowQuota? {
        didSet { capturePresentationTimeBaseline() }
    }
    @Published var quotaError = "Token Hub 界面快照数据未知"
    @Published var sourceReadinessText = "企业后台直接来源未接通"
    @Published var message = ""
    @Published var history: [SpeedPoint] = []
    @Published var quotaLoading = false
    @Published private(set) var tokenHubQuotaSnapshot: TokenHubQuotaSnapshot? {
        didSet { capturePresentationTimeBaseline() }
    }
    @Published private(set) var tokenHubQuotaStatus: TokenHubQuotaStatus = .targetNotRunning {
        didSet { capturePresentationTimeBaseline() }
    }
    @Published private(set) var tokenHubQuotaFailure: TokenHubQuotaFailure?
    @Published private(set) var tokenHubDirectFailure: TokenHubDirectQuotaFailure?
    private(set) var tokenHubQuotaIsDirect = false
    var tokenHubAutomaticReadingEnabled: Bool {
        get { preferences.tokenHubCompatibilityReadEnabled }
        set { preferences.tokenHubCompatibilityReadEnabled = newValue }
    }
    var tokenHubPermissionProvider: TokenHubPermissionProviding = TokenHubNativePermissionProvider()
    var tokenHubNow: () -> Date = Date.init
    @Published var panelVisible = false
    let engine = MetricsEngine()
    private var timer: Timer?
    private var localScan: DispatchWorkItem?
    private var localScanRunning = false
    private var tokenHubRefreshWork: DispatchWorkItem?
    private var tokenHubScanInFlight = false
    private var tokenHubDirectScanInFlight = false
    private var tokenHubWorkspaceObservers: [NSObjectProtocol] = []
    private var lastTokenHubPermissionCheck = Date.distantPast
    private var cachedTokenHubPermission = false
    private let localScanning: LocalCodexScanDependencies
    private var localRefreshScheduler = LocalRefreshScheduler()
    private var isShuttingDown = false
    private var generation = 0
    private var tokenHubGeneration: UInt64 = 0
    private var tokenHubAXGeneration: UInt64 = 0
    private var lastPresentationTimeState: PresentationTimeState?
    private var lastHistorySampleAt = Date.distantPast
    var onTick: (() -> Void)?

    private static let historyDuration: TimeInterval = 10 * 60
    private static let historyCapacity = 1_200

    var isSeasunOnly: Bool { true }
    var tokenHubQuotaReadingEnabled: Bool { usesDirectQuotaSource || tokenHubAutomaticReadingEnabled }
    var userFacingStatus: String {
        if tokenHubQuotaIsDirect, tokenHubQuotaStatus == .connected {
            return "Seasun Token Hub 企业额度已自动读取；5 小时和 7 天重置时间来自后台响应。"
        }
        if let failure = tokenHubDirectFailure {
            return "Seasun Token Hub 企业后台直接来源：\(directFailureText(failure))。"
        }
        return "Seasun Token Hub 企业后台直接来源：尚未连接；额度、重置时间、月度用量和实时速度均未知。"
    }
    var sourceStatus: String { "unknown" }
    var activityIsLive: Bool {
        config.dataSource == "localCodex" ? freshLocalLiveTurn != nil : stats.active > 0
    }
    var backgroundServiceResources: BackgroundServiceResources {
        BackgroundServiceResources(timerCount: timer == nil ? 0 : 1,
            workspaceObserverCount: tokenHubWorkspaceObservers.count,
            localScanQueuedCount: localScan == nil || localScan!.isCancelled ? 0 : 1,
            axRefreshScheduledCount: tokenHubRefreshWork == nil || tokenHubRefreshWork!.isCancelled ? 0 : 1,
            axScanInFlightCount: tokenHubScanInFlight ? 1 : 0)
    }

    init(preview: Bool = false, startup: AppModelStartupDependencies = .production,
         directQuota: TokenHubDirectQuotaDependencies? = nil,
         localScanning: LocalCodexScanDependencies? = nil,
         tokenHubAXSource: TokenHubAXSource? = nil) {
        isPreview = preview
        self.startup = startup
        self.directQuota = directQuota ?? .production
        self.tokenHubAXSource = tokenHubAXSource ?? .production
        self.localScanning = localScanning ?? .production
        usesDirectQuotaSource = directQuota != nil || !(preview || CommandLine.arguments.contains("--test-fixture"))
        if preview {
            sourceReadinessText = "模拟预览 · 无配置读取、无自动服务"
            return
        }
        do {
            preferences = SeasunPreferences.decode(try startup.loadPreferences()).normalized
        } catch {
            message = "无法读取本地偏好设置；当前使用安全默认值。"
        }
        applyPreferencesToPresentationConfig()
        if startup.shouldStartBackgroundServices() {
            backgroundServicesStarted = true
            startBackgroundServices()
        }
    }
    func shutdown() {
        isShuttingDown = true; backgroundServicesStarted = false
        generation += 1; _ = localRefreshScheduler.invalidate()
        timer?.invalidate(); timer = nil; localScan?.cancel(); localScan = nil
        tokenHubGeneration &+= 1
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        for observer in tokenHubWorkspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        tokenHubWorkspaceObservers.removeAll()
        tokenHubQuotaSnapshot = nil; tokenHubQuotaStatus = .disabled; tokenHubQuotaFailure = nil
        tokenHubDirectFailure = nil; tokenHubQuotaIsDirect = false; tokenHubDirectScanInFlight = false
    }
    func tick() {
        // The formal local-history mode never consumes proxy engine metrics.
        // Publishing its identical empty snapshot would redraw a hidden or
        // open dashboard twice a second. Legacy proxy previews keep sampling.
        if config.dataSource != "localCodex" { stats = engine.snapshot() }
        let now = tokenHubNow()
        var publishedTransition = false
        // Check presence first: creating a date formatter for an absent quota
        // was otherwise part of every idle menu tick.
        if let quota, quota.month != QuotaSnapshot.currentMonth(at: now) {
            self.quota = nil; quotaError = "已跨月，等待本月用量"
            publishedTransition = true
        }
        if tokenHubQuotaStatus == .connected, freshTokenHubQuota(at: now) == nil {
            tokenHubQuotaStatus = .stale
            publishedTransition = true
        }
        if backgroundServicesStarted { pollTokenHubPermissionIfDue() }
        updateLocalHistory(at: now)
        let timeState = presentationTimeState
        if let previous = lastPresentationTimeState, previous != timeState, !publishedTransition {
            objectWillChange.send()
        }
        lastPresentationTimeState = timeState
        onTick?()
    }

    /// Keep one bounded point per half-second for ten minutes. Only fresh local
    /// estimates enter this series; stale or unknown values create no fake
    /// zero-speed samples and mode switches cannot leak proxy observations.
    private func updateLocalHistory(at now: Date) {
        guard panelVisible, config.dataSource == "localCodex", let live = freshLocalLiveTurn,
              now.timeIntervalSince(lastHistorySampleAt) >= 0.5 else { return }
        lastHistorySampleAt = now
        let point = SpeedPoint(date: now, value: live.outputTPS)
        let cutoff = now.addingTimeInterval(-Self.historyDuration)
        history = (history + [point]).filter { $0.date >= cutoff }
        if history.count > Self.historyCapacity { history.removeFirst(history.count - Self.historyCapacity) }
    }
    var freshQuota: QuotaSnapshot? {
        let now = tokenHubNow()
        guard let quota, quota.month == QuotaSnapshot.currentMonth(at: now),
              quota.fetchedAt <= now,
              now.timeIntervalSince(quota.fetchedAt) < max(120, config.refreshSeconds * 2) else { return nil }
        return quota
    }
    /// A measurement can arrive and expire between timer ticks. Remember
    /// its time state after the input mutation, since SwiftUI may render that
    /// intervening published value even if the previous tick had no live data.
    private func capturePresentationTimeBaseline() {
        lastPresentationTimeState = presentationTimeState
    }
    var presentationTimeState: PresentationTimeState {
        let now = tokenHubNow()
        func window(_ value: WindowQuota?) -> PresentationTimeState.Window? {
            value.map { PresentationTimeState.Window(futureObservation: $0.fetchedAt > now,
                fresh: $0.isFresh(at: now, refreshSeconds: config.refreshSeconds),
                resetPassed: $0.resetsAt.map { $0 <= now } ?? false) }
        }
        return PresentationTimeState(localLive: freshLocalLiveTurn != nil,
            tokenHubFresh: freshTokenHubQuota(at: now) != nil, monthlyFresh: freshQuota != nil,
            fiveHour: window(fiveHourQuota), sevenDay: window(sevenDayQuota))
    }
    var currencyFactor: Double { config.currency == "CNY" ? config.usdToCNY : 1 }
    var currencySymbol: String { config.currency == "CNY" ? "¥" : "$" }
    var quotaSource: QuotaSource { isPreview && config.dataSource != "localCodex" ? .enterprise : .localCodex }
    var hasRequestData: Bool { quotaSource == .localCodex ? localSnapshot.knownThreadCount > 0 : stats.requests > 0 }
    var dataNotice: String {
        if isTestFixture { return "模拟测试 · 以下速度、Token、费用和配额均非企业真实数据" }
        if !isPreview {
            if tokenHubQuotaIsDirect, tokenHubQuotaStatus == .connected {
                return "企业额度已自动读取 Token Hub 后台；本地 Codex 历史记录与企业额度分开统计。"
            }
            if tokenHubDirectFailure != nil, tokenHubQuotaSnapshot == nil {
                return "企业后台直接来源暂不可用：\(tokenHubQuotaStatusText)"
            }
            return "企业后台直接来源尚未连接；本地 Codex 历史记录与 Token Hub 额度分别展示。"
        }
        if config.dataSource == "localCodex" { return "当前配置关联的本机 Codex 记录，历史路由未核验；当前扫描范围记录小计，实时速度为活动事件短窗口估算" }
        return hasRequestData ? "本次启动 · 仅统计经过本机代理的请求" : "未采集到请求数据 · 尚未观测到客户端流量"
    }
    /// Presentation checks freshness on every menu update, even if the local
    /// file scan stalls. A future or invalid observation is never called live.
    var freshLocalLiveTurn: LocalLiveTurnSummary? {
        let now = tokenHubNow()
        guard let live = localSnapshot.liveTurn,
              live.observedAt <= now, now.timeIntervalSince(live.observedAt) <= 15,
              live.inputTPS.isFinite, live.outputTPS.isFinite,
              live.inputTPS >= 0, live.outputTPS >= 0 else { return nil }
        return live
    }
    var title: String {
        if config.dataSource == "localCodex" {
            let rate: String
            if let live = freshLocalLiveTurn {
                rate = String(format: "实时≈%.1ftok/s", live.outputTPS)
            } else if let turn = localSnapshot.lastTurn {
                rate = String(format: "上轮均:%.1ftok/s", turn.outputTPS)
            } else {
                rate = "上轮均:—"
            }
            let uncertainty = localSnapshot.unknownThreadCount + localSnapshot.unidentifiedFileCount
            let total = localSnapshot.hasCompleteAccounting ? "Σ\(formatCompactCount(localSnapshot.total))"
                : localSnapshot.knownThreadCount > 0 ? "小计\(formatCompactCount(localSnapshot.total)) · 未核验\(uncertainty)" : "Σ— · 未核验\(uncertainty)"
            let sessions = localSnapshot.hasCompleteAccounting ? " · \(localSnapshot.sessionCount)顶层对话" : ""
            let quotaSuffix = tokenHubMenuSuffix
            return (isTestFixture ? "测试 " : "") + "\(rate) · \(total)\(sessions)\(quotaSuffix)"
        }
        let value = !hasRequestData ? "T:—" : stats.active > 0
            ? String(format: "T:≈%.1ftok/s", stats.outputTPS) : "T:0.0tok/s"
        let total = stats.requests > 0 ? formatCompactCount(stats.total) : "—"
        return (isTestFixture ? "测试 " : "") + "\(value) · Σ\(total) · 请求\(stats.requests)"
    }
    var menuTooltip: String {
        if isPreview && config.dataSource != "localCodex" {
            return "\(dataNotice) · \(sourceReadinessText)\n5 小时额度：\(quotaDescription(fiveHourQuota, source: .enterprise))\n7 天额度：\(quotaDescription(sevenDayQuota, source: .enterprise))"
        }
        let live = freshLocalLiveTurn.map { String(format: "实时估算：输入 %.1f · 输出 %.1f tok/s（观测于 %@）", $0.inputTPS, $0.outputTPS, $0.observedAt.formatted()) } ?? "实时估算：未知（无新鲜活动 token_count）"
        let turn = localSnapshot.lastTurn.map { String(format: "上轮记录均速：%.1f tok/s（完成于 %@）", $0.outputTPS, $0.completedAt.formatted()) } ?? "上轮记录均速：未知"
        let range = localSnapshot.latestEventAt.map { "最新记录：\($0.formatted())" } ?? "记录时间：未知"
        let coverage = "扫描范围最多32个物理文件；不是全部对话；每文件头64KiB与尾256KiB，总计10MiB；" + (localSnapshot.isLimited ? "本次达到扫描上限" : "本次安全检查 \(localSnapshot.filesScanned) 个物理文件")
        let input = localSnapshot.knownThreadCount > 0 ? formatCount(localSnapshot.input) : "未知"
        let output = localSnapshot.knownThreadCount > 0 ? formatCount(localSnapshot.output) : "未知"
        let amountLabel = localSnapshot.hasCompleteAccounting ? "本次扫描记录量" : "已核验记录小计"
        let total = localSnapshot.knownThreadCount > 0 ? formatCount(localSnapshot.total) : "未知"
        let hub = tokenHubTooltipDetail
        return "\(userFacingStatus)\n当前配置关联的本机 Codex 记录，历史路由未核验；当前扫描范围：输入 \(input) · 输出 \(output) · 总计 \(total) tokens（\(amountLabel) \(total) tokens）\n\(accountingDetail)\n\(coverage)；\(range)\n\(live)；\(turn)；实时值是最近活动 token_count 的短窗口估算；上轮均速含工具、网络和等待，不是模型瞬时生成速度\n\(hub)\n5 小时额度：\(quotaDescription(fiveHourQuota, source: .localCodex))\n7 天额度：\(quotaDescription(sevenDayQuota, source: .localCodex))"
    }
    private var tokenHubMenuSuffix: String {
        guard let snapshot = freshTokenHubQuota(at: tokenHubNow()) else { return "" }
        let windows = [snapshot.fiveHour.map { "5h剩 \(percentText($0.remainingPercent))" },
                       snapshot.sevenDay.map { "7d剩 \(percentText($0.remainingPercent))" }].compactMap { $0 }
        return windows.isEmpty ? "" : " · Hub \(windows.joined(separator: " / "))"
    }
    var menuTitleContainsTokenHubSuffix: Bool { !tokenHubMenuSuffix.isEmpty }
    var tokenHubPermissionGrantedForDiagnostics: Bool { cachedTokenHubPermission }
    var tokenHubPermissionRequiredForDiagnostics: Bool { tokenHubQuotaStatus == .permissionRequired }
    private var tokenHubTooltipDetail: String {
        let snapshot = freshTokenHubQuota(at: tokenHubNow())
        let five = snapshot?.fiveHour.map { "界面显示剩余 \(percentText($0.remainingPercent))（5 小时）" } ?? "5 小时未知"
        let seven = snapshot?.sevenDay.map { "界面显示剩余 \(percentText($0.remainingPercent))（7 天）" } ?? "7 天未知"
        let source = tokenHubQuotaIsDirect ? "Token Hub 后台直接响应" : "Token Hub 界面快照"
        let timing = tokenHubQuotaIsDirect ? "后台响应已提供" : "后台更新时间未提供"
        let currency = tokenHubQuotaIsDirect ? "币种来自后台响应" : "币种未核验"
        return "\(source)：\(five) · \(seven)；\(tokenHubQuotaStatusText)；\(timing)；\(currency)"
    }
    private func percentText(_ value: Decimal) -> String {
        TwoDecimalPercentFormatter.string(value)
    }
    var tokenHubQuotaStatusText: String {
        if tokenHubQuotaIsDirect, tokenHubQuotaStatus == .connected { return "企业后台已直接读取" }
        if tokenHubQuotaSnapshot == nil, let failure = tokenHubDirectFailure { return directFailureText(failure) }
        return switch tokenHubQuotaStatus {
        case .disabled: "自动读取已关闭"
        case .permissionRequired: "未授权辅助功能"
        case .targetNotRunning: "Token Hub 未运行"
        case .ambiguousTarget: "检测到多个 Token Hub 进程"
        case .quotaGroupUnavailable: "找不到用量和限额页"
        case .unsupportedLayout: "用量页面布局暂不支持"
        case .accessFailed: "辅助功能读取失败"
        case .stale: "界面快照已过期"
        case .connected: "界面快照已读取"
        }
    }
    private func directFailureText(_ failure: TokenHubDirectQuotaFailure) -> String {
        switch failure {
        case .credentialExpired: "Token Hub 会话已过期"
        case .identityChanged: "Token Hub 进程在读取期间发生变化"
        case .connectionUnavailable, .connectionMalformed, .databaseUnsafe: "Token Hub 连接配置不可用"
        case .sessionUnavailable: "Token Hub 本机登录态不可用"
        case .exchangeFailed, .redirectMissing, .accessTokenMissing: "Token Hub 登录态交换失败"
        case .endpointRejected: "Token Hub 地址不在受信范围"
        case .httpStatus(let status) where status == 401 || status == 403: "Token Hub 会话未获授权"
        case .httpStatus: "Token Hub 后台暂时不可用"
        case .responseTooLarge, .malformedResponse, .noRecognizedWindows: "Token Hub 返回数据无法核验"
        case .duplicateWindow, .duplicateMonthly: "Token Hub 返回了重复额度窗口"
        case .transportFailed: "Token Hub 网络请求失败"
        }
    }
    private var accountingDetail: String {
        "已核验线程 \(localSnapshot.knownThreadCount) · 未核验线程 \(localSnapshot.unknownThreadCount) · 未识别文件 \(localSnapshot.unidentifiedFileCount) · 子代理 \(localSnapshot.subagentCount) · 分叉 \(localSnapshot.forkCount) · 顶层对话 \(localSnapshot.sessionCount)"
    }
    private func quotaDescription(_ quota: WindowQuota?, source: QuotaSource) -> String {
        let presentation = WindowQuotaCard.presentation(for: quota, at: tokenHubNow(), refreshSeconds: config.refreshSeconds, source: source)
        guard let usedPercent = presentation.usedPercent else { return "\(presentation.sourceLabel) · \(presentation.statusLabel)" }
        let resetLabel = source == .localCodex || !presentation.isFresh ? "原重置时间" : "重置时间"
        let reset = presentation.resetsAt.map { "，\(resetLabel) \($0.formatted())" } ?? "，重置时间未知"
        let recorded = presentation.recordedAt.map { "，记录于 \($0.formatted())" } ?? ""
        return "\(presentation.sourceLabel) · \(presentation.statusLabel)，上游已用 \(TwoDecimalPercentFormatter.string(usedPercent))\(reset)\(recorded)"
    }
    private func formatCount(_ value: Int) -> String { value.formatted(.number) }
    private func formatCompactCount(_ value: Int) -> String { value.formatted(.number.notation(.compactName)) }
    var alertColor: NSColor {
        if tokenHubQuotaIsDirect, let snapshot = freshTokenHubQuota(at: tokenHubNow()) {
            let windows = [snapshot.fiveHour?.usedPercent, snapshot.sevenDay?.usedPercent].compactMap { $0 }
            guard let used = windows.max() else { return .labelColor }
            if used >= Decimal(string: "95")! { return .systemRed }
            if used >= Decimal(string: "80")! { return .systemYellow }
            return .labelColor
        }
        guard quotaSource == .enterprise else { return .labelColor }
        let windows = (quotaSource == .enterprise ? [fiveHourQuota, sevenDayQuota].compactMap { $0 } : [])
            .filter { $0.isFresh(at: tokenHubNow(), refreshSeconds: config.refreshSeconds) }.map { $0.usedPercent / 100 }
        guard let ratio = (windows + [freshQuota?.fraction].compactMap { $0 }).max() else { return .labelColor }
        return ratio >= 0.95 ? .systemRed : ratio >= 0.8 ? .systemYellow : .labelColor
    }
    /// Kept for the synthetic legacy core-state regression only; never used by the formal Settings path.
    static func configurationForApplying(_ draft: AppConfiguration,
                                         automaticReadingEnabled: Bool) -> AppConfiguration {
        var configuration = draft
        configuration.tokenHubAutomaticReadingEnabled = automaticReadingEnabled
        return configuration
    }

    func savePreferences(_ newPreferences: SeasunPreferences) -> Bool {
        let normalized = newPreferences.normalized
        do {
            try startup.savePreferences(normalized)
        } catch {
            message = "偏好设置保存失败；当前设置保持不变。"
            return false
        }
        preferences = normalized
        applyPreferencesToPresentationConfig()
        message = "偏好设置已保存。"
        restartBackgroundServicesIfPermitted()
        return true
    }

    func reload() {
        do {
            let loaded = try startup.loadPreferences()
            preferences = SeasunPreferences.decode(loaded).normalized
            applyPreferencesToPresentationConfig()
            message = "偏好设置已重新加载。"
            restartBackgroundServicesIfPermitted()
        }
        catch { message = "偏好设置重新加载失败；当前设置保持不变。" }
    }

    private func applyPreferencesToPresentationConfig() {
        // This compatibility projection exists for the local-history views and synthetic tests.
        // No integration field is loaded from the old plist or used to activate an app service.
        var safe = AppConfiguration()
        safe.dataSource = "localCodex"
        safe.refreshSeconds = preferences.refreshSeconds
        safe.tokenHubAutomaticReadingEnabled = preferences.tokenHubCompatibilityReadEnabled
        config = safe
        tokenHubQuotaStatus = tokenHubQuotaReadingEnabled ? .targetNotRunning : .disabled
    }

    private func restartBackgroundServicesIfPermitted() {
        guard !isPreview, !isShuttingDown else { return }
        guard startup.shouldStartBackgroundServices() else {
            stopBackgroundServices()
            return
        }
        backgroundServicesStarted = true
        startBackgroundServices()
    }

    private func startBackgroundServices() {
        guard !isPreview, !isShuttingDown, backgroundServicesStarted else { return }
        stopBackgroundResources()
        generation += 1; tokenHubGeneration &+= 1
        history.removeAll(keepingCapacity: true)
        lastHistorySampleAt = .distantPast
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        tokenHubQuotaSnapshot = nil; tokenHubQuotaFailure = nil
        tokenHubDirectFailure = nil; tokenHubQuotaIsDirect = false; tokenHubDirectScanInFlight = false
        tokenHubQuotaStatus = tokenHubQuotaReadingEnabled ? .targetNotRunning : .disabled
        lastTokenHubPermissionCheck = .distantPast; cachedTokenHubPermission = false
        _ = localRefreshScheduler.invalidate()
        localScan?.cancel(); localScan = nil
        localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0,
            filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
            knownThreadCount: 0, unknownThreadCount: 0, unidentifiedFileCount: 0,
            subagentCount: 0, forkCount: 0)
        resetQuotaState()
        let observationNow = tokenHubNow()
        scheduleLocalScan(immediate: true, observationNow: observationNow)
        if tokenHubQuotaReadingEnabled { scheduleTokenHubRefresh(after: 0, observationNow: observationNow) }
        installTokenHubWorkspaceObservers()
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        timer?.tolerance = 0.1
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func stopBackgroundResources() {
        timer?.invalidate(); timer = nil
        localScan?.cancel(); localScan = nil
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        for observer in tokenHubWorkspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        tokenHubWorkspaceObservers.removeAll()
    }

    private func stopBackgroundServices() {
        backgroundServicesStarted = false
        generation += 1; tokenHubGeneration &+= 1
        _ = localRefreshScheduler.invalidate()
        stopBackgroundResources()
        tokenHubQuotaSnapshot = nil; tokenHubQuotaFailure = nil
        tokenHubDirectFailure = nil; tokenHubQuotaIsDirect = false; tokenHubDirectScanInFlight = false
        tokenHubQuotaStatus = tokenHubQuotaReadingEnabled ? .targetNotRunning : .disabled
    }
    /// Clears quota values at a source transition without performing I/O.
    func resetQuotaState() {
        quota = nil
        fiveHourQuota = nil
        sevenDayQuota = nil
        quotaLoading = false
        quotaError = "Token Hub 界面快照数据未知"
    }
    private func scheduleLocalScan(immediate: Bool = false, observationNow scheduledObservationNow: Date? = nil) {
        guard backgroundServicesStarted else { return }
        let context = RefreshObservationContext(observationNow: scheduledObservationNow ?? tokenHubNow())
        localScan?.cancel()
        let version = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard !self.isShuttingDown, self.backgroundServicesStarted, self.generation == version,
                      self.config.dataSource == "localCodex" else { return }
                guard !self.localScanRunning else { return }
                guard let scanGeneration = self.localRefreshScheduler.begin(now: Date()) else {
                    self.scheduleLocalScan(immediate: false); return
                }
                self.localScanRunning = true
                let observationNow = context.observationNow
                // Production discovers the path and route inside the scan
                // worker. Injected legacy seams remain available for tests.
                let result: LocalCodexScanWorker.Result?
                if let scanDefault = self.localScanning.scanDefault {
                    result = try? await scanDefault(observationNow, version)
                } else {
                    if let resolveInputs = self.localScanning.resolveInputs,
                       let scan = self.localScanning.scan {
                        let inputs = resolveInputs()
                        result = try? await scan(inputs.directory, observationNow,
                                                version, inputs.routeContext)
                    } else {
                        result = nil
                    }
                }
                self.localScanRunning = false
                guard self.generation == version, self.localRefreshScheduler.complete(generation: scanGeneration, now: Date()) else {
                    if self.config.dataSource == "localCodex", self.backgroundServicesStarted, !self.isShuttingDown { self.scheduleLocalScan(immediate: true) }
                    return
                }
                if self.config.dataSource == "localCodex" {
                    if let snapshot = result?.snapshot {
                        self.localSnapshot = snapshot; self.fiveHourQuota = snapshot.fiveHour; self.sevenDayQuota = snapshot.sevenDay
                        self.quotaError = snapshot.latestEventAt == nil ? "未发现有效本地用量记录" : "额度来自 Codex 会话事件，可能已过期"
                    } else {
                        self.localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0, filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil, knownThreadCount: 0, unknownThreadCount: 0, unidentifiedFileCount: 0, subagentCount: 0, forkCount: 0)
                        self.fiveHourQuota = nil; self.sevenDayQuota = nil; self.quotaError = "本地会话记录暂时无法读取"
                    }
                }
                if self.config.dataSource == "localCodex", self.backgroundServicesStarted { self.scheduleLocalScan() }
            }
        }
        localScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 5), execute: work)
    }

    /// Associates the current Codex provider with this local Token Hub's
    /// configured origin. Historical rollout routes are not independently
    /// verifiable from the current provider name and configuration alone.
    nonisolated fileprivate static func seasunRouteContext() -> LocalCodexRouteContext {
        let configURL = LocalCodexUsageReader.defaultConfigURL()
        guard let active = GatewayDiscovery.activeCodexProvider(at: configURL),
              let connectionURLs = try? TokenHubConnectionDiscovery.readDefaultConnectionBaseURLs(),
              let activeOrigin = GatewayDiscovery.originKey(active.origin),
              connectionURLs.compactMap({ GatewayDiscovery.originKey($0) }).contains(activeOrigin) else {
            return .unverified
        }
        return .verified(provider: active.provider, origin: activeOrigin)
    }
    /// Production refresh first uses Token Hub's own read-only connection and
    /// in-memory SSO exchange. Preview and synthetic tests retain the
    /// bounded AX scanner path without touching real local credentials.
    func refreshTokenHubQuota(observationNow: Date? = nil) {
        guard !isShuttingDown else { return }
        guard config.dataSource == "localCodex", tokenHubQuotaReadingEnabled else {
            invalidateTokenHubQuota(status: .disabled); tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
            return
        }
        if !usesDirectQuotaSource {
            refreshTokenHubQuotaUsingAccessibility()
            return
        }
        if tokenHubAutomaticReadingEnabled { checkTokenHubPermissionIfDue(scheduleIfGranted: false) }
        guard !tokenHubDirectScanInFlight else { return }

        let version = tokenHubGeneration
        let now = observationNow ?? tokenHubNow()
        let source = directQuota
        let interval = config.refreshSeconds
        // Production resolves the target, reads settings and performs the
        // direct request inside its worker actor. Only the sanitized DTO
        // returns to this main-actor model.
        if let workerFetch = source.workerFetch {
            tokenHubDirectScanInFlight = true
            Task { [weak self] in
                let result: Result<DirectQuotaTransportSnapshot, Error>
                do { result = .success(try await workerFetch(now)) }
                catch { result = .failure(error) }
                guard let self else { return }
                guard !self.isShuttingDown, self.tokenHubGeneration == version else { return }
                self.tokenHubDirectScanInFlight = false
                guard self.config.dataSource == "localCodex", self.tokenHubQuotaReadingEnabled else { return }
                switch result {
                case .success(let transport):
                    self.tokenHubQuotaSnapshot = transport.materializedSnapshot()
                    self.tokenHubStatusConnected(interval: interval)
                case .failure(let error):
                    self.tokenHubStatusFailed(error, interval: interval)
                }
            }
            return
        }

        // Compatibility path for injected synthetic tests. Production never
        // reaches this branch, so its discovery and settings reads stay off
        // the main actor.
        let identity: TokenHubIdentity
        do { identity = try directQuota.discoverTarget() }
        catch {
            tokenHubDirectScanInFlight = false
            tokenHubQuotaSnapshot = nil; tokenHubQuotaIsDirect = false
            tokenHubDirectFailure = nil
            tokenHubQuotaStatus = (error as? TokenHubQuotaFailure) == .noTarget ? .targetNotRunning : .ambiguousTarget
            sourceReadinessText = tokenHubQuotaStatus == .targetNotRunning ? "Token Hub 未运行" : "检测到多个 Token Hub 进程"
            scheduleTokenHubRefresh(after: config.refreshSeconds)
            return
        }
        tokenHubDirectScanInFlight = true
        Task { [weak self] in
            let result: Result<TokenHubQuotaSnapshot, Error>
            do { result = .success(try await source.fetch(identity, now)) }
            catch { result = .failure(error) }
            guard let self else { return }
            // Invalidation already released the old generation. Its late
            // completion must not unlock a newer generation's active request.
            guard !self.isShuttingDown, self.tokenHubGeneration == version else { return }
            self.tokenHubDirectScanInFlight = false
            guard self.config.dataSource == "localCodex", self.tokenHubQuotaReadingEnabled else { return }
            switch result {
            case .success(let snapshot):
                guard source.identityIsCurrent(identity) else {
                    self.tokenHubQuotaSnapshot = nil
                    self.tokenHubQuotaIsDirect = false
                    self.tokenHubDirectFailure = .identityChanged
                    self.tokenHubQuotaStatus = .accessFailed
                    self.tokenHubQuotaFailure = nil
                    self.sourceReadinessText = "企业后台直接来源：\(self.directFailureText(.identityChanged))"
                    self.scheduleTokenHubRefresh(after: interval)
                    return
                }
                self.tokenHubQuotaSnapshot = snapshot
                self.tokenHubStatusConnected(interval: interval)
            case .failure(let error):
                self.tokenHubStatusFailed(error, interval: interval)
            }
        }
    }

    private func tokenHubStatusConnected(interval: TimeInterval) {
        tokenHubQuotaStatus = .connected
        tokenHubQuotaFailure = nil
        tokenHubDirectFailure = nil
        tokenHubQuotaIsDirect = true
        sourceReadinessText = "企业额度已自动读取 Token Hub 后台"
        scheduleTokenHubRefresh(after: interval)
    }

    private func tokenHubStatusFailed(_ error: Error, interval: TimeInterval) {
        let failure = (error as? TokenHubDirectQuotaFailure) ?? .transportFailed
        tokenHubQuotaSnapshot = nil
        tokenHubQuotaIsDirect = false
        tokenHubDirectFailure = failure
        if let targetFailure = error as? TokenHubQuotaFailure, targetFailure == .noTarget {
            tokenHubDirectFailure = nil
            tokenHubQuotaStatus = .targetNotRunning
            sourceReadinessText = "Token Hub 未运行"
            scheduleTokenHubRefresh(after: interval)
            return
        }
        if let targetFailure = error as? TokenHubQuotaFailure, targetFailure == .multipleTargets {
            tokenHubDirectFailure = nil
            tokenHubQuotaStatus = .ambiguousTarget
            sourceReadinessText = "检测到多个 Token Hub 进程"
            scheduleTokenHubRefresh(after: interval)
            return
        }
        tokenHubQuotaStatus = .accessFailed
        tokenHubQuotaFailure = nil
        sourceReadinessText = "企业后台直接来源：\(directFailureText(failure))"
        // AX is an optional compatibility fallback only when the user has
        // already granted trust; it never gates direct reading.
        if tokenHubAutomaticReadingEnabled, cachedTokenHubPermission, !isFixtureUsingNativeTokenHubReader {
            refreshTokenHubQuotaUsingAccessibility()
        } else {
            scheduleTokenHubRefresh(after: interval)
        }
    }

    private func refreshTokenHubQuotaUsingAccessibility() {
        guard !isShuttingDown else { return }
        guard !isFixtureUsingNativeTokenHubReader else { return }
        guard config.dataSource == "localCodex", tokenHubAutomaticReadingEnabled else {
            invalidateTokenHubQuota(status: .disabled); tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
            return
        }
        checkTokenHubPermissionIfDue(scheduleIfGranted: false)
        guard cachedTokenHubPermission else {
            invalidateAccessibilityQuota(status: .permissionRequired)
            // Trust can be revoked while the direct request is in flight.
            // Its optional fallback must not cancel the unattended retry loop.
            if usesDirectQuotaSource { scheduleTokenHubRefresh(after: config.refreshSeconds) }
            return
        }
        guard !tokenHubScanInFlight else { return }
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        tokenHubScanInFlight = true
        let version = tokenHubGeneration, axVersion = tokenHubAXGeneration, mode: TokenHubRunMode = .localCodex
        let now = tokenHubNow(), interval = config.refreshSeconds
        let source = tokenHubAXSource
        let request = TokenHubAXRequest(now: now, permissionTrusted: cachedTokenHubPermission,
            refreshSeconds: interval, mode: mode, generation: version)
        Task(priority: .utility) { [weak self] in
            // The main actor only awaits a value. Native traversal runs as one
            // non-suspending operation on its private worker actor.
            let result = await source.scan(request)
            guard let self else { return }
            self.tokenHubScanInFlight = false
            guard !self.isShuttingDown, self.tokenHubGeneration == version, self.tokenHubAXGeneration == axVersion,
                  self.config.dataSource == "localCodex", self.tokenHubAutomaticReadingEnabled,
                  self.cachedTokenHubPermission, !self.tokenHubQuotaIsDirect else {
                if !self.isShuttingDown, self.config.dataSource == "localCodex",
                   self.tokenHubQuotaReadingEnabled {
                    self.scheduleTokenHubRefresh(after: self.tokenHubQuotaIsDirect ? interval : 0)
                }
                return
            }
            self.applyTokenHubQuotaResult(result, generation: version, mode: mode, now: now)
            self.scheduleTokenHubRefresh(after: self.config.refreshSeconds)
        }
    }

    func setTokenHubAutomaticReadingEnabled(_ enabled: Bool) {
        guard tokenHubAutomaticReadingEnabled != enabled else { return }
        preferences.tokenHubCompatibilityReadEnabled = enabled
        tokenHubAXGeneration &+= 1
        config.tokenHubAutomaticReadingEnabled = enabled
        if usesDirectQuotaSource {
            // This preference controls only AX compatibility; it cannot turn
            // off the unattended enterprise source or discard its snapshot.
            if !tokenHubQuotaIsDirect {
                tokenHubQuotaSnapshot = nil; tokenHubQuotaFailure = nil
                tokenHubQuotaStatus = .targetNotRunning
            }
            if config.dataSource == "localCodex", !isShuttingDown, backgroundServicesStarted || isPreview {
                scheduleTokenHubRefresh(after: 0)
            }
            return
        }
        tokenHubGeneration &+= 1
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        if enabled && config.dataSource == "localCodex" && !isShuttingDown && (backgroundServicesStarted || isPreview) {
            tokenHubQuotaStatus = .targetNotRunning; tokenHubQuotaFailure = nil
            lastTokenHubPermissionCheck = .distantPast
            scheduleTokenHubRefresh(after: 0)
        } else { invalidateTokenHubQuota(status: .disabled) }
    }

    func requestTokenHubAccessibilityAccess() {
        guard !isPreview, !isTestFixture, config.dataSource == "localCodex", tokenHubAutomaticReadingEnabled, !isShuttingDown else { return }
        permissionPromptRequested = true
        tokenHubPermissionProvider.requestOnceAndOpenSystemSettings()
        lastTokenHubPermissionCheck = .distantPast
        checkTokenHubPermissionIfDue(scheduleIfGranted: false)
        if cachedTokenHubPermission { refreshTokenHubQuota() }
        else { invalidateAccessibilityQuota(status: .permissionRequired) }
    }

    private func invalidateAccessibilityQuota(status: TokenHubQuotaStatus) {
        tokenHubAXGeneration &+= 1
        if !usesDirectQuotaSource {
            invalidateTokenHubQuota(status: status)
        } else if !tokenHubQuotaIsDirect, !tokenHubDirectScanInFlight {
            tokenHubQuotaSnapshot = nil; tokenHubQuotaFailure = nil
            // Keep a direct failure (if any) visible; missing AX trust is not
            // a failure of the automatic source.
            if tokenHubDirectFailure == nil { tokenHubQuotaStatus = .targetNotRunning }
        }
    }

    func invalidateTokenHubQuota(status: TokenHubQuotaStatus) {
        tokenHubGeneration &+= 1
        tokenHubRefreshWork?.cancel(); tokenHubRefreshWork = nil
        tokenHubQuotaSnapshot = nil; tokenHubQuotaFailure = nil; tokenHubDirectFailure = nil
        tokenHubQuotaIsDirect = false; tokenHubDirectScanInFlight = false; tokenHubQuotaStatus = status
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
            tokenHubQuotaIsDirect = false
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
        guard config.dataSource == "localCodex", tokenHubQuotaReadingEnabled,
              tokenHubQuotaStatus == .connected, let snapshot = tokenHubQuotaSnapshot,
              snapshot.observedAt <= now,
              now.timeIntervalSince(snapshot.observedAt) <= max(120, config.refreshSeconds * 2) else { return nil }
        return snapshot
    }

    private func checkTokenHubPermissionIfDue(scheduleIfGranted: Bool = true) {
        guard backgroundServicesStarted || isPreview else { return }
        let now = tokenHubNow()
        guard now.timeIntervalSince(lastTokenHubPermissionCheck) >= 2 else { return }
        let old = cachedTokenHubPermission
        cachedTokenHubPermission = tokenHubPermissionProvider.isTrusted()
        lastTokenHubPermissionCheck = now
        if old && !cachedTokenHubPermission { invalidateAccessibilityQuota(status: .permissionRequired) }
        if scheduleIfGranted && !old && cachedTokenHubPermission && config.dataSource == "localCodex" && tokenHubAutomaticReadingEnabled {
            scheduleTokenHubRefresh(after: 0)
        }
    }

    private func pollTokenHubPermissionIfDue() {
        guard backgroundServicesStarted, config.dataSource == "localCodex", tokenHubAutomaticReadingEnabled, !isShuttingDown,
              !isFixtureUsingNativeTokenHubReader else { return }
        checkTokenHubPermissionIfDue()
    }

    private func scheduleTokenHubRefresh(after seconds: TimeInterval, observationNow scheduledObservationNow: Date? = nil) {
        guard (backgroundServicesStarted || isPreview), config.dataSource == "localCodex", tokenHubQuotaReadingEnabled,
              !isShuttingDown, (usesDirectQuotaSource || !tokenHubScanInFlight), !isFixtureUsingNativeTokenHubReader else { return }
        let context = RefreshObservationContext(observationNow: scheduledObservationNow ?? tokenHubNow())
        tokenHubRefreshWork?.cancel()
        let version = tokenHubGeneration
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.isShuttingDown, self.tokenHubGeneration == version,
                      self.config.dataSource == "localCodex", self.tokenHubQuotaReadingEnabled else { return }
                self.refreshTokenHubQuota(observationNow: context.observationNow)
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
            scannerIsNative: tokenHubAXSource.kind == .native)
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
        guard isPreview || backgroundServicesStarted else { return }
        guard bundleIdentifier == TokenHubTarget.bundleID, !isShuttingDown else { return }
        invalidateTokenHubQuota(status: config.dataSource == "localCodex" ? .targetNotRunning : .disabled)
    }

    /// Metadata-only lifecycle seam; a launch never makes an old snapshot current.
    func tokenHubApplicationDidLaunch(bundleIdentifier: String) {
        guard isPreview || backgroundServicesStarted else { return }
        guard bundleIdentifier == TokenHubTarget.bundleID, !isShuttingDown else { return }
        invalidateTokenHubQuota(status: config.dataSource == "localCodex" && tokenHubQuotaReadingEnabled
            ? .targetNotRunning : .disabled)
        guard config.dataSource == "localCodex", tokenHubQuotaReadingEnabled,
              !isFixtureUsingNativeTokenHubReader else { return }
        if usesDirectQuotaSource {
            scheduleTokenHubRefresh(after: 0)
            return
        }
        checkTokenHubPermissionIfDue(scheduleIfGranted: false)
        guard cachedTokenHubPermission else {
            tokenHubQuotaStatus = .permissionRequired
            return
        }
        scheduleTokenHubRefresh(after: 0)
    }

}
```

### Sources/TokenStatMenu/DashboardView.swift

```swift
import SwiftUI
#if SWIFT_PACKAGE
import TokenStatCore
#endif

// Select the property wrapper explicitly for SDKs that also expose a State macro.
typealias ValueState<Value> = SwiftUI.State<Value>

@MainActor struct DashboardView: View {
    @ObservedObject var model: AppModel
    @ValueState private var settings = false
    private let initialLocalHistoryExpanded: Bool
    init(model: AppModel, settings: Bool = false, localHistoryExpanded: Bool = false) {
        self.model = model
        _settings = State(initialValue: settings)
        initialLocalHistoryExpanded = localHistoryExpanded
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
                    overviewContent
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
    /// Shared with full-content rendering checks, including the actual card
    /// styles and insets rather than a reconstruction outside the ScrollView.
    var overviewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            tokenHubCard
            Text(model.userFacingStatus)
                .font(.system(size: 10)).foregroundStyle(.secondary)
            localUsageCard
            if model.quotaSource == .localCodex {
                LocalHistoryDisclosure(initiallyExpanded: initialLocalHistoryExpanded) {
                    localQuotaCard
                }
            } else {
                // The generic enterprise branch is available to synthetic
                // previews only; production local history has its own section.
                HStack(alignment: .top, spacing: 10) {
                    WindowQuotaCard(title: "5 小时额度", quota: model.fiveHourQuota,
                        color: PanelPalette.blue, refreshSeconds: model.config.refreshSeconds, source: model.quotaSource)
                    WindowQuotaCard(title: "7 天额度", quota: model.sevenDayQuota,
                        color: PanelPalette.violet, refreshSeconds: model.config.refreshSeconds, source: model.quotaSource)
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .groupBoxStyle(PanelCardStyle())
        .tint(PanelPalette.blue)
    }
    var tokenHubCard: TokenHubQuotaCard {
        TokenHubQuotaCard(snapshot: model.freshTokenHubQuota(at: model.tokenHubNow()), status: model.tokenHubQuotaStatusText,
            enabled: model.tokenHubQuotaReadingEnabled, refreshSeconds: model.preferences.refreshSeconds,
            directSource: model.tokenHubQuotaIsDirect)
    }
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(PanelPalette.gradient, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("TokenStatMenu").font(.system(size: 16, weight: .bold, design: .rounded))
                Text(settings ? "Seasun Token Hub · 偏好设置" : "Seasun Token Hub · \(model.tokenHubQuotaIsDirect && model.freshTokenHubQuota(at: model.tokenHubNow()) != nil ? "后台额度已连接" : "后台额度等待连接")")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { settings.toggle() } label: {
                Image(systemName: settings ? "chart.bar.xaxis" : "slider.horizontal.3")
                    .frame(width: HeaderActionMetrics.actionSize, height: HeaderActionMetrics.actionSize)
            }.buttonStyle(NeutralHeaderActionButtonStyle()).help(settings ? "返回概览" : "偏好设置")
                .accessibilityLabel(settings ? "返回概览" : "偏好设置")
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").frame(width: HeaderActionMetrics.actionSize, height: HeaderActionMetrics.actionSize)
            }.buttonStyle(NeutralHeaderActionButtonStyle()).help("退出 TokenStatMenu").accessibilityLabel("退出")
        }.padding(16)
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
                if let live = model.freshLocalLiveTurn {
                    metric("实时估算 · 输入 tok/s", String(format: "%.1f", live.inputTPS))
                    metric("实时估算 · 输出 tok/s", String(format: "%.1f", live.outputTPS))
                    metric("实时观测时间", live.observedAt.formatted(date: .abbreviated, time: .shortened))
                } else {
                    metric("实时估算 · 输出 tok/s", "未知")
                }
                if !model.history.isEmpty {
                    SpeedHistorySparkline(points: model.history)
                        .frame(height: 42)
                        .accessibilityLabel("最近十分钟输出 token 每秒变化")
                }
                if let turn = model.localSnapshot.lastTurn {
                    metric("上轮记录均速", String(format: "%.1f tok/s", turn.outputTPS))
                    metric("上轮完成时间", turn.completedAt.formatted(date: .abbreviated, time: .shortened))
                } else {
                    metric("上轮记录均速", "未知")
                }
                Text("汇总与当前配置关联的本机 Codex 记录；历史路由未核验，无法核算的记录不计入小计。实时值来自活动 token_count 的短窗口估算，事件停止推进时会变为未知；上轮均速含工具、网络和等待。\(model.localSnapshot.isLimited ? "已达到扫描范围限制。" : "")")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } label: { Label("本地记录用量", systemImage: "doc.text.magnifyingglass") }
    }
    private var localQuotaCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                historyWindow("5 小时历史", quota: model.fiveHourQuota)
                historyWindow("7 天历史", quota: model.sevenDayQuota)
                Text("本地记录额度始终只是历史参考，不论事件是否新鲜；不代表当前企业剩余额度，也不触发企业额度告警。保留源记录的已用比例、记录时间和原重置时间。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if let at = model.fiveHourQuota?.fetchedAt ?? model.sevenDayQuota?.fetchedAt { Text("额度事件时间：\(at.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        } label: { Label("本地 Codex 历史 · 账号/组织未核验", systemImage: "clock") }
    }
    private func historyWindow(_ title: String, quota: WindowQuota?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .medium))
            Text(localQuotaDescription(quota))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
    private func localQuotaDescription(_ quota: WindowQuota?) -> String {
        let state = WindowQuotaCard.presentation(for: quota, refreshSeconds: model.config.refreshSeconds, source: .localCodex)
        guard let percent = state.usedPercent else { return state.statusLabel }
        let reset = state.resetsAt.map { " · \($0.formatted(date: .abbreviated, time: .shortened))重置" } ?? " · 重置时间未知"
        let recorded = state.recordedAt.map { " · 记录于 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        return "\(state.sourceLabel) · \(state.statusLabel) · 上游已用 \(TwoDecimalPercentFormatter.string(percent))\(recorded)\(reset)"
    }
    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(model.activityIsLive ? Color.green : Color.secondary.opacity(0.5)).frame(width: 5, height: 5)
            Text(model.message.isEmpty ? model.sourceReadinessText : model.message)
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
}

/// Expansion belongs to this installed view, never to the model or preferences.
/// Keeping the State here also lets a detached overview be hosted for rendering
/// without accessing a State projection on an uninstalled DashboardView value.
private struct LocalHistoryDisclosure<Content: View>: View {
    @ValueState private var expanded: Bool
    private let content: Content

    init(initiallyExpanded: Bool, @ViewBuilder content: () -> Content) {
        _expanded = SwiftUI.State(initialValue: initiallyExpanded)
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content.padding(.top, 8)
        } label: {
            Label("本地历史额度（非企业当前额度）", systemImage: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .accessibilityHint("只显示本地历史记录，不代表企业当前剩余额度")
    }
}

private struct SpeedHistorySparkline: View {
    let points: [SpeedPoint]

    var body: some View {
        GeometryReader { proxy in
            let values = points.map(\.value)
            let maximum = max(values.max() ?? 1, 1)
            let minimum = values.min() ?? 0
            let span = max(maximum - minimum, 1)
            Path { path in
                for (index, point) in points.enumerated() {
                    let x = points.count <= 1 ? 0 : proxy.size.width * CGFloat(index) / CGFloat(points.count - 1)
                    let y = proxy.size.height * (1 - CGFloat((point.value - minimum) / span))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(PanelPalette.blue, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            .overlay(alignment: .topLeading) {
                Text("近 10 分钟 · 输出 tok/s")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
    }
}
```

### Sources/TokenStatMenu/SettingsView.swift

```swift
import SwiftUI

@MainActor struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ValueState private var draft: SeasunPreferences

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.preferences)
    }

    /// The Settings status follows the same fresh direct observation as the
    /// dashboard; optional AX compatibility cannot declare a backend connected.
    var sourceStatusText: String {
        if model.tokenHubQuotaIsDirect {
            return model.freshTokenHubQuota(at: model.tokenHubNow()) != nil
                ? "企业后台直接来源：已直接读取"
                : "企业后台直接来源：快照已过期，等待自动刷新"
        }
        if model.tokenHubDirectFailure != nil { return model.userFacingStatus }
        return "企业后台直接来源：尚未连接，等待自动读取"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Seasun Token Hub") {
                    VStack(alignment: .leading, spacing: 8) {
                Text("自动复用本机已登录 Hub 的现有会话，只读获取企业额度，无需填写接口或密钥。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("企业后台额度、本地 Codex 记录和可选界面快照分开标明来源；本地记录与界面快照不能代替后台额度。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(sourceStatusText)
                    .font(.caption)
                    .accessibilityIdentifier("seasun-source-status")
                    }
                }
                .accessibilityLabel("Seasun Token Hub")

                GroupBox("可选偏好") {
                    VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("刷新秒数（15–3600）")
                    Spacer()
                    TextField("60", value: $draft.refreshSeconds, format: .number)
                        .frame(width: 88)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                        .accessibilityLabel("刷新秒数")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("刷新秒数（15–3600）")
                Toggle("Token Hub 界面兼容读取（可选）", isOn: $draft.tokenHubCompatibilityReadEnabled)
                    .accessibilityIdentifier("token-hub-compatibility-toggle")
                    .accessibilityLabel("Token Hub 界面兼容读取（可选）")
                Text("此开关只控制界面快照；关闭后仍自动读取企业后台。兼容读取默认启用，不会自动请求辅助功能授权。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("保存偏好") {
                        if model.savePreferences(draft) { draft = model.preferences }
                    }.buttonStyle(.borderedProminent)
                    Button("重新加载偏好") {
                        model.reload()
                        draft = model.preferences
                    }
                    Spacer()
                }
                if !model.message.isEmpty {
                    Text(model.message).font(.caption2).foregroundStyle(.secondary)
                }
                    }
                }

                GroupBox("兼容读取授权") {
                    VStack(alignment: .leading, spacing: 8) {
                Text(model.tokenHubQuotaStatusText)
                    .font(.caption)
                Button("请求辅助功能访问…") {
                    model.requestTokenHubAccessibilityAccess()
                }
                .disabled(model.isTestFixture || !draft.tokenHubCompatibilityReadEnabled)
                Text("此权限仅用于读取界面快照，不用于连接企业后台。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .accessibilityElement(children: .contain)
        }
        .textFieldStyle(.roundedBorder)
    }
}
```

### Sources/TokenStatMenu/StatusBarController.swift

```swift
import AppKit
import Combine
import SwiftUI

/// Native content factories keep expensive view construction at the UI
/// boundary; tests can wrap the real builders using synthetic models.
struct StatusBarContentFactories {
    let dashboard: @MainActor (AppModel) -> NSViewController
    let tooltip: @MainActor (AppModel) -> String
    static var production: StatusBarContentFactories {
        StatusBarContentFactories(dashboard: { NSHostingController(rootView: DashboardView(model: $0)) },
                                  tooltip: { $0.menuTooltip })
    }
}

@MainActor final class StatusBarController: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let model: AppModel
    private let factories: StatusBarContentFactories
    private var tooltipNeedsRefresh = true
    private var lastTooltipTimeState: PresentationTimeState?
    private var presentationObservers = Set<AnyCancellable>()
    private var lastTitle = ""
    private var lastColor: NSColor?
    private var lastDiagnostic = Date.distantPast
    private let diagnosticsURL: URL?
    init(model: AppModel, factories: StatusBarContentFactories = .production,
         diagnosticsURL: URL? = StatusBarController.commandLineDiagnosticsURL()) {
        self.model = model
        self.factories = factories
        self.diagnosticsURL = diagnosticsURL
        // Keep a strong reference: a local NSStatusItem vanishes when deallocated.
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.autosaveName = "TokenStatMenu.Metrics"
        popover.behavior = .transient; popover.animates = false; popover.delegate = self
        popover.contentSize = NSSize(width: 460, height: 700)
        if let button = item.button {
            button.target = self; button.action = #selector(toggle)
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.setAccessibilityLabel("TokenStatMenu 实时 Token 速度")
        }
        // Published measurements/preferences invalidate the expensive tooltip;
        // the half-second timer separately checks cheap freshness boundaries.
        model.objectWillChange.sink { [weak self] in self?.tooltipNeedsRefresh = true }
            .store(in: &presentationObservers)
        NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.tooltipNeedsRefresh = true }
            .store(in: &presentationObservers)
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
        let timeState = model.presentationTimeState
        if tooltipNeedsRefresh || lastTooltipTimeState != timeState {
            item.button?.toolTip = factories.tooltip(model)
            tooltipNeedsRefresh = false
            lastTooltipTimeState = timeState
        }
        writeDiagnosticsIfRequested()
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) } else { show() }
    }
    func show() {
        guard let button = item.button else { return }
        // Do not allocate SwiftUI's dashboard/layout graph for users who only
        // need the menu title. Keep it after first open so settings state lives.
        if popover.contentViewController == nil {
            popover.contentViewController = factories.dashboard(model)
        }
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
    /// Opt-in local diagnostic output for integration tests; contains only approved booleans and resource counts.
    private func writeDiagnosticsIfRequested() {
        guard let url = diagnosticsURL,
              Date().timeIntervalSince(lastDiagnostic) >= 1 else { return }
        lastDiagnostic = Date()
        struct Report: Encodable {
            let seasunOnlyMode: Bool
            let backgroundServicesStarted: Bool
            let statusItemVisible: Bool
            let permissionPromptRequested: Bool
            let quotaPresent: Bool
            let directQuotaPresent: Bool
            let directQuotaStatus: String
            let fiveHourPresent: Bool
            let sevenDayPresent: Bool
            let fiveHourResetPresent: Bool
            let sevenDayResetPresent: Bool
            let resetTimePresent: Bool
            let monthlyUsagePresent: Bool
            let liveTokenSpeedPresent: Bool
            let sourceStatus: String
            let backgroundServiceResources: BackgroundServiceResources
        }
        let snapshot = model.freshTokenHubQuota(at: model.tokenHubNow())
        func hasReset(_ value: String?) -> Bool {
            guard let value else { return false }
            return !value.isEmpty && value != "未知"
        }
        let fiveHourResetPresent = hasReset(snapshot?.fiveHour?.resetDisplay)
        let sevenDayResetPresent = hasReset(snapshot?.sevenDay?.resetDisplay)
        let resetTimePresent = fiveHourResetPresent || sevenDayResetPresent
        let report = Report(
            seasunOnlyMode: model.isSeasunOnly,
            backgroundServicesStarted: model.backgroundServicesStarted,
            statusItemVisible: item.isVisible,
            permissionPromptRequested: model.permissionPromptRequested,
            quotaPresent: snapshot != nil || model.quota != nil || model.fiveHourQuota != nil || model.sevenDayQuota != nil,
            directQuotaPresent: model.tokenHubQuotaIsDirect && snapshot != nil,
            directQuotaStatus: model.tokenHubQuotaStatusText,
            fiveHourPresent: snapshot?.fiveHour != nil,
            sevenDayPresent: snapshot?.sevenDay != nil,
            fiveHourResetPresent: fiveHourResetPresent,
            sevenDayResetPresent: sevenDayResetPresent,
            resetTimePresent: resetTimePresent,
            monthlyUsagePresent: snapshot?.monthly != nil || model.quota?.used != nil,
            liveTokenSpeedPresent: model.config.dataSource == "localCodex"
                ? model.freshLocalLiveTurn != nil : model.stats.active > 0,
            sourceStatus: model.sourceStatus,
            backgroundServiceResources: model.backgroundServiceResources)
        if let data = try? JSONEncoder().encode(report) {
            DispatchQueue.global(qos: .utility).async { try? data.write(to: url, options: .atomic) }
        }
    }

    private nonisolated static func commandLineDiagnosticsURL() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--diagnostics-output"),
              arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }
}
```

### Sources/TokenStatMenu/Storage.swift

```swift
import Foundation
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
    static func loadPreferences(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    static func savePreferences(_ preferences: SeasunPreferences, at url: URL) throws {
        let normalized = preferences.normalized
        let value: [String: Any] = [
            "refreshSeconds": normalized.refreshSeconds,
            "tokenHubCompatibilityReadEnabled": normalized.tokenHubCompatibilityReadEnabled
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func savePreferences(_ preferences: SeasunPreferences) throws {
        try savePreferences(preferences, at: AppPaths.configURL)
    }
}

/// Historical identity helper retained for a pure regression test; it performs no Keychain I/O.
enum KeychainStore {
    static func accountName(_ purpose: String, validatedURL: String) throws -> String {
        guard ["upstream", "usage"].contains(purpose),
              let url = URL(string: validatedURL), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              ["https", "http"].contains(url.scheme ?? "") else { throw StatError.message("无效密钥绑定 URL") }
        let digest = SHA256.hash(data: Data(validatedURL.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(purpose)-\(digest)"
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
        let model = AppModel(startup: .production); self.model = model
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
import Foundation
import SwiftUI

// Original native components inspired by compact translucent desktop dashboards.
// Semantic foregrounds/materials keep both system appearances legible.
enum PanelPalette {
    static let blue = Color(red: 0.24, green: 0.43, blue: 0.96)
    static let violet = Color(red: 0.55, green: 0.39, blue: 0.89)
    static let gradient = LinearGradient(colors: [blue, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
}

enum TwoDecimalPercentFormatter {
    static func string(_ value: Double) -> String {
        String(format: "%.2f%%", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func string(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value).doubleValue
        return string(number)
    }
}

enum HeaderActionMetrics {
    static let actionSize: CGFloat = 30
}

/// Header actions intentionally ignore the dashboard's accent tint. This
/// keeps the settings and quit hit targets visually neutral and symmetric,
/// including when the popover opens with keyboard focus.
struct NeutralHeaderActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background(Color.clear)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
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
                    Text(source == .localCodex ? presentation.usedPercent.map { TwoDecimalPercentFormatter.string($0) } ?? "—"
                        : fresh ? TwoDecimalPercentFormatter.string(quota!.remainingPercent) : "—")
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
                    Text("上游已用 " + TwoDecimalPercentFormatter.string(used))
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

/// Only immutable values cross the native AX actor boundary. AppKit process
/// references, AXUIElement objects and the mutable traversal map stay inside it.
struct TokenHubAXRequest: Sendable {
    let now: Date
    let permissionTrusted: Bool
    let refreshSeconds: TimeInterval
    let mode: TokenHubRunMode
    let generation: UInt64
}

actor NativeTokenHubAXWorker {
    private let reader = TokenHubAXReader()

    func scan(_ request: TokenHubAXRequest) -> TokenHubQuotaResult {
        // No suspension point while the native reader owns AX references.
        // Core still rejects an untrusted or inactive request before discovery.
        reader.scan(now: request.now, monotonicNow: { ProcessInfo.processInfo.systemUptime },
                    permissionTrusted: request.permissionTrusted,
                    refreshSeconds: request.refreshSeconds, mode: request.mode,
                    generation: request.generation)
    }
}

/// Immutable constructor injection keeps the native actor as the sole AX owner.
/// The marker survives closure wrapping so fixture launches cannot read real UI.
struct TokenHubAXSource {
    enum Kind { case native, synthetic }
    let kind: Kind
    let scan: @MainActor (TokenHubAXRequest) async -> TokenHubQuotaResult

    private init(kind: Kind, scan: @escaping @MainActor (TokenHubAXRequest) async -> TokenHubQuotaResult) {
        self.kind = kind
        self.scan = scan
    }

    @MainActor static var production: TokenHubAXSource {
        let worker = NativeTokenHubAXWorker()
        return TokenHubAXSource(kind: .native, scan: { await worker.scan($0) })
    }

    static func synthetic(_ scan: @escaping @MainActor (TokenHubAXRequest) async -> TokenHubQuotaResult) -> TokenHubAXSource {
        TokenHubAXSource(kind: .synthetic, scan: scan)
    }
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
        case kAXApplicationRole: value = .application
        case kAXWindowRole: value = .window
        case kAXGroupRole: value = .group
        case kAXStaticTextRole: value = .staticText
        case kAXProgressIndicatorRole: value = .progressIndicator
        case kAXButtonRole, kAXRadioButtonRole, kAXCheckBoxRole,
             kAXPopUpButtonRole, kAXMenuButtonRole, "AXLink":
            value = .button
        case kAXTableRole, kAXOutlineRole, kAXListRole:
            value = .table
        case kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole:
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
    let directSource: Bool
    init(snapshot: TokenHubQuotaSnapshot?, status: String, enabled: Bool, refreshSeconds: Double,
         directSource: Bool = false) {
        self.snapshot = snapshot; self.status = status; self.enabled = enabled
        self.refreshSeconds = refreshSeconds; self.directSource = directSource
    }
    var emptyStateText: String { enabled ? status : "自动读取已关闭" }
    static func resetLabel(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == "未知" ? "重置时间未知" : "重置 \(text)"
    }
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                Text(directSource
                    ? "只读后台额度；仅向 Hub 既有来源交换会话，短期令牌仅存内存。与本机 Token 统计和费用分开。"
                    : "仅读取 Token Hub 界面显示；账号与组织未核验，币种未核验。与本机 Token 统计、企业 API 配额和费用分开。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Text(directSource ? "本次后台读取时间已记录。" : "Token Hub 后台更新时间未提供。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                if let snapshot {
                    if let window = snapshot.fiveHour { row("5 小时", window.usedPercent, window.usedAmount, window.limitAmount, window.sourceSymbol, window.resetDisplay) }
                    else { unknownWindowRow("5 小时") }
                    if let window = snapshot.sevenDay { row("7 天", window.usedPercent, window.usedAmount, window.limitAmount, window.sourceSymbol, window.resetDisplay) }
                    else { unknownWindowRow("7 天") }
                    if let monthly = snapshot.monthly {
                        monthlyRow(monthly)
                    }
                    Text("\(directSource ? "后台读取" : "界面读取")于 \(snapshot.observedAt.formatted(.dateTime.hour().minute()))；快照有效期 \(Int(max(120, refreshSeconds * 2))) 秒")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    Text(emptyStateText).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label(directSource ? "Token Hub 企业额度" : "Token Hub 界面额度快照", systemImage: "window.ceiling") }
    }
    private func monthlyRow(_ monthly: TokenHubMonthlyUsage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("月度").fontWeight(.medium)
                Spacer(minLength: 0)
                if let usedPercent = monthly.usedPercent {
                    Text("已用 \(TwoDecimalPercentFormatter.string(usedPercent))")
                        .fontWeight(.semibold).monospacedDigit()
                } else {
                    Text("已用").fontWeight(.semibold)
                }
            }
            if let limit = monthly.limitAmount, let usedPercent = monthly.usedPercent {
                let usedFraction = min(1, max(0, NSDecimalNumber(decimal: usedPercent / 100).doubleValue))
                GeometryReader { geometry in
                    Capsule().fill(PanelPalette.blue.opacity(0.12))
                    Capsule().fill(PanelPalette.blue)
                        .frame(width: geometry.size.width * usedFraction)
                }
                .frame(height: 5)
                HStack {
                    Text("\(monthly.sourceSymbol)\(amount(monthly.usedAmount)) / \(monthly.sourceSymbol)\(amount(limit))")
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    if let remaining = monthly.remainingAmount {
                        Text("剩余 \(monthly.sourceSymbol)\(amount(remaining))")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            } else {
                Text("已用 \(monthly.sourceSymbol)\(amount(monthly.usedAmount)) · 后台未提供月度总额，剩余与进度未知")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10))
    }
    private func unknownWindowRow(_ title: String) -> some View {
        HStack {
            Text(title).fontWeight(.medium)
            Spacer(minLength: 0)
            Text("未知").foregroundStyle(.secondary)
        }
        .font(.system(size: 10))
    }
    private func row(_ title: String, _ usedPercent: Decimal, _ used: Decimal, _ limit: Decimal, _ symbol: String, _ reset: String) -> some View {
        let remainingPercent = Decimal(100) - usedPercent
        let usedFraction = min(1, max(0, NSDecimalNumber(decimal: usedPercent / 100).doubleValue))
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer(minLength: 0)
            Text("剩余 \(TwoDecimalPercentFormatter.string(remainingPercent))")
                .fontWeight(.semibold).monospacedDigit()
            }
            GeometryReader { geometry in
                Capsule().fill(PanelPalette.blue.opacity(0.12))
                Capsule().fill(PanelPalette.blue)
                    .frame(width: geometry.size.width * usedFraction)
            }
            .frame(height: 5)
            HStack {
                Text("\(directSource ? "后台已用" : "界面已用") \(TwoDecimalPercentFormatter.string(usedPercent)) · \(symbol)\(amount(used)) / \(symbol)\(amount(limit))")
                    .monospacedDigit()
                Spacer(minLength: 0)
                Text(Self.resetLabel(reset)).foregroundStyle(.secondary)
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
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>1.1.5</string>
<key>CFBundleVersion</key><string>7</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
```

### Resources/config.example.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>refreshSeconds</key>
	<real>60.0</real>
	<key>tokenHubCompatibilityReadEnabled</key>
	<true/>
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
691E49AD166C9C1FA740FA37 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "TokenHubDirectQuota.swift"; sourceTree = "<group>"; };
3D0FB2D7E3115DC2E870C0E0 = { isa = PBXBuildFile; fileRef = 691E49AD166C9C1FA740FA37; };
854D234B4ABC73F4622474C9 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "TokenHubQuota.swift"; sourceTree = "<group>"; };
EE000FBD14AA318AC3D38D79 = { isa = PBXBuildFile; fileRef = 854D234B4ABC73F4622474C9; };
52C5DE96C0BE6977037C956F = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "WindowQuota.swift"; sourceTree = "<group>"; };
D495B366C1D0E1A6672A9637 = { isa = PBXBuildFile; fileRef = 52C5DE96C0BE6977037C956F; };
AF7F4C7B765701F258FB7F4D = { isa = PBXGroup; children = (8E4403D07D4E24DF01F86E5D, 6060CB36BD32E4DE62121D71, 25DB8EC2672FE7C810B75A38, 967CB92DBAF3C5042457AF3F, 4C87C1C697E481BB11B23261, 99081DE7CEB5C9C7DAFEADA1, 4B0A93085460A2D4B5B2F8C2, A1B8AA05224B907A20995624, 951D8E55C70DA883B1E10A70, 0C519B277D7405758007F620, 691E49AD166C9C1FA740FA37, 854D234B4ABC73F4622474C9, 52C5DE96C0BE6977037C956F,); path = "Sources/TokenStatCore"; sourceTree = "<group>"; };
11043337019FA9BE53E5DEA5 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "AppModel.swift"; sourceTree = "<group>"; };
60476D6C0F010F89CDCF9332 = { isa = PBXBuildFile; fileRef = 11043337019FA9BE53E5DEA5; };
B3117F547294E09EFEF92409 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "DashboardView.swift"; sourceTree = "<group>"; };
BBE06DCD34D248AEC63DEFB1 = { isa = PBXBuildFile; fileRef = B3117F547294E09EFEF92409; };
1568C8A45BC98EBCCE9A8EA4 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "PanelStyle.swift"; sourceTree = "<group>"; };
1C6C1E79E7D0D3008EFA0C51 = { isa = PBXBuildFile; fileRef = 1568C8A45BC98EBCCE9A8EA4; };
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
96BD6B98AF8DAF812B21484D = { isa = PBXGroup; children = (11043337019FA9BE53E5DEA5, B3117F547294E09EFEF92409, 1568C8A45BC98EBCCE9A8EA4, 7DBBE1964667520E74C4B575, 262E8C516B62E763FA6537BF, 3D39E548358F39784FDEFE9F, 25AEEBE9806DD6E732A43A43, F32057C12C25AA597CC2C1C9, 9215CF293A4FF1D70E77EC32, 414355FEF7F80FBFD58C7086,); path = "Sources/TokenStatMenu"; sourceTree = "<group>"; };
A8792157CB4F27FB949C035F = { isa = PBXFileReference; explicitFileType = wrapper.application; path = TokenStatMenu.app; sourceTree = BUILT_PRODUCTS_DIR; };
0A3E27B8CA818264D75C8D81 = { isa = PBXGroup; children = (A8792157CB4F27FB949C035F,); name = Products; sourceTree = "<group>"; };
9B987D631012EC23CDD96B6A = { isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Resources/Info.plist"; sourceTree = "<group>"; };
652E7FD0652728D9B3EF13DF = { isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Resources/config.example.plist"; sourceTree = "<group>"; };
237F74AE00B061E8017BA06F = { isa = PBXFileReference; lastKnownFileType = image.icns; path = "Resources/AppIcon.icns"; sourceTree = "<group>"; };
E24DE23ACEDF31B2061282C1 = { isa = PBXBuildFile; fileRef = 237F74AE00B061E8017BA06F; };
0D6E4079E36703EBD37C0072 = { isa = PBXGroup; children = (AF7F4C7B765701F258FB7F4D, 96BD6B98AF8DAF812B21484D, 9B987D631012EC23CDD96B6A, 652E7FD0652728D9B3EF13DF, 237F74AE00B061E8017BA06F, 0A3E27B8CA818264D75C8D81,); sourceTree = "<group>"; };
878A52FC5FF6A57D50B7B870 = { isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (6A3864C6E6DB561D02F46C35, 08BC9043587CC788D01C24E7, C6D71C6FAB45AC1E6B57A569, 2D299820E6AC3A52FFC40FC8, BACF14F65A3D26C56E4559AC, DDA47B3DEE61C34C2F297CF7, 49E56DE5EE1D3357BC99E0B5, E51281927C6E41F6B2F2A59B, 06CC516465ECBFB9656FCFE3, FE8BDDD173656D12A732897D, 3D0FB2D7E3115DC2E870C0E0, EE000FBD14AA318AC3D38D79, D495B366C1D0E1A6672A9637, 60476D6C0F010F89CDCF9332, BBE06DCD34D248AEC63DEFB1, 1C6C1E79E7D0D3008EFA0C51, DF47DB83567E12D94C90C186, 775730CD86C47FBDC9419E49, F2E25F94650242E3A64878B7, 4BE492A2D95B99D7EAB5E1B2, 3263F0161C5BC399111E323B, B71BD30B9E5D41A06B13B456, 164B1DA057D49AA2DDF2EB36,); runOnlyForDeploymentPostprocessing = 0; };
E2AA269EB967A8853A258BFA = { isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
41D311A605520FC7B8B9A980 = { isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (E24DE23ACEDF31B2061282C1,); runOnlyForDeploymentPostprocessing = 0; };
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

### TokenStatMenu.xcodeproj/xcshareddata/xcschemes/TokenStatMenu.xcscheme

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="34A04005BCAF206EEC990BD9" BuildableName="TokenStatMenu.app" BlueprintName="TokenStatMenu" ReferencedContainer="container:TokenStatMenu.xcodeproj"/>
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="34A04005BCAF206EEC990BD9" BuildableName="TokenStatMenu.app" BlueprintName="TokenStatMenu" ReferencedContainer="container:TokenStatMenu.xcodeproj"/>
    </BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
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
        try directQuotaChecks()
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
        check(GatewayDiscovery.originKey(found.first!.endpoint) == "https://gateway.example:443",
            "route verification reduces a provider endpoint to its credential-free origin")
        check(GatewayDiscovery.originKey("https://user:password@gateway.example/v1") == nil,
            "route origin matching rejects embedded credentials")
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

        // Seasun production mode must fail closed when the active Codex route
        // cannot be tied to Token Hub.  The legacy no-context scan below is
        // intentionally retained for source-independent fixtures.
        let routeRoot = try fixtureDirectory("seasun-route-filter")
        let routeMatchingID = "31313131-3131-4131-8131-313131313131"
        let routeOtherID = "32323232-3232-4232-8232-323232323232"
        try writeSession(in: routeRoot, uuid: routeMatchingID,
            events: [tokenEvent(at: now, input: 10, output: 5)], modified: now,
            metadataFields: ["model_provider": "seasun"])
        try writeSession(in: routeRoot, uuid: routeOtherID,
            events: [tokenEvent(at: now, input: 100, output: 50)], modified: now,
            metadataFields: ["model_provider": "other"])
        let verifiedRoute = LocalCodexRouteContext.verified(provider: "seasun", origin: "https://gateway.example")
        let routeFiltered = try LocalCodexUsageReader.scan(directory: routeRoot, now: now,
            cache: nil, routeContext: verifiedRoute)
        check(routeFiltered.input == 10 && routeFiltered.output == 5
            && routeFiltered.knownThreadCount == 1 && routeFiltered.unidentifiedFileCount == 1,
            "verified Seasun route includes only the matching Codex provider")
        let unverifiedRoute = try LocalCodexUsageReader.scan(directory: routeRoot, now: now,
            cache: nil, routeContext: .unverified)
        check(unverifiedRoute.total == 0 && unverifiedRoute.knownThreadCount == 0
            && !unverifiedRoute.hasCompleteAccounting,
            "unproven Seasun route never mixes local Codex totals")
        try? FileManager.default.removeItem(at: routeRoot.deletingLastPathComponent())

        let liveRoot = try fixtureDirectory("live-output-speed")
        try writeSession(in: liveRoot, uuid: "33333333-3333-4333-8333-333333333333", events: [
            turnTokenEvent(at: now.addingTimeInterval(-5), output: 10),
            turnBoundary(at: now.addingTimeInterval(-4), type: "task_started", id: "live"),
            turnTokenEvent(at: now.addingTimeInterval(-2), output: 30),
            turnTokenEvent(at: now.addingTimeInterval(-1), output: 50)
        ], modified: now)
        let liveCache = LocalCodexUsageReader.Cache()
        let live = try LocalCodexUsageReader.scan(directory: liveRoot, now: now, cache: liveCache)
        check(live.liveTurn?.outputTPS == 20 && live.liveTurn?.inputTPS == 0,
            "active cumulative token_count events produce a live output TPS estimate")
        let staleLive = try LocalCodexUsageReader.scan(directory: liveRoot,
            now: now.addingTimeInterval(20), cache: liveCache)
        check(staleLive.liveTurn == nil,
            "live output TPS expires when the latest token_count event is stale")
        try? FileManager.default.removeItem(at: liveRoot.deletingLastPathComponent())

        let malformedLiveRoot = try fixtureDirectory("live-output-malformed")
        try writeSession(in: malformedLiveRoot, uuid: "34343434-3434-4434-8434-343434343434", events: [
            turnTokenEvent(at: now.addingTimeInterval(-3), output: 10),
            turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "malformed-live"),
            turnTokenEvent(at: now.addingTimeInterval(-1.5), output: 20),
            turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 25),
            rawTokenEvent(at: now, inputLiteral: "null", outputLiteral: "30")
        ], modified: now)
        let malformedLive = try LocalCodexUsageReader.scan(directory: malformedLiveRoot, now: now)
        check(malformedLive.liveTurn == nil,
            "malformed cumulative usage in an active turn keeps live speed unknown")
        try? FileManager.default.removeItem(at: malformedLiveRoot.deletingLastPathComponent())

        try localLiveIntegrityChecks(now: now)

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
        check(aggregate.input == 4 && aggregate.output == 6 && aggregate.total == 10,
            "a root counter reset is excluded instead of being reported as complete accounting")
        check(aggregate.sessionCount == 2 && aggregate.latestEventAt == now.addingTimeInterval(-60),
            "local Codex reports metadata-backed top-level count and latest event timestamp")
        check(aggregate.knownThreadCount == 1 && aggregate.unknownThreadCount == 1
            && aggregate.unidentifiedFileCount == 0 && !aggregate.hasCompleteAccounting,
            "a root reset marks only the affected thread unknown")
        check(aggregate.input == 4 && aggregate.output == 6,
            "cached input and reasoning output subfields are not added twice")
        let rescanned = try LocalCodexUsageReader.scan(directory: aggregateRoot, now: now)
        check(rescanned.input == aggregate.input && rescanned.output == aggregate.output
            && rescanned.total == aggregate.total && rescanned.sessionCount == aggregate.sessionCount,
            "repeated local Codex scans replace the snapshot instead of accumulating it")
        let reflectedFields = Set(Mirror(reflecting: aggregate).children.compactMap(\.label))
        check(reflectedFields == Set(["input", "output", "total", "sessionCount", "filesScanned",
            "isLimited", "latestEventAt", "fiveHour", "sevenDay", "lastTurn", "liveTurn", "knownThreadCount",
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

        let noFinalLFRoot = try fixtureDirectory("complete-no-final-lf")
        let noFinalLFID = "13131313-1313-4313-8313-131313131313"
        try writeSession(in: noFinalLFRoot, uuid: noFinalLFID,
            events: [tokenEvent(at: now.addingTimeInterval(-1), input: 7, output: 5)],
            modified: now, finalNewline: false)
        let noFinalLF = try LocalCodexUsageReader.scan(directory: noFinalLFRoot, now: now)
        check(noFinalLF.input == 7 && noFinalLF.output == 5 && noFinalLF.total == 12
            && noFinalLF.knownThreadCount == 1 && noFinalLF.hasCompleteAccounting,
            "a complete final JSONL event is retained without a trailing LF")
        try? FileManager.default.removeItem(at: noFinalLFRoot.deletingLastPathComponent())

        let truncatedFinalRoot = try fixtureDirectory("truncated-final-no-lf")
        let truncatedFinalID = "14141414-1414-4414-8414-141414141414"
        try writeSession(in: truncatedFinalRoot, uuid: truncatedFinalID,
            events: [tokenEvent(at: now.addingTimeInterval(-2), input: 3, output: 2)],
            modified: now, suffix: Data("{\"type\":\"event_msg\"".utf8), finalNewline: false)
        let truncatedFinal = try LocalCodexUsageReader.scan(directory: truncatedFinalRoot, now: now)
        check(truncatedFinal.input == 0 && truncatedFinal.output == 0 && truncatedFinal.total == 0
            && !truncatedFinal.hasCompleteAccounting,
            "a malformed final no-LF fragment remains unknown instead of being counted")
        try? FileManager.default.removeItem(at: truncatedFinalRoot.deletingLastPathComponent())

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
        check(afterRollback.lastTurn == nil && rollbackCache.diagnostics.cacheHits == 0
            && rollbackCache.diagnostics.parsedFiles == 1,
            "clock rollback reparses cached evidence and revalidates completion time")
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
        if let range = sameSizeRewrite.range(of: Data("\"total_tokens\":7".utf8)) {
            sameSizeRewrite.replaceSubrange(range, with: Data("\"total_tokens\":8".utf8))
        } else {
            check(false, "same-size cache rewrite fixture locates the matching total count")
        }
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
        let wrongSettingsFork = try LocalCodexUsageReader.scan(directory: wrongSettingsRoot, now: now.addingTimeInterval(1))
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
            events: [rawTokenEvent(at: now, inputLiteral: "9007199254740993", outputLiteral: "0",
                                   totalLiteral: "9007199254740993")], modified: now)
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
            events: [rawTokenEvent(at: now, inputLiteral: String(Int.max), outputLiteral: "0",
                                   totalLiteral: String(Int.max))], modified: now)
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

    /// Live estimates require an intact final record segment and an unambiguous,
    /// current lifecycle. These fixtures never inspect actual local sessions.
    private static func localLiveIntegrityChecks(now: Date) throws {
        let id = "35353535-3535-4535-8535-353535353535"
        func assertUnknown(_ label: String, events: [Data], suffix: Data = Data(),
                           incompleteAccounting: Bool = false) throws {
            let root = try fixtureDirectory("live-integrity-\(label)")
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            try writeSession(in: root, uuid: id, events: events, modified: now, suffix: suffix)
            let cache = LocalCodexUsageReader.Cache()
            let cold = try LocalCodexUsageReader.scan(directory: root, now: now, cache: cache)
            let warm = try LocalCodexUsageReader.scan(directory: root, now: now, cache: cache)
            check(cold.liveTurn == nil && warm.liveTurn == nil,
                "live integrity rejects \(label) on cold and cached scans")
            if incompleteAccounting {
                check(cold.total == 0 && !cold.hasCompleteAccounting && warm.total == 0 && !warm.hasCompleteAccounting,
                    "future counters never enter complete accounting for \(label)")
            }
        }
        let start = try turnBoundary(at: now.addingTimeInterval(-5), type: "task_started", id: "A")
        let first = try turnTokenEvent(at: now.addingTimeInterval(-3), output: 10)
        let second = try turnTokenEvent(at: now.addingTimeInterval(-2), output: 30)
        try assertUnknown("truncated-tail", events: [start, first, second], suffix: json("{\"type\":\"event_msg\","))
        try assertUnknown("damaged-record-between-counters", events: [start, first, json("{BROKEN}"), second])
        try assertUnknown("damaged-record-after-counters", events: [start, first, second, json("{BROKEN}")])
        try assertUnknown("invalid-event-payload", events: [start, first, json("{\"type\":\"event_msg\",\"payload\":null}"), second])
        try assertUnknown("missing-event-kind", events: [start, first, json("{\"type\":\"event_msg\",\"payload\":{}}"), second])
        try assertUnknown("overlapping-tasks", events: [start,
            turnBoundary(at: now.addingTimeInterval(-4), type: "task_started", id: "B"), first, second,
            turnBoundary(at: now.addingTimeInterval(-1), type: "task_complete", id: "A")])
        try assertUnknown("unmatched-completion", events: [start, first, second,
            turnBoundary(at: now.addingTimeInterval(-1), type: "task_complete", id: "B")])
        try assertUnknown("reused-task-id", events: [
            turnBoundary(at: now.addingTimeInterval(-9), type: "task_started", id: "A"),
            turnBoundary(at: now.addingTimeInterval(-8), type: "task_complete", id: "A"), start, first, second])
        try assertUnknown("future-task-start", events: [
            turnBoundary(at: now.addingTimeInterval(10), type: "task_started", id: "A"), first, second])
        let missingStartDate = try JSONSerialization.data(withJSONObject: ["type": "event_msg",
            "payload": ["type": "task_started", "turn_id": "A"]])
        try assertUnknown("missing-task-start-time", events: [missingStartDate, first, second])
        try assertUnknown("backwards-lifecycle-time", events: [
            turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "A"), first,
            turnTokenEvent(at: now.addingTimeInterval(-1), output: 30)])
        try assertUnknown("earlier-counter-reset", events: [start,
            turnTokenEvent(at: now.addingTimeInterval(-4), output: 40), first, second])
        try assertUnknown("earlier-counter-time-reversal", events: [start,
            turnTokenEvent(at: now.addingTimeInterval(-2), output: 5), first,
            turnTokenEvent(at: now.addingTimeInterval(-1), output: 30)])
        try assertUnknown("future-final-counter", events: [start, first, second,
            turnTokenEvent(at: now.addingTimeInterval(1), output: 50)], incompleteAccounting: true)
        try assertUnknown("future-earlier-counter", events: [start,
            turnTokenEvent(at: now.addingTimeInterval(1), output: 5), first, second], incompleteAccounting: true)

        let paddingA = try JSONSerialization.data(withJSONObject: ["type": "padding", "text": String(repeating: "a", count: 130_000)])
        let paddingB = try JSONSerialization.data(withJSONObject: ["type": "padding", "text": String(repeating: "b", count: 300_000)])
        try assertUnknown("unread-middle-task-completion", events: [start, paddingA,
            turnBoundary(at: now.addingTimeInterval(-4), type: "task_complete", id: "A"), paddingB, first, second])

        let recoveryRoot = try fixtureDirectory("live-integrity-final-segment-recovery")
        defer { try? FileManager.default.removeItem(at: recoveryRoot.deletingLastPathComponent()) }
        try writeSession(in: recoveryRoot, uuid: id, events: [start, paddingA,
            turnBoundary(at: now.addingTimeInterval(-4), type: "task_complete", id: "A"), paddingB,
            turnBoundary(at: now.addingTimeInterval(-4), type: "task_started", id: "B"), first, second], modified: now)
        let recovered = try LocalCodexUsageReader.scan(directory: recoveryRoot, now: now)
        check(recovered.isLimited && recovered.liveTurn?.outputTPS == 20,
            "complete independent task in the retained tail can recover a live estimate after a read gap")

        let futureRoot = try fixtureDirectory("live-integrity-cache-time-revalidation")
        defer { try? FileManager.default.removeItem(at: futureRoot.deletingLastPathComponent()) }
        try writeSession(in: futureRoot, uuid: id, events: [start, first, second,
            turnTokenEvent(at: now.addingTimeInterval(1), output: 50)], modified: now)
        let futureCache = LocalCodexUsageReader.Cache()
        _ = try LocalCodexUsageReader.scan(directory: futureRoot, now: now, cache: futureCache)
        let caughtUp = try LocalCodexUsageReader.scan(directory: futureRoot, now: now.addingTimeInterval(2), cache: futureCache)
        let caughtUpCold = try LocalCodexUsageReader.scan(directory: futureRoot, now: now.addingTimeInterval(2))
        check(caughtUp == caughtUpCold && caughtUp.hasCompleteAccounting && caughtUp.liveTurn != nil,
            "unchanged cached file is rejudged when a future counter becomes current")
        let rewound = try LocalCodexUsageReader.scan(directory: futureRoot, now: now, cache: futureCache)
        let rewoundCold = try LocalCodexUsageReader.scan(directory: futureRoot, now: now)
        check(rewound == rewoundCold && rewound.liveTurn == nil && !rewound.hasCompleteAccounting,
            "clock rollback cannot reuse counters or live estimates that are now in the future")

        let aggregateRoot = try fixtureDirectory("live-integrity-aggregate-expiry")
        defer { try? FileManager.default.removeItem(at: aggregateRoot.deletingLastPathComponent()) }
        try writeSession(in: aggregateRoot, uuid: id, events: [
            turnBoundary(at: now.addingTimeInterval(-17), type: "task_started", id: "older"),
            turnTokenEvent(at: now.addingTimeInterval(-16), output: 10),
            turnTokenEvent(at: now.addingTimeInterval(-14), output: 30)], modified: now)
        try writeSession(in: aggregateRoot, uuid: "36363636-3636-4636-8636-363636363636", events: [
            turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "newer"),
            turnTokenEvent(at: now.addingTimeInterval(-1), output: 10),
            turnTokenEvent(at: now, output: 30)], modified: now)
        let aggregateCache = LocalCodexUsageReader.Cache()
        let coldAggregate = try LocalCodexUsageReader.scan(directory: aggregateRoot, now: now, cache: aggregateCache)
        let warmAggregate = try LocalCodexUsageReader.scan(directory: aggregateRoot, now: now, cache: aggregateCache)
        check(coldAggregate.liveTurn?.outputTPS == 30 && warmAggregate == coldAggregate
            && coldAggregate.liveTurn?.observedAt == now.addingTimeInterval(-14),
            "aggregate live freshness uses its oldest component so one newer session cannot extend an older rate")
        let afterComponentExpiry = try LocalCodexUsageReader.scan(directory: aggregateRoot,
            now: now.addingTimeInterval(1.001), cache: aggregateCache)
        check(afterComponentExpiry.liveTurn?.outputTPS == 20 && afterComponentExpiry.liveTurn?.observedAt == now,
            "next cached scan drops the expired aggregate component and restores the remaining fresh session")
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
                                     metadataFields: [String: Any] = [:], metadata: Data? = nil,
                                     finalNewline: Bool = true) throws {
        var data = metadata ?? sessionMetadata(id: metadataID ?? uuid, source: metadataSource, fields: metadataFields)
        if !data.isEmpty { data.append(10) }
        data.append(contentsOf: prefix)
        for (index, event) in events.enumerated() {
            data.append(contentsOf: event)
            if finalNewline || index < events.count - 1 || !suffix.isEmpty { data.append(10) }
        }
        data.append(contentsOf: suffix)
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

### Tests/TokenStatCoreTests/DirectQuotaChecks.swift

```swift
import Foundation
import TokenStatCore
import SQLite3
import Darwin

private final class DirectQuotaCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks = 0
    private var quotas = 0
    private var callbackShape = false
    private var quotaShape = false
    private var succeeded = false
    private var failure: TokenHubDirectQuotaFailure?
    @discardableResult func noteCallback(_ shape: Bool) -> Int { lock.lock(); callbacks += 1; callbackShape = shape; let value = callbacks; lock.unlock(); return value }
    func noteQuota(_ shape: Bool) -> Int { lock.lock(); quotas += 1; quotaShape = shape; let value = quotas; lock.unlock(); return value }
    func noteSuccess(_ value: Bool) { lock.lock(); succeeded = value; lock.unlock() }
    func noteFailure(_ value: TokenHubDirectQuotaFailure?) { lock.lock(); failure = value; lock.unlock() }
    func snapshot() -> (Int, Int, Bool, Bool, Bool, TokenHubDirectQuotaFailure?) {
        lock.lock(); defer { lock.unlock() }; return (callbacks, quotas, callbackShape, quotaShape, succeeded, failure)
    }
}

extension CoreChecks {
    static func directQuotaChecks() throws {
        try directCallbackLocationChecks()
        try directDatabaseReplacementChecks()
        try directAmountLexicalChecks()
        let identity = TokenHubIdentity(pid: 47816,
            bundleID: TokenHubTarget.bundleID,
            executablePath: "/Applications/Seasun Token Hub.app/Contents/MacOS/seasun-token-hub")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let valid = json("""
        {
          "code": "OK",
          "data": {
            "currency": "USD",
            "observed_at": "2027-01-15T08:00:00Z",
            "allowed": true,
            "windows": [
              {"kind":"five_hours","quota_amount":100,"used_amount":25,
               "period_start":"2027-01-15T03:00:00Z","period_end":"2027-01-15T08:00:00Z","violated":false},
              {"kind":"seven_days","quota_amount":"1000.00","used_amount":"375",
               "period_start":"2027-01-08T08:00:00Z","period_end":"2027-01-15T08:00:00Z","violated":false}
            ]
          }
        }
        """)
        let decoded = try TokenHubDirectQuotaDecoder.decode(valid, identity: identity, now: now,
                                                             timeZone: TimeZone(secondsFromGMT: 0)!)
        check(decoded.fiveHour?.usedAmount == Decimal(25) && decoded.fiveHour?.limitAmount == Decimal(100),
              "direct quota maps five-hour amount fields")
        check(decoded.fiveHour?.usedPercent == Decimal(25) && decoded.sevenDay?.usedPercent == Decimal(37.5),
              "direct quota derives percentages from exact amounts")
        check(decoded.fiveHour?.resetDisplay == "01-15 08:00" && decoded.sevenDay?.resetDisplay == "01-15 08:00",
              "direct quota formats period end without guessing a year")
        check(decoded.fiveHour?.resetAt == Date(timeIntervalSince1970: 1_800_000_000)
            && decoded.sevenDay?.resetAt == Date(timeIntervalSince1970: 1_800_000_000),
              "direct quota retains source period end for freshness checks")
        check(decoded.fiveHour?.sourceSymbol == "$" && decoded.sevenDay?.sourceSymbol == "$",
              "direct quota normalizes USD currency to a display symbol")

        let wrapped = json("""
        {"data":{"currency":"CNY","windows":[
          {"kind":"5h","quota_amount":1000,"used_amount":0,"period_start":1800000000,"period_end":1800018000},
          {"kind":"7d","quota_amount":10000,"used_amount":10000,"period_start":1799395200,"period_end":1800000000}
        ]}}
        """)
        let wrappedDecoded = try TokenHubDirectQuotaDecoder.decode(wrapped, identity: identity, now: now,
                                                                    timeZone: TimeZone(secondsFromGMT: 0)!)
        check(wrappedDecoded.fiveHour?.usedPercent == Decimal(0) && wrappedDecoded.sevenDay?.usedPercent == Decimal(100),
              "direct quota accepts numeric Unix period timestamps")
        check(wrappedDecoded.fiveHour?.sourceSymbol == "¥", "direct quota normalizes CNY currency")
        let unknownCurrency = json(#"{"data":{"currency":"https://example.invalid/account","windows":[{"kind":"fixed_5h","quota_amount":10,"used_amount":2}]}}"#)
        let unknownCurrencyDecoded = try TokenHubDirectQuotaDecoder.decode(
            unknownCurrency,
            identity: identity,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        check(unknownCurrencyDecoded.fiveHour?.sourceSymbol == "¤", "unknown currency cannot leak a URL or account label into UI")
        let rootShape = json("""
        {"code":"OK","currency":"USD","windows":[{"kind":"fixed_5h","quota_amount":10,"used_amount":2}]}
        """)
        let rootDecoded = try TokenHubDirectQuotaDecoder.decode(rootShape, identity: identity, now: now)
        check(rootDecoded.fiveHour?.usedPercent == Decimal(20),
              "direct quota accepts equivalent unwrapped response shape")

        let duplicate = json(#"{"data":{"currency":"USD","windows":[{"kind":"five_hours","quota_amount":10,"used_amount":1},{"kind":"5h","quota_amount":10,"used_amount":1}]}}"#)
        do { _ = try TokenHubDirectQuotaDecoder.decode(duplicate, identity: identity, now: now); check(false, "duplicate direct windows reject") }
        catch let error as TokenHubDirectQuotaFailure { check(error == .duplicateWindow(.fiveHour), "duplicate direct five-hour window reports typed failure") }

        let unknown = json(#"{"data":{"currency":"USD","windows":[{"kind":"mystery","quota_amount":10,"used_amount":1}]}}"#)
        do { _ = try TokenHubDirectQuotaDecoder.decode(unknown, identity: identity, now: now); check(false, "unrecognized direct windows reject") }
        catch let error as TokenHubDirectQuotaFailure { check(error == .noRecognizedWindows, "unrecognized direct windows do not become five-hour quota") }

        let monthly = json(#"{"data":{"currency":"USD","windows":[{"kind":"monthly","quota_amount":100,"used_amount":12.5}]}}"#)
        let monthlyDecoded = try TokenHubDirectQuotaDecoder.decode(monthly, identity: identity, now: now)
        check(monthlyDecoded.monthly?.usedAmount == Decimal(string: "12.5") && monthlyDecoded.fiveHour == nil,
              "direct quota preserves a monthly window without inventing rolling windows")
        check(monthlyDecoded.monthly?.limitAmount == Decimal(100)
            && monthlyDecoded.monthly?.remainingAmount == Decimal(string: "87.5")
            && monthlyDecoded.monthly?.usedPercent == Decimal(string: "12.5"),
              "direct quota preserves monthly limit and derives remaining percentage")
        let userMonth = json(#"{"data":{"currency":"USD","windows":[{"kind":"user_month","quota_amount":100,"used_amount":12.5}]}}"#)
        let userMonthDecoded = try TokenHubDirectQuotaDecoder.decode(userMonth, identity: identity, now: now)
        check(userMonthDecoded.monthly != nil,
              "direct quota maps the Token Hub user_month window")
        let duplicateMonthly = json(#"{"data":{"currency":"USD","windows":[{"kind":"monthly","quota_amount":100,"used_amount":1},{"kind":"user_month","quota_amount":100,"used_amount":1}]}}"#)
        do {
            _ = try TokenHubDirectQuotaDecoder.decode(duplicateMonthly, identity: identity, now: now)
            check(false, "duplicate direct monthly windows reject")
        } catch let error as TokenHubDirectQuotaFailure {
            check(error == .duplicateMonthly, "duplicate direct monthly windows report typed failure")
        }
        let invalidMonthlyLimit = json(#"{"data":{"currency":"USD","windows":[{"kind":"monthly","quota_amount":-1,"used_amount":1}]}}"#)
        do {
            _ = try TokenHubDirectQuotaDecoder.decode(invalidMonthlyLimit, identity: identity, now: now)
            check(false, "invalid direct monthly limit rejects")
        } catch let error as TokenHubDirectQuotaFailure {
            check(error == .malformedResponse, "invalid direct monthly limit reports malformed response")
        }
        let invalidPeriodEnd = json(#"{"data":{"currency":"USD","windows":[{"kind":"five_hours","quota_amount":10,"used_amount":1,"period_end":"not-a-date"}]}}"#)
        do {
            _ = try TokenHubDirectQuotaDecoder.decode(invalidPeriodEnd, identity: identity, now: now)
            check(false, "invalid direct reset date rejects")
        } catch let error as TokenHubDirectQuotaFailure {
            check(error == .malformedResponse, "invalid direct reset date reports malformed response")
        }

        let malformed = json(#"{"data":{"currency":"USD","windows":[{"kind":"five_hours","quota_amount":10,"used_amount":11}]}}"#)
        do { _ = try TokenHubDirectQuotaDecoder.decode(malformed, identity: identity, now: now); check(false, "used above limit rejects direct quota") }
        catch let error as TokenHubDirectQuotaFailure { check(error == .malformedResponse, "used above limit reports malformed response") }

        let bodyWithSecrets = json(#"{"data":{"currency":"USD","windows":[]},"access_token":"fixture-secret"}"#)
        do { _ = try TokenHubDirectQuotaDecoder.decode(bodyWithSecrets, identity: identity, now: now); check(false, "empty direct windows reject") }
        catch let error as TokenHubDirectQuotaFailure { check(error == .noRecognizedWindows, "decoder failure remains redacted and typed") }

        let endpoint = try TokenHubDirectQuotaEndpoint(baseURL: URL(string: "https://aihub.example.test")!,
                                                       organizationURL: URL(string: "https://sso.example.test")!)
        check(endpoint.url.path == "/api/v1/auth/me/quota-usage", "direct endpoint appends fixed quota path")
        check(TokenHubDirectQuotaEndpoint.sameOrganization(URL(string: "https://aihub.example.com")!,
                                                            URL(string: "https://sso.example.com")!),
              "same organization accepts sibling hosts under a normal registrable domain")
        check(TokenHubDirectQuotaEndpoint.sameOrganization(URL(string: "https://aihub.example.co.uk")!,
                                                            URL(string: "https://sso.example.co.uk")!),
              "same organization accepts sibling hosts under a multi-label registrable domain")
        check(!TokenHubDirectQuotaEndpoint.sameOrganization(URL(string: "https://aihub.example.co.uk")!,
                                                             URL(string: "https://sso.other.co.uk")!),
              "same organization rejects unrelated hosts sharing only a public suffix")
        check(!TokenHubDirectQuotaEndpoint.sameOrganization(URL(string: "https://ai.co.uk")!,
                                                             URL(string: "https://sso.co.uk")!),
              "same organization rejects hosts with no registrable label")
        let routed = try TokenHubDirectQuotaEndpoint(baseURL: URL(string: "https://aihub.example.test/aimanager")!,
                                                     organizationURL: URL(string: "https://sso.example.test")!)
        check(routed.url.path == "/aimanager/api/v1/auth/me/quota-usage", "direct endpoint preserves trusted AI Manager path prefix")
        do { _ = try TokenHubDirectQuotaEndpoint(baseURL: URL(string: "https://example.invalid")!,
                                                  organizationURL: URL(string: "https://sso.example.test")!); check(false, "untrusted endpoint host rejects") }
        catch let error as TokenHubDirectQuotaFailure { check(error == .endpointRejected, "untrusted endpoint reports typed failure") }


        // All connection/session values are synthetic; tests never inspect the
        // current user's Hub database or make a network request.
        let temporaryHome = FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-direct-fixture-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryHome) }
        let database = TokenHubConnectionDiscovery.defaultDatabaseURL(home: temporaryHome)
        for scenario in 0..<3 {
            try writeDirectQuotaFixture(at: database, now: now, sessionToken: "fixture-session")
            let counter = DirectQuotaCounter()
            let client = TokenHubDirectQuotaClient(request: { url, bearer in
                let call = counter.noteQuota(url.path == "/api/v1/auth/me/quota-usage" && bearer == "fixture-access")
                if scenario == 2 && call == 1 {
                    try writeDirectQuotaFixture(at: database, now: now, sessionToken: "fixture-replaced-session")
                }
                return call == 1 || scenario == 1 ? TokenHubDirectQuotaHTTPResponse(statusCode: 401, data: Data())
                    : TokenHubDirectQuotaHTTPResponse(statusCode: 200, data: valid)
            }, callbackRequest: { url in
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let shape = components?.path == "/api/v1/auth/it-sso/callback"
                    && Set(components?.queryItems?.map(\.name) ?? []).isSuperset(of: ["token", "verifySign", "redirect", "sourceChannel", "sourceTokenType"])
                counter.noteCallback(shape)
                return "fixture-access"
            })
            let done = DispatchSemaphore(value: 0)
            Task {
                defer { done.signal() }
                do { _ = try await client.fetch(identity: identity, now: now, home: temporaryHome); counter.noteSuccess(true) }
                catch { counter.noteFailure(error as? TokenHubDirectQuotaFailure) }
            }
            check(done.wait(timeout: .now() + 3) == .success, "direct client fixture completes within its bounded wait")
            let state = counter.snapshot()
            switch scenario {
            case 0:
                check(state.4 && state.0 == 2 && state.1 == 2 && state.2 && state.3,
                      "direct client exchanges synthetic session and retries quota once after 401")
            case 1:
                check(!state.4 && state.0 == 2 && state.1 == 2 && state.5 == .httpStatus(401),
                      "direct client stops after a repeated 401 instead of retrying again")
            default:
                check(!state.4 && state.0 == 1 && state.1 == 1 && state.5 == .identityChanged,
                      "direct client re-reads session after 401 and rejects changes before exchanging again")
            }
        }
    }

    /// Exercise the public response decoder, not Foundation's Decimal parser:
    /// accepting a numeric prefix must never publish a believable quota.
    private static func directAmountLexicalChecks() throws {
        let identity = TokenHubIdentity(pid: 47901, bundleID: TokenHubTarget.bundleID,
            executablePath: "/Applications/Synthetic Amount Hub.app/Contents/MacOS/Hub")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let contexts = [("fixed_5h", "used_amount"), ("fixed_5h", "quota_amount"),
                        ("user_month", "used_amount"), ("user_month", "quota_amount")]
        func response(kind: String, field: String, literal: String,
                      companionLimit: String = "1000000000000000000") -> Data {
            let used = field == "used_amount" ? literal : "0"
            let limit = field == "quota_amount" ? literal : companionLimit
            return json("{\"data\":{\"currency\":\"USD\",\"windows\":[{\"kind\":\"\(kind)\",\"used_amount\":\(used),\"quota_amount\":\(limit)}]}}")
        }
        func stringLiteral(_ value: String) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
        }
        let invalidStrings = [
            ("numeric suffix", "12.5junk"), ("exponent suffix", "1e2oops"),
            ("blank", ""), ("space only", " "), ("leading whitespace", " 12.5"),
            ("trailing whitespace", "12.5 "), ("embedded whitespace", "1 2"),
            ("line break", "12.5\n"), ("decimal comma", "1,25"),
            ("grouping comma", "1,000"), ("incomplete exponent", "1e"),
            ("incomplete fraction", "1."), ("missing integer", ".5"),
            ("leading plus", "+1"), ("leading zero", "01"),
            ("non ASCII digits", "１２.５"), ("NaN", "NaN"),
            ("positive infinity", "Infinity"), ("negative infinity", "-Infinity"),
            ("negative value", "-1"), ("above amount limit", "1000000000000000001"),
            ("decimal overflow", "1e999"),
            ("decimal underflow", "1e-129"),
            ("significant precision loss", "0.12345678901234567890123456789012345678901234567890"),
            ("bounded string exceeded", "1." + String(repeating: "0", count: 127))
        ]
        var rejected: [(String, String)] = try invalidStrings.map { ($0.0, try stringLiteral($0.1)) }
        rejected += [("Boolean true", "true"), ("Boolean false", "false"),
                     ("negative JSON number", "-1"), ("above amount limit JSON number", "1000000000000000001"),
                     ("nonfinite JSON number", "1e999"), ("array", "[]"), ("object", "{}")]
        for (kind, field) in contexts {
            for (label, literal) in rejected {
                do {
                    _ = try TokenHubDirectQuotaDecoder.decode(response(kind: kind, field: field, literal: literal),
                        identity: identity, now: now)
                    check(false, "direct amount rejects \(label) for \(kind).\(field)")
                } catch let error as TokenHubDirectQuotaFailure {
                    check(error == .malformedResponse,
                          "direct amount rejects \(label) with a redacted typed failure for \(kind).\(field)")
                } catch { check(false, "direct amount failure stays typed for \(kind).\(field)") }
            }
            // A monthly limit is optional/null by the existing contract;
            // required window amounts and monthly usage are never nullable.
            if kind != "user_month" || field != "quota_amount" {
                do {
                    _ = try TokenHubDirectQuotaDecoder.decode(response(kind: kind, field: field, literal: "null"),
                        identity: identity, now: now)
                    check(false, "required direct amount rejects null for \(kind).\(field)")
                } catch let error as TokenHubDirectQuotaFailure {
                    check(error == .malformedResponse, "required direct null amount has a typed failure")
                }
            }
        }

        // Literal expected values are independent of the production helper.
        let validValues = [
            ("JSON integer", "25", "25"), ("JSON fraction", "12.5", "12.5"),
            ("JSON exponent", "1.25e1", "12.5"), ("numeric string", "\"12.50\"", "12.5"),
            ("string exponent", "\"125e-1\"", "12.5"),
            ("string signed exponent", "\"1.25E+1\"", "12.5"),
            ("exact string precision", "\"0.1234567890123456789012345678\"", "0.1234567890123456789012345678"),
            ("38 significant digits", "\"0.12345678901234567890123456789012345678\"", "0.12345678901234567890123456789012345678"),
            ("equivalent trailing zero precision", "\"0.123456789012345678901234567890123456780000000000\"", "0.12345678901234567890123456789012345678"),
            ("small fraction", "\"0.00000001\"", "0.00000001"),
            ("minimum decimal exponent", "\"1e-128\"", "1e-128"),
            ("amount maximum JSON", "1000000000000000000", "1000000000000000000"),
            ("amount maximum string", "\"1e18\"", "1000000000000000000"),
            ("bounded string exact boundary", "\"1." + String(repeating: "0", count: 126) + "\"", "1")
        ]
        for (label, literal, expectedText) in validValues {
            let expected = Decimal(string: expectedText, locale: Locale(identifier: "en_US_POSIX"))!
            for (kind, field) in contexts {
                // Existing rolling used/limit percentage arithmetic may not
                // represent this extreme ratio. Preserve the already valid
                // monthly amount and rolling limit inputs without broadening
                // the mathematical domain of the percentage calculation.
                if expectedText == "1e-128", kind == "fixed_5h", field == "used_amount" { continue }
                // Keep the minimum-exponent lexical case separate from
                // percentage underflow caused by dividing by a huge limit.
                let limit = expectedText == "1e-128" ? "1" : "1000000000000000000"
                let decoded: TokenHubQuotaSnapshot
                do {
                    decoded = try TokenHubDirectQuotaDecoder.decode(response(kind: kind, field: field, literal: literal,
                        companionLimit: limit), identity: identity, now: now)
                } catch {
                    check(false, "direct amount accepts \(label) for \(kind).\(field)")
                    continue
                }
                if kind == "fixed_5h" {
                    check((field == "used_amount" ? decoded.fiveHour?.usedAmount : decoded.fiveHour?.limitAmount) == expected,
                          "direct amount preserves \(label) for \(kind).\(field)")
                } else {
                    check(decoded.monthly?.usedAmount == (field == "used_amount" ? expected : Decimal(0)),
                          "direct amount accepts \(label) for \(kind).\(field) without inventing usage")
                }
            }
        }
        for literal in ["0", "0.0", "\"0\"", "\"0e0\""] {
            for kind in ["fixed_5h", "user_month"] {
                let decoded = try TokenHubDirectQuotaDecoder.decode(response(kind: kind, field: "used_amount", literal: literal),
                    identity: identity, now: now)
                check((kind == "fixed_5h" ? decoded.fiveHour?.usedAmount : decoded.monthly?.usedAmount) == Decimal(0),
                      "direct amount preserves explicit zero \(literal) for \(kind)")
            }
        }
        let noMonthlyLimit = try TokenHubDirectQuotaDecoder.decode(response(kind: "user_month", field: "quota_amount", literal: "null"),
            identity: identity, now: now)
        check(noMonthlyLimit.monthly?.usedAmount == Decimal(0), "optional monthly null limit remains supported")
        check(noMonthlyLimit.monthly?.limitAmount == nil
            && noMonthlyLimit.monthly?.remainingAmount == nil
            && noMonthlyLimit.monthly?.usedPercent == nil,
              "used-only monthly response keeps limit-derived fields unknown")
    }
}


extension CoreChecks {
    static func directCallbackLocationChecks() throws {
        var callbackComponents = URLComponents(string: "https://aihub.example.test/api/v1/auth/it-sso/callback")!
        callbackComponents.queryItems = [URLQueryItem(name: "token", value: "fixture")]
        let callback = callbackComponents.url!
        let token = try TokenHubDirectQuotaClient.accessToken(
            fromCallbackLocation: "https://aihub.example.test/auth/it/callback#access_token=fixture-access&redirect=%2Fme%2Fapi-key",
            callbackURL: callback)
        check(token == "fixture-access", "callback accepts its original HTTPS origin and fixed landing path")
        callbackComponents.path = "/aimanager/api/v1/auth/it-sso/callback"
        let prefixed = callbackComponents.url!
        let prefixedToken = try TokenHubDirectQuotaClient.accessToken(
            fromCallbackLocation: "https://aihub.example.test/aimanager/auth/it/callback#access_token=fixture-access",
            callbackURL: prefixed)
        check(prefixedToken == "fixture-access", "callback keeps the verified manager path prefix")
        var duplicateFragment = URLComponents()
        duplicateFragment.queryItems = [URLQueryItem(name: "access_token", value: "fixture-access"),
                                        URLQueryItem(name: "access_token", value: "other")]
        let duplicateTokenLocation = "https://aihub.example.test/auth/it/callback#" + duplicateFragment.percentEncodedQuery!
        let rejected = [
            ("https://sibling.example.test/auth/it/callback#access_token=fixture-access", "sibling host"),
            ("https://other.example.test:8443/auth/it/callback#access_token=fixture-access", "sibling host and port"),
            ("https://aihub.example.test:8443/auth/it/callback#access_token=fixture-access", "nondefault port"),
            ("https://user:password@aihub.example.test/auth/it/callback#access_token=fixture-access", "userinfo"),
            ("https://aihub.example.test/auth/it/callback?ignored=1#access_token=fixture-access", "query"),
            ("http://aihub.example.test/auth/it/callback#access_token=fixture-access", "plaintext"),
            ("https://aihub.example.test/unexpected#access_token=fixture-access", "unexpected path"),
            ("https://aihub.example.test/auth/it/callback#access_token=fixture-access&redirect=%2Funexpected", "unexpected fragment redirect"),
            (duplicateTokenLocation, "duplicate access token"),
            ("https://aihub.example.test/auth/it/callback#access_token=fixture-access&redirect=%2Fme%2Fapi-key&redirect=%2Funexpected", "duplicate redirect"),
            ("https://aihub.example.test/auth/it/callback#access_token=fixture%0Aaccess", "control character in token")
        ]
        for (location, label) in rejected {
            do {
                _ = try TokenHubDirectQuotaClient.accessToken(fromCallbackLocation: location, callbackURL: callback)
                check(false, "callback rejects \(label)")
            } catch let error as TokenHubDirectQuotaFailure {
                check(error == .accessTokenMissing, "callback rejects \(label) without exposing credential data")
            }
        }
        let defaultPort = try TokenHubDirectQuotaClient.accessToken(
            fromCallbackLocation: "https://aihub.example.test:443/auth/it/callback#access_token=fixture-access",
            callbackURL: callback)
        check(defaultPort == "fixture-access", "callback permits an explicit default HTTPS port on the same origin")
        let encodedToken = try TokenHubDirectQuotaClient.accessToken(
            fromCallbackLocation: "https://aihub.example.test/auth/it/callback#access_token=fixture%252Daccess",
            callbackURL: callback)
        check(encodedToken == "fixture%2Daccess", "callback decodes token percent escapes exactly once")
        // This suffix is intentionally absent from the compatibility domain
        // list. Redirect security must never depend on a guessed public suffix.
        let nested = URL(string: "https://manager.organization.co.id/api/v1/auth/it-sso/callback")!
        do {
            _ = try TokenHubDirectQuotaClient.accessToken(
                fromCallbackLocation: "https://other.co.id/auth/it/callback#access_token=fixture-access", callbackURL: nested)
            check(false, "callback rejects unrelated registrant under an unlisted suffix")
        } catch let error as TokenHubDirectQuotaFailure {
            check(error == .accessTokenMissing, "callback exact origin rejects unlisted public suffix ambiguity")
        }
    }
}


private func writeDirectQuotaFixture(at database: URL, now: Date, sessionToken: String) throws {
    try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
    var db: OpaquePointer?
    guard sqlite3_open(database.path, &db) == SQLITE_OK, let db else {
        if let db { sqlite3_close(db) }
        throw NSError(domain: "SyntheticDirectQuotaFixture", code: 1)
    }
    defer { sqlite3_close(db) }
    let connection = "{\"aiManagerBaseUrl\":\"https://aihub.example.test\",\"ssoBaseUrl\":\"https://sso.example.test\"}"
    let session = try JSONSerialization.data(withJSONObject: [
        "token": sessionToken, "verifySign": "fixture-signature", "channel": "fixture-channel",
        "tokenType": "fixture-type", "expiresAt": (now.timeIntervalSince1970 + 3600) * 1000
    ])
    let sessionJSON = String(decoding: session, as: UTF8.self).replacingOccurrences(of: "'", with: "''")
    let sql = "CREATE TABLE IF NOT EXISTS client_settings (key TEXT PRIMARY KEY, value_json TEXT);"
        + "INSERT OR REPLACE INTO client_settings VALUES ('client.connection', '\(connection)');"
        + "INSERT OR REPLACE INTO client_settings VALUES ('seasun_sso_session', '\(sessionJSON)');"
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "SyntheticDirectQuotaFixture", code: 2)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database.path)
}


extension CoreChecks {
    static func directDatabaseReplacementChecks() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = TokenHubIdentity(pid: 47817, bundleID: TokenHubTarget.bundleID,
            executablePath: "/Applications/Synthetic Hub.app/Contents/MacOS/Hub")
        let valid = json(#"{"data":{"currency":"USD","windows":[{"kind":"fixed_5h","quota_amount":10,"used_amount":1}]}}"#)
        for scenario in 0..<5 {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-db-replacement-fixture-" + UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let database = TokenHubConnectionDiscovery.defaultDatabaseURL(home: home)
            try writeDirectQuotaFixture(at: database, now: now, sessionToken: "fixture-session")
            let counter = DirectQuotaCounter()
            let client = TokenHubDirectQuotaClient(request: { _, _ in
                let call = counter.noteQuota(true)
                if (scenario == 2 || scenario == 3) && call == 1 {
                    try replaceDirectQuotaFixture(at: database, now: now)
                }
                let status = (scenario == 3 || scenario == 4) && call == 1 ? 401 : 200
                return TokenHubDirectQuotaHTTPResponse(statusCode: status, data: valid)
            }, callbackRequest: { _ in
                let call = counter.noteCallback(true)
                if (scenario == 1 && call == 1) || (scenario == 4 && call == 2) {
                    try replaceDirectQuotaFixture(at: database, now: now)
                }
                return "fixture-access"
            })
            let done = DispatchSemaphore(value: 0)
            Task {
                defer { done.signal() }
                do { _ = try await client.fetch(identity: identity, now: now, home: home); counter.noteSuccess(true) }
                catch { counter.noteFailure(error as? TokenHubDirectQuotaFailure) }
            }
            check(done.wait(timeout: .now() + 3) == .success, "database replacement fixture completes within its bounded wait")
            let state = counter.snapshot()
            if scenario == 0 {
                check(state.4 && state.0 == 1 && state.1 == 1,
                      "unchanged synthetic database accepts a normal 200 quota response")
            } else {
                check(!state.4 && (state.5 == .identityChanged || state.5 == .databaseUnsafe),
                      "same-field database replacement at stage \(scenario) cannot publish a quota snapshot")
                let expectedCallbacks = scenario == 4 ? 2 : 1
                let expectedQuotas = scenario == 1 ? 0 : 1
                check(state.0 == expectedCallbacks && state.1 == expectedQuotas,
                      "database replacement at stage \(scenario) rejects before the next external request")
            }
        }
    }
}

/// Atomically replace only a synthetic fixture. The contents intentionally
/// remain identical while the opened file identity changes.
private func replaceDirectQuotaFixture(at database: URL, now: Date) throws {
    var before = stat()
    guard stat(database.path, &before) == 0 else { throw NSError(domain: "SyntheticDirectQuotaFixture", code: 3) }
    let replacement = database.deletingLastPathComponent().appendingPathComponent("replacement-" + UUID().uuidString + ".db")
    try writeDirectQuotaFixture(at: replacement, now: now, sessionToken: "fixture-session")
    guard rename(replacement.path, database.path) == 0 else { throw NSError(domain: "SyntheticDirectQuotaFixture", code: 4) }
    var after = stat()
    guard stat(database.path, &after) == 0, before.st_dev != after.st_dev || before.st_ino != after.st_ino else {
        throw NSError(domain: "SyntheticDirectQuotaFixture", code: 5)
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
        XCTAssertTrue(local.menuTooltip.contains("99.00%"), "local tooltip renders two decimal places")
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
        XCTAssertTrue(enterprise.menuTooltip.contains("96.00%"), "proxy tooltip renders two decimal places")
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
        let duplicate = duplicateReader.nodes[2]!; duplicateReader.nodes[93] = duplicate
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
import Combine
import SwiftUI
import XCTest
import TokenStatCore
@testable import TokenStatMenu

@MainActor
private final class HubTestScanner {
    var nextResult: TokenHubQuotaResult
    var started: (() -> Void)?
    var beforeReturn: (() async -> Void)?
    private var activeCount = 0
    private(set) var maximumConcurrent = 0
    private(set) var calls = 0
    private(set) var requests: [TokenHubAXRequest] = []
    init(result: TokenHubQuotaResult) { nextResult = result }

    var source: TokenHubAXSource {
        .synthetic { request in await self.scan(request) }
    }

    func scan(_ request: TokenHubAXRequest) async -> TokenHubQuotaResult {
        calls += 1; activeCount += 1; requests.append(request)
        maximumConcurrent = max(maximumConcurrent, activeCount)
        // Preserve the old fake's semantics: a suspended request returns the
        // result captured when it started, not a later generation's value.
        let result = nextResult
        started?()
        await beforeReturn?()
        activeCount -= 1
        return result
    }
}

/// Deterministic suspension without blocking the main actor's executor.
@MainActor
private final class HubScanGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume(); continuation = nil
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

/// Replaces only process discovery and the external direct fetch. All source
/// selection, lifecycle, freshness and late-result handling remain in AppModel.
@MainActor
private final class HubDirectHarness {
    let identity = TokenHubIdentity(pid: 925, bundleID: TokenHubTarget.bundleID,
        executablePath: "/Applications/Synthetic Direct Hub.app/Contents/MacOS/Hub")
    var running = true
    private(set) var requestCount = 0
    private var pending: [Int: (Date, CheckedContinuation<TokenHubQuotaSnapshot, Error>)] = [:]

    var dependencies: TokenHubDirectQuotaDependencies {
        TokenHubDirectQuotaDependencies(discoverTarget: {
            guard self.running else { throw TokenHubQuotaFailure.noTarget }
            return self.identity
        }, identityIsCurrent: { self.running && $0 == self.identity }, fetch: { identity, now in
            guard identity == self.identity else { throw TokenHubDirectQuotaFailure.identityChanged }
            self.requestCount += 1
            let request = self.requestCount
            return try await withCheckedThrowingContinuation { self.pending[request] = (now, $0) }
        })
    }

    func complete(_ request: Int, failure: TokenHubDirectQuotaFailure? = nil) {
        guard let (now, continuation) = pending.removeValue(forKey: request) else { return }
        if let failure { continuation.resume(throwing: failure); return }
        continuation.resume(returning: TokenHubQuotaSnapshot(identity: identity,
            fiveHour: TokenHubWindowQuota(kind: .fiveHour, usedAmount: 3, limitAmount: 10,
                sourceSymbol: "$", usedPercent: 30, resetDisplay: "synthetic reset"),
            sevenDay: TokenHubWindowQuota(kind: .sevenDay, usedAmount: 4, limitAmount: 10,
                sourceSymbol: "$", usedPercent: 40, resetDisplay: "synthetic reset"),
            monthly: TokenHubMonthlyUsage(usedAmount: 12, sourceSymbol: "$"), observedAt: now))
    }

    func finishPending() { for request in Array(pending.keys) { complete(request) } }
}

@MainActor
final class TokenHubQuotaStateTests: XCTestCase {
    private let identity = TokenHubIdentity(pid: 924, bundleID: TokenHubTarget.bundleID,
        executablePath: "/Applications/Synthetic Hub.app/Contents/MacOS/Hub")

    /// A hidden local dashboard must not be invalidated by an unchanged
    /// legacy proxy snapshot at the 0.5-second menu cadence.
    func testIdleLocalTicksDoNotRepublishUnchangedMetrics() {
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        model.config.dataSource = "localCodex"
        model.tick()
        var publications = 0
        let observer = model.objectWillChange.sink { publications += 1 }
        for _ in 0..<100 { model.tick() }
        XCTAssertEqual(publications, 0, "idle menu checks must not redraw the dashboard")
        withExtendedLifetime(observer) {}
    }

    func testLiveExpiryPublishesOnceAndStillRefreshesMenuEveryTick() {
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var now = observedAt
        model.tokenHubNow = { now }
        model.config.dataSource = "localCodex"
        model.localSnapshot = LocalCodexSnapshot(input: 100, output: 50, total: 150,
            sessionCount: 1, filesScanned: 1, isLimited: false, latestEventAt: observedAt,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 1,
            liveTurn: LocalLiveTurnSummary(inputTPS: 10, outputTPS: 24.5, observedAt: observedAt))
        model.tick()
        var publications = 0, menuChecks = 0
        let observer = model.objectWillChange.sink { publications += 1 }
        model.onTick = { menuChecks += 1 }
        now = observedAt.addingTimeInterval(15)
        model.tick()
        XCTAssertEqual(publications, 0, "the exact freshness boundary remains live")
        now = observedAt.addingTimeInterval(15.001)
        model.tick()
        XCTAssertEqual(publications, 1, "expiry must notify an open dashboard once")
        XCTAssertTrue(model.title.hasPrefix("上轮均:—"))
        for _ in 0..<100 { model.tick() }
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(menuChecks, 102, "the menu cadence is independent of dashboard notifications")
        now = observedAt
        model.tick()
        XCTAssertEqual(publications, 2, "clock rollback must recompute time-dependent presentation")
        XCTAssertTrue(model.title.hasPrefix("实时≈24.5tok/s"))
        withExtendedLifetime(observer) {}
    }

    func testDashboardHostingIsDeferredUntilFirstOpenAndReused() {
        _ = NSApplication.shared
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        var dashboardCreations = 0
        let factories = StatusBarContentFactories(dashboard: { model in
            dashboardCreations += 1
            return NSHostingController(rootView: DashboardView(model: model))
        }, tooltip: { $0.menuTooltip })
        let controller = StatusBarController(model: model, factories: factories)
        XCTAssertEqual(dashboardCreations, 0, "menu-only startup must not allocate the SwiftUI dashboard")
        controller.show()
        XCTAssertEqual(dashboardCreations, 1)
        XCTAssertTrue(model.panelVisible)
        controller.toggle()
        controller.show()
        XCTAssertEqual(dashboardCreations, 1, "reopening reuses native hosting and its settings-page state")
        controller.toggle()
    }

    func testDiagnosticsURLIsCachedAndNilDisablesOutput() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStatMenu-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("report.json")
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        let controller = StatusBarController(model: model, diagnosticsURL: output)

        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: output.path) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let firstData = try Data(contentsOf: output)
        let firstAttributes = try FileManager.default.attributesOfItem(atPath: output.path)
        let firstModificationDate = try XCTUnwrap(firstAttributes[.modificationDate] as? Date)
        let firstObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: firstData) as? [String: Any])
        let approvedKeys: Set<String> = [
            "seasunOnlyMode", "backgroundServicesStarted", "statusItemVisible",
            "permissionPromptRequested", "quotaPresent", "directQuotaPresent",
            "directQuotaStatus", "fiveHourPresent", "sevenDayPresent",
            "fiveHourResetPresent", "sevenDayResetPresent", "resetTimePresent",
            "monthlyUsagePresent", "liveTokenSpeedPresent", "sourceStatus",
            "backgroundServiceResources"
        ]
        XCTAssertEqual(Set(firstObject.keys), approvedKeys)

        controller.refreshTitle()
        try await Task.sleep(for: .milliseconds(100))
        let secondData = try Data(contentsOf: output)
        let secondAttributes = try FileManager.default.attributesOfItem(atPath: output.path)
        let secondModificationDate = try XCTUnwrap(secondAttributes[.modificationDate] as? Date)
        XCTAssertEqual(secondData, firstData)
        XCTAssertEqual(secondModificationDate, firstModificationDate,
                       "the one-second diagnostic throttle should avoid a second write")

        let nilOutput = directory.appendingPathComponent("nil.json")
        let nilModel = AppModel(preview: true)
        defer { nilModel.shutdown() }
        let nilController = StatusBarController(model: nilModel, diagnosticsURL: nil)
        nilController.refreshTitle()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nilOutput.path))
        withExtendedLifetime(controller) {}
        withExtendedLifetime(nilController) {}
    }

    func testDiagnosticsUsesModelClockForFreshness() async throws {
        _ = NSApplication.shared
        let harness = HubDirectHarness()
        let permission = HubTestPermission(); permission.trusted = false
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = HubManualClock(observedAt)
        let model = directModel(harness, clock: clock, permission: permission)
        defer { model.shutdown(); harness.finishPending() }

        model.refreshTokenHubQuota()
        guard await waitForDirectRequests(1, harness: harness) else { return }
        harness.complete(1)
        await settle(model, status: .connected)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStatMenu-diagnostics-clock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let freshOutput = directory.appendingPathComponent("fresh.json")
        let freshController = StatusBarController(model: model, diagnosticsURL: freshOutput)
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: freshOutput.path) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let freshData = try Data(contentsOf: freshOutput)
        let freshObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: freshData) as? [String: Any])
        XCTAssertEqual(freshObject["directQuotaPresent"] as? Bool, true,
                       "diagnostics should use the injected model clock while the snapshot is fresh")

        clock.now = observedAt.addingTimeInterval(120.001)
        let staleOutput = directory.appendingPathComponent("stale.json")
        let staleController = StatusBarController(model: model, diagnosticsURL: staleOutput)
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: staleOutput.path) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let staleData = try Data(contentsOf: staleOutput)
        let staleObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: staleData) as? [String: Any])
        XCTAssertEqual(staleObject["directQuotaPresent"] as? Bool, false,
                       "diagnostics should expire the snapshot at the injected model-clock boundary")
        withExtendedLifetime(freshController) {}
        withExtendedLifetime(staleController) {}
    }

    func testTooltipFormattingIsReusedForIdleTicksButTracksValuesAndTimeBoundaries() throws {
        _ = NSApplication.shared
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        model.config.dataSource = "localCodex"
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var now = observedAt
        model.tokenHubNow = { now }
        model.localSnapshot = LocalCodexSnapshot(input: 100, output: 50, total: 150,
            sessionCount: 1, filesScanned: 1, isLimited: false, latestEventAt: observedAt,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 1,
            liveTurn: LocalLiveTurnSummary(inputTPS: 10, outputTPS: 24.5, observedAt: observedAt))
        var tooltipBuilds = 0
        var displayedTooltip = ""
        let factories = StatusBarContentFactories(dashboard: { NSHostingController(rootView: DashboardView(model: $0)) },
            tooltip: { model in
                tooltipBuilds += 1
                displayedTooltip = model.menuTooltip
                return displayedTooltip
            })
        let controller = StatusBarController(model: model, factories: factories)
        model.tick()
        XCTAssertEqual(tooltipBuilds, 1)
        XCTAssertTrue(displayedTooltip.contains("输出 24.5 tok/s"))
        for _ in 0..<100 { model.tick() }
        XCTAssertEqual(tooltipBuilds, 1, "unchanged half-second menu checks reuse the formatted tooltip")
        now = observedAt.addingTimeInterval(15.001)
        model.tick()
        XCTAssertEqual(tooltipBuilds, 2)
        XCTAssertTrue(displayedTooltip.contains("实时估算：未知"))
        now = observedAt
        controller.refreshTitle()
        XCTAssertTrue(displayedTooltip.contains("输出 24.5 tok/s"), "clock rollback updates even without another file scan")

        model.localSnapshot = LocalCodexSnapshot(input: 200, output: 75, total: 275,
            sessionCount: 1, filesScanned: 1, isLimited: false, latestEventAt: observedAt,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 1)
        model.tick()
        XCTAssertTrue(displayedTooltip.contains("总计 275"), "new measurements invalidate the tooltip")
        let quotaData = try JSONSerialization.data(withJSONObject: ["result": ["rateLimits": [
            "primary": ["usedPercent": 22, "windowDurationMins": 300,
                        "resetsAt": observedAt.addingTimeInterval(10).timeIntervalSince1970]
        ]]])
        model.fiveHourQuota = try QuotaReport.parse(quotaData, config: AppConfiguration(),
            now: observedAt.addingTimeInterval(2)).fiveHour
        model.tick()
        XCTAssertTrue(displayedTooltip.contains("异常时间戳"))
        now = observedAt.addingTimeInterval(2)
        model.tick()
        XCTAssertFalse(displayedTooltip.contains("异常时间戳"))
        now = observedAt.addingTimeInterval(10)
        model.tick()
        XCTAssertTrue(displayedTooltip.contains("重置已过期"), "a cached historical reset label must still expire")
        model.config.dataSource = "proxy"
        controller.refreshTitle()
        XCTAssertTrue(displayedTooltip.contains("已配置企业用量接口数据"), "configuration and source changes invalidate the cache")
    }

    func testCachedTooltipDropsExpiredHubSnapshotAtBoundary() async {
        _ = NSApplication.shared
        let harness = HubDirectHarness()
        let permission = HubTestPermission(); permission.trusted = false
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = HubManualClock(observedAt)
        let model = directModel(harness, clock: clock, permission: permission)
        defer { model.shutdown(); harness.finishPending() }
        var tooltipBuilds = 0
        var displayedTooltip = ""
        let controller = StatusBarController(model: model, factories: StatusBarContentFactories(
            dashboard: { NSHostingController(rootView: DashboardView(model: $0)) }, tooltip: { model in
                tooltipBuilds += 1
                displayedTooltip = model.menuTooltip
                return displayedTooltip
            }))
        model.refreshTokenHubQuota()
        guard await waitForDirectRequests(1, harness: harness) else { return }
        harness.complete(1)
        await settle(model, status: .connected)
        model.tick()
        XCTAssertTrue(model.title.contains("Hub 5h剩 70.00% / 7d剩 60.00%"))
        XCTAssertTrue(displayedTooltip.contains("5 小时）"))
        let beforeBoundary = tooltipBuilds
        clock.now = observedAt.addingTimeInterval(120)
        model.tick()
        XCTAssertEqual(tooltipBuilds, beforeBoundary, "the inclusive Hub freshness boundary does not rebuild")
        clock.now = observedAt.addingTimeInterval(120.001)
        model.tick()
        XCTAssertFalse(model.title.contains("Hub 5h剩"))
        XCTAssertTrue(displayedTooltip.contains("5 小时未知"))
        XCTAssertEqual(model.tokenHubQuotaStatus, .stale)
        let afterExpiry = tooltipBuilds
        for _ in 0..<100 { model.tick() }
        XCTAssertEqual(tooltipBuilds, afterExpiry, "an expired snapshot must not cause endless redraws")
        withExtendedLifetime(controller) {}
    }

    func testTokenHubCardUsesModelClockForFreshness() async {
        let harness = HubDirectHarness()
        let permission = HubTestPermission(); permission.trusted = false
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = HubManualClock(observedAt)
        let model = directModel(harness, clock: clock, permission: permission)
        defer { model.shutdown(); harness.finishPending() }

        model.refreshTokenHubQuota()
        guard await waitForDirectRequests(1, harness: harness) else { return }
        harness.complete(1)
        await settle(model, status: .connected)

        let dashboard = DashboardView(model: model)
        XCTAssertNotNil(dashboard.tokenHubCard.snapshot,
                       "the card should use the injected model clock at the observation time")

        clock.now = observedAt.addingTimeInterval(120)
        XCTAssertNotNil(dashboard.tokenHubCard.snapshot,
                       "the inclusive freshness boundary should remain visible")
        clock.now = observedAt.addingTimeInterval(120.001)
        XCTAssertNil(dashboard.tokenHubCard.snapshot,
                     "the card should expire from the injected model clock")
    }

    func testLiveObservationBetweenTicksStillInvalidatesAtItsNextExpiry() {
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        let initial = Date(timeIntervalSince1970: 1_800_000_000)
        var now = initial
        model.tokenHubNow = { now }
        model.config.dataSource = "localCodex"
        model.tick() // Previous timer state has no fresh live observation.
        model.localSnapshot = LocalCodexSnapshot(input: 100, output: 50, total: 150,
            sessionCount: 1, filesScanned: 1, isLimited: false, latestEventAt: initial,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 1,
            liveTurn: LocalLiveTurnSummary(inputTPS: 10, outputTPS: 24.5,
                observedAt: initial.addingTimeInterval(-14.9)))
        XCTAssertTrue(model.title.hasPrefix("实时≈24.5tok/s"), "the intervening data publication can render live")
        var publicationsAfterData = 0
        let observer = model.objectWillChange.sink { publicationsAfterData += 1 }
        now = initial.addingTimeInterval(0.2)
        model.tick()
        XCTAssertEqual(publicationsAfterData, 1,
                       "expiry must compare against the presented new input, not only the last timer tick")
        XCTAssertTrue(model.title.hasPrefix("上轮均:—"))
        for _ in 0..<100 { model.tick() }
        XCTAssertEqual(publicationsAfterData, 1, "expired input must not restore blanket redraws")
        withExtendedLifetime(observer) {}
    }

    func testBackgroundLocaleAndTimezoneNotificationsInvalidateTooltipOnMainActor() async {
        _ = NSApplication.shared
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        var builds = 0
        let controller = StatusBarController(model: model, factories: StatusBarContentFactories(
            dashboard: { NSHostingController(rootView: DashboardView(model: $0)) }, tooltip: { model in
                XCTAssertTrue(Thread.isMainThread, "native formatting stays on the main actor")
                builds += 1
                return model.menuTooltip
            }))
        XCTAssertEqual(builds, 1)
        for name in [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange] {
            let posted = expectation(description: "synthetic background formatting notification")
            DispatchQueue.global(qos: .utility).async {
                NotificationCenter.default.post(name: name, object: nil)
                posted.fulfill()
            }
            await fulfillment(of: [posted], timeout: 2)
            let before = builds
            for _ in 0..<100 where builds == before {
                try? await Task.sleep(for: .milliseconds(1))
                controller.refreshTitle()
            }
            XCTAssertEqual(builds, before + 1, "a formatting notification must invalidate the cached tooltip")
            for _ in 0..<100 { controller.refreshTitle() }
            XCTAssertEqual(builds, before + 1, "one notification cannot turn into repeated tooltip rebuilds")
        }
        withExtendedLifetime(controller) {}
    }

    func testHistoricalWindowUpdatedBetweenTicksStillPublishesItsResetExpiry() throws {
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        let initial = Date(timeIntervalSince1970: 1_800_000_000)
        var now = initial
        model.tokenHubNow = { now }
        model.config.dataSource = "localCodex"
        func window(reset: Date, fetchedAt: Date) throws -> WindowQuota? {
            let bytes = try JSONSerialization.data(withJSONObject: ["result": ["rateLimits": [
                "primary": ["usedPercent": 22, "windowDurationMins": 300,
                            "resetsAt": reset.timeIntervalSince1970]
            ]]])
            return try QuotaReport.parse(bytes, config: AppConfiguration(), now: fetchedAt).fiveHour
        }
        model.fiveHourQuota = try window(reset: initial.addingTimeInterval(-1),
                                         fetchedAt: initial.addingTimeInterval(-1000))
        model.tick() // Old historical window was already expired.
        model.fiveHourQuota = try window(reset: initial.addingTimeInterval(0.1), fetchedAt: initial)
        XCTAssertFalse(model.menuTooltip.contains("重置已过期"))
        var publicationsAfterData = 0
        let observer = model.objectWillChange.sink { publicationsAfterData += 1 }
        now = initial.addingTimeInterval(0.2)
        model.tick()
        XCTAssertEqual(publicationsAfterData, 1, "a new window reset can also cross between timer ticks")
        XCTAssertTrue(model.menuTooltip.contains("重置已过期"))
        model.tick()
        XCTAssertEqual(publicationsAfterData, 1)
        withExtendedLifetime(observer) {}
    }

    func testHubObservationArrivingNearExpiryStillPublishesItsInvalidation() async {
        let harness = HubDirectHarness()
        let permission = HubTestPermission(); permission.trusted = false
        let initial = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = HubManualClock(initial)
        let model = directModel(harness, clock: clock, permission: permission)
        defer { model.shutdown(); harness.finishPending() }
        model.tick() // No Hub observation at the old timer tick.
        model.refreshTokenHubQuota()
        guard await waitForDirectRequests(1, harness: harness) else { return }
        clock.now = initial.addingTimeInterval(119.9)
        harness.complete(1)
        await settle(model, status: .connected)
        XCTAssertNotNil(model.freshTokenHubQuota(at: clock.now))
        var publicationsAfterData = 0
        let observer = model.objectWillChange.sink { publicationsAfterData += 1 }
        clock.now = initial.addingTimeInterval(120.1)
        model.tick()
        XCTAssertEqual(publicationsAfterData, 1)
        XCTAssertNil(model.freshTokenHubQuota(at: clock.now))
        XCTAssertEqual(model.tokenHubQuotaStatus, .stale)
        model.tick()
        XCTAssertEqual(publicationsAfterData, 1)
        withExtendedLifetime(observer) {}
    }

    func testProductionCompatibilityPreferenceCannotDisableAutomaticDirectSource() {
        let startup = AppModelStartupDependencies(loadPreferences: { nil }, savePreferences: { _ in },
                                                  shouldStartBackgroundServices: { false })
        let model = AppModel(startup: startup)
        defer { model.shutdown() }

        model.setTokenHubAutomaticReadingEnabled(false)

        XCTAssertFalse(model.preferences.tokenHubCompatibilityReadEnabled)
        XCTAssertNotEqual(model.tokenHubQuotaStatus, .disabled,
                          "disabling optional AX compatibility must leave the automatic direct source available")
    }

    func testLiveMenuSpeedUsesOneLabelAndExpiresWithoutAnotherLocalScan() {
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        model.config.dataSource = "localCodex"
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var now = observedAt
        model.tokenHubNow = { now }
        model.localSnapshot = LocalCodexSnapshot(input: 100, output: 50, total: 150,
            sessionCount: 1, filesScanned: 1, isLimited: false, latestEventAt: observedAt,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 1,
            lastTurn: LocalTurnSummary(outputTokens: 50, durationSeconds: 2, completedAt: observedAt),
            liveTurn: LocalLiveTurnSummary(inputTPS: 10, outputTPS: 24.5, observedAt: observedAt))

        XCTAssertTrue(model.title.hasPrefix("实时≈24.5tok/s ·"), "a live rate must not be prefixed with the completed-turn label")
        XCTAssertTrue(model.menuTooltip.contains("实时估算：输入 10.0 · 输出 24.5 tok/s"))
        now = observedAt.addingTimeInterval(15)
        XCTAssertTrue(model.title.hasPrefix("实时≈24.5tok/s ·"), "the 15-second boundary is still fresh")
        now = observedAt.addingTimeInterval(15.001)
        XCTAssertTrue(model.title.hasPrefix("上轮均:25.0tok/s ·"), "a stalled scan cannot keep an old estimate live indefinitely")
        XCTAssertTrue(model.menuTooltip.contains("实时估算：未知"), "tooltip freshness must match menu freshness")
        now = observedAt.addingTimeInterval(-0.001)
        XCTAssertTrue(model.title.hasPrefix("上轮均:25.0tok/s ·"), "a future observation is not fresh")
        XCTAssertTrue(model.menuTooltip.contains("实时估算：未知"))
    }

    func testUnknownMenuSpeedUsesOneCompletedTurnLabel() {
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        model.config.dataSource = "localCodex"
        XCTAssertTrue(model.title.hasPrefix("上轮均:— ·"), "unknown speed must not duplicate its label")
    }

    func testUnknownAndAccountingLabelsRemainExplicitWhenSourcesAreMissing() {
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        model.config.dataSource = "localCodex"

        // No live turn, completed turn, or quota windows is the synthetic
        // missing-data state used by a fresh or stale local scan.
        model.localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0,
            sessionCount: 0, filesScanned: 0, isLimited: false, latestEventAt: nil,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 0,
            unknownThreadCount: 0)
        XCTAssertTrue(model.title.contains("上轮均:—"))
        XCTAssertTrue(model.menuTooltip.contains("实时估算：未知"))
        XCTAssertTrue(model.menuTooltip.contains("5 小时未知"))
        XCTAssertTrue(model.menuTooltip.contains("7 天未知"))

        model.localSnapshot = LocalCodexSnapshot(input: 120, output: 80, total: 200,
            sessionCount: 2, filesScanned: 32, isLimited: true, latestEventAt: nil,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 3,
            unknownThreadCount: 2)
        XCTAssertTrue(model.title.contains("小计"))
        XCTAssertTrue(model.title.contains("未核验"))

        model.localSnapshot = LocalCodexSnapshot(input: 120, output: 80, total: 200,
            sessionCount: 2, filesScanned: 3, isLimited: false, latestEventAt: nil,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 3,
            unknownThreadCount: 0)
        XCTAssertTrue(model.title.contains("Σ"))
        XCTAssertTrue(model.title.contains("顶层对话"))
    }

    private func directModel(_ harness: HubDirectHarness, clock: HubManualClock,
                             permission: HubTestPermission, axSource: TokenHubAXSource? = nil) -> AppModel {
        let model = AppModel(preview: true, directQuota: harness.dependencies, tokenHubAXSource: axSource)
        model.config.dataSource = "localCodex"
        model.config.refreshSeconds = 60
        model.tokenHubNow = { clock.now }
        model.tokenHubPermissionProvider = permission
        return model
    }

    private func waitForDirectRequests(_ count: Int, harness: HubDirectHarness) async -> Bool {
        for _ in 0..<100 {
            if harness.requestCount >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("automatic direct source did not start request \(count)")
        return false
    }

    private func waitForDirectObservation(_ model: AppModel, at now: Date) async {
        for _ in 0..<100 {
            if model.tokenHubQuotaSnapshot?.observedAt == now, model.tokenHubQuotaIsDirect { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("AppModel did not accept the current synthetic direct observation")
    }

    func testDirectSourceAutomaticallyReadsOnTargetLaunchWithoutAXPermission() async {
        let harness = HubDirectHarness()
        let permission = HubTestPermission(); permission.trusted = false
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = directModel(harness, clock: HubManualClock(now), permission: permission)
        defer { model.shutdown(); harness.finishPending() }

        model.tokenHubApplicationDidLaunch(bundleIdentifier: TokenHubTarget.bundleID)
        guard await waitForDirectRequests(1, harness: harness) else { return }
        harness.complete(1)
        await settle(model, status: .connected)

        XCTAssertTrue(model.tokenHubQuotaIsDirect)
        XCTAssertNotNil(model.freshTokenHubQuota(at: now))
        XCTAssertFalse(model.tokenHubPermissionGrantedForDiagnostics)
        XCTAssertEqual(permission.requests, 0, "unattended direct reading never prompts for OS permission")
    }

    func testDisablingAXCompatibilityPreservesDirectSnapshotAndAutomaticRelaunch() async {
        let harness = HubDirectHarness()
        let permission = HubTestPermission(); permission.trusted = false
        let clock = HubManualClock(Date(timeIntervalSince1970: 1_800_000_000))
        let model = directModel(harness, clock: clock, permission: permission)
        defer { model.shutdown(); harness.finishPending() }
        model.refreshTokenHubQuota()
        guard await waitForDirectRequests(1, harness: harness) else { return }
        harness.complete(1)
        await settle(model, status: .connected)
        let snapshot = model.tokenHubQuotaSnapshot

        model.setTokenHubAutomaticReadingEnabled(false)
        XCTAssertEqual(model.tokenHubQuotaSnapshot, snapshot, "the AX-only switch must not clear direct enterprise data")
        XCTAssertEqual(model.freshTokenHubQuota(at: clock.now), snapshot, "direct data remains selected with AX compatibility off")
        model.tokenHubApplicationDidTerminate(bundleIdentifier: TokenHubTarget.bundleID)
        XCTAssertNil(model.tokenHubQuotaSnapshot)
        model.tokenHubApplicationDidLaunch(bundleIdentifier: TokenHubTarget.bundleID)
        guard await waitForDirectRequests(2, harness: harness) else { return }
        harness.complete(2)
        await settle(model, status: .connected)
        XCTAssertTrue(model.tokenHubQuotaIsDirect)
        XCTAssertEqual(permission.requests, 0)
    }

    func testAXPermissionRevocationDoesNotClearOrInvalidateDirectRead() async {
        let harness = HubDirectHarness()
        let permission = HubTestPermission()
        let clock = HubManualClock(Date(timeIntervalSince1970: 1_800_000_000))
        let model = directModel(harness, clock: clock, permission: permission)
        defer { model.shutdown(); harness.finishPending() }
        model.refreshTokenHubQuota()
        guard await waitForDirectRequests(1, harness: harness) else { return }
        harness.complete(1)
        await settle(model, status: .connected)
        let snapshot = model.tokenHubQuotaSnapshot
        XCTAssertTrue(model.tokenHubPermissionGrantedForDiagnostics)

        clock.now = clock.now.addingTimeInterval(2.1)
        permission.trusted = false
        model.refreshTokenHubQuota()
        guard await waitForDirectRequests(2, harness: harness) else { return }
        XCTAssertFalse(model.tokenHubPermissionGrantedForDiagnostics)
        XCTAssertEqual(model.tokenHubQuotaSnapshot, snapshot, "revoking optional AX trust cannot remove direct data")
        harness.complete(2)
        await waitForDirectObservation(model, at: clock.now)
        XCTAssertEqual(model.tokenHubQuotaSnapshot?.observedAt, clock.now)
        XCTAssertTrue(model.tokenHubQuotaIsDirect)
    }

    func testDirectTargetExitRejectsLateResultWithoutUnlockingRelaunchedRequest() async {
        let harness = HubDirectHarness()
        let permission = HubTestPermission(); permission.trusted = false
        let clock = HubManualClock(Date(timeIntervalSince1970: 1_800_000_000))
        let model = directModel(harness, clock: clock, permission: permission)
        defer { model.shutdown(); harness.finishPending() }
        model.refreshTokenHubQuota()
        guard await waitForDirectRequests(1, harness: harness) else { return }

        model.tokenHubApplicationDidTerminate(bundleIdentifier: TokenHubTarget.bundleID)
        XCTAssertNil(model.tokenHubQuotaSnapshot)
        XCTAssertEqual(model.tokenHubQuotaStatus, .targetNotRunning)
        clock.now = clock.now.addingTimeInterval(1)
        model.tokenHubApplicationDidLaunch(bundleIdentifier: TokenHubTarget.bundleID)
        guard await waitForDirectRequests(2, harness: harness) else { return }
        harness.complete(1)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.tokenHubQuotaSnapshot, "a pre-exit result cannot become current after relaunch")
        model.refreshTokenHubQuota()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(harness.requestCount, 2, "an old completion cannot unlock a different generation's in-flight request")
        harness.complete(2)
        await settle(model, status: .connected)
        XCTAssertEqual(model.tokenHubQuotaSnapshot?.observedAt, clock.now)

        model.tokenHubApplicationDidTerminate(bundleIdentifier: TokenHubTarget.bundleID)
        XCTAssertNil(model.tokenHubQuotaSnapshot, "exit clears a previously accepted direct snapshot synchronously")
        XCTAssertFalse(model.tokenHubQuotaIsDirect)
    }

    func testDisabledAXCompatibilityCannotFallbackAfterDirectFailure() async {
        let harness = HubDirectHarness()
        let permission = HubTestPermission()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scanner = HubTestScanner(result: result(now: now))
        let model = directModel(harness, clock: HubManualClock(now), permission: permission, axSource: scanner.source)
        defer { model.shutdown(); harness.finishPending() }
        model.setTokenHubAutomaticReadingEnabled(false)
        model.refreshTokenHubQuota()
        guard await waitForDirectRequests(1, harness: harness) else { return }
        harness.complete(1, failure: .transportFailed)
        await settle(model, status: .accessFailed)
        XCTAssertEqual(model.tokenHubDirectFailure, .transportFailed)
        XCTAssertNil(model.tokenHubQuotaSnapshot)
        XCTAssertEqual(scanner.calls, 0, "the compatibility preference controls only the optional AX fallback")
    }

    func testRevokedAXFallbackKeepsDirectFailureAndAutomaticallyRetriesDirectSource() async {
        let harness = HubDirectHarness()
        let permission = HubTestPermission()
        let clock = HubManualClock(Date(timeIntervalSince1970: 1_800_000_000))
        let scanner = HubTestScanner(result: result(now: clock.now))
        let model = directModel(harness, clock: clock, permission: permission, axSource: scanner.source)
        model.config.refreshSeconds = 0.05
        defer { model.shutdown(); harness.finishPending() }
        model.refreshTokenHubQuota()
        guard await waitForDirectRequests(1, harness: harness) else { return }
        XCTAssertTrue(model.tokenHubPermissionGrantedForDiagnostics)

        clock.now = clock.now.addingTimeInterval(2.1)
        permission.trusted = false
        harness.complete(1, failure: .transportFailed)
        guard await waitForDirectRequests(2, harness: harness) else { return }
        XCTAssertEqual(model.tokenHubDirectFailure, .transportFailed,
                       "AX revocation during a direct failure must not erase the direct error")
        XCTAssertNotEqual(model.tokenHubQuotaStatus, .permissionRequired,
                          "missing optional trust cannot stop the unattended direct source")
        XCTAssertEqual(scanner.calls, 0)
        harness.complete(2)
        await waitForDirectObservation(model, at: clock.now)
        XCTAssertEqual(permission.requests, 0)
    }

    func testLateAXFallbackCannotOverwriteNewerDirectObservation() async {
        let harness = HubDirectHarness()
        let permission = HubTestPermission()
        let clock = HubManualClock(Date(timeIntervalSince1970: 1_800_000_000))
        let scanner = HubTestScanner(result: result(now: clock.now))
        let model = directModel(harness, clock: clock, permission: permission, axSource: scanner.source)
        let axStarted = expectation(description: "synthetic AX fallback started")
        let releaseAX = HubScanGate()
        scanner.started = { axStarted.fulfill() }
        scanner.beforeReturn = { await releaseAX.wait() }
        defer { model.shutdown(); harness.finishPending(); releaseAX.release() }
        model.refreshTokenHubQuota()
        guard await waitForDirectRequests(1, harness: harness) else { return }
        harness.complete(1, failure: .transportFailed)
        await fulfillment(of: [axStarted], timeout: 2)

        clock.now = clock.now.addingTimeInterval(1)
        model.refreshTokenHubQuota()
        guard await waitForDirectRequests(2, harness: harness) else { return }
        harness.complete(2)
        await waitForDirectObservation(model, at: clock.now)
        let directSnapshot = model.tokenHubQuotaSnapshot
        releaseAX.release()
        for _ in 0..<100 {
            if model.backgroundServiceResources.axScanInFlightCount == 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.backgroundServiceResources.axScanInFlightCount, 0)
        XCTAssertEqual(model.tokenHubQuotaSnapshot, directSnapshot,
                       "a slow compatibility response cannot replace a newer enterprise response")
        XCTAssertTrue(model.tokenHubQuotaIsDirect)
        XCTAssertEqual(model.tokenHubQuotaStatus, .connected)
        XCTAssertNil(model.tokenHubDirectFailure)
    }

    func testLateAXAfterRelaunchCannotUnlockCurrentDirectRequest() async {
        let harness = HubDirectHarness()
        let permission = HubTestPermission()
        let clock = HubManualClock(Date(timeIntervalSince1970: 1_800_000_000))
        let scanner = HubTestScanner(result: result(now: clock.now))
        let model = directModel(harness, clock: clock, permission: permission, axSource: scanner.source)
        let gate = HubScanGate()
        let started = expectation(description: "old target AX fallback suspended")
        scanner.started = { started.fulfill() }
        scanner.beforeReturn = { await gate.wait() }
        defer { model.shutdown(); harness.finishPending(); gate.release() }
        model.refreshTokenHubQuota()
        guard await waitForDirectRequests(1, harness: harness) else { return }
        harness.complete(1, failure: .transportFailed)
        await fulfillment(of: [started], timeout: 2)

        model.tokenHubApplicationDidTerminate(bundleIdentifier: TokenHubTarget.bundleID)
        clock.now = clock.now.addingTimeInterval(1)
        model.tokenHubApplicationDidLaunch(bundleIdentifier: TokenHubTarget.bundleID)
        guard await waitForDirectRequests(2, harness: harness) else { return }
        gate.release()
        for _ in 0..<100 {
            if model.backgroundServiceResources.axScanInFlightCount == 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(model.tokenHubQuotaSnapshot, "pre-exit AX data cannot become current after relaunch")
        model.refreshTokenHubQuota()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(harness.requestCount, 2,
                       "an old AX completion must not release the newer direct request's in-flight guard")
        XCTAssertEqual(scanner.calls, 1)
        XCTAssertEqual(model.backgroundServiceResources.axScanInFlightCount, 0)
        harness.complete(2)
        await waitForDirectObservation(model, at: clock.now)
        XCTAssertTrue(model.tokenHubQuotaIsDirect)
        XCTAssertEqual(permission.requests, 0)
    }

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
        let scanner = HubTestScanner(result: value)
        let model = AppModel(preview: true, tokenHubAXSource: scanner.source)
        model.config.dataSource = "localCodex"
        model.config.refreshSeconds = 60
        model.tokenHubAutomaticReadingEnabled = true
        model.tokenHubNow = { clock.now }
        let permission = HubTestPermission()
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

        let scanner = HubTestScanner(result: TokenHubQuotaResult(status: .targetNotRunning, snapshot: nil, failure: nil))
        let model = AppModel(preview: true, tokenHubAXSource: scanner.source)
        defer { model.shutdown() }
        model.config.dataSource = "localCodex"
        model.tokenHubAutomaticReadingEnabled = false

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

    func testNativeAXWorkerRejectsUntrustedRequestAndSourceRetainsNativeKind() async {
        let request = TokenHubAXRequest(now: Date(timeIntervalSince1970: 1_800_000_000),
            permissionTrusted: false, refreshSeconds: 60, mode: .localCodex, generation: 41)
        let workerResult = await NativeTokenHubAXWorker().scan(request)
        XCTAssertEqual(workerResult.status, .permissionRequired)
        XCTAssertEqual(workerResult.failure, .permissionMissing)
        XCTAssertNil(workerResult.snapshot)

        // The real reader uses Core's already-tested pre-discovery permission
        // gate. This negative call never discovers a process or sends AX I/O.
        let native = TokenHubAXSource.production
        XCTAssertEqual(native.kind, .native, "closure wrapping must not erase fixture suppression identity")
        let wrappedResult = await native.scan(request)
        XCTAssertEqual(wrappedResult.status, .permissionRequired)
        XCTAssertEqual(wrappedResult.failure, .permissionMissing)
        XCTAssertNil(wrappedResult.snapshot)
        XCTAssertTrue(AppModel.shouldSuppressNativeTokenHubRead(isTestFixture: true,
            scannerIsNative: native.kind == .native))
        XCTAssertFalse(AppModel.shouldSuppressNativeTokenHubRead(isTestFixture: false,
            scannerIsNative: native.kind == .native), "ordinary preview behavior must stay unchanged")

        let scanner = HubTestScanner(result: wrappedResult)
        XCTAssertEqual(scanner.source.kind, .synthetic)
        XCTAssertFalse(AppModel.shouldSuppressNativeTokenHubRead(isTestFixture: true,
            scannerIsNative: scanner.source.kind == .native))
        let defaultModel = AppModel(preview: true)
        defer { defaultModel.shutdown() }
        XCTAssertEqual(defaultModel.isFixtureUsingNativeTokenHubReader, defaultModel.isTestFixture,
                       "the default source stays classified as native after initializer injection")
    }

    func testPendingAXRejectsLateResultsAfterDisableRevocationModeChangeAndShutdown() async {
        enum Transition: CaseIterable { case disable, revoke, proxy, shutdown }
        for transition in Transition.allCases {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let clock = HubManualClock(now)
            let (model, scanner, permission) = configuredModel(result(now: now), clock: clock)
            let gate = HubScanGate()
            defer { model.shutdown(); gate.release() }
            let started = expectation(description: "AX suspended before \(transition)")
            scanner.started = { started.fulfill() }
            scanner.beforeReturn = { await gate.wait() }
            model.refreshTokenHubQuota()
            await fulfillment(of: [started], timeout: 2)
            XCTAssertEqual(model.backgroundServiceResources.axScanInFlightCount, 1)

            let status: TokenHubQuotaStatus
            switch transition {
            case .disable:
                model.setTokenHubAutomaticReadingEnabled(false); status = .disabled
            case .revoke:
                clock.now = clock.now.addingTimeInterval(2.1); permission.trusted = false
                model.refreshTokenHubQuota(); status = .permissionRequired
            case .proxy:
                model.config.dataSource = "proxy"; model.refreshTokenHubQuota(); status = .disabled
            case .shutdown:
                model.shutdown(); status = .disabled
            }
            XCTAssertEqual(model.tokenHubQuotaStatus, status)
            XCTAssertNil(model.tokenHubQuotaSnapshot)
            gate.release()
            for _ in 0..<100 {
                let resources = model.backgroundServiceResources
                if resources.axScanInFlightCount == 0 && resources.axRefreshScheduledCount == 0 { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(model.tokenHubQuotaStatus, status, "late success cannot undo \(transition)")
            XCTAssertNil(model.tokenHubQuotaSnapshot, "late success cannot repopulate after \(transition)")
            XCTAssertEqual(scanner.calls, 1)
            XCTAssertEqual(scanner.maximumConcurrent, 1)
            XCTAssertEqual(model.backgroundServiceResources.axScanInFlightCount, 0)
            XCTAssertEqual(model.backgroundServiceResources.axRefreshScheduledCount, 0)
            XCTAssertEqual(permission.requests, 0)
        }
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
        XCTAssertTrue(model.title.contains("5h剩 62.50%"), "the actual menu title must retain a two-decimal remaining percent")
        XCTAssertTrue(model.menuTooltip.contains("界面显示剩余 62.50%"), "the actual tooltip must retain a two-decimal remaining percent")

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
        let release = HubScanGate()
        defer { release.release() }
        scanner.started = { started.fulfill() }
        scanner.beforeReturn = { await release.wait() }
        model.refreshTokenHubQuota()
        await fulfillment(of: [started], timeout: 2)
        model.shutdown()
        release.release()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(model.tokenHubQuotaSnapshot, "shutdown rejects a late scanner completion")
    }

    func testSingleInflightRefreshNeverOverlaps() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (model, scanner, _) = configuredModel(result(now: now), clock: HubManualClock(now))
        defer { model.shutdown() }
        let started = expectation(description: "one scan started")
        let release = HubScanGate()
        defer { release.release() }
        scanner.started = { started.fulfill() }
        scanner.beforeReturn = { await release.wait() }
        model.refreshTokenHubQuota()
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.backgroundServiceResources.axScanInFlightCount, 1)
        XCTAssertEqual(model.backgroundServiceResources.axRefreshScheduledCount, 0)
        let heartbeat = expectation(description: "main actor remains responsive during an AX suspension")
        Task { @MainActor in heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 1)
        model.refreshTokenHubQuota()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(scanner.calls, 1, "a second refresh cannot overlap an in-flight scan")
        XCTAssertEqual(scanner.requests.first?.now, now)
        XCTAssertEqual(scanner.requests.first?.mode, .localCodex)
        XCTAssertEqual(scanner.requests.first?.permissionTrusted, true)
        XCTAssertEqual(scanner.requests.first?.refreshSeconds, 60)
        release.release()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(scanner.maximumConcurrent, 1)
        XCTAssertEqual(model.backgroundServiceResources.axScanInFlightCount, 0)
        XCTAssertEqual(model.backgroundServiceResources.axRefreshScheduledCount, 1,
                       "one completion schedules one completion-relative next refresh")
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
        let release = HubScanGate()
        defer { release.release() }
        scanner.started = { blocked.fulfill() }
        scanner.beforeReturn = { await release.wait() }
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
        release.release()
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
            defer { window.close() }
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hostingView
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.displayIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            window.displayIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: bounds) else {
                XCTFail("synthetic Hub dashboard bitmap should be available"); return
            }
            hostingView.cacheDisplay(in: bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
            let pixelScale = Int(window.backingScaleFactor.rounded())
            XCTAssertEqual(decoded.pixelsWide, 460 * pixelScale)
            XCTAssertEqual(decoded.pixelsHigh, 700 * pixelScale)
            XCTAssertGreaterThan(png.count, 0)
            try png.write(to: output.appendingPathComponent("synthetic-tokenhub-\(name).png"))
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
            defer { window.close() }
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hostingView
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.displayIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            window.displayIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: cardBounds) else {
                XCTFail("synthetic full-card bitmap should be available"); return
            }
            hostingView.cacheDisplay(in: cardBounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
            let pixelScale = Int(window.backingScaleFactor.rounded())
            XCTAssertEqual(decoded.pixelsWide, 460 * pixelScale)
            XCTAssertEqual(decoded.pixelsHigh, 280 * pixelScale)
            XCTAssertGreaterThan(png.count, 0)
            try png.write(to: output.appendingPathComponent("synthetic-tokenhub-full-card-\(name).png"))
        }
        print("Synthetic Token Hub dashboard renders: \(output.path)/synthetic-tokenhub-light.png and synthetic-tokenhub-dark.png")
        print("Synthetic full-card renders: \(output.path)/synthetic-tokenhub-full-card-light.png and synthetic-tokenhub-full-card-dark.png")
        XCTAssertTrue(model.menuTooltip.contains("界面显示剩余"))
        XCTAssertTrue(model.menuTooltip.contains("币种未核验"))
    }
}


extension TokenHubQuotaStateTests {
    func testDashboardDirectFailureIsVisibleWhenAXCompatibilityIsDisabled() async {
        let harness = HubDirectHarness()
        let permission = HubTestPermission(); permission.trusted = false
        let clock = HubManualClock(Date(timeIntervalSince1970: 1_800_000_000))
        let model = directModel(harness, clock: clock, permission: permission)
        defer { model.shutdown(); harness.finishPending() }
        model.setTokenHubAutomaticReadingEnabled(false)
        model.refreshTokenHubQuota()
        guard await waitForDirectRequests(1, harness: harness) else { return }
        harness.complete(1, failure: .transportFailed)
        await settle(model, status: .accessFailed)
        let card = DashboardView(model: model).tokenHubCard
        XCTAssertTrue(card.enabled, "optional AX compatibility cannot hide the automatic direct reader's status")
        XCTAssertEqual(card.emptyStateText, "Token Hub 网络请求失败")
        XCTAssertEqual(permission.requests, 0)
    }

    func testDashboardAXPreviewKeepsDisabledCompatibilityPresentation() {
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        model.setTokenHubAutomaticReadingEnabled(false)
        let card = DashboardView(model: model).tokenHubCard
        XCTAssertFalse(card.enabled, "AX-only preview has no injected or production direct source")
        XCTAssertEqual(card.emptyStateText, "自动读取已关闭")
    }

    func testMissingHubResetTextIsExplicitlyUnknown() {
        XCTAssertEqual(TokenHubQuotaCard.resetLabel(""), "重置时间未知")
        XCTAssertEqual(TokenHubQuotaCard.resetLabel("  "), "重置时间未知")
        XCTAssertEqual(TokenHubQuotaCard.resetLabel("未知"), "重置时间未知")
        XCTAssertEqual(TokenHubQuotaCard.resetLabel("01-15 08:00"), "重置 01-15 08:00")
    }
}


private actor ControlledLocalScan {
    private var pending: [(Int, CheckedContinuation<LocalCodexScanWorker.Result, Error>)] = []
    private(set) var requests = 0
    private(set) var maximumPending = 0
    func scan(generation: Int) async throws -> LocalCodexScanWorker.Result {
        requests += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending.append((generation, continuation)); maximumPending = max(maximumPending, pending.count)
        }
    }
    func completeFirst(total: Int) {
        guard !pending.isEmpty else { return }
        let (_, continuation) = pending.removeFirst()
        continuation.resume(returning: LocalCodexScanWorker.Result(
            snapshot: LocalCodexSnapshot(input: total, output: 0, total: total,
                sessionCount: 1, filesScanned: 1, isLimited: false, latestEventAt: nil,
                fiveHour: nil, sevenDay: nil, knownThreadCount: 1),
            diagnostics: LocalCodexUsageReader.Cache().diagnostics))
    }
    func finishPending() {
        while !pending.isEmpty { pending.removeFirst().1.resume(throwing: CancellationError()) }
    }
}

extension TokenHubQuotaStateTests {
    private func workerFixture() throws -> (URL, Date) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TokenStatMenu-C23B-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stamp = ISO8601DateFormatter().string(from: now)
        let id = "51515151-5151-4515-8515-515151515151"
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": id, "source": "cli", "model_provider": "synthetic"]],
            ["timestamp": stamp, "type": "event_msg", "payload": ["type": "token_count",
                "info": ["total_token_usage": ["input_tokens": 10, "output_tokens": 5, "total_tokens": 15]]]]
        ]
        var bytes = Data()
        for row in rows { bytes.append(try JSONSerialization.data(withJSONObject: row)); bytes.append(10) }
        try bytes.write(to: directory.appendingPathComponent("rollout-fixture-\(id).jsonl"))
        return (directory, now)
    }

    func testLocalWorkerReusesRealCacheAndResetsItForNewGeneration() async throws {
        let (directory, now) = try workerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = LocalCodexScanWorker()
        let cold = try await worker.scan(directory: directory, now: now, generation: 7, routeContext: nil)
        XCTAssertEqual(cold.snapshot.total, 15)
        XCTAssertEqual(cold.diagnostics.parsedFiles, 1)
        let warm = try await worker.scan(directory: directory, now: now, generation: 7, routeContext: nil)
        XCTAssertEqual(warm.snapshot, cold.snapshot)
        XCTAssertEqual(warm.diagnostics.cacheHits, 1)
        XCTAssertEqual(warm.diagnostics.bytesRead, 0)
        let restarted = try await worker.scan(directory: directory, now: now, generation: 8, routeContext: nil)
        XCTAssertEqual(restarted.snapshot.total, 15)
        XCTAssertEqual(restarted.diagnostics.parsedFiles, 1, "a new generation cannot inherit the old worker cache")
        XCTAssertEqual(restarted.diagnostics.cacheHits, 0)
    }

    func testLocalWorkerSerializesConcurrentRequestsAndKeepsRoutesIsolated() async throws {
        let (directory, now) = try workerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = LocalCodexScanWorker()
        let route = LocalCodexRouteContext.verified(provider: "synthetic", origin: "https://gateway.example")
        let results = try await withThrowingTaskGroup(of: LocalCodexScanWorker.Result.self) { group in
            for _ in 0..<24 {
                group.addTask { try await worker.scan(directory: directory, now: now, generation: 9, routeContext: route) }
            }
            var results: [LocalCodexScanWorker.Result] = []
            for try await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.count, 24)
        XCTAssertTrue(results.allSatisfy { $0.snapshot.total == 15 && $0.snapshot.knownThreadCount == 1 })
        XCTAssertEqual(results.filter { $0.diagnostics.parsedFiles == 1 }.count, 1)
        XCTAssertEqual(results.filter { $0.diagnostics.cacheHits == 1 && $0.diagnostics.bytesRead == 0 }.count, 23)
        let unknown = try await worker.scan(directory: directory, now: now, generation: 9, routeContext: .unverified)
        XCTAssertEqual(unknown.snapshot.total, 0)
        XCTAssertEqual(unknown.snapshot.knownThreadCount, 0)
        let restored = try await worker.scan(directory: directory, now: now, generation: 9, routeContext: route)
        XCTAssertEqual(restored.snapshot.total, 15)
        XCTAssertEqual(restored.diagnostics.parsedFiles, 1, "a route change cannot reuse a summary from another source")
    }

    private func localConsumer(_ harness: ControlledLocalScan) -> AppModel {
        let noHub = TokenHubDirectQuotaDependencies(discoverTarget: { throw TokenHubQuotaFailure.noTarget },
            identityIsCurrent: { _ in false }, fetch: { _, _ in throw TokenHubDirectQuotaFailure.transportFailed })
        let source = LocalCodexScanDependencies(resolveInputs: {
            (directory: URL(fileURLWithPath: "/synthetic-unused-local-scan"), routeContext: .unverified)
        }, scan: { _, _, generation, _ in try await harness.scan(generation: generation) })
        let model = AppModel(startup: AppModelStartupDependencies(loadPreferences: { nil },
            savePreferences: { _ in }, shouldStartBackgroundServices: { true }),
            directQuota: noHub, localScanning: source)
        let permission = HubTestPermission(); permission.trusted = false
        model.tokenHubPermissionProvider = permission
        return model
    }

    private func waitForLocalRequests(_ count: Int, harness: ControlledLocalScan) async {
        for _ in 0..<100 {
            if await harness.requests >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("controlled local request did not arrive")
    }

    func testLocalConsumerRejectsOldGenerationWithoutOverlappingOrLosingRefresh() async {
        let harness = ControlledLocalScan()
        let model = localConsumer(harness)
        defer { model.shutdown(); Task { await harness.finishPending() } }
        await waitForLocalRequests(1, harness: harness)
        model.reload()
        try? await Task.sleep(for: .milliseconds(20))
        let requestsWhileOldReadRuns = await harness.requests
        XCTAssertEqual(requestsWhileOldReadRuns, 1, "reload must not overlap the old local read")
        await harness.completeFirst(total: 111)
        await waitForLocalRequests(2, harness: harness)
        XCTAssertEqual(model.localSnapshot.total, 0, "the old generation must not publish after reload")
        await harness.completeFirst(total: 15)
        for _ in 0..<100 where model.localSnapshot.total != 15 { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.localSnapshot.total, 15)
        XCTAssertEqual(model.backgroundServiceResources.localScanQueuedCount, 1)
        try? await Task.sleep(for: .milliseconds(30))
        let requestsAfterCompletion = await harness.requests
        let maximumPending = await harness.maximumPending
        XCTAssertEqual(requestsAfterCompletion, 2, "completion must schedule at the five-second cadence, not immediate repetition")
        XCTAssertEqual(maximumPending, 1)
    }

    func testLocalConsumerShutdownRejectsLateResultAndOwnsNoMoreResources() async {
        let harness = ControlledLocalScan()
        let model = localConsumer(harness)
        defer { model.shutdown(); Task { await harness.finishPending() } }
        await waitForLocalRequests(1, harness: harness)
        model.shutdown()
        await harness.completeFirst(total: 111)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.localSnapshot.total, 0)
        let resources = model.backgroundServiceResources
        XCTAssertEqual(resources.timerCount, 0)
        XCTAssertEqual(resources.workspaceObserverCount, 0)
        XCTAssertEqual(resources.localScanQueuedCount, 0)
        XCTAssertEqual(resources.axRefreshScheduledCount, 0)
        XCTAssertEqual(resources.axScanInFlightCount, 0)
        let requestsAfterShutdown = await harness.requests
        XCTAssertEqual(requestsAfterShutdown, 1)
    }

    func testDirectAlertThresholdsUseFullPrecisionAndTwoDecimalDisplay() async {
        let identity = TokenHubIdentity(pid: 990, bundleID: TokenHubTarget.bundleID,
            executablePath: "/Applications/Synthetic Threshold Hub.app/Contents/MacOS/Hub")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        func color(for usedPercent: Decimal) async -> NSColor {
            let snapshot = TokenHubQuotaSnapshot(identity: identity,
                fiveHour: TokenHubWindowQuota(kind: .fiveHour, usedAmount: usedPercent,
                    limitAmount: 100, sourceSymbol: "$", usedPercent: usedPercent,
                    resetDisplay: "synthetic reset", resetAt: now.addingTimeInterval(3600)),
                sevenDay: nil, monthly: nil, observedAt: now)
            let direct = TokenHubDirectQuotaDependencies(discoverTarget: { identity },
                identityIsCurrent: { $0 == identity }, fetch: { _, _ in snapshot })
            let model = AppModel(preview: true, directQuota: direct)
            defer { model.shutdown() }
            model.config.dataSource = "localCodex"
            model.tokenHubAutomaticReadingEnabled = false
            model.tokenHubNow = { now }
            model.refreshTokenHubQuota()
            for _ in 0..<100 where !model.tokenHubQuotaIsDirect {
                try? await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(model.tokenHubQuotaIsDirect)
            return model.alertColor
        }

        let belowYellow = await color(for: Decimal(string: "79.995")!)
        let aboveYellow = await color(for: Decimal(string: "80.005")!)
        let belowRed = await color(for: Decimal(string: "94.995")!)
        let aboveRed = await color(for: Decimal(string: "95.005")!)
        XCTAssertEqual(belowYellow, .labelColor)
        XCTAssertEqual(aboveYellow, .systemYellow)
        XCTAssertEqual(belowRed, .systemYellow)
        XCTAssertEqual(aboveRed, .systemRed)
        XCTAssertEqual(TwoDecimalPercentFormatter.string(Decimal(string: "37.5")!), "37.50%")
    }

    func testDirectMonthlyLimitAndMissingWindowFactsRemainIndependent() async {
        let identity = TokenHubIdentity(pid: 991, bundleID: TokenHubTarget.bundleID,
            executablePath: "/Applications/Synthetic Monthly Hub.app/Contents/MacOS/Hub")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let monthly = TokenHubMonthlyUsage(usedAmount: Decimal(string: "37.5")!, sourceSymbol: "$",
            limitAmount: Decimal(string: "100")!)
        let snapshot = TokenHubQuotaSnapshot(identity: identity,
            fiveHour: nil,
            sevenDay: TokenHubWindowQuota(kind: .sevenDay, usedAmount: 40, limitAmount: 100,
                sourceSymbol: "$", usedPercent: 40, resetDisplay: "synthetic 7d reset",
                resetAt: now.addingTimeInterval(3600)),
            monthly: monthly, observedAt: now)
        let direct = TokenHubDirectQuotaDependencies(discoverTarget: { identity },
            identityIsCurrent: { $0 == identity }, fetch: { _, _ in snapshot })
        let model = AppModel(preview: true, directQuota: direct)
        defer { model.shutdown() }
        model.config.dataSource = "localCodex"
        model.tokenHubAutomaticReadingEnabled = false
        model.tokenHubNow = { now }
        model.refreshTokenHubQuota()
        for _ in 0..<100 where !model.tokenHubQuotaIsDirect {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let current = try! XCTUnwrap(model.tokenHubQuotaSnapshot)
        XCTAssertNil(current.fiveHour, "a missing five-hour window stays unknown")
        XCTAssertEqual(current.sevenDay?.remainingPercent, 60)
        XCTAssertEqual(current.monthly?.remainingAmount, Decimal(string: "62.5"))
        XCTAssertEqual(current.monthly?.usedPercent, Decimal(string: "37.5"))
        XCTAssertTrue(model.menuTooltip.contains("5 小时未知"))
        XCTAssertTrue(model.title.contains("7d剩 60.00%"))

        let card = TokenHubQuotaCard(snapshot: current, status: model.tokenHubQuotaStatusText,
            enabled: true, refreshSeconds: 60, directSource: true)
        let host = NSHostingView(rootView: card.frame(width: 420))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 260)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)

        let usedOnly = TokenHubMonthlyUsage(usedAmount: 12, sourceSymbol: "$", limitAmount: nil)
        XCTAssertNil(usedOnly.remainingAmount)
        XCTAssertNil(usedOnly.usedPercent)
    }

    func testFreshLocalActivityBuildsBoundedHistoryAndStopsWhenStale() {
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        model.config.dataSource = "localCodex"
        model.panelVisible = true
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var now = base
        model.tokenHubNow = { now }
        for index in 0..<1_300 {
            now = base.addingTimeInterval(Double(index) * 0.5)
            model.localSnapshot = LocalCodexSnapshot(input: 10, output: 20, total: 30,
                sessionCount: 1, filesScanned: 1, isLimited: false, latestEventAt: now,
                fiveHour: nil, sevenDay: nil, knownThreadCount: 1, unknownThreadCount: 0,
                liveTurn: LocalLiveTurnSummary(inputTPS: 4, outputTPS: 8, observedAt: now))
            model.tick()
        }
        XCTAssertEqual(model.history.count, 1_200)
        XCTAssertTrue(model.activityIsLive)
        let retained = model.history.count
        now = now.addingTimeInterval(16)
        model.localSnapshot = LocalCodexSnapshot(input: 10, output: 20, total: 30,
            sessionCount: 1, filesScanned: 1, isLimited: false, latestEventAt: now,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 1, unknownThreadCount: 0,
            liveTurn: LocalLiveTurnSummary(inputTPS: 4, outputTPS: 8, observedAt: now.addingTimeInterval(-16)))
        model.tick()
        XCTAssertFalse(model.activityIsLive)
        XCTAssertEqual(model.history.count, retained, "stale estimates do not append synthetic zero points")
    }

    func testHeaderActionsShareSymmetricNeutralGeometry() {
        XCTAssertEqual(HeaderActionMetrics.actionSize, 30)
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        let host = NSHostingView(rootView: DashboardView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 700)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
}
```

### Tests/TokenStatUITests/SeasunStartupContractTests.swift

```swift
import AppKit
import SwiftUI
import XCTest
import TokenStatCore
import Vision
@testable import TokenStatMenu

/// BP10b executable checks for the formal app boundary. These intentionally
/// target the planned initializer/configuration API; do not weaken the tests
/// to match the current legacy proxy activation path. Run only after G4 and
/// PE approval, and after the product implementation provides this interface.
@MainActor
final class SeasunStartupContractTests: XCTestCase {
    private struct IsolatedConfig {
        let directory: URL
        let file: URL
        let calls = StartupCallCounts()

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("TokenStatMenu-BP10-\(UUID().uuidString)", isDirectory: true)
            file = directory.appendingPathComponent("config.plist")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func write(_ value: Any) throws -> Data {
            let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
            try data.write(to: file, options: .atomic)
            return data
        }

        func tearDown() { try? FileManager.default.removeItem(at: directory) }
    }

    private final class StartupCallCounts {
        private let lock = NSLock()
        private var loads = 0
        private var saves = 0
        private var gates = 0
        func noteLoad() { lock.lock(); loads += 1; lock.unlock() }
        func noteSave() { lock.lock(); saves += 1; lock.unlock() }
        func noteGate() { lock.lock(); gates += 1; lock.unlock() }
        func snapshot() -> (loads: Int, saves: Int, gates: Int) {
            lock.lock(); defer { lock.unlock() }; return (loads, saves, gates)
        }
    }

    private func makeModel(_ isolated: IsolatedConfig) -> AppModel {
        AppModel(preview: false, startup: startup(for: isolated))
    }

    private func startup(for isolated: IsolatedConfig, shouldStartBackgroundServices: Bool = false)
        -> AppModelStartupDependencies {
        startup(for: isolated, shouldStartBackgroundServices: shouldStartBackgroundServices,
                loadOverride: nil, saveOverride: nil)
    }

    private func startup(for isolated: IsolatedConfig, shouldStartBackgroundServices: Bool,
                         loadOverride: (() throws -> Data?)?,
                         saveOverride: ((SeasunPreferences) throws -> Void)?) -> AppModelStartupDependencies {
        AppModelStartupDependencies(
            loadPreferences: {
                isolated.calls.noteLoad()
                if let loadOverride { return try loadOverride() }
                return try ConfigStore.loadPreferences(at: isolated.file)
            },
            savePreferences: { preferences in
                isolated.calls.noteSave()
                if let saveOverride { try saveOverride(preferences) }
                else { try ConfigStore.savePreferences(preferences, at: isolated.file) }
            },
            shouldStartBackgroundServices: {
                isolated.calls.noteGate()
                return shouldStartBackgroundServices
            })
    }

    private func assertQuietSafeStartup(_ model: AppModel, file: URL, source: StaticString = #filePath,
                                        line: UInt = #line) {
        XCTAssertTrue(model.isSeasunOnly, "legacy data source must not select an active integration", file: source, line: line)
        assertNoBackgroundResources(model, file: source, line: line)
        XCTAssertNil(model.tokenHubQuotaSnapshot, "startup cannot fabricate an observed quota", file: source, line: line)
        XCTAssertFalse(model.hasRequestData, "startup cannot imply observed usage", file: source, line: line)
        XCTAssertFalse(model.userFacingStatus.contains(file.path), "status must not reveal a config path", file: source, line: line)
        XCTAssertFalse(model.userFacingStatus.contains("https://legacy.invalid"), "status must not expose an old endpoint", file: source, line: line)
    }

    private func assertNoBackgroundResources(_ model: AppModel, file: StaticString = #filePath, line: UInt = #line) {
        let resources = model.backgroundServiceResources
        XCTAssertEqual(resources.timerCount, 0, "disabled startup must own no repeating timer", file: file, line: line)
        XCTAssertEqual(resources.workspaceObserverCount, 0, "disabled startup must install no workspace observers", file: file, line: line)
        XCTAssertEqual(resources.localScanQueuedCount, 0, "disabled startup must queue no local scan", file: file, line: line)
        XCTAssertEqual(resources.axRefreshScheduledCount, 0, "disabled startup must schedule no AX refresh", file: file, line: line)
        XCTAssertEqual(resources.axScanInFlightCount, 0, "disabled startup must start no AX scan", file: file, line: line)
    }

    func testInitAndReloadKeepLegacyFilesUntouchedAndSelectSeasunSafeDefault() throws {
        let cases: [(String, Data?)] = [
            ("absent", nil),
            ("legacy proxy with arbitrary endpoint", try PropertyListSerialization.data(fromPropertyList: [
                "dataSource": "proxy", "endpoint": "https://legacy.invalid/v1/chat/completions",
                "usageURL": "https://quota.invalid/api", "model": "old-model", "port": 18765,
                "monthlyLimit": 900_000, "inputPrice": 1.25
            ], format: .xml, options: 0)),
            ("invalid legacy endpoint", try PropertyListSerialization.data(fromPropertyList: [
                "dataSource": "proxy", "endpoint": "file:///private/legacy",
                "usageURL": "https://quota.invalid/api"
            ], format: .xml, options: 0)),
            ("malformed plist", Data("not a plist".utf8)),
            ("non-dictionary root", try PropertyListSerialization.data(fromPropertyList: ["legacy", "array"], format: .xml, options: 0))
        ]

        for (name, bytes) in cases {
            let isolated = try IsolatedConfig()
            defer { isolated.tearDown() }
            if let bytes { try bytes.write(to: isolated.file, options: .atomic) }
            let before = try? Data(contentsOf: isolated.file)

            let model = makeModel(isolated)
            defer { model.shutdown() }
            assertQuietSafeStartup(model, file: isolated.file)
            let afterInit = isolated.calls.snapshot()
            XCTAssertEqual(afterInit.loads, 1, "init reads only the isolated preference file: \(name)")
            XCTAssertEqual(afterInit.saves, 0, "init never writes preferences: \(name)")
            XCTAssertGreaterThan(afterInit.gates, 0, "init consults the unified background gate: \(name)")
            XCTAssertEqual(try? Data(contentsOf: isolated.file), before,
                           "init must not migrate, normalize, or rewrite case: \(name)")

            model.reload()
            assertQuietSafeStartup(model, file: isolated.file)
            let afterReload = isolated.calls.snapshot()
            XCTAssertEqual(afterReload.loads, 2, "reload reads once from the isolated preference path: \(name)")
            XCTAssertEqual(afterReload.saves, 0, "reload never writes preferences: \(name)")
            XCTAssertGreaterThan(afterReload.gates, afterInit.gates,
                                 "reload reuses the unified background gate: \(name)")
            XCTAssertEqual(try? Data(contentsOf: isolated.file), before,
                           "reload must not migrate, normalize, or rewrite case: \(name)")
        }
    }

    func testPreferenceDefaultsValidationAndCompatibilityKeyPrecedence() throws {
        let fixtures: [(String, [String: Any], Double, Bool)] = [
            ("no preferences", [:], 60, true),
            ("valid minimum and new true overrides old false", [
                "refreshSeconds": 15.0, "tokenHubCompatibilityReadEnabled": true,
                "tokenHubAutomaticReadingEnabled": false
            ], 15, true),
            ("valid maximum and new false overrides old true", [
                "refreshSeconds": 3600.0, "tokenHubCompatibilityReadEnabled": false,
                "tokenHubAutomaticReadingEnabled": true
            ], 3600, false),
            ("legacy key used only when new key is absent", [
                "tokenHubAutomaticReadingEnabled": false
            ], 60, false),
            ("invalid current key defaults true without legacy fallback", [
                "tokenHubCompatibilityReadEnabled": "invalid", "tokenHubAutomaticReadingEnabled": false
            ], 60, true),
            ("numeric current key defaults true without legacy fallback", [
                "tokenHubCompatibilityReadEnabled": NSNumber(value: 0), "tokenHubAutomaticReadingEnabled": false
            ], 60, true),
            ("out of range refresh defaults to 60", ["refreshSeconds": 3601.0], 60, true),
            ("below range refresh defaults to 60", ["refreshSeconds": 14.9], 60, true),
            ("wrong-type refresh defaults to 60", ["refreshSeconds": "15"], 60, true),
            ("boolean refresh defaults to 60", ["refreshSeconds": true], 60, true)
        ]

        for (name, plist, expectedRefresh, expectedCompatibility) in fixtures {
            let isolated = try IsolatedConfig()
            defer { isolated.tearDown() }
            let original = try isolated.write(plist)
            let model = makeModel(isolated)
            defer { model.shutdown() }
            XCTAssertEqual(model.preferences.refreshSeconds, expectedRefresh, name)
            XCTAssertEqual(model.preferences.tokenHubCompatibilityReadEnabled, expectedCompatibility, name)
            XCTAssertEqual(try? Data(contentsOf: isolated.file), original,
                           "preference decoding at startup is read-only: \(name)")
            XCTAssertFalse(model.permissionPromptRequested,
                           "default-enabled AX compatibility must not prompt automatically: \(name)")
            XCTAssertEqual(isolated.calls.snapshot().saves, 0, "decoding must never persist normalized values: \(name)")
            assertNoBackgroundResources(model)
        }
    }

    func testPreferenceSaveNormalizesNonFiniteAndOutOfRangeRefreshValues() throws {
        let isolated = try IsolatedConfig()
        defer { isolated.tearDown() }
        let model = makeModel(isolated)
        defer { model.shutdown() }
        for invalid in [Double.nan, Double.infinity, -Double.infinity, 14.9, 3601] {
            XCTAssertTrue(model.savePreferences(SeasunPreferences(refreshSeconds: invalid,
                tokenHubCompatibilityReadEnabled: true)))
            model.reload()
            XCTAssertEqual(model.preferences.refreshSeconds, 60,
                           "non-finite or out-of-range refresh interval must normalize to 60")
        }
    }

    func testPreviewReturnsBeforeCallingPreferenceLoader() throws {
        let isolated = try IsolatedConfig()
        defer { isolated.tearDown() }
        let startup = AppModelStartupDependencies(
            loadPreferences: {
                isolated.calls.noteLoad()
                throw NSError(domain: "BP10PreviewMustNotLoad", code: 1)
            },
            savePreferences: { _ in isolated.calls.noteSave() },
            shouldStartBackgroundServices: {
                isolated.calls.noteGate()
                return true
            })
        let model = AppModel(preview: true, startup: startup)
        defer { model.shutdown() }
        let calls = isolated.calls.snapshot()
        XCTAssertEqual(calls.loads, 0, "preview must return before calling the preference loader")
        XCTAssertEqual(calls.saves, 0)
        XCTAssertEqual(calls.gates, 0, "preview returns before consulting the service gate")
        assertNoBackgroundResources(model)
    }

    func testExplicitSaveWritesOnlyAllowlistedPreferencesAndReloadsThem() throws {
        let isolated = try IsolatedConfig()
        defer { isolated.tearDown() }
        _ = try isolated.write([
            "dataSource": "proxy", "endpoint": "https://legacy.invalid/v1/chat/completions",
            "usageURL": "https://quota.invalid/api", "apiKey": "never persist or read",
            "model": "old-model", "monthlyLimit": 900_000,
            "tokenHubAutomaticReadingEnabled": false
        ])
        let model = makeModel(isolated)
        defer { model.shutdown() }

        let gateCountBeforeSave = isolated.calls.snapshot().gates
        XCTAssertTrue(model.savePreferences(SeasunPreferences(refreshSeconds: 120,
            tokenHubCompatibilityReadEnabled: false)))
        assertNoBackgroundResources(model)
        let afterSave = isolated.calls.snapshot()
        XCTAssertEqual(afterSave.saves, 1)
        XCTAssertGreaterThan(afterSave.gates, gateCountBeforeSave,
                             "save must consult the same background gate as init/reload")
        let saved = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: isolated.file), format: nil) as? [String: Any])
        XCTAssertEqual(Set(saved.keys), Set(["refreshSeconds", "tokenHubCompatibilityReadEnabled"]))
        XCTAssertEqual(saved["refreshSeconds"] as? Double, 120)
        XCTAssertEqual(saved["tokenHubCompatibilityReadEnabled"] as? Bool, false)
        model.reload()
        XCTAssertTrue(model.isSeasunOnly, "reload of the reduced schema remains Seasun-only")
        assertNoBackgroundResources(model)
        XCTAssertGreaterThan(isolated.calls.snapshot().gates, afterSave.gates,
                             "reload must consult the unified background gate")
        XCTAssertEqual(model.preferences.refreshSeconds, 120)
        XCTAssertFalse(model.preferences.tokenHubCompatibilityReadEnabled)
        XCTAssertEqual(isolated.calls.snapshot().saves, 1, "reload must not save")
    }

    func testFailedExplicitSavePreservesMemoryAndDoesNotExposeFilesystemDetails() throws {
        let isolated = try IsolatedConfig()
        defer { isolated.tearDown() }
        _ = try isolated.write(["refreshSeconds": 90.0, "tokenHubCompatibilityReadEnabled": true])
        let model = makeModel(isolated)
        defer { model.shutdown() }
        let originalStatus = model.userFacingStatus
        let originalRefresh = model.preferences.refreshSeconds
        let originalCompatibility = model.preferences.tokenHubCompatibilityReadEnabled

        try FileManager.default.removeItem(at: isolated.file)
        try FileManager.default.createDirectory(at: isolated.file, withIntermediateDirectories: false)
        XCTAssertFalse(model.savePreferences(SeasunPreferences(refreshSeconds: 300,
            tokenHubCompatibilityReadEnabled: false)))
        XCTAssertEqual(model.preferences.refreshSeconds, originalRefresh)
        XCTAssertEqual(model.preferences.tokenHubCompatibilityReadEnabled, originalCompatibility)
        XCTAssertEqual(model.userFacingStatus, originalStatus,
                       "failed save leaves active runtime state unchanged")
        assertNoBackgroundResources(model)
        XCTAssertFalse(model.message.contains(isolated.directory.path), "raw path must not be exposed")
        XCTAssertFalse(model.message.localizedCaseInsensitiveContains("no such file"),
                       "raw filesystem errors must not be exposed")
    }

    func testReloadLoaderFailurePreservesPreferencesAndShowsSafeStatus() throws {
        let isolated = try IsolatedConfig()
        defer { isolated.tearDown() }
        let original = try isolated.write(["refreshSeconds": 90.0, "tokenHubCompatibilityReadEnabled": false])
        var attempts = 0
        let startup = startup(for: isolated, shouldStartBackgroundServices: false, loadOverride: {
            attempts += 1
            if attempts > 1 {
                throw NSError(domain: "BP10ReloadFixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "secret raw path \(isolated.file.path)"])
            }
            return try ConfigStore.loadPreferences(at: isolated.file)
        }, saveOverride: nil)
        let model = AppModel(preview: false, startup: startup)
        defer { model.shutdown() }
        let initialStatus = model.userFacingStatus
        XCTAssertEqual(model.preferences.refreshSeconds, 90)
        XCTAssertFalse(model.preferences.tokenHubCompatibilityReadEnabled)

        model.reload()
        XCTAssertEqual(model.preferences.refreshSeconds, 90)
        XCTAssertFalse(model.preferences.tokenHubCompatibilityReadEnabled)
        XCTAssertEqual(model.userFacingStatus, initialStatus,
                       "failed reload keeps the last accepted runtime settings")
        XCTAssertFalse(model.message.contains(isolated.file.path))
        XCTAssertFalse(model.message.contains("secret raw path"))
        XCTAssertEqual(isolated.calls.snapshot().loads, 2)
        XCTAssertEqual(isolated.calls.snapshot().saves, 0)
        XCTAssertEqual(try Data(contentsOf: isolated.file), original)
        assertNoBackgroundResources(model)
    }

    func testDeterministicPreferenceSaveFailurePreservesTheOldFileAndRuntimeState() throws {
        let isolated = try IsolatedConfig()
        defer { isolated.tearDown() }
        let original = try isolated.write(["refreshSeconds": 90.0, "tokenHubCompatibilityReadEnabled": true])
        let startup = startup(for: isolated, shouldStartBackgroundServices: false, loadOverride: nil,
                              saveOverride: { _ in
            throw NSError(domain: "BP10SaveFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "secret raw path \(isolated.file.path)"])
        })
        let model = AppModel(preview: false, startup: startup)
        defer { model.shutdown() }
        let status = model.userFacingStatus

        XCTAssertFalse(model.savePreferences(SeasunPreferences(refreshSeconds: 300,
            tokenHubCompatibilityReadEnabled: false)))
        XCTAssertEqual(model.preferences.refreshSeconds, 90)
        XCTAssertTrue(model.preferences.tokenHubCompatibilityReadEnabled)
        XCTAssertEqual(model.userFacingStatus, status)
        XCTAssertFalse(model.message.contains(isolated.file.path))
        XCTAssertFalse(model.message.contains("secret raw path"))
        XCTAssertEqual(try Data(contentsOf: isolated.file), original,
                       "a deterministic save closure failure cannot delete or alter the old fixture")
        XCTAssertEqual(isolated.calls.snapshot().saves, 1)
        assertNoBackgroundResources(model)
    }

    func testFormalStartupTooltipPreservesSyntheticLocalHistoryAlongsideUnknownSeasunSource() throws {
        let isolated = try IsolatedConfig()
        defer { isolated.tearDown() }
        let model = makeModel(isolated)
        defer { model.shutdown() }
        XCTAssertFalse(model.sourceStatus.isEmpty)
        XCTAssertEqual(model.sourceStatus, "unknown")

        let cases: [(String, LocalCodexSnapshot, [String])] = [
            ("complete", LocalCodexSnapshot(input: 120, output: 80, total: 200,
                sessionCount: 2, filesScanned: 3, isLimited: false,
                latestEventAt: Date(timeIntervalSince1970: 1_797_000_000), fiveHour: nil, sevenDay: nil,
                knownThreadCount: 2, unknownThreadCount: 0, unidentifiedFileCount: 0,
                subagentCount: 1, forkCount: 1,
                lastTurn: LocalTurnSummary(outputTokens: 75, durationSeconds: 5,
                    completedAt: Date(timeIntervalSince1970: 1_797_000_000))),
             ["输入 120", "输出 80", "总计 200 tokens", "本次扫描记录量 200 tokens",
              "已核验线程 2", "子代理 1", "分叉 1", "顶层对话 2", "上轮记录均速：15.0 tok/s",
              "5 小时额度：本地", "7 天额度：本地"]),
            ("partial", LocalCodexSnapshot(input: 30, output: 20, total: 50,
                sessionCount: 1, filesScanned: 4, isLimited: false,
                latestEventAt: nil, fiveHour: nil, sevenDay: nil,
                knownThreadCount: 1, unknownThreadCount: 2, unidentifiedFileCount: 1,
                subagentCount: 1, forkCount: 2),
             ["输入 30", "输出 20", "总计 50 tokens", "已核验记录小计 50 tokens",
              "已核验线程 1", "未核验线程 2", "未识别文件 1", "子代理 1", "分叉 2", "最多32个物理文件"]),
            ("unknown", LocalCodexSnapshot(input: 0, output: 0, total: 0,
                sessionCount: 0, filesScanned: 2, isLimited: false,
                latestEventAt: nil, fiveHour: nil, sevenDay: nil,
                knownThreadCount: 0, unknownThreadCount: 2, unidentifiedFileCount: 0,
                subagentCount: 0, forkCount: 0),
             ["输入 未知", "输出 未知", "总计 未知 tokens", "已核验记录小计 未知 tokens",
              "未核验线程 2", "上轮记录均速：未知"])
        ]

        for (name, snapshot, expectedLocalDetails) in cases {
            model.localSnapshot = snapshot
            let tooltip = model.menuTooltip
            for detail in expectedLocalDetails {
                XCTAssertTrue(tooltip.contains(detail), "\(name) formal tooltip preserves local history detail: \(detail)")
            }
            XCTAssertTrue(tooltip.contains("不是模型瞬时生成速度"), "\(name) tooltip keeps the non-instantaneous speed qualification")
            XCTAssertTrue(tooltip.contains("Seasun Token Hub"), "\(name) tooltip identifies the enterprise direct source")
            let directLine = tooltip.split(separator: "\n").first { $0.contains("企业后台直接来源") }
            XCTAssertNotNil(directLine, "\(name) tooltip labels the enterprise direct source explicitly")
            XCTAssertTrue(directLine?.contains("尚未连接") == true || directLine?.contains("尚未接通") == true,
                          "\(name) tooltip keeps the enterprise direct source disconnected")
            XCTAssertTrue(directLine?.contains("额度、重置时间、月度用量和实时速度均未知") == true,
                          "\(name) tooltip scopes unknown quota and usage fields to the disconnected direct source")
        }
    }

    func testSettingsVisibleContentShowsSeasunPreferencesWithoutGenericIntegration() throws {
        let isolated = try IsolatedConfig()
        defer { isolated.tearDown() }
        let model = makeModel(isolated)
        defer { model.shutdown() }
        let bounds = NSRect(x: 0, y: 0, width: 460, height: 700)
        let hostingView = NSHostingView(rootView: SettingsView(model: model).frame(width: 460, height: 700))
        hostingView.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: bounds))
        hostingView.cacheDisplay(in: bounds, to: bitmap)
        let visibleText = try recognizedText(in: bitmap).joined(separator: "\n")
        XCTAssertTrue(visibleText.contains("Seasun Token Hub") || visibleText.contains("Token Hub"),
                      "the rendered Settings surface names the intended source")
        XCTAssertTrue(visibleText.contains("刷新"), "the rendered surface exposes an optional refresh preference")
        XCTAssertTrue(visibleText.contains("兼容"), "the rendered surface exposes the optional compatibility preference")
        for forbidden in ["上游完整 Endpoint", "API Key", "模型覆盖", "自定义价格", "企业额度接口", "手动月度 Token 上限"] {
            XCTAssertFalse(visibleText.contains(forbidden),
                           "the rendered Settings surface must not expose \(forbidden)")
        }
        XCTAssertFalse(visibleText.localizedCaseInsensitiveContains("填入企业") || visibleText.contains("连接成功"),
                       "Settings must not imply that a generic endpoint or credential connects the Seasun source")
    }

    func testSettingsSourceStatusFollowsFreshDirectObservationAndFailure() async throws {
        let now = Date(timeIntervalSince1970: 1_797_000_000)
        let identity = TokenHubIdentity(pid: 944, bundleID: TokenHubTarget.bundleID,
            executablePath: "/Applications/Synthetic Settings Hub.app/Contents/MacOS/Hub")
        let snapshot = TokenHubQuotaSnapshot(identity: identity,
            fiveHour: TokenHubWindowQuota(kind: .fiveHour, usedAmount: 25, limitAmount: 100,
                sourceSymbol: "$", usedPercent: 25, resetDisplay: "合成重置时间"),
            sevenDay: nil, monthly: nil, observedAt: now)
        var failure: TokenHubDirectQuotaFailure?
        var clock = now
        let direct = TokenHubDirectQuotaDependencies(discoverTarget: { identity },
            identityIsCurrent: { $0 == identity }, fetch: { _, _ in
                if let failure { throw failure }
                return snapshot
            })
        let model = AppModel(preview: true, directQuota: direct)
        defer { model.shutdown() }
        model.config.dataSource = "localCodex"
        model.tokenHubAutomaticReadingEnabled = false
        model.tokenHubNow = { clock }
        let settings = SettingsView(model: model)

        XCTAssertTrue(settings.sourceStatusText.contains("尚未连接"),
                      "unobserved source cannot claim a connected enterprise backend")
        model.refreshTokenHubQuota()
        for _ in 0..<100 where !model.tokenHubQuotaIsDirect { await Task.yield() }
        XCTAssertTrue(model.tokenHubQuotaIsDirect, "synthetic direct observation must be accepted")
        XCTAssertTrue(settings.sourceStatusText.contains("已直接读取"),
                      "Settings must reflect the same direct observation as the dashboard")
        XCTAssertFalse(settings.sourceStatusText.contains("尚不可用"))
        XCTAssertFalse(model.tokenHubAutomaticReadingEnabled,
                       "optional AX compatibility is disabled throughout this direct-only check")

        clock = now.addingTimeInterval(121)
        XCTAssertTrue(settings.sourceStatusText.contains("过期"),
                      "Settings cannot describe an expired direct snapshot as connected")
        failure = .credentialExpired
        model.refreshTokenHubQuota()
        for _ in 0..<100 where model.tokenHubDirectFailure == nil { await Task.yield() }
        XCTAssertEqual(model.tokenHubDirectFailure, .credentialExpired)
        XCTAssertTrue(settings.sourceStatusText.contains("会话已过期"),
                      "Settings must preserve the actual sanitized direct failure")
        XCTAssertFalse(settings.sourceStatusText.contains("已直接读取"))
    }

    func testSettingsLightAndDarkRendersAreAvailableForIndependentVisualReview() throws {
        let isolated = try IsolatedConfig()
        defer { isolated.tearDown() }
        let model = makeModel(isolated)
        defer { model.shutdown() }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/bp10-settings-review", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bounds = NSRect(x: 0, y: 0, width: 460, height: 700)
        for (name, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light),
                                           ("dark", NSAppearance.Name.darkAqua, ColorScheme.dark)] {
            let background = scheme == .dark
                ? Color(red: 0.13, green: 0.14, blue: 0.17)
                : Color(red: 0.96, green: 0.97, blue: 0.99)
            let root = DashboardView(model: model, settings: true)
                .environment(\.colorScheme, scheme)
                .frame(width: 460, height: 700)
                .background(background)
            let hostingView = NSHostingView(rootView: root)
            hostingView.frame = bounds
            hostingView.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)
            hostingView.frame = bounds
            window.displayIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            window.displayIfNeeded()
            hostingView.needsDisplay = true
            hostingView.layoutSubtreeIfNeeded()
            guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: bounds) else {
                window.close(); XCTFail("Seasun Settings render should be available"); continue
            }
            hostingView.cacheDisplay(in: bounds, to: bitmap)
            let renderedText = try recognizedText(in: bitmap).joined(separator: "\n")
            XCTAssertTrue(renderedText.contains("Seasun Token Hub") || renderedText.contains("Token Hub"),
                          "\(name) review render contains the intended source text")
            XCTAssertTrue(renderedText.contains("刷新"), "\(name) review render contains the refresh preference")
            XCTAssertTrue(renderedText.contains("兼容"), "\(name) review render contains the compatibility preference")
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 0)
            try png.write(to: output.appendingPathComponent("seasun-settings-\(name).png"), options: .atomic)
            window.close()
        }
        print("BP10 Seasun Settings light/dark visual review files: \(output.path)")
    }

    private func recognizedText(in bitmap: NSBitmapImageRep) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage), options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}
```

### Tests/TokenStatUITests/DashboardHistoryTests.swift

```swift
import AppKit
import Combine
import CryptoKit
import SwiftUI
import XCTest
import TokenStatCore
@testable import TokenStatMenu

/// These checks host the actual overview used by DashboardView.body. The four
/// full-content images are synthetic private review artifacts, not snapshots
/// of a user's running app. Initial state rendering does not prove a native
/// disclosure click; that interaction remains outside this bounded check.
@MainActor
final class DashboardHistoryTests: XCTestCase {
    private final class Calls {
        var loads = 0, saves = 0, starts = 0, discoveries = 0, fetches = 0
        var localResolves = 0, localScans = 0, axScans = 0
        var values: [Int] { [loads, saves, starts, discoveries, fetches, localResolves, localScans, axScans] }
    }
    private final class Permission: TokenHubPermissionProviding {
        var requests = 0
        func isTrusted() -> Bool { false }
        func requestOnceAndOpenSystemSettings() { requests += 1 }
    }
    private struct Fixture {
        let model: AppModel
        let calls: Calls
        let permission: Permission
        let now: Date
    }
    private struct Render {
        let png: Data
        let points: NSSize
        let pixels: NSSize
    }
    private struct ModelState: Equatable {
        let direct: TokenHubQuotaSnapshot?
        let local: LocalCodexSnapshot
        let five: WindowQuota?
        let seven: WindowQuota?
        let status: TokenHubQuotaStatus
        let directSource: Bool
        let failure: TokenHubDirectQuotaFailure?
        let sourceReadiness: String
        let title: String
        let tooltip: String
        let preferences: SeasunPreferences
        let resources: BackgroundServiceResources
    }

    private func state(_ model: AppModel) -> ModelState {
        ModelState(direct: model.tokenHubQuotaSnapshot, local: model.localSnapshot,
            five: model.fiveHourQuota, seven: model.sevenDayQuota,
            status: model.tokenHubQuotaStatus, directSource: model.tokenHubQuotaIsDirect,
            failure: model.tokenHubDirectFailure, sourceReadiness: model.sourceReadinessText,
            title: model.title, tooltip: model.menuTooltip, preferences: model.preferences,
            resources: model.backgroundServiceResources)
    }

    private func fixture(failing: Bool = false) async throws -> Fixture {
        let calls = Calls(), permission = Permission()
        // Wall time is used only to keep the synthetic direct snapshot fresh in
        // the real view, which uses Date(). All amounts/identities are invented.
        let now = Date().addingTimeInterval(-5)
        let identity = TokenHubIdentity(pid: 928, bundleID: TokenHubTarget.bundleID,
            executablePath: "/Applications/Synthetic C28 Hub.app/Contents/MacOS/Hub")
        let snapshot = TokenHubQuotaSnapshot(identity: identity,
            fiveHour: TokenHubWindowQuota(kind: .fiveHour, usedAmount: Decimal(string: "3.75")!,
                limitAmount: 10, sourceSymbol: "$", usedPercent: Decimal(string: "37.5")!,
                resetDisplay: "synthetic five-hour reset"),
            sevenDay: TokenHubWindowQuota(kind: .sevenDay, usedAmount: 4,
                limitAmount: 10, sourceSymbol: "$", usedPercent: 40,
                resetDisplay: "synthetic seven-day reset"),
            monthly: TokenHubMonthlyUsage(usedAmount: Decimal(string: "12.5")!, sourceSymbol: "$"),
            observedAt: now)
        let startup = AppModelStartupDependencies(loadPreferences: {
            calls.loads += 1; XCTFail("C28 rendering must not read real preferences"); return nil
        }, savePreferences: { _ in
            calls.saves += 1; XCTFail("C28 rendering must not save preferences")
        }, shouldStartBackgroundServices: {
            calls.starts += 1; XCTFail("C28 rendering must not start services"); return false
        })
        let direct = TokenHubDirectQuotaDependencies(discoverTarget: {
            calls.discoveries += 1; return identity
        }, identityIsCurrent: { $0 == identity }, fetch: { _, _ in
            calls.fetches += 1
            if failing { throw TokenHubDirectQuotaFailure.transportFailed }
            return snapshot
        })
        let local = LocalCodexScanDependencies(resolveInputs: {
            calls.localResolves += 1; XCTFail("C28 rendering must not discover local sessions")
            return (URL(fileURLWithPath: "/tmp/TokenStatMenu-C28-no-read"), .unverified)
        }, scan: { _, _, _, _ in
            await MainActor.run { calls.localScans += 1; XCTFail("C28 rendering must not scan local sessions") }
            throw TokenHubDirectQuotaFailure.transportFailed
        })
        let ax = TokenHubAXSource.synthetic { _ in
            calls.axScans += 1; XCTFail("C28 rendering must not read another app")
            return TokenHubQuotaResult(status: .accessFailed, snapshot: nil, failure: nil)
        }
        let model = AppModel(preview: true, startup: startup, directQuota: direct,
                             localScanning: local, tokenHubAXSource: ax)
        model.config.dataSource = "localCodex"
        model.tokenHubNow = { now }
        model.tokenHubPermissionProvider = permission
        model.tokenHubAutomaticReadingEnabled = false
        model.refreshTokenHubQuota()
        for _ in 0..<100 {
            if failing ? model.tokenHubDirectFailure == .transportFailed : model.tokenHubQuotaIsDirect {
                return Fixture(model: model, calls: calls, permission: permission, now: now)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.shutdown()
        XCTFail("C28 injected direct result was not applied")
        throw TokenHubDirectQuotaFailure.transportFailed
    }

    private func localQuotas(primary: Bool, secondary: Bool, now: Date,
                             future: Bool = false, missingReset: Bool = false) throws -> QuotaReport {
        var limits: [String: Any] = [:]
        if primary {
            var value: [String: Any] = ["usedPercent": 90, "windowDurationMins": 300]
            if !missingReset { value["resetsAt"] = Int(now.addingTimeInterval(-3600).timeIntervalSince1970) }
            limits["primary"] = value
        }
        if secondary {
            var value: [String: Any] = ["usedPercent": 5, "windowDurationMins": 10_080]
            if !missingReset { value["resetsAt"] = Int(now.addingTimeInterval(-1800).timeIntervalSince1970) }
            limits["secondary"] = value
        }
        // Empty local objects are assigned directly as nil windows by the caller;
        // QuotaReport intentionally rejects a response containing no facts.
        let bytes = try JSONSerialization.data(withJSONObject: ["result": ["rateLimits": limits]])
        return try QuotaReport.parse(bytes, config: AppConfiguration(),
            now: future ? now.addingTimeInterval(3600) : now.addingTimeInterval(-7200))
    }

    private func assignLocal(_ report: QuotaReport?, to model: AppModel, now: Date) {
        model.fiveHourQuota = report?.fiveHour; model.sevenDayQuota = report?.sevenDay
        model.localSnapshot = LocalCodexSnapshot(input: 120, output: 80, total: 200,
            sessionCount: 2, filesScanned: 3, isLimited: false,
            latestEventAt: now.addingTimeInterval(-7200),
            fiveHour: report?.fiveHour, sevenDay: report?.sevenDay,
            knownThreadCount: 3, unknownThreadCount: 1, unidentifiedFileCount: 0,
            subagentCount: 1, forkCount: 0,
            lastTurn: LocalTurnSummary(outputTokens: 20, durationSeconds: 4,
                completedAt: now.addingTimeInterval(-7200)))
    }

    private func render<V: View>(_ content: V, dark: Bool) throws -> Render {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let root = content.environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: 460).fixedSize(horizontal: false, vertical: true)
            .background(dark ? Color(red: 0.13, green: 0.14, blue: 0.17)
                             : Color(red: 0.96, green: 0.97, blue: 0.99))
        let host = NSHostingView(rootView: root)
        host.appearance = appearance
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 1600)
        host.layoutSubtreeIfNeeded()
        let fitted = host.fittingSize
        XCTAssertEqual(fitted.width, 460, accuracy: 0.5)
        XCTAssertGreaterThan(fitted.height, 200, "render must include actual overview content, not a toolbar crop")
        XCTAssertLessThan(fitted.height, 4000)
        let bounds = NSRect(x: 0, y: 0, width: 460, height: ceil(fitted.height))
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        host.frame = bounds; window.contentView = host; window.appearance = appearance
        window.displayIfNeeded(); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: bounds))
        host.cacheDisplay(in: bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertGreaterThan(png.count, 4000, "a nonempty blank-sized stub is insufficient")
        XCTAssertEqual(decoded.pixelsWide, Int(bounds.width * window.backingScaleFactor))
        XCTAssertEqual(decoded.pixelsHigh, Int(bounds.height * window.backingScaleFactor))
        return Render(png: png, points: bounds.size,
            pixels: NSSize(width: decoded.pixelsWide, height: decoded.pixelsHigh))
    }

    func testC28ActualOverviewCollapsedAndExpandedFullContentRenders() async throws {
        let f = try await fixture(); defer { f.model.shutdown() }
        assignLocal(try localQuotas(primary: false, secondary: true, now: f.now), to: f.model, now: f.now)
        let original = state(f.model), calls = f.calls.values, alert = f.model.alertColor
        let direct = try XCTUnwrap(f.model.tokenHubQuotaSnapshot)
        XCTAssertEqual(direct.fiveHour?.remainingPercent, Decimal(string: "62.5"))
        XCTAssertEqual(direct.sevenDay?.remainingPercent, 60)
        XCTAssertNil(f.model.fiveHourQuota)
        XCTAssertEqual(f.model.sevenDayQuota?.usedPercent, 5)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStatMenu-C28-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        var manifest: [[String: Any]] = []
        for (name, dark) in [("light", false), ("dark", true)] {
            let implicit = try render(DashboardView(model: f.model).overviewContent, dark: dark)
            let collapsed = try render(DashboardView(model: f.model, localHistoryExpanded: false).overviewContent, dark: dark)
            let expanded = try render(DashboardView(model: f.model, localHistoryExpanded: true).overviewContent, dark: dark)
            XCTAssertEqual(implicit.png, collapsed.png, "default history presentation must be collapsed")
            XCTAssertGreaterThan(expanded.points.height, collapsed.points.height + 30,
                                 "expanded history must contain actual secondary content")
            XCTAssertNotEqual(expanded.png, collapsed.png)
            for (stateName, image) in [("collapsed", collapsed), ("expanded", expanded)] {
                let basename = "synthetic-c28-\(name)-\(stateName).png"
                try image.png.write(to: output.appendingPathComponent(basename))
                manifest.append(["name": basename, "sha256": SHA256.hash(data: image.png).map { String(format: "%02x", $0) }.joined(),
                    "widthPoints": image.points.width, "heightPoints": image.points.height,
                    "widthPixels": image.pixels.width, "heightPixels": image.pixels.height])
            }
        }
        try JSONSerialization.data(withJSONObject: ["syntheticOnly": true, "nativeInteractionVerified": false,
            "images": manifest], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("render-manifest.json"))
        print("C28 synthetic full-content review images: \(output.path)")
        XCTAssertEqual(state(f.model), original)
        XCTAssertEqual(f.calls.values, calls)
        XCTAssertEqual(f.model.alertColor, alert)
        XCTAssertEqual(f.permission.requests, 0)
        XCTAssertEqual(calls, [0, 0, 0, 1, 1, 0, 0, 0])
        XCTAssertEqual(f.model.localSnapshot.total, 200)
        XCTAssertEqual(f.model.localSnapshot.unknownThreadCount, 1)
    }

    func testC28DirectFailureCannotBecomeCurrentFromExpandedLocalHistory() async throws {
        let f = try await fixture(failing: true); defer { f.model.shutdown() }
        assignLocal(try localQuotas(primary: true, secondary: true, now: f.now), to: f.model, now: f.now)
        let original = state(f.model), calls = f.calls.values, alert = f.model.alertColor
        XCTAssertNil(f.model.tokenHubQuotaSnapshot)
        XCTAssertFalse(f.model.tokenHubQuotaIsDirect)
        XCTAssertEqual(DashboardView(model: f.model).tokenHubCard.emptyStateText, "Token Hub 网络请求失败")
        for expanded in [false, true] {
            _ = try render(DashboardView(model: f.model, localHistoryExpanded: expanded).overviewContent, dark: false)
        }
        XCTAssertEqual(state(f.model), original)
        XCTAssertEqual(f.calls.values, calls)
        XCTAssertEqual(f.model.alertColor, alert)
        XCTAssertEqual(f.permission.requests, 0)
    }

    func testC28LocalWindowCombinationsPreserveMissingAndHistoricalFacts() async throws {
        let f = try await fixture(); defer { f.model.shutdown() }
        for (five, seven, future, noReset) in [(false, false, false, false), (true, false, false, false),
            (false, true, false, false), (true, true, false, false), (true, true, true, false),
            (true, true, false, true)] {
            let report = five || seven ? try localQuotas(primary: five, secondary: seven,
                now: f.now, future: future, missingReset: noReset) : nil
            assignLocal(report, to: f.model, now: f.now)
            let original = state(f.model), calls = f.calls.values
            _ = try render(DashboardView(model: f.model, localHistoryExpanded: true).overviewContent, dark: false)
            XCTAssertEqual(state(f.model), original)
            XCTAssertEqual(f.calls.values, calls)
            XCTAssertEqual(f.model.fiveHourQuota != nil, five)
            XCTAssertEqual(f.model.sevenDayQuota != nil, seven)
            for value in [f.model.fiveHourQuota, f.model.sevenDayQuota].compactMap({ $0 }) {
                let presentation = WindowQuotaCard.presentation(for: value, at: f.now, refreshSeconds: 60, source: .localCodex)
                XCTAssertFalse(presentation.isFresh)
                XCTAssertEqual(presentation.usedPercent, value.usedPercent)
                XCTAssertEqual(presentation.recordedAt, value.fetchedAt)
                XCTAssertEqual(presentation.resetsAt, value.resetsAt)
                XCTAssertTrue(presentation.sourceLabel.contains("账号/组织未核验"))
                XCTAssertTrue(presentation.statusLabel.contains("历史"))
                if future { XCTAssertTrue(presentation.statusLabel.contains("异常时间戳")) }
                if noReset { XCTAssertTrue(presentation.statusLabel.contains("重置时间未知")) }
            }
        }
        XCTAssertEqual(f.permission.requests, 0)
    }

    func testC29AccountingLabelsRenderForLimitedAndCompleteSyntheticSnapshots() async throws {
        let f = try await fixture(); defer { f.model.shutdown() }

        f.model.localSnapshot = LocalCodexSnapshot(input: 120, output: 80, total: 200,
            sessionCount: 2, filesScanned: 32, isLimited: true, latestEventAt: nil,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 3,
            unknownThreadCount: 2)
        XCTAssertTrue(f.model.title.contains("小计"))
        XCTAssertTrue(f.model.title.contains("未核验"))
        XCTAssertTrue(f.model.menuTooltip.contains("实时估算：未知"))
        XCTAssertTrue(f.model.menuTooltip.contains("当前配置关联的本机 Codex 记录"))
        XCTAssertTrue(f.model.menuTooltip.contains("已核验记录小计"))
        XCTAssertTrue(f.model.menuTooltip.contains("本次达到扫描上限"))
        XCTAssertTrue(f.model.menuTooltip.contains("未核验线程 2"))
        for dark in [false, true] {
            let image = try render(DashboardView(model: f.model).overviewContent, dark: dark)
            XCTAssertGreaterThan(image.png.count, 4000)
        }

        f.model.localSnapshot = LocalCodexSnapshot(input: 120, output: 80, total: 200,
            sessionCount: 2, filesScanned: 3, isLimited: false, latestEventAt: nil,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 3,
            unknownThreadCount: 0)
        XCTAssertTrue(f.model.title.contains("Σ"))
        XCTAssertTrue(f.model.title.contains("顶层对话"))
        XCTAssertTrue(f.model.menuTooltip.contains("本次扫描记录量"))
        XCTAssertTrue(f.model.menuTooltip.contains("本次安全检查 3 个物理文件"))
        XCTAssertTrue(f.model.menuTooltip.contains("未核验线程 0"))
        for dark in [false, true] {
            let image = try render(DashboardView(model: f.model).overviewContent, dark: dark)
            XCTAssertGreaterThan(image.png.count, 4000)
        }
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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Native SwiftPM also works with Command Line Tools; no global xcode-select changes.
if [ "$MODE" = "--universal" ]; then
    for ARCH in arm64 x86_64; do
        swift build --force-resolved-versions --arch "$ARCH" --scratch-path ".build/$ARCH" -c release --product TokenStatMenu
    done
    ARM_DIR="$(swift build --force-resolved-versions --arch arm64 --scratch-path .build/arm64 -c release --show-bin-path)"
    INTEL_DIR="$(swift build --force-resolved-versions --arch x86_64 --scratch-path .build/x86_64 -c release --show-bin-path)"
    lipo -create "$ARM_DIR/TokenStatMenu" "$INTEL_DIR/TokenStatMenu" -output "$APP/Contents/MacOS/TokenStatMenu"
else
    CONFIG=debug
    if [ "$MODE" = "--release" ]; then CONFIG=release; fi
    swift build --force-resolved-versions -c "$CONFIG" --product TokenStatMenu
    BIN_DIR="$(swift build --force-resolved-versions -c "$CONFIG" --show-bin-path)"
    cp "$BIN_DIR/TokenStatMenu" "$APP/Contents/MacOS/TokenStatMenu"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Only public source identity enters the bundle: never include a machine path,
# hostname, account, configuration, or session. Exported source has no Git ID.
SOURCE_REVISION="source-export"
SOURCE_STATE="unspecified"
SOURCE_GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
# A source export unpacked below another repository must never inherit that
# unrelated repository's revision or working-tree state.
if [ -n "$SOURCE_GIT_ROOT" ] && [ "$(cd "$SOURCE_GIT_ROOT" && pwd -P)" = "$(pwd -P)" ]; then
    SOURCE_CANDIDATE_REVISION="$(git rev-parse --verify HEAD 2>/dev/null || true)"
    if [ -n "$SOURCE_CANDIDATE_REVISION" ]; then
        SOURCE_REVISION="$SOURCE_CANDIDATE_REVISION"
        SOURCE_STATE="clean"
        if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then SOURCE_STATE="modified"; fi
    fi
fi
/usr/libexec/PlistBuddy -c "Add :TokenStatSourceRevision string $SOURCE_REVISION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :TokenStatSourceState string $SOURCE_STATE" "$APP/Contents/Info.plist"
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
swift run --force-resolved-versions TokenStatCoreChecks
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
"""Isolated BP10b startup integration for the formal Seasun-only app.

This test deliberately does not start a proxy/mock server, send inference
requests, inspect credentials, or read diagnostic values. It launches only its
own app child process against temporary plist fixtures and terminates that
exact child PID. Source call-graph review remains necessary: the optional
URLProtocol tripwire in XCTest cannot establish comprehensive network silence.
"""
from __future__ import annotations

import json
import os
import pathlib
import plistlib
import signal
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP = ROOT / "dist/TokenStatMenu.app"
EXECUTABLE = APP / "Contents/MacOS/TokenStatMenu"
ALLOWED_REPORT_KEYS = {
    "seasunOnlyMode",
    "backgroundServicesStarted",
    "statusItemVisible",
    "permissionPromptRequested",
    "quotaPresent",
    "directQuotaPresent",
    "directQuotaStatus",
    "fiveHourPresent",
    "sevenDayPresent",
    "fiveHourResetPresent",
    "sevenDayResetPresent",
    "resetTimePresent",
    "monthlyUsagePresent",
    "liveTokenSpeedPresent",
    "sourceStatus",
    "backgroundServiceResources",
}
EXPECTED_QUIET_RESOURCE_COUNTS = {
    "timerCount": 0,
    "workspaceObserverCount": 0,
    "localScanQueuedCount": 0,
    "axRefreshScheduledCount": 0,
    "axScanInFlightCount": 0,
}


def wait_for_report(path: pathlib.Path, process: subprocess.Popen[bytes], timeout: float = 15.0) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError("isolated app process exited before writing readiness booleans")
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(value, dict):
                return value
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            pass
        time.sleep(0.1)
    raise AssertionError("timed out waiting for isolated startup readiness booleans")


def stop_own_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        # Kill only the Popen child created by this test. Never use pkill or
        # match process names, which could terminate a user's running app.
        process.kill()
        process.wait(timeout=5)


def verify_report(report: dict) -> None:
    assert set(report) == ALLOWED_REPORT_KEYS, "diagnostics must contain only the approved readiness schema"
    assert report["seasunOnlyMode"] is True
    assert report["backgroundServicesStarted"] is False
    assert report["permissionPromptRequested"] is False
    assert report["quotaPresent"] is False
    assert report["directQuotaPresent"] is False
    assert isinstance(report["directQuotaStatus"], str) and report["directQuotaStatus"]
    assert report["fiveHourPresent"] is False
    assert report["sevenDayPresent"] is False
    assert report["fiveHourResetPresent"] is False
    assert report["sevenDayResetPresent"] is False
    assert report["resetTimePresent"] is False
    assert report["monthlyUsagePresent"] is False
    assert report["liveTokenSpeedPresent"] is False
    assert report["statusItemVisible"] is True
    assert report["sourceStatus"] in {"notConnected", "unavailable", "unknown"}
    assert report["backgroundServiceResources"] == EXPECTED_QUIET_RESOURCE_COUNTS


def fixture_cases() -> list[tuple[str, bytes | None]]:
    return [
        ("no-config", None),
        ("legacy-proxy-arbitrary-endpoint", plistlib.dumps({
            "dataSource": "proxy",
            "endpoint": "https://legacy.invalid/v1/chat/completions",
            "usageURL": "https://quota.invalid/api",
            "model": "legacy-model",
            "port": 18765,
            "monthlyLimit": 900000,
            "tokenHubAutomaticReadingEnabled": False,
        })),
        ("invalid-legacy-endpoint", plistlib.dumps({
            "dataSource": "proxy",
            "endpoint": "file:///private/legacy",
            "usageURL": "https://quota.invalid/api",
        })),
        ("malformed-plist", b"not a property list"),
        ("non-dictionary-root", plistlib.dumps(["legacy", "array"])),
    ]


def verify_build_only_never_invokes_global_kill(root: pathlib.Path) -> None:
    """Run a copy of the build-only control flow with kill/build tools stubbed.

    The pkill stub records a call and never signals any process. Thus this
    check can detect a regression without risking a user-owned app process.
    """
    checkout = root / "build-script-fixture"
    (checkout / "script").mkdir(parents=True)
    (checkout / "Resources").mkdir()
    (checkout / "Resources/Info.plist").write_bytes((ROOT / "Resources/Info.plist").read_bytes())
    (checkout / "Resources/AppIcon.icns").write_bytes((ROOT / "Resources/AppIcon.icns").read_bytes())
    (checkout / "script/build_and_run.sh").write_bytes((ROOT / "script/build_and_run.sh").read_bytes())
    tools = checkout / "tools"
    tools.mkdir()
    pkill_log = checkout / "pkill-called"
    open_log = checkout / "open-called"
    swift_log = checkout / "swift-arguments"
    fake_bin = checkout / "fake-bin"
    fake_bin.mkdir()
    (fake_bin / "TokenStatMenu").write_bytes(b"synthetic-executable-fixture")

    stubs = {
        "open": "#!/bin/sh\nprintf called >> \"$V23_OPEN_LOG\"\nexit 74\n",
        "pkill": "#!/bin/sh\nprintf called >> \"$BP10_PKILL_LOG\"\nexit 0\n",
        "swift": "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$V23_SWIFT_ARGUMENT_LOG\"\nfor arg in \"$@\"; do if [ \"$arg\" = --build-system ]; then exit 73; fi; done\nfor arg in \"$@\"; do if [ \"$arg\" = --show-bin-path ]; then printf '%s\\n' \"$BP10_FAKE_BIN\"; exit 0; fi; done\nexit 0\n",
        "chmod": "#!/bin/sh\nexit 0\n",
        "codesign": "#!/bin/sh\nexit 0\n",
    }
    for name, content in stubs.items():
        path = tools / name
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    environment = os.environ.copy()
    environment["PATH"] = str(tools) + os.pathsep + environment.get("PATH", "")
    environment["BP10_PKILL_LOG"] = str(pkill_log)
    environment["BP10_FAKE_BIN"] = str(fake_bin)
    environment["V23_OPEN_LOG"] = str(open_log)
    environment["V23_SWIFT_ARGUMENT_LOG"] = str(swift_log)
    completed = subprocess.run(
        ["/bin/bash", str(checkout / "script/build_and_run.sh"), "--build-only"],
        cwd=checkout,
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=20,
        check=False,
    )
    assert completed.returncode == 0, "isolated --build-only must use default SwiftPM and complete with stubbed build tools"
    assert not open_log.exists(), "--build-only must not invoke LaunchServices"
    assert "--build-system" not in swift_log.read_text().splitlines(), "build script must use the default SwiftPM build system"
    assert not pkill_log.exists(), "--build-only must not invoke a global process-name kill"
    packaged_info = plistlib.loads((checkout / "dist/TokenStatMenu.app/Contents/Info.plist").read_bytes())
    source_info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
    assert packaged_info["CFBundleShortVersionString"] == source_info["CFBundleShortVersionString"]
    assert packaged_info["CFBundleVersion"] == source_info["CFBundleVersion"]
    assert packaged_info["CFBundleIconFile"] == "AppIcon"
    assert (checkout / "dist/TokenStatMenu.app/Contents/Resources/AppIcon.icns").read_bytes() == (ROOT / "Resources/AppIcon.icns").read_bytes()
    assert packaged_info["TokenStatSourceRevision"] == "source-export", "source-only export must not acquire a machine identity"
    assert packaged_info["TokenStatSourceState"] == "unspecified"
    assert (checkout / "dist/TokenStatMenu.app/Contents/MacOS/TokenStatMenu").read_bytes() == b"synthetic-executable-fixture"
    # An exported source folder may be unpacked below an unrelated Git repo.
    # It must keep source-export rather than embed that parent repository's HEAD.
    parent_repository = root / "synthetic-parent-repository"
    parent_repository.mkdir()
    subprocess.run(["git", "init", "--quiet", str(parent_repository)], check=True,
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["git", "-C", str(parent_repository), "-c", "user.name=Synthetic Fixture",
                    "-c", "user.email=fixture@example.test", "-c", "commit.gpgsign=false",
                    "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "--allow-empty", "-m", "Synthetic parent fixture"],
                   check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    nested_checkout = parent_repository / "exported-source"
    checkout.rename(nested_checkout)
    nested_environment = environment.copy()
    nested_environment["PATH"] = str(nested_checkout / "tools") + os.pathsep + os.environ.get("PATH", "")
    nested_environment["BP10_PKILL_LOG"] = str(nested_checkout / "pkill-called")
    nested_environment["BP10_FAKE_BIN"] = str(nested_checkout / "fake-bin")
    nested_environment["V23_OPEN_LOG"] = str(nested_checkout / "open-called")
    nested_environment["V23_SWIFT_ARGUMENT_LOG"] = str(nested_checkout / "swift-arguments")
    nested = subprocess.run(["/bin/bash", str(nested_checkout / "script/build_and_run.sh"), "--build-only"],
                            cwd=nested_checkout, env=nested_environment, stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20, check=False)
    assert nested.returncode == 0, "nested exported source must build under an unrelated Git parent"
    nested_info = plistlib.loads((nested_checkout / "dist/TokenStatMenu.app/Contents/Info.plist").read_bytes())
    assert nested_info["TokenStatSourceRevision"] == "source-export", "export must not inherit an unrelated parent Git HEAD"
    assert nested_info["TokenStatSourceState"] == "unspecified"
    assert not (nested_checkout / "pkill-called").exists()
    assert not (nested_checkout / "open-called").exists()
    for script_name in ["script/build_and_run.sh", "script/test.sh", ".github/workflows/ci.yml"]:
        assert "--build-system native" not in (ROOT / script_name).read_text(), "published build/test/CI commands must not force deprecated native mode"
    print("PASS: --build-only invokes no global process kill; version and project-only source identity preserved (isolated fixtures)", flush=True)


def run_case(name: str, source: bytes | None, root: pathlib.Path) -> None:
    case = root / name
    case.mkdir()
    config = case / "config.plist"
    if source is not None:
        config.write_bytes(source)
    before = config.read_bytes() if config.exists() else None
    report_path = case / "readiness.json"

    process = subprocess.Popen(
        [str(EXECUTABLE), "--config", str(config), "--disable-background-services",
         "--diagnostics-output", str(report_path)],
        cwd=case,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        report = wait_for_report(report_path, process)
        verify_report(report)
        after = config.read_bytes() if config.exists() else None
        assert after == before, "startup must not rewrite, migrate, or normalize the old configuration"
    finally:
        stop_own_process(process)
    print(f"PASS: {name} (safe startup booleans; config unchanged)", flush=True)


def main() -> int:
    if not EXECUTABLE.is_file():
        raise FileNotFoundError(f"BP10b app executable is missing: {EXECUTABLE}")
    if not os.access(EXECUTABLE, os.X_OK):
        raise PermissionError("BP10b app executable is not executable")
    with tempfile.TemporaryDirectory(prefix="tokenstat-bp10-startup-") as temporary:
        root = pathlib.Path(temporary)
        verify_build_only_never_invokes_global_kill(root)
        for name, source in fixture_cases():
            run_case(name, source, root)
    print("PASS: isolated Seasun-only startup cases; no proxy fixture server or inference traffic", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

### script/release_assets.py

```python
#!/usr/bin/env python3
"""Build and verify the public release assets, then publish without clobber.

Only the explicit ``publish`` command makes GitHub writes. It receives the
short-lived Actions token through GH_TOKEN; no credential is read or logged.
Native bundle checks run during packaging on macOS. Artifact readback checks
are portable and never extract or execute an application.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import zipfile

from package_source import PUBLIC_FILES


REPOSITORY = "Tupig/TokenStatMenu"
APP_FILES = {
    "Contents/Info.plist": 0o644,
    "Contents/MacOS/TokenStatMenu": 0o755,
    "Contents/Resources/AppIcon.icns": 0o644,
    "Contents/_CodeSignature/CodeResources": 0o644,
}
APP_DIRECTORIES = {"Contents", "Contents/MacOS", "Contents/Resources", "Contents/_CodeSignature"}
TAG_PATTERN = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
COMMIT_PATTERN = re.compile(r"[0-9a-f]{40}\Z")
SHA_PATTERN = re.compile(r"[0-9a-f]{64}\Z")


@dataclass(frozen=True)
class ReleaseIdentity:
    version: str
    build: str
    tag: str
    commit: str


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def _identity_fields(identity: ReleaseIdentity) -> dict:
    _require(isinstance(identity.tag, str) and TAG_PATTERN.fullmatch(identity.tag) is not None,
             "release tag must be a stable vMAJOR.MINOR.PATCH")
    _require(identity.version == identity.tag[1:], "tag/version mismatch")
    _require(isinstance(identity.build, str) and re.fullmatch(r"[1-9][0-9]*", identity.build) is not None,
             "build must be a positive ASCII integer string")
    _require(isinstance(identity.commit, str) and COMMIT_PATTERN.fullmatch(identity.commit) is not None,
             "invalid source commit")
    return dict(version=identity.version, build=identity.build, tag=identity.tag, commit=identity.commit)


def _git(root: Path, *arguments: str, check: bool = True) -> subprocess.CompletedProcess:
    # Release checks must not inherit an unrelated index, worktree or Git config.
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                       GIT_CONFIG_SYSTEM=os.devnull, GIT_TERMINAL_PROMPT="0")
    command = ["git", "-c", "core.hooksPath=" + os.devnull, *arguments]
    result = subprocess.run(command, cwd=root, env=environment, capture_output=True)
    if check and result.returncode:
        raise ValueError("required local Git check failed")
    return result


def _root(root: Path) -> Path:
    root = Path(root).resolve()
    _require(root.is_dir(), "missing source directory")
    actual = _git(root, "rev-parse", "--show-toplevel").stdout.decode().strip()
    _require(Path(actual).resolve() == root, "source must be the exact repository root")
    return root


def _plist(data: bytes) -> dict:
    try:
        value = plistlib.loads(data)
    except (ValueError, plistlib.InvalidFileException, TypeError, OverflowError) as error:
        raise ValueError("invalid bundle plist") from error
    _require(isinstance(value, dict), "bundle plist must be a dictionary")
    return value


def release_identity(root: Path, tag: str, expected_commit: str) -> ReleaseIdentity:
    root = _root(root)
    # Validate untrusted tag text before it reaches even an argument-array tool.
    _require(isinstance(tag, str) and TAG_PATTERN.fullmatch(tag) is not None, "invalid release tag")
    _require(isinstance(expected_commit, str) and COMMIT_PATTERN.fullmatch(expected_commit) is not None,
             "invalid expected source commit")
    info = _plist((root / "Resources/Info.plist").read_bytes())
    identity = ReleaseIdentity(info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"),
                               tag, expected_commit)
    _identity_fields(identity)
    head = _git(root, "rev-parse", "--verify", "HEAD").stdout.decode().strip()
    peeled = _git(root, "rev-parse", "--verify", "refs/tags/" + tag + "^{commit}").stdout.decode().strip()
    _require(head == expected_commit == peeled, "tag, HEAD and expected commit must match")
    _require(_git(root, "merge-base", "--is-ancestor", head, "refs/remotes/origin/main",
                  check=False).returncode == 0, "release commit must be in fetched origin/main history")
    _require(not _git(root, "status", "--porcelain", "--untracked-files=normal").stdout,
             "release source/index must be clean, with no untracked files")
    return identity


def _source_files(root: Path, public_files: list[str]) -> dict[str, tuple[bytes, int]]:
    root = _root(root)
    expected = set(public_files)
    _require(len(expected) == len(public_files), "duplicate public source name")
    for name in expected:
        _require(isinstance(name, str) and name and not name.startswith("/")
                 and all(part not in ["", ".", ".."] for part in name.split("/"))
                 and not any(ord(character) < 32 for character in name), "unsafe public source name")
    indexed = set(_git(root, "ls-files", "-z").stdout.decode().split("\0")[:-1])
    _require(indexed == expected, "tracked source set differs from the public allowlist")
    records = _git(root, "ls-tree", "-rz", "--full-tree", "HEAD").stdout.split(b"\0")
    committed = {}
    for record in records:
        if not record:
            continue
        metadata, encoded_name = record.split(b"\t", 1)
        mode, kind, object_id = metadata.decode().split()
        name = encoded_name.decode()
        _require(kind == "blob" and mode in ["100644", "100755"], "source has an unapproved Git file mode")
        committed[name] = (object_id, int(mode, 8))
    _require(set(committed) == expected, "commit source set differs from the public allowlist")
    result = {}
    for name, (object_id, git_mode) in committed.items():
        path = root / name
        # Inspect every component before reading, including directory symlinks.
        current = root
        for part in name.split("/"):
            current = current / part
            _require(not current.is_symlink(), "source contains a symbolic link")
        _require(path.is_file() and stat.S_ISREG(path.stat().st_mode), "source file is not regular")
        mode = stat.S_IMODE(path.stat().st_mode)
        _require(mode == stat.S_IMODE(git_mode), "source filesystem/Git modes differ")
        data = _git(root, "cat-file", "blob", object_id).stdout
        _require(path.read_bytes() == data, "source bytes differ from the release commit")
        result[name] = (data, mode)
    _require(_git(root, "diff", "--quiet", "HEAD", "--", check=False).returncode == 0,
             "source index or worktree differs from the release commit")
    return result


def _zip_files(path: Path, prefix: str, expected: set[str], modes: dict[str, int],
               sizes: dict[str, int] | None = None) -> dict[str, tuple[bytes, int]]:
    _require(not Path(path).is_symlink() and Path(path).is_file(), "archive is not a regular file")
    try:
        with zipfile.ZipFile(path) as archive:
            members = archive.infolist()
            names = [member.filename for member in members]
            required = {prefix + name for name in expected}
            _require(len(names) == len(set(names)) and set(names) == required,
                     "archive has missing, duplicate or unexpected members")
            result = {}
            for member in members:
                name = member.filename[len(prefix):]
                mode = member.external_attr >> 16
                _require(member.create_system == 3 and stat.S_ISREG(mode)
                         and stat.S_IMODE(mode) == modes[name] and not member.is_dir(),
                         "archive has a symbolic link, directory or incorrect mode")
                if sizes is not None:
                    _require(member.file_size == sizes[name], "archive member size differs from source")
                data = archive.read(member)
                _require(len(data) == member.file_size, "archive member is truncated")
                result[name] = (data, modes[name])
            return result
    except (zipfile.BadZipFile, RuntimeError, OSError, EOFError, NotImplementedError) as error:
        raise ValueError("invalid release archive") from error


def validate_source_archive(root: Path, source_zip: Path, public_files: list[str]) -> dict:
    source = _source_files(root, public_files)
    archived = _zip_files(source_zip, "TokenStatMenu/", set(source),
                          {name: mode for name, (_, mode) in source.items()},
                          {name: len(data) for name, (data, _) in source.items()})
    _require(archived == source, "archive source bytes differ from the release commit")
    return archived


def _bundle_content(root: Path, content: dict[str, tuple[bytes, int]], identity: ReleaseIdentity) -> None:
    _identity_fields(identity)
    _require(set(content) == set(APP_FILES), "bundle file set differs")
    source_info = _plist((Path(root) / "Resources/Info.plist").read_bytes())
    info = _plist(content["Contents/Info.plist"][0])
    expected = dict(source_info, TokenStatSourceRevision=identity.commit, TokenStatSourceState="clean")
    _require(info == expected, "bundle plist differs from source identity/provenance")
    _require(info.get("CFBundleShortVersionString") == identity.version
             and info.get("CFBundleVersion") == identity.build, "bundle version/build differs")
    _require(info.get("CFBundleIdentifier") == "com.tupig.TokenStatMenu"
             and info.get("CFBundleExecutable") == "TokenStatMenu"
             and info.get("CFBundleName") == "TokenStatMenu"
             and info.get("CFBundlePackageType") == "APPL"
             and info.get("CFBundleIconFile") == "AppIcon"
             and info.get("LSMinimumSystemVersion") == "13.0"
             and info.get("LSUIElement") is True, "unexpected application identity/platform")
    _require(content["Contents/Resources/AppIcon.icns"][0]
             == (Path(root) / "Resources/AppIcon.icns").read_bytes(), "bundle icon differs from source")
    _require(all(data and mode == APP_FILES[name] for name, (data, mode) in content.items()),
             "bundle has an empty file or incorrect mode")


def validate_app(root: Path, app: Path, identity: ReleaseIdentity, command_runner=subprocess.run) -> dict:
    app = Path(app)
    _require(not app.is_symlink() and app.is_dir(), "application is not a regular bundle directory")
    files, directories = {}, set()
    for path in app.rglob("*"):
        _require(not path.is_symlink(), "application contains a symbolic link")
        name = path.relative_to(app).as_posix()
        mode = path.stat().st_mode
        if stat.S_ISDIR(mode):
            directories.add(name)
        else:
            _require(stat.S_ISREG(mode) and name in APP_FILES, "application contains an unapproved file")
            _require(stat.S_IMODE(mode) == APP_FILES[name], "incorrect application file mode")
            files[name] = (path.read_bytes(), stat.S_IMODE(mode))
    _require(directories == APP_DIRECTORIES and set(files) == set(APP_FILES), "application full tree differs")
    _bundle_content(root, files, identity)
    try:
        arch = command_runner(["lipo", "-archs", str(app / "Contents/MacOS/TokenStatMenu")],
                              text=True, capture_output=True, check=False)
        _require(arch.returncode == 0 and set(arch.stdout.split()) == {"arm64", "x86_64"}
                 and len(arch.stdout.split()) == 2, "application must have exactly arm64 and x86_64")
        signed = command_runner(["codesign", "--verify", "--deep", "--strict", str(app)],
                                text=True, capture_output=True, check=False)
        _require(signed.returncode == 0, "strict application signature verification failed")
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError("native application validation tool failed") from error
    return files


def _names(identity: ReleaseIdentity) -> dict[str, str]:
    _identity_fields(identity)
    names = {kind: f"TokenStatMenu-{identity.version}-{kind}.zip" for kind in ["universal", "source"]}
    version_parts = tuple(int(part) for part in identity.version.split("."))
    if version_parts >= (1, 1, 5):
        names["dmg"] = f"TokenStatMenu-{identity.version}-universal.dmg"
    return names


def create_dmg(root: Path, app: Path, output_path: Path, identity: ReleaseIdentity,
               command_runner=subprocess.run) -> dict:
    """Create a Finder-friendly DMG around an already validated App.

    The staging directory is private and disposable. The only link inside the
    image is the conventional `/Applications` alias. No application is
    launched and no caller-owned path is removed.
    """
    _identity_fields(identity)
    _require(tuple(int(part) for part in identity.version.split(".")) >= (1, 1, 5),
             "DMG assets start with the 1.1.5 release contract")
    output_path = Path(output_path)
    _require(not output_path.exists() and not output_path.is_symlink(),
             "DMG output must be a new regular path")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    validate_app(root, app, identity, command_runner)
    with tempfile.TemporaryDirectory(prefix="tokenstat-dmg-stage-", dir=str(output_path.parent)) as temporary:
        staging = Path(temporary)
        staged_app = staging / "TokenStatMenu.app"
        shutil.copytree(app, staged_app, symlinks=True)
        applications = staging / "Applications"
        applications.symlink_to("/Applications")
        command = ["/usr/bin/hdiutil", "create", "-volname", "TokenStatMenu " + identity.version,
                   "-srcfolder", str(staging), "-format", "UDZO", "-ov", str(output_path)]
        try:
            result = command_runner(command, text=True, capture_output=True, check=False)
        except (OSError, subprocess.SubprocessError) as error:
            raise RuntimeError("DMG creation tool failed") from error
        _require(result.returncode == 0 and output_path.is_file() and not output_path.is_symlink(),
                 "DMG creation failed")
    data = output_path.read_bytes()
    return {"name": output_path.name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def validate_dmg(root: Path, dmg_path: Path, identity: ReleaseIdentity,
                 command_runner=subprocess.run) -> dict:
    """Inspect a DMG through imageinfo and a read-only owned mount."""
    _identity_fields(identity)
    dmg_path = Path(dmg_path)
    _require(not dmg_path.is_symlink() and dmg_path.is_file(), "DMG is not a regular file")
    mount = Path(tempfile.mkdtemp(prefix="tokenstat-dmg-mount-"))
    device: str | None = None
    def run_tool(arguments):
        try:
            return command_runner(arguments, text=True, capture_output=True, check=False)
        except (OSError, subprocess.SubprocessError) as error:
            raise RuntimeError("hdiutil command failed") from error
    try:
        info = run_tool(["/usr/bin/hdiutil", "imageinfo", str(dmg_path)])
        _require(info.returncode == 0, "hdiutil imageinfo failed")
        attach = run_tool(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse",
                           "-mountpoint", str(mount), str(dmg_path)])
        _require(attach.returncode == 0, "read-only DMG attach failed")
        # `hdiutil attach` may print localized checksum diagnostics before
        # its tabular device rows. Select only the row that explicitly names
        # our disposable mountpoint; never detach an arbitrary first device.
        # macOS commonly renders `/var/...` as its canonical `/private/var/...`
        # spelling in hdiutil output, so compare both spellings of our path.
        mount_texts = {str(mount), os.path.realpath(mount)}
        for line in attach.stdout.splitlines():
            fields = [field.strip() for field in line.split("\t")]
            if fields and fields[0].startswith("/dev/") and any(field in mount_texts for field in fields[1:]):
                device = fields[0]
                break
        _require(device is not None, "hdiutil attach returned no owned device")
        entries = list(mount.iterdir())
        _require({entry.name for entry in entries} == {"TokenStatMenu.app", "Applications"},
                 "DMG root has unexpected members")
        app = mount / "TokenStatMenu.app"
        applications = mount / "Applications"
        _require(app.is_dir() and not app.is_symlink(), "DMG App is missing or symbolic")
        _require(applications.is_symlink() and os.readlink(applications) == "/Applications",
                 "DMG Applications alias is unsafe")
        validate_app(root, app, identity, command_runner)
        data = dmg_path.read_bytes()
        return {"name": dmg_path.name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    finally:
        detach_error: BaseException | None = None
        if device is not None:
            try:
                detached = run_tool(["/usr/bin/hdiutil", "detach", device])
                _require(detached.returncode == 0, "owned DMG detach failed")
            except BaseException as error:
                detach_error = error
        shutil.rmtree(mount, ignore_errors=True)
        if detach_error is not None:
            # A cleanup failure must remain visible even when inspection also
            # failed; silently swallowing it could leave an owned image mounted.
            raise RuntimeError("owned DMG detach failed") from detach_error


def _canonical_zip(path: Path, prefix: str, files: dict[str, tuple[bytes, int]]) -> None:
    # Release-only normalization: original payload/modes, fixed ZIP metadata.
    # The generic source exporter retains its existing behavior.
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, (data, mode) in sorted(files.items()):
            item = zipfile.ZipInfo(prefix + name, (2026, 1, 1, 0, 0, 0))
            item.create_system = 3
            item.external_attr = (stat.S_IFREG | mode) << 16
            item.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(item, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def _sums(directory: Path, names: list[str]) -> bytes:
    return "".join(hashlib.sha256((directory / name).read_bytes()).hexdigest() + "  " + name + "\n"
                   for name in sorted(names)).encode("ascii")


def package_assets(root: Path, app: Path, source_zip: Path, output_dir: Path,
                   identity: ReleaseIdentity) -> dict:
    fields = _identity_fields(identity)
    output_dir = Path(output_dir)
    _require(not output_dir.is_symlink(), "staging directory is a symbolic link")
    _require(not output_dir.exists() or (output_dir.is_dir() and not any(output_dir.iterdir())),
             "staging directory must be new or empty; existing content is never removed")
    source = validate_source_archive(root, source_zip, PUBLIC_FILES)
    bundle = validate_app(root, app, identity)
    output_dir.mkdir(parents=True, exist_ok=True)
    names = _names(identity)
    _canonical_zip(output_dir / names["source"], "TokenStatMenu/", source)
    _canonical_zip(output_dir / names["universal"], "TokenStatMenu.app/", bundle)
    if "dmg" in names:
        create_dmg(root, app, output_dir / names["dmg"], identity)
    manifest = dict(fields, assets={})
    for kind, name in names.items():
        data = (output_dir / name).read_bytes()
        manifest["assets"][kind] = dict(name=name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
    (output_dir / "release-manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                                                        encoding="utf-8")
    (output_dir / "SHA256SUMS").write_bytes(_sums(output_dir, [*names.values(), "release-manifest.json"]))
    return validate_assets(root, output_dir, identity, validate_dmg_image=("dmg" in names))


def _unique_json(pairs: list[tuple]) -> dict:
    result = {}
    for key, value in pairs:
        _require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def validate_assets(root: Path, directory: Path, identity: ReleaseIdentity,
                    validate_dmg_image: bool = False,
                    command_runner=subprocess.run) -> dict:
    directory = Path(directory)
    fields, names = _identity_fields(identity), _names(identity)
    _require(not directory.is_symlink() and directory.is_dir(), "missing asset directory")
    expected = {*names.values(), "release-manifest.json", "SHA256SUMS"}
    files = list(directory.iterdir())
    _require({path.name for path in files} == expected
             and all(not path.is_symlink() and path.is_file() and stat.S_ISREG(path.stat().st_mode)
                     for path in files), "asset directory must contain the exact release asset set")
    try:
        manifest = json.loads((directory / "release-manifest.json").read_text(encoding="utf-8"),
                              object_pairs_hook=_unique_json)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValueError("invalid release manifest JSON") from error
    _require(isinstance(manifest, dict) and set(manifest) == {*fields, "assets"}, "unexpected manifest keys")
    _require(all(manifest[key] == value for key, value in fields.items()), "manifest release identity differs")
    assets = manifest["assets"]
    _require(isinstance(assets, dict) and set(assets) == set(names), "unexpected manifest asset keys")
    for kind, name in names.items():
        item = assets[kind]
        _require(isinstance(item, dict) and set(item) == {"name", "bytes", "sha256"}, "unexpected asset fields")
        _require(item["name"] == name and type(item["bytes"]) is int and item["bytes"] > 0
                 and isinstance(item["sha256"], str) and SHA_PATTERN.fullmatch(item["sha256"]) is not None,
                 "invalid asset name, byte count or digest")
        data = (directory / name).read_bytes()
        _require(len(data) == item["bytes"] and hashlib.sha256(data).hexdigest() == item["sha256"],
                 "asset byte count/digest mismatch")
    _require((directory / "SHA256SUMS").read_bytes()
             == _sums(directory, [*names.values(), "release-manifest.json"]), "checksum file differs")
    validate_source_archive(root, directory / names["source"], PUBLIC_FILES)
    bundle = _zip_files(directory / names["universal"], "TokenStatMenu.app/", set(APP_FILES), APP_FILES)
    _bundle_content(root, bundle, identity)
    if "dmg" in names and validate_dmg_image:
        validate_dmg(root, directory / names["dmg"], identity, command_runner)
    return manifest


def publish_release(root: Path, directory: Path, identity: ReleaseIdentity, client) -> str:
    """Validate before writes; a conflicting release is never overwritten.

    Failures after upload leave a draft. Failure after publish is a readback
    failure and is never described as a rollback or a successful publication.
    """
    # Publication must validate the complete release set, including the
    # native DMG image whenever this identity carries the fifth asset.
    validate_assets(root, directory, identity, validate_dmg_image=True)
    paths = {path.name: path for path in Path(directory).iterdir()}
    _require(client.resolve_tag(identity.tag) == identity.commit, "remote tag moved or differs")
    remote = client.lookup(identity.tag)
    if remote is not None:
        _require(remote.get("tag") == identity.tag and type(remote.get("draft")) is bool
                 and remote.get("prerelease") is False,
                 "remote release identity is invalid")
        existing = client.list_assets(remote["id"])
        _require(len(existing) == len(set(existing)) and set(existing) <= set(paths), "unexpected remote asset set")
        _require(remote["draft"] or set(existing) == set(paths), "published release has missing assets")
        for name in existing:
            _require(client.download(remote["id"], name) == paths[name].read_bytes(), "conflicting remote asset bytes")
        if not remote["draft"]:
            return "already-published"
    else:
        remote = client.create_draft(identity)
        _require(remote.get("tag") == identity.tag and remote.get("draft") is True
                 and remote.get("prerelease") is False,
                 "new release must be the matching draft")
        existing = []
    for name in sorted(set(paths) - set(existing)):
        client.upload(remote["id"], paths[name])

    def readback(release_id: int) -> None:
        actual = client.list_assets(release_id)
        _require(len(actual) == len(set(actual)) and set(actual) == set(paths), "remote asset set differs")
        for name, path in sorted(paths.items()):
            _require(client.download(release_id, name) == path.read_bytes(), "remote asset readback differs")
        _require(client.resolve_tag(identity.tag) == identity.commit, "remote tag changed during publication")

    readback(remote["id"])
    client.publish(remote["id"])
    final = client.lookup(identity.tag)
    _require(final is not None and final.get("id") == remote["id"] and final.get("tag") == identity.tag
             and final.get("draft") is False and final.get("prerelease") is False,
             "post-publication release readback failed")
    readback(final["id"])
    return "published"


class GitHubClient:
    """Small fixed-repository GitHub CLI adapter; response bodies stay private."""
    def __init__(self, identity: ReleaseIdentity, *, visibility_retries: int = 2,
                 visibility_delay: float = 0.25, sleep=time.sleep):
        _require(type(visibility_retries) is int and 0 <= visibility_retries <= 8,
                 "visibility retry count must be a bounded integer")
        _require(type(visibility_delay) in (int, float) and not isinstance(visibility_delay, bool)
                 and math.isfinite(visibility_delay) and visibility_delay >= 0,
                 "visibility retry delay must be finite and non-negative")
        _require(callable(sleep), "visibility retry sleep must be callable")
        self.identity = identity
        self.visibility_retries = visibility_retries
        self.visibility_delay = visibility_delay
        self.sleep = sleep
        self.base = "repos/" + REPOSITORY
        self.asset_ids: dict[tuple[int, str], int] = {}

    def _command(self, arguments: list[str], phase: str) -> bytes:
        result = subprocess.run(["gh", *arguments], capture_output=True)
        if result.returncode:
            raise RuntimeError("GitHub " + phase + " failed; remote state was preserved")
        return result.stdout

    def _get(self, path: str, *, missing: bool = False):
        result = subprocess.run(["gh", "api", "--hostname", "github.com", "--include", path], capture_output=True)
        # --include exposes the actual HTTP status. Only an explicit 404 is a
        # missing release; authentication, transport and service errors fail.
        match = re.match(rb"HTTP/\S+\s+(\d{3})[^\r\n]*\r?\n", result.stdout)
        if match and match.group(1) == b"404" and missing:
            return None
        if result.returncode or not match or match.group(1) != b"200":
            raise RuntimeError("GitHub read failed; no missing-release assumption was made")
        try:
            body = re.split(rb"\r?\n\r?\n", result.stdout, maxsplit=1)[1]
            return json.loads(body)
        except (IndexError, UnicodeError, json.JSONDecodeError) as error:
            raise RuntimeError("GitHub returned invalid response data") from error

    def resolve_tag(self, tag: str) -> str:
        _require(tag == self.identity.tag, "unexpected remote tag lookup")
        value = self._get(self.base + "/git/ref/tags/" + tag)
        for _ in range(8):
            obj = value.get("object", {})
            digest = obj.get("sha")
            _require(isinstance(digest, str) and COMMIT_PATTERN.fullmatch(digest) is not None,
                     "invalid remote Git object")
            if obj.get("type") == "commit":
                return digest
            _require(obj.get("type") == "tag", "remote tag does not reference a commit")
            value = self._get(self.base + "/git/tags/" + digest)
        raise ValueError("remote annotated tag nesting is excessive")

    def lookup(self, tag: str) -> dict | None:
        _require(tag == self.identity.tag, "unexpected remote release lookup")
        value = self._get(self.base + "/releases/tags/" + tag, missing=True)
        if value is None:
            releases = self._get(self.base + "/releases?per_page=100")
            _require(isinstance(releases, list) and len(releases) < 100,
                     "remote release list is invalid or incomplete")
            matching = [item for item in releases
                        if isinstance(item, dict) and item.get("tag_name") == tag]
            _require(len(matching) <= 1, "multiple remote releases match the requested tag")
            value = matching[0] if matching else None
            if value is None:
                return None
            # A tag endpoint miss is only recoverable for the intended draft
            # resume path. A published/prerelease match indicates conflicting
            # remote state and must fail closed rather than be guessed at.
            _require(type(value.get("draft")) is bool and value.get("draft") is True
                     and type(value.get("prerelease")) is bool and value.get("prerelease") is False,
                     "tag lookup miss found a non-resumable remote release")
        _require(type(value.get("id")) is int and type(value.get("draft")) is bool
                 and type(value.get("prerelease")) is bool,
                 "invalid remote release metadata")
        return dict(id=value["id"], tag=value.get("tag_name"), draft=value["draft"],
                    prerelease=value["prerelease"])

    def list_assets(self, release_id: int) -> list[str]:
        _require(type(release_id) is int and release_id > 0, "invalid remote release ID")
        value = self._get(self.base + f"/releases/{release_id}/assets?per_page=100")
        # A full page already proves a conflict; never hide additional pages
        # behind an apparently complete asset list.
        _require(isinstance(value, list) and len(value) < 100, "remote asset list is invalid or excessive")
        names = []
        for item in value:
            _require(isinstance(item, dict) and isinstance(item.get("name"), str)
                     and type(item.get("id")) is int and item["id"] > 0, "invalid remote asset metadata")
            names.append(item["name"])
            self.asset_ids[(release_id, item["name"])] = item["id"]
        return names

    def create_draft(self, identity: ReleaseIdentity) -> dict:
        _require(identity == self.identity, "unexpected draft identity")
        notes = (f"TokenStatMenu {identity.version} (build {identity.build}).\n\n"
                 "macOS 13 or later; Universal arm64 and x86_64.\n"
                 "This archive is ad hoc signed for local development. It is not Developer ID signed or notarized.\n"
                 f"Public source commit: {identity.commit}.\n")
        with tempfile.TemporaryDirectory(prefix="tokenstat-release-notes-") as temporary:
            path = Path(temporary) / "notes.md"
            path.write_text(notes, encoding="utf-8")
            self._command(["release", "create", identity.tag, "--repo", "github.com/" + REPOSITORY,
                           "--verify-tag", "--draft", "--title", "TokenStatMenu " + identity.version,
                           "--notes-file", str(path)], "create-draft")
        remote = None
        for attempt in range(self.visibility_retries + 1):
            remote = self.lookup(identity.tag)
            if remote is not None:
                return remote
            if attempt < self.visibility_retries:
                self.sleep(self.visibility_delay)
        _require(remote is not None, "created draft could not be read back")

    def upload(self, release_id: int, path: Path) -> None:
        self._command(["release", "upload", self.identity.tag, str(path), "--repo", "github.com/" + REPOSITORY],
                      "upload")

    def download(self, release_id: int, name: str) -> bytes:
        asset_id = self.asset_ids.get((release_id, name))
        _require(type(asset_id) is int, "remote asset ID was not enumerated")
        return self._command(["api", "--hostname", "github.com", "--header", "Accept: application/octet-stream",
                              self.base + f"/releases/assets/{asset_id}"], "download")

    def publish(self, release_id: int) -> None:
        self._command(["release", "edit", self.identity.tag, "--repo", "github.com/" + REPOSITORY,
                       "--draft=false"], "publish")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["preflight", "package", "verify", "publish"])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--directory", type=Path)
    args = parser.parse_args()
    try:
        identity = release_identity(args.root, args.tag, args.commit)
        if args.operation == "package":
            _require(args.app is not None and args.source is not None and args.directory is not None,
                     "package requires --app, --source and --directory")
            package_assets(args.root, args.app, args.source, args.directory, identity)
        elif args.operation in ["verify", "publish"]:
            _require(args.directory is not None, "verify/publish requires --directory")
            if args.operation == "verify":
                validate_assets(args.root, args.directory, identity, validate_dmg_image=True)
            else:
                outcome = publish_release(args.root, args.directory, identity, GitHubClient(identity))
                print("Release outcome: " + outcome)
        print("Release " + args.operation + " verified: " + identity.tag + " @ " + identity.commit)
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        # The messages above are deliberately fixed and contain no raw API data.
        print("Release " + args.operation + " failed: " + type(error).__name__, file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
```

### script/test_release_assets.py

```python
#!/usr/bin/env python3
"""Executable C26A checks. All fixtures are synthetic and private.

The API import intentionally fails until the paired implementation exists.
Native fixture success is not a substitute for the actual product build.
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

from package_source import PUBLIC_FILES
import release_assets as release


PROJECT = Path(__file__).resolve().parents[1]
TAG = "v1.1.3"
VERSION = "1.1.3"
BUILD = "5"
PUBLISH_IF = "$" + "{{ github.repository == 'Tupig/TokenStatMenu' && github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}"
TAG_ONLY_IF = "$" + "{{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}"
APP_FILES = {
    "Contents/Info.plist": 0o644,
    "Contents/MacOS/TokenStatMenu": 0o755,
    "Contents/Resources/AppIcon.icns": 0o644,
    "Contents/_CodeSignature/CodeResources": 0o644,
}


def run(*args: str, cwd: Path | None = None) -> str:
    environment = os.environ.copy()
    if args[0] == "git":
        # A private fixture must not execute user hooks, read signing settings,
        # inherit another index/worktree, or ask for any real credentials.
        environment = {key: value for key, value in environment.items()
                       if not key.startswith("GIT_")}
        environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                           GIT_CONFIG_SYSTEM=os.devnull, GIT_TERMINAL_PROMPT="0")
        args = ("git", "-c", "core.hooksPath=" + os.devnull,
                "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", *args[1:])
    result = subprocess.run(args, cwd=cwd, env=environment,
                            text=True, capture_output=True, check=True)
    return result.stdout.strip()


def write_zip(path: Path, entries: list[tuple[str, bytes, int]]) -> None:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data, mode in entries:
            item = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            item.create_system = 3
            item.external_attr = mode << 16
            archive.writestr(item, data)


def zip_entries(path: Path) -> list[tuple[str, bytes, int]]:
    with zipfile.ZipFile(path) as archive:
        return [(item.filename, archive.read(item), item.external_attr >> 16)
                for item in archive.infolist()]


class Fixture:
    def __init__(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="tokenstat-release-fixture-")
        self.base = Path(self.temporary.name)
        self.root = self.base / "source"
        self.root.mkdir()
        # Use actual reviewed file bytes and modes, without any real user data.
        for name in PUBLIC_FILES:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(PROJECT / name, target)
        self.source_info = plistlib.loads((self.root / "Resources/Info.plist").read_bytes())
        self.source_info["CFBundleShortVersionString"] = VERSION
        self.source_info["CFBundleVersion"] = BUILD
        (self.root / "Resources/Info.plist").write_bytes(plistlib.dumps(self.source_info))
        run("git", "init", "--quiet", "--initial-branch=main", cwd=self.root)
        run("git", "config", "user.name", "Synthetic Release Fixture", cwd=self.root)
        run("git", "config", "user.email", "release-fixture@example.invalid", cwd=self.root)
        run("git", "add", "--all", cwd=self.root)
        run("git", "commit", "--quiet", "-m", "Synthetic release fixture", cwd=self.root)
        self.commit = run("git", "rev-parse", "HEAD", cwd=self.root)
        run("git", "update-ref", "refs/remotes/origin/main", self.commit, cwd=self.root)
        run("git", "tag", TAG, cwd=self.root)
        self.identity = release.ReleaseIdentity(VERSION, BUILD, TAG, self.commit)
        self.source_zip = self.base / "source.zip"
        self.source_entries = []
        for name in PUBLIC_FILES:
            file = self.root / name
            self.source_entries.append(("TokenStatMenu/" + name, file.read_bytes(),
                                        stat.S_IFREG | stat.S_IMODE(file.stat().st_mode)))
        write_zip(self.source_zip, self.source_entries)
        self.app = self.base / "TokenStatMenu.app"
        info = dict(self.source_info, TokenStatSourceRevision=self.commit,
                    TokenStatSourceState="clean")
        contents = {
            "Contents/Info.plist": plistlib.dumps(info),
            "Contents/MacOS/TokenStatMenu": b"synthetic-native-payload",
            "Contents/Resources/AppIcon.icns": (self.root / "Resources/AppIcon.icns").read_bytes(),
            "Contents/_CodeSignature/CodeResources": b"synthetic-signature-resource",
        }
        for name, data in contents.items():
            file = self.app / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(data)
            file.chmod(APP_FILES[name])
        self.assets = self.base / "assets"

    def close(self) -> None:
        self.temporary.cleanup()

    def source_archive(self, entries: list[tuple[str, bytes, int]]) -> None:
        write_zip(self.source_zip, entries)

    def synthetic_assets(self) -> dict:
        """Independent file-format fixture; no production packager is called."""
        self.assets.mkdir()
        app_name = f"TokenStatMenu-{VERSION}-universal.zip"
        source_name = f"TokenStatMenu-{VERSION}-source.zip"
        app_entries = [("TokenStatMenu.app/" + name, (self.app / name).read_bytes(),
                        stat.S_IFREG | mode) for name, mode in APP_FILES.items()]
        write_zip(self.assets / app_name, app_entries)
        shutil.copy2(self.source_zip, self.assets / source_name)
        manifest = {
            "version": VERSION, "build": BUILD, "tag": TAG, "commit": self.commit,
            "assets": {},
        }
        for kind, name in [("universal", app_name), ("source", source_name)]:
            data = (self.assets / name).read_bytes()
            manifest["assets"][kind] = {
                "name": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            }
        (self.assets / "release-manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        self.refresh_sums()
        return manifest

    def refresh_sums(self) -> None:
        names = [f"TokenStatMenu-{VERSION}-universal.zip",
                 f"TokenStatMenu-{VERSION}-source.zip", "release-manifest.json"]
        (self.assets / "SHA256SUMS").write_text("".join(
            hashlib.sha256((self.assets / name).read_bytes()).hexdigest()
            + "  " + name + "\n" for name in sorted(names)))

    def mutate_manifest(self, change) -> None:
        file = self.assets / "release-manifest.json"
        value = json.loads(file.read_text())
        change(value)
        file.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        self.refresh_sums()


class FakeClient:
    """Only network transport is replaced; production state logic is exercised."""
    def __init__(self, fixture: Fixture, draft: bool | None = None,
                 existing: list[str] | None = None, failure: str | None = None,
                 final_readback: str | None = None) -> None:
        self.fixture = fixture
        self.tag_commit = fixture.commit
        self.remote = None if draft is None else {"id": 7, "tag": TAG, "draft": draft, "prerelease": False}
        self.assets = {} if existing is None else {
            name: (fixture.assets / name).read_bytes() for name in existing
        }
        self.calls: list[tuple] = []
        self.mutations: list[tuple] = []
        self.failure = failure
        self.final_readback = final_readback
        self.after_publish = False

    def record(self, name: str, *args, mutation: bool = False) -> None:
        self.calls.append((name, *args))
        if mutation:
            self.mutations.append((name, *args))
        if self.failure == name:
            raise RuntimeError("synthetic transport failure: " + name)

    def resolve_tag(self, tag: str) -> str:
        self.record("resolve_tag", tag)
        return self.tag_commit

    def lookup(self, tag: str) -> dict | None:
        self.record("lookup", tag)
        if self.after_publish and self.final_readback == "lookup-failed":
            raise RuntimeError("synthetic final lookup failure")
        result = copy.deepcopy(self.remote)
        if self.after_publish and self.final_readback == "still-draft":
            result["draft"] = True
        if self.after_publish and self.final_readback == "wrong-tag":
            result["tag"] = "v9.9.9"
        if self.after_publish and self.final_readback == "prerelease":
            result["prerelease"] = True
        return result

    def list_assets(self, release_id: int) -> list[str]:
        self.record("list_assets", release_id)
        return list(self.assets)

    def create_draft(self, identity) -> dict:
        self.record("create_draft", identity.tag, mutation=True)
        self.remote = {"id": 7, "tag": identity.tag, "draft": True, "prerelease": False}
        return copy.deepcopy(self.remote)

    def upload(self, release_id: int, path: Path) -> None:
        self.record("upload", Path(path).name, mutation=True)
        assert Path(path).name not in self.assets, "client must not clobber"
        self.assets[Path(path).name] = Path(path).read_bytes()

    def download(self, release_id: int, name: str) -> bytes:
        self.record("download", name)
        return self.assets[name]

    def publish(self, release_id: int) -> None:
        self.record("publish", release_id, mutation=True)
        self.remote["draft"] = False
        self.after_publish = True


class ReleaseChecks(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = Fixture()
        self.addCleanup(self.fixture.close)

    def reject_source(self, entries) -> None:
        self.fixture.source_archive(entries)
        with self.assertRaises(ValueError):
            release.validate_source_archive(self.fixture.root, self.fixture.source_zip, PUBLIC_FILES)

    def test_fixture_git_explicitly_disables_hooks_and_signing(self):
        f = self.fixture
        self.assertEqual(run("git", "config", "--get", "core.hooksPath", cwd=f.root), os.devnull)
        self.assertEqual(run("git", "config", "--get", "commit.gpgsign", cwd=f.root), "false")
        self.assertEqual(run("git", "config", "--get", "tag.gpgsign", cwd=f.root), "false")

    def test_identity_accepts_real_lightweight_and_annotated_tags(self):
        f = self.fixture
        self.assertEqual(release.release_identity(f.root, TAG, f.commit), f.identity)
        run("git", "tag", "-d", TAG, cwd=f.root)
        run("git", "tag", "-a", TAG, "-m", "Synthetic annotated release", cwd=f.root)
        self.assertEqual(release.release_identity(f.root, TAG, f.commit), f.identity)

    def test_identity_rejects_malformed_and_shell_special_tags(self):
        f = self.fixture
        marker = f.base / "unexpected-marker"
        for tag in ["1.1.3", "v01.1.3", "v1.1", "v1.1.3-rc.1", "v1.1.3;false",
                    "v1.1.3\n", f"v1.1.3; touch {marker}", f"v1.1.3$(touch {marker})"]:
            with self.subTest(tag=repr(tag)), self.assertRaises(ValueError):
                release.release_identity(f.root, tag, f.commit)
        self.assertFalse(marker.exists())

    def test_identity_rejects_wrong_commit_or_info_and_non_main_history(self):
        f = self.fixture
        with self.assertRaises(ValueError):
            release.release_identity(f.root, TAG, "a" * 40)
        run("git", "update-ref", "-d", "refs/remotes/origin/main", cwd=f.root)
        with self.assertRaises(ValueError):
            release.release_identity(f.root, TAG, f.commit)
        run("git", "update-ref", "refs/remotes/origin/main", f.commit, cwd=f.root)
        info = dict(f.source_info, CFBundleShortVersionString="9.9.9")
        (f.root / "Resources/Info.plist").write_bytes(plistlib.dumps(info))
        run("git", "add", "Resources/Info.plist", cwd=f.root)
        run("git", "commit", "--quiet", "-m", "Synthetic version mismatch", cwd=f.root)
        commit = run("git", "rev-parse", "HEAD", cwd=f.root)
        run("git", "tag", "-f", TAG, commit, cwd=f.root)
        run("git", "update-ref", "refs/remotes/origin/main", commit, cwd=f.root)
        with self.assertRaises(ValueError):
            release.release_identity(f.root, TAG, commit)

    def test_identity_rejects_dirty_staged_and_untracked_source(self):
        f = self.fixture
        (f.root / "README.md").write_text("synthetic changed source\n")
        with self.assertRaises(ValueError):
            release.release_identity(f.root, TAG, f.commit)
        run("git", "add", "README.md", cwd=f.root)
        with self.assertRaises(ValueError):
            release.release_identity(f.root, TAG, f.commit)
        run("git", "reset", "--hard", "HEAD", cwd=f.root)
        (f.root / "unreviewed.txt").write_text("synthetic\n")
        with self.assertRaises(ValueError):
            release.release_identity(f.root, TAG, f.commit)

    def test_identity_rejects_wrong_tag_target_and_unmerged_commit(self):
        f = self.fixture
        (f.root / "README.md").write_text("synthetic next commit\n")
        run("git", "add", "README.md", cwd=f.root)
        run("git", "commit", "--quiet", "-m", "Synthetic next commit", cwd=f.root)
        next_commit = run("git", "rev-parse", "HEAD", cwd=f.root)
        run("git", "update-ref", "refs/remotes/origin/main", next_commit, cwd=f.root)
        with self.assertRaises(ValueError):
            release.release_identity(f.root, TAG, next_commit)
        run("git", "tag", "-f", TAG, next_commit, cwd=f.root)
        run("git", "update-ref", "refs/remotes/origin/main", f.commit, cwd=f.root)
        with self.assertRaises(ValueError):
            release.release_identity(f.root, TAG, next_commit)

    def test_identity_rejects_invalid_build_metadata_after_clean_commit(self):
        f = self.fixture
        info = dict(f.source_info, CFBundleVersion="not-an-integer")
        (f.root / "Resources/Info.plist").write_bytes(plistlib.dumps(info))
        run("git", "add", "Resources/Info.plist", cwd=f.root)
        run("git", "commit", "--quiet", "-m", "Synthetic invalid build", cwd=f.root)
        commit = run("git", "rev-parse", "HEAD", cwd=f.root)
        run("git", "tag", "-f", TAG, commit, cwd=f.root)
        run("git", "update-ref", "refs/remotes/origin/main", commit, cwd=f.root)
        with self.assertRaises(ValueError):
            release.release_identity(f.root, TAG, commit)

    def test_identity_rejects_missing_tag_and_parent_repository_identity(self):
        f = self.fixture
        run("git", "tag", "-d", TAG, cwd=f.root)
        with self.assertRaises(ValueError):
            release.release_identity(f.root, TAG, f.commit)
        run("git", "tag", TAG, cwd=f.root)
        nested = f.root / "nested-export"
        nested.mkdir()
        with self.assertRaises(ValueError):
            release.release_identity(nested, TAG, f.commit)

    def test_source_archive_accepts_all_actual_commit_bytes_and_modes(self):
        f = self.fixture
        release.validate_source_archive(f.root, f.source_zip, PUBLIC_FILES)

    def test_source_archive_rejects_missing_extra_duplicate_and_hidden_members(self):
        entries = self.fixture.source_entries
        for changed in [entries[:-1],
                        entries + [("TokenStatMenu/extra.txt", b"x", stat.S_IFREG | 0o644)],
                        entries + [entries[0]],
                        entries + [("TokenStatMenu/.hidden", b"x", stat.S_IFREG | 0o644)]]:
            with self.subTest(count=len(changed)):
                self.reject_source(changed)

    def test_source_archive_rejects_path_escape_symlink_directory_mode_and_content(self):
        entries = self.fixture.source_entries
        name, data, mode = entries[0]
        for replacement in [("/absolute", data, mode), ("TokenStatMenu/../escape", data, mode),
                            (name, b"target", stat.S_IFLNK | 0o777),
                            (name + "/", b"", stat.S_IFDIR | 0o755),
                            (name, data, stat.S_IFREG | 0o755),
                            (name, data + b"changed", mode)]:
            with self.subTest(replacement=replacement[0]):
                self.reject_source([replacement, *entries[1:]])

    def test_source_archive_rejects_source_symlink_extra_tracked_and_changed_bytes(self):
        f = self.fixture
        target = f.root / "README.md"
        target.unlink()
        target.symlink_to(f.root / "LICENSE")
        with self.assertRaises(ValueError):
            release.validate_source_archive(f.root, f.source_zip, PUBLIC_FILES)
        target.unlink()
        run("git", "checkout", "--", "README.md", cwd=f.root)
        (f.root / "unreviewed.txt").write_text("synthetic")
        run("git", "add", "unreviewed.txt", cwd=f.root)
        with self.assertRaises(ValueError):
            release.validate_source_archive(f.root, f.source_zip, PUBLIC_FILES)
        run("git", "reset", "--hard", "HEAD", cwd=f.root)
        target.write_text("changed fixture")
        with self.assertRaises(ValueError):
            release.validate_source_archive(f.root, f.source_zip, PUBLIC_FILES)

    def test_cross_platform_assets_accept_independently_formatted_fixture(self):
        f = self.fixture
        expected = f.synthetic_assets()
        self.assertEqual(release.validate_assets(f.root, f.assets, f.identity), expected)

    def test_next_release_asset_names_add_universal_dmg_without_retroactive_legacy_asset(self):
        f = self.fixture
        next_identity = release.ReleaseIdentity("1.1.5", "7", "v1.1.5", f.commit)
        legacy_identity = release.ReleaseIdentity("1.1.4", "6", "v1.1.4", f.commit)
        self.assertEqual(release._names(next_identity), {
            "universal": "TokenStatMenu-1.1.5-universal.zip",
            "source": "TokenStatMenu-1.1.5-source.zip",
            "dmg": "TokenStatMenu-1.1.5-universal.dmg",
        })
        self.assertNotIn("dmg", release._names(legacy_identity))

    def test_verify_and_publish_request_native_dmg_validation(self):
        f = self.fixture
        f.synthetic_assets()
        with mock.patch.object(release, "validate_assets", wraps=release.validate_assets) as validator:
            release.publish_release(f.root, f.assets, f.identity, FakeClient(f))
            self.assertTrue(validator.call_args.kwargs["validate_dmg_image"])

        argv = ["release_assets.py", "verify", "--root", str(f.root),
                "--tag", f.identity.tag, "--commit", f.identity.commit,
                "--directory", str(f.assets)]
        with mock.patch.object(release, "release_identity", return_value=f.identity), \
             mock.patch.object(release, "validate_assets", return_value={}) as cli_validator, \
             mock.patch.object(sys, "argv", argv):
            release.main()
        self.assertTrue(cli_validator.call_args.kwargs["validate_dmg_image"])

    def test_assets_reject_extra_hidden_missing_and_symlink(self):
        f = self.fixture
        f.synthetic_assets()
        hidden = f.assets / ".unreviewed"
        hidden.write_bytes(b"synthetic")
        with self.assertRaises(ValueError):
            release.validate_assets(f.root, f.assets, f.identity)
        hidden.unlink()
        target = f.assets / "SHA256SUMS"
        data = target.read_bytes()
        target.unlink()
        with self.assertRaises(ValueError):
            release.validate_assets(f.root, f.assets, f.identity)
        outside = f.base / "sums"
        outside.write_bytes(data)
        target.symlink_to(outside)
        with self.assertRaises(ValueError):
            release.validate_assets(f.root, f.assets, f.identity)

    def test_assets_reject_unexpected_empty_subdirectory(self):
        f = self.fixture
        f.synthetic_assets()
        (f.assets / ".unexpected-directory").mkdir()
        with self.assertRaises(ValueError):
            release.validate_assets(f.root, f.assets, f.identity)

    def test_assets_reject_manifest_identity_unknown_keys_names_and_numeric_types(self):
        f = self.fixture
        baseline = f.synthetic_assets()
        changes = [
            lambda x: x.update(commit="a" * 40),
            lambda x: x.update(version="9.9.9"),
            lambda x: x.update(build="99"),
            lambda x: x.update(tag="v9.9.9"),
            lambda x: x.update(environment="not-an-approved-key"),
            lambda x: x["assets"]["source"].update(name="../source.zip"),
            lambda x: x["assets"]["source"].update(bytes=True),
            lambda x: x["assets"]["source"].update(bytes=-1),
            lambda x: x["assets"]["source"].update(sha256="A" * 64),
            lambda x: x["assets"]["source"].update(unreviewed=True),
        ]
        for change in changes:
            with self.subTest(change=changes.index(change)):
                (f.assets / "release-manifest.json").write_text(json.dumps(baseline))
                f.mutate_manifest(change)
                with self.assertRaises(ValueError):
                    release.validate_assets(f.root, f.assets, f.identity)

    def test_assets_reject_changed_checksum_duplicate_extra_and_path_sums(self):
        f = self.fixture
        f.synthetic_assets()
        target = f.assets / "SHA256SUMS"
        baseline = target.read_text()
        for text in [baseline.replace(baseline[:64], "0" * 64, 1),
                     baseline + baseline.splitlines()[0] + "\n",
                     baseline + "0" * 64 + "  extra.txt\n",
                     baseline.replace("  release-manifest.json", "  ../release-manifest.json")]:
            with self.subTest(text_length=len(text)):
                target.write_text(text)
                with self.assertRaises(ValueError):
                    release.validate_assets(f.root, f.assets, f.identity)

    def test_assets_reject_zip_bytes_even_when_manifest_and_sums_are_recomputed(self):
        f = self.fixture
        f.synthetic_assets()
        source_name = f"TokenStatMenu-{VERSION}-source.zip"
        write_zip(f.assets / source_name, f.source_entries[:-1])
        data = (f.assets / source_name).read_bytes()
        f.mutate_manifest(lambda x: x["assets"]["source"].update(
            bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
        with self.assertRaises(ValueError):
            release.validate_assets(f.root, f.assets, f.identity)

    def test_assets_reject_truncated_or_duplicate_bundle_zip(self):
        f = self.fixture
        f.synthetic_assets()
        name = f"TokenStatMenu-{VERSION}-universal.zip"
        archive = f.assets / name
        baseline = archive.read_bytes()
        original = zip_entries(archive)
        for kind in ["truncated", "duplicate", "hidden", "symlink"]:
            with self.subTest(kind=kind):
                if kind == "truncated":
                    archive.write_bytes(baseline[:20])
                else:
                    changed = list(original)
                    if kind == "duplicate":
                        changed.append(original[0])
                    elif kind == "hidden":
                        changed.append(("TokenStatMenu.app/.hidden", b"x", stat.S_IFREG | 0o644))
                    else:
                        item, _, _ = changed[0]
                        changed[0] = (item, b"target", stat.S_IFLNK | 0o777)
                    write_zip(archive, changed)
                data = archive.read_bytes()
                f.mutate_manifest(lambda x: x["assets"]["universal"].update(
                    bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
                with self.assertRaises(ValueError):
                    release.validate_assets(f.root, f.assets, f.identity)

    def test_assets_reject_zip_info_identity_even_with_recomputed_digests(self):
        f = self.fixture
        f.synthetic_assets()
        archive = f.assets / f"TokenStatMenu-{VERSION}-universal.zip"
        baseline = zip_entries(archive)
        for key, value in [("TokenStatSourceRevision", "a" * 40),
                           ("TokenStatSourceState", "modified"),
                           ("CFBundleShortVersionString", "9.9.9"),
                           ("CFBundleVersion", "99")]:
            with self.subTest(key=key):
                changed = []
                for name, data, mode in baseline:
                    if name == "TokenStatMenu.app/Contents/Info.plist":
                        info = plistlib.loads(data)
                        info[key] = value
                        data = plistlib.dumps(info)
                    changed.append((name, data, mode))
                write_zip(archive, changed)
                data = archive.read_bytes()
                f.mutate_manifest(lambda x: x["assets"]["universal"].update(
                    bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
                with self.assertRaises(ValueError):
                    release.validate_assets(f.root, f.assets, f.identity)

    def test_publish_creates_draft_reads_back_every_asset_then_publishes(self):
        f = self.fixture
        f.synthetic_assets()
        client = FakeClient(f)
        release.publish_release(f.root, f.assets, f.identity, client)
        names = set(p.name for p in f.assets.iterdir())
        self.assertEqual(set(client.assets), names)
        self.assertFalse(client.remote["draft"])
        self.assertEqual([item[0] for item in client.mutations],
                         ["create_draft", "upload", "upload", "upload", "upload", "publish"])
        publish_index = next(i for i, item in enumerate(client.calls) if item[0] == "publish")
        before = {item[1] for item in client.calls[:publish_index] if item[0] == "download"}
        self.assertEqual(before, names)
        self.assertTrue(any(item[0] == "lookup" for item in client.calls[publish_index + 1:]))

    def test_publish_identical_published_rerun_is_read_only(self):
        f = self.fixture
        f.synthetic_assets()
        client = FakeClient(f, draft=False, existing=[p.name for p in f.assets.iterdir()])
        release.publish_release(f.root, f.assets, f.identity, client)
        self.assertEqual(client.mutations, [])
        self.assertEqual({item[1] for item in client.calls if item[0] == "download"},
                         set(client.assets))

    def test_publish_matching_partial_draft_uploads_only_missing_assets(self):
        f = self.fixture
        f.synthetic_assets()
        client = FakeClient(f, draft=True, existing=["release-manifest.json"])
        release.publish_release(f.root, f.assets, f.identity, client)
        self.assertFalse(client.remote["draft"])
        uploaded = [item[1] for item in client.mutations if item[0] == "upload"]
        self.assertEqual(set(uploaded), {p.name for p in f.assets.iterdir()} - {"release-manifest.json"})
        self.assertEqual(len(uploaded), 3)
        self.assertNotIn("create_draft", [item[0] for item in client.mutations])

    def test_existing_release_requires_explicit_false_prerelease_before_writes(self):
        f = self.fixture
        f.synthetic_assets()
        for draft in [False, True]:
            for invalid in [True, None, 0, "false", "missing"]:
                with self.subTest(draft=draft, prerelease=invalid):
                    client = FakeClient(f, draft=draft, existing=[p.name for p in f.assets.iterdir()])
                    if invalid == "missing":
                        del client.remote["prerelease"]
                    else:
                        client.remote["prerelease"] = invalid
                    with self.assertRaises(ValueError):
                        release.publish_release(f.root, f.assets, f.identity, client)
                    self.assertEqual(client.mutations, [], "never silently convert a prerelease or ambiguous release")

    def test_new_draft_requires_explicit_false_prerelease_before_uploads(self):
        f = self.fixture
        f.synthetic_assets()
        for invalid in [True, None, 0, "false", "missing"]:
            with self.subTest(prerelease=invalid):
                client = FakeClient(f)
                original = client.create_draft
                def create_invalid(identity):
                    remote = original(identity)
                    if invalid == "missing":
                        del remote["prerelease"]
                    else:
                        remote["prerelease"] = invalid
                    return remote
                client.create_draft = create_invalid
                with self.assertRaises(ValueError):
                    release.publish_release(f.root, f.assets, f.identity, client)
                self.assertEqual([item[0] for item in client.mutations], ["create_draft"])
                self.assertTrue(client.remote["draft"])

    def test_github_adapter_preserves_strict_boolean_prerelease_metadata(self):
        client = release.GitHubClient(self.fixture.identity)
        baseline = {"id": 7, "tag_name": TAG, "draft": False, "prerelease": False}
        with mock.patch.object(client, "_get", return_value=baseline):
            self.assertEqual(client.lookup(TAG),
                             {"id": 7, "tag": TAG, "draft": False, "prerelease": False})
        for invalid in [None, 0, "false", "missing"]:
            value = dict(baseline)
            if invalid == "missing":
                del value["prerelease"]
            else:
                value["prerelease"] = invalid
            with self.subTest(prerelease=invalid), mock.patch.object(client, "_get", return_value=value):
                with self.assertRaises(ValueError):
                    client.lookup(TAG)
        # A real boolean true is preserved by transport, then rejected by the
        # publisher. The adapter must never coerce any metadata to false.
        with mock.patch.object(client, "_get", return_value=dict(baseline, prerelease=True)):
            self.assertIs(client.lookup(TAG)["prerelease"], True)

    def test_github_lookup_404_fallback_accepts_one_exact_draft_only(self):
        client = release.GitHubClient(self.fixture.identity)
        draft = {"id": 77, "tag_name": TAG, "draft": True, "prerelease": False}
        calls = []
        def get(path, *, missing=False):
            calls.append((path, missing))
            if path.endswith("/releases/tags/" + TAG):
                return None
            return [dict(draft), {"id": 78, "tag_name": "v1.1.30", "draft": True, "prerelease": False}]
        with mock.patch.object(client, "_get", side_effect=get):
            self.assertEqual(client.lookup(TAG), {"id": 77, "tag": TAG, "draft": True, "prerelease": False})
        self.assertEqual(calls, [("repos/Tupig/TokenStatMenu/releases/tags/" + TAG, True),
                                 ("repos/Tupig/TokenStatMenu/releases?per_page=100", False)])

    def test_github_lookup_404_fallback_empty_or_unrelated_is_absent(self):
        client = release.GitHubClient(self.fixture.identity)
        for releases in [[], [{"id": 78, "tag_name": "v1.1.30", "draft": True, "prerelease": False}]]:
            with self.subTest(releases=releases), mock.patch.object(
                    client, "_get", side_effect=[None, releases]):
                self.assertIsNone(client.lookup(TAG))

    def test_github_lookup_404_fallback_rejects_duplicate_conflicts_and_bad_lists(self):
        client = release.GitHubClient(self.fixture.identity)
        valid = {"id": 77, "tag_name": TAG, "draft": True, "prerelease": False}
        cases = [
            [valid, dict(valid, id=78)],
            [dict(valid, draft=False)],
            [dict(valid, prerelease=True)],
            [dict(valid, tag_name=TAG, draft="true")],
            [{"id": 77, "tag_name": TAG}],
            [{"id": 77, "tag_name": TAG, "draft": True, "prerelease": False}] * 100,
            {"items": [valid]},
        ]
        for releases in cases:
            with self.subTest(releases=releases), mock.patch.object(
                    client, "_get", side_effect=[None, releases]):
                with self.assertRaises((ValueError, RuntimeError)):
                    client.lookup(TAG)

    def test_create_draft_retries_only_post_create_visibility_miss(self):
        f = self.fixture
        sleeps = []
        commands = []
        client = release.GitHubClient(f.identity, visibility_retries=2,
                                      visibility_delay=0.25, sleep=sleeps.append)
        draft = {"id": 77, "tag": TAG, "draft": True, "prerelease": False}
        with mock.patch.object(client, "_command",
                               side_effect=lambda arguments, phase: commands.append((arguments, phase))), \
             mock.patch.object(client, "lookup", side_effect=[None, draft]) as lookup:
            self.assertEqual(client.create_draft(f.identity), draft)
        self.assertEqual(lookup.call_count, 2)
        self.assertEqual(sleeps, [0.25])
        self.assertEqual([phase for _, phase in commands], ["create-draft"])

    def test_create_draft_visibility_retry_is_bounded_and_transport_errors_do_not_retry(self):
        f = self.fixture
        for lookup_values, expected_sleeps in [([None, None, None], [0.25, 0.25]),
                                               ([RuntimeError("synthetic transport")], [])]:
            with self.subTest(expected_sleeps=expected_sleeps):
                sleeps = []
                commands = []
                client = release.GitHubClient(f.identity, visibility_retries=2,
                                              visibility_delay=0.25, sleep=sleeps.append)
                with mock.patch.object(client, "_command",
                                       side_effect=lambda arguments, phase: commands.append((arguments, phase))), \
                     mock.patch.object(client, "lookup", side_effect=lookup_values) as lookup:
                    with self.assertRaises((ValueError, RuntimeError)):
                        client.create_draft(f.identity)
                self.assertEqual(lookup.call_count, len(lookup_values))
                self.assertEqual(sleeps, expected_sleeps)
                self.assertEqual([phase for _, phase in commands], ["create-draft"])

    def test_publish_resumes_single_fallback_draft_without_creating_release(self):
        f = self.fixture
        f.synthetic_assets()
        client = FakeClient(f, draft=True, existing=["release-manifest.json"])
        release.publish_release(f.root, f.assets, f.identity, client)
        self.assertNotIn("create_draft", [item[0] for item in client.mutations])
        self.assertFalse(client.remote["draft"])
        self.assertEqual(len([item for item in client.mutations if item[0] == "upload"]), 3)

    def test_publish_conflicts_or_retagging_never_mutate_remote_release(self):
        f = self.fixture
        f.synthetic_assets()
        names = [p.name for p in f.assets.iterdir()]
        for kind in ["published-content", "draft-content", "extra", "missing", "retagged"]:
            with self.subTest(kind=kind):
                client = FakeClient(f, draft=(kind == "draft-content"), existing=names)
                if kind.endswith("content"):
                    client.assets[names[0]] += b"conflict"
                elif kind == "extra":
                    client.assets["unreviewed.txt"] = b"synthetic"
                elif kind == "missing":
                    del client.assets[names[0]]
                else:
                    client.tag_commit = "a" * 40
                with self.assertRaises((ValueError, RuntimeError)):
                    release.publish_release(f.root, f.assets, f.identity, client)
                self.assertEqual(client.mutations, [])

    def test_publish_rejects_invalid_local_assets_before_any_mutation(self):
        f = self.fixture
        f.synthetic_assets()
        (f.assets / "unexpected.txt").write_text("synthetic")
        client = FakeClient(f)
        with self.assertRaises(ValueError):
            release.publish_release(f.root, f.assets, f.identity, client)
        self.assertEqual(client.mutations, [])

    def test_publish_transport_failures_are_not_missing_release_or_success(self):
        f = self.fixture
        f.synthetic_assets()
        for phase in ["resolve_tag", "lookup", "create_draft", "upload", "download", "publish"]:
            with self.subTest(phase=phase):
                client = FakeClient(f, failure=phase)
                with self.assertRaises((ValueError, RuntimeError)):
                    release.publish_release(f.root, f.assets, f.identity, client)
                if phase in ["resolve_tag", "lookup"]:
                    self.assertEqual(client.mutations, [])
                if phase in ["upload", "download"]:
                    self.assertTrue(client.remote["draft"])
                    self.assertNotIn("publish", [item[0] for item in client.mutations])

    def test_post_publish_readback_failures_do_not_claim_success_or_rollback(self):
        f = self.fixture
        f.synthetic_assets()
        for mode in ["lookup-failed", "still-draft", "wrong-tag", "prerelease"]:
            with self.subTest(mode=mode):
                client = FakeClient(f, final_readback=mode)
                with self.assertRaises((ValueError, RuntimeError)):
                    release.publish_release(f.root, f.assets, f.identity, client)
                self.assertTrue(client.after_publish)
                self.assertFalse(client.remote["draft"],
                                 "a failed readback must not pretend publication was rolled back")
                self.assertEqual(client.mutations[-1][0], "publish")
                self.assertEqual([item[0] for item in client.mutations].count("publish"), 1)


@unittest.skipUnless(sys.platform == "darwin", "real private macOS signing/Universal fixture")
class NativeReleaseChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.native_directory = tempfile.TemporaryDirectory(prefix="tokenstat-native-release-check-")
        cls.addClassCleanup(cls.native_directory.cleanup)
        cls.native_root = Path(cls.native_directory.name)
        source = cls.native_root / "main.swift"
        source.write_text('print("synthetic release validation")\n')
        cls.thin = cls.native_root / "thin"
        intel = cls.native_root / "intel"
        cls.universal = cls.native_root / "universal"
        run("xcrun", "--sdk", "macosx", "swiftc", "-target", "arm64-apple-macosx13.0",
            str(source), "-o", str(cls.thin))
        run("xcrun", "--sdk", "macosx", "swiftc", "-target", "x86_64-apple-macosx13.0",
            str(source), "-o", str(intel))
        run("lipo", "-create", str(cls.thin), str(intel), "-output", str(cls.universal))

    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.close)
        f = self.fixture
        shutil.copy2(self.universal, f.app / "Contents/MacOS/TokenStatMenu")
        self.sign()

    def sign(self):
        run("codesign", "--force", "--sign", "-", str(self.fixture.app))

    def test_real_private_universal_signature_and_packaging(self):
        f = self.fixture
        release.validate_app(f.root, f.app, f.identity, subprocess.run)
        release.package_assets(f.root, f.app, f.source_zip, f.assets, f.identity)
        expected = {f"TokenStatMenu-{VERSION}-universal.zip",
                    f"TokenStatMenu-{VERSION}-source.zip",
                    "release-manifest.json", "SHA256SUMS"}
        self.assertEqual({p.name for p in f.assets.iterdir()}, expected)
        release.validate_assets(f.root, f.assets, f.identity)
        with zipfile.ZipFile(f.assets / f"TokenStatMenu-{VERSION}-universal.zip") as archive:
            for name, mode in APP_FILES.items():
                member = archive.getinfo("TokenStatMenu.app/" + name)
                self.assertEqual(archive.read(member), (f.app / name).read_bytes())
                self.assertEqual(stat.S_IMODE(member.external_attr >> 16), mode)

    def test_release_assets_ignore_only_filesystem_and_input_zip_metadata(self):
        f = self.fixture
        release.package_assets(f.root, f.app, f.source_zip, f.assets, f.identity)
        first = {path.name: path.read_bytes() for path in f.assets.iterdir()}
        original_source_zip = f.source_zip.read_bytes()
        for file in f.app.rglob("*"):
            if file.is_file():
                original = file.stat()
                os.utime(file, (original.st_atime + 3600, original.st_mtime + 3600))
        with zipfile.ZipFile(f.source_zip, "w", zipfile.ZIP_STORED) as archive:
            archive.comment = b"synthetic source archive metadata"
            for name, data, mode in reversed(f.source_entries):
                member = zipfile.ZipInfo(name, (2026, 2, 2, 1, 2, 4))
                member.create_system = 3
                member.external_attr = mode << 16
                member.comment = b"synthetic entry metadata"
                archive.writestr(member, data)
        self.assertNotEqual(f.source_zip.read_bytes(), original_source_zip)
        second_dir = f.base / "assets-second"
        release.package_assets(f.root, f.app, f.source_zip, second_dir, f.identity)
        second = {path.name: path.read_bytes() for path in second_dir.iterdir()}
        self.assertEqual(first, second,
                         "release metadata normalization must preserve deterministic four-asset bytes")

    def test_real_signature_rejects_post_signing_plist_tamper(self):
        f = self.fixture
        file = f.app / "Contents/Info.plist"
        info = plistlib.loads(file.read_bytes())
        info["CFBundleDisplayName"] = "synthetic tamper"
        file.write_bytes(plistlib.dumps(info))
        result = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(f.app)],
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, subprocess.run)

    def test_signature_is_required_when_only_signed_executable_bytes_change(self):
        f = self.fixture
        info = (f.app / "Contents/Info.plist").read_bytes()
        icon = (f.app / "Contents/Resources/AppIcon.icns").read_bytes()
        binary = f.app / "Contents/MacOS/TokenStatMenu"
        data = bytearray(binary.read_bytes())
        offset = data.index(b"synthetic release validation")
        data[offset] ^= 1
        binary.write_bytes(data)
        self.assertEqual((f.app / "Contents/Info.plist").read_bytes(), info)
        self.assertEqual((f.app / "Contents/Resources/AppIcon.icns").read_bytes(), icon)
        self.assertEqual(set(run("lipo", "-archs", str(binary)).split()), {"arm64", "x86_64"})
        result = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(f.app)],
                                text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0,
                            "only the signature should distinguish this otherwise valid bundle")
        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, subprocess.run)

    def test_real_thin_signed_bundle_is_not_universal(self):
        f = self.fixture
        shutil.copy2(self.thin, f.app / "Contents/MacOS/TokenStatMenu")
        self.sign()
        self.assertEqual(run("lipo", "-archs", str(f.app / "Contents/MacOS/TokenStatMenu")), "arm64")
        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, subprocess.run)

    def test_architecture_reader_rejects_additional_unapproved_architecture(self):
        f = self.fixture
        def synthetic_tool_result(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, "arm64 x86_64 arm64e\n", "")
        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, synthetic_tool_result)

    def test_packaging_refuses_nonempty_staging_without_deleting_anything(self):
        f = self.fixture
        f.assets.mkdir()
        sentinel = f.assets / "preserve-this-file"
        sentinel.write_bytes(b"synthetic sentinel")
        with self.assertRaises(ValueError):
            release.package_assets(f.root, f.app, f.source_zip, f.assets, f.identity)
        self.assertEqual({p.name for p in f.assets.iterdir()}, {sentinel.name})
        self.assertEqual(sentinel.read_bytes(), b"synthetic sentinel")

    def test_bundle_full_tree_modes_identity_and_icon_are_enforced(self):
        f = self.fixture
        hidden = f.app / ".hidden"
        hidden.write_bytes(b"synthetic")
        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, subprocess.run)
        hidden.unlink()
        binary = f.app / "Contents/MacOS/TokenStatMenu"
        binary.chmod(0o644)
        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, subprocess.run)
        binary.chmod(0o755)
        icon = f.app / "Contents/Resources/AppIcon.icns"
        icon.write_bytes(b"synthetic wrong icon")
        self.sign()
        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, subprocess.run)

    def test_bundle_symlink_missing_resource_and_wrong_provenance_are_rejected(self):
        f = self.fixture
        resource = f.app / "Contents/_CodeSignature/CodeResources"
        saved = resource.read_bytes()
        resource.unlink()
        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, subprocess.run)
        outside = f.base / "resource"
        outside.write_bytes(saved)
        resource.symlink_to(outside)
        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, subprocess.run)
        resource.unlink()
        resource.write_bytes(saved)
        file = f.app / "Contents/Info.plist"
        info = plistlib.loads(file.read_bytes())
        info["TokenStatSourceRevision"] = "a" * 40
        info["TokenStatSourceState"] = "modified"
        file.write_bytes(plistlib.dumps(info))
        self.sign()
        with self.assertRaises(ValueError):
            release.validate_app(f.root, f.app, f.identity, subprocess.run)


def load_workflow(path: Path) -> dict:
    # Ruby standard YAML is the frozen parser; normalize YAML1.1 on=>true.
    program = (
        "require 'yaml'; require 'json'; "
        "value=YAML.safe_load(File.read(ARGV.fetch(0)), aliases: true); "
        "value['on']=value.delete(true) if value.key?(true); "
        "STDOUT.write(JSON.generate(value))"
    )
    return json.loads(run("ruby", "-e", program, str(path)))


def workflow_contract(document: dict, raw: str) -> None:
    """A bounded assertion for this workflow, not a general workflow scanner."""
    assert document["on"] == {
        "push": {"branches": ["main"], "tags": ["v*"]},
        "pull_request": {},
    }
    assert document["permissions"] == {"contents": "read"}
    assert set(document["jobs"]) == {"build", "publish"}
    build = document["jobs"]["build"]
    publish = document["jobs"]["publish"]
    assert "if" not in build
    assert all(job.get("continue-on-error", False) is False for job in [build, publish])
    assert build.get("permissions", document["permissions"]) == {"contents": "read"}
    assert publish["permissions"] == {"contents": "write"}
    assert publish["needs"] in ["build", ["build"]]
    assert " ".join(publish["if"].split()) == PUBLISH_IF
    assert document["concurrency"]["cancel-in-progress"] is False
    actions = [step["uses"] for job in [build, publish] for step in job["steps"] if "uses" in step]
    allowed = {
        "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
        "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9",
        "actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333",
    }
    assert set(actions) == allowed
    for job in [build, publish]:
        for step in job["steps"]:
            if step.get("uses", "").startswith("actions/checkout@"):
                assert step["with"]["persist-credentials"] is False
    assert any(step.get("with", {}).get("fetch-depth") == 0 for step in build["steps"])
    uploads = [step for step in build["steps"]
               if step.get("uses", "").startswith("actions/upload-artifact@")]
    assert len(uploads) == 1 and uploads[0]["with"]["if-no-files-found"] == "error"
    assert " ".join(uploads[0].get("if", "").split()) == TAG_ONLY_IF
    paths = uploads[0]["with"]["path"]
    assert "*" not in paths and len(paths.splitlines()) == 5
    assert any(path.endswith("-universal.dmg") for path in paths.splitlines())
    scripts = "\n".join(step.get("run", "") for job in [build, publish] for step in job["steps"])
    assert "$" + "{{ github.ref_name }}" not in scripts
    assert "--clobber" not in scripts and "continue-on-error: true" not in raw
    assert "script/release_assets.py" in scripts
    assert "--universal" in scripts
    assert "script/test_release_assets.py" in scripts
    assert "GH_TOKEN" in json.dumps(publish)
    assert "GH_TOKEN" not in json.dumps(build)
    def assert_step(job_name: str, prefix: str, expected_if: str | None,
                    expected_lines: int = 1) -> None:
        matching = [step for step in document["jobs"][job_name]["steps"]
                    if any(line.strip().startswith(prefix)
                           for line in step.get("run", "").splitlines())]
        assert len(matching) == 1
        step = matching[0]
        if expected_if is None:
            assert "if" not in step
        else:
            if_value = step.get("if", "")
            assert isinstance(if_value, str)
            assert " ".join(if_value.split()) == expected_if
        assert step.get("continue-on-error", False) is False
        lines = [line.strip() for line in step["run"].splitlines()
                 if line.strip().startswith(prefix)]
        assert len(lines) == expected_lines
        for line in lines:
            assert "||" not in line and "; true" not in line
            assert not line.endswith("&")

    for prefix in ["python3 -B script/test_release_assets.py",
                   "swift run --force-resolved-versions TokenStatCoreChecks",
                   "xcodebuild -project TokenStatMenu.xcodeproj",
                   "git diff --exit-code -- Package.resolved"]:
        assert_step("build", prefix, None)
    assert_step("build", "swift test --force-resolved-versions", None, expected_lines=2)
    for prefix in ["python3 -B script/release_assets.py preflight",
                   "./script/build_and_run.sh --universal",
                   "python3 -B script/package_source.py",
                   "python3 -B script/release_assets.py package",
                   "python3 -B script/release_assets.py verify"]:
        assert_step("build", prefix, TAG_ONLY_IF)
    assert_step("publish", "python3 -B script/release_assets.py verify", None)
    assert_step("publish", "python3 -B script/release_assets.py publish", None)


class WorkflowChecks(unittest.TestCase):
    def test_repository_has_one_workflow_entrypoint(self):
        workflow_root = PROJECT / ".github/workflows"
        workflow_files = sorted(
            path.name for path in workflow_root.iterdir()
            if path.is_file() and path.suffix in {".yml", ".yaml"}
        )
        self.assertEqual(workflow_files, ["ci.yml"])

    def test_release_workflow_has_bounded_tag_only_write_permissions(self):
        path = PROJECT / ".github/workflows/ci.yml"
        workflow_contract(load_workflow(path), path.read_text())

    def test_workflow_assertions_reject_gate_permission_and_asset_mutations(self):
        path = PROJECT / ".github/workflows/ci.yml"
        raw = path.read_text()
        baseline = load_workflow(path)
        variants = []
        value = copy.deepcopy(baseline)
        value["on"]["pull_request_target"] = {}
        variants.append(value)
        value = copy.deepcopy(baseline)
        value["permissions"] = {"contents": "write"}
        variants.append(value)
        value = copy.deepcopy(baseline)
        value["jobs"]["publish"]["needs"] = []
        variants.append(value)
        value = copy.deepcopy(baseline)
        value["jobs"]["publish"]["if"] = "always()"
        variants.append(value)
        value = copy.deepcopy(baseline)
        value["jobs"]["build"]["steps"].append({"run": "echo " + "$" + "{{ github.ref_name }}"})
        variants.append(value)
        value = copy.deepcopy(baseline)
        for step in value["jobs"]["build"]["steps"]:
            if step.get("uses", "").startswith("actions/upload-artifact@"):
                step["with"]["path"] = "dist/*"
        variants.append(value)
        value = copy.deepcopy(baseline)
        value["jobs"]["publish"]["steps"].append({"run": "gh release upload --clobber"})
        variants.append(value)
        value = copy.deepcopy(baseline)
        value["jobs"]["unexpected-writer"] = {
            "permissions": {"contents": "write"}, "runs-on": "ubuntu-latest",
            "steps": [{"run": "false"}],
        }
        variants.append(value)
        for job_name in ["build", "publish"]:
            value = copy.deepcopy(baseline)
            value["jobs"][job_name]["continue-on-error"] = True
            variants.append(value)
            if job_name == "build":
                value = copy.deepcopy(baseline)
                value["jobs"][job_name]["if"] = False
                variants.append(value)
            for alteration in ["disabled", "removed", "commented", "shell-or", "shell-true", "background"]:
                value = copy.deepcopy(baseline)
                steps = value["jobs"][job_name]["steps"]
                index = next(i for i, step in enumerate(steps)
                             if any(line.strip().startswith("python3 -B script/release_assets.py verify")
                                    for line in step.get("run", "").splitlines()))
                if alteration == "disabled":
                    steps[index]["if"] = False
                elif alteration == "removed":
                    steps.pop(index)
                elif alteration == "commented":
                    steps[index]["run"] = "\n".join("# " + line for line in steps[index]["run"].splitlines())
                else:
                    suffix = {"shell-or": " || true", "shell-true": "; true", "background": " &"}[alteration]
                    steps[index]["run"] = "\n".join(
                        line + suffix if line.strip().startswith("python3 -B script/release_assets.py verify")
                        else line for line in steps[index]["run"].splitlines())
                variants.append(value)
        for index, value in enumerate(variants):
            with self.subTest(index=index), self.assertRaises(AssertionError):
                workflow_contract(value, raw)
        with self.assertRaises(AssertionError):
            workflow_contract(baseline, raw + "\ncontinue-on-error: true\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
```

### script/BenchmarkMenu.swift

```swift
import AppKit
import Combine
import Foundation
import TokenStatCore
@testable import TokenStatMenu

/// An isolated menu-update workload, never an application launch. Preview mode
/// disables configuration loading, Hub discovery and every background service.
/// The wrapper links this same harness against both source variants.
@main
struct BenchmarkMenu {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2,
              let iterations = Int(CommandLine.arguments[1]),
              (1...1_000_000).contains(iterations) else { exit(2) }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let model = AppModel(preview: true)
        model.config.dataSource = "localCodex"
        let syntheticDate = Date(timeIntervalSince1970: 1_800_000_000)
        model.tokenHubNow = { syntheticDate }
        model.localSnapshot = LocalCodexSnapshot(input: 125, output: 300, total: 425,
            sessionCount: 2, filesScanned: 2, isLimited: false, latestEventAt: syntheticDate,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 2,
            lastTurn: LocalTurnSummary(outputTokens: 75, durationSeconds: 5, completedAt: syntheticDate))
        let controller = StatusBarController(model: model)
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        let startedAt = ProcessInfo.processInfo.systemUptime
        for _ in 0..<iterations { autoreleasepool { model.tick() } }
        let elapsedMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        let tickPublications = publications // Exclude shutdown notifications.
        withExtendedLifetime(controller) {}
        withExtendedLifetime(subscription) {}
        model.shutdown()
        let report: [String: Any] = ["iterations": iterations, "elapsedMS": elapsedMS,
                                     "objectWillChange": tickPublications]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
```

### script/benchmark_menu.py

```python
#!/usr/bin/env python3
"""Compare a pure-synthetic menu workload using isolated, matching Swift builds.

Only AppModel.swift and StatusBarController.swift differ between variants:
by default the baseline comes from the published 1.1.0 commit and the candidate
comes from the working tree. Current Core and other App sources are shared.
No SwiftPM cache, installed app, external request or local business data is used.
Run from any directory: python3 script/benchmark_menu.py [--rounds 1].
"""
import argparse
import json
import math
import platform
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "4713f1ae465675056b18dbbb40c09c717bb171d1"
MENU_FILES = ("AppModel.swift", "StatusBarController.swift")
CORE_FILES = (
    "Configuration.swift", "GatewayDiscovery.swift", "HTTPDecoder.swift",
    "LocalCodexUsageReader.swift", "MetricsEngine.swift", "ProxyServer.swift",
    "Quota.swift", "RateWindow.swift", "StreamParser.swift", "TokenHubAXScanning.swift",
    "TokenHubDirectQuota.swift", "TokenHubQuota.swift", "WindowQuota.swift",
)
APP_FILES = (
    "AppModel.swift", "DashboardView.swift", "PanelStyle.swift", "SettingsView.swift",
    "StatusBarController.swift", "Storage.swift", "TokenHubAXReader.swift",
    "TokenHubQuotaCard.swift", "WindowQuotaCard.swift",
)


def command(arguments, stage):
    """Capture compiler output so normal reports contain no temporary paths."""
    result = subprocess.run(arguments, cwd=ROOT, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f"{stage} failed; check the selected full Xcode toolchain and source compatibility")
    return result.stdout


def checked_source(directory, name):
    path = ROOT / "Sources" / directory / name
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("a required regular source file is unavailable")
    return path


def bounded_integer(value, upper):
    number = int(value)
    if not 1 <= number <= upper:
        raise argparse.ArgumentTypeError(f"must be between 1 and {upper}")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default=BASELINE, help="local baseline commit; changes only the two menu source files")
    parser.add_argument("--rounds", type=lambda value: bounded_integer(value, 10), default=3)
    parser.add_argument("--iterations", type=lambda value: bounded_integer(value, 1_000_000), default=10_000)
    args = parser.parse_args()
    architecture = platform.machine()
    if sys.platform != "darwin" or architecture not in ("arm64", "x86_64"):
        raise RuntimeError("this native AppKit benchmark requires an Apple Silicon or Intel Mac")
    revision = command(["git", "rev-parse", "--verify", "--end-of-options", args.baseline + "^{commit}"],
                       "baseline resolution").decode().strip()
    swiftc = command(["xcrun", "--find", "swiftc"], "Swift discovery").decode().strip()
    sdk = command(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "SDK discovery").decode().strip()
    # Identical SDK, target, optimization and module flags for both variants.
    flags = ["-target", architecture + "-apple-macosx13.0", "-sdk", sdk, "-Onone", "-parse-as-library"]
    with tempfile.TemporaryDirectory(prefix="TokenStatMenu-synthetic-benchmark-") as temporary:
        workspace = Path(temporary)
        core = workspace / "core"
        core.mkdir()
        command([swiftc, *flags, "-module-name", "TokenStatCore", "-emit-module",
                 "-emit-module-path", str(core / "TokenStatCore.swiftmodule"), "-emit-library",
                 *(str(checked_source("TokenStatCore", name)) for name in CORE_FILES),
                 "-lsqlite3", "-o", str(core / "libTokenStatCore.dylib")], "isolated Core compilation")
        reports = {}
        for variant in ("baseline", "current"):
            directory = workspace / variant
            directory.mkdir()
            sources = []
            for name in APP_FILES:
                if variant == "baseline" and name in MENU_FILES:
                    path = directory / name
                    path.write_bytes(command(["git", "show", revision + ":Sources/TokenStatMenu/" + name],
                                             "baseline source extraction"))
                else:
                    path = checked_source("TokenStatMenu", name)
                sources.append(str(path))
            linkage = ["-I", str(core), "-L", str(core), "-lTokenStatCore",
                       "-Xlinker", "-rpath", "-Xlinker", str(core)]
            command([swiftc, *flags, "-enable-testing", "-D", "SWIFT_PACKAGE", "-module-name", "TokenStatMenu",
                     "-emit-module", "-emit-module-path", str(directory / "TokenStatMenu.swiftmodule"),
                     "-emit-library", *linkage, *sources, "-lsqlite3", "-o", str(directory / "libTokenStatMenu.dylib")],
                    "isolated menu compilation")
            binary = directory / "benchmark-menu"
            command([swiftc, *flags, "-I", str(directory), *linkage, str(ROOT / "script/BenchmarkMenu.swift"),
                     "-L", str(directory), "-lTokenStatMenu", "-Xlinker", "-rpath", "-Xlinker", str(directory),
                     "-o", str(binary)], "synthetic harness compilation")
            reports[variant] = []
            for round_index in range(args.rounds):
                output = command([str(binary), str(args.iterations)], "synthetic workload")
                if len(output) > 4096:
                    raise RuntimeError("unexpected synthetic workload output")
                report = json.loads(output)
                if (set(report) != {"iterations", "elapsedMS", "objectWillChange"}
                        or report["iterations"] != args.iterations
                        or type(report["objectWillChange"]) is not int
                        or not 0 <= report["objectWillChange"] <= args.iterations * 10
                        or type(report["elapsedMS"]) not in (int, float)
                        or not math.isfinite(report["elapsedMS"]) or report["elapsedMS"] < 0):
                    raise RuntimeError("unexpected synthetic measurement schema")
                reports[variant].append(report["elapsedMS"])
                print(json.dumps({"variant": variant, "round": round_index + 1, **report}, sort_keys=True), flush=True)
        print(json.dumps({"baselineMedianMS": statistics.median(reports["baseline"]),
                          "currentMedianMS": statistics.median(reports["current"])}, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired):
        print("Synthetic menu benchmark could not complete; verify local Git sources and the selected full Xcode toolchain.", file=sys.stderr)
        raise SystemExit(1) from None
```

### script/RenderAppIcon.swift

```swift
// Original code-native geometry. This renderer reads no images or user data.
// The reviewed PNG and native .icns are reproducible build-time assets only.
import AppKit
import Foundation

let output = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/AppIcon.png")
let dimension = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: dimension, pixelsHigh: dimension,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: dimension * 4, bitsPerPixel: 32)!
bitmap.bitmapData!.initialize(repeating: 0, count: bitmap.bytesPerRow * dimension)
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.shouldAntialias = true

// All colored pixels are clipped to this one native rounded rectangle.
let tile = NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832),
                        xRadius: 190, yRadius: 190)
tile.addClip()
let blue = NSColor(srgbRed: 0.20, green: 0.38, blue: 0.98, alpha: 1)
let violet = NSColor(srgbRed: 0.52, green: 0.27, blue: 0.95, alpha: 1)
NSGradient(starting: blue, ending: violet)!.draw(in: tile, angle: -45)

// A single opaque pulse and two token dots stay clear at small icon sizes.
NSColor.white.setStroke()
NSColor.white.setFill()
let pulse = NSBezierPath()
pulse.move(to: NSPoint(x: 320, y: 512))
pulse.curve(to: NSPoint(x: 450, y: 650), controlPoint1: NSPoint(x: 388, y: 512),
            controlPoint2: NSPoint(x: 396, y: 650))
pulse.curve(to: NSPoint(x: 562, y: 374), controlPoint1: NSPoint(x: 508, y: 650),
            controlPoint2: NSPoint(x: 504, y: 374))
pulse.curve(to: NSPoint(x: 704, y: 512), controlPoint1: NSPoint(x: 620, y: 374),
            controlPoint2: NSPoint(x: 632, y: 512))
pulse.lineWidth = 50
pulse.lineCapStyle = .round
pulse.lineJoinStyle = .round
pulse.stroke()
for centerX in [220.0, 804.0] {
    NSBezierPath(ovalIn: NSRect(x: centerX - 31, y: 481, width: 62, height: 62)).fill()
}
NSGraphicsContext.restoreGraphicsState()

// Guard the transparent margin without modifying any rendered pixels.
for y in 0..<dimension {
    for x in 0..<dimension where x < 95 || x > 929 || y < 95 || y > 929 {
        precondition(bitmap.colorAt(x: x, y: y)!.alphaComponent == 0, "Icon margin must stay transparent")
    }
}
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode original icon geometry")
}
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: output, options: .atomic)
print("Rendered original 1024px TokenStatMenu icon.")
```

### script/make_app_icon.sh

```bash
#!/bin/bash
# Render original native geometry, then build every native icon size.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SOURCE="$ROOT/Resources/AppIcon.png"
ICONSET="$ROOT/.build/AppIcon.iconset"
xcrun swift "$ROOT/script/RenderAppIcon.swift" "$SOURCE"
if [ "$(sips -g pixelWidth "$SOURCE" | awk '/pixelWidth/ {print $2}')" != "1024" ] || \
   [ "$(sips -g pixelHeight "$SOURCE" | awk '/pixelHeight/ {print $2}')" != "1024" ]; then
    echo "AppIcon.png must be the reviewed 1024 by 1024 PNG master." >&2
    exit 1
fi
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil --convert icns "$ICONSET" --output "$ROOT/Resources/AppIcon.icns"
echo "Built Resources/AppIcon.icns with macOS sips and iconutil."
```

### script/check_docs.py

```python
#!/usr/bin/env python3
"""Check only publication Markdown links; no network or third-party packages.

Supports inline/reference links, HTML img src, GitHub-style heading suffixes,
and explicit HTML ids. Fenced and inline code are excluded from link parsing.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import html
import posixpath
from pathlib import Path
import re
import tempfile
import unicodedata
from urllib.parse import unquote, urlsplit, urlunsplit


@dataclass(frozen=True)
class Link:
    destination: str
    start: int
    end: int
    line: int


def mask_fences(text: str) -> str:
    result = []
    fence = None
    for line in text.splitlines(keepends=True):
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line.rstrip("\r\n"))
        if fence:
            result.append(re.sub(r"[^\r\n]", " ", line))
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= fence[1] and not marker[2].strip():
                fence = None
        elif marker:
            fence = (marker[1][0], len(marker[1]))
            result.append(re.sub(r"[^\r\n]", " ", line))
        else:
            result.append(line)
    return "".join(result)


def mask_inline_code(text: str) -> str:
    # Equal-length backtick runs are paired; length and line numbers survive.
    chars = list(text)
    runs = list(re.finditer(r"`+", text))
    index = 0
    while index < len(runs):
        opening = runs[index]
        closing = next((j for j in range(index + 1, len(runs)) if len(runs[j][0]) == len(opening[0])), None)
        if closing is None:
            index += 1
            continue
        for position in range(opening.start(), runs[closing].end()):
            if chars[position] not in "\r\n":
                chars[position] = " "
        index = closing + 1
    return "".join(chars)


def normalized_label(value: str) -> str:
    return " ".join(value.split()).casefold()


def links_in(text: str) -> tuple[list[Link], list[tuple[int, str]]]:
    masked = mask_inline_code(mask_fences(text))
    links: list[Link] = []
    failures = []
    definitions = {}
    definition_spans = []
    pattern = r"(?m)^ {0,3}\[([^\]\n]+)\]:[ \t]*(?:<([^>\n]+)>|(\S+))"
    for match in re.finditer(pattern, masked):
        group = 2 if match[2] is not None else 3
        definitions.setdefault(normalized_label(match[1]), match[group])
        definition_spans.append((match.start(), match.end()))
        links.append(Link(match[group], match.start(group), match.end(group), text.count("\n", 0, match.start()) + 1))
    for match in re.finditer(r"!?\[([^\]\n]*)\]\(", masked):
        position = match.end()
        while position < len(masked) and masked[position].isspace():
            position += 1
        if position >= len(masked):
            continue
        start = position
        if masked[position] == "<":
            start += 1
            end = masked.find(">", start)
            if end < 0:
                continue
        else:
            depth = 0
            while position < len(masked):
                char = masked[position]
                if char == "\\" and position + 1 < len(masked):
                    position += 2
                    continue
                if char == "(":
                    depth += 1
                elif char == ")":
                    if depth == 0:
                        break
                    depth -= 1
                elif char.isspace() and depth == 0:
                    break
                position += 1
            end = position
        if end > start:
            links.append(Link(text[start:end], start, end, text.count("\n", 0, start) + 1))
    # Definitions themselves are checked above. Explicit unresolved references
    # are errors; bracketed prose without a reference definition is ordinary text.
    for match in re.finditer(r"!?\[([^\]\n]+)\](?:\[([^\]\n]*)\])?", masked):
        if any(a <= match.start() < b for a, b in definition_spans):
            continue
        if masked[match.end():].startswith("("):
            continue
        label = normalized_label(match[2] or match[1])
        if match[2] is not None and label not in definitions:
            failures.append((text.count("\n", 0, match.start()) + 1, "undefined reference link"))
    for match in re.finditer(r"(?is)<img\b[^>]*?\bsrc\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))", masked):
        group = next(i for i in (1, 2, 3) if match[i] is not None)
        links.append(Link(text[match.start(group):match.end(group)], match.start(group), match.end(group), text.count("\n", 0, match.start()) + 1))
    return sorted(set(links), key=lambda link: link.start), failures


def heading_anchors(text: str) -> set[str]:
    masked = mask_fences(text)
    used: set[str] = set()
    lines = masked.splitlines()
    for index, line in enumerate(lines):
        atx = re.match(r"^ {0,3}#{1,6}(?:[ \t]+|$)(.*)$", line)
        if atx:
            title = re.sub(r"[ \t]+#+[ \t]*$", "", atx[1])
        elif index + 1 < len(lines) and line.strip() and re.fullmatch(r" {0,3}(?:=+|-+)[ \t]*", lines[index + 1]):
            title = line.strip()
        else:
            continue
        title = html.unescape(re.sub(r"<[^>]*>", "", title))
        title = re.sub(r"!?\[([^]]*)\]\([^)]*\)", r"\1", title)
        title = re.sub(r"(?<!\w)(_{1,3}|\*{1,3})(.*?)\1(?!\w)", r"\2", title)
        title = title.replace("`", "").lower()
        base = "".join(char for char in title if char in " _-" or unicodedata.category(char)[0] in "LNM").replace(" ", "-")
        slug = base
        suffix = 0
        while slug in used:
            suffix += 1
            slug = f"{base}-{suffix}"
        used.add(slug)
    used.update(html.unescape(match[2]) for match in re.finditer(r"\b(?:id|name)\s*=\s*([\"'])(.*?)\1", masked, re.IGNORECASE))
    return used


def local_parts(destination: str):
    value = html.unescape(re.sub(r"\\([\\()<> #])", r"\1", destination))
    if value.startswith("//"):
        return None
    parts = urlsplit(value)
    return None if parts.scheme or parts.netloc else parts


def rebase_links(text: str, source: str, destination: str) -> str:
    """Rebase copied prose without editing code fences or external URLs."""
    links, _ = links_in(text)
    for link in reversed(links):
        parts = local_parts(link.destination)
        if parts is None:
            continue
        target = posixpath.normpath(posixpath.join(posixpath.dirname(source), parts.path or posixpath.basename(source)))
        path = posixpath.relpath(target, posixpath.dirname(destination) or ".")
        replacement = urlunsplit(("", "", path, parts.query, parts.fragment))
        text = text[:link.start] + replacement + text[link.end:]
    return text


def check_documents(root: Path, names: list[str], allowed: set[str]) -> list[tuple[str, int, str]]:
    root = root.resolve()
    failures = []
    cache = {}
    for name in names:
        path = root / name
        if path.is_symlink() or not path.resolve().is_relative_to(root) or not path.is_file():
            failures.append((name, 0, "missing or unsafe documentation file"))
            continue
        text = path.read_text(encoding="utf-8")
        links, parsing_failures = links_in(text)
        failures.extend((name, line, error) for line, error in parsing_failures)
        for link in links:
            try:
                parts = local_parts(link.destination)
            except ValueError:
                failures.append((name, link.line, "malformed link destination"))
                continue
            if parts is None:
                continue
            local_path = unquote(parts.path)
            target = (path.parent / local_path if local_path else path).resolve()
            if local_path.startswith("/") or not target.is_relative_to(root):
                failures.append((name, link.line, "local link escapes publication root"))
                continue
            if not target.exists():
                failures.append((name, link.line, "missing local link target"))
                continue
            if target.is_dir():
                if parts.fragment:
                    failures.append((name, link.line, "directory link cannot have a heading anchor"))
                continue
            target_name = target.relative_to(root).as_posix()
            if target_name not in allowed:
                failures.append((name, link.line, "link target is not on publication allowlist"))
                continue
            if parts.fragment and target.suffix.lower() == ".md":
                if target not in cache:
                    cache[target] = heading_anchors(target.read_text(encoding="utf-8"))
                if unquote(parts.fragment) not in cache[target]:
                    failures.append((name, link.line, "missing local heading anchor"))
    return failures


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="tokenstat-doc-links-fixture-") as temporary:
        root = Path(temporary)
        (root / "docs").mkdir()
        (root / "Assets").mkdir()
        (root / "Assets/icon.png").write_bytes(b"synthetic-file-fixture")
        (root / "docs/Guide.md").write_text("# Repeated\n# Repeated\n# Repeated-1\n# 中文标题\n", encoding="utf-8")
        allowed = {"README.md", "docs/Guide.md", "Assets/icon.png"}
        good = '# Home\n[guide](docs/Guide.md#repeated-1)\n[ref][guide]\n[guide]: docs/Guide.md#中文标题\n<img src="Assets/icon.png">\n`[literal](missing.md)`\n```md\n[ignored](../../outside)\n```\n'
        (root / "README.md").write_text(good, encoding="utf-8")
        assert not check_documents(root, ["README.md", "docs/Guide.md"], allowed)
        assert heading_anchors((root / "docs/Guide.md").read_text()) == {"repeated", "repeated-1", "repeated-1-1", "中文标题"}
        for link, expected in [("missing.md", "missing local link target"), ("docs/Guide.md#absent", "missing local heading anchor"), ("../../outside.md", "local link escapes publication root")]:
            (root / "README.md").write_text(f"[bad]({link})\n", encoding="utf-8")
            assert any(error == expected for _, _, error in check_documents(root, ["README.md"], allowed)), expected
        copied = rebase_links(good, "README.md", "docs/FULL_SOURCE.md")
        assert "[guide](Guide.md#repeated-1)" in copied and '<img src="../Assets/icon.png">' in copied
        assert "[guide]: Guide.md#中文标题" in copied
        assert "```md\n[ignored](../../outside)\n```" in copied
        self_link = "[home](#home) and [web](https://example.test/page#anchor)"
        rebased = rebase_links(self_link, "README.md", "docs/FULL_SOURCE.md")
        assert rebased == "[home](../README.md#home) and [web](https://example.test/page#anchor)"
        assert "`[literal](missing.md)`" in copied
    print("PASS: synthetic Markdown link, reference, HTML image, fence, duplicate-heading, missing-target, missing-anchor and escape fixtures")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true", help="Run synthetic positive/negative fixtures before checking publication docs")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    from package_source import PUBLIC_FILES, ROOT
    names = [name for name in PUBLIC_FILES if name.lower().endswith(".md")]
    failures = check_documents(ROOT, names, set(PUBLIC_FILES))
    for name, line, reason in failures:
        print(f"FAIL {name}:{line}: {reason}")
    if failures:
        return 1
    print(f"PASS: local links and anchors in {len(names)} publication Markdown files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
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
icon_ref = obj("resource:AppIcon.icns", 'isa = PBXFileReference; lastKnownFileType = image.icns; path = "Resources/AppIcon.icns"; sourceTree = "<group>";')
resource_files.append(icon_ref)
icon_build = obj("resource-build:AppIcon.icns", f"isa = PBXBuildFile; fileRef = {icon_ref};")
main = obj("main", f'isa = PBXGroup; children = {refs(groups + resource_files + [products])}; sourceTree = "<group>";')
source_phase = obj("sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(sources)}; runOnlyForDeploymentPostprocessing = 0;")
framework_phase = obj("frameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
resource_phase = obj("resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({icon_build},); runOnlyForDeploymentPostprocessing = 0;")
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
# Bind the app target explicitly. Relying on an inferred user scheme caused
# Xcode's destination preflight to report an empty supported-platform set.
scheme_directory = directory / "xcshareddata" / "xcschemes"
scheme_directory.mkdir(parents=True, exist_ok=True)
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="TokenStatMenu.app" BlueprintName="TokenStatMenu" ReferencedContainer="container:TokenStatMenu.xcodeproj"/>
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="TokenStatMenu.app" BlueprintName="TokenStatMenu" ReferencedContainer="container:TokenStatMenu.xcodeproj"/>
    </BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
(scheme_directory / "TokenStatMenu.xcscheme").write_text(scheme)
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
from check_docs import rebase_links

ROOT = Path(__file__).resolve().parents[1]
PUBLIC_FILES = [
    ".gitignore", ".github/workflows/ci.yml", "Package.swift", "Package.resolved", "README.md", "LICENSE", "PRIVACY.md",
    "Sources/TokenStatCore/Configuration.swift", "Sources/TokenStatCore/GatewayDiscovery.swift",
    "Sources/TokenStatCore/HTTPDecoder.swift", "Sources/TokenStatCore/LocalCodexUsageReader.swift", "Sources/TokenStatCore/MetricsEngine.swift",
    "Sources/TokenStatCore/ProxyServer.swift", "Sources/TokenStatCore/Quota.swift",
    "Sources/TokenStatCore/WindowQuota.swift", "Sources/TokenStatCore/RateWindow.swift", "Sources/TokenStatCore/StreamParser.swift",
    "Sources/TokenStatCore/TokenHubQuota.swift", "Sources/TokenStatCore/TokenHubAXScanning.swift", "Sources/TokenStatCore/TokenHubDirectQuota.swift",
    "Sources/TokenStatMenu/AppModel.swift", "Sources/TokenStatMenu/DashboardView.swift",
    "Sources/TokenStatMenu/SettingsView.swift",
    "Sources/TokenStatMenu/StatusBarController.swift", "Sources/TokenStatMenu/Storage.swift",
    "Sources/TokenStatMenu/TokenStatMenuApp.swift", "Sources/TokenStatMenu/PanelStyle.swift", "Sources/TokenStatMenu/WindowQuotaCard.swift", "Sources/TokenStatMenu/TokenHubAXReader.swift", "Sources/TokenStatMenu/TokenHubQuotaCard.swift",
    "Resources/Info.plist", "Resources/config.example.plist", "Resources/AppIcon.png", "Resources/AppIcon.icns", "TokenStatMenu.xcodeproj/project.pbxproj",
    "TokenStatMenu.xcodeproj/xcshareddata/xcschemes/TokenStatMenu.xcscheme",
    "Tests/TokenStatCoreTests/CoreChecks.swift", "Tests/TokenStatCoreTests/GatewayDiscoveryChecks.swift", "Tests/TokenStatCoreTests/WindowQuotaChecks.swift", "Tests/TokenStatCoreTests/LocalCodexUsageChecks.swift", "Tests/TokenStatCoreTests/DirectQuotaChecks.swift",
    "Tests/TokenStatUITests/TokenStatUISnapshotTests.swift", "Tests/TokenStatCoreTests/TokenHubQuotaChecks.swift", "Tests/TokenStatUITests/TokenHubQuotaStateTests.swift", "Tests/TokenStatUITests/SeasunStartupContractTests.swift", "Tests/TokenStatUITests/DashboardHistoryTests.swift",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testDashboardLightAndDark.dashboard-light.png",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testDashboardLightAndDark.dashboard-dark.png",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testSettingsLightAndDark.settings-light.png",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testSettingsLightAndDark.settings-dark.png",
    "script/build_and_run.sh", "script/test.sh", "script/mock_server.py", "script/integration.py", "script/release_assets.py", "script/test_release_assets.py",
    "script/BenchmarkMenu.swift", "script/benchmark_menu.py", "script/RenderAppIcon.swift", "script/make_app_icon.sh", "script/check_docs.py", "script/generate_xcode_project.py", "script/render_preview.py", "script/RenderPreview.swift", "script/package_source.py", "script/check_public_content.py", "script/diagnose_swift_toolchain.py", "script/run_settings_ax_check.sh", "script/test_phase2_diagnostics.py",
    "docs/README.md", "docs/wiki/Home.md", "docs/wiki/安装与使用.md", "docs/wiki/统计口径.md",
    "docs/wiki/常见问题.md", "docs/wiki/编译指南.md", "docs/wiki/测试指南.md", "docs/wiki/命令行参数.md",
    "docs/wiki/CI-CD.md", "docs/wiki/贡献指南.md",
    "docs/superpowers/specs/2026-10-18-accuracy-and-validation-optimization-design.md",
    "docs/superpowers/plans/2026-10-18-accuracy-and-validation-optimization.md",
    "docs/PERFORMANCE.md", "docs/DESIGN.md", "docs/IMPLEMENTATION.md", "docs/CONFIGURATION.md", "docs/VALIDATION.md", "docs/UI_TESTING.md", "docs/FULL_SOURCE.md",
]


def source_document():
    readme = (ROOT / "README.md").read_text()
    architecture = readme.split("## 整体架构\n", 1)[1].split("## 文件与职责", 1)[0]
    architecture = rebase_links(architecture, "README.md", "docs/FULL_SOURCE.md")
    parts = ["# TokenStatMenu 完整源码\n\n## 项目整体架构\n", architecture, "\n## 分文件完整源码\n"]
    languages = {".swift": "swift", ".plist": "xml", ".pbxproj": "text", ".xcscheme": "xml", ".py": "python", ".sh": "bash", ".yml": "yaml"}
    for name in PUBLIC_FILES:
        path = ROOT / name
        if path.suffix not in languages:
            continue
        parts += [f"\n### {name}\n\n```{languages[path.suffix]}\n", path.read_text().rstrip(), "\n```\n"]
    usage = rebase_links(readme.split("## 构建与运行\n", 1)[1], "README.md", "docs/FULL_SOURCE.md")
    parts += ["\n## 编译与使用\n\n", usage]
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
import hashlib
import struct
import re
import subprocess
from pathlib import Path
from package_source import PUBLIC_FILES, ROOT

SYNTHETIC_PNG_SHA256 = {
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testDashboardLightAndDark.dashboard-light.png": "ead24ba5ff05e81ddb9f042e1e601725a052e3835ca5c8b980ab70ce7f516617",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testDashboardLightAndDark.dashboard-dark.png": "9819e254364e4ba2bc5c60ff2e4574fa4828264aa341b05920349333b253b91d",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testSettingsLightAndDark.settings-light.png": "00285b94a18af9ca7ac7220e0f8eb08932916868756e3de4807a6633e77611a8",
    "Tests/TokenStatUITests/__Snapshots__/TokenStatUISnapshotTests/testSettingsLightAndDark.settings-dark.png": "66b9653affa7b809eaa53f2c6e16f706830c3401f5377d5b441fa208be434c53",
}


# Original code-native assets, independently reviewed at 1024/64/32px.
# No wildcard, file extension, or directory grants a binary exception.
REVIEWED_ICON_ASSETS = {
    "Resources/AppIcon.png": ("png-rgba-1024", "664e54034f49380b3dc60d72841ec8c7d9bae142e5e20f154c8e5dfcbae1e16f"),
    "Resources/AppIcon.icns": ("icns", "edfc3aa520be04f987cc6c8a273995f57bafca68603d89f8265c640d0009e980"),
}


def reviewed_icon_failure(name: str, data: bytes):
    format_name, digest = REVIEWED_ICON_ASSETS[name]
    if format_name == "png-rgba-1024":
        if (len(data) < 33 or not data.startswith(b"\x89PNG\r\n\x1a\n")
                or data[8:16] != b"\x00\x00\x00\rIHDR"
                or struct.unpack(">II", data[16:24]) != (1024, 1024)
                or data[24:26] != b"\x08\x06"):
            return "reviewed icon PNG format/dimensions/alpha mismatch"
    elif format_name == "icns":
        if len(data) < 8 or data[:4] != b"icns" or struct.unpack(">I", data[4:8])[0] != len(data):
            return "reviewed icon ICNS signature/length mismatch"
    else:
        return "unsupported reviewed icon format"
    if hashlib.sha256(data).hexdigest() != digest:
        return "reviewed icon hash mismatch"
    return None


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
    fixture_files = {"Tests/TokenStatCoreTests/GatewayDiscoveryChecks.swift", "Tests/TokenStatCoreTests/DirectQuotaChecks.swift", "docs/FULL_SOURCE.md"}
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
        if name in REVIEWED_ICON_ASSETS:
            reason = reviewed_icon_failure(name, data)
            if reason:
                failures.append((name, 0, reason))
            continue
        if name in SYNTHETIC_PNG_SHA256:
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

### script/diagnose_swift_toolchain.py

```python
#!/usr/bin/env python3
"""Run a read-only CLT/Xcode comparison without publishing raw tool output."""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import re
from typing import Sequence


ROOT = Path(__file__).resolve().parents[1]
SEARCH_PATH_WARNING = re.compile(
    r"ld: warning: search path '(/Library/Developer/CommandLineTools/Developer/[^']*)' not found",
)


@dataclass(frozen=True)
class WarningClassification:
    kind: str
    count: int
    is_build_failure: bool


def classify_linker_warnings(output: str) -> WarningClassification:
    """Classify only the known missing CLT search-path linker diagnostics."""
    count = len(SEARCH_PATH_WARNING.findall(output))
    if count:
        return WarningClassification("clt_search_path_warning", count, False)
    return WarningClassification("none", 0, False)


def _safe_env(developer_dir: str | None) -> dict[str, str]:
    allowed = {"HOME", "TMPDIR", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL"}
    env = {key: value for key, value in os.environ.items() if key in allowed}
    for key in ("SDKROOT", "LIBRARY_PATH", "FRAMEWORK_PATH", "LDFLAGS", "CPATH", "DEVELOPER_DIR"):
        env.pop(key, None)
    if developer_dir:
        env["DEVELOPER_DIR"] = developer_dir
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    return env


def _run(args: Sequence[str], cwd: Path, env: dict[str, str], timeout: int, log: Path) -> tuple[int, str, float]:
    started = time.monotonic()
    try:
        completed = subprocess.run(
            list(args), cwd=cwd, env=env, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, timeout=timeout, check=False,
        )
        output = completed.stdout or ""
        code = completed.returncode
    except subprocess.TimeoutExpired as error:
        output = error.stdout if isinstance(error.stdout, str) else ""
        code = 124
    log.write_text(output, encoding="utf-8", errors="replace")
    return code, output, round(time.monotonic() - started, 3)


def _digest(path: Path) -> str | None:
    if not path.is_file():
        return None
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _version(args: Sequence[str], env: dict[str, str], scratch: Path, timeout: int) -> tuple[int, str]:
    code, output, _ = _run(args, ROOT, env, timeout, scratch / "version.log")
    first = next((line.strip() for line in output.splitlines() if line.strip()), "unknown")
    if first.startswith("xcode-select: error"):
        first = "xcodebuild unavailable under selected toolchain"
    return code, first[:160]


def _run_one(kind: str, project: Path, timeout: int) -> dict[str, object]:
    developer_dir = "/Applications/Xcode.app/Contents/Developer" if kind == "xcode" else None
    env = _safe_env(developer_dir)
    scratch = Path(tempfile.mkdtemp(prefix="tokenstat-toolchain-"))
    (scratch / "home").mkdir()
    (scratch / "tmp").mkdir()
    (scratch / "xdg-config").mkdir()
    (scratch / "xdg-data").mkdir()
    env["HOME"] = str(scratch / "home")
    env["TMPDIR"] = str(scratch / "tmp")
    env["XDG_CONFIG_HOME"] = str(scratch / "xdg-config")
    env["XDG_DATA_HOME"] = str(scratch / "xdg-data")
    original_lock = _digest(project / "Package.resolved")
    try:
        swift_code, swift_version = _version(["swift", "--version"], env, scratch, timeout)
        sdk_code, sdk_path = _version(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env, scratch, timeout)
        xcode_code, xcode_version = _version(["xcodebuild", "-version"], env, scratch, timeout)
        hello = scratch / "hello"
        hello.mkdir()
        init_code, _, _ = _run(
            ["swift", "package", "init", "--type", "executable"], hello, env, timeout, scratch / "hello-init.log"
        )
        hello_build_code = hello_run_code = 125
        hello_classification = WarningClassification("command_not_run", 0, True)
        hello_seconds = 0.0
        if init_code == 0:
            hello_build_code, hello_output, hello_seconds = _run(
                ["swift", "build", "-v"],
                hello, env, timeout, scratch / "hello-build.log",
            )
            hello_classification = classify_linker_warnings(hello_output)
            if hello_build_code == 0:
                hello_run_code, _, _ = _run(
                    ["swift", "run", "-v"],
                    hello, env, timeout, scratch / "hello-run.log",
                )
        project_copy = scratch / "project"
        shutil.copytree(
            project, project_copy,
            ignore=shutil.ignore_patterns(
                ".git", ".build", "dist", ".integration", ".xcodebuild", "__pycache__",
                ".DS_Store", "config.plist", "auth.json", ".env", ".env.*", "*.jsonl",
            ),
            symlinks=True,
        )
        if any(path.is_symlink() for path in project_copy.rglob("*")):
            raise ValueError("symlink in controlled checkout")
        lock_before = _digest(project_copy / "Package.resolved")
        project_build_code, project_output, project_seconds = _run(
            ["swift", "build", "-v", "--force-resolved-versions", "--product", "TokenStatMenu"],
            project_copy, env, timeout, scratch / "project-build.log",
        )
        project_classification = classify_linker_warnings(project_output)
        return {
            "toolchain": kind,
            "developer_dir_set": bool(developer_dir),
            "swift_exit": swift_code,
            "swift_version": swift_version,
            "sdk_exit": sdk_code,
            "sdk_version": Path(sdk_path).name if sdk_path and sdk_path != "unknown" else sdk_path,
            "xcode_exit": xcode_code,
            "xcode_version": xcode_version,
            "hello": {"init_exit": init_code, "build_exit": hello_build_code, "run_exit": hello_run_code,
                       "warning": asdict(hello_classification), "seconds": hello_seconds},
            "project": {"build_exit": project_build_code, "warning": asdict(project_classification),
                        "seconds": project_seconds},
            "package_resolved_before_sha256": lock_before,
            "package_resolved_after_sha256": _digest(project_copy / "Package.resolved"),
            "package_resolved_checkout_sha256": original_lock,
            "status": "success" if (
                swift_code == 0 and sdk_code == 0 and project_build_code == 0
                and init_code == 0 and hello_build_code == 0 and hello_run_code == 0
                and (kind == "clt" or xcode_code == 0)
                and original_lock == lock_before == _digest(project_copy / "Package.resolved")
            ) else "failed",
        }
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toolchain", choices=("clt", "xcode", "both"), default="both")
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--timeout", type=int, default=90)
    args = parser.parse_args(argv)
    if args.timeout < 5 or args.timeout > 600:
        parser.error("--timeout must be between 5 and 600 seconds")
    if args.project.is_symlink():
        parser.error("--project must not be a symbolic link")
    project = args.project.resolve()
    if not (project / "Package.swift").is_file():
        parser.error("--project must point to a Swift package checkout")
    kinds = ("clt", "xcode") if args.toolchain == "both" else (args.toolchain,)
    try:
        reports = [_run_one(kind, project, args.timeout) for kind in kinds]
    except (OSError, ValueError, subprocess.SubprocessError):
        print(json.dumps({"kind": "upstream_toolchain_diagnostic", "status": "failed", "error": "diagnostic_setup_failed"}))
        return 1
    print(json.dumps({"kind": "upstream_toolchain_diagnostic", "reports": reports}, ensure_ascii=False, sort_keys=True))
    return 0 if all(report["status"] == "success" for report in reports) else 1


if __name__ == "__main__":
    raise SystemExit(main())
```

### script/run_settings_ax_check.sh

```bash
#!/bin/bash
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: run_settings_ax_check.sh --project PROJECT --scheme SCHEME \
  --fixture-manifest MANIFEST --fixture-bundle BUNDLE [options]

Runs the private C27 macOS AX runner with full Xcode. It validates the frozen
fixture manifest and project source before build-for-testing, then runs
 test-without-building and verifies the transient xcresult summary. An
automation-mode timeout is reported as automation_environment_blocked and keeps
its non-zero exit code; no result is converted to a pass.

Options:
  --project PATH       Private C27 Xcode project (required)
  --scheme NAME        Private C27 scheme (required)
  --fixture-manifest PATH  Frozen C27 manifest (required)
  --fixture-bundle PATH    Frozen C27 fixture bundle (required)
  --timeout SECONDS    Per-command timeout, 30..600 (default: 120)
  --help               Show this help
USAGE
}

configuration_error() {
  echo '{"classification":"configuration_error","exit":2}'
  exit 2
}

project=""
scheme=""
fixture_manifest=""
fixture_bundle=""
timeout_seconds=120
while (($#)); do
  case "$1" in
    --project)
      (($# >= 2)) || configuration_error
      project="$2"; shift 2 ;;
    --scheme)
      (($# >= 2)) || configuration_error
      scheme="$2"; shift 2 ;;
    --fixture-manifest)
      (($# >= 2)) || configuration_error
      fixture_manifest="$2"; shift 2 ;;
    --fixture-bundle)
      (($# >= 2)) || configuration_error
      fixture_bundle="$2"; shift 2 ;;
    --derived-data) configuration_error ;;
    --timeout)
      (($# >= 2)) || configuration_error
      timeout_seconds="$2"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) configuration_error ;;
  esac
done

[[ -n "$project" && -n "$scheme" && -n "$fixture_manifest" && -n "$fixture_bundle" ]] || configuration_error
[[ -n "${DEVELOPER_DIR:-}" ]] || configuration_error
[[ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" && -x "/usr/bin/xcrun" ]] || configuration_error
if ! [[ "$timeout_seconds" =~ ^[0-9]+$ ]]; then configuration_error; fi
if (( timeout_seconds < 30 )); then configuration_error; fi
if (( timeout_seconds > 600 )); then configuration_error; fi

[[ ! -L "$project" && ! -L "$fixture_manifest" && ! -L "$fixture_bundle" ]] || configuration_error
project_real="$(cd "$project" 2>/dev/null && pwd -P)" || configuration_error
bundle_real="$(cd "$fixture_bundle" 2>/dev/null && pwd -P)" || configuration_error
[[ -f "$project_real/project.pbxproj" ]] || configuration_error
scheme_file="$project_real/xcshareddata/xcschemes/$scheme.xcscheme"
[[ -f "$scheme_file" ]] || configuration_error
project_parent="$(dirname "$project_real")"
test_source="$project_parent/Tests/NativeSettingsAXTests.swift"
[[ -f "$test_source" ]] || configuration_error
# Bind the wrapper to the reviewed C27 project/test shape, not an arbitrary UI test.
grep -Fq 'C27SettingsAXUITests' "$project_real/project.pbxproj" || configuration_error
grep -Fq 'NativeSettingsAXTests' "$test_source" || configuration_error
grep -Fq 'XCUIApplication(url:' "$test_source" || configuration_error
grep -Fq -- '--test-fixture' "$test_source" || configuration_error
grep -Fq -- '--disable-background-services' "$test_source" || configuration_error
grep -Fq 'A07' "$test_source" || configuration_error
[[ "$(shasum -a 256 "$project_real/project.pbxproj" | awk '{print $1}')" == "0ab0c1958fb718cc572519ac451dcc1c78227c4a7093dff42451b22856593d5f" ]] || configuration_error
[[ "$(shasum -a 256 "$scheme_file" | awk '{print $1}')" == "d8e2920aaced40f6b47fb1267015b2fd87c67eb5996f3d56b6064493d54fede1" ]] || configuration_error
[[ "$(shasum -a 256 "$test_source" | awk '{print $1}')" == "4b03e8190cb510ea5904bb12a94c8bd8c71f922cba509f0950c9c721760dfc78" ]] || configuration_error

python3 - "$fixture_manifest" "$fixture_bundle" <<'PY' || exit 2
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

manifest_input = Path(sys.argv[1])
bundle_input = Path(sys.argv[2])
if manifest_input.is_symlink() or bundle_input.is_symlink():
    raise SystemExit(2)
manifest_bytes = manifest_input.read_bytes()
if hashlib.sha256(manifest_bytes).hexdigest() != "be265d66e7322bb9a790b6ac2b99532ede0d274182c1b143895785dd46e99c93":
    raise SystemExit(2)
manifest_path = manifest_input.resolve()
bundle = bundle_input.resolve()
try:
    manifest = json.loads(manifest_bytes.decode("utf-8"))
    expected_files = manifest["bundleFiles"]
    if manifest.get("syntheticOnly") is not True:
        raise ValueError
    if Path(manifest["bundlePath"]).resolve() != bundle:
        raise ValueError
    if manifest["bundleIdentifier"] != "com.tupig.TokenStatMenu.AXFixture.c23.jk1svxze":
        raise ValueError
    if manifest["requiredArguments"] != ["--test-fixture", "--disable-background-services"]:
        raise ValueError
    if manifest.get("privateHarnessSHA256") != "b0fa06419695bd0b1e2e0c34989b2081a75e2d5d63883f8a29bb651d03f97e53":
        raise ValueError
    if manifest.get("sourceFiles", {}).get("Sources/TokenStatMenu/SettingsView.swift") != "dae957654ee285b45825e6f4afacdebf76b2f9790dcb0d42f963f3709f161bb3":
        raise ValueError
    if set(expected_files) != {"Contents/Info.plist", "Contents/MacOS/TokenStatAXFixture", "Contents/_CodeSignature/CodeResources"}:
        raise ValueError
    if bundle.is_symlink() or not bundle.is_dir():
        raise ValueError
    found_files = set()
    found_dirs = set()
    for root, dirs, files in os.walk(bundle, followlinks=False):
        root_path = Path(root)
        for name in dirs:
            path = root_path / name
            if path.is_symlink():
                raise ValueError
            found_dirs.add(str(path.relative_to(bundle)))
        for name in files:
            path = root_path / name
            if path.is_symlink():
                raise ValueError
            rel = str(path.relative_to(bundle))
            record = expected_files.get(rel)
            if record is None:
                raise ValueError
            data = path.read_bytes()
            mode = oct(path.stat().st_mode & 0o777)
            if len(data) != record["bytes"] or hashlib.sha256(data).hexdigest() != record["sha256"] or mode != record["mode"]:
                raise ValueError
            found_files.add(rel)
    if found_files != set(expected_files) or found_dirs != {"Contents", "Contents/MacOS", "Contents/_CodeSignature"}:
        raise ValueError
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != manifest["bundleIdentifier"] or info.get("CFBundleExecutable") != "TokenStatAXFixture":
        raise ValueError
    verified = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if verified.returncode != 0:
        raise ValueError
except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(2)
PY

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/tokenstatmenu-ax-check.XXXXXX")" || exit 2
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
derived_data="$tmp_dir/DerivedData"
mkdir -p "$derived_data"

run_bounded() {
  local log="$1"
  shift
  "$DEVELOPER_DIR/usr/bin/xcodebuild" "$@" >"$log" 2>&1 &
  local child=$!
  local waited=0
  while kill -0 "$child" 2>/dev/null; do
    if (( waited >= timeout_seconds )); then
      kill "$child" 2>/dev/null || true
      wait "$child" 2>/dev/null || true
      return 124
    fi
    sleep 1
    ((waited += 1))
  done
  wait "$child"
}

build_log="$tmp_dir/build.log"
run_bounded "$build_log" -project "$project_real" -scheme "$scheme" -configuration Debug \
  -derivedDataPath "$derived_data" -destination 'platform=macOS' -parallel-testing-enabled NO build-for-testing
build_exit=$?
if (( build_exit != 0 )); then
  printf '{"classification":"build_failed","build_exit":%d,"test_exit":null,"fixture_manifest_verified":true,"fixture_bundle_identity_verified":true,"a01_a07_executed":false}\n' "$build_exit"
  exit "$build_exit"
fi

test_log="$tmp_dir/test.log"
run_bounded "$test_log" -project "$project_real" -scheme "$scheme" -configuration Debug \
  -derivedDataPath "$derived_data" -destination 'platform=macOS' -parallel-testing-enabled NO \
  -only-testing:C27SettingsAXUITests/NativeSettingsAXTests/testFrozenSettingsExposeExpectedAXControls \
  test-without-building -resultBundlePath "$tmp_dir/result.xcresult"
test_exit=$?

if grep -q 'Timed out while enabling automation mode' "$test_log" || grep -q 'automation mode' "$test_log" || grep -q 'existingInstance' "$test_log"; then
  classification="automation_environment_blocked"
else
  summary_class="failed"
  summary_file="$tmp_dir/summary.json"
  if [[ -f "$tmp_dir/result.xcresult" ]] && "/usr/bin/xcrun" xcresulttool get test-results summary --path "$tmp_dir/result.xcresult" --format json >"$summary_file" 2>/dev/null; then
    summary_class="$(python3 - "$summary_file" <<'PY'
import json
import sys
summary = json.loads(open(sys.argv[1], encoding="utf-8").read())
passed = summary.get("totalTestCount") == 1 and summary.get("passedTests") == 1 and summary.get("failedTests") == 0 and summary.get("skippedTests") == 0
failures = " ".join(item.get("failureText", "") for item in summary.get("testFailures", []))
if ("automation" in failures.lower() or "runner failed to initialize" in failures.lower()
        or "existinginstance" in failures.lower()):
    print("automation_environment_blocked")
elif passed:
    print("passed")
else:
    print("failed")
PY
    )"
  fi
  if [[ "$summary_class" == automation_environment_blocked ]]; then
    classification="automation_environment_blocked"
  elif (( test_exit == 65 )); then
    classification="automation_environment_blocked"
  elif [[ "$summary_class" == passed && "$test_exit" == 0 ]]; then
    classification="passed"
  else
    classification="test_failed"
  fi
fi

if [[ "$classification" == passed ]]; then executed=true; else executed=false; fi
printf '{"classification":"%s","build_exit":%d,"test_exit":%d,"fixture_manifest_verified":true,"fixture_bundle_identity_verified":true,"a01_a07_executed":%s}\n' \
  "$classification" "$build_exit" "$test_exit" "$executed"
if [[ "$classification" == passed ]]; then exit 0; fi
if (( test_exit != 0 )); then exit "$test_exit"; fi
exit 1
```

### script/test_phase2_diagnostics.py

```python
#!/usr/bin/env python3
"""Contract tests for the non-bypassing phase-two diagnostics."""
from __future__ import annotations

import importlib.util
import subprocess
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "script/diagnose_swift_toolchain.py"


def load_diagnostic_module():
    spec = importlib.util.spec_from_file_location("diagnose_swift_toolchain", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError("diagnostic module must be importable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class PhaseTwoDiagnosticTests(unittest.TestCase):
    def test_missing_clt_search_paths_are_reported_as_nonfatal(self):
        module = load_diagnostic_module()
        result = module.classify_linker_warnings(
            "ld: warning: search path '/Library/Developer/CommandLineTools/Developer/usr/lib' not found\n"
        )
        self.assertEqual(result.kind, "clt_search_path_warning")
        self.assertEqual(result.count, 1)
        self.assertFalse(result.is_build_failure)

    def test_verbose_swiftpm_warning_is_not_linker_warning(self):
        module = load_diagnostic_module()
        result = module.classify_linker_warnings(
            "warning: 'TokenStatMenu': manifest compiler invocation\n"
        )
        self.assertEqual(result.kind, "none")
        self.assertEqual(result.count, 0)

    def test_runner_help_describes_blocked_exit(self):
        runner = ROOT / "script/run_settings_ax_check.sh"
        completed = subprocess.run([str(runner), "--help"], text=True, capture_output=True)
        self.assertEqual(completed.returncode, 0)
        self.assertIn("automation_environment_blocked", completed.stdout)
        self.assertIn("build-for-testing", completed.stdout)
        self.assertIn("test-without-building", completed.stdout)

    def test_runner_rejects_missing_value_without_hanging(self):
        runner = ROOT / "script/run_settings_ax_check.sh"
        completed = subprocess.run(
            [str(runner), "--project"], text=True, capture_output=True, timeout=1,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn('"classification":"configuration_error"', completed.stdout)


if __name__ == "__main__":
    unittest.main()
```

## 编译与使用


在仓库根目录执行。构建不会按进程名关闭其他应用，打开新实例前应先退出旧版，避免误看另一份构建。

| 命令 | 结果 |
| --- | --- |
| `./script/build_and_run.sh --build-only` | 构建本机架构 Debug `.app`，不启动应用 |
| `./script/build_and_run.sh --universal` | 构建 arm64 与 x86_64 Release 通用 `.app`，不启动应用 |
| `./script/build_and_run.sh` | 构建并运行本机架构 Debug `.app` |
| `./script/build_and_run.sh --release` | 构建后运行本机架构 Release `.app`，不是只编译模式 |
| `swift build --force-resolved-versions -c release --product TokenStatMenu` | 按审核锁文件编译 SwiftPM 可执行目标；不会单独完成 `.app` 资源打包 |

也可打开 `TokenStatMenu.xcodeproj`，选择 TokenStatMenu Scheme 和 My Mac 编译。若默认开发目录仍指向 Command Line Tools，可只为当前命令选择完整 Xcode：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project TokenStatMenu.xcodeproj \
  -scheme TokenStatMenu \
  -configuration Release build
```

更多环境准备、图标资源、双架构、构建身份和常见错误见 [编译指南](wiki/编译指南.md)；发布前检查与签名限制见 [CI/CD](wiki/CI-CD.md)。

SwiftPM 构建和测试使用 `--force-resolved-versions`，只接受已提交的 `Package.resolved`。测试依赖在不同 Swift 工具链下会选择不同的兼容清单，锁文件包含这两条依赖图的审核版本；缺少必要 pin 或版本冲突时应停止，不能通过自动解析、构建后恢复锁文件或跳过源码一致性检查来掩盖。正式 App 的运行时依赖不因此增加。

## 验证与维护

```bash
# 纯合成核心检查
swift run --force-resolved-versions TokenStatCoreChecks

# 原生 XCTest 与界面回归
swift test --force-resolved-versions

# 核心、只构建及隔离启动集成
./script/test.sh

# 更新完整源码文档，并按白名单打包源码
python3 script/package_source.py

# 检查文档链接与公开内容
python3 script/check_docs.py
python3 script/check_public_content.py

# 发布资产合同（合成 Git/ZIP 与隔离的本机签名样本）
python3 -B script/test_release_assets.py
```

正式版本推送 `vMAJOR.MINOR.PATCH` 标签后，由 [macOS CI 与发布工作流](../.github/workflows/ci.yml) 检查版本、源码提交和 `main` 归属，构建 arm64 + x86_64 Universal App。该单一工作流也在 `main` push 和 pull request 上运行只读检查；只有 canonical 仓库的版本标签会在构建成功后进入发布 job。当前 1.1.4 历史合同发布四项资产；从 1.1.5/build7 起，目标是五项资产：应用 ZIP、源码 ZIP、同一 App 的 Universal DMG、`release-manifest.json` 和 `SHA256SUMS`。构建检查与写入 Release 的 job 分开授权；相同内容可安全重跑，不会覆盖不同内容的既有资产。DMG 只提供将 App 拖入“应用程序”的 Finder 包装，不声明 Developer ID 或公证。维护者步骤和失败恢复见 [CI/CD](wiki/CI-CD.md)。

真实机器核验与合成测试分开记录；后者不能证明企业账号、完整账单或真实服务器吞吐正确。视觉参考图只使用合成数据，录制图像本身不算通过。详细方法见 [测试指南](wiki/测试指南.md) 和 [UI 测试说明](UI_TESTING.md)，最近的结果与限制见 [验证记录](VALIDATION.md)。

## 隐私与开源

应用只读获取 Token Hub 必要的连接与现有登录材料，在内存中向其既有 HTTPS 来源交换短期会话并读取额度。它不会把令牌、账号、实际额度或响应正文写入正常日志、配置或源码仓库；本地会话文件在解析时可能短暂接触正文，但仅提取允许的计量和身份字段，不保存或上传正文。完整读取边界与开源检查方法见 [隐私说明](../PRIVACY.md)。

采用 [MIT 许可证](../LICENSE)。报告问题时只提交版本、状态描述、操作步骤和合成示例，不提交凭据、企业地址、账户数据库、会话正文或原始运行截图。贡献流程见 [贡献指南](wiki/贡献指南.md)。

界面布局参考 codexU 的紧凑分组思路；文档组织参考 [TuPigGHD2Chinese](https://github.com/Tupig/TuPigGHD2Chinese) 的文档中心与专题导航，内容依据本项目的实际实现编写。
