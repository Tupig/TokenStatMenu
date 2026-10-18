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
        let userMonth = json(#"{"data":{"currency":"USD","windows":[{"kind":"user_month","quota_amount":100,"used_amount":12.5}]}}"#)
        let userMonthDecoded = try TokenHubDirectQuotaDecoder.decode(userMonth, identity: identity, now: now)
        check(userMonthDecoded.monthly != nil,
              "direct quota maps the Token Hub user_month window")

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
