import AppKit
import Combine
import SwiftUI
import XCTest
import TokenStatCore
@testable import TokenStatMenu
import os
import Vision
import Darwin

#if TOKENSTAT_BP38_C01 || TOKENSTAT_BP38_C02 || TOKENSTAT_BP38_C03
/// Cross-actor test clock. All reads and writes are serialized; tests never
/// send a mutable captured Date closure to a worker task.
private final class BP38LockedWallClock: Sendable {
    private let storage: OSAllocatedUnfairLock<Date>
    init(_ initial: Date) { storage = OSAllocatedUnfairLock(initialState: initial) }
    var now: Date { storage.withLock { $0 } }
    func set(_ value: Date) { storage.withLock { $0 = value } }
}

private final class BP38LockedMonotonicClock: Sendable {
    private let storage: OSAllocatedUnfairLock<TimeInterval>
    init(_ initial: TimeInterval = 0) { storage = OSAllocatedUnfairLock(initialState: initial) }
    var now: TimeInterval { storage.withLock { $0 } }
    func set(_ value: TimeInterval) { storage.withLock { $0 = value } }
}

@MainActor
private final class BP38ManualScheduler {
    struct Entry {
        let deadline: TimeInterval
        let operation: @MainActor () -> Void
        var cancelled: Bool
    }
    private(set) var elapsed: TimeInterval = 0
    private var entries: [UUID: Entry] = [:]
    private let monotonic: BP38LockedMonotonicClock
    var activeEntryCount: Int { entries.values.filter { !$0.cancelled }.count }
    func activeEntryCount(at deadline: TimeInterval) -> Int {
        entries.values.filter { !$0.cancelled && $0.deadline == deadline }.count
    }

    init(monotonic: BP38LockedMonotonicClock = BP38LockedMonotonicClock()) {
        self.monotonic = monotonic
    }

    func schedule(_ delay: TimeInterval, _ operation: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let id = UUID()
        entries[id] = Entry(deadline: elapsed + delay, operation: operation, cancelled: false)
        return { [weak self] in self?.entries[id]?.cancelled = true }
    }

    func advance(to value: TimeInterval) {
        precondition(value >= elapsed)
        elapsed = value
        monotonic.set(value)
        let due = entries.filter { !$0.value.cancelled && $0.value.deadline <= value }
        for (id, entry) in due.sorted(by: { $0.value.deadline < $1.value.deadline }) {
            entries.removeValue(forKey: id)
            entry.operation()
        }
    }
}
#endif

#if TOKENSTAT_BP38_C02
private struct BP38QuotaSnapshotBox: Sendable {
    private let storage: OSAllocatedUnfairLock<TokenHubQuotaSnapshot>
    init(_ snapshot: TokenHubQuotaSnapshot) { storage = OSAllocatedUnfairLock(initialState: snapshot) }
    var value: TokenHubQuotaSnapshot { storage.withLock { $0 } }
    func set(_ snapshot: TokenHubQuotaSnapshot) { storage.withLock { $0 = snapshot } }
}
#endif

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
    var isReleased: Bool { released }
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

/// A callback is parsed by the real Core parser before AppModel receives its
/// result. No production discovery, database, HTTP, AX or local scan is used.
@MainActor
private final class BP46DirectErrorHarness {
    let identity = TokenHubIdentity(pid: 46_301, bundleID: TokenHubTarget.bundleID,
        executablePath: "/Applications/Synthetic BP46 UI Hub.app/Contents/MacOS/Hub")
    private var callbackURL: URL {
        var components = URLComponents(string: "https://aihub.example.test/api/v1/auth/it-sso/callback")!
        components.queryItems = [URLQueryItem(name: "token", value: "fixture-session")]
        return components.url!
    }
    var callbackLocation: String?
    var legacyFailure: TokenHubDirectQuotaFailure?
    private(set) var calls = 0

    var dependencies: TokenHubDirectQuotaDependencies {
        TokenHubDirectQuotaDependencies(discoverTarget: { self.identity },
            identityIsCurrent: { $0 == self.identity }, fetch: { identity, now in
                self.calls += 1
                guard identity == self.identity else { throw TokenHubDirectQuotaFailure.identityChanged }
                if let failure = self.legacyFailure { throw failure }
                if let location = self.callbackLocation {
                    _ = try TokenHubDirectQuotaClient.accessToken(fromCallbackLocation: location, callbackURL: self.callbackURL)
                }
                // If a broken parser accepts error+token, this positive
                // snapshot reaches the UI and the rejection assertions fail.
                return TokenHubQuotaSnapshot(identity: identity,
                    fiveHour: TokenHubWindowQuota(kind: .fiveHour, usedAmount: 96, limitAmount: 100,
                        sourceSymbol: "$", usedPercent: 96, resetDisplay: "synthetic 5h reset",
                        resetAt: now.addingTimeInterval(3600)),
                    sevenDay: TokenHubWindowQuota(kind: .sevenDay, usedAmount: 97, limitAmount: 100,
                        sourceSymbol: "$", usedPercent: 97, resetDisplay: "synthetic 7d reset",
                        resetAt: now.addingTimeInterval(7200)),
                    monthly: TokenHubMonthlyUsage(usedAmount: 98, sourceSymbol: "$", limitAmount: 100), observedAt: now)
            })
    }
}

extension TokenHubQuotaStateTests {
    private var bp46Canaries: [String] {
        ["bp46-ui-synthetic-account@example.invalid", "/synthetic/bp46-ui-only/path",
         "bp46-ui-synthetic-body", "https://canary.example.invalid/bp46-ui", "bp46-ui-synthetic-token"]
    }

    private func bp46Callback(marker: String, includeToken: Bool) -> String {
        var fragment = URLComponents()
        var items = [URLQueryItem(name: "error", value: marker),
            URLQueryItem(name: "error_description", value: bp46Canaries.joined(separator: "|"))]
        if includeToken { items.append(URLQueryItem(name: "access_token", value: bp46Canaries.last!)) }
        fragment.queryItems = items
        return "https://aihub.example.test/auth/it/callback#" + fragment.percentEncodedQuery!
    }

    private func bp46Model(_ harness: BP46DirectErrorHarness, now: Date)
        -> (AppModel, HubTestPermission, HubTestScanner) {
        let permission = HubTestPermission(); permission.trusted = false
        let scanner = HubTestScanner(result: TokenHubQuotaResult(status: .targetNotRunning, snapshot: nil, failure: nil))
        let timing = AppModelTimingDependencies(wallNow: { now }, monotonicNow: { 0 }, schedule: { _, _ in { } })
        let model = AppModel(preview: true, timing: timing, directQuota: harness.dependencies,
            tokenHubPermissionProvider: permission, tokenHubAXSource: scanner.source)
        model.config.dataSource = "localCodex"
        model.config.refreshSeconds = 60
        model.tokenHubAutomaticReadingEnabled = false
        XCTAssertFalse(model.backgroundServicesStarted, "BP46 preview never starts default background sources")
        return (model, permission, scanner)
    }

    private func bp46Refresh(_ model: AppModel, harness: BP46DirectErrorHarness,
                            requestCount: Int, status: TokenHubQuotaStatus) async {
        model.refreshTokenHubQuota()
        for _ in 0..<100 {
            if harness.calls == requestCount && model.tokenHubQuotaStatus == status { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(harness.calls, requestCount, "BP46 explicitly injected fetch must run exactly once per refresh")
        XCTAssertEqual(model.tokenHubQuotaStatus, status, "BP46 synthetic result must reach its expected UI state")
    }

    private func bp46AssertRejected(_ model: AppModel, expectedLabel: String, expectedMessage: String,
                                   permission: HubTestPermission, scanner: HubTestScanner) {
        XCTAssertTrue(model.tokenHubDirectFailure.map { String(describing: $0) } == expectedLabel,
                      "BP46 user-visible failure retains the actual parser category without printing server fields")
        XCTAssertNil(model.tokenHubQuotaSnapshot, "BP46 rejection clears every prior quota source field")
        XCTAssertFalse(model.tokenHubQuotaIsDirect)
        XCTAssertEqual(model.tokenHubQuotaStatus, .accessFailed)
        XCTAssertNil(model.freshTokenHubQuota(at: model.tokenHubNow()))
        XCTAssertNil(model.quotaPresentation.fiveHourCurrent)
        XCTAssertNil(model.quotaPresentation.sevenDayCurrent)
        XCTAssertNil(model.quotaPresentation.monthlyCurrent)
        XCTAssertNil(model.quotaPresentation.fiveHour?.resetAt)
        XCTAssertNil(model.quotaPresentation.sevenDay?.resetAt)
        XCTAssertFalse(model.menuTitleContainsTokenHubSuffix, "BP46 failed source has no stale remaining-percent suffix")
        XCTAssertEqual(model.alertColor, .labelColor, "BP46 discarded quota cannot drive a current warning")
        XCTAssertTrue(model.menuTooltip.contains("5 小时未知"))
        XCTAssertTrue(model.menuTooltip.contains("7 天未知"))
        let card = DashboardView(model: model).tokenHubCard
        XCTAssertTrue(card.enabled, "BP46 direct failure stays visible with optional AX disabled")
        let surfaces = [("status", model.userFacingStatus), ("readiness", model.sourceReadinessText),
            ("quota status", model.tokenHubQuotaStatusText), ("tooltip", model.menuTooltip),
            ("dashboard", card.emptyStateText), ("settings", SettingsView(model: model).sourceStatusText)]
        for (name, text) in surfaces {
            XCTAssertTrue(text.contains(expectedMessage), "BP46 \(name) presents the fixed safe failure meaning")
            XCTAssertFalse(text.contains("已直接读取"), "BP46 \(name) cannot retain connected-source wording")
            XCTAssertFalse(text.contains("已自动读取"), "BP46 \(name) cannot claim successful automatic reading")
            if expectedLabel != "credentialExpired" {
                XCTAssertFalse(text.contains("过期"), "BP46 \(name) cannot infer session expiry from a rejection")
            }
            XCTAssertTrue(bp46Canaries.allSatisfy { !text.contains($0) }, "BP46 \(name) does not reflect synthetic server fields")
            XCTAssertFalse(text.contains("token_verify_failed"), "BP46 \(name) never reflects the raw known marker")
        }
        let otherPublicText = model.message + model.title
            + (model.tokenHubDirectFailure.map { String(reflecting: $0) } ?? "")
        XCTAssertTrue(bp46Canaries.allSatisfy { !otherPublicText.contains($0) }, "BP46 other output carries no synthetic private fields")
        XCTAssertFalse(model.tokenHubAutomaticReadingEnabled)
        XCTAssertEqual(permission.requests, 0, "BP46 safe rejection never requests an OS permission")
        XCTAssertEqual(scanner.calls, 0, "BP46 safe rejection cannot invoke optional AX fallback")
        XCTAssertFalse(model.backgroundServicesStarted)
    }

    func testBP46FirstRejectedCallbackShowsSafeMeaningAndUnknownValues() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for known in [true, false] {
            for includeToken in [false, true] {
                let harness = BP46DirectErrorHarness()
                harness.callbackLocation = bp46Callback(marker: known ? "token_verify_failed" : bp46Canaries.joined(separator: "|"),
                                                       includeToken: includeToken)
                let (model, permission, scanner) = bp46Model(harness, now: now)
                defer { model.shutdown() }
                let before = model.stats
                await bp46Refresh(model, harness: harness, requestCount: 1, status: .accessFailed)
                bp46AssertRejected(model, expectedLabel: known ? "loginRejected" : "exchangeRejected",
                    expectedMessage: known ? "Token Hub 登录验证未通过，请在 Hub 中确认登录状态" : "Token Hub 服务端拒绝登录交换",
                    permission: permission, scanner: scanner)
                XCTAssertEqual(model.stats.total, before.total, "BP46 rejection cannot fabricate token accounting")
                XCTAssertEqual(model.stats.input, before.input)
                XCTAssertEqual(model.stats.output, before.output)
                XCTAssertEqual(harness.calls, 1, "BP46 failure does not add an immediate retry")
            }
        }
    }

    func testBP46RejectedCallbackClearsOldQuotaAndFollowingSuccessRecovers() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for known in [true, false] {
            let harness = BP46DirectErrorHarness()
            let (model, permission, scanner) = bp46Model(harness, now: now)
            defer { model.shutdown() }
            await bp46Refresh(model, harness: harness, requestCount: 1, status: .connected)
            XCTAssertNotNil(model.quotaPresentation.fiveHourCurrent, "BP46 positive control must publish real synthetic fields")
            XCTAssertNotNil(model.quotaPresentation.sevenDayCurrent)
            XCTAssertNotNil(model.quotaPresentation.monthlyCurrent)
            XCTAssertTrue(model.tokenHubQuotaIsDirect)
            XCTAssertTrue(model.menuTitleContainsTokenHubSuffix)
            XCTAssertNotEqual(model.alertColor, .labelColor, "BP46 positive control must actually engage a quota warning")
            XCTAssertTrue(SettingsView(model: model).sourceStatusText.contains("已直接读取"))

            harness.callbackLocation = bp46Callback(marker: known ? "token_verify_failed" : bp46Canaries.joined(separator: "|"),
                                                   includeToken: true)
            await bp46Refresh(model, harness: harness, requestCount: 2, status: .accessFailed)
            bp46AssertRejected(model, expectedLabel: known ? "loginRejected" : "exchangeRejected",
                expectedMessage: known ? "Token Hub 登录验证未通过，请在 Hub 中确认登录状态" : "Token Hub 服务端拒绝登录交换",
                permission: permission, scanner: scanner)

            harness.callbackLocation = nil
            await bp46Refresh(model, harness: harness, requestCount: 3, status: .connected)
            XCTAssertNil(model.tokenHubDirectFailure, "BP46 the following successful observation clears the rejection")
            XCTAssertTrue(model.tokenHubQuotaIsDirect)
            XCTAssertNotNil(model.freshTokenHubQuota(at: now))
            XCTAssertNotNil(model.quotaPresentation.fiveHourCurrent)
            XCTAssertNotNil(model.quotaPresentation.sevenDayCurrent)
            XCTAssertNotNil(model.quotaPresentation.monthlyCurrent)
            XCTAssertTrue(SettingsView(model: model).sourceStatusText.contains("已直接读取"))
            XCTAssertEqual(permission.requests, 0)
            XCTAssertEqual(scanner.calls, 0)
            XCTAssertEqual(harness.calls, 3)
        }
    }

