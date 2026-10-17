import Foundation
import TokenStatCore

private final class DirectQuotaCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks = 0
    private var quotas = 0
    private var callbackShape = false
    private var quotaShape = false
    private var succeeded = false
    func noteCallback(_ shape: Bool) { lock.lock(); callbacks += 1; callbackShape = shape; lock.unlock() }
    func noteQuota(_ shape: Bool) -> Int { lock.lock(); quotas += 1; quotaShape = shape; let value = quotas; lock.unlock(); return value }
    func noteSuccess(_ value: Bool) { lock.lock(); succeeded = value; lock.unlock() }
    func snapshot() -> (Int, Int, Bool, Bool, Bool) {
        lock.lock(); defer { lock.unlock() }; return (callbacks, quotas, callbackShape, quotaShape, succeeded)
    }
}

extension CoreChecks {
    static func directQuotaChecks() throws {
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


        // On a machine with Token Hub installed, exercise the real local DB
        // discovery while replacing both network legs with in-memory fixtures.
        // No session values or URLs are printed or persisted.
        let localDB = TokenHubConnectionDiscovery.defaultDatabaseURL()
        if FileManager.default.fileExists(atPath: localDB.path) {
            let counter = DirectQuotaCounter()
            let client = TokenHubDirectQuotaClient(request: { url, bearer in
                let call = counter.noteQuota(url.path.contains("/api/v1/auth/me/quota-usage") && bearer == "fixture-access")
                return call == 1 ? TokenHubDirectQuotaHTTPResponse(statusCode: 401, data: Data())
                    : TokenHubDirectQuotaHTTPResponse(statusCode: 200, data: valid)
            }, callbackRequest: { url in
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let shape = components?.path.contains("/api/v1/auth/it-sso/callback") == true
                    && Set(components?.queryItems?.map(\.name) ?? []).isSuperset(of: ["token", "verifySign", "redirect", "sourceChannel", "sourceTokenType"])
                counter.noteCallback(shape)
                return "fixture-access"
            })
            let done = DispatchSemaphore(value: 0)
            Task {
                defer { done.signal() }
                do { _ = try await client.fetch(identity: identity, now: Date()); counter.noteSuccess(true) }
                catch { counter.noteSuccess(false) }
            }
            _ = done.wait(timeout: .now() + 3)
            let state = counter.snapshot()
            check(state.4 && state.0 == 2 && state.1 == 2 && state.2 && state.3,
                  "direct client exchanges local SSO session and retries quota once after 401")
        }
    }
}
