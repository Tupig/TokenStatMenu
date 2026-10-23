import Foundation

/// 有意不包含任何认证字段。结果仅保存在本地 UI 内存中。
public struct GatewayCandidate: Identifiable, Codable, Equatable {
    public var id: String { source + "|" + provider + "|" + endpoint }
    public let source: String
    public let provider: String
    public let endpoint: String
    public let model: String
    public let isActive: Bool
}

/// 一个面向常见 Codex 标量 TOML 设置的小型、失败即关闭的读取器，而非通用
/// TOML 解析器。仅保留 model/provider/profile/base_url/wire_api。它不会
/// 打开 auth.json、shell 配置文件、浏览器存储、数据库或钥匙串。
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
            // 即使是对未识别的 key，也跳过多行正文；其内容不属于配置。
            if let delimiter = ["\"\"\"", "'''"].first(where: { value.hasPrefix($0) }) {
                if !value.dropFirst(3).contains(delimiter) { multiline = delimiter }
                continue
            }
            let allowed: Set<String> = table.isEmpty ? ["model", "model_provider", "profile"]
                : table.first == "model_providers" && table.count == 2 ? ["base_url", "wire_api"]
                : table.first == "profiles" && table.count == 2 ? ["model", "model_provider"] : []
            guard allowed.contains(key) else { continue }
            // 重复的值是模糊的。绝不猜测哪个上游应该接收某个 key。
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

    /// 返回选中的 Codex provider 及其已配置 endpoint 的不含凭据的 origin。
    /// 仅使用 origin 进行 Seasun 路由校验；路径、查询字符串和凭据都会被丢弃。
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
        // 拒绝内嵌凭据/查询串/片段的完整 URL，而不是剥离凭据
        // 并将一个签名 URL 悄然变成不同的 endpoint。
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
