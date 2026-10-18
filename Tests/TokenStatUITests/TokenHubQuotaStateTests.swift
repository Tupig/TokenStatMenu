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
