import Foundation
import TokenStatCore
import SQLite3
import Darwin
import os

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

private enum DirectQuotaOutcome<Value: Sendable>: Sendable {
    case success(Value)
    case failure(TokenHubDirectQuotaFailure)
}

private struct DirectQuotaOutcomeBox<Value: Sendable>: Sendable {
    private let storage = OSAllocatedUnfairLock<DirectQuotaOutcome<Value>?>(initialState: nil)
    func setSuccess(_ value: Value) { storage.withLock { $0 = .success(value) } }
    func setFailure(_ error: Error) {
        storage.withLock { $0 = .failure((error as? TokenHubDirectQuotaFailure) ?? .transportFailed) }
    }
    func get() -> DirectQuotaOutcome<Value>? { storage.withLock { $0 } }
}

private struct DirectQuotaClock: Sendable {
    private struct State { var value: Date }
    private let storage: OSAllocatedUnfairLock<State>
    init(_ value: Date) { storage = OSAllocatedUnfairLock(initialState: State(value: value)) }
    func now() -> Date { storage.withLock { $0.value } }
    func set(_ value: Date) { storage.withLock { $0.value = value } }
}

extension CoreChecks {
    static func directQuotaChecks() throws {
#if TOKENSTAT_BP38_C01
        try bp38C01DirectQuotaChecks()
#endif
        try directCallbackLocationChecks()
        try directDatabaseReplacementChecks()
        try directDatabaseReadChecks()
        try directAmountLexicalChecks()
        try directVoucherTransportChecks()
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
                if url.path.hasSuffix("/reset-vouchers") { return TokenHubDirectQuotaHTTPResponse(statusCode: 404, data: Data()) }
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

    private static func directVoucherTransportChecks() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = TokenHubIdentity(pid: 47095, bundleID: TokenHubTarget.bundleID, executablePath: "/Synthetic/Hub")
        let quota = json(#"{"data":{"currency":"USD","windows":[{"kind":"fixed_5h","quota_amount":100,"used_amount":20}]}}"#)
        for scenario in ["valid", "zero", "http", "malformed", "throw", "quota-error", "quota-malformed", "callback-error", "identity-change", "retry"] {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("voucher-transport-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: home) }
            let database = TokenHubConnectionDiscovery.defaultDatabaseURL(home: home)
            try writeDirectQuotaFixture(at: database, now: now, sessionToken: "fixture-session")
            let calls = OSAllocatedUnfairLock(initialState: [String]())
            let client = TokenHubDirectQuotaClient(request: { url, bearer in
                let quotaCalls = calls.withLock {
                    $0.append("\(url.path)|\(bearer)")
                    return $0.filter { $0.hasPrefix("/api/v1/auth/me/quota-usage|") }.count
                }
                let expectedAccess = scenario == "retry" && (url.path == "/api/v1/me/reset-vouchers" || quotaCalls > 1)
                    ? "fixture-refreshed-access" : "fixture-access"
                guard url.host == "aihub.example.test", bearer == expectedAccess else {
                    throw TokenHubDirectQuotaFailure.transportFailed
                }
                if url.path == "/api/v1/auth/me/quota-usage" {
                    if scenario == "retry" && quotaCalls == 1 {
                        return TokenHubDirectQuotaHTTPResponse(statusCode: 401, data: Data())
                    }
                    return TokenHubDirectQuotaHTTPResponse(statusCode: scenario == "quota-error" ? 403 : 200,
                        data: scenario == "quota-malformed" ? Data("{}".utf8) : quota)
                }
                guard url.path == "/api/v1/me/reset-vouchers" else { throw TokenHubDirectQuotaFailure.endpointRejected }
                if scenario == "throw" { throw URLError(.notConnectedToInternet) }
                if scenario == "identity-change" {
                    try writeDirectQuotaFixture(at: database, now: now, sessionToken: "changed-session")
                }
                return TokenHubDirectQuotaHTTPResponse(statusCode: scenario == "http" ? 503 : 200,
                    data: scenario == "malformed" ? Data("{}".utf8) : json(scenario == "zero" ? #"{"data":{"total":0}}"# : #"{"data":{"total":3}}"#))
            }, callbackRequest: { url in
                let access = calls.withLock {
                    let number = $0.filter { $0.hasPrefix("callback|") }.count + 1
                    let access = scenario == "retry" && number == 2 ? "fixture-refreshed-access" : "fixture-access"
                    $0.append("callback|\(access)")
                    return access
                }
                guard url.host == "aihub.example.test", url.path == "/api/v1/auth/it-sso/callback" else {
                    throw TokenHubDirectQuotaFailure.endpointRejected
                }
                if scenario == "callback-error" { throw TokenHubDirectQuotaFailure.exchangeRejected }
                return access
            })
            var failure: TokenHubDirectQuotaFailure?
            let result: TokenHubQuotaSnapshot?
            do {
                result = try awaitDirectQuota {
                    do { return try await client.fetch(identity: identity, now: now, home: home) }
                    catch let error as TokenHubDirectQuotaFailure { throw error }
                    catch {
                        check(false, "voucher transport \(scenario) never escapes an unknown failure before the result bridge")
                        throw error
                    }
                }
            } catch let error as TokenHubDirectQuotaFailure { failure = error; result = nil }
            catch {
                check(false, "voucher transport \(scenario) never escapes an unknown failure")
                result = nil
            }
            let events = calls.withLock { $0 }
            let noVoucher = ["quota-error", "quota-malformed", "callback-error"].contains(scenario)
            var expectedEvents = ["callback|fixture-access"]
            if scenario != "callback-error" { expectedEvents.append("/api/v1/auth/me/quota-usage|fixture-access") }
            if scenario == "retry" {
                expectedEvents += ["callback|fixture-refreshed-access", "/api/v1/auth/me/quota-usage|fixture-refreshed-access"]
            }
            if !noVoucher { expectedEvents.append("/api/v1/me/reset-vouchers|\(scenario == "retry" ? "fixture-refreshed-access" : "fixture-access")") }
            check(events == expectedEvents,
                  "voucher transport \(scenario) uses exact callback, quota and voucher order, counts and bearers")
            if noVoucher || scenario == "identity-change" {
                check(result == nil, "voucher transport \(scenario) cannot publish invalid or changed identity")
                let expected: TokenHubDirectQuotaFailure = scenario == "identity-change" ? .identityChanged :
                    scenario == "quota-error" ? .httpStatus(403) : scenario == "callback-error" ? .exchangeRejected : .malformedResponse
                check(failure == expected, "voucher transport \(scenario) preserves exact typed failure")
            } else {
                check(failure == nil && result != nil, "voucher transport \(scenario) returns quota without a typed or unknown failure")
                check(result?.fiveHour?.usedPercent == 20, "voucher failure does not discard valid quota \(scenario)")
                check(result?.resetVoucherCount == (["valid", "retry"].contains(scenario) ? 3 : scenario == "zero" ? 0 : nil),
                      "voucher \(scenario) preserves count or unknown without live transport")
            }
        }
    }

#if TOKENSTAT_BP38_C01
    /// Synthetic database, clock and HTTP callbacks verify that a worker's
    /// observation timestamp is fixed at transaction start while credential
    /// freshness is re-read at the existing exchange checkpoints.
    private static func bp38C01DirectQuotaChecks() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenstat-bp38-c01-direct-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try writeDirectQuotaFixture(at: TokenHubConnectionDiscovery.defaultDatabaseURL(home: home),
                                    now: startedAt, sessionToken: "bp38-synthetic")

        let counter = DirectQuotaCounter()
        let clock = DirectQuotaClock(startedAt)
        let client = TokenHubDirectQuotaClient(request: { url, _ in
            if url.path.hasSuffix("/reset-vouchers") { return TokenHubDirectQuotaHTTPResponse(statusCode: 404, data: Data()) }
            counter.noteQuota(true)
            clock.set(startedAt.addingTimeInterval(2))
            return TokenHubDirectQuotaHTTPResponse(statusCode: 200, data: json("""
            {"data":{"currency":"USD","windows":[{"kind":"fixed_5h","used_amount":20,"quota_amount":100,"period_end":"2027-01-15T08:05:00Z"}]}}
            """))
        }, callbackRequest: { _ in
            counter.noteCallback(true)
            clock.set(startedAt.addingTimeInterval(1))
            return "synthetic-access"
        })
        let identity = TokenHubIdentity(pid: 84_201, bundleID: TokenHubTarget.bundleID,
            executablePath: "/Synthetic/Hub")
        let observation = try awaitDirectQuota {
            try await client.fetch(identity: identity, nowProvider: { clock.now() }, home: home)
        }
        counter.noteSuccess(true) // Reaching here proves the fetch returned a decoded success.
        check(observation.observedAt == startedAt,
              "BP38 C01 decoding retains one transaction-start observedAt despite later callback work")
        check(observation.fiveHour?.resetAt == startedAt.addingTimeInterval(300),
              "BP38 C01 synthetic response reset date is decoded against its fixed transaction")
        let counts = counter.snapshot()
        check(counts.0 == 1 && counts.1 == 1 && counts.2 && counts.3 && counts.4,
              "BP38 C01 uses the controlled callback and exactly one quota request")

        // Each substitute moves the stable clock to the exact boundary when
        // that named phase occurs. Harmless extra provider reads therefore
        // cannot shift the trigger to a different transaction checkpoint.
        let checkpointCases: [(name: String, transition: String, callbacks: Int, quotas: Int)] = [
            ("before-callback", "initial", 0, 0),
            ("after-callback", "callback-1", 1, 0),
            ("before-retry", "quota-1", 1, 1),
            ("after-retry-callback", "callback-2", 2, 1),
            ("after-success-response", "quota-1", 1, 1)
        ]
        for checkpoint in checkpointCases {
            let boundaryHome = FileManager.default.temporaryDirectory
                .appendingPathComponent("tokenstat-bp38-c01-checkpoint-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: boundaryHome) }
            let expiration = startedAt.addingTimeInterval(checkpoint.transition == "initial" ? 30 : 31)
            try writeDirectQuotaFixture(at: TokenHubConnectionDiscovery.defaultDatabaseURL(home: boundaryHome),
                now: startedAt, sessionToken: "bp38-checkpoint-\(checkpoint.name)", expiresAt: expiration)
            let boundaryClock = DirectQuotaClock(startedAt)
            let exactBoundary = expiration.addingTimeInterval(-30)
            let checkpointCounts = DirectQuotaCounter()
            let checkpointClient = TokenHubDirectQuotaClient(request: { url, _ in
                if url.path.hasSuffix("/reset-vouchers") { return TokenHubDirectQuotaHTTPResponse(statusCode: 404, data: Data()) }
                let number = checkpointCounts.noteQuota(true)
                if checkpoint.transition == "quota-\(number)" { boundaryClock.set(exactBoundary) }
                if (checkpoint.name == "before-retry" || checkpoint.name == "after-retry-callback") && number == 1 {
                    return TokenHubDirectQuotaHTTPResponse(statusCode: 401, data: Data())
                }
                return TokenHubDirectQuotaHTTPResponse(statusCode: 200, data: json("""
                {"data":{"currency":"USD","windows":[{"kind":"fixed_5h","used_amount":20,"quota_amount":100}]}}
                """))
            }, callbackRequest: { _ in
                let number = checkpointCounts.noteCallback(true)
                if checkpoint.transition == "callback-\(number)" { boundaryClock.set(exactBoundary) }
                return "synthetic-access"
            })
            let result = awaitDirectQuotaOutcome {
                try await checkpointClient.fetch(identity: identity,
                    nowProvider: { boundaryClock.now() }, home: boundaryHome)
            }
            let checkpointState = checkpointCounts.snapshot()
            check(!result.succeeded && result.failure == .credentialExpired
                && checkpointState.0 == checkpoint.callbacks && checkpointState.1 == checkpoint.quotas,
                  "BP38 C01 \(checkpoint.name) checkpoint rejects exactly-30-second session before later exchange")
        }

        // Credential freshness is intentionally tested through the client’s
        // explicit clock parameter; production’s injected provider is covered
        // by the AppModel worker-level tests in A38-01.
        for remaining in [30.001, 30.0] {
            let boundaryHome = FileManager.default.temporaryDirectory
                .appendingPathComponent("tokenstat-bp38-c01-expiry-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: boundaryHome) }
            try writeDirectQuotaFixture(at: TokenHubConnectionDiscovery.defaultDatabaseURL(home: boundaryHome),
                now: startedAt, sessionToken: "bp38-boundary-\(remaining)",
                expiresAt: startedAt.addingTimeInterval(remaining))
            let calls = DirectQuotaCounter()
            let boundedClient = TokenHubDirectQuotaClient(request: { url, _ in
                if url.path.hasSuffix("/reset-vouchers") { return TokenHubDirectQuotaHTTPResponse(statusCode: 404, data: Data()) }
                calls.noteQuota(true)
                return TokenHubDirectQuotaHTTPResponse(statusCode: 200, data: json("""
                {"data":{"currency":"USD","windows":[{"kind":"fixed_5h","used_amount":20,"quota_amount":100}]}}
                """))
            }, callbackRequest: { _ in calls.noteCallback(true); return "synthetic-access" })
            let outcome = awaitDirectQuotaOutcome {
                try await boundedClient.fetch(identity: identity, nowProvider: { startedAt }, home: boundaryHome)
            }
            let count = calls.snapshot()
            if remaining > 30 {
                check(outcome.succeeded && count.0 == 1 && count.1 == 1,
                      "BP38 C01 accepts a synthetic session with more than 30 seconds remaining")
            } else {
                check(!outcome.succeeded && outcome.failure == .credentialExpired
                    && count.0 == 0 && count.1 == 0,
                      "BP38 C01 rejects an exactly-30-second session before callback or quota request")
            }
        }

        let exactCurrentHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenstat-bp38-c01-current-initial-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: exactCurrentHome) }
        let expiresAt = startedAt.addingTimeInterval(100)
        try writeDirectQuotaFixture(at: TokenHubConnectionDiscovery.defaultDatabaseURL(home: exactCurrentHome),
            now: startedAt, sessionToken: "bp38-current-exact-30", expiresAt: expiresAt)
        let exactCurrentClock = DirectQuotaClock(startedAt.addingTimeInterval(70))
        let exactCurrentCalls = DirectQuotaCounter()
        let exactCurrentClient = TokenHubDirectQuotaClient(request: { url, _ in
            if url.path.hasSuffix("/reset-vouchers") { return TokenHubDirectQuotaHTTPResponse(statusCode: 404, data: Data()) }
            _ = exactCurrentCalls.noteQuota(true)
            return TokenHubDirectQuotaHTTPResponse(statusCode: 200, data: json("""
            {"data":{"currency":"USD","windows":[{"kind":"fixed_5h","used_amount":20,"quota_amount":100}]}}
            """))
        }, callbackRequest: { _ in
            _ = exactCurrentCalls.noteCallback(true)
            return "synthetic-access"
        })
        let exactCurrentResult = awaitDirectQuotaOutcome {
            try await exactCurrentClient.fetch(identity: identity,
                nowProvider: { exactCurrentClock.now() }, observationAt: startedAt, home: exactCurrentHome)
        }
        let exactCurrentCounts = exactCurrentCalls.snapshot()
        check(!exactCurrentResult.succeeded && exactCurrentResult.failure == .credentialExpired
            && exactCurrentCounts.0 == 0 && exactCurrentCounts.1 == 0,
            "BP38 C01 initial settings read uses current provider time and rejects exactly 30 seconds before callback or quota request")

        let aboveBoundaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenstat-bp38-c01-current-initial-above-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: aboveBoundaryHome) }
        try writeDirectQuotaFixture(at: TokenHubConnectionDiscovery.defaultDatabaseURL(home: aboveBoundaryHome),
            now: startedAt, sessionToken: "bp38-current-above-30",
            expiresAt: expiresAt)
        let aboveBoundaryClock = DirectQuotaClock(startedAt.addingTimeInterval(69.999))
        let aboveBoundaryCalls = DirectQuotaCounter()
        let aboveBoundaryClient = TokenHubDirectQuotaClient(request: { url, bearer in
            if url.path.hasSuffix("/reset-vouchers") { return TokenHubDirectQuotaHTTPResponse(statusCode: 404, data: Data()) }
            _ = aboveBoundaryCalls.noteQuota(url.path == "/api/v1/auth/me/quota-usage" && bearer == "synthetic-access")
            return TokenHubDirectQuotaHTTPResponse(statusCode: 200, data: json("""
            {"data":{"currency":"USD","windows":[{"kind":"fixed_5h","used_amount":20,"quota_amount":100}]}}
            """))
        }, callbackRequest: { url in
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let shape = components?.path == "/api/v1/auth/it-sso/callback"
                && Set(components?.queryItems?.map(\.name) ?? []).isSuperset(of: [
                    "token", "verifySign", "redirect", "sourceChannel", "sourceTokenType"
                ])
            _ = aboveBoundaryCalls.noteCallback(shape)
            return "synthetic-access"
        })
        let aboveBoundarySnapshot = try? awaitDirectQuota {
            try await aboveBoundaryClient.fetch(identity: identity,
                nowProvider: { aboveBoundaryClock.now() }, observationAt: startedAt, home: aboveBoundaryHome)
        }
        let aboveBoundaryCounts = aboveBoundaryCalls.snapshot()
        check(aboveBoundarySnapshot?.observedAt == startedAt
            && aboveBoundarySnapshot?.fiveHour?.usedPercent == Decimal(20)
            && aboveBoundaryCounts.0 == 1 && aboveBoundaryCounts.1 == 1
            && aboveBoundaryCounts.2 && aboveBoundaryCounts.3,
            "BP38 C01 initial settings read accepts 30.001 seconds remaining with one callback, one quota request and fixed decoder observation")
    }
#endif

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
        try bp46SafeCallbackErrorChecks()
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

// C46 uses the public parser and fixed, payload-free failure labels so the
// checks compile against the predecessor enum and can first fail on behavior.
extension CoreChecks {
    private static func bp46SafeCallbackErrorChecks() throws {
        var callbackComponents = URLComponents(string: "https://aihub.example.test/api/v1/auth/it-sso/callback")!
        callbackComponents.queryItems = [URLQueryItem(name: "token", value: "fixture-session")]
        let callback = callbackComponents.url!
        let landing = "https://aihub.example.test/auth/it/callback"
        func location(_ items: [URLQueryItem]) -> String {
            var fragment = URLComponents()
            fragment.queryItems = items
            return landing + "#" + fragment.percentEncodedQuery!
        }
        func reject(_ name: String, _ value: String, _ expected: String, original: URL? = nil) {
            do {
                _ = try TokenHubDirectQuotaClient.accessToken(fromCallbackLocation: value,
                                                               callbackURL: original ?? callback)
                check(false, "BP46 \(name) rejects instead of returning a token")
            } catch let failure as TokenHubDirectQuotaFailure {
                check(String(describing: failure) == expected, "BP46 \(name) has the required safe failure type")
            } catch {
                check(false, "BP46 \(name) remains a direct-quota typed failure")
            }
        }
        func accept(_ name: String, _ value: String, _ expected: String, original: URL? = nil) {
            do {
                let actual = try TokenHubDirectQuotaClient.accessToken(fromCallbackLocation: value,
                                                                        callbackURL: original ?? callback)
                check(actual == expected, "BP46 \(name) preserves the exact synthetic token")
            } catch {
                check(false, "BP46 \(name) accepts its valid synthetic callback")
            }
        }

        // This is the first RED oracle: the old parser returns fixture-access.
        let token = URLQueryItem(name: "access_token", value: "fixture-access")
        reject("C01b error-plus-token behavior", location([URLQueryItem(name: "error", value: "token_verify_failed"), token]),
               "loginRejected")
        if ProcessInfo.processInfo.environment["TOKENSTAT_BP46_RED_ONLY"] == "1" { return }

        for (index, marker) in ["token_verify_failed", "synthetic_other_rejection"].enumerated() {
            let expected = index == 0 ? "loginRejected" : "exchangeRejected"
            let error = URLQueryItem(name: "error", value: marker)
            let variants = [[error], [error, token], [token, error],
                [error, token, URLQueryItem(name: "redirect", value: "/me/api-key")],
                [token, error, URLQueryItem(name: "access_token", value: "other")],
                [URLQueryItem(name: "access_token", value: nil), error],
                [error, URLQueryItem(name: "access_token", value: "bad\nvalue")]]
            for (variant, items) in variants.enumerated() {
                reject("C01b priority \(index)-\(variant)", location(items), expected)
            }
        }
        let known = ["token_verify_failed", "ToKeN_vErIfY_FaIlEd", " token_verify_failed ",
            "\t\r\ntoken_verify_failed\r\n\t", "\u{00A0}\u{3000}TOKEN_VERIFY_FAILED\u{0085}"]
        for (index, marker) in known.enumerated() {
            reject("C01c known marker \(index)", location([URLQueryItem(name: "error", value: marker)]), "loginRejected")
        }
        reject("C01c once-encoded marker", landing + "#error=%74oken%5Fverify%5Ffailed", "loginRejected")
        reject("C01b once-encoded exact key", landing + "#err%6Fr=token_verify_failed", "loginRejected")
        let unknown = ["xtoken_verify_failed", "token_verify_failedx", "token_verify_failed_extra",
            "token_verify_failed.extra", "token verify_failed", "token_ve rify_failed", "token_verify_failed+",
            "\u{200B}token_verify_failed", "token_ver\u{0131}fy_failed", "ｔoken_verify_failed", "synthetic_unknown"]
        for (index, marker) in unknown.enumerated() {
            reject("C01c unknown marker \(index)", location([URLQueryItem(name: "error", value: marker)]), "exchangeRejected")
        }
        reject("C01c twice-encoded marker", landing + "#error=%2574oken_verify_failed", "exchangeRejected")
        reject("C01c twice-encoded separator", landing + "#error=token%255Fverify_failed", "exchangeRejected")

        let malformed: [[URLQueryItem]] = [
            [URLQueryItem(name: "error", value: nil)], [URLQueryItem(name: "error", value: "")],
            [URLQueryItem(name: "error", value: " \t\r\n\u{00A0}\u{3000}")],
            [URLQueryItem(name: "error", value: "token_verify_failed"), URLQueryItem(name: "error", value: "token_verify_failed")],
            [URLQueryItem(name: "error", value: "token_verify_failed"), URLQueryItem(name: "error", value: "synthetic_other")],
            [URLQueryItem(name: "error", value: nil), URLQueryItem(name: "error", value: "token_verify_failed")]
        ]
        for (index, items) in malformed.enumerated() {
            reject("C01d malformed error \(index)", location(items), "malformedResponse")
            reject("C01d malformed error with token \(index)", location(items + [token]), "malformedResponse")
        }
        reject("C01d no token", location([URLQueryItem(name: "redirect", value: "/me/api-key")]), "accessTokenMissing")
        reject("C01b description alone", location([URLQueryItem(name: "error_description", value: "token_verify_failed")]),
               "accessTokenMissing")
        accept("C01b description is not an error key", location([token, URLQueryItem(name: "error_description", value: "token_verify_failed")]),
               "fixture-access")
        accept("C01b error key remains case-sensitive", location([token, URLQueryItem(name: "Error", value: "token_verify_failed")]),
               "fixture-access")
        reject("C01b wrong-case key without token", location([URLQueryItem(name: "ERROR", value: "token_verify_failed")]),
               "accessTokenMissing")

        accept("C01a token-only positive control", location([token]), "fixture-access")
        accept("C01a explicit default port", "https://aihub.example.test:443/auth/it/callback#access_token=fixture-access",
               "fixture-access")
        let prefixed = URL(string: "https://aihub.example.test/aimanager/api/v1/auth/it-sso/callback")!
        accept("C01a verified prefix", "https://aihub.example.test/aimanager/auth/it/callback#access_token=fixture-access",
               "fixture-access", original: prefixed)
        reject("C01a error on verified prefix", "https://aihub.example.test/aimanager/auth/it/callback#error=token_verify_failed",
               "loginRejected", original: prefixed)
        reject("C01a error respects verified prefix", "https://aihub.example.test/auth/it/callback#error=token_verify_failed",
               "accessTokenMissing", original: prefixed)
        reject("C01a unrelated registrant with error", "https://other.co.id/auth/it/callback#error=token_verify_failed",
               "accessTokenMissing", original: URL(string: "https://manager.organization.co.id/api/v1/auth/it-sso/callback")!)
        let safeError = String(location([URLQueryItem(name: "error", value: "token_verify_failed"), token]).dropFirst(landing.count))
        // Foundation encodes the second literal hash into the token value.
        // Preserve the predecessor's token behavior while keeping error first.
        reject("C01b normalized second hash keeps error priority", landing + safeError + "#nested", "loginRejected")
        accept("C01d normalized second hash preserves original token", location([token]) + "#nested", "fixture-access#nested")
        let badTrust = [
            "https://sibling.example.test/auth/it/callback" + safeError,
            "https://other.example.test:8443/auth/it/callback" + safeError,
            "https://aihub.example.test:8443/auth/it/callback" + safeError,
            "https://user:password@aihub.example.test/auth/it/callback" + safeError,
            landing + "?ignored=1" + safeError,
            "http://aihub.example.test/auth/it/callback" + safeError,
            "https://aihub.example.test/unexpected" + safeError,
            landing + safeError + "&redirect=%2Funexpected",
            landing + safeError + "&redirect=%2Fme%2Fapi-key&redirect=%2Funexpected",
            "/auth/it/callback" + safeError,
            landing,
            landing + "#error= token_verify_failed",
            landing + "#error=token_verify_failed\n",
            landing + safeError + "&padding=" + String(repeating: "x", count: 65_536)
        ]
        for (index, value) in badTrust.enumerated() {
            reject("C01a untrusted shape \(index)", value, "accessTokenMissing")
        }
        for (index, original) in [
            "http://aihub.example.test/api/v1/auth/it-sso/callback",
            "https://aihub.example.test:8443/api/v1/auth/it-sso/callback",
            "https://user:password@aihub.example.test/api/v1/auth/it-sso/callback",
            "https://aihub.example.test/unexpected"
        ].enumerated() {
            reject("C01a untrusted original \(index)", landing + safeError, "accessTokenMissing", original: URL(string: original)!)
        }
        for (index, items) in [
            [URLQueryItem(name: "access_token", value: nil)], [URLQueryItem(name: "access_token", value: "")],
            [token, token], [URLQueryItem(name: "access_token", value: "bad value")],
            [URLQueryItem(name: "access_token", value: "bad\nvalue")],
            [URLQueryItem(name: "access_token", value: String(repeating: "x", count: 16_385))]
        ].enumerated() {
            reject("C01d original token boundary \(index)", location(items), "accessTokenMissing")
        }
        let maximumToken = String(repeating: "x", count: 16_384)
        accept("C01d token length positive boundary", location([URLQueryItem(name: "access_token", value: maximumToken)]), maximumToken)
        accept("C01d one token decoding pass", landing + "#access_token=fixture%252Daccess", "fixture%2Daccess")

        let canaries = ["bp46-synthetic-account@example.invalid", "/synthetic/bp46-only/path",
            "bp46-synthetic-body", "https://canary.example.invalid/bp46", "bp46-synthetic-token"]
        for (index, marker) in ["token_verify_failed", canaries.joined(separator: "|")].enumerated() {
            let input = location([URLQueryItem(name: "error", value: marker),
                URLQueryItem(name: "error_description", value: canaries.joined(separator: "|")),
                URLQueryItem(name: "access_token", value: canaries.last!)])
            do {
                _ = try TokenHubDirectQuotaClient.accessToken(fromCallbackLocation: input, callbackURL: callback)
                check(false, "BP46 C09 privacy input \(index) cannot become success")
            } catch let failure as TokenHubDirectQuotaFailure {
                check(String(describing: failure) == (index == 0 ? "loginRejected" : "exchangeRejected"),
                      "BP46 C09 privacy input \(index) preserves the required safe category")
                let publicFailure = String(describing: failure) + String(reflecting: failure)
                check(canaries.allSatisfy { !publicFailure.contains($0) }, "BP46 C09 failure carries no synthetic private fields")
            } catch { check(false, "BP46 C09 privacy failure stays typed") }
        }
        try bp46RejectedCallbackClientChecks()
    }

    private static func bp46RejectedCallbackClientChecks() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = TokenHubIdentity(pid: 46_201, bundleID: TokenHubTarget.bundleID,
            executablePath: "/Applications/Synthetic BP46 Hub.app/Contents/MacOS/Hub")
        let data = json(#"{"data":{"currency":"USD","windows":[{"kind":"fixed_5h","quota_amount":10,"used_amount":1}]}}"#)
        for (index, marker) in ["token_verify_failed", "synthetic_other_rejection"].enumerated() {
            for rejectedCallback in [1, 2] {
                let home = FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-bp46-client-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: home) }
                try writeDirectQuotaFixture(at: TokenHubConnectionDiscovery.defaultDatabaseURL(home: home),
                                            now: now, sessionToken: "fixture-session")
                let calls = DirectQuotaCounter()
                let client = TokenHubDirectQuotaClient(request: { url, bearer in
                    if url.path.hasSuffix("/reset-vouchers") { return TokenHubDirectQuotaHTTPResponse(statusCode: 404, data: Data()) }
                    let count = calls.noteQuota(url.absoluteString == "https://aihub.example.test/api/v1/auth/me/quota-usage"
                        && bearer == "fixture-access")
                    return TokenHubDirectQuotaHTTPResponse(statusCode: rejectedCallback == 2 && count == 1 ? 401 : 200, data: data)
                }, callbackRequest: { url in
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    let expected = ["token": "fixture-session", "verifySign": "fixture-signature", "redirect": "/me/api-key",
                        "sourceChannel": "fixture-channel", "sourceTokenType": "fixture-type"]
                    let items = components?.queryItems ?? []
                    let count = calls.noteCallback(components?.scheme == "https" && components?.host == "aihub.example.test"
                        && components?.path == "/api/v1/auth/it-sso/callback" && items.count == expected.count
                        && expected.allSatisfy { key, value in items.filter { $0.name == key && $0.value == value }.count == 1 })
                    var fragment = URLComponents()
                    let token = URLQueryItem(name: "access_token", value: "fixture-access")
                    fragment.queryItems = count == rejectedCallback ? [URLQueryItem(name: "error", value: marker), token] : [token]
                    return try TokenHubDirectQuotaClient.accessToken(
                        fromCallbackLocation: "https://aihub.example.test/auth/it/callback#" + fragment.percentEncodedQuery!, callbackURL: url)
                })
                let outcome = awaitDirectQuotaOutcome { try await client.fetch(identity: identity, now: now, home: home) }
                let state = calls.snapshot()
                check(!outcome.succeeded && outcome.failure.map { String(describing: $0) } == (index == 0 ? "loginRejected" : "exchangeRejected"),
                      "BP46 C02 callback \(rejectedCallback) propagates safe rejection category \(index)")
                check(state.0 == rejectedCallback && state.1 == rejectedCallback - 1,
                      "BP46 C02 callback \(rejectedCallback) stops before quota or any additional retry")
                check(state.2 && (state.1 == 0 || state.3), "BP46 C02 retains synthetic callback and bearer request contracts")
            }
        }
    }
}

