import AppKit
import Combine
import CryptoKit
import SwiftUI
import XCTest
import TokenStatCore
@testable import TokenStatMenu

/// These checks host the actual overview used by DashboardView.body. The four
/// full-content images are synthetic private review artifacts, not snapshots
/// of a user's running app. Initial state rendering does not prove a native
/// disclosure click; that interaction remains outside this bounded check.
@MainActor
final class DashboardHistoryTests: XCTestCase {
    private final class Calls {
        var loads = 0, saves = 0, starts = 0, discoveries = 0, fetches = 0
        var localResolves = 0, localScans = 0, axScans = 0
        var values: [Int] { [loads, saves, starts, discoveries, fetches, localResolves, localScans, axScans] }
    }
    private final class Permission: TokenHubPermissionProviding {
        var requests = 0
        func isTrusted() -> Bool { false }
        func requestOnceAndOpenSystemSettings() { requests += 1 }
    }
    private struct Fixture {
        let model: AppModel
        let calls: Calls
        let permission: Permission
        let now: Date
    }
    private struct Render {
        let png: Data
        let points: NSSize
        let pixels: NSSize
    }
    private struct ModelState: Equatable {
        let direct: TokenHubQuotaSnapshot?
        let local: LocalCodexSnapshot
        let five: WindowQuota?
        let seven: WindowQuota?
        let status: TokenHubQuotaStatus
        let directSource: Bool
        let failure: TokenHubDirectQuotaFailure?
        let sourceReadiness: String
        let title: String
        let tooltip: String
        let preferences: SeasunPreferences
        let resources: BackgroundServiceResources
    }

    private func state(_ model: AppModel) -> ModelState {
        ModelState(direct: model.tokenHubQuotaSnapshot, local: model.localSnapshot,
            five: model.fiveHourQuota, seven: model.sevenDayQuota,
            status: model.tokenHubQuotaStatus, directSource: model.tokenHubQuotaIsDirect,
            failure: model.tokenHubDirectFailure, sourceReadiness: model.sourceReadinessText,
            title: model.title, tooltip: model.menuTooltip, preferences: model.preferences,
            resources: model.backgroundServiceResources)
    }

