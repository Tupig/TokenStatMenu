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
