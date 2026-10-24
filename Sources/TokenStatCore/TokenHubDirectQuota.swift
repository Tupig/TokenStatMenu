import Foundation
import SQLite3
import CoreFoundation
import Darwin

/// 直读 Seasun Token Hub 的错误不携带响应正文、URL、账号或凭据，可用于诊断和日志。
public enum TokenHubDirectQuotaFailure: Error, Equatable, Sendable {
    case endpointRejected
    case identityChanged
    case credentialExpired
    case connectionUnavailable
    case connectionMalformed
    case databaseUnsafe
    case sessionUnavailable
    case loginRejected
    case exchangeRejected
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

/// 根据 Token Hub 的只读连接配置推导接口，仅接受不含凭据的 HTTPS URL。
/// 可要求 AI Manager 与 SSO 主机拥有相同的组织域名后缀，源码不内嵌主机名。
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

    /// 兼容规则只识别下列后缀，不是完整公共后缀列表，也不用于判定重定向可信度。
    /// 回调 Location 必须与原先确认的源站完全匹配。
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

/// 只读打开本机 Token Hub 数据库。
/// 额度刷新读取连接与登录态；路由关联只读取连接源站，不读取会话行。不写库。
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

    /// 仅读取不含凭据的连接源站，用于确认当前 Codex 提供商由此 Token Hub 管理。
    /// 此发现调用不访问 SSO 会话行。
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
        // 按真实路径只读打开，WAL 的 -wal/-shm 才能落在数据库旁边。
        // /dev/fd 会让 SQLite 去找不存在的侧车文件，从而漏掉尚未检查点的提交。
        // 描述符只用于确认最终文件不是符号链接；打开后关闭，不交给 SQLite。
        // 不用 SQLITE_OPEN_NOFOLLOW：它会拒绝路径中任意一级符号链接，临时目录和部分主目录因此无法打开。
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw TokenHubDirectQuotaFailure.connectionUnavailable
        }
        var pathInfo = stat()
        guard lstat(url.path, &pathInfo) == 0, (pathInfo.st_mode & S_IFMT) == S_IFREG,
              pathInfo.st_dev == info.st_dev, pathInfo.st_ino == info.st_ino else {
            sqlite3_close(db)
            throw TokenHubDirectQuotaFailure.databaseUnsafe
        }
        // 将实际打开的文件身份带入请求事务；inode 被替换后即使 JSON 相同也不再信任。
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
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bindResult = key.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
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