    private func fixture(failing: Bool = false) async throws -> Fixture {
        let calls = Calls(), permission = Permission()
        // Wall time is used only to keep the synthetic direct snapshot fresh in
        // the real view, which uses Date(). All amounts/identities are invented.
        let now = Date().addingTimeInterval(-5)
        let identity = TokenHubIdentity(pid: 928, bundleID: TokenHubTarget.bundleID,
            executablePath: "/Applications/Synthetic C28 Hub.app/Contents/MacOS/Hub")
        let snapshot = TokenHubQuotaSnapshot(identity: identity,
            fiveHour: TokenHubWindowQuota(kind: .fiveHour, usedAmount: Decimal(string: "3.75")!,
                limitAmount: 10, sourceSymbol: "$", usedPercent: Decimal(string: "37.5")!,
                resetDisplay: "synthetic five-hour reset"),
            sevenDay: TokenHubWindowQuota(kind: .sevenDay, usedAmount: 4,
                limitAmount: 10, sourceSymbol: "$", usedPercent: 40,
                resetDisplay: "synthetic seven-day reset"),
            monthly: TokenHubMonthlyUsage(usedAmount: Decimal(string: "12.5")!, sourceSymbol: "$"),
            observedAt: now)
        let startup = AppModelStartupDependencies(loadPreferences: {
            calls.loads += 1; XCTFail("C28 rendering must not read real preferences"); return nil
        }, savePreferences: { _ in
            calls.saves += 1; XCTFail("C28 rendering must not save preferences")
        }, shouldStartBackgroundServices: {
            calls.starts += 1; XCTFail("C28 rendering must not start services"); return false
        })
        let direct = TokenHubDirectQuotaDependencies(discoverTarget: {
            calls.discoveries += 1; return identity
        }, identityIsCurrent: { $0 == identity }, fetch: { _, _ in
            calls.fetches += 1
            if failing { throw TokenHubDirectQuotaFailure.transportFailed }
            return snapshot
        })
        let local = LocalCodexScanDependencies(resolveInputs: {
            calls.localResolves += 1; XCTFail("C28 rendering must not discover local sessions")
            return (URL(fileURLWithPath: "/tmp/TokenStatMenu-C28-no-read"), .unverified)
        }, scan: { _, _, _, _ in
            await MainActor.run { calls.localScans += 1; XCTFail("C28 rendering must not scan local sessions") }
            throw TokenHubDirectQuotaFailure.transportFailed
        })
        let ax = TokenHubAXSource.synthetic { _ in
            calls.axScans += 1; XCTFail("C28 rendering must not read another app")
            return TokenHubQuotaResult(status: .accessFailed, snapshot: nil, failure: nil)
        }
        let model = AppModel(preview: true, startup: startup, directQuota: direct,
                             localScanning: local, tokenHubAXSource: ax)
        model.config.dataSource = "localCodex"
        model.tokenHubNow = { now }
        model.tokenHubPermissionProvider = permission
        model.tokenHubAutomaticReadingEnabled = false
        model.refreshTokenHubQuota()
        for _ in 0..<100 {
            if failing ? model.tokenHubDirectFailure == .transportFailed : model.tokenHubQuotaIsDirect {
                return Fixture(model: model, calls: calls, permission: permission, now: now)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.shutdown()
        XCTFail("C28 injected direct result was not applied")
        throw TokenHubDirectQuotaFailure.transportFailed
    }

    private func localQuotas(primary: Bool, secondary: Bool, now: Date,
                             future: Bool = false, missingReset: Bool = false) throws -> QuotaReport {
        var limits: [String: Any] = [:]
        if primary {
            var value: [String: Any] = ["usedPercent": 90, "windowDurationMins": 300]
            if !missingReset { value["resetsAt"] = Int(now.addingTimeInterval(-3600).timeIntervalSince1970) }
            limits["primary"] = value
        }
        if secondary {
            var value: [String: Any] = ["usedPercent": 5, "windowDurationMins": 10_080]
            if !missingReset { value["resetsAt"] = Int(now.addingTimeInterval(-1800).timeIntervalSince1970) }
            limits["secondary"] = value
        }
        // Empty local objects are assigned directly as nil windows by the caller;
        // QuotaReport intentionally rejects a response containing no facts.
        let bytes = try JSONSerialization.data(withJSONObject: ["result": ["rateLimits": limits]])
        return try QuotaReport.parse(bytes, config: AppConfiguration(),
            now: future ? now.addingTimeInterval(3600) : now.addingTimeInterval(-7200))
    }

    private func assignLocal(_ report: QuotaReport?, to model: AppModel, now: Date) {
        model.fiveHourQuota = report?.fiveHour; model.sevenDayQuota = report?.sevenDay
        model.localSnapshot = LocalCodexSnapshot(input: 120, output: 80, total: 200,
            sessionCount: 2, filesScanned: 3, isLimited: false,
            latestEventAt: now.addingTimeInterval(-7200),
            fiveHour: report?.fiveHour, sevenDay: report?.sevenDay,
            knownThreadCount: 3, unknownThreadCount: 1, unidentifiedFileCount: 0,
            subagentCount: 1, forkCount: 0,
            lastTurn: LocalTurnSummary(outputTokens: 20, durationSeconds: 4,
                completedAt: now.addingTimeInterval(-7200)))
    }

    private func render<V: View>(_ content: V, dark: Bool) throws -> Render {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let root = content.environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: 460).fixedSize(horizontal: false, vertical: true)
            .background(dark ? Color(red: 0.13, green: 0.14, blue: 0.17)
                             : Color(red: 0.96, green: 0.97, blue: 0.99))
        let host = NSHostingView(rootView: root)
        host.appearance = appearance
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 1600)
        host.layoutSubtreeIfNeeded()
        let fitted = host.fittingSize
        XCTAssertEqual(fitted.width, 460, accuracy: 0.5)
        XCTAssertGreaterThan(fitted.height, 120, "render must include the quota overview, not a toolbar crop")
        XCTAssertLessThan(fitted.height, 4000)
        let bounds = NSRect(x: 0, y: 0, width: 460, height: ceil(fitted.height))
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        host.frame = bounds; window.contentView = host; window.appearance = appearance
        window.displayIfNeeded(); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: bounds))
        host.cacheDisplay(in: bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertGreaterThan(png.count, 4000, "a nonempty blank-sized stub is insufficient")
        XCTAssertEqual(decoded.pixelsWide, Int(bounds.width * window.backingScaleFactor))
        XCTAssertEqual(decoded.pixelsHigh, Int(bounds.height * window.backingScaleFactor))
        return Render(png: png, points: bounds.size,
            pixels: NSSize(width: decoded.pixelsWide, height: decoded.pixelsHigh))
    }

    func testC28ActualOverviewCollapsedAndExpandedFullContentRenders() async throws {
        let f = try await fixture(); defer { f.model.shutdown() }
        assignLocal(try localQuotas(primary: false, secondary: true, now: f.now), to: f.model, now: f.now)
        let original = state(f.model), calls = f.calls.values, alert = f.model.alertColor
        let direct = try XCTUnwrap(f.model.tokenHubQuotaSnapshot)
        XCTAssertEqual(direct.fiveHour?.remainingPercent, Decimal(string: "62.5"))
        XCTAssertEqual(direct.sevenDay?.remainingPercent, 60)
        XCTAssertNil(f.model.fiveHourQuota)
        XCTAssertEqual(f.model.sevenDayQuota?.usedPercent, 5)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenStatMenu-C28-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        var manifest: [[String: Any]] = []
        for (name, dark) in [("light", false), ("dark", true)] {
            let implicit = try render(DashboardView(model: f.model).overviewContent, dark: dark)
            let collapsed = try render(DashboardView(model: f.model, localHistoryExpanded: false).overviewContent, dark: dark)
            let expanded = try render(DashboardView(model: f.model, localHistoryExpanded: true).overviewContent, dark: dark)
            XCTAssertEqual(implicit.png, collapsed.png, "default history presentation must be collapsed")
            XCTAssertGreaterThan(expanded.points.height, collapsed.points.height + 30,
                                 "expanded history must contain actual secondary content")
            XCTAssertNotEqual(expanded.png, collapsed.png)
            for (stateName, image) in [("collapsed", collapsed), ("expanded", expanded)] {
                let basename = "synthetic-c28-\(name)-\(stateName).png"
                try image.png.write(to: output.appendingPathComponent(basename))
                manifest.append(["name": basename, "sha256": SHA256.hash(data: image.png).map { String(format: "%02x", $0) }.joined(),
                    "widthPoints": image.points.width, "heightPoints": image.points.height,
                    "widthPixels": image.pixels.width, "heightPixels": image.pixels.height])
            }
        }
        try JSONSerialization.data(withJSONObject: ["syntheticOnly": true, "nativeInteractionVerified": false,
            "images": manifest], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("render-manifest.json"))
        print("C28 synthetic full-content review images: \(output.path)")
        XCTAssertEqual(state(f.model), original)
        XCTAssertEqual(f.calls.values, calls)
        XCTAssertEqual(f.model.alertColor, alert)
        XCTAssertEqual(f.permission.requests, 0)
        XCTAssertEqual(calls, [0, 0, 0, 1, 1, 0, 0, 0])
        XCTAssertEqual(f.model.localSnapshot.total, 200)
        XCTAssertEqual(f.model.localSnapshot.unknownThreadCount, 1)
    }

    func testC28DirectFailureCannotBecomeCurrentFromExpandedLocalHistory() async throws {
        let f = try await fixture(failing: true); defer { f.model.shutdown() }
        assignLocal(try localQuotas(primary: true, secondary: true, now: f.now), to: f.model, now: f.now)
        let original = state(f.model), calls = f.calls.values, alert = f.model.alertColor
        XCTAssertNil(f.model.tokenHubQuotaSnapshot)
        XCTAssertFalse(f.model.tokenHubQuotaIsDirect)
        XCTAssertEqual(DashboardView(model: f.model).tokenHubCard.emptyStateText, "Token Hub 网络请求失败")
        for expanded in [false, true] {
            _ = try render(DashboardView(model: f.model, localHistoryExpanded: expanded).overviewContent, dark: false)
        }
        XCTAssertEqual(state(f.model), original)
        XCTAssertEqual(f.calls.values, calls)
        XCTAssertEqual(f.model.alertColor, alert)
        XCTAssertEqual(f.permission.requests, 0)
    }

    func testC28LocalWindowCombinationsPreserveMissingAndHistoricalFacts() async throws {
        let f = try await fixture(); defer { f.model.shutdown() }
        for (five, seven, future, noReset) in [(false, false, false, false), (true, false, false, false),
            (false, true, false, false), (true, true, false, false), (true, true, true, false),
            (true, true, false, true)] {
            let report = five || seven ? try localQuotas(primary: five, secondary: seven,
                now: f.now, future: future, missingReset: noReset) : nil
            assignLocal(report, to: f.model, now: f.now)
            let original = state(f.model), calls = f.calls.values
            _ = try render(DashboardView(model: f.model, localHistoryExpanded: true).overviewContent, dark: false)
            XCTAssertEqual(state(f.model), original)
            XCTAssertEqual(f.calls.values, calls)
            XCTAssertEqual(f.model.fiveHourQuota != nil, five)
            XCTAssertEqual(f.model.sevenDayQuota != nil, seven)
            for value in [f.model.fiveHourQuota, f.model.sevenDayQuota].compactMap({ $0 }) {
                let presentation = WindowQuotaCard.presentation(for: value, at: f.now, refreshSeconds: 60, source: .localCodex)
                XCTAssertFalse(presentation.isFresh)
                XCTAssertEqual(presentation.usedPercent, value.usedPercent)
                XCTAssertEqual(presentation.recordedAt, value.fetchedAt)
                XCTAssertEqual(presentation.resetsAt, value.resetsAt)
                XCTAssertTrue(presentation.sourceLabel.contains("本地 Codex 历史快照"))
                XCTAssertTrue(presentation.statusLabel.contains("历史"))
                if future { XCTAssertTrue(presentation.statusLabel.contains("异常时间戳")) }
                if noReset { XCTAssertTrue(presentation.statusLabel.contains("重置时间未知")) }
            }
        }
        XCTAssertEqual(f.permission.requests, 0)
    }

    func testC29AccountingLabelsRenderForLimitedAndCompleteSyntheticSnapshots() async throws {
        let f = try await fixture(); defer { f.model.shutdown() }

        f.model.localSnapshot = LocalCodexSnapshot(input: 120, output: 80, total: 200,
            sessionCount: 2, filesScanned: 32, isLimited: true, latestEventAt: nil,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 3,
            unknownThreadCount: 2)
        XCTAssertFalse(f.model.title.contains("Σ"))
        XCTAssertTrue(f.model.menuTooltip.contains("实时估算：未知"))
        XCTAssertTrue(f.model.menuTooltip.contains("当前配置关联的本机 Codex 记录"))
        XCTAssertTrue(f.model.menuTooltip.contains("本次记录合计"))
        XCTAssertTrue(f.model.menuTooltip.contains("本次达到扫描上限"))
        XCTAssertTrue(f.model.menuTooltip.contains("其他线程 2"))
        for dark in [false, true] {
            let image = try render(DashboardView(model: f.model).overviewContent, dark: dark)
            XCTAssertGreaterThan(image.png.count, 4000)
        }

        f.model.localSnapshot = LocalCodexSnapshot(input: 120, output: 80, total: 200,
            sessionCount: 2, filesScanned: 3, isLimited: false, latestEventAt: nil,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 3,
            unknownThreadCount: 0)
        XCTAssertFalse(f.model.title.contains("Σ"))
        XCTAssertFalse(f.model.title.contains("顶层对话"))
        XCTAssertTrue(f.model.menuTooltip.contains("本次扫描记录量"))
        XCTAssertTrue(f.model.menuTooltip.contains("本次安全检查 3 个物理文件"))
        XCTAssertTrue(f.model.menuTooltip.contains("其他线程 0"))
        for dark in [false, true] {
            let image = try render(DashboardView(model: f.model).overviewContent, dark: dark)
            XCTAssertGreaterThan(image.png.count, 4000)
        }
    }
}