    func testBP46LegacyFailuresKeepTheirOriginalSafeMeaning() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let failures: [(TokenHubDirectQuotaFailure, String)] = [
            (.credentialExpired, "Token Hub 会话已过期"), (.exchangeFailed, "Token Hub 登录态交换失败"),
            (.redirectMissing, "Token Hub 登录态交换失败"), (.accessTokenMissing, "Token Hub 登录态交换失败")]
        for (failure, message) in failures {
            let harness = BP46DirectErrorHarness(); harness.legacyFailure = failure
            let (model, permission, scanner) = bp46Model(harness, now: now)
            defer { model.shutdown() }
            await bp46Refresh(model, harness: harness, requestCount: 1, status: .accessFailed)
            XCTAssertEqual(model.tokenHubDirectFailure, failure)
            bp46AssertRejected(model, expectedLabel: String(describing: failure), expectedMessage: message,
                               permission: permission, scanner: scanner)
        }
    }
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
        XCTAssertEqual(model.title, "— | — | —")
        for _ in 0..<100 { model.tick() }
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(menuChecks, 102, "the menu cadence is independent of dashboard notifications")
        now = observedAt
        model.tick()
        XCTAssertEqual(publications, 2, "clock rollback must recompute time-dependent presentation")
        XCTAssertEqual(model.title, "— | — | —")
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
            "backgroundServiceResources", "widgetSnapshotPublished", "widgetChannelUnavailable", "resetVoucherPresent"
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
        XCTAssertTrue(model.title.contains("30.00%") && model.title.contains("40.00%"))
        XCTAssertTrue(displayedTooltip.contains("5 小时）"))
        let beforeBoundary = tooltipBuilds
        clock.now = observedAt.addingTimeInterval(120)
        model.tick()
        XCTAssertEqual(tooltipBuilds, beforeBoundary, "the inclusive Hub freshness boundary does not rebuild")
        clock.now = observedAt.addingTimeInterval(120.001)
        model.tick()
        XCTAssertFalse(model.title.contains("30.00%"))
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
        XCTAssertEqual(model.title, "— | — | —", "菜单栏不显示本地速度")
        var publicationsAfterData = 0
        let observer = model.objectWillChange.sink { publicationsAfterData += 1 }
        now = initial.addingTimeInterval(0.2)
        model.tick()
        XCTAssertEqual(publicationsAfterData, 1,
                       "expiry must compare against the presented new input, not only the last timer tick")
        XCTAssertEqual(model.title, "— | — | —")
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

        XCTAssertEqual(model.title, "— | — | —", "菜单栏只显示额度，不显示本地速度")
        XCTAssertTrue(model.menuTooltip.contains("实时估算：输入 10.0 · 输出 24.5 tok/s"))
        now = observedAt.addingTimeInterval(15)
        XCTAssertEqual(model.title, "— | — | —", "菜单栏不随本地速度变化")
        now = observedAt.addingTimeInterval(15.001)
        XCTAssertEqual(model.title, "— | — | —", "菜单栏不显示本地速度")
        XCTAssertTrue(model.menuTooltip.contains("实时估算：未知"), "tooltip freshness must match menu freshness")
        now = observedAt.addingTimeInterval(-0.001)
        XCTAssertEqual(model.title, "— | — | —", "菜单栏不显示本地速度")
        XCTAssertTrue(model.menuTooltip.contains("实时估算：未知"))
    }

    func testUnknownMenuSpeedUsesOneCompletedTurnLabel() {
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        model.config.dataSource = "localCodex"
        XCTAssertEqual(model.title, "— | — | —", "无额度数据时三个位置都显示未知")
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
        XCTAssertEqual(model.title, "— | — | —")
        XCTAssertTrue(model.menuTooltip.contains("实时估算：未知"))
        XCTAssertTrue(model.menuTooltip.contains("5 小时未知"))
        XCTAssertTrue(model.menuTooltip.contains("7 天未知"))

        model.localSnapshot = LocalCodexSnapshot(input: 120, output: 80, total: 200,
            sessionCount: 2, filesScanned: 32, isLimited: true, latestEventAt: nil,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 3,
            unknownThreadCount: 2)
        XCTAssertFalse(model.title.contains("Σ"))

        model.localSnapshot = LocalCodexSnapshot(input: 120, output: 80, total: 200,
            sessionCount: 2, filesScanned: 3, isLimited: false, latestEventAt: nil,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 3,
            unknownThreadCount: 0)
        XCTAssertFalse(model.title.contains("Σ"))
        XCTAssertFalse(model.title.contains("顶层对话"))
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
        XCTAssertTrue(text.contains("币种来源待确认"))
        XCTAssertFalse(model.message.contains("3.75"), "raw quota amount must not enter diagnostics")
        XCTAssertFalse(model.message.contains("37.5"), "raw percentage must not enter diagnostics")
    }

    func testMenuTitleShowsThreeQuotaNumbersInRequestedFormat() async {
        let now = Date()
        let (model, scanner, _) = configuredModel(result(now: now), clock: HubManualClock(now))
        defer { model.shutdown() }
        await refresh(model, scanner: scanner)
        XCTAssertEqual(model.title, "37.50% | 40.00% | $12.50")
        XCTAssertFalse(model.title.contains("tok/s"))
        XCTAssertFalse(model.title.contains("Σ"))
    }

    func testMenuTitleShowsDashForMissingQuota() {
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        XCTAssertEqual(model.title, "— | — | —")
    }

    func testTokenHubDecimalDisplayPreservesFractionsAtModelAndCardCallsites() async {
        let now = Date()
        let (model, scanner, _) = configuredModel(result(now: now), clock: HubManualClock(now))
        defer { model.shutdown() }
        await refresh(model, scanner: scanner)
        XCTAssertTrue(model.title.contains("37.50%"), "菜单栏显示两位小数的已用百分比")
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
        XCTAssertTrue(model.menuTooltip.contains("币种来源待确认"))
    }
}

#if TOKENSTAT_BP38_C01
extension TokenHubQuotaStateTests {
    func testBP38C01MainActorScheduledScanUsesWorkerStartClock() async {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let wall = BP38LockedWallClock(base)
        let monotonic = BP38LockedMonotonicClock()
        let scheduler = BP38ManualScheduler(monotonic: monotonic)
        let timing = AppModelTimingDependencies(wallNow: { wall.now },
            monotonicNow: { monotonic.now }, schedule: { delay, operation in
                scheduler.schedule(delay, operation)
            })
        let harness = ControlledLocalScan()
        let model = localConsumer(harness, timing: timing)
        defer { model.shutdown(); Task { await harness.finishPending() } }

        // AppModel has enqueued its initial refresh. Time advances while it is
        // waiting on the main actor scheduler; the read must capture on start.
        wall.set(base.addingTimeInterval(5))
        scheduler.advance(to: 0)
        await waitForLocalRequests(1, harness: harness)
        let observed = await harness.observedDates
        let maximumPending = await harness.maximumPending
        XCTAssertEqual(observed.first, base.addingTimeInterval(5),
            "C01 a delayed main-actor callback uses actual worker start, not enqueue time")
        XCTAssertEqual(maximumPending, 1,
            "C01 manual scheduling never starts overlapping local scans")
        await harness.completeFirst(total: 1)
        for _ in 0..<100 where model.backgroundServiceResources.localScanQueuedCount == 0 { await Task.yield() }
        XCTAssertEqual(model.backgroundServiceResources.localScanQueuedCount, 1,
            "C01 successful completion queues one local refresh")
        XCTAssertEqual(scheduler.activeEntryCount(at: 5), 1,
            "C01 the local completion callback is scheduled at its five-second monotonic deadline")
        model.shutdown()
        XCTAssertEqual(model.backgroundServiceResources.localScanQueuedCount, 0,
            "C01 shutdown cancels the queued local refresh")
        XCTAssertEqual(scheduler.activeEntryCount(at: 5), 0,
            "C01 shutdown removes the local callback without counting unrelated service retries")
        scheduler.advance(to: 5)
        let requestsAfterShutdown = await harness.requests
        XCTAssertEqual(requestsAfterShutdown, 1,
            "C01 advancing after shutdown cannot start the queued local scan")
    }

    func testBP38C01LocalWorkerCapturesNowAfterActorQueueDelay() async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let legalEventAt = base.addingTimeInterval(1)
        let (directory, _) = try workerFixture(eventAt: legalEventAt)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = BP38LockedWallClock(base)
        let worker = LocalCodexScanWorker()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let secondWillSubmit = DispatchSemaphore(value: 0)
        let firstCall = OSAllocatedUnfairLock(initialState: true)
        let first = Task {
            try await worker.scan(directory: directory, nowProvider: {
                let shouldBlock = firstCall.withLock { state -> Bool in
                    if state { state = false; return true }
                    return false
                }
                if shouldBlock { started.signal(); _ = release.wait(timeout: .now() + 3) }
                return clock.now
            }, generation: 41, routeContext: nil)
        }
        let didStart = await Task.detached { started.wait(timeout: .now() + 3) == .success }.value
        XCTAssertTrue(didStart, "C01 first synthetic worker request reached the controlled actor queue")
        let sampled = BP38LockedWallClock(.distantPast)
        let second = Task {
            // This marker is emitted at base immediately before submitting the
            // actor call. The held first call keeps the worker actor occupied
            // while the test waits for this ordering point.
            secondWillSubmit.signal()
            return try await worker.scan(directory: directory, nowProvider: {
                let now = clock.now
                sampled.set(now)
                return now
            }, generation: 41, routeContext: nil)
        }
        let didSubmit = await Task.detached { secondWillSubmit.wait(timeout: .now() + 3) == .success }.value
        XCTAssertTrue(didSubmit, "C01 second request reaches its submission point while the actor is held")
        XCTAssertEqual(sampled.now, .distantPast,
            "C01 queued scan has not sampled while the earlier actor read remains held")
        await Task.yield()
        clock.set(base.addingTimeInterval(5))
        release.signal()
        _ = try await first.value
        let queuedResult = try await second.value
        XCTAssertEqual(sampled.now, base.addingTimeInterval(5),
            "C01 queued actor request samples model time when its serialized read actually begins")
        XCTAssertEqual(queuedResult.snapshot.latestEventAt, legalEventAt,
            "C01 queued scan accepts an event that is legal relative to its actual worker start")
        XCTAssertEqual(queuedResult.snapshot.total, 15,
            "C01 accepted usage contributes its decoded token total")

