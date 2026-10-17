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
