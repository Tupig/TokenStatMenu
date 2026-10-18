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

    private func directModel(_ harness: HubDirectHarness, clock: HubManualClock,
                             permission: HubTestPermission) -> AppModel {
        let model = AppModel(preview: true, directQuota: harness.dependencies)
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
        let model = directModel(harness, clock: HubManualClock(now), permission: permission)
        let scanner = HubTestScanner(result: result(now: now))
        model.tokenHubScanner = scanner
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
        let model = directModel(harness, clock: clock, permission: permission)
        model.config.refreshSeconds = 0.05
        let scanner = HubTestScanner(result: result(now: clock.now))
        model.tokenHubScanner = scanner
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
        let model = directModel(harness, clock: clock, permission: permission)
        let scanner = HubTestScanner(result: result(now: clock.now))
        model.tokenHubScanner = scanner
        let axStarted = expectation(description: "synthetic AX fallback started")
        let releaseAX = DispatchSemaphore(value: 0)
        scanner.started = { axStarted.fulfill() }
        scanner.beforeReturn = { releaseAX.wait() }
        defer { model.shutdown(); harness.finishPending(); releaseAX.signal() }
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
        releaseAX.signal()
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