private func writeDirectQuotaFixture(at database: URL, now: Date, sessionToken: String,
                                     expiresAt: Date? = nil) throws {
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
        "tokenType": "fixture-type", "expiresAt": ((expiresAt ?? now.addingTimeInterval(3600)).timeIntervalSince1970) * 1000
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

private func awaitDirectQuota<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let done = DispatchSemaphore(value: 0)
    let result = DirectQuotaOutcomeBox<Value>()
    Task {
        do { result.setSuccess(try await operation()) }
        catch { result.setFailure(error) }
        done.signal()
    }
    guard done.wait(timeout: .now() + 3) == .success,
          let value = result.get() else { throw TokenHubDirectQuotaFailure.transportFailed }
    switch value {
    case .success(let value): return value
    case .failure(let failure): throw failure
    }
}

private struct DirectQuotaAttempt: Sendable {
    let succeeded: Bool
    let failure: TokenHubDirectQuotaFailure?
}

private func awaitDirectQuotaOutcome<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) -> DirectQuotaAttempt {
    do { _ = try awaitDirectQuota(operation); return DirectQuotaAttempt(succeeded: true, failure: nil) }
    catch { return DirectQuotaAttempt(succeeded: false, failure: error as? TokenHubDirectQuotaFailure) }
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
            let client = TokenHubDirectQuotaClient(request: { url, _ in
                if url.path.hasSuffix("/reset-vouchers") { return TokenHubDirectQuotaHTTPResponse(statusCode: 404, data: Data()) }
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

extension CoreChecks {
    static func directDatabaseReadChecks() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenstat-db-read-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let database = TokenHubConnectionDiscovery.defaultDatabaseURL(home: home)
        try writeDirectQuotaFixture(at: database, now: now, sessionToken: "fixture-session")
        var writer: OpaquePointer?
        guard sqlite3_open(database.path, &writer) == SQLITE_OK, let writer else {
            if let writer { sqlite3_close(writer) }
            throw NSError(domain: "SyntheticDirectQuotaFixture", code: 6)
        }
        defer { sqlite3_close(writer) }
        let wal = "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;"
            + "UPDATE client_settings SET value_json = "
            + "'{\"aiManagerBaseUrl\":\"https://wal.example.test\",\"aitsBaseUrl\":\"https://wal-aits.example.test\"}' "
            + "WHERE key = 'client.connection';"
        guard sqlite3_exec(writer, wal, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SyntheticDirectQuotaFixture", code: 7)
        }
        let visible = try TokenHubConnectionDiscovery.readDefaultConnectionBaseURLs(home: home)
        check(visible.compactMap(\.host) == ["wal.example.test", "wal-aits.example.test"],
              "read-only open sees committed WAL pages beside the database")
        let before = openDescriptorCount()
        for _ in 0..<24 {
            _ = try TokenHubConnectionDiscovery.readDefaultConnectionBaseURLs(home: home)
        }
        let after = openDescriptorCount()
        check(after <= before, "repeated hub database reads release the probe descriptor")
    }

    private static func openDescriptorCount() -> Int {
        var count = 0
        for fd in 0..<256 {
            var info = stat()
            if fstat(Int32(fd), &info) == 0 { count += 1 }
        }
        return count
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