/// 可注入客户端使解析测试无需联网，换取的访问令牌仅在本次刷新期间保留。
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
        let fixedObservation = now
        return try await fetch(identity: identity, nowProvider: { fixedObservation }, home: home)
    }

    public func fetch(identity: TokenHubIdentity, nowProvider: @Sendable () -> Date,
                      home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> TokenHubQuotaSnapshot {
        let observedAt = nowProvider()
        return try await fetch(identity: identity, nowProvider: nowProvider,
                               observationAt: observedAt, home: home)
    }

    public func fetch(identity: TokenHubIdentity, nowProvider: @Sendable () -> Date,
                      observationAt observedAt: Date,
                      home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> TokenHubQuotaSnapshot {
        let settings = try TokenHubConnectionDiscovery.readDefaultStoredSettings(home: home, now: nowProvider())
        let endpoint = try TokenHubDirectQuotaEndpoint(baseURL: settings.aiManagerBaseURL,
                                                       organizationURL: settings.ssoBaseURL)
        let callbackURL = try Self.callbackURL(baseURL: settings.aiManagerBaseURL, session: settings.session)
        var access: String
        do { access = try await callbackRequest(callbackURL) }
        catch let error as TokenHubDirectQuotaFailure { throw error }
        catch { throw TokenHubDirectQuotaFailure.exchangeFailed }
        try Self.requireUnchangedSettings(settings, home: home, now: nowProvider())
        var response = try await quotaResponse(endpoint: endpoint.url, access: access)
        // 按 Token Hub 的业务流程，在 401 后刷新一次代理令牌；其他状态不重试，令牌不落盘。
        if response.statusCode == 401 {
            // 再次换取令牌前重新读取配置；若会话或接口变化，留待下次刷新，避免混用身份。
            let refreshed = try TokenHubConnectionDiscovery.readDefaultStoredSettings(home: home, now: nowProvider())
            guard refreshed == settings else { throw TokenHubDirectQuotaFailure.identityChanged }
            let refreshedCallbackURL = try Self.callbackURL(baseURL: refreshed.aiManagerBaseURL, session: refreshed.session)
            do { access = try await callbackRequest(refreshedCallbackURL) }
            catch let error as TokenHubDirectQuotaFailure { throw error }
            catch { throw TokenHubDirectQuotaFailure.exchangeFailed }
            try Self.requireUnchangedSettings(settings, home: home, now: nowProvider())
            response = try await quotaResponse(endpoint: endpoint.url, access: access)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw TokenHubDirectQuotaFailure.httpStatus(response.statusCode)
        }
        guard response.data.count <= 1_048_576 else { throw TokenHubDirectQuotaFailure.responseTooLarge }
        try Self.requireUnchangedSettings(settings, home: home, now: nowProvider())
        let decoded = try TokenHubDirectQuotaDecoder.decode(response.data, identity: identity, now: observedAt)
        // 先确认额度有效，再用同一个可注入transport读取券；失败仅令券未知。
        let voucherCount = await resetVoucherCount(baseURL: settings.aiManagerBaseURL, access: access)
        try Self.requireUnchangedSettings(settings, home: home, now: nowProvider())
        return TokenHubQuotaSnapshot(identity: decoded.identity, fiveHour: decoded.fiveHour,
                                     sevenDay: decoded.sevenDay, monthly: decoded.monthly,
                                     resetVoucherCount: voucherCount, observedAt: decoded.observedAt)
    }

    /// 读取当前可用的重置券数量；接口不可用或响应异常时返回 nil。
    private func resetVoucherCount(baseURL: URL, access: String) async -> Int? {
        guard let url = Self.resetVoucherURL(baseURL: baseURL) else { return nil }
        do {
            let response = try await request(url, access)
            guard (200..<300).contains(response.statusCode),
                  response.data.count <= 1_048_576 else { return nil }
            return TokenHubResetVoucherDecoder.decode(response.data)
        } catch {
            return nil
        }
    }

    private static func resetVoucherURL(baseURL: URL) -> URL? {
        guard baseURL.scheme?.lowercased() == "https", baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil,
              let host = baseURL.host, !host.isEmpty else { return nil }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let prefix = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = prefix.isEmpty ? "/api/v1/me/reset-vouchers" : "/\(prefix)/api/v1/me/reset-vouchers"
        return components?.url
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

    /// 只解析捕获的 Location，不实际跳转，可离线测试重定向校验。
    public static func accessToken(fromCallbackLocation location: String, callbackURL: URL) throws -> String {
        // Location 携带 bearer 令牌，仅同组织后缀不足以信任；
        // 拒绝同级主机、查询参数、userinfo 和非默认端口，不向此 URL 发请求。
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
        let redirects = items.filter { $0.name == "redirect" }
        guard redirects.count <= 1,
              redirects.first.map({ $0.value == "/me/api-key" }) ?? true else {
            throw TokenHubDirectQuotaFailure.accessTokenMissing
        }
        let errors = items.filter { $0.name == "error" }
        if !errors.isEmpty {
            guard errors.count == 1, let value = errors.first?.value else {
                throw TokenHubDirectQuotaFailure.malformedResponse
            }
            let scalars = Array(value.unicodeScalars)
            var first = 0, last = scalars.count
            while first < last && scalars[first].properties.isWhitespace { first += 1 }
            while first < last && scalars[last - 1].properties.isWhitespace { last -= 1 }
            guard first < last else { throw TokenHubDirectQuotaFailure.malformedResponse }
            let ascii = scalars[first..<last].map { (65...90).contains($0.value) ? $0.value + 32 : $0.value }
            if ascii == "token_verify_failed".unicodeScalars.map(\.value) {
                throw TokenHubDirectQuotaFailure.loginRejected
            }
            throw TokenHubDirectQuotaFailure.exchangeRejected
        }
        let tokens = items.filter { $0.name == "access_token" }
        guard tokens.count == 1, let token = tokens.first?.value, !token.isEmpty, token.count <= 16_384,
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

/// 解码 `/api/v1/auth/me/quota-usage` 响应，不从本地 token 计数推算额度。
/// 通过 `kind` 识别窗口，未知类型不分配到五小时或七天窗口。
public enum TokenHubDirectQuotaDecoder {
    public static func decode(_ data: Data, identity: TokenHubIdentity, now: Date = Date(),
                              timeZone: TimeZone = .current) throws -> TokenHubQuotaSnapshot {
        guard data.count <= 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = root as? [String: Any] else {
            throw TokenHubDirectQuotaFailure.malformedResponse
        }
        // 当前响应将用量放在 `data` 中，同时接受旧网关直接返回根对象的结构。
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
        // Decimal(string:) 接受数字前缀、空白和部分残缺格式。
        // 转换前限制长度并匹配完整 JSON 数字，连末尾换行也拒绝。
        guard raw.utf8.count <= 128,
              raw.range(of: #"\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z"#,
                        options: .regularExpression) != nil else { return nil }
        // Decimal 可能丢失低位有效数字，故尾数有效位保守限制为 38 位，不计前导和末尾零。
        // 原生 JSON 数字可能已被 JSONSerialization 规范化。
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

/// 解码 `/api/v1/me/reset-vouchers` 的可用券总数。
///
/// 只接受非负整数 `data.total`；字段缺失、类型异常或超出上限时返回 nil。
public enum TokenHubResetVoucherDecoder {
    public static func decode(_ data: Data) -> Int? {
        guard data.count <= 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = root as? [String: Any],
              let payload = object["data"] as? [String: Any],
              let raw = payload["total"] as? NSNumber,
              CFGetTypeID(raw) != CFBooleanGetTypeID() else { return nil }
        let value = raw.doubleValue
        guard value.isFinite, value >= 0, value <= 1_000_000,
              value == value.rounded() else { return nil }
        return Int(value)
    }
}

private extension Data {
    init?(base64URL value: String) {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }
}