        // An event one second after the actual read start must still be
        // rejected. This proves the provider's sampled value affects scan
        // behavior, rather than merely being observed by the test callback.
        let (futureDirectory, _) = try workerFixture(eventAt: base.addingTimeInterval(6))
        defer { try? FileManager.default.removeItem(at: futureDirectory) }
        let futureStart = base.addingTimeInterval(5)
        let futureResult = try await worker.scan(directory: futureDirectory,
            nowProvider: { futureStart }, generation: 42, routeContext: nil)
        XCTAssertEqual(futureResult.snapshot.total, 0,
            "C01 event after the actual worker start is rejected")
        XCTAssertEqual(futureResult.snapshot.latestEventAt, base.addingTimeInterval(6),
            "C01 future event timestamp remains available as a diagnostic")
        XCTAssertEqual(futureResult.snapshot.input, 0,
            "C01 future cumulative input is excluded from accounting")
        XCTAssertEqual(futureResult.snapshot.output, 0,
            "C01 future cumulative output is excluded from accounting")
        XCTAssertEqual(futureResult.snapshot.knownThreadCount, 0,
            "C01 future cumulative evidence does not make the thread known")
        XCTAssertEqual(futureResult.snapshot.unknownThreadCount, 1,
            "C01 future cumulative evidence leaves the thread unknown")
        XCTAssertFalse(futureResult.snapshot.hasCompleteAccounting,
            "C01 future cumulative evidence cannot complete accounting")
        XCTAssertNil(futureResult.snapshot.liveTurn,
            "C01 future evidence cannot create a live turn")
        XCTAssertNil(futureResult.snapshot.lastTurn,
            "C01 future evidence cannot create a completed turn")
    }

    func testBP38C01DirectWorkerKeepsStartObservationWhileResponseIsSuspended() async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let wall = BP38LockedWallClock(base)
        let fetchClock = BP38LockedWallClock(.distantPast)
        let monotonic = BP38LockedMonotonicClock()
        let scheduler = BP38ManualScheduler(monotonic: monotonic)
        let timing = AppModelTimingDependencies(wallNow: { wall.now },
            monotonicNow: { monotonic.now }, schedule: { delay, operation in
                scheduler.schedule(delay, operation)
            })
        let workerEntered = HubScanGate()
        let allowStartSample = HubScanGate()
        let responseGate = HubScanGate()
        let identity = TokenHubIdentity(pid: 85_001, bundleID: TokenHubTarget.bundleID,
            executablePath: "/Synthetic/Delayed Hub")
        let direct = TokenHubDirectQuotaDependencies(discoverTarget: { identity },
            identityIsCurrent: { $0 == identity }, fetch: { receivedIdentity, transactionNow in
                XCTAssertEqual(receivedIdentity, identity)
                fetchClock.set(transactionNow)
                await responseGate.wait()
                return TokenHubQuotaSnapshot(identity: identity,
                    fiveHour: TokenHubWindowQuota(kind: .fiveHour, usedAmount: 3, limitAmount: 10,
                        sourceSymbol: "$", usedPercent: 30, resetDisplay: "synthetic", resetAt: base.addingTimeInterval(900)),
                    sevenDay: nil, monthly: nil, observedAt: transactionNow)
            }, workerFetch: { nowProvider in
                await MainActor.run { workerEntered.release() }
                await allowStartSample.wait()
                let transactionNow = nowProvider()
                fetchClock.set(transactionNow)
                await responseGate.wait()
                let snapshot = TokenHubQuotaSnapshot(identity: identity,
                    fiveHour: TokenHubWindowQuota(kind: .fiveHour, usedAmount: 3, limitAmount: 10,
                        sourceSymbol: "$", usedPercent: 30, resetDisplay: "synthetic", resetAt: base.addingTimeInterval(900)),
                    sevenDay: nil, monthly: nil, observedAt: transactionNow)
                return DirectQuotaTransportSnapshot(snapshot: snapshot)
            })
        let permission = HubTestPermission()
        permission.trusted = false
        let syntheticAX = HubTestScanner(result: TokenHubQuotaResult(
            status: .targetNotRunning, snapshot: nil, failure: nil)).source
        let model = AppModel(preview: true, timing: timing, directQuota: direct,
            tokenHubPermissionProvider: permission,
            tokenHubAXSource: syntheticAX)
        model.config.dataSource = "localCodex"
        model.tokenHubAutomaticReadingEnabled = false
        defer { model.shutdown(); allowStartSample.release(); responseGate.release() }

        XCTAssertFalse(model.shouldPublishWidgetState, "首次读取前不抢占 reload")
        model.refreshTokenHubQuota()
        for _ in 0..<100 where !workerEntered.isReleased { await Task.yield() }
        XCTAssertTrue(workerEntered.isReleased, "C01 synthetic worker starts before the model clock advances")
        wall.set(base.addingTimeInterval(5))
        allowStartSample.release()
        for _ in 0..<100 where fetchClock.now == .distantPast { await Task.yield() }
        XCTAssertEqual(fetchClock.now, base.addingTimeInterval(5),
            "C01 worker samples the injected provider after its controlled start delay")
        wall.set(base.addingTimeInterval(126))
        responseGate.release()
        await settle(model, status: .connected)
        XCTAssertTrue(model.shouldPublishWidgetState)
        XCTAssertEqual(model.tokenHubQuotaSnapshot?.observedAt, base.addingTimeInterval(5),
            "C01 delayed response retains the actual worker-start observation time")
        XCTAssertNil(model.freshTokenHubQuota(at: model.tokenHubNow()),
            "C01 the existing freshness getter re-reads the model's injected current clock after the delayed response")
        XCTAssertTrue(model.title.hasPrefix("— |"),
            "C01 menu title does not present a response older than its freshness horizon")
        model.invalidateTokenHubQuota(status: .targetNotRunning)
        XCTAssertNil(model.tokenHubQuotaSnapshot)
        XCTAssertTrue(model.shouldPublishWidgetState, "断连必须发布未知，不保留成功快照")
    }
}
#endif

#if TOKENSTAT_BP38_C02
extension TokenHubQuotaStateTests {
    func testBP38C02TimerProjectionAndBetweenTickResponseReachEveryPresentationSurface() async throws {
        _ = NSApplication.shared
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let wall = BP38LockedWallClock(base)
        let monotonic = BP38LockedMonotonicClock()
        let scheduler = BP38ManualScheduler(monotonic: monotonic)
        let timing = AppModelTimingDependencies(wallNow: { wall.now },
            monotonicNow: { monotonic.now }, schedule: { delay, operation in
                scheduler.schedule(delay, operation)
            })
        let identity = TokenHubIdentity(pid: 85_102, bundleID: TokenHubTarget.bundleID,
            executablePath: "/Synthetic/Quota Projection Hub")
        func makeSnapshot(_ observedAt: Date, fiveReset: Date, sevenReset: Date,
                          fivePercent: Decimal = 95, sevenPercent: Decimal = 80) -> TokenHubQuotaSnapshot {
            TokenHubQuotaSnapshot(identity: identity,
                fiveHour: TokenHubWindowQuota(kind: .fiveHour, usedAmount: fivePercent, limitAmount: 100,
                    sourceSymbol: "$", usedPercent: fivePercent, resetDisplay: "synthetic 5h", resetAt: fiveReset),
                sevenDay: TokenHubWindowQuota(kind: .sevenDay, usedAmount: sevenPercent, limitAmount: 100,
                    sourceSymbol: "$", usedPercent: sevenPercent, resetDisplay: "synthetic 7d", resetAt: sevenReset),
                monthly: TokenHubMonthlyUsage(usedAmount: 96, sourceSymbol: "$", limitAmount: 100),
                observedAt: observedAt)
        }
        let source = BP38QuotaSnapshotBox(makeSnapshot(base,
            fiveReset: base.addingTimeInterval(10), sevenReset: base.addingTimeInterval(80)))
        let requests = OSAllocatedUnfairLock(initialState: 0)
        let direct = TokenHubDirectQuotaDependencies(discoverTarget: { identity },
            identityIsCurrent: { $0 == identity }, fetch: { _, _ in
                requests.withLock { $0 += 1 }
                return source.value
            })
        let permission = HubTestPermission(); permission.trusted = false
        let model = AppModel(preview: true, timing: timing, directQuota: direct,
            tokenHubPermissionProvider: permission,
            tokenHubAXSource: HubTestScanner(result: TokenHubQuotaResult(
                status: .targetNotRunning, snapshot: nil, failure: nil)).source)
        defer { model.shutdown() }
        model.config.dataSource = "localCodex"
        model.tokenHubAutomaticReadingEnabled = false

        model.refreshTokenHubQuota()
        await settle(model, status: .connected)
        XCTAssertEqual(requests.withLock { $0 }, 1)

        // No response arrives. A menu tick at reset equality updates the same
        // projection consumed by title, tooltip, diagnostics and the card.
        wall.set(base.addingTimeInterval(10))
        var publications = 0
        let observer = model.objectWillChange.sink { publications += 1 }
        model.tick()
        XCTAssertLessThanOrEqual(publications, 1, "C02 one timer tick publishes an expiry transition at most once")
        for _ in 0..<20 { model.tick() }
        XCTAssertLessThanOrEqual(publications, 1, "C02 repeated no-response ticks do not republish unchanged expired state")
        let projected = model.quotaPresentation
        XCTAssertNil(projected.fiveHourCurrent)
        XCTAssertNotNil(projected.sevenDayCurrent)
        XCTAssertNotNil(projected.monthlyCurrent)
        XCTAssertTrue(projected.fiveHour?.resetPassed == true)
        XCTAssertTrue(projected.sevenDay?.fresh == true)
        XCTAssertEqual(model.tokenHubQuotaSnapshot, source.value,
            "timer expiry projects current facts while retaining the raw source snapshot")
        XCTAssertFalse(model.title.contains("95.00%"))
        XCTAssertTrue(model.title.contains("80.00%"))
        XCTAssertTrue(model.menuTooltip.contains("5 小时未知"))
        XCTAssertTrue(model.menuTooltip.contains("7 天"))
        XCTAssertEqual(model.alertColor, .systemYellow,
            "the live seven-day window alone continues to drive the 80% menu alert")
        XCTAssertEqual(model.presentationTimeState.fiveHour?.resetPassed, true)
        let card = TokenHubQuotaCard(presentation: projected, status: model.tokenHubQuotaStatusText,
            enabled: true, refreshSeconds: 60, directSource: true)
        XCTAssertEqual(card.presentation, projected,
            "quota card consumes the exact projection used by menu and diagnostic state")
        let cardHost = NSHostingView(rootView: card.frame(width: 420))
        cardHost.frame = NSRect(x: 0, y: 0, width: 420, height: 260)
        cardHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(cardHost.fittingSize.height, 0,
            "C02 projected state is consumable by the native quota card")

        let diagnosticsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStatMenu-BP38-C02-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: diagnosticsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: diagnosticsRoot) }
        let diagnosticURL = diagnosticsRoot.appendingPathComponent("synthetic-diagnostics.json")
        _ = NSApplication.shared
        let controller = StatusBarController(model: model, diagnosticsURL: diagnosticURL)
        controller.refreshTitle()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: diagnosticURL.path) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let diagnosticData = try Data(contentsOf: diagnosticURL)
        let diagnostic = try XCTUnwrap(try JSONSerialization.jsonObject(with: diagnosticData) as? [String: Any])
        XCTAssertEqual(diagnostic["fiveHourPresent"] as? Bool, false)
        XCTAssertEqual(diagnostic["sevenDayPresent"] as? Bool, true)
        XCTAssertEqual(diagnostic["monthlyUsagePresent"] as? Bool, true)
        XCTAssertEqual(diagnostic["resetTimePresent"] as? Bool, true,
            "C02 diagnostics retain reset presence for the still-current sibling window")
        XCTAssertEqual(requests.withLock { $0 }, 1, "expiry tick issues no new quota request")

        // A response between ticks replaces the raw snapshot and projection.
        let betweenTick = makeSnapshot(base.addingTimeInterval(11),
            fiveReset: base.addingTimeInterval(50), sevenReset: base.addingTimeInterval(80),
            fivePercent: 40, sevenPercent: 50)
        source.set(betweenTick)
        wall.set(base.addingTimeInterval(11))
        model.refreshTokenHubQuota()
        for _ in 0..<100 where model.tokenHubQuotaSnapshot != betweenTick { await Task.yield() }
        XCTAssertEqual(model.tokenHubQuotaSnapshot, betweenTick)
        XCTAssertEqual(model.quotaPresentation.fiveHourCurrent, betweenTick.fiveHour)
        XCTAssertEqual(model.quotaPresentation.sevenDayCurrent, betweenTick.sevenDay)
        XCTAssertEqual(requests.withLock { $0 }, 2)

        // A following timer tick must publish the replacement's 5-hour reset
        // through every model-facing surface while the 7-day sibling remains.
        wall.set(base.addingTimeInterval(51))
        model.tick()
        let fiveHourOutput = diagnosticsRoot.appendingPathComponent("five-hour-reset.json")
        let fiveHourController = StatusBarController(model: model, diagnosticsURL: fiveHourOutput)
        fiveHourController.refreshTitle()
        XCTAssertNil(model.quotaPresentation.fiveHourCurrent)
        XCTAssertNotNil(model.quotaPresentation.sevenDayCurrent)
        XCTAssertEqual(model.alertColor, .labelColor)
        XCTAssertFalse(model.title.contains("60.00%"))
        XCTAssertTrue(model.title.contains("50.00%"))
        XCTAssertTrue(model.menuTooltip.contains("5 小时未知"))
        XCTAssertTrue(model.menuTooltip.contains("7 天额度"))
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: fiveHourOutput.path) { await Task.yield() }
        let fiveHourData = try Data(contentsOf: fiveHourOutput)
        let fiveHourDiagnostic = try XCTUnwrap(try JSONSerialization.jsonObject(with: fiveHourData) as? [String: Any])
        XCTAssertEqual(fiveHourDiagnostic["fiveHourPresent"] as? Bool, false)
        XCTAssertEqual(fiveHourDiagnostic["sevenDayPresent"] as? Bool, true)
        XCTAssertEqual(fiveHourDiagnostic["monthlyUsagePresent"] as? Bool, true)
        XCTAssertEqual(fiveHourDiagnostic["resetTimePresent"] as? Bool, true)
        XCTAssertEqual(model.tokenHubQuotaSnapshot, betweenTick,
            "C02 response remains the raw source fact as the first replacement window expires")
        withExtendedLifetime(observer) {}

        wall.set(base.addingTimeInterval(81))
        model.tick()
        let sevenDayOutput = diagnosticsRoot.appendingPathComponent("seven-day-reset.json")
        let sevenDayController = StatusBarController(model: model, diagnosticsURL: sevenDayOutput)
        sevenDayController.refreshTitle()
        XCTAssertNil(model.quotaPresentation.fiveHourCurrent)
        XCTAssertNil(model.quotaPresentation.sevenDayCurrent,
            "the following tick expires the seven-day window at its own reset")
        XCTAssertNotNil(model.quotaPresentation.monthlyCurrent)
        XCTAssertTrue(model.title.hasPrefix("— | — |"))
        XCTAssertTrue(model.title.hasPrefix("— | — |"))
        XCTAssertTrue(model.menuTooltip.contains("5 小时未知"))
        XCTAssertTrue(model.menuTooltip.contains("7 天未知"))
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: sevenDayOutput.path) { await Task.yield() }
        let sevenDayData = try Data(contentsOf: sevenDayOutput)
        let sevenDayDiagnostic = try XCTUnwrap(try JSONSerialization.jsonObject(with: sevenDayData) as? [String: Any])
        XCTAssertEqual(sevenDayDiagnostic["fiveHourPresent"] as? Bool, false)
        XCTAssertEqual(sevenDayDiagnostic["sevenDayPresent"] as? Bool, false)
        XCTAssertEqual(sevenDayDiagnostic["monthlyUsagePresent"] as? Bool, true)
        XCTAssertEqual(model.tokenHubQuotaSnapshot, betweenTick,
            "two expired rolling windows do not erase the independent monthly raw fact")
        XCTAssertEqual(requests.withLock { $0 }, 2)
    }

    func testBP38C02WindowResetProjectionIsIndependentAndPresentationWide() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = TokenHubIdentity(pid: 0, bundleID: TokenHubTarget.bundleID,
            executablePath: "/Synthetic/Projection Hub")
        func window(_ kind: TokenHubWindowKind, percent: Decimal, reset: Date?) -> TokenHubWindowQuota {
            TokenHubWindowQuota(kind: kind, usedAmount: percent, limitAmount: 100,
                sourceSymbol: "$", usedPercent: percent, resetDisplay: "synthetic", resetAt: reset)
        }
        func snapshot(observedAt: Date = base, fiveReset: Date?, sevenReset: Date?, percent: Decimal = 79) -> TokenHubQuotaSnapshot {
            TokenHubQuotaSnapshot(identity: identity,
                fiveHour: window(.fiveHour, percent: percent, reset: fiveReset),
                sevenDay: window(.sevenDay, percent: 34, reset: sevenReset),
                monthly: TokenHubMonthlyUsage(usedAmount: 45, sourceSymbol: "$", limitAmount: 100),
                observedAt: observedAt)
        }

        for focalWindow in [TokenHubWindowKind.fiveHour, .sevenDay] {
            let focalReset = base.addingTimeInterval(60)
            let siblingReset = base.addingTimeInterval(100)
            let raw = snapshot(fiveReset: focalWindow == .fiveHour ? focalReset : siblingReset,
                sevenReset: focalWindow == .sevenDay ? focalReset : siblingReset)
            func current(_ value: TokenHubQuotaPresentation) -> TokenHubWindowQuota? {
                focalWindow == .fiveHour ? value.fiveHourCurrent : value.sevenDayCurrent
            }
            let siblingBefore = TokenHubQuotaPresentation.project(snapshot: raw,
                now: focalReset.addingTimeInterval(-0.001), refreshSeconds: 60)
            XCTAssertNotNil(current(siblingBefore), "C02 \(focalWindow) remains current immediately before its reset")
            XCTAssertNotNil(focalWindow == .fiveHour ? siblingBefore.sevenDayCurrent : siblingBefore.fiveHourCurrent)
            let atReset = TokenHubQuotaPresentation.project(snapshot: raw, now: focalReset, refreshSeconds: 60)
            XCTAssertNil(current(atReset), "C02 \(focalWindow) expires at reset equality")
            XCTAssertNotNil(focalWindow == .fiveHour ? atReset.sevenDayCurrent : atReset.fiveHourCurrent,
                "C02 the sibling window stays current at the focal reset")
            XCTAssertNotNil(atReset.monthlyCurrent, "C02 rolling-window expiry preserves monthly usage")
            let afterReset = TokenHubQuotaPresentation.project(snapshot: raw,
                now: focalReset.addingTimeInterval(0.001), refreshSeconds: 60)
            XCTAssertNil(current(afterReset), "C02 \(focalWindow) remains expired immediately after its reset")
            XCTAssertNotNil(focalWindow == .fiveHour ? afterReset.sevenDayCurrent : afterReset.fiveHourCurrent,
                "C02 the sibling window stays current immediately after the focal reset")
            XCTAssertTrue(focalWindow == .fiveHour ? atReset.fiveHour?.resetPassed == true : atReset.sevenDay?.resetPassed == true)
        }

        let nilReset = snapshot(fiveReset: nil, sevenReset: base.addingTimeInterval(900))
        let missingReset = TokenHubQuotaPresentation.project(snapshot: nilReset,
            now: base.addingTimeInterval(30), refreshSeconds: 60)
        XCTAssertNotNil(missingReset.fiveHourCurrent, "missing reset does not discard a fresh percentage")
        XCTAssertNil(missingReset.fiveHour?.resetAt, "missing reset remains explicitly unknown")
        XCTAssertNotNil(missingReset.sevenDayCurrent)

        for (refresh, inclusiveAge) in [(60.0, 120.0), (300.0, 600.0)] {
            let timed = snapshot(observedAt: base, fiveReset: nil, sevenReset: nil)
            XCTAssertNotNil(TokenHubQuotaPresentation.project(snapshot: timed,
                now: base.addingTimeInterval(inclusiveAge), refreshSeconds: refresh).fiveHourCurrent,
                "C02 snapshot age boundary is inclusive for refresh interval \(refresh)")
            XCTAssertNil(TokenHubQuotaPresentation.project(snapshot: timed,
                now: base.addingTimeInterval(inclusiveAge + 0.001), refreshSeconds: refresh).fiveHourCurrent,
                "C02 snapshot expires immediately above max(120, 2×refresh) for \(refresh)")
            if refresh == 300 {
                XCTAssertNotNil(TokenHubQuotaPresentation.project(snapshot: timed,
                    now: base.addingTimeInterval(120.001), refreshSeconds: refresh).fiveHourCurrent,
                    "C02 120.001-second snapshot remains fresh when 300-second refresh policy allows 600 seconds")
            }

            let legacyData = try JSONSerialization.data(withJSONObject: ["data": ["five_hour": [
                "used_percent": 50
            ]]])
            let legacyWindow = try XCTUnwrap(QuotaReport.parse(legacyData,
                config: AppConfiguration(), now: base).fiveHour)
            XCTAssertTrue(legacyWindow.isFresh(at: base.addingTimeInterval(inclusiveAge - 0.001),
                refreshSeconds: refresh),
                "C02 legacy WindowQuota remains fresh immediately before its strict max-age boundary at refresh \(refresh)")
            XCTAssertFalse(legacyWindow.isFresh(at: base.addingTimeInterval(inclusiveAge),
                refreshSeconds: refresh),
                "C02 legacy WindowQuota expires at its strict max-age equality at refresh \(refresh)")
            XCTAssertFalse(legacyWindow.isFresh(at: base.addingTimeInterval(inclusiveAge + 0.001),
                refreshSeconds: refresh),
                "C02 legacy WindowQuota remains expired immediately after its strict max-age boundary at refresh \(refresh)")
        }

        let monthlyOnly = TokenHubQuotaSnapshot(identity: identity, fiveHour: nil, sevenDay: nil,
            monthly: TokenHubMonthlyUsage(usedAmount: 95, sourceSymbol: "$", limitAmount: 100),
            observedAt: base)
        let monthlyProjection = TokenHubQuotaPresentation.project(snapshot: monthlyOnly, now: base, refreshSeconds: 60)
        XCTAssertNotNil(monthlyProjection.monthlyCurrent)
        XCTAssertEqual(monthlyProjection.menuAlertLevel, .none,
            "C02 monthly-only usage stays diagnosable but never drives the menu alert")

        let thresholds: [(String, Decimal, TokenHubQuotaPresentation.AlertLevel)] = [
            ("79.995", Decimal(string: "79.995")!, .none),
            ("80", Decimal(80), .warning),
            ("94.995", Decimal(string: "94.995")!, .warning),
            ("95", Decimal(95), .critical)
        ]
        for (label, percent, expected) in thresholds {
            let projection = TokenHubQuotaPresentation.project(
                snapshot: snapshot(fiveReset: nil, sevenReset: nil, percent: percent),
                now: base, refreshSeconds: 60)
            XCTAssertEqual(projection.menuAlertLevel, expected,
                "C02 menu threshold uses exact Decimal \(label), before display rounding")
        }

        // Card and model-facing presentation use the same immutable projection,
        // preventing independently refreshed copies of one snapshot.
        let fixedTimeSnapshot = snapshot(fiveReset: nil, sevenReset: nil)
        let fixedTimeProjection = TokenHubQuotaPresentation.project(snapshot: fixedTimeSnapshot,
            now: base, refreshSeconds: 60)
        XCTAssertEqual(fixedTimeProjection, TokenHubQuotaPresentation.project(snapshot: fixedTimeSnapshot,
            now: base, refreshSeconds: 60))
    }
}
#endif

#if TOKENSTAT_BP38_C03
extension TokenHubQuotaStateTests {
    func testBP38C03PrunesBeforeGuardsAndBeforePanelOpen() {
        _ = NSApplication.shared
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let wall = BP38LockedWallClock(base)
        let monotonic = BP38LockedMonotonicClock()
        let scheduler = BP38ManualScheduler(monotonic: monotonic)
        let timing = AppModelTimingDependencies(wallNow: { wall.now },
            monotonicNow: { monotonic.now }, schedule: { delay, operation in
                scheduler.schedule(delay, operation)
            })
        let model = AppModel(preview: true, timing: timing)
        defer { model.shutdown() }
        model.config.dataSource = "localCodex"
        let tooOld = SpeedPoint(date: base.addingTimeInterval(-600.001), value: 1)
        let exactBoundary = SpeedPoint(date: base.addingTimeInterval(-600), value: 2)
        let nearNow = SpeedPoint(date: base.addingTimeInterval(-599.999), value: 3)
        let rollbackVictim = SpeedPoint(date: base.addingTimeInterval(-0.001), value: 4)
        let initiallyFuture = SpeedPoint(date: base.addingTimeInterval(0.001), value: 5)
        model.history = [tooOld, exactBoundary, nearNow, rollbackVictim, initiallyFuture]
        var prunePublications = 0
        let pruneObserver = model.objectWillChange.sink { prunePublications += 1 }
        model.tick() // Hidden and idle: pruning must precede both guards.
        XCTAssertLessThanOrEqual(prunePublications, 1,
            "C03 one changed maintenance tick publishes at most once while pruning")
        XCTAssertEqual(model.history.map(\.id), [exactBoundary.id, nearNow.id, rollbackVictim.id],
            "C03 first idle tick keeps the exact age-600 point and the two current points")
        XCTAssertEqual(model.history.map(\.date), [base.addingTimeInterval(-600), base.addingTimeInterval(-599.999), base.addingTimeInterval(-0.001)],
            "C03 idle hidden tick keeps only timestamps in the closed [now-600, now] interval")
        wall.set(base.addingTimeInterval(-0.5)) // Rollback makes the near-now point future.
        model.tick()
        XCTAssertEqual(model.history.map(\.id), [exactBoundary.id, nearNow.id],
            "C03 rollback prunes the formerly valid near-now point and keeps the older in-range IDs")
        XCTAssertEqual(model.history.map(\.date), [base.addingTimeInterval(-600), base.addingTimeInterval(-599.999)],
            "C03 rollback retains exact survivors inside the new closed interval")
        wall.set(base)

        model.history = [SpeedPoint(date: base.addingTimeInterval(-601), value: 99),
                         SpeedPoint(date: base.addingTimeInterval(1), value: 88)]
        model.localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0,
            sessionCount: 0, filesScanned: 0, isLimited: false, latestEventAt: nil,
            fiveHour: nil, sevenDay: nil)
        let controller = StatusBarController(model: model)
        controller.show()
        XCTAssertTrue(model.history.isEmpty, "C03 panel opening prunes stale and future points before the first displayed frame")
        controller.toggle()
        withExtendedLifetime(pruneObserver) {}
    }

    func testBP38C03MonotonicCadenceFiniteValuesStableIDsAndCapacity() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let wall = BP38LockedWallClock(base)
        let monotonic = BP38LockedMonotonicClock()
        let scheduler = BP38ManualScheduler(monotonic: monotonic)
        let timing = AppModelTimingDependencies(wallNow: { wall.now },
            monotonicNow: { monotonic.now }, schedule: { delay, operation in
                scheduler.schedule(delay, operation)
            })
        let model = AppModel(preview: true, timing: timing)
        defer { model.shutdown() }
        model.config.dataSource = "localCodex"
        model.panelVisible = true

        func supply(_ wallNow: Date, _ value: Double) {
            wall.set(wallNow)
            model.localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0,
                sessionCount: 1, filesScanned: 1, isLimited: false, latestEventAt: wallNow,
                fiveHour: nil, sevenDay: nil, knownThreadCount: 1,
                liveTurn: LocalLiveTurnSummary(inputTPS: 0, outputTPS: value, observedAt: wallNow))
            model.tick()
        }
        supply(base, 0)
        XCTAssertEqual(model.history.last?.value, 0, "C03 accepts a measured current zero")
        let firstID = model.history.last?.id
        scheduler.advance(to: 0.499)
        supply(base.addingTimeInterval(1), 8)
        XCTAssertEqual(model.history.count, 1,
            "C03 wall time above .5 cannot bypass a .499 monotonic interval")
        scheduler.advance(to: 0.5)
        supply(base, 8)
        let retainedID = model.history.first?.id
        XCTAssertEqual(retainedID, firstID, "C03 retained samples keep their original stable identifiers")
        XCTAssertEqual(model.history.count, 2,
            "C03 monotonic .5 permits sampling despite wall-clock rollback")

        for index in 3...1_301 {
            scheduler.advance(to: Double(index) * 0.5)
            supply(base.addingTimeInterval(Double(index) * 0.5), 8)
        }
        XCTAssertEqual(model.history.count, 1_200, "C03 keeps the newest 1,200 of more than 1,300 eligible samples")
        XCTAssertEqual(Set(model.history.map(\.id)).count, 1_200, "C03 retained sample identities are unique")
        XCTAssertEqual(model.history.last?.date, base.addingTimeInterval(1_301 * 0.5))

        let countBeforeInvalid = model.history.count
        let lastDateBeforeInvalid = model.history.last?.date
        scheduler.advance(to: 651)
        supply(base.addingTimeInterval(651), .infinity)
        XCTAssertLessThanOrEqual(model.history.count, countBeforeInvalid, "C03 pruning may remove old points while a non-finite rate adds none")
        XCTAssertEqual(model.history.last?.date, lastDateBeforeInvalid, "C03 non-finite rate does not append a point")
        scheduler.advance(to: 651.5)
        supply(base.addingTimeInterval(651.5), -1)
        XCTAssertEqual(model.history.last?.date, lastDateBeforeInvalid, "C03 negative rate does not append a point")
        scheduler.advance(to: 652)
        supply(base.addingTimeInterval(652), 0)
        XCTAssertEqual(model.history.last?.date, base.addingTimeInterval(652))
        XCTAssertEqual(model.history.last?.value, 0, "C03 a later real zero remains distinguishable from unknown speed")

        let retainedLatest = model.history.last?.date
        let retainedLatestID = model.history.last?.id
        scheduler.advance(to: 652.5)
        model.localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0,
            sessionCount: 0, filesScanned: 0, isLimited: false, latestEventAt: nil,
            fiveHour: nil, sevenDay: nil)
        model.tick()
        XCTAssertEqual(model.history.last?.date, retainedLatest,
            "C03 unknown current speed does not manufacture a zero sample")
        XCTAssertEqual(model.history.last?.id, retainedLatestID)
        scheduler.advance(to: 653)
        model.localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0,
            sessionCount: 1, filesScanned: 1, isLimited: false, latestEventAt: nil,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 1,
            liveTurn: LocalLiveTurnSummary(inputTPS: 0, outputTPS: 42,
                observedAt: base.addingTimeInterval(652 - 15.001)))
        model.tick()
        XCTAssertEqual(model.history.last?.date, retainedLatest,
            "C03 stale speed does not manufacture a zero sample or extend the series")
        XCTAssertEqual(model.history.last?.id, retainedLatestID)
        scheduler.advance(to: 653.5)
        model.localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0,
            sessionCount: 1, filesScanned: 1, isLimited: false, latestEventAt: nil,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 1,
            liveTurn: LocalLiveTurnSummary(inputTPS: 0, outputTPS: 42,
                observedAt: wall.now.addingTimeInterval(0.001)))
        model.tick()
        XCTAssertEqual(model.history.last?.id, retainedLatestID,
            "C03 future observation is rejected with cadence otherwise eligible")
        scheduler.advance(to: 654)
        supply(wall.now, .nan)
        XCTAssertEqual(model.history.last?.id, retainedLatestID,
            "C03 NaN observation is rejected with cadence otherwise eligible")
        scheduler.advance(to: 654.5)
        supply(wall.now.addingTimeInterval(0.5), 0)
        XCTAssertEqual(model.history.last?.value, 0,
            "C03 legitimate current zero is accepted after eligible negative cases")

        // One tick both prunes out-of-window points and appends a current
        // measurement. Seed all test input before measuring history publishes.
        let combinedNow = wall.now.addingTimeInterval(1)
        wall.set(combinedNow)
        model.localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0,
            sessionCount: 1, filesScanned: 1, isLimited: false, latestEventAt: combinedNow,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 1,
            liveTurn: LocalLiveTurnSummary(inputTPS: 0, outputTPS: 7, observedAt: combinedNow))
        let prunedPoint = SpeedPoint(date: combinedNow.addingTimeInterval(-601), value: 90)
        let eligiblePoints = (0..<1_200).map { index in
            SpeedPoint(date: combinedNow.addingTimeInterval(-Double(1_199 - index) * 0.4), value: Double(index))
        }
        let futurePoint = SpeedPoint(date: combinedNow.addingTimeInterval(1), value: 92)
        model.history = [prunedPoint] + eligiblePoints + [futurePoint]
        let retainedIDsAfterCap = eligiblePoints.dropFirst().map(\.id)
        var combinedHistoryPublications = 0
        let combinedObserver = model.$history.dropFirst().sink { _ in combinedHistoryPublications += 1 }
        scheduler.advance(to: 655)
        model.tick()
        XCTAssertLessThanOrEqual(combinedHistoryPublications, 1,
            "C03 prune, capacity trim and append publish at most once in one maintenance tick")
        XCTAssertEqual(model.history.count, 1_200,
            "C03 combined prune and append still enforces the 1,200-point cap")
        XCTAssertEqual(Array(model.history.dropLast().map(\.id)), Array(retainedIDsAfterCap),
            "C03 combined capacity update preserves IDs of retained points")
        XCTAssertEqual(model.history.last?.date, combinedNow)
        XCTAssertEqual(Set(model.history.map(\.id)).count, model.history.count)
        withExtendedLifetime(combinedObserver) {}

        var publications = 0
        let observer = model.objectWillChange.sink { publications += 1 }
        model.tick()
        XCTAssertEqual(publications, 0, "C03 unchanged history state publishes zero times")
        withExtendedLifetime(observer) {}
    }
}
#endif

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
    private(set) var observedDates: [Date] = []
    func scan(now: Date, generation: Int) async throws -> LocalCodexScanWorker.Result {
        requests += 1
        observedDates.append(now)
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

private actor BP39LocalInvalidationRecorder {
    private(set) var generations: [Int] = []
    private(set) var resolvedPaths: [String] = []
    private(set) var scannedGenerations: [Int] = []

    func recordInvalidation(generation: Int) {
        generations.append(generation)
    }

    func recordScan(path: URL, generation: Int) {
        resolvedPaths.append(path.standardizedFileURL.path)
        scannedGenerations.append(generation)
    }

    func snapshot() -> (generations: [Int], resolvedPaths: [String], scannedGenerations: [Int]) {
        (generations, resolvedPaths, scannedGenerations)
    }
}

@MainActor
private final class BP39BackgroundGate {
    var enabled = true
}

extension TokenHubQuotaStateTests {
    private func workerFixture(eventAt: Date? = nil) throws -> (URL, Date) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TokenStatMenu-C23B-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stamp = ISO8601DateFormatter().string(from: eventAt ?? now)
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

    private func localConsumer(_ harness: ControlledLocalScan,
                               timing: AppModelTimingDependencies = .production) -> AppModel {
        let noHub = TokenHubDirectQuotaDependencies(discoverTarget: { throw TokenHubQuotaFailure.noTarget },
            identityIsCurrent: { _ in false }, fetch: { _, _ in throw TokenHubDirectQuotaFailure.transportFailed })
        let source = LocalCodexScanDependencies(resolveInputs: {
            (directory: URL(fileURLWithPath: "/synthetic-unused-local-scan"), routeContext: .unverified)
        }, scan: { _, now, generation, _ in try await harness.scan(now: now, generation: generation) })
        let permission = HubTestPermission(); permission.trusted = false
        let model = AppModel(startup: AppModelStartupDependencies(loadPreferences: { nil },
            savePreferences: { _ in }, shouldStartBackgroundServices: { true },
            observeWorkspaceNotifications: false), timing: timing,
            directQuota: noHub, localScanning: source,
            tokenHubPermissionProvider: permission,
            tokenHubAXSource: HubTestScanner(result: TokenHubQuotaResult(
                status: .targetNotRunning, snapshot: nil, failure: nil)).source)
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
        model.history = [SpeedPoint(date: Date(timeIntervalSince1970: 1_800_000_000), value: 77)]
        model.reload()
        XCTAssertTrue(model.history.isEmpty,
            "C03 generation reload clears retained history before the new generation samples")
        try? await Task.sleep(for: .milliseconds(20))
        let requestsWhileOldReadRuns = await harness.requests
        XCTAssertEqual(requestsWhileOldReadRuns, 1, "reload must not overlap the old local read")
        await harness.completeFirst(total: 111)
        await waitForLocalRequests(2, harness: harness)
        XCTAssertEqual(model.localSnapshot.total, 0, "the old generation must not publish after reload")
        XCTAssertTrue(model.history.isEmpty, "C03 a late old-generation result cannot restore prior history")
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

    func testBP39WorkerInvalidationClearsSyntheticCacheAndRejectsOldGeneration() async throws {
        let (directory, now) = try workerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = LocalCodexScanWorker()

        let cold = try await worker.scan(directory: directory, now: now, generation: 41,
                                         routeContext: nil)
        let warm = try await worker.scan(directory: directory, now: now, generation: 41,
                                         routeContext: nil)
        XCTAssertEqual(cold.snapshot.total, 15)
        XCTAssertEqual(cold.diagnostics.parsedFiles, 1)
        XCTAssertEqual(warm.diagnostics.cacheHits, 1)
        XCTAssertEqual(warm.diagnostics.bytesRead, 0)
        XCTAssertEqual(cold.snapshot.details.count, 1)
        XCTAssertEqual(warm.snapshot.details, cold.snapshot.details)

        await worker.invalidate(generation: 42)
        var rejected = false
        do {
            _ = try await worker.scan(directory: directory, now: now, generation: 41,
                                      routeContext: nil)
        } catch {
            rejected = true
        }
        XCTAssertTrue(rejected,
                      "an invalidated local generation cannot publish or repopulate the old cache")

        let fresh = try await worker.scan(directory: directory, now: now, generation: 42,
                                          routeContext: nil)
        XCTAssertEqual(fresh.snapshot.total, 15)
        XCTAssertEqual(fresh.diagnostics.parsedFiles, 1,
                       "the larger generation continues on the synthetic directory")
        XCTAssertEqual(fresh.diagnostics.cacheHits, 0,
                       "invalidation clears the prior generation's file summaries")

        await worker.invalidate(generation: 41)
        let afterOldInvalidation = try await worker.scan(directory: directory, now: now, generation: 42,
                                                         routeContext: nil)
        XCTAssertEqual(afterOldInvalidation.diagnostics.cacheHits, 1,
                       "a late older invalidation cannot clear a newer generation's cache")
        XCTAssertEqual(afterOldInvalidation.snapshot.details, fresh.snapshot.details)

        await worker.invalidate(generation: 42)
        let afterSameGenerationInvalidation = try await worker.scan(directory: directory, now: now,
                                                                    generation: 42, routeContext: nil)
        XCTAssertEqual(afterSameGenerationInvalidation.diagnostics.cacheHits, 1,
                       "a late same-generation invalidation cannot clear the active generation's cache")
        XCTAssertEqual(afterSameGenerationInvalidation.diagnostics.bytesRead, 0)
        XCTAssertEqual(afterSameGenerationInvalidation.snapshot.details.map(\.opaqueKey),
                       afterOldInvalidation.snapshot.details.map(\.opaqueKey),
                       "same-generation invalidation preserves the current opaque detail keys")

        await worker.invalidate(generation: 43)
        let newer = try await worker.scan(directory: directory, now: now, generation: 43,
                                          routeContext: nil)
        XCTAssertEqual(newer.diagnostics.parsedFiles, 1)
        XCTAssertEqual(newer.diagnostics.cacheHits, 0,
                       "each newer invalidation starts with an empty bounded cache")
    }

    func testBP39AppModelInvalidatesWorkerOnGenerationChangesWithoutDefaultPath() async throws {
        let (directory, now) = try workerFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = LocalCodexScanWorker()
        let recorder = BP39LocalInvalidationRecorder()
        let syntheticPath = directory.standardizedFileURL.path
        let backgroundGate = BP39BackgroundGate()
        let scheduling = AppModelTimingDependencies.production
        let timing = AppModelTimingDependencies(wallNow: { now },
            monotonicNow: scheduling.monotonicNow, schedule: scheduling.schedule)

        let noHub = TokenHubDirectQuotaDependencies(
            discoverTarget: { throw TokenHubQuotaFailure.noTarget },
            identityIsCurrent: { _ in false },
            fetch: { _, _ in throw TokenHubDirectQuotaFailure.transportFailed })
        let source = LocalCodexScanDependencies(
            resolveInputs: {
                (directory, .unverified)
            },
            scan: { resolved, scanNow, generation, _ in
                await recorder.recordScan(path: resolved, generation: generation)
                return try await worker.scan(directory: resolved, now: scanNow,
                                             generation: generation, routeContext: nil)
            },
            invalidate: { generation in
                await recorder.recordInvalidation(generation: generation)
                await worker.invalidate(generation: generation)
            })
        let permission = HubTestPermission(); permission.trusted = false
        let model = AppModel(
            startup: AppModelStartupDependencies(
                loadPreferences: { nil }, savePreferences: { _ in },
                shouldStartBackgroundServices: { backgroundGate.enabled },
                observeWorkspaceNotifications: false),
            timing: timing,
            directQuota: noHub, localScanning: source,
            tokenHubPermissionProvider: permission,
            tokenHubAXSource: HubTestScanner(
                result: TokenHubQuotaResult(status: .targetNotRunning, snapshot: nil,
                failure: nil)).source)
        var didShutdown = false
        defer {
            if !didShutdown { model.shutdown() }
        }

        func waitForInvalidations(_ minimum: Int) async -> [Int] {
            for _ in 0..<200 {
                let current = await recorder.snapshot().generations
                if current.count >= minimum { return current }
                try? await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("local invalidation callback did not receive generation \(minimum)")
            return await recorder.snapshot().generations
        }

        func waitForPublishedDetails() async {
            for _ in 0..<200 {
                if model.localSnapshot.details.count == 1 { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("the real synthetic scan must publish details before a lifecycle transition")
        }

        let initial = await waitForInvalidations(1)
        XCTAssertTrue(initial.allSatisfy { $0 >= 1 })
        await waitForPublishedDetails()
        XCTAssertEqual(model.localSnapshot.total, 15)
        backgroundGate.enabled = false
        model.reload()
        let stopped = await waitForInvalidations(initial.count + 1)
        XCTAssertTrue(model.localSnapshot.details.isEmpty,
                      "stopping a source must clear retained opaque detail rows")
        backgroundGate.enabled = true
        model.reload()
        let restarted = await waitForInvalidations(stopped.count + 1)
        await waitForPublishedDetails()
        XCTAssertEqual(model.localSnapshot.total, 15,
                       "the next generation can publish the independently read synthetic snapshot")
        model.shutdown()
        didShutdown = true
        let shutDown = await waitForInvalidations(restarted.count + 1)
        XCTAssertTrue(model.localSnapshot.details.isEmpty,
                      "shutdown must not retain the prior generation's opaque detail rows")

        XCTAssertTrue(zip(shutDown, shutDown.dropFirst()).allSatisfy { $0 < $1 },
                      "each AppModel lifecycle transition invalidates with a strictly newer generation")
        let recorded = await recorder.snapshot()
        let paths = recorded.resolvedPaths
        XCTAssertFalse(paths.isEmpty, "the actual injected scan path was exercised")
        XCTAssertTrue(paths.allSatisfy { $0 == syntheticPath },
                      "no lifecycle check may discover or read the production default sessions path")
        XCTAssertGreaterThanOrEqual(recorded.scannedGenerations.count, 2)
        XCTAssertEqual(Set(recorded.scannedGenerations).count, 2,
                       "only the two enabled lifecycle generations perform a synthetic scan")
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
        XCTAssertTrue(model.title.contains("40.00%"))

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
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let wall = OSAllocatedUnfairLock(initialState: base)
        let monotonic = OSAllocatedUnfairLock(initialState: 0.0)
        let timing = AppModelTimingDependencies(wallNow: { wall.withLock { $0 } },
            monotonicNow: { monotonic.withLock { $0 } }, schedule: { _, _ in { } })
        let model = AppModel(preview: true, timing: timing)
        defer { model.shutdown() }
        model.config.dataSource = "localCodex"
        model.panelVisible = true
        var now = base
        for index in 0..<1_300 {
            now = base.addingTimeInterval(Double(index) * 0.5)
            wall.withLock { $0 = now }
            monotonic.withLock { $0 = Double(index) * 0.5 }
            model.localSnapshot = LocalCodexSnapshot(input: 10, output: 20, total: 30,
                sessionCount: 1, filesScanned: 1, isLimited: false, latestEventAt: now,
                fiveHour: nil, sevenDay: nil, knownThreadCount: 1, unknownThreadCount: 0,
                liveTurn: LocalLiveTurnSummary(inputTPS: 4, outputTPS: 8, observedAt: now))
            model.tick()
        }
        XCTAssertEqual(model.history.count, 1_200)
        XCTAssertTrue(model.activityIsLive)
#if TOKENSTAT_BP38_C03
        let priorIDs = Set(model.history.map(\.id))
#else
        let retained = model.history.count
#endif
        now = now.addingTimeInterval(16)
        wall.withLock { $0 = now }
        monotonic.withLock { $0 += 16 }
        model.localSnapshot = LocalCodexSnapshot(input: 10, output: 20, total: 30,
            sessionCount: 1, filesScanned: 1, isLimited: false, latestEventAt: now,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 1, unknownThreadCount: 0,
            liveTurn: LocalLiveTurnSummary(inputTPS: 4, outputTPS: 8, observedAt: now.addingTimeInterval(-16)))
        model.tick()
        XCTAssertFalse(model.activityIsLive)
#if TOKENSTAT_BP38_C03
        let currentIDs = Set(model.history.map(\.id))
        XCTAssertTrue(currentIDs.isSubset(of: priorIDs),
            "stale estimates do not append a new history point or synthetic zero")
        XCTAssertTrue(model.history.allSatisfy { $0.date >= now.addingTimeInterval(-600) && $0.date <= now },
            "history retains only points in the closed ten-minute interval at the current wall time")
#else
        XCTAssertEqual(model.history.count, retained,
            "stale estimates do not append synthetic zero points")
#endif
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
    private func bp39UIWriteFixture(now: Date, uuid: String, cacheLiteral: String?,
                                   input: Int = 100, output: Int = 20, total: Int = 120,
                                   in directory: URL? = nil) throws -> URL {
        let root = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenstat-bp39-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = cacheLiteral.map { ",\"cached_input_tokens\":\($0)" } ?? ""
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(uuid)\",\"source\":\"cli\"}}"
        let event = "{\"timestamp\":\"\(ISO8601DateFormatter().string(from: now))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"total_tokens\":\(total)\(cache)}}}}"
        let url = root.appendingPathComponent("rollout-\(uuid).jsonl")
        try Data("\(meta)\n\(event)\n".utf8).write(to: url)
        return root
    }

    /// Cold/warm controls exercise the real reader; file-cache reuse is not a
    /// model cache hit. Literal fixture values below supply the expectations.
    private func bp39UIScanPair(_ directory: URL, now: Date) throws -> LocalCodexSnapshot {
        let cache = LocalCodexUsageReader.Cache()
        let cold = try LocalCodexUsageReader.scan(directory: directory, now: now, cache: cache)
        let warm = try LocalCodexUsageReader.scan(directory: directory, now: now, cache: cache)
        XCTAssertEqual(warm, cold, "DM-A07 warm scans preserve the same bounded value projection")
        XCTAssertGreaterThan(cache.diagnostics.cacheHits, 0)
        XCTAssertEqual(cache.diagnostics.bytesRead, 0)
        return cold
    }

    private func bp39UIModel(_ snapshot: LocalCodexSnapshot, now: Date) -> AppModel {
        let model = AppModel(preview: true)
        model.config.dataSource = "localCodex"
        model.tokenHubNow = { now }
        model.localSnapshot = snapshot
        return model
    }

    private func bp39UIFact(_ text: String, containing marker: String,
                           file: StaticString = #filePath, line: UInt = #line) -> String {
        let fact = text.split(separator: "\n").map(String.init).first {
            $0.range(of: marker, options: .caseInsensitive) != nil
        }
        XCTAssertNotNil(fact, "DM-A07 presentation must expose \(marker)", file: file, line: line)
        return fact ?? ""
    }

    private func bp39UIHasSourceReason(_ fact: String, reason: [String]) -> Bool {
        reason.contains { fact.contains($0) }
    }

    private func bp39UIAssertUnknown(_ text: String, marker: String, reason: [String],
                                    file: StaticString = #filePath, line: UInt = #line) {
        let fact = bp39UIFact(text, containing: marker, file: file, line: line)
        XCTAssertTrue(fact.contains("未知"), "\(marker) must be unknown", file: file, line: line)
        XCTAssertTrue(bp39UIHasSourceReason(fact, reason: reason),
                      "\(marker) must explain its own missing/invalid source; synthetic fact: \(String(fact.prefix(300)))",
                      file: file, line: line)
    }

    func testBP39DetailedMetricsPresentationSeparatesKnownCacheAndUnknown() throws {
        let now = Date(timeIntervalSince1970: 1_797_000_000)
        let knownRoot = try bp39UIWriteFixture(now: now.addingTimeInterval(-60),
            uuid: "b0390000-0000-4000-8000-000000000001", cacheLiteral: "35")
        defer { try? FileManager.default.removeItem(at: knownRoot) }
        let known = try bp39UIScanPair(knownRoot, now: now)
        let model = bp39UIModel(known, now: now)
        defer { model.shutdown() }
        let knownText = model.menuTooltip
        XCTAssertEqual(known.readAt, now)
        XCTAssertEqual(known.latestEventAt, now.addingTimeInterval(-60))
        XCTAssertEqual(known.cacheCoverage.state, .complete)
        XCTAssertEqual(known.cacheCoverage.cachedInputTokens, 35)
        XCTAssertEqual(known.cacheCoverage.uncachedInputTokens, 65)
        XCTAssertTrue(bp39UIFact(knownText, containing: "缓存读取").contains("35"))
        XCTAssertTrue(bp39UIFact(knownText, containing: "未缓存输入").contains("65"))
        XCTAssertTrue(bp39UIFact(knownText, containing: "命中率").contains("35.00%"))
        XCTAssertTrue(knownText.contains("本次读取") || knownText.contains("读取时间")
            || knownText.contains("扫描时间") || knownText.contains("核对时间"),
                      "DM-A07 local presentation exposes snapshot read time")
        for marker in ["模型调用", "TTFT", "decode"] {
            bp39UIAssertUnknown(knownText, marker: marker, reason: ["来源未提供"])
        }
    }

    func testBP39DetailedMetricsDoesNotAlterTokenHubOrActivityAccounting() throws {
        let now = Date(timeIntervalSince1970: 1_797_000_000)
        let root = try bp39UIWriteFixture(now: now,
            uuid: "b0390000-0000-4000-8000-000000000003", cacheLiteral: "35")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try bp39UIScanPair(root, now: now)
        let model = bp39UIModel(snapshot, now: now)
        defer { model.shutdown() }
        let before = model.stats
        let hubBefore = model.tokenHubQuotaSnapshot
        let hubStatusBefore = model.tokenHubQuotaStatus
        model.tick()
        XCTAssertEqual(model.stats.input, before.input, "DM-A07 cache fields never alter proxy input accounting")
        XCTAssertEqual(model.stats.output, before.output, "DM-A07 cache fields never alter proxy output accounting")
        XCTAssertEqual(model.stats.total, before.total, "DM-A07 cache fields never alter proxy total accounting")
        XCTAssertEqual(snapshot.input, 100, "DM-A03 detail projection leaves base input accounting unchanged")
        XCTAssertEqual(snapshot.output, 20, "DM-A03 detail projection leaves base output accounting unchanged")
        XCTAssertEqual(snapshot.total, 120)
        XCTAssertEqual(model.tokenHubQuotaSnapshot, hubBefore, "local cache facts cannot create enterprise quota")
        XCTAssertEqual(model.tokenHubQuotaStatus, hubStatusBefore)
        XCTAssertFalse(model.activityIsLive, "reading old cumulative cache fields cannot manufacture live activity")
    }

    func testBP39KnownZeroMissingAndInvalidHaveDistinctCachePresentation() throws {
        let now = Date(timeIntervalSince1970: 1_797_000_000)
        let cases: [(String, String?, LocalCacheAggregateState, String)] = [
            ("b0390000-0000-4000-8000-000000000004", "0", .complete, "known-zero"),
            ("b0390000-0000-4000-8000-000000000005", nil, .missing, "missing"),
            ("b0390000-0000-4000-8000-000000000006", "101", .invalid, "invalid")
        ]
        for (id, literal, state, label) in cases {
            let root = try bp39UIWriteFixture(now: now, uuid: id, cacheLiteral: literal)
            defer { try? FileManager.default.removeItem(at: root) }
            let snapshot = try bp39UIScanPair(root, now: now)
            let model = bp39UIModel(snapshot, now: now)
            defer { model.shutdown() }
            XCTAssertEqual(snapshot.cacheCoverage.state, state, label)
            XCTAssertEqual(snapshot.input, 100, "\(label) does not erase inclusive base input")
            XCTAssertEqual(snapshot.output, 20)
            XCTAssertEqual(snapshot.total, 120)
            XCTAssertEqual(snapshot.details.count, 1)
            let usage = try XCTUnwrap(snapshot.details.first?.usage)
            let text = model.menuTooltip
            if state == .complete {
                XCTAssertEqual(usage.cache, .value(0))
                XCTAssertEqual(usage.uncachedInput, 100)
                XCTAssertEqual(snapshot.cacheCoverage.cachedInputTokens, 0)
                XCTAssertEqual(snapshot.cacheCoverage.uncachedInputTokens, 100)
                let cache = bp39UIFact(text, containing: "缓存读取")
                XCTAssertTrue(cache.contains("0")); XCTAssertFalse(cache.contains("未知"))
                XCTAssertTrue(bp39UIFact(text, containing: "未缓存输入").contains("100"))
                XCTAssertTrue(bp39UIFact(text, containing: "命中率").contains("0.00%"))
            } else {
                XCTAssertEqual(usage.cache, state == .missing ? .notReported : .invalid)
                XCTAssertNil(usage.uncachedInput)
                XCTAssertNil(snapshot.cacheCoverage.cachedInputTokens)
                XCTAssertNil(snapshot.cacheCoverage.uncachedInputTokens)
                XCTAssertNil(snapshot.cacheCoverage.hitRate)
                for marker in ["缓存读取", "未缓存输入", "命中率"] {
                    bp39UIAssertUnknown(text, marker: marker,
                        reason: state == .missing ? ["未提供", "缺失"] : ["无效", "非法"])
                }
                XCTAssertFalse(bp39UIFact(text, containing: "命中率").contains("0.00%"))
            }
        }
    }

    func testBP39MatchedCoverageNeverUsesTheLargerBaseDenominator() throws {
        let now = Date(timeIntervalSince1970: 1_797_000_000)
        let root = try bp39UIWriteFixture(now: now,
            uuid: "b0390000-0000-4000-8000-000000000007", cacheLiteral: "90")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try bp39UIWriteFixture(now: now,
            uuid: "b0390000-0000-4000-8000-000000000008", cacheLiteral: "90",
            input: 900, output: 30, total: 930, in: root)
        let complete = try bp39UIScanPair(root, now: now)
        let model = bp39UIModel(complete, now: now)
        defer { model.shutdown() }
        XCTAssertEqual(complete.input, 1_000)
        XCTAssertEqual(complete.cacheCoverage.cachedInputTokens, 180)
        XCTAssertEqual(complete.cacheCoverage.uncachedInputTokens, 820)
        XCTAssertTrue(bp39UIFact(model.menuTooltip, containing: "命中率").contains("18.00%"),
                      "ratio of sums is 180/1000, not the 50 percent average of row ratios")

        _ = try bp39UIWriteFixture(now: now,
            uuid: "b0390000-0000-4000-8000-000000000008", cacheLiteral: nil,
            input: 900, output: 30, total: 930, in: root)
        let partial = try bp39UIScanPair(root, now: now)
        model.localSnapshot = partial
        XCTAssertEqual(partial.input, 1_000)
        XCTAssertEqual(partial.cacheCoverage.state, .partial)
        XCTAssertEqual(partial.cacheCoverage.baseRows, 2)
        XCTAssertEqual(partial.cacheCoverage.cacheKnownRows, 1)
        XCTAssertEqual(partial.cacheCoverage.cacheMissingRows, 1)
        XCTAssertEqual(partial.cacheCoverage.matchedInputTokens, 100)
        XCTAssertEqual(partial.cacheCoverage.matchedCachedInputTokens, 90)
        XCTAssertNil(partial.cacheCoverage.cachedInputTokens)
        XCTAssertNil(partial.cacheCoverage.uncachedInputTokens)
        XCTAssertNil(partial.cacheCoverage.hitRate)
        let text = model.menuTooltip
        for marker in ["缓存读取", "未缓存输入", "命中率"] {
            bp39UIAssertUnknown(text, marker: marker, reason: ["覆盖", "部分", "未提供"])
        }
        let coverage = bp39UIFact(text, containing: "缓存覆盖")
        XCTAssertNotNil(coverage.range(of: #"1\s*[/／]\s*2"#, options: .regularExpression))
        let matched = text.split(separator: "\n").map(String.init).first {
            $0.contains("匹配") || $0.contains("相同覆盖") || $0.contains("同覆盖")
        }
        let matchedFact = try XCTUnwrap(matched, "a narrower subtotal must identify its matched coverage")
        XCTAssertNotNil(matchedFact.range(of: #"(?<![0-9])90(?![0-9])"#, options: .regularExpression))
        XCTAssertNotNil(matchedFact.range(of: #"(?<![0-9])100(?![0-9])"#, options: .regularExpression))
        XCTAssertFalse(text.contains("9.00%"), "90 cached tokens cannot be divided by the unmatched 1000 input")
    }

    func testBP39NonFullIntegerBoundaryAndExactFullHitRenderDifferentPercentages() throws {
        let now = Date(timeIntervalSince1970: 1_797_000_000)
        for (id, input, cache, expected) in [
            ("b0390000-0000-4000-8000-000000000009", Int.max, Int.max - 1, "99.99%"),
            ("b0390000-0000-4000-8000-000000000010", 10, 10, "100.00%")
        ] {
            let root = try bp39UIWriteFixture(now: now, uuid: id, cacheLiteral: String(cache),
                                             input: input, output: 0, total: input)
            defer { try? FileManager.default.removeItem(at: root) }
            let snapshot = try bp39UIScanPair(root, now: now)
            let model = bp39UIModel(snapshot, now: now)
            defer { model.shutdown() }
            XCTAssertEqual(snapshot.cacheCoverage.matchedInputTokens, input)
            XCTAssertEqual(snapshot.cacheCoverage.matchedCachedInputTokens, cache)
            let rate = bp39UIFact(model.menuTooltip, containing: "命中率")
            XCTAssertTrue(rate.contains(expected), "the UI must format exact integer coverage: \(expected)")
            if input != cache { XCTAssertFalse(rate.contains("100.00%")) }
        }
    }

    func testBP39SnapshotReplacementRemovesPriorCacheDetailsAndDeletedRows() throws {
        let now = Date(timeIntervalSince1970: 1_797_000_000)
        let id = "b0390000-0000-4000-8000-000000000011"
        let root = try bp39UIWriteFixture(now: now, uuid: id, cacheLiteral: "35")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = LocalCodexUsageReader.Cache()
        let first = try LocalCodexUsageReader.scan(directory: root, now: now, cache: cache)
        let model = bp39UIModel(first, now: now)
        defer { model.shutdown() }
        XCTAssertEqual(model.localSnapshot.details.count, 1)
        XCTAssertEqual(model.localSnapshot.cacheCoverage.cachedInputTokens, 35)
        model.localSnapshot = first
        XCTAssertEqual(model.localSnapshot.details.count, 1, "an identical scan is replacement, not append")

        _ = try bp39UIWriteFixture(now: now, uuid: id, cacheLiteral: nil,
                                   input: 200, output: 50, total: 250, in: root)
        let replacement = try LocalCodexUsageReader.scan(directory: root, now: now, cache: cache)
        model.localSnapshot = replacement
        XCTAssertEqual(model.localSnapshot.input, 200)
        XCTAssertEqual(model.localSnapshot.total, 250)
        XCTAssertEqual(model.localSnapshot.details.count, 1)
        XCTAssertEqual(model.localSnapshot.cacheCoverage.state, .missing)
        XCTAssertNil(model.localSnapshot.cacheCoverage.cachedInputTokens)
        XCTAssertEqual(model.localSnapshot.details.first?.usage.cache, .notReported)
        bp39UIAssertUnknown(model.menuTooltip, marker: "缓存读取", reason: ["未提供", "缺失"])

        try FileManager.default.removeItem(at: root.appendingPathComponent("rollout-\(id).jsonl"))
        model.localSnapshot = try LocalCodexUsageReader.scan(directory: root, now: now, cache: cache)
        XCTAssertTrue(model.localSnapshot.details.isEmpty)
        XCTAssertEqual(model.localSnapshot.cacheCoverage.baseRows, 0)
        XCTAssertNil(model.localSnapshot.cacheCoverage.cachedInputTokens)
        XCTAssertNil(model.localSnapshot.lastTurn)
        XCTAssertFalse(bp39UIFact(model.menuTooltip, containing: "缓存读取").contains("35"),
                       "a deleted row cannot survive as the current cache subtotal")
    }

    private func bp39UICompletedTurnFixture(now: Date) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenstat-bp39-ui-turn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = "b0390000-0000-4000-8000-000000000012"
        let formatter = ISO8601DateFormatter()
        func row(_ seconds: TimeInterval, _ payload: String) -> String {
            "{\"timestamp\":\"\(formatter.string(from: now.addingTimeInterval(seconds)))\",\"type\":\"event_msg\",\"payload\":\(payload)}"
        }
        let rows = [
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"source\":\"cli\"}}",
            row(-10, #"{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":20,"total_tokens":120}}}"#),
            row(-4, #"{"type":"task_started","turn_id":"synthetic-bp39-turn"}"#),
            row(-1, #"{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":70,"output_tokens":50,"total_tokens":210}}}"#),
            row(0, #"{"type":"task_complete","turn_id":"synthetic-bp39-turn","duration_ms":3000}"#)
        ]
        try Data((rows.joined(separator: "\n") + "\n").utf8)
            .write(to: root.appendingPathComponent("rollout-\(id).jsonl"))
        return root
    }

    func testBP39WholeTurnEvidenceNeverFillsMissingModelTiming() throws {
        let completedAt = Date(timeIntervalSince1970: 1_797_000_000)
        let now = completedAt.addingTimeInterval(30)
        let root = try bp39UICompletedTurnFixture(now: completedAt)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try bp39UIScanPair(root, now: now)
        XCTAssertEqual(snapshot.lastTurn?.durationSeconds, 3)
        XCTAssertEqual(snapshot.lastTurn?.outputTPS, 10)
        let turn = try XCTUnwrap(snapshot.details.first?.turns.first)
        XCTAssertEqual(turn.durationSeconds, 3)
        XCTAssertEqual(turn.outputTPS, 10)
        XCTAssertEqual(turn.usage.input, 60)
        XCTAssertEqual(turn.usage.cache, .value(30))
        let model = bp39UIModel(snapshot, now: now)
        defer { model.shutdown() }
        for marker in ["模型调用", "TTFT", "decode"] {
            bp39UIAssertUnknown(model.menuTooltip, marker: marker, reason: ["来源未提供"])
        }
        XCTAssertFalse(model.activityIsLive, "a completed turn cannot become an active decode measurement")
    }

    private func bp39UIArtifactDirectory() throws -> (url: URL, retain: Bool) {
        let requested = ProcessInfo.processInfo.environment["TOKENSTAT_BP39_UI_ARTIFACT_DIR"]
        let parent: URL
        if let requested {
            guard requested.hasPrefix("/") else { throw NSError(domain: "BP39ArtifactPath", code: 1) }
            parent = URL(fileURLWithPath: requested, isDirectory: true).standardizedFileURL
            let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  parent.resolvingSymlinksInPath() == parent else {
                throw NSError(domain: "BP39ArtifactPath", code: 2)
            }
        } else {
            parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        }
        let directory = parent.appendingPathComponent("TokenStatMenu-BP39-UI-\(UUID().uuidString)", isDirectory: true)
        // A unique, owned child is the only mutation target; never overwrite a
        // caller's directory, prior artifact, baseline or symlink.
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw NSError(domain: "BP39ArtifactPath", code: 3)
        }
        // mkdir, unlike a convenience "create if absent" API, also rejects a
        // concurrently created directory or dangling symlink with this name.
        guard mkdir(directory.path, 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return (directory, requested != nil)
    }

    private func bp39UIRenderOverview(_ model: AppModel, expanded: Bool, dark: Bool,
                                     output: URL) async throws -> (text: String, png: Data) {
        let content = DashboardView(model: model, detailedMetricsExpanded: expanded).overviewContent
            .environment(\.colorScheme, dark ? .dark : .light)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 460)
            .background(dark ? Color(red: 0.13, green: 0.14, blue: 0.17)
                             : Color(red: 0.96, green: 0.97, blue: 0.99))
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 700)
        host.layoutSubtreeIfNeeded()
        let height = max(700, ceil(host.fittingSize.height))
        guard height.isFinite, height <= 8_000 else { throw NSError(domain: "BP39OverviewRender", code: 1) }
        let bounds = NSRect(x: 0, y: 0, width: 460, height: height)
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        host.frame = bounds
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let pixelsWide = Int(bounds.width * 4)
        let pixelsHigh = Int(bounds.height * 4)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = bounds.size
        host.cacheDisplay(in: bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(decoded.pixelsWide, pixelsWide)
        XCTAssertEqual(decoded.pixelsHigh, pixelsHigh)
        XCTAssertNotNil(decoded.bitmapData)
        try png.write(to: output, options: .withoutOverwriting)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.002
        try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        // Vision may return a metric's label/value as separate observations.
        // Rejoin observations sharing a visual baseline before checking that
        // each timing label has its own unknown/source-not-provided value.
        let observations = (request.results ?? []).compactMap { observation -> (text: String, bounds: CGRect)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return (text, observation.boundingBox)
        }.sorted { $0.bounds.midY > $1.bounds.midY }
        var lines: [[(text: String, bounds: CGRect)]] = []
        for observation in observations {
            if let last = lines.last?.first,
               abs(last.bounds.midY - observation.bounds.midY) <= max(last.bounds.height, observation.bounds.height) * 0.6 {
                lines[lines.count - 1].append(observation)
            } else { lines.append([observation]) }
        }
        let text = lines.map { line in
            line.sorted { $0.bounds.minX < $1.bounds.minX }.map(\.text).joined(separator: " ")
        }.joined(separator: "\n")
        return (text, png)
    }

    func testBP39DashboardActuallyRendersCacheFactsAndExpandedWholeTurnOffline() async throws {
        XCTAssertTrue(bp39UIHasSourceReason("decode TPS 未知（来源未提供）", reason: ["来源未提供"]))
        XCTAssertFalse(bp39UIHasSourceReason("decode TPS 未知", reason: ["来源未提供"]))
        XCTAssertFalse(bp39UIHasSourceReason("decode TPS 未知（来源末提供）", reason: ["来源未提供"]))
        let now = Date(timeIntervalSince1970: 1_797_000_000)
        let root = try bp39UICompletedTurnFixture(now: now.addingTimeInterval(-30))
        defer { try? FileManager.default.removeItem(at: root) }
        let model = bp39UIModel(try bp39UIScanPair(root, now: now), now: now)
        defer { model.shutdown() }
        let artifacts = try bp39UIArtifactDirectory()
        defer { if !artifacts.retain { try? FileManager.default.removeItem(at: artifacts.url) } }
        for dark in [false, true] {
            let appearance = dark ? "dark" : "light"
            let collapsed = try await bp39UIRenderOverview(model, expanded: false, dark: dark,
                output: artifacts.url.appendingPathComponent("\(appearance)-collapsed.png"))
            let expanded = try await bp39UIRenderOverview(model, expanded: true, dark: dark,
                output: artifacts.url.appendingPathComponent("\(appearance)-expanded.png"))
            let text = expanded.text.replacingOccurrences(of: " ", with: "")
            for marker in ["缓存", "未缓存", "命中率", "线程", "轮次", "整轮用时", "整轮均速"] {
                XCTAssertTrue(text.contains(marker), "\(appearance) actual bitmap must display \(marker)")
            }
            XCTAssertTrue(text.contains("43.75%"), "the actual summary renders source C=70 / I=160")
            XCTAssertTrue(text.contains("线程1")); XCTAssertTrue(text.contains("轮次1"))
            for marker in ["模型调用", "TTFT", "decode"] {
                bp39UIAssertUnknown(text, marker: marker, reason: ["来源未提供"])
            }
            XCTAssertFalse(text.contains("b0390000"), "raw thread IDs cannot appear in the bitmap")
            XCTAssertFalse(text.contains("synthetic-bp39-turn"), "raw turn IDs cannot appear in the bitmap")
            XCTAssertNotEqual(collapsed.png, expanded.png,
                              "the expanded control must reveal actual content, not an inert fitting-size view")
            XCTAssertFalse(collapsed.text.replacingOccurrences(of: " ", with: "").contains("轮次1"),
                           "the default detail disclosure is collapsed")
        }
    }

}
