import AppKit
import SnapshotTesting
import SwiftUI
import XCTest
import TokenStatCore
@testable import TokenStatMenu
#if TOKENSTAT_BP38_C04
import CryptoKit
import Vision
#endif

@MainActor
final class TokenStatUISnapshotTests: XCTestCase {
    func testDashboardLightAndDark() {
        assertDashboard(_appearance: .aqua, name: "dashboard-light")
        assertDashboard(_appearance: .darkAqua, name: "dashboard-dark")
    }

    func testSettingsLightAndDark() {
        assertDashboard(_appearance: .aqua, settings: true, name: "settings-light")
        assertDashboard(_appearance: .darkAqua, settings: true, name: "settings-dark")
    }

    func testCompactPanelSizeMatchesPopover() {
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        XCTAssertEqual(PanelMetrics.size, NSSize(width: 300, height: 420))
        for settings in [false, true] {
            let host = NSHostingView(rootView: DashboardView(model: model, settings: settings))
            host.frame = NSRect(origin: .zero, size: PanelMetrics.size)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, PanelMetrics.size.width, accuracy: 0.5)
            XCTAssertEqual(host.fittingSize.height, PanelMetrics.size.height, accuracy: 0.5)
        }
    }

    func testVersionTextUsesBundleMetadataWithoutInventingARelease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        let contents = directory.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.tupig.TokenStatMenu",
            "CFBundlePackageType": "BNDL", "CFBundleShortVersionString": "2.3.4", "CFBundleVersion": "17"
        ], format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: directory))
        XCTAssertEqual(SettingsView.versionText(bundle: bundle), "版本 2.3.4（构建 17）")
        XCTAssertEqual(SettingsView.versionText(), "开发运行（未打包）")
    }

    func testLocalStatusTitleUsesCompletedTurnAndRecordedSessionTotal() throws {
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        model.localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0,
            filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
            knownThreadCount: 0, unknownThreadCount: 0, unidentifiedFileCount: 0,
            subagentCount: 0, forkCount: 0)
        XCTAssertEqual(model.title, "— | — | —")
        model.localSnapshot = LocalCodexSnapshot(input: 125, output: 300, total: 425,
            sessionCount: 2, filesScanned: 2, isLimited: false,
            latestEventAt: Date(timeIntervalSince1970: 1_797_000_000), fiveHour: nil, sevenDay: nil,
            knownThreadCount: 2, unknownThreadCount: 0, unidentifiedFileCount: 0,
            subagentCount: 0, forkCount: 0,
            lastTurn: LocalTurnSummary(outputTokens: 75, durationSeconds: 5,
                completedAt: Date(timeIntervalSince1970: 1_797_000_000)))
        XCTAssertEqual(model.title, "— | — | —")
        XCTAssertTrue(model.dataNotice.contains("当前扫描范围记录合计"))
        XCTAssertTrue(model.menuTooltip.contains("425"))
        XCTAssertTrue(model.menuTooltip.contains("顶层对话 2"))
        XCTAssertTrue(model.menuTooltip.contains("含工具、网络和等待"))
        XCTAssertTrue(model.menuTooltip.contains("5 小时"))
        XCTAssertTrue(model.menuTooltip.contains("7 天"))
        XCTAssertTrue(model.menuTooltip.contains("32"), "tooltip should describe the bounded session/file coverage")
        model.localSnapshot = LocalCodexSnapshot(input: 1_234_200, output: 367, total: 1_234_567,
            sessionCount: 2, filesScanned: 2, isLimited: false,
            latestEventAt: Date(timeIntervalSince1970: 1_797_000_000), fiveHour: nil, sevenDay: nil,
            knownThreadCount: 2, unknownThreadCount: 0, unidentifiedFileCount: 0,
            subagentCount: 0, forkCount: 0,
            lastTurn: LocalTurnSummary(outputTokens: 75, durationSeconds: 5,
                completedAt: Date(timeIntervalSince1970: 1_797_000_000)))
        let fullTotal = 1_234_567.formatted(.number)
        XCTAssertEqual(model.title, "— | — | —")
        XCTAssertFalse(model.title.contains("Σ"))
        XCTAssertTrue(model.menuTooltip.contains(fullTotal), "tooltip should retain the full cumulative total")
        let futureQuotaData = try JSONSerialization.data(withJSONObject: ["result": ["rateLimits": [
            "primary": ["usedPercent": 88, "windowDurationMins": 300,
                        "resetsAt": Date().addingTimeInterval(7200).timeIntervalSince1970]
        ]]])
        model.fiveHourQuota = try QuotaReport.parse(futureQuotaData, config: AppConfiguration(),
            now: Date().addingTimeInterval(3600)).fiveHour
        XCTAssertTrue(model.menuTooltip.contains("异常时间戳"), "tooltip should label future quota data anomalous")
    }

    func testC12LocalAccountingUINeverLabelsPartialSubtotalAsComplete() {
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        model.config.dataSource = "localCodex"
        let known = LocalCodexSnapshot(input: 30, output: 20, total: 50, sessionCount: 1,
            filesScanned: 2, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
            knownThreadCount: 1, unknownThreadCount: 2, unidentifiedFileCount: 1,
            subagentCount: 0, forkCount: 0)
        XCTAssertFalse(known.hasCompleteAccounting)
        model.localSnapshot = known
        XCTAssertEqual(model.title, "— | — | —")
        XCTAssertTrue(model.menuTooltip.contains("输入 30"))
        XCTAssertTrue(model.menuTooltip.contains("输出 20"))
        XCTAssertTrue(model.menuTooltip.contains("总计 50"))
        XCTAssertTrue(model.menuTooltip.contains("其他线程 2"))
        XCTAssertTrue(model.menuTooltip.contains("未识别文件 1"))
        XCTAssertFalse(model.menuTooltip.contains("本次扫描记录量 50"))

        model.localSnapshot = LocalCodexSnapshot(input: 8, output: 2, total: 10, sessionCount: 0,
            filesScanned: 1, isLimited: true, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
            knownThreadCount: 1, unknownThreadCount: 0, unidentifiedFileCount: 0,
            subagentCount: 0, forkCount: 0)
        XCTAssertFalse(model.localSnapshot.hasCompleteAccounting, "a scan limit prevents complete accounting")
        XCTAssertEqual(model.title, "— | — | —")

        model.localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0,
            filesScanned: 2, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
            knownThreadCount: 0, unknownThreadCount: 0, unidentifiedFileCount: 2,
            subagentCount: 0, forkCount: 0)
        XCTAssertEqual(model.title, "— | — | —")
        XCTAssertTrue(model.menuTooltip.contains("总计 未知"))

        model.localSnapshot = LocalCodexSnapshot(input: 30, output: 20, total: 50, sessionCount: 1,
            filesScanned: 1, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
            knownThreadCount: 1, unknownThreadCount: 0, unidentifiedFileCount: 0,
            subagentCount: 0, forkCount: 0)
        XCTAssertTrue(model.localSnapshot.hasCompleteAccounting)
        XCTAssertEqual(model.title, "— | — | —")
        XCTAssertTrue(model.menuTooltip.contains("本次扫描记录量 50"))

        for snapshot in [known, model.localSnapshot,
            LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0,
                filesScanned: 1, isLimited: false, latestEventAt: nil,
                fiveHour: nil, sevenDay: nil, unidentifiedFileCount: 1)] {
            model.localSnapshot = snapshot
            XCTAssertFalse(model.title.contains("Σ"))
            XCTAssertFalse(model.title.contains("顶层对话"))
            for text in [model.title, model.menuTooltip, model.dataNotice] {
                XCTAssertFalse(text.contains("未核验"))
                XCTAssertFalse(text.contains("小计"))
            }
        }
    }

    func testC12AccountingDashboardExportsSyntheticReviewRenders() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("TokenStatMenu-C12-review", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scenarios: [(String, LocalCodexSnapshot)] = [
            ("known-subagent-no-top-level", LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0,
                filesScanned: 1, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
                knownThreadCount: 1, unknownThreadCount: 0, unidentifiedFileCount: 0, subagentCount: 1, forkCount: 1)),
            ("partial-accounting", LocalCodexSnapshot(input: 30, output: 20, total: 50, sessionCount: 1,
                filesScanned: 4, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
                knownThreadCount: 1, unknownThreadCount: 2, unidentifiedFileCount: 1, subagentCount: 0, forkCount: 0)),
            ("zero-known-threads", LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0,
                filesScanned: 2, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
                knownThreadCount: 0, unknownThreadCount: 2, unidentifiedFileCount: 0, subagentCount: 0, forkCount: 0))
        ]
        var paths: [String] = []
        for (scenario, snapshot) in scenarios {
            let model = AppModel(preview: true)
            model.config.dataSource = "localCodex"
            model.localSnapshot = snapshot
            for (scheme, appearance) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
                let content = DashboardView(model: model)
                    .environment(\.colorScheme, scheme)
                    .frame(width: 460, height: 700)
                    .background(scheme == .dark ? Color(red: 0.13, green: 0.14, blue: 0.17) : Color(red: 0.96, green: 0.97, blue: 0.99))
                let bounds = NSRect(x: 0, y: 0, width: 460, height: 700)
                let host = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
                host.frame = bounds
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else {
                    throw NSError(domain: "C12DashboardRender", code: 1)
                }
                host.cacheDisplay(in: bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "C12DashboardRender", code: 2)
                }
                let name = "\(scenario)-\(scheme == .dark ? "dark" : "light").png"
                let url = output.appendingPathComponent(name)
                try png.write(to: url)
                XCTAssertGreaterThan(try Data(contentsOf: url).count, 0)
                paths.append(url.path)
                window.close()
            }
            model.shutdown()
        }
        print("C12 synthetic accounting Dashboard renders: \(paths.joined(separator: ", "))")
    }

    func testEnterpriseQuotaAlertsUseOnlyFreshIndependentWindows() throws {
        let now = Date()
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        model.config.dataSource = "proxy"
        func quota(five: Double?, seven: Double?, fetchedAt: Date, reset: Date) throws -> QuotaReport {
            var limits: [String: Any] = [:]
            if let five { limits["primary"] = ["usedPercent": five, "windowDurationMins": 300, "resetsAt": reset.timeIntervalSince1970] }
            if let seven { limits["secondary"] = ["usedPercent": seven, "windowDurationMins": 10080, "resetsAt": reset.timeIntervalSince1970] }
            let object: [String: Any] = ["result": ["rateLimits": limits]]
            return try QuotaReport.parse(JSONSerialization.data(withJSONObject: object), config: AppConfiguration(), now: fetchedAt)
        }
        let fresh = try quota(five: 96, seven: 20, fetchedAt: now, reset: now.addingTimeInterval(3600))
        model.fiveHourQuota = fresh.fiveHour
        model.sevenDayQuota = fresh.sevenDay
        XCTAssertEqual(model.alertColor, .systemRed)

        let stale = try quota(five: 99, seven: 20, fetchedAt: now.addingTimeInterval(-3600), reset: now.addingTimeInterval(3600))
        model.fiveHourQuota = stale.fiveHour
        model.sevenDayQuota = fresh.sevenDay
        XCTAssertEqual(model.alertColor, .labelColor, "stale 5-hour quota must not override its fresh 7-day sibling")

        let freshSevenDay = try quota(five: 20, seven: 96, fetchedAt: now, reset: now.addingTimeInterval(3600))
        model.fiveHourQuota = stale.fiveHour
        model.sevenDayQuota = freshSevenDay.sevenDay
        XCTAssertEqual(model.alertColor, .systemRed, "fresh 7-day alert remains active when the 5-hour sibling is stale")

        let future = try quota(five: 99, seven: nil, fetchedAt: now.addingTimeInterval(3600), reset: now.addingTimeInterval(7200))
        model.fiveHourQuota = future.fiveHour
        model.sevenDayQuota = nil
        XCTAssertEqual(model.alertColor, .labelColor, "future-dated quota must not contribute to current alerts")

        let resetExpired = try quota(five: 99, seven: nil, fetchedAt: now, reset: now.addingTimeInterval(-1))
        model.fiveHourQuota = resetExpired.fiveHour
        model.sevenDayQuota = nil
        XCTAssertEqual(model.alertColor, .labelColor, "reset-expired quota must not contribute to current alerts")
    }

    func testC11LocalQuotaSnapshotsNeverBecomeEnterpriseCurrentOrAlerts() throws {
        let now = Date()
        let monthlyData = try JSONSerialization.data(withJSONObject: ["data": [
            "used_tokens": 123, "total_tokens": 1234
        ]])
        var monthlyConfig = AppConfiguration()
        monthlyConfig.periodPath = ""
        let monthlyFixture = try QuotaSnapshot.parse(monthlyData, config: monthlyConfig, now: now)
        func quota(five: Double?, seven: Double?, fetchedAt: Date, reset: Date) throws -> QuotaReport {
            var limits: [String: Any] = [:]
            if let five { limits["primary"] = ["usedPercent": five, "windowDurationMins": 300, "resetsAt": reset.timeIntervalSince1970] }
            if let seven { limits["secondary"] = ["usedPercent": seven, "windowDurationMins": 10080, "resetsAt": reset.timeIntervalSince1970] }
            return try QuotaReport.parse(JSONSerialization.data(withJSONObject: ["result": ["rateLimits": limits]]),
                config: AppConfiguration(), now: fetchedAt)
        }

        let local = AppModel(preview: true)
        defer { local.shutdown() }
        local.config.dataSource = "localCodex"
        let recentLocal = try quota(five: 99, seven: 98, fetchedAt: now, reset: now.addingTimeInterval(3600))
        local.fiveHourQuota = recentLocal.fiveHour
        local.sevenDayQuota = recentLocal.sevenDay
        let highMonthlyData = try JSONSerialization.data(withJSONObject: ["data": [
            "used_tokens": 1234, "total_tokens": 1234
        ]])
        local.quota = try QuotaSnapshot.parse(highMonthlyData, config: monthlyConfig, now: now)
        XCTAssertEqual(local.quotaSource, .localCodex)
        for value in [recentLocal.fiveHour, recentLocal.sevenDay].compactMap({ $0 }) {
            let card = WindowQuotaCard.presentation(for: value, at: now, refreshSeconds: 60, source: .localCodex)
            XCTAssertFalse(card.isFresh, "a recent local snapshot is never an enterprise-current allowance")
            XCTAssertTrue(card.sourceLabel.contains("本地"))
            XCTAssertTrue(card.statusLabel.contains("本地"))
            XCTAssertFalse(card.statusLabel.contains("当前企业"))
            XCTAssertEqual(card.usedPercent, value.usedPercent)
            XCTAssertEqual(card.resetsAt, value.resetsAt)
            XCTAssertEqual(card.recordedAt, value.fetchedAt)
        }
        XCTAssertEqual(local.alertColor, .labelColor, "local rolling snapshots and a high monthly quota never drive enterprise alerts")
        XCTAssertTrue(local.menuTooltip.contains("5 小时额度：本地"))
        XCTAssertTrue(local.menuTooltip.contains("7 天额度：本地"))
        XCTAssertFalse(local.menuTooltip.contains("当前企业"))
        XCTAssertTrue(local.menuTooltip.contains("99.00%"), "local tooltip renders two decimal places")
        XCTAssertTrue(local.menuTooltip.contains("重置"), "local tooltip includes the reset time when present")

        for (window, percent) in [(300, 77.0), (10080, 78.0)] {
            let stale = try quota(five: window == 300 ? percent : nil, seven: window == 10080 ? percent : nil,
                fetchedAt: now.addingTimeInterval(-3600), reset: now.addingTimeInterval(3600))
            let value = window == 300 ? stale.fiveHour : stale.sevenDay
            let card = WindowQuotaCard.presentation(for: value, at: now, refreshSeconds: 60, source: .localCodex)
            XCTAssertFalse(card.isFresh, "stale local \(window)-minute window is never current")
            XCTAssertEqual(card.usedPercent, percent)
            XCTAssertEqual(card.resetsAt, value?.resetsAt)
            XCTAssertTrue(card.statusLabel.contains("本地"))
            XCTAssertTrue(card.statusLabel.contains("历史"))
            XCTAssertEqual(card.recordedAt, value?.fetchedAt)

            let future = try quota(five: window == 300 ? percent : nil, seven: window == 10080 ? percent : nil,
                fetchedAt: now.addingTimeInterval(600), reset: now.addingTimeInterval(3600))
            let futureValue = window == 300 ? future.fiveHour : future.sevenDay
            let futureCard = WindowQuotaCard.presentation(for: futureValue, at: now, refreshSeconds: 60, source: .localCodex)
            XCTAssertTrue(futureCard.statusLabel.contains("本地"))
            XCTAssertTrue(futureCard.statusLabel.contains("异常"))
            XCTAssertEqual(futureCard.usedPercent, percent)

            let expired = try quota(five: window == 300 ? percent : nil, seven: window == 10080 ? percent : nil,
                fetchedAt: now, reset: now.addingTimeInterval(-1))
            let expiredValue = window == 300 ? expired.fiveHour : expired.sevenDay
            let expiredCard = WindowQuotaCard.presentation(for: expiredValue, at: now, refreshSeconds: 60, source: .localCodex)
            XCTAssertTrue(expiredCard.statusLabel.contains("本地"))
            XCTAssertTrue(expiredCard.statusLabel.contains("重置已过"))
            XCTAssertEqual(expiredCard.usedPercent, percent)
            XCTAssertEqual(expiredCard.resetsAt, expiredValue?.resetsAt)

            let missingResetData = try JSONSerialization.data(withJSONObject: ["result": ["rateLimits": [
                "primary": ["usedPercent": percent, "windowDurationMins": 300],
                "secondary": ["usedPercent": percent, "windowDurationMins": 10080]
            ]]])
            let missingReset = try QuotaReport.parse(missingResetData, config: AppConfiguration(), now: now)
            let missingResetValue = window == 300 ? missingReset.fiveHour : missingReset.sevenDay
            let missingResetCard = WindowQuotaCard.presentation(for: missingResetValue, at: now,
                refreshSeconds: 60, source: .localCodex)
            XCTAssertEqual(missingResetCard.usedPercent, percent)
            XCTAssertNil(missingResetCard.resetsAt)
            XCTAssertTrue(missingResetCard.statusLabel.contains("本地"))
            XCTAssertTrue(missingResetCard.statusLabel.contains("未知"))

            let missingCard = WindowQuotaCard.presentation(for: nil, at: now, refreshSeconds: 60, source: .localCodex)
            XCTAssertTrue(missingCard.statusLabel.contains("本地"))
            XCTAssertTrue(missingCard.statusLabel.contains("未提供"))
        }

        let enterprise = AppModel(preview: true)
        defer { enterprise.shutdown() }
        enterprise.config.dataSource = "proxy"
        let currentEnterprise = try quota(five: 96, seven: 20, fetchedAt: now, reset: now.addingTimeInterval(3600))
        enterprise.fiveHourQuota = currentEnterprise.fiveHour
        enterprise.sevenDayQuota = currentEnterprise.sevenDay
        XCTAssertTrue(enterprise.menuTooltip.contains("企业"), "proxy tooltip identifies its quota source")
        XCTAssertTrue(enterprise.menuTooltip.contains("96.00%"), "proxy tooltip renders two decimal places")
        XCTAssertTrue(enterprise.menuTooltip.contains("重置"), "proxy tooltip includes the reset time")
        XCTAssertEqual(enterprise.quotaSource, .enterprise)
        let enterpriseCard = WindowQuotaCard.presentation(for: try XCTUnwrap(currentEnterprise.fiveHour), at: now,
            refreshSeconds: 60, source: .enterprise)
        XCTAssertTrue(enterpriseCard.isFresh)
        XCTAssertTrue(enterpriseCard.sourceLabel.contains("企业"))
        XCTAssertTrue(enterpriseCard.statusLabel.contains("企业"))
        XCTAssertEqual(enterprise.alertColor, .systemRed, "configured enterprise fresh-window alerts remain unchanged")

        let staleEnterprise = try quota(five: 99, seven: 20, fetchedAt: now.addingTimeInterval(-3600), reset: now.addingTimeInterval(3600))
        enterprise.fiveHourQuota = staleEnterprise.fiveHour
        enterprise.sevenDayQuota = currentEnterprise.sevenDay
        let staleEnterpriseCard = WindowQuotaCard.presentation(for: try XCTUnwrap(staleEnterprise.fiveHour), at: now,
            refreshSeconds: 60, source: .enterprise)
        XCTAssertFalse(staleEnterpriseCard.isFresh)
        XCTAssertTrue(staleEnterpriseCard.statusLabel.contains("企业"))
        XCTAssertEqual(staleEnterpriseCard.usedPercent, 99)
        XCTAssertEqual(enterprise.alertColor, .labelColor, "stale enterprise 5-hour data remains excluded beside fresh 7-day data")

        enterprise.fiveHourQuota = nil
        enterprise.sevenDayQuota = nil
        enterprise.quota = monthlyFixture
        enterprise.quotaLoading = true
        enterprise.resetQuotaState()
        XCTAssertNil(enterprise.quota)
        XCTAssertNil(enterprise.fiveHourQuota)
        XCTAssertNil(enterprise.sevenDayQuota)
        XCTAssertFalse(enterprise.quotaLoading)

        let switching = AppModel(preview: true)
        defer { switching.shutdown() }
        switching.config.dataSource = "localCodex"
        switching.quota = monthlyFixture
        switching.quotaLoading = true
        switching.fiveHourQuota = recentLocal.fiveHour
        switching.sevenDayQuota = recentLocal.sevenDay
        switching.resetQuotaState()
        XCTAssertNil(switching.fiveHourQuota)
        XCTAssertNil(switching.sevenDayQuota)
        XCTAssertNil(switching.quota)
        switching.config.dataSource = "proxy"
        switching.quota = monthlyFixture
        switching.quotaLoading = true
        switching.fiveHourQuota = currentEnterprise.fiveHour
        switching.sevenDayQuota = currentEnterprise.sevenDay
        switching.resetQuotaState()
        XCTAssertNil(switching.fiveHourQuota)
        XCTAssertNil(switching.sevenDayQuota)
        XCTAssertNil(switching.quota)
        XCTAssertFalse(switching.quotaLoading)
        XCTAssertEqual(switching.alertColor, .labelColor)
        XCTAssertFalse(switching.menuTooltip.contains("本地额度快照"))
        switching.sevenDayQuota = currentEnterprise.sevenDay
        XCTAssertNil(switching.fiveHourQuota, "injecting only the new 7-day source window leaves its missing 5-hour sibling missing")
        XCTAssertNotNil(switching.sevenDayQuota)
        switching.quota = monthlyFixture
        switching.quotaLoading = true
        switching.config.dataSource = "localCodex"
        switching.resetQuotaState()
        XCTAssertNil(switching.fiveHourQuota)
        XCTAssertNil(switching.sevenDayQuota)
        XCTAssertNil(switching.quota)
        XCTAssertFalse(switching.quotaLoading)
        switching.fiveHourQuota = recentLocal.fiveHour
        XCTAssertNotNil(switching.fiveHourQuota)
        XCTAssertNil(switching.sevenDayQuota, "injecting only the new 5-hour source window leaves its missing 7-day sibling missing")
        XCTAssertEqual(switching.alertColor, .labelColor)
    }

    func testC11QuotaCardRenderExportsLocalAndEnterpriseSyntheticExamples() throws {
        let now = Date()
        func quota(_ minutes: Int, _ percent: Double, hasReset: Bool = true) throws -> WindowQuota {
            var limit: [String: Any] = ["usedPercent": percent, "windowDurationMins": minutes]
            if hasReset { limit["resetsAt"] = now.addingTimeInterval(3600).timeIntervalSince1970 }
            let key = minutes == 300 ? "primary" : "secondary"
            let data = try JSONSerialization.data(withJSONObject: ["result": ["rateLimits": [key: limit]]])
            let report = try QuotaReport.parse(data, config: AppConfiguration(), now: now)
            return try XCTUnwrap(minutes == 300 ? report.fiveHour : report.sevenDay)
        }
        let artifactDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("TokenStatMenu-C11-review", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        var paths: [String] = []
        for (source, sourceName) in [(QuotaSource.localCodex, "local-codex"), (.enterprise, "enterprise")] {
            for (appearance, appearanceName) in [(NSAppearance.Name.aqua, "aqua"), (.darkAqua, "dark-aqua")] {
                let url = artifactDirectory.appendingPathComponent("\(sourceName)-\(appearanceName).png")
                try renderQuotaCard(try quota(300, 97), source: source, appearance: appearance).write(to: url)
                XCTAssertGreaterThan(try Data(contentsOf: url).count, 0)
                paths.append(url.path)
            }
        }
        let pairedURL = artifactDirectory.appendingPathComponent("local-5h-missing-7d-present.png")
        try renderQuotaCard(try quota(10080, 42, hasReset: false), source: .localCodex, appearance: .aqua,
            missingFiveHour: true).write(to: pairedURL)
        XCTAssertGreaterThan(try Data(contentsOf: pairedURL).count, 0)
        paths.append(pairedURL.path)
        print("C11 synthetic quota card renders: \(paths.joined(separator: ", "))")
    }

    func testHistoricalQuotaPresentationPreservesOriginalSourceValues() throws {
        let now = Date(timeIntervalSince1970: 1_797_000_000)
        let data = try JSONSerialization.data(withJSONObject: ["result": ["rateLimits": [
            "primary": ["usedPercent": 73, "windowDurationMins": 300,
                        "resetsAt": now.addingTimeInterval(-120).timeIntervalSince1970]
        ]]])
        let parsed = try QuotaReport.parse(data, config: AppConfiguration(), now: now.addingTimeInterval(-3600))
        let historic = try XCTUnwrap(parsed.fiveHour)
        let viewState = WindowQuotaCard.presentation(for: historic, at: now, refreshSeconds: 60)
        XCTAssertFalse(viewState.isFresh)
        XCTAssertEqual(viewState.usedPercent, 73)
        XCTAssertEqual(viewState.resetsAt, historic.resetsAt)
        XCTAssertTrue(viewState.statusLabel.contains("历史"))
        XCTAssertTrue(viewState.statusLabel.contains("已过期"))

        let freshData = try JSONSerialization.data(withJSONObject: ["result": ["rateLimits": [
            "primary": ["usedPercent": 73, "windowDurationMins": 300,
                        "resetsAt": now.addingTimeInterval(7200).timeIntervalSince1970]
        ]]])
        let freshReport = try QuotaReport.parse(freshData, config: AppConfiguration(), now: now)
        let fresh = WindowQuotaCard.presentation(for: try XCTUnwrap(freshReport.fiveHour), at: now, refreshSeconds: 60)
        XCTAssertTrue(fresh.isFresh)
        XCTAssertTrue(fresh.statusLabel.contains("当前"))
        let futureReport = try QuotaReport.parse(freshData, config: AppConfiguration(), now: now.addingTimeInterval(3600))
        let future = WindowQuotaCard.presentation(for: try XCTUnwrap(futureReport.fiveHour), at: now, refreshSeconds: 60)
        XCTAssertFalse(future.isFresh)
        XCTAssertTrue(future.statusLabel.contains("异常"))
        let staleReport = try QuotaReport.parse(freshData, config: AppConfiguration(), now: now.addingTimeInterval(-3600))
        let stale = WindowQuotaCard.presentation(for: try XCTUnwrap(staleReport.fiveHour), at: now, refreshSeconds: 60)
        XCTAssertFalse(stale.isFresh)
        XCTAssertEqual(stale.usedPercent, 73)
        XCTAssertEqual(stale.resetsAt, freshReport.fiveHour?.resetsAt)
        XCTAssertTrue(stale.statusLabel.contains("历史"))
        XCTAssertFalse(stale.statusLabel.contains("已过期"))
        let absent = WindowQuotaCard.presentation(for: nil, at: now, refreshSeconds: 60)
        XCTAssertFalse(absent.isFresh)
        XCTAssertNil(absent.usedPercent)
        XCTAssertTrue(absent.statusLabel.contains("未提供"))
    }

    func testImageMatcherDetectsDeliberateMismatchWithoutRecording() {
        let reference = solidImage(.white)
        let unchanged = solidImage(.white)
        let changed = solidImage(.black)
        XCTAssertNil(Snapshotting<NSImage, NSImage>.image.diffing.diffV2(reference, unchanged))
        XCTAssertNotNil(Snapshotting<NSImage, NSImage>.image.diffing.diffV2(reference, changed))
    }

    func testCredentialAccountNamesAreURLAndPurposeBoundWithoutKeychainIO() throws {
        let urlA = "https://gateway-a.example/v1/chat/completions"
        let urlB = "https://gateway-b.example/v1/chat/completions"
        let stableA = try KeychainStore.accountName("upstream", validatedURL: urlA)
        XCTAssertEqual(stableA, try KeychainStore.accountName("upstream", validatedURL: urlA))
        XCTAssertNotEqual(stableA, try KeychainStore.accountName("upstream", validatedURL: urlB))
        XCTAssertNotEqual(stableA, try KeychainStore.accountName("usage", validatedURL: urlA))
    }

    private func solidImage(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 24, height: 24)).fill()
        image.unlockFocus()
        return image
    }

    private func renderQuotaCard(_ quota: WindowQuota, source: QuotaSource, appearance: NSAppearance.Name,
                                 missingFiveHour: Bool = false) throws -> Data {
        let card = Group {
            if missingFiveHour {
                VStack {
                    WindowQuotaCard(title: "5 小时额度", quota: nil, color: .blue, refreshSeconds: 60, source: source)
                    WindowQuotaCard(title: "7 天额度", quota: quota, color: .blue, refreshSeconds: 60, source: source)
                }
            } else {
                WindowQuotaCard(title: quota.minutes == 300 ? "5 小时额度" : "7 天额度", quota: quota,
                    color: .blue, refreshSeconds: 60, source: source)
            }
        }
        let dark = appearance == .darkAqua
        let root = card
            .environment(\.colorScheme, dark ? .dark : .light)
            .padding(16)
            .frame(width: 300, height: 300, alignment: .topLeading)
            .background(dark ? Color(red: 0.13, green: 0.14, blue: 0.17) : Color(red: 0.96, green: 0.97, blue: 0.99))
        let bounds = NSRect(x: 0, y: 0, width: 300, height: 300)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = bounds
        hostingView.appearance = NSAppearance(named: appearance)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        window.displayIfNeeded()
        hostingView.needsDisplay = true
        hostingView.layoutSubtreeIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw NSError(domain: "C11QuotaCardRender", code: 1)
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "C11QuotaCardRender", code: 2)
        }
        return png
    }

    private func assertDashboard(_appearance appearance: NSAppearance.Name, settings: Bool = false, name: String,
                                 file: StaticString = #filePath, testName: String = #function, line: UInt = #line) {
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        // 沿用工具栏基线的画布尺寸；实际紧凑面板由独立布局测试覆盖。
        let root = DashboardView(model: model, settings: settings, panelSize: NSSize(width: 460, height: 700))
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: 460, height: 700)
        hostingView.appearance = NSAppearance(named: appearance)
        let toolbarCrop = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 66))
        toolbarCrop.wantsLayer = true
        hostingView.frame.origin.y = -634
        toolbarCrop.addSubview(hostingView)
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: toolbarCrop.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = toolbarCrop
        window.appearance = NSAppearance(named: appearance)
        window.displayIfNeeded()
        toolbarCrop.layoutSubtreeIfNeeded()
        let recordMode: SnapshotTestingConfiguration.Record =
            ProcessInfo.processInfo.environment["TOKENSTAT_RECORD_SNAPSHOTS"] == "1" ? .all : .never
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: toolbarCrop, as: .image, named: name, record: recordMode,
                           file: file, testName: testName, line: line)
        }
        window.orderOut(nil)
    }
}

#if TOKENSTAT_BP38_C04
@MainActor
extension TokenStatUISnapshotTests {
    private enum BP38C04State: String, CaseIterable {
        case directCurrent = "direct-current"
        case axCurrent = "ax-current"
        case missing = "missing"
        case usedOnly = "monthly-used-only"
        case expired = "expired-windows"
        case staleWhole = "whole-snapshot-stale"
        case futureWhole = "whole-snapshot-future"
        case mixedMissing = "mixed-missing-five-hour-valid-seven-day"
        case mixedExpired = "mixed-expired-five-hour-valid-seven-day"
        case monthlyWithLimit = "monthly-with-limit"
        case belowWarning = "threshold-79.995"
        case warning = "threshold-80"
        case belowCritical = "threshold-94.995"
        case critical = "threshold-95"
    }

    private enum BP38C04BarColor: String, CaseIterable {
        case normalBlue = "normal-blue"
        case warningYellow = "warning-yellow"
        case criticalRed = "critical-red"
    }

    private struct BP38C04RenderedCase: Codable {
        let name: String
        let appearance: String
        let width: Int
        let height: Int
        let sha256: String
        let visibleText: [String]
        let ocrText: [String]
        let alertLevel: String
        let barStates: [String]
        let pixelTargets: [String]
        let kind: String
        let mutation: String?
    }

    private struct BP38C04CandidateStatus: Encodable {
        let status: String
        let reason: String
        let acceptedBaseline: Bool
    }

    private struct BP38C04AcceptedManifest: Decodable {
        struct Image: Decodable {
            let name: String
            let sha256: String
        }
        let contract: String
        let acceptanceID: String
        let acceptedAt: String
        let acceptedBy: String
        let images: [Image]
    }

    private final class BP38C04Permission: TokenHubPermissionProviding {
        private(set) var trusted = true
        private(set) var requests = 0
        func isTrusted() -> Bool { trusted }
        func requestOnceAndOpenSystemSettings() { requests += 1 }
    }

    private final class BP38C04Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Int] = [:]
        private var axResults: [(String?, Bool)] = []
        func increment(_ key: String) { lock.lock(); defer { lock.unlock() }; values[key, default: 0] += 1 }
        func recordAX(identity: String?, connected: Bool) {
            lock.lock(); defer { lock.unlock() }; axResults.append((identity, connected))
        }
        func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return values[key, default: 0] }
        func axSnapshot() -> [(String?, Bool)] { lock.lock(); defer { lock.unlock() }; return axResults }
        @MainActor func assertInitialized(model: AppModel, permission: BP38C04Permission) {
            XCTAssertEqual(count("load"), 0); XCTAssertEqual(count("save"), 0)
            XCTAssertEqual(count("shouldStart"), 0); XCTAssertEqual(count("localResolve"), 0)
            XCTAssertEqual(count("localScan"), 0); XCTAssertEqual(permission.requests, 0)
            XCTAssertFalse(model.backgroundServicesStarted)
            XCTAssertEqual(model.backgroundServiceResources.timerCount, 0)
            XCTAssertEqual(model.backgroundServiceResources.workspaceObserverCount, 0)
            XCTAssertEqual(model.backgroundServiceResources.localScanQueuedCount, 0)
            XCTAssertEqual(model.backgroundServiceResources.axRefreshScheduledCount, 0)
            XCTAssertEqual(model.backgroundServiceResources.axScanInFlightCount, 0)
        }
        @MainActor func assertInitAndRefresh(state: BP38C04State, expectedDirect: Bool, model: AppModel, permission: BP38C04Permission) {
            XCTAssertEqual(count("load"), 0); XCTAssertEqual(count("save"), 0)
            XCTAssertEqual(count("shouldStart"), 0); XCTAssertEqual(count("localResolve"), 0)
            XCTAssertEqual(count("localScan"), 0); XCTAssertEqual(permission.requests, 0)
            XCTAssertEqual(model.backgroundServicesStarted, false)
            XCTAssertEqual(model.backgroundServiceResources.timerCount, 0)
            XCTAssertEqual(model.backgroundServiceResources.workspaceObserverCount, 0)
            XCTAssertEqual(model.backgroundServiceResources.localScanQueuedCount, 0)
            XCTAssertEqual(model.backgroundServiceResources.axScanInFlightCount, 0)
            XCTAssertEqual(model.tokenHubQuotaIsDirect, expectedDirect,
                "post-refresh source marker must match the injected DIRECT or AX route")
            XCTAssertEqual(count("scheduleExecuted"), 0)
            XCTAssertGreaterThanOrEqual(count("scheduleSubmitted"), count("scheduleCancelled"))
            XCTAssertLessThanOrEqual(model.backgroundServiceResources.axRefreshScheduledCount, 1,
                "only one inert cancellation handle may remain after refresh")
            let ax = axSnapshot()
            if state == .axCurrent || state == .usedOnly {
                XCTAssertEqual(ax.count, 1)
                XCTAssertEqual(ax.first?.0, "85404|\(TokenHubTarget.bundleID)|/Synthetic/BP38-C04-Hub")
                XCTAssertEqual(ax.first?.1, true)
                XCTAssertFalse(model.tokenHubQuotaIsDirect,
                    "actual AX-positive refresh must retain the non-DIRECT model marker")
            } else if state == .missing {
                XCTAssertTrue(ax.isEmpty, "missing fixture must not fabricate a successful AX scan")
            }
        }
        @MainActor func assertShutdown(_ model: AppModel, permission: BP38C04Permission) {
            XCTAssertEqual(count("load"), 0); XCTAssertEqual(count("save"), 0)
            XCTAssertEqual(count("shouldStart"), 0); XCTAssertEqual(count("localResolve"), 0)
            XCTAssertEqual(count("localScan"), 0); XCTAssertEqual(permission.requests, 0)
            XCTAssertEqual(model.backgroundServiceResources.timerCount, 0)
            XCTAssertEqual(model.backgroundServiceResources.workspaceObserverCount, 0)
            XCTAssertEqual(model.backgroundServiceResources.localScanQueuedCount, 0)
            XCTAssertEqual(model.backgroundServiceResources.axRefreshScheduledCount, 0)
            XCTAssertEqual(model.backgroundServiceResources.axScanInFlightCount, 0)
            XCTAssertEqual(model.backgroundServicesStarted, false)
            XCTAssertEqual(count("scheduleExecuted"), 0)
            XCTAssertEqual(count("scheduleCancelled"), count("scheduleSubmitted"))
        }
    }

    private var bp38C04ExpectedImageNames: [String] {
        let appearances = ["light", "dark"]
        let renders = BP38C04State.allCases.flatMap { state in appearances.map { "\(state.rawValue)-\($0)" } }
        let focus = ["settings", "return", "quit"].flatMap { control in
            appearances.map { "header-\(control)-focus-\($0)" }
        }
        return renders + focus
    }

    private func bp38C04PrivateRoot() throws -> URL {
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = checkout.appendingPathComponent("dist/bp38b/A38-04", isDirectory: true)
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw NSError(domain: "A38-04", code: 20, userInfo: [NSLocalizedDescriptionKey: "Private A38-04 root is unavailable at \(root.path)"])
        }
        return root
    }

    private func bp38C04ValidateOutputDirectories(candidate: URL, accepted: URL?, privateRoot: URL) throws {
        let expectedCandidate = privateRoot.appendingPathComponent("candidates", isDirectory: true).standardizedFileURL
        let candidateResolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        let expectedCandidateResolved = expectedCandidate.resolvingSymlinksInPath().standardizedFileURL
        guard expectedCandidateResolved == expectedCandidate, candidateResolved == expectedCandidate else {
            throw NSError(domain: "A38-04", code: 21, userInfo: [NSLocalizedDescriptionKey: "Candidate output must resolve to the owned private candidates directory"])
        }
        if let accepted {
            let expectedAccepted = privateRoot.appendingPathComponent("accepted", isDirectory: true).standardizedFileURL
            let acceptedResolved = accepted.resolvingSymlinksInPath().standardizedFileURL
            let expectedAcceptedResolved = expectedAccepted.resolvingSymlinksInPath().standardizedFileURL
            guard expectedAcceptedResolved == expectedAccepted, acceptedResolved == expectedAccepted else {
                throw NSError(domain: "A38-04", code: 22, userInfo: [NSLocalizedDescriptionKey: "Accepted output must resolve to the owned private accepted directory"])
            }
            guard candidateResolved != acceptedResolved else {
                throw NSError(domain: "A38-04", code: 23, userInfo: [NSLocalizedDescriptionKey: "Candidate and accepted directories alias after symlink resolution"])
            }
            guard FileManager.default.fileExists(atPath: accepted.path) else {
                throw NSError(domain: "A38-04", code: 24, userInfo: [NSLocalizedDescriptionKey: "Independent accepted image directory does not exist"])
            }
            _ = try bp38C04ReadAcceptedManifest(from: accepted)
        }
    }

    private func bp38C04ReadAcceptedManifest(from directory: URL) throws -> BP38C04AcceptedManifest {
        let manifestURL = directory.appendingPathComponent("accepted-manifest.json")
        try bp38C04RequireRegularOwnedFile(manifestURL)
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(BP38C04AcceptedManifest.self, from: data)
        guard manifest.contract == "C38-04 rev1", !manifest.acceptanceID.isEmpty,
              !manifest.acceptedAt.isEmpty, !manifest.acceptedBy.isEmpty else {
            throw NSError(domain: "A38-04", code: 25, userInfo: [NSLocalizedDescriptionKey: "Accepted manifest lacks independent acceptance identity"])
        }
        let names = manifest.images.map(\.name)
        guard Set(names).count == names.count, Set(names) == Set(bp38C04ExpectedImageNames) else {
            throw NSError(domain: "A38-04", code: 26, userInfo: [NSLocalizedDescriptionKey: "Accepted manifest names do not exactly match the frozen render set"])
        }
        for item in manifest.images {
            let imageURL = directory.appendingPathComponent("\(item.name).png")
            try bp38C04RequireRegularOwnedFile(imageURL)
            let imageData = try Data(contentsOf: imageURL)
            let actual = bp38C04SHA256(imageData)
            guard actual == item.sha256 else {
                throw NSError(domain: "A38-04", code: 27, userInfo: [NSLocalizedDescriptionKey: "Accepted PNG hash does not match accepted-manifest.json: \(item.name)"])
            }
            guard let image = NSImage(data: imageData), image.size == NSSize(width: 460, height: 700) else {
                throw NSError(domain: "A38-04", code: 33, userInfo: [NSLocalizedDescriptionKey: "Accepted PNG is unreadable or has wrong dimensions: \(item.name)"])
            }
        }
        return manifest
    }

    private func bp38C04RequireRegularOwnedFile(_ url: URL) throws {
        let standardized = url.standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard resolved == standardized, values.isSymbolicLink != true, values.isRegularFile == true else {
            throw NSError(domain: "A38-04", code: 34,
                userInfo: [NSLocalizedDescriptionKey: "Accepted input must be an owned regular file with no symlink alias: \(url.lastPathComponent)"])
        }
    }

    private func bp38C04SHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testBP38C04ActualDashboardRenderMatrixAndAcceptedImageOracle() async throws {
        _ = NSApplication.shared
        guard let testRun else {
            throw NSError(domain: "A38-04", code: 35,
                userInfo: [NSLocalizedDescriptionKey: "Cannot verify XCTest assertion status; accepted matching is disabled"])
        }
        let failureCountAtEntry = testRun.failureCount
        guard let candidatePath = ProcessInfo.processInfo.environment["TOKENSTAT_BP38_C04_CANDIDATE_DIR"] else {
            throw XCTSkip("Set TOKENSTAT_BP38_C04_CANDIDATE_DIR to a private A38-04 output directory")
        }
        let privateRoot = try bp38C04PrivateRoot()
        let candidateDirectory = URL(fileURLWithPath: candidatePath, isDirectory: true).standardizedFileURL
        let acceptedPath = ProcessInfo.processInfo.environment["TOKENSTAT_BP38_C04_APPROVED_DIR"]
        let acceptedDirectory = acceptedPath.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        try bp38C04ValidateOutputDirectories(candidate: candidateDirectory, accepted: acceptedDirectory,
            privateRoot: privateRoot)
        let acceptedManifest = try acceptedDirectory.map { try bp38C04ReadAcceptedManifest(from: $0) }
        try FileManager.default.createDirectory(at: candidateDirectory, withIntermediateDirectories: true)
        let pendingStatus = BP38C04CandidateStatus(status: "NOT_ACCEPTED",
            reason: "This run has not completed all required render, focus, action, and image assertions.",
            acceptedBaseline: false)
        try JSONEncoder().encode(pendingStatus).write(to: candidateDirectory.appendingPathComponent("candidate-state.json"), options: .atomic)
        var manifest: [BP38C04RenderedCase] = []
        var images: [String: NSImage] = [:]
        var negativeControlFocusRect: NSRect?
        var negativeControlBarRect: NSRect?
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let appearances: [(String, ColorScheme, NSAppearance.Name)] = [
            ("light", .light, .aqua), ("dark", .dark, .darkAqua)
        ]

        for state in BP38C04State.allCases {
            for (appearanceName, scheme, nativeAppearance) in appearances {
                let now = state == .expired ? base.addingTimeInterval(900) : base
                let observedAt = switch state {
                case .staleWhole: now.addingTimeInterval(-3600)
                case .futureWhole: now.addingTimeInterval(3600)
                case .expired, .mixedExpired: now.addingTimeInterval(-5)
                default: base
                }
                let (model, permission, observations) = try await bp38C04Model(for: state, now: now,
                    observedAt: observedAt)
                observations.assertInitAndRefresh(state: state, expectedDirect: bp38C04UsesDirectSource(state),
                    model: model, permission: permission)
                let root = DashboardView(model: model, panelSize: NSSize(width: 460, height: 700), quitAction: {})
                    .environment(\.colorScheme, scheme)
                    .frame(width: 460, height: 700)
                let host = NSHostingView(rootView: root)
                let bounds = NSRect(x: 0, y: 0, width: 460, height: 700)
                host.frame = bounds
                host.appearance = NSAppearance(named: nativeAppearance)
                let window = NSWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.title = "BP38 synthetic render fixture"
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.center()
                window.appearance = NSAppearance(named: nativeAppearance)
                window.contentView = host
                defer {
                    window.close()
                    model.shutdown()
                    observations.assertShutdown(model, permission: permission)
                }
                window.orderFront(nil)
                window.displayIfNeeded()
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                window.displayIfNeeded()
                host.layoutSubtreeIfNeeded()

                let name = "\(state.rawValue)-\(appearanceName)"
                let normalized = try bp38C04NormalizedImage(from: host, bounds: bounds)
                let png = try XCTUnwrap(bp38C04PNG(normalized))
                let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
                try png.write(to: candidateDirectory.appendingPathComponent("\(name).png"), options: .atomic)
                let visibleText = bp38C04VisibleText(in: host)
                let ocrText = try bp38C04RecognizedText(in: normalized)
                let expected = bp38C04ExpectedText(for: state)
                for text in expected {
                    XCTAssertTrue(ocrText.contains(where: { $0.contains(text) }), "\(name) rendered pixels should visibly contain \(text); OCR=\(ocrText)")
                }
                if state == .staleWhole {
                    XCTAssertTrue(ocrText.contains(where: { $0.contains("95.00%") }), "stale raw percentage remains available as history")
                    XCTAssertTrue(ocrText.contains(where: { $0.contains("历史") }), "stale raw percentage must be labeled historical")
                    XCTAssertFalse(ocrText.contains(where: { $0.contains("剩余") }), "stale values must not present current remaining quota")
                }
                if state == .expired {
                    XCTAssertTrue(ocrText.contains(where: { $0.contains("历史") }), "reset-passed raw facts must be labeled historical")
                    XCTAssertFalse(ocrText.contains(where: { $0.contains("剩余") }), "reset-passed facts must not present current remaining quota")
                }
                if state == .mixedExpired {
                    XCTAssertTrue(ocrText.contains(where: { $0.contains("历史") }), "reset-passed raw facts must be labeled historical")
                    let expiredFiveHourText = try bp38C04VisibleText(inQuotaRow: "5 小时", root: host, window: window)
                    XCTAssertFalse(expiredFiveHourText.contains(where: { $0.contains("剩余") }),
                        "expired five-hour history must not present current remaining quota")
                    let validSevenDayText = try bp38C04VisibleText(inQuotaRow: "7 天", root: host, window: window)
                    XCTAssertTrue(validSevenDayText.contains(where: { $0.contains("剩余") && $0.contains("52.75%") }),
                        "valid 47.25%-used seven-day sibling must retain its 52.75% remaining presentation")
                }
                if state == .futureWhole {
                    XCTAssertFalse(ocrText.contains(where: { $0.contains("95.00%") }), "future observations must not render current percentage facts")
                    XCTAssertFalse(ocrText.contains(where: { $0.contains("剩余") }), "future observations must not present current remaining quota")
                }
                XCTAssertEqual(normalized.size, NSSize(width: 460, height: 700))
                let settingsLookup = bp38C04Element(label: "偏好设置", in: host)
                if settingsLookup == nil {
                    bp38C04DiagnoseMissingRequiredLabel("偏好设置", in: window, host: host)
                }
                let settingsElement = try XCTUnwrap(settingsLookup,
                    "settings label must remain in the real rendered Dashboard")
                let quitLookup = bp38C04Element(label: "退出", in: host)
                if quitLookup == nil {
                    bp38C04DiagnoseMissingRequiredLabel("退出", in: window, host: host)
                }
                let quitElement = try XCTUnwrap(quitLookup,
                    "quit label must remain in the real rendered Dashboard")
                XCTAssertEqual(settingsElement.accessibilityHelp(), "偏好设置")
                XCTAssertEqual(quitElement.accessibilityHelp(), "退出 TokenStatMenu")
                XCTAssertEqual(settingsElement.accessibilityRole(), .button)
                XCTAssertEqual(quitElement.accessibilityRole(), .button)
                var pixelTargets: [String] = []
                var quotaRects: [String: NSRect] = [:]
                for rowLabel in bp38C04ExpectedBarRows(for: state) {
                    let expectedColor = try XCTUnwrap(bp38C04ExpectedBarColor(for: state, row: rowLabel))
                    let rect = try bp38C04QuotaBarRect(label: rowLabel, in: host, window: window,
                        image: normalized, expectedColor: expectedColor)
                    pixelTargets.append("\(rowLabel):\(expectedColor.rawValue):\(bp38C04RectString(rect))")
                    quotaRects[rowLabel] = rect
                }
                for rowLabel in bp38C04NoProgressRows(for: state) {
                    let bar = try bp38C04FindQuotaBarRect(label: rowLabel, in: host, window: window,
                        image: normalized, expectedColor: nil)
                    XCTAssertNil(bar, "\(name) \(rowLabel) has no current progress bar in any quota palette")
                }
                let manifestEntry = BP38C04RenderedCase(name: name, appearance: appearanceName,
                    width: 460, height: 700, sha256: digest, visibleText: visibleText, ocrText: ocrText,
                    alertLevel: bp38C04AlertLevel(model.alertColor),
                    barStates: bp38C04ExpectedBarStates(for: state), pixelTargets: pixelTargets, kind: "render", mutation: nil)
                manifest.append(manifestEntry)
                images[name] = normalized
                XCTAssertEqual(permission.requests, 0, "all direct and AX states must remain on the injected permission provider")

                if state == .directCurrent && appearanceName == "light" {
                    let settingsScreenFrame = try XCTUnwrap(bp38C04Frame(settingsElement))
                    negativeControlFocusRect = bp38C04HostRect(settingsScreenFrame, window: window, host: host)
                    negativeControlBarRect = quotaRects["5 小时"]
                }

                if let acceptedDirectory, let acceptedManifest {
                    let acceptedURL = acceptedDirectory.appendingPathComponent("\(name).png")
                    let expectedImage = try XCTUnwrap(NSImage(contentsOf: acceptedURL), "independently PE-accepted image is required: \(acceptedURL.lastPathComponent)")
                    XCTAssertNil(Snapshotting<NSImage, NSImage>.image.diffing.diffV2(expectedImage, normalized),
                        "\(name) must match the independently reviewed baseline")
                }

                if state == .directCurrent || state == .belowWarning || state == .monthlyWithLimit || state == .usedOnly {
                    XCTAssertEqual(model.alertColor, .labelColor, "monthly usage alone does not trigger the enterprise menu alert")
                }
                if state == .axCurrent {
                    XCTAssertEqual(model.alertColor, .labelColor, "AX display-only percentages remain neutral and never drive menu alerts")
                }
                if state == .staleWhole || state == .futureWhole || state == .missing {
                    XCTAssertEqual(model.alertColor, .labelColor, "whole-snapshot stale, future, and missing data cannot raise a current alert")
                    XCTAssertNil(model.freshTokenHubQuota(at: now), "noncurrent whole-snapshot data must not be exposed as current")
                }
                if state == .belowWarning { XCTAssertEqual(model.alertColor, .labelColor) }
                if state == .warning { XCTAssertEqual(model.alertColor, .systemYellow) }
                if state == .belowCritical { XCTAssertEqual(model.alertColor, .systemYellow) }
                if state == .critical { XCTAssertEqual(model.alertColor, .systemRed) }
            }
        }

        let focused = try await bp38C04CaptureNaturalFocusStates(candidateDirectory: candidateDirectory,
            acceptedDirectory: acceptedDirectory)
        manifest += focused.entries
        images.merge(focused.images) { _, newer in newer }

        // The negative control changes the real rendered settings-control
        // region to the forbidden green edge and must trip the same oracle.
        let baselineName = "direct-current-light"
        let baseline = try XCTUnwrap(images[baselineName])
        let focusRect = try XCTUnwrap(negativeControlFocusRect, "the real settings semantic frame is needed for the focus-edge negative control")
        let barRect = try XCTUnwrap(negativeControlBarRect, "the actual rendered quota bar is needed for the wrong-bar negative control")
        let focusBaselineName = "header-settings-focus-light"
        let focusedBaseline = try XCTUnwrap(images[focusBaselineName], "focused actual render is needed for green-edge mutation")
        let greenMutation = try bp38C04AddGreenFocusEdge(to: focusedBaseline, focusTarget: focusRect)
        let barMutation = try bp38C04RecolorQuotaBar(to: baseline, barTarget: barRect)
        manifest.append(try bp38C04RecordMutation(greenMutation, baseline: focusedBaseline,
            name: "negative-green-focus-edge-only", appearance: "light", derivedFrom: focusBaselineName,
            mutation: "green-border-only", target: focusRect, candidateDirectory: candidateDirectory))
        manifest.append(try bp38C04RecordMutation(barMutation, baseline: baseline,
            name: "negative-five-hour-bar-red-only", appearance: "light", derivedFrom: baselineName,
            mutation: "five-hour-bar-red-only", target: barRect, candidateDirectory: candidateDirectory))

        let renderNames = bp38C04ExpectedImageNames
        let acceptedImageNames = Set(renderNames)
        XCTAssertEqual(Set(manifest.filter { $0.kind == "render" }.map(\.name)), acceptedImageNames,
            "candidate manifest must contain every valid render case exactly once")
        let manifestData = try JSONEncoder().encode(manifest.sorted { $0.name < $1.name })
        try manifestData.write(to: candidateDirectory.appendingPathComponent("manifest.json"), options: .atomic)

        guard let acceptedDirectory, let acceptedManifest else {
            let status = BP38C04CandidateStatus(status: "NOT_ACCEPTED",
                reason: "Candidate images require independent PE visual review and a separate matching run.",
                acceptedBaseline: false)
            try JSONEncoder().encode(status).write(to: candidateDirectory.appendingPathComponent("candidate-state.json"), options: .atomic)
            throw XCTSkip("C38-04 candidate renders were recorded, but matching is not passing until independent PE accepts every image and supplies TOKENSTAT_BP38_C04_APPROVED_DIR")
        }

        XCTAssertEqual(Set(acceptedManifest.images.map(\.name)), acceptedImageNames,
            "the independent acceptance manifest must freeze exactly the valid render image set")
        XCTAssertEqual(acceptedManifest.images.count, acceptedImageNames.count)
        XCTAssertNotNil(Snapshotting<NSImage, NSImage>.image.diffing.diffV2(
            try XCTUnwrap(NSImage(contentsOf: acceptedDirectory.appendingPathComponent("\(focusBaselineName).png"))), greenMutation),
            "green-edge-only mutation must fail against its accepted focused render")
        XCTAssertNotNil(Snapshotting<NSImage, NSImage>.image.diffing.diffV2(
            try XCTUnwrap(NSImage(contentsOf: acceptedDirectory.appendingPathComponent("\(baselineName).png"))), barMutation),
            "wrong-bar-only mutation must fail independently against its accepted quota render")
        guard testRun.failureCount == failureCountAtEntry else {
            let failedStatus = BP38C04CandidateStatus(status: "FAILED",
                reason: "Required XCTest assertions or image comparisons failed; accepted matching is not recorded.",
                acceptedBaseline: false)
            try JSONEncoder().encode(failedStatus).write(to: candidateDirectory.appendingPathComponent("candidate-state.json"), options: .atomic)
            throw NSError(domain: "A38-04", code: 36,
                userInfo: [NSLocalizedDescriptionKey: "Required C38-04 assertions failed; MATCHED_ACCEPTED status was withheld"])
        }
        let acceptedStatus = BP38C04CandidateStatus(status: "MATCHED_ACCEPTED",
            reason: "Every independently accepted render matched and both isolated negative controls were rejected.",
            acceptedBaseline: true)
        try JSONEncoder().encode(acceptedStatus).write(to: candidateDirectory.appendingPathComponent("candidate-state.json"), options: .atomic)
    }

    private func bp38C04CaptureNaturalFocusStates(candidateDirectory: URL, acceptedDirectory: URL?) async throws
        -> (entries: [BP38C04RenderedCase], images: [String: NSImage]) {
        var entries: [BP38C04RenderedCase] = []
        var images: [String: NSImage] = [:]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let appearances: [(String, ColorScheme, NSAppearance.Name)] = [
            ("light", .light, .aqua), ("dark", .dark, .darkAqua)
        ]
        for (appearanceName, scheme, nativeAppearance) in appearances {
            let (model, permission, observations) = try await bp38C04Model(for: .directCurrent, now: base, observedAt: base)
            observations.assertInitAndRefresh(state: .directCurrent, expectedDirect: bp38C04UsesDirectSource(.directCurrent),
                model: model, permission: permission)
            var quitCalls = 0
            let root = DashboardView(model: model, panelSize: NSSize(width: 460, height: 700), quitAction: { quitCalls += 1 })
                .environment(\.colorScheme, scheme)
                .frame(width: 460, height: 700)
            let bounds = NSRect(x: 0, y: 0, width: 460, height: 700)
            let host = NSHostingView(rootView: root)
            host.frame = bounds
            host.appearance = NSAppearance(named: nativeAppearance)
            let window = NSWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "BP38 natural-focus fixture \(appearanceName)"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.center()
            window.appearance = NSAppearance(named: nativeAppearance)
            window.contentView = host
            defer {
                window.close()
                model.shutdown()
                observations.assertShutdown(model, permission: permission)
            }
            host.layoutSubtreeIfNeeded()
            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            host.layoutSubtreeIfNeeded()
            guard window.isKeyWindow else {
                throw XCTSkip("BLOCKED C38-04: test-owned \(appearanceName) window could not become key")
            }

            let settings = try XCTUnwrap(bp38C04Element(label: "偏好设置", in: host))
            let quit = try XCTUnwrap(bp38C04Element(label: "退出", in: host))
            XCTAssertEqual(settings.accessibilityRole(), .button)
            XCTAssertEqual(quit.accessibilityRole(), .button)
            XCTAssertEqual(settings.accessibilityHelp(), "偏好设置")
            XCTAssertEqual(quit.accessibilityHelp(), "退出 TokenStatMenu")
            let settingsFrame = try XCTUnwrap(bp38C04Frame(settings))
            let quitFrame = try XCTUnwrap(bp38C04Frame(quit))
            bp38C04AssertActionFrame(settingsFrame, label: "settings \(appearanceName)")
            bp38C04AssertActionFrame(quitFrame, label: "quit \(appearanceName)")

            try bp38C04Focus(label: "偏好设置", backwards: false, in: window, host: host)
            try bp38C04Focus(label: "退出", backwards: true, in: window, host: host)
            try bp38C04Focus(label: "偏好设置", backwards: false, in: window, host: host)
            var (settingsEntry, settingsImage) = try bp38C04RecordFocusedImage(name: "header-settings-focus-\(appearanceName)",
                appearance: appearanceName, model: model, host: host, bounds: bounds,
                candidateDirectory: candidateDirectory, acceptedDirectory: acceptedDirectory)
            entries.append(settingsEntry)
            images[settingsEntry.name] = settingsImage

            try bp38C04Click(settingsFrame, in: window)
            let returnButton = try bp38C04WaitForElement(label: "返回概览", in: host)
            XCTAssertEqual(returnButton.accessibilityRole(), .button)
            XCTAssertEqual(returnButton.accessibilityHelp(), "返回概览")
            let returnFrame = try XCTUnwrap(bp38C04Frame(returnButton))
            bp38C04AssertActionFrame(returnFrame, label: "return \(appearanceName)")
            try bp38C04Focus(label: "返回概览", backwards: false, in: window, host: host)
            let (returnEntry, returnImage) = try bp38C04RecordFocusedImage(name: "header-return-focus-\(appearanceName)",
                appearance: appearanceName, model: model, host: host, bounds: bounds,
                candidateDirectory: candidateDirectory, acceptedDirectory: acceptedDirectory)
            entries.append(returnEntry)
            images[returnEntry.name] = returnImage

            try bp38C04Click(returnFrame, in: window)
            let restoredSettings = try bp38C04WaitForElement(label: "偏好设置", in: host)
            XCTAssertEqual(restoredSettings.accessibilityHelp(), "偏好设置", "return action restores the overview state")
            try bp38C04Focus(label: "退出", backwards: false, in: window, host: host)
            let (quitEntry, quitImage) = try bp38C04RecordFocusedImage(name: "header-quit-focus-\(appearanceName)",
                appearance: appearanceName, model: model, host: host, bounds: bounds,
                candidateDirectory: candidateDirectory, acceptedDirectory: acceptedDirectory)
            entries.append(quitEntry)
            images[quitEntry.name] = quitImage

            // Reconfirm the actual target and owned responder immediately before activation.
            XCTAssertTrue(window.isKeyWindow)
            XCTAssertTrue(bp38C04ResponderIsInsideHost(window, host: host))
            XCTAssertEqual(bp38C04FocusedLabel(in: host), "退出")
            bp38C04SendSpace(window)
            XCTAssertEqual(quitCalls, 1, "focused quit invokes only the injected fixture closure")
            XCTAssertTrue(window.isVisible, "the contained action leaves the test host visible and alive")
            XCTAssertEqual(permission.requests, 0)
        }
        return (entries, images)
    }

    private func bp38C04Focus(label: String, backwards: Bool, in window: NSWindow, host: NSView) throws {
        for _ in 0..<24 {
            bp38C04SendTab(window, backwards: backwards)
            guard window.isKeyWindow else {
                throw XCTSkip("BLOCKED C38-04: key-window status was lost during natural focus traversal")
            }
            guard bp38C04ResponderIsInsideHost(window, host: host) else {
                throw XCTSkip("BLOCKED C38-04: natural traversal could not obtain a responder inside the owned host")
            }
            if bp38C04FocusedLabel(in: host) == label { return }
        }
        XCTFail("Natural Tab/Shift-Tab traversal retained the keyed hosted responder but did not focus semantic control \(label)")
        throw NSError(domain: "A38-04", code: 28, userInfo: [NSLocalizedDescriptionKey: "Missing natural focus target \(label)"])
    }

    private func bp38C04FocusedLabel(in host: NSView) -> String? {
        guard let focused = bp38C04FocusedDescendant(in: host) else { return nil }
        return bp38C04TextAttribute(focused, #selector(NSAccessibilityProtocol.accessibilityLabel))
    }

    private func bp38C04ResponderIsInsideHost(_ window: NSWindow, host: NSView) -> Bool {
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder === host || responder.isDescendant(of: host)
    }

    private func bp38C04AssertActionFrame(_ frame: NSRect, label: String) {
        XCTAssertEqual(frame.width, 30, accuracy: 1, "\(label) target width")
        XCTAssertEqual(frame.height, 30, accuracy: 1, "\(label) target height")
    }

    private func bp38C04RecordFocusedImage(name: String, appearance: String, model: AppModel, host: NSView,
                                             bounds: NSRect, candidateDirectory: URL, acceptedDirectory: URL?) throws
        -> (BP38C04RenderedCase, NSImage) {
        let normalized = try bp38C04NormalizedImage(from: host, bounds: bounds)
        guard let png = bp38C04PNG(normalized) else {
            throw NSError(domain: "A38-04", code: 29, userInfo: [NSLocalizedDescriptionKey: "Cannot encode focused render \(name)"])
        }
        try png.write(to: candidateDirectory.appendingPathComponent("\(name).png"), options: .atomic)
        let ocrText = try bp38C04RecognizedText(in: normalized)
        XCTAssertTrue(ocrText.contains(where: { $0.contains("TokenStatMenu") }), "\(name) must preserve visible dashboard text: \(ocrText)")
        let entry = BP38C04RenderedCase(name: name, appearance: appearance, width: 460, height: 700,
            sha256: bp38C04SHA256(png), visibleText: bp38C04VisibleText(in: host), ocrText: ocrText,
            alertLevel: bp38C04AlertLevel(model.alertColor), barStates: bp38C04ExpectedBarStates(for: .directCurrent),
            pixelTargets: [], kind: "render", mutation: nil)
        if let acceptedDirectory {
            let accepted = try XCTUnwrap(NSImage(contentsOf: acceptedDirectory.appendingPathComponent("\(name).png")),
                "accepted focused render is required: \(name)")
            XCTAssertNil(Snapshotting<NSImage, NSImage>.image.diffing.diffV2(accepted, normalized),
                "naturally focused render must match independent PE acceptance: \(name)")
        }
        return (entry, normalized)
    }

    private func bp38C04Model(for state: BP38C04State, now: Date, observedAt: Date) async throws -> (AppModel, BP38C04Permission, BP38C04Observations) {
        let identity = TokenHubIdentity(pid: 85_404, bundleID: TokenHubTarget.bundleID,
            executablePath: "/Synthetic/BP38-C04-Hub")
        func window(_ kind: TokenHubWindowKind, percent: Decimal, reset: Date?) -> TokenHubWindowQuota {
            TokenHubWindowQuota(kind: kind, usedAmount: percent, limitAmount: 100,
                sourceSymbol: "$", usedPercent: percent,
                resetDisplay: reset == nil ? "未知" : "合成重置", resetAt: reset)
        }
        let percent: Decimal = switch state {
        case .directCurrent, .belowWarning: Decimal(string: "79.995")!
        case .warning: Decimal(80)
        case .belowCritical: Decimal(string: "94.995")!
        case .critical, .expired, .mixedExpired, .staleWhole, .futureWhole: Decimal(95)
        default: Decimal(string: "47.25")!
        }
        let direct = bp38C04UsesDirectSource(state)
        let five: TokenHubWindowQuota? = switch state {
        case .missing, .usedOnly, .monthlyWithLimit, .mixedMissing: nil
        case .expired, .mixedExpired: window(.fiveHour, percent: percent, reset: now.addingTimeInterval(-1))
        default: window(.fiveHour, percent: percent, reset: direct ? now.addingTimeInterval(3600) : nil)
        }
        let seven: TokenHubWindowQuota? = switch state {
        case .missing, .usedOnly, .monthlyWithLimit: nil
        case .expired: window(.sevenDay, percent: percent, reset: now.addingTimeInterval(-1))
        case .mixedExpired: window(.sevenDay, percent: Decimal(string: "47.25")!, reset: now.addingTimeInterval(7200))
        default: window(.sevenDay, percent: percent, reset: direct ? now.addingTimeInterval(7200) : nil)
        }
        let monthly: TokenHubMonthlyUsage? = switch state {
        case .usedOnly, .axCurrent: TokenHubMonthlyUsage(usedAmount: Decimal(string: "37.50")!, sourceSymbol: "$")
        case .monthlyWithLimit: TokenHubMonthlyUsage(usedAmount: Decimal(string: "79.995")!, sourceSymbol: "$", limitAmount: Decimal(100))
        case .directCurrent, .belowWarning, .warning, .belowCritical, .critical, .staleWhole, .futureWhole:
            TokenHubMonthlyUsage(usedAmount: percent, sourceSymbol: "$", limitAmount: Decimal(100))
        default: nil
        }
        let snapshot: TokenHubQuotaSnapshot? = state == .missing ? nil : TokenHubQuotaSnapshot(
            identity: identity, fiveHour: five, sevenDay: seven, monthly: monthly, observedAt: observedAt)
        let axResult = TokenHubQuotaResult(status: snapshot == nil ? .targetNotRunning : .connected,
            snapshot: snapshot, failure: nil)
        let observations = BP38C04Observations()
        let syntheticAX = TokenHubAXSource.synthetic { _ in
            observations.increment("axScan")
            observations.recordAX(identity: snapshot.map { "\($0.identity.pid)|\($0.identity.bundleID)|\($0.identity.executablePath)" },
                connected: axResult.status == .connected)
            return axResult
        }
        let permission = BP38C04Permission()
        let timing = AppModelTimingDependencies(wallNow: { now }, monotonicNow: { 0 }, schedule: { _, operation in
            observations.increment("scheduleSubmitted")
            let observedOperation: @MainActor () -> Void = {
                observations.increment("scheduleExecuted")
                operation()
            }
            return {
                withExtendedLifetime(observedOperation) {}
                observations.increment("scheduleCancelled")
            }
        })
        let startup = AppModelStartupDependencies(
            loadPreferences: { observations.increment("load"); return nil },
            savePreferences: { _ in observations.increment("save") },
            shouldStartBackgroundServices: { observations.increment("shouldStart"); return false },
            observeWorkspaceNotifications: false)
        let localScanning = LocalCodexScanDependencies(
            resolveInputs: { observations.increment("localResolve"); return (URL(fileURLWithPath: "/Synthetic/BP38-C04"), .unverified) },
            scan: { _, _, _, _ in observations.increment("localScan"); throw CancellationError() })
        let model: AppModel
        if direct {
            let direct = TokenHubDirectQuotaDependencies(discoverTarget: { identity },
                identityIsCurrent: { $0 == identity }, fetch: { _, _ in
                    guard let snapshot else { throw TokenHubQuotaFailure.noTarget }
                    return snapshot
                })
            model = AppModel(preview: true, startup: startup, timing: timing, directQuota: direct,
                localScanning: localScanning,
                tokenHubPermissionProvider: permission, tokenHubAXSource: syntheticAX)
        } else {
            model = AppModel(preview: true, startup: startup, timing: timing, directQuota: nil,
                localScanning: localScanning,
                tokenHubPermissionProvider: permission, tokenHubAXSource: syntheticAX)
        }
        var ownershipTransferred = false
        defer {
            if !ownershipTransferred {
                model.shutdown()
                observations.assertShutdown(model, permission: permission)
            }
        }
        observations.assertInitialized(model: model, permission: permission)
        model.config.dataSource = "localCodex"
        model.tokenHubAutomaticReadingEnabled = true
        if state != .missing {
            model.refreshTokenHubQuota(observationNow: observedAt)
            for _ in 0..<100 {
                if model.tokenHubQuotaStatus == .connected { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(model.tokenHubQuotaStatus, .connected, "synthetic model should reach connected state without OS or network")
        }
        observations.assertInitAndRefresh(state: state, expectedDirect: direct, model: model, permission: permission)
        let observedSnapshot = model.freshTokenHubQuota(at: now)
        if !direct, let observedSnapshot {
            XCTAssertNil(observedSnapshot.fiveHour?.resetAt, "AX fixture never invents a reset timestamp")
            XCTAssertNil(observedSnapshot.sevenDay?.resetAt, "AX fixture never invents a reset timestamp")
            if let monthly = observedSnapshot.monthly {
                XCTAssertNil(monthly.limitAmount, "AX monthly fixture remains used-only")
            }
        }
        if state == .expired {
            let projection = model.quotaPresentation(at: now)
            let raw = try XCTUnwrap(projection.snapshot)
            XCTAssertLessThanOrEqual(try XCTUnwrap(raw.fiveHour?.resetAt), now)
            XCTAssertLessThanOrEqual(try XCTUnwrap(raw.sevenDay?.resetAt), now)
            XCTAssertEqual(raw.fiveHour?.usedPercent, Decimal(95))
            XCTAssertEqual(raw.sevenDay?.usedPercent, Decimal(95))
            XCTAssertTrue(projection.fiveHour?.resetPassed == true, "five-hour reset is expired in the projection")
            XCTAssertTrue(projection.sevenDay?.resetPassed == true, "seven-day reset is expired in the projection")
            XCTAssertNil(projection.fiveHourCurrent, "expired five-hour data is retained only as raw history")
            XCTAssertNil(projection.sevenDayCurrent, "expired seven-day data is retained only as raw history")
            XCTAssertNil(projection.monthlyCurrent, "this fixture has no current monthly fact")
            XCTAssertNil(observedSnapshot, "no current facts remain after both windows expire")
            XCTAssertEqual(model.alertColor, .labelColor, "both reset-passed windows are excluded from the current alert")
        }
        if state == .mixedMissing {
            XCTAssertNil(observedSnapshot?.fiveHour)
            XCTAssertGreaterThan(try XCTUnwrap(observedSnapshot?.sevenDay?.resetAt), now)
        }
        if state == .mixedExpired {
            let raw = try XCTUnwrap(model.tokenHubQuotaSnapshot)
            XCTAssertLessThanOrEqual(try XCTUnwrap(raw.fiveHour?.resetAt), now)
            XCTAssertGreaterThan(try XCTUnwrap(raw.sevenDay?.resetAt), now)
            XCTAssertEqual(raw.fiveHour?.usedPercent, Decimal(95))
            XCTAssertEqual(raw.sevenDay?.usedPercent, Decimal(string: "47.25"))
            XCTAssertNil(observedSnapshot?.fiveHour, "expired five-hour data remains raw history only")
            XCTAssertEqual(observedSnapshot?.sevenDay?.usedPercent, Decimal(string: "47.25"),
                "the valid seven-day sibling remains a distinct current fact")
            XCTAssertGreaterThan(try XCTUnwrap(observedSnapshot?.sevenDay?.resetAt), now)
            XCTAssertNotNil(observedSnapshot, "valid seven-day sibling keeps the current-only result nonnil")
            XCTAssertEqual(model.alertColor, .labelColor, "expired 5-hour history cannot alert; valid low 7-day sibling remains neutral")
        }
        if state == .monthlyWithLimit {
            XCTAssertNotNil(observedSnapshot?.monthly?.limitAmount)
            XCTAssertNil(observedSnapshot?.fiveHour)
            XCTAssertNil(observedSnapshot?.sevenDay)
        }
        if state == .staleWhole || state == .futureWhole {
            let raw = try XCTUnwrap(model.tokenHubQuotaSnapshot, "noncurrent snapshot facts must be retained for diagnosis/history")
            XCTAssertEqual(raw.observedAt, observedAt)
            XCTAssertEqual(raw.fiveHour?.usedPercent, percent)
            XCTAssertEqual(raw.sevenDay?.usedPercent, percent)
            XCTAssertEqual(raw.fiveHour?.resetDisplay, "合成重置")
            XCTAssertEqual(raw.sevenDay?.resetDisplay, "合成重置")
            XCTAssertEqual(raw.fiveHour?.resetAt, now.addingTimeInterval(3600))
            XCTAssertEqual(raw.sevenDay?.resetAt, now.addingTimeInterval(7200))
            XCTAssertEqual(raw.monthly?.usedAmount, percent)
            XCTAssertEqual(raw.monthly?.limitAmount, Decimal(100))
            XCTAssertNil(model.freshTokenHubQuota(at: now), "stale/future raw facts cannot become current window or monthly facts")
        }
        if state == .missing {
            XCTAssertNil(model.tokenHubQuotaSnapshot, "missing source data must not fall back to an earlier raw snapshot")
            XCTAssertNil(model.freshTokenHubQuota(at: now))
        }
        XCTAssertEqual(permission.requests, 0, "synthetic fixture must never request Accessibility trust or open System Settings")
        ownershipTransferred = true
        return (model, permission, observations)
    }

    private func bp38C04ExpectedText(for state: BP38C04State) -> [String] {
        switch state {
        case .directCurrent: ["Token Hub 企业额度", "后台已用", "月度"]
        case .axCurrent: ["Token Hub 界面额度快照", "界面已用", "47.25%", "月度", "后台未提供月度总额"]
        case .missing: ["Token Hub 界面额度快照", "Token Hub 未运行"]
        case .usedOnly: ["Token Hub 界面额度快照", "月度", "后台未提供月度总额"]
        case .expired: ["Token Hub 企业额度", "历史", "后台已用", "95.00%", "合成重置"]
        case .staleWhole: ["Token Hub 企业额度", "历史", "后台已用", "合成重置"]
        case .futureWhole: ["Token Hub 企业额度", "异常", "未知"]
        case .mixedMissing: ["Token Hub 企业额度", "5 小时", "未知", "7 天"]
        case .mixedExpired: ["Token Hub 企业额度", "历史", "后台已用", "95.00%", "合成重置", "7 天", "47.25%"]
        case .monthlyWithLimit: ["Token Hub 企业额度", "月度", "已用 80.00%", "剩余"]
        case .belowWarning, .warning, .belowCritical, .critical: ["后台已用"]
        }
    }

    private func bp38C04ExpectedBarRows(for state: BP38C04State) -> [String] {
        switch state {
        case .directCurrent, .belowWarning, .warning, .belowCritical, .critical:
            return ["5 小时", "7 天", "月度"]
        case .axCurrent:
            return ["5 小时", "7 天"]
        case .mixedMissing:
            return ["7 天"]
        case .mixedExpired:
            return ["7 天"]
        case .monthlyWithLimit:
            return ["月度"]
        case .expired, .staleWhole, .futureWhole, .missing, .usedOnly:
            return []
        }
    }

    private func bp38C04ExpectedBarStates(for state: BP38C04State) -> [String] {
        let percent: String
        switch state {
        case .directCurrent, .belowWarning: percent = "79.995"
        case .warning: percent = "80"
        case .belowCritical: percent = "94.995"
        case .critical, .staleWhole, .futureWhole: percent = "95"
        default: percent = "47.25"
        }
        switch state {
        case .directCurrent, .belowWarning:
            return ["5 小时=\(percent)%/normal-blue", "7 天=\(percent)%/normal-blue", "月度=\(percent)%/normal-blue"]
        case .warning, .belowCritical:
            return ["5 小时=\(percent)%/warning-yellow", "7 天=\(percent)%/warning-yellow", "月度=\(percent)%/warning-yellow"]
        case .critical:
            return ["5 小时=\(percent)%/critical-red", "7 天=\(percent)%/critical-red", "月度=\(percent)%/critical-red"]
        case .axCurrent:
            return ["5 小时=47.25%/display-only-normal-blue", "7 天=47.25%/display-only-normal-blue", "月度=used-only/no-bar"]
        case .expired:
            return ["5 小时=95%/historical-no-progress", "7 天=95%/historical-no-progress"]
        case .staleWhole:
            return ["5 小时=95%/historical-no-progress", "7 天=95%/historical-no-progress", "月度=95%/historical-no-progress"]
        case .futureWhole:
            return ["5 小时=unavailable/no-bar", "7 天=unavailable/no-bar", "月度=unavailable/no-bar"]
        case .mixedMissing:
            return ["5 小时=missing/no-bar", "7 天=47.25%/normal-blue"]
        case .mixedExpired:
            return ["5 小时=95%/historical-no-progress", "7 天=47.25%/normal-blue"]
        case .monthlyWithLimit:
            return ["5 小时=missing/no-bar", "7 天=missing/no-bar", "月度=79.995%/normal-blue"]
        case .missing, .usedOnly:
            return ["5 小时=missing/no-bar", "7 天=missing/no-bar", "月度=used-only/no-bar"]
        }
    }

    private func bp38C04ExpectedBarColor(for state: BP38C04State, row _: String) -> BP38C04BarColor? {
        switch state {
        case .axCurrent:
            return .normalBlue
        case .directCurrent, .belowWarning, .mixedMissing, .mixedExpired, .monthlyWithLimit:
            return .normalBlue
        case .warning, .belowCritical:
            return .warningYellow
        case .critical:
            return .criticalRed
        case .missing, .usedOnly, .expired, .staleWhole, .futureWhole:
            return nil
        }
    }

    private func bp38C04NoProgressRows(for state: BP38C04State) -> [String] {
        switch state {
        case .expired, .staleWhole, .futureWhole:
            return ["5 小时", "7 天", "月度"]
        case .missing:
            return ["5 小时", "7 天", "月度"]
        case .usedOnly:
            return ["月度"]
        case .axCurrent:
            return ["月度"]
        case .mixedMissing, .mixedExpired:
            return ["5 小时", "月度"]
        case .monthlyWithLimit:
            return ["5 小时", "7 天"]
        case .directCurrent, .belowWarning, .warning, .belowCritical, .critical:
            return []
        }
    }

    private func bp38C04UsesDirectSource(_ state: BP38C04State) -> Bool {
        switch state {
        case .directCurrent, .expired, .staleWhole, .futureWhole, .mixedMissing, .mixedExpired, .monthlyWithLimit,
             .belowWarning, .warning, .belowCritical, .critical: true
        default: false
        }
    }

    private func bp38C04Element(label: String, in root: NSView) -> (any NSAccessibilityProtocol)? {
        bp38C04Elements(in: root).first {
            bp38C04TextAttribute($0, #selector(NSAccessibilityProtocol.accessibilityLabel)) == label
        }
    }

    private func bp38C04WaitForElement(label: String, in root: NSView) throws -> any NSAccessibilityProtocol {
        for _ in 0..<30 {
            if let element = bp38C04Element(label: label, in: root) { return element }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("C38-04 required semantic control/action state did not expose \(label)")
        throw NSError(domain: "A38-04", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required semantic label \(label)"])
    }

    private func bp38C04Elements(in root: NSView) -> [any NSAccessibilityProtocol] {
        var result: [any NSAccessibilityProtocol] = []
        var visited = Set<ObjectIdentifier>()
        var queue: [any NSAccessibilityProtocol] = [root]
        while let item = queue.popLast(), visited.insert(ObjectIdentifier(item as AnyObject)).inserted {
            result.append(item)
            queue.append(contentsOf: item.accessibilityChildren()?.compactMap { $0 as? any NSAccessibilityProtocol } ?? [])
        }
        return result
    }

    private func bp38C04DiagnoseMissingRequiredLabel(_ label: String, in window: NSWindow, host: NSView) {
        // The caller already captured nil. This same-contract owned-process experiment cannot
        // replace the original semantic failure oracle, the required XCTUnwrap below.
        let application = NSApplication.shared
        let savedPolicy = application.activationPolicy()
        let dashboardBefore = bp38C04KeyProbeSnapshot(label: label, window: window, host: host,
            source: "dashboard.before-key-transition")
        var report: [String: Any] = [
            "phase": "original-checkpoint-preserved",
            "targetLabel": bp38C04AllowlistedDiagnosticText(label),
            "dashboardBeforeKeyTransition": dashboardBefore.facts
        ]
        if dashboardBefore.rootRoutesEmpty {
            report["ownedWindowFallback"] = "queried-explicit-owned-window-and-contentView-before-and-after-key-transition"
        } else {
            report["ownedWindowFallback"] = "not-queried-host-routes-nonempty"
        }

        var restoreRequired = false
        var setterAttempted = false
        var setterSucceeded: Bool?
        var accessoryEstablished: Bool?
        var restorationSucceeded: Bool?
        var restorationMatchesSavedPolicy: Bool?
        var controlWindowForCleanup: NSWindow?
        defer { controlWindowForCleanup?.close() }

        do {
            defer {
                if restoreRequired {
                    let restored = application.setActivationPolicy(savedPolicy)
                    let readback = application.activationPolicy()
                    restorationSucceeded = restored
                    restorationMatchesSavedPolicy = readback == savedPolicy
                    report["policyRestoration"] = [
                        "attempted": true,
                        "setterSucceeded": restored,
                        "policyReadback": bp38C04ActivationPolicyCategory(readback),
                        "matchesSavedPolicy": readback == savedPolicy
                    ]
                }
            }

            // Re-read the guard at the point of the experiment. An unexpected state records
            // not-attempted and proceeds with the existing owned-window key probes unchanged.
            let guardPolicy = application.activationPolicy()
            let dashboardCanBecomeKey = window.canBecomeKey
            let mayAttemptAccessory = guardPolicy == .prohibited && dashboardCanBecomeKey
            report["policyExperiment"] = [
                "savedPolicy": bp38C04ActivationPolicyCategory(savedPolicy),
                "guardPolicy": bp38C04ActivationPolicyCategory(guardPolicy),
                "dashboardWindowCanBecomeKey": dashboardCanBecomeKey,
                "attempted": mayAttemptAccessory
            ]
            if mayAttemptAccessory {
                restoreRequired = true
                setterAttempted = true
                let changed = application.setActivationPolicy(.accessory)
                let readback = application.activationPolicy()
                setterSucceeded = changed
                accessoryEstablished = readback == .accessory
                report["policyExperiment"] = [
                    "savedPolicy": bp38C04ActivationPolicyCategory(savedPolicy),
                    "guardPolicy": bp38C04ActivationPolicyCategory(guardPolicy),
                    "dashboardWindowCanBecomeKey": dashboardCanBecomeKey,
                    "attempted": true,
                    "requestedPolicy": "accessory",
                    "setterSucceeded": changed,
                    "policyReadback": bp38C04ActivationPolicyCategory(readback),
                    "accessoryEstablished": readback == .accessory
                ]
            }

            window.makeKeyAndOrderFront(nil)
            bp38C04SettleKeyProbe(window: window, host: host)
            let dashboardAfter = bp38C04KeyProbeSnapshot(label: label, window: window, host: host,
                source: "dashboard.after-key-transition", includeOwnedWindowRoutes: dashboardBefore.rootRoutesEmpty)
            report["dashboardAfterKeyTransition"] = dashboardAfter.facts

            // Positive capability control only: plain SwiftUI Button in its own test-owned window.
            let controlRoot = Button("C04 probe button") {}
                .help("C04 probe help")
                .accessibilityLabel("C04 probe button")
                .frame(width: 460, height: 700)
            let controlHost = NSHostingView(rootView: controlRoot)
            let bounds = NSRect(x: 0, y: 0, width: 460, height: 700)
            controlHost.frame = bounds
            controlHost.appearance = host.appearance
            let controlWindow = NSWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
            controlWindow.isReleasedWhenClosed = false
            controlWindow.title = "C04 owned diagnostic control"
            controlWindow.titleVisibility = .hidden
            controlWindow.titlebarAppearsTransparent = true
            controlWindow.center()
            controlWindow.appearance = window.appearance
            controlWindow.contentView = controlHost
            controlWindowForCleanup = controlWindow
            controlWindow.orderFront(nil)
            bp38C04SettleKeyProbe(window: controlWindow, host: controlHost)
            let controlBefore = bp38C04KeyProbeSnapshot(label: "C04 probe button", window: controlWindow,
                host: controlHost, source: "synthetic-button.before-key-transition", includeOwnedWindowRoutes: false)
            controlWindow.makeKeyAndOrderFront(nil)
            bp38C04SettleKeyProbe(window: controlWindow, host: controlHost)
            let controlAfter = bp38C04KeyProbeSnapshot(label: "C04 probe button", window: controlWindow,
                host: controlHost, source: "synthetic-button.after-key-transition", includeOwnedWindowRoutes: false)
            report["syntheticButtonControl"] = [
                "beforeKeyTransition": controlBefore.facts,
                "afterKeyTransition": controlAfter.facts
            ]
        }

        // The experiment's defer has restored the original policy before this report is serialized.
        if JSONSerialization.isValidJSONObject(report),
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print("[C04-OWN-ROUTES] \(text)")
        } else {
            print("[C04-OWN-ROUTES] summaryEncodingFailed=true")
        }

        if setterAttempted && (setterSucceeded != true || accessoryEstablished != true) {
            XCTFail("Owned-process accessory policy setter/readback did not establish accessory policy")
        }
        if restoreRequired && (restorationSucceeded != true || restorationMatchesSavedPolicy != true) {
            XCTFail("Owned-process activation policy restoration failed or did not match the saved policy")
        }
    }

    private func bp38C04KeyProbeSnapshot(label: String, window: NSWindow, host: NSView, source: String,
                                         includeOwnedWindowRoutes: Bool? = nil)
        -> (facts: [String: Any], rootRoutesEmpty: Bool) {
        let hostRoutes = bp38C04RouteSummary(for: host as any NSAccessibilityProtocol,
            source: "\(source).host", targetLabel: label)
        let hostDescendants = bp38C04BoundedContentRoutes(from: host as any NSAccessibilityProtocol,
            source: "\(source).host-descendants", targetLabel: label)
        let shouldIncludeWindow = includeOwnedWindowRoutes ?? !hostRoutes.hasObjects
        let application = NSApplication.shared
        var facts: [String: Any] = [
            "source": source,
            "applicationActivationPolicy": bp38C04ActivationPolicyCategory(application.activationPolicy()),
            "applicationIsRunning": application.isRunning,
            "applicationIsActive": application.isActive,
            "hostAttachedToPassedWindow": host.window === window,
            "windowVisible": window.isVisible,
            "windowKey": window.isKeyWindow,
            "windowCanBecomeKey": window.canBecomeKey,
            "windowCanBecomeMain": window.canBecomeMain,
            "hostRoutes": hostRoutes.summary,
            "hostDescendants": hostDescendants
        ]
        if shouldIncludeWindow {
            let ownedWindow = bp38C04RouteSummary(for: window as any NSAccessibilityProtocol,
                source: "\(source).owned-window", targetLabel: label)
            facts["ownedWindowRoutes"] = ownedWindow.summary
            facts["ownedWindowContentDescendants"] = bp38C04BoundedContentRoutes(
                from: window as any NSAccessibilityProtocol, source: "\(source).owned-window-content-routes",
                targetLabel: label)
            if let contentView = window.contentView as? any NSAccessibilityProtocol {
                facts["ownedContentViewDescendants"] = bp38C04BoundedContentRoutes(
                    from: contentView, source: "\(source).owned-window.contentView-descendants", targetLabel: label)
            } else {
                facts["ownedContentViewDescendants"] = ["available": false, "incomplete": true]
            }
        }
        return (facts, !hostRoutes.hasObjects)
    }

    private func bp38C04ActivationPolicyCategory(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown"
        }
    }

    private func bp38C04SettleKeyProbe(window: NSWindow, host: NSView) {
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
    }

    private func bp38C04RouteSummary(for provider: any NSAccessibilityProtocol, source: String,
                                    targetLabel: String)
        -> (summary: [String: Any], objects: [AnyObject], hasObjects: Bool) {
        let routes: [(String, [Any])] = [
            ("children", provider.accessibilityChildren() ?? []),
            ("navigationOrder", provider.accessibilityChildrenInNavigationOrder() ?? []),
            ("contents", provider.accessibilityContents() ?? [])
        ]
        let routeLimit = 32
        var routeRecords: [[String: Any]] = []
        var allObjects: [AnyObject] = []
        var allIDs = Set<ObjectIdentifier>()
        var hasObjects = false
        var anyRouteTruncated = false
        var totalIncompleteCount = 0
        var providerFacts: [[String: Any]] = []

        if let facts = bp38C04DiagnosticFacts(for: provider, targetLabel: targetLabel) {
            providerFacts.append(facts)
        }

        for (routeName, rawValues) in routes {
            hasObjects = hasObjects || !rawValues.isEmpty
            let objects = Array(rawValues.prefix(routeLimit)).map { $0 as AnyObject }
            var routeIDs = Set<ObjectIdentifier>()
            let distinctObjects = objects.filter { routeIDs.insert(ObjectIdentifier($0)).inserted }
            let full = distinctObjects.compactMap { $0 as? any NSAccessibilityProtocol }
            let narrow = distinctObjects.compactMap { $0 as? any NSAccessibilityElementProtocol }
            let fullIDs = Set(full.map { ObjectIdentifier($0 as AnyObject) })
            let narrowIDs = Set(narrow.map { ObjectIdentifier($0 as AnyObject) })
            let narrowOnlyIDs = narrowIDs.subtracting(fullIDs)
            let unsupportedCount = distinctObjects.count - fullIDs.count
            let narrowOnlyFacts = distinctObjects.compactMap { object -> (any NSAccessibilityElementProtocol)? in
                guard let element = object as? any NSAccessibilityElementProtocol,
                      narrowOnlyIDs.contains(ObjectIdentifier(object)) else { return nil }
                return element
            }.prefix(16).map { ["hasFrame": !$0.accessibilityFrame().isEmpty] as [String: Any] }
            var targetFacts: [[String: Any]] = []
            for element in full {
                if let facts = bp38C04DiagnosticFacts(for: element, targetLabel: targetLabel) {
                    targetFacts.append(facts)
                }
            }
            let routeTruncated = rawValues.count > routeLimit
            anyRouteTruncated = anyRouteTruncated || routeTruncated
            totalIncompleteCount += unsupportedCount
            for object in distinctObjects where allIDs.insert(ObjectIdentifier(object)).inserted {
                allObjects.append(object)
            }
            routeRecords.append([
                "source": source,
                "route": routeName,
                "rawCount": rawValues.count,
                "acceptedCount": objects.count,
                "distinctObjectCount": distinctObjects.count,
                "fullProtocolCount": rawValues.prefix(routeLimit).compactMap { $0 as? any NSAccessibilityProtocol }.count,
                "distinctFullProtocolCount": fullIDs.count,
                "narrowElementProtocolCount": rawValues.prefix(routeLimit).compactMap { $0 as? any NSAccessibilityElementProtocol }.count,
                "distinctNarrowElementProtocolCount": narrowIDs.count,
                "narrowOnlyCount": narrowOnlyIDs.count,
                "unsupportedNonFullProviderCount": unsupportedCount,
                "narrowOnlyFacts": narrowOnlyFacts,
                "objectCategories": bp38C04ObjectCategories(distinctObjects),
                "targetFacts": targetFacts,
                "truncated": routeTruncated
            ])
        }
        return ([
            "source": source,
            "providerCategory": bp38C04ObjectCategory(provider as AnyObject),
            "providerTargetFacts": providerFacts,
            "routes": routeRecords,
            "routeTruncated": anyRouteTruncated,
            "unsupportedNonFullProviderCount": totalIncompleteCount,
            "incomplete": anyRouteTruncated || totalIncompleteCount > 0
        ], allObjects, hasObjects)
    }

    private func bp38C04DiagnosticFacts(for element: any NSAccessibilityProtocol,
                                        targetLabel: String) -> [String: Any]? {
        guard element.accessibilityLabel() == targetLabel else { return nil }
        return [
            "label": bp38C04AllowlistedDiagnosticText(element.accessibilityLabel()),
            "help": bp38C04AllowlistedDiagnosticText(element.accessibilityHelp()),
            "role": bp38C04AllowlistedDiagnosticRole(element.accessibilityRole()),
            "hasFrame": !element.accessibilityFrame().isEmpty
        ]
    }

    private func bp38C04BoundedContentRoutes(from root: any NSAccessibilityProtocol, source: String,
                                              targetLabel: String) -> [String: Any] {
        let nodeLimit = 24
        let depthLimit = 4
        let childLimit = 24
        let routeLimit = 32
        let timeLimit: TimeInterval = 0.12
        let start = ProcessInfo.processInfo.systemUptime
        let rootObject = root as AnyObject
        var queue: [(object: AnyObject, depth: Int)] = [(rootObject, 0)]
        var queuedIDs: Set<ObjectIdentifier> = [ObjectIdentifier(rootObject)]
        var visitedIDs = Set<ObjectIdentifier>()
        var duplicateCount = 0
        var unsupportedCount = 0
        var summarizedFullProviders = 0
        var truncated = false
        var nodes: [[String: Any]] = []

        while !queue.isEmpty {
            if ProcessInfo.processInfo.systemUptime - start > timeLimit || visitedIDs.count >= nodeLimit {
                truncated = true
                break
            }
            let next = queue.removeFirst()
            let id = ObjectIdentifier(next.object)
            queuedIDs.remove(id)
            guard visitedIDs.insert(id).inserted else {
                duplicateCount += 1
                continue
            }
            if next.depth > depthLimit {
                truncated = true
                continue
            }
            guard let provider = next.object as? any NSAccessibilityProtocol else {
                unsupportedCount += 1
                continue
            }

            summarizedFullProviders += 1
            let sample = bp38C04RouteSummary(for: provider,
                source: "\(source).depth-\(next.depth)", targetLabel: targetLabel)
            let routeRecords = sample.summary["routes"] as? [[String: Any]] ?? []
            nodes.append([
                "depth": next.depth,
                "objectCategory": bp38C04ObjectCategory(next.object),
                "providerTargetFacts": sample.summary["providerTargetFacts"] ?? [],
                "routes": routeRecords,
                "targetFound": !(sample.summary["providerTargetFacts"] as? [[String: Any]] ?? []).isEmpty
                    || !routeRecords.flatMap { $0["targetFacts"] as? [[String: Any]] ?? [] }.isEmpty
            ])

            if sample.summary["incomplete"] as? Bool == true { truncated = true }
            let uniqueChildren = sample.objects
            if next.depth == depthLimit {
                if !uniqueChildren.isEmpty { truncated = true }
                continue
            }
            let cappedChildren = Array(uniqueChildren.prefix(childLimit))
            if uniqueChildren.count > childLimit { truncated = true }
            for child in cappedChildren {
                let childID = ObjectIdentifier(child)
                if visitedIDs.contains(childID) || queuedIDs.contains(childID) {
                    duplicateCount += 1
                    continue
                }
                if queue.count + visitedIDs.count >= nodeLimit {
                    truncated = true
                    break
                }
                queue.append((child, next.depth + 1))
                queuedIDs.insert(childID)
            }
            if ProcessInfo.processInfo.systemUptime - start > timeLimit {
                truncated = true
                break
            }
        }
        return [
            "source": source,
            "uniqueVisitedObjectCount": visitedIDs.count,
            "summarizedFullProviderCount": summarizedFullProviders,
            "unsupportedNonFullProviderCount": unsupportedCount,
            "duplicateReferences": duplicateCount,
            "pendingCount": queue.count,
            "visitedLimit": nodeLimit,
            "depthLimit": depthLimit,
            "childLimit": childLimit,
            "routeLimit": routeLimit,
            "elapsedWithinLimit": ProcessInfo.processInfo.systemUptime - start <= timeLimit,
            "truncatedOrIncomplete": truncated,
            "nodes": nodes
        ]
    }

    private func bp38C04ObjectCategory(_ object: AnyObject) -> String {
        if object is NSWindow { return "window" }
        if object is NSView { return "view" }
        if object is NSObject { return "object" }
        return "opaque"
    }

    private func bp38C04ObjectCategories(_ objects: [AnyObject]) -> [String: Int] {
        var result: [String: Int] = [:]
        for object in objects {
            let category = bp38C04ObjectCategory(object)
            result[category, default: 0] += 1
        }
        return result
    }

    private func bp38C04DiagnosticRole(_ role: NSAccessibility.Role?) -> String {
        if role == .button { return "button" }
        if role == .group { return "group" }
        if role == .staticText { return "staticText" }
        if role == nil { return "-" }
        return "other"
    }

    private func bp38C04AllowlistedDiagnosticRole(_ role: NSAccessibility.Role?) -> String {
        bp38C04DiagnosticRole(role)
    }

    private func bp38C04AllowlistedDiagnosticText(_ value: String?) -> String {
        guard let value else { return "-" }
        let allowed = ["偏好设置", "退出", "退出 TokenStatMenu", "返回概览", "C04 probe button", "C04 probe help"]
        return allowed.contains(value) ? value : "<other-synthetic-text>"
    }

    private func bp38C04FocusedDescendant(in root: NSView) -> (any NSAccessibilityProtocol)? {
        bp38C04Elements(in: root).first { $0.isAccessibilityFocused() }
    }

    private func bp38C04TextAttribute(_ element: any NSAccessibilityProtocol, _ selector: Selector) -> String? {
        if selector == #selector(NSAccessibilityProtocol.accessibilityLabel) { return element.accessibilityLabel() }
        if selector == #selector(NSAccessibilityProtocol.accessibilityHelp) { return element.accessibilityHelp() }
        return nil
    }

    private func bp38C04Frame(_ element: any NSAccessibilityProtocol) -> NSRect? {
        let frame = element.accessibilityFrame()
        return frame.isEmpty ? nil : frame
    }

    private func bp38C04VisibleText(in root: NSView) -> [String] {
        bp38C04Elements(in: root).flatMap { element in
            [element.accessibilityLabel(), element.accessibilityValue() as? String].compactMap { $0 }
        }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func bp38C04VisibleText(inQuotaRow label: String, root: NSView, window: NSWindow) throws -> [String] {
        guard let rowElement = bp38C04Element(label: label, in: root), let screenFrame = bp38C04Frame(rowElement) else {
            XCTFail("Quota row \(label) needs runtime accessibility geometry for row-scoped text assertions")
            throw NSError(domain: "A38-04", code: 37)
        }
        let rowFrame = bp38C04HostRect(screenFrame, window: window, host: root)
        let verticalBand = rowFrame.insetBy(dx: 0, dy: -12)
        return bp38C04Elements(in: root).compactMap { element in
            guard let elementScreenFrame = bp38C04Frame(element) else { return nil }
            let elementFrame = bp38C04HostRect(elementScreenFrame, window: window, host: root)
            // Keep text from the same compact rendered row while excluding broad card/group labels.
            guard elementFrame.height <= 40, verticalBand.intersects(elementFrame) else { return nil }
            return [element.accessibilityLabel(), element.accessibilityValue() as? String]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }.filter { !$0.isEmpty }
    }

    private func bp38C04HostRect(_ screenFrame: NSRect, window: NSWindow, host: NSView) -> NSRect {
        let windowOrigin = window.convertPoint(fromScreen: screenFrame.origin)
        let hostOrigin = host.convert(windowOrigin, from: nil)
        let windowOpposite = window.convertPoint(fromScreen: NSPoint(x: screenFrame.maxX, y: screenFrame.maxY))
        let hostOpposite = host.convert(windowOpposite, from: nil)
        let rect = NSRect(x: min(hostOrigin.x, hostOpposite.x), y: min(hostOrigin.y, hostOpposite.y),
            width: abs(hostOpposite.x - hostOrigin.x), height: abs(hostOpposite.y - hostOrigin.y))
        if host.isFlipped { return NSRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height) }
        return rect
    }

    private func bp38C04SendTab(_ window: NSWindow, backwards: Bool) {
        let flags: NSEvent.ModifierFlags = backwards ? [.shift] : []
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48) else { return }
        window.sendEvent(event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    }

    private func bp38C04SendSpace(_ window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) else { continue }
            window.sendEvent(event)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    }

    private func bp38C04Click(_ screenFrame: NSRect, in window: NSWindow) throws {
        let screenPoint = NSPoint(x: screenFrame.midX, y: screenFrame.midY)
        let point = window.convertPoint(fromScreen: screenPoint)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw XCTSkip("BLOCKED C38-04: cannot create an owned-window mouse event")
            }
            window.sendEvent(event)
        }
    }

    private func bp38C04NormalizedImage(from host: NSView, bounds: NSRect) throws -> NSImage {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw XCTSkip("BLOCKED C38-04: owned NSHostingView cannot produce a native render")
        }
        host.cacheDisplay(in: bounds, to: bitmap)
        let raw = NSImage(size: bounds.size)
        raw.addRepresentation(bitmap)
        let normalized = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let normalized else { throw XCTSkip("BLOCKED C38-04: cannot normalize native pixels") }
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: normalized)!
        NSGraphicsContext.current = context
        raw.draw(in: NSRect(origin: .zero, size: bounds.size), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: bounds.size)
        image.addRepresentation(normalized)
        return image
    }

    private func bp38C04PNG(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func bp38C04RecognizedText(in image: NSImage) throws -> [String] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw XCTSkip("BLOCKED C38-04: normalized render has no CGImage for local OCR")
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    }

    private func bp38C04QuotaBarRect(label: String, in host: NSView, window: NSWindow,
                                     image: NSImage, expectedColor: BP38C04BarColor) throws -> NSRect {
        guard let rect = try bp38C04FindQuotaBarRect(label: label, in: host, window: window,
            image: image, expectedColor: expectedColor) else {
            XCTFail("No rendered \(expectedColor.rawValue) progress pixels were found within semantic quota row \(label)")
            throw NSError(domain: "A38-04", code: 31)
        }
        return rect
    }

    private func bp38C04FindQuotaBarRect(label: String, in host: NSView, window: NSWindow,
                                          image: NSImage, expectedColor: BP38C04BarColor?) throws -> NSRect? {
        guard let element = bp38C04Element(label: label, in: host) else { return nil }
        guard let screenFrame = bp38C04Frame(element) else {
            XCTFail("Quota row \(label) needs runtime geometry")
            throw NSError(domain: "A38-04", code: 29)
        }
        let rowFrame = bp38C04HostRect(screenFrame, window: window, host: host)
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) else {
            XCTFail("Actual normalized render could not be inspected for quota row \(label)")
            throw NSError(domain: "A38-04", code: 30)
        }
        let yMinimum = max(0, Int(floor(rowFrame.minY - 20)))
        let yMaximum = min(bitmap.pixelsHigh, Int(ceil(rowFrame.maxY + 28)))
        let xMinimum = max(0, Int(floor(rowFrame.minX - 8)))
        let xMaximum = min(bitmap.pixelsWide, Int(ceil(rowFrame.maxX + 390)))
        var best = NSRect.zero
        var bestCount = 0
        guard yMaximum > yMinimum, xMaximum > xMinimum else {
            XCTFail("Quota row geometry for \(label) is outside the actual render")
            throw NSError(domain: "A38-04", code: 32)
        }
        let palettes = expectedColor.map { [$0] } ?? BP38C04BarColor.allCases
        for y in yMinimum..<yMaximum {
            var start: Int?
            for x in xMinimum..<xMaximum {
                let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                let matchesPalette = color.map { actual in
                    palettes.contains { bp38C04ColorMatches(actual, palette: $0, appearance: window.effectiveAppearance) }
                } ?? false
                if matchesPalette && start == nil { start = x }
                if (!matchesPalette || x == xMaximum - 1), let first = start {
                    let end = matchesPalette ? x + 1 : x
                    if end - first > bestCount {
                        bestCount = end - first
                        best = NSRect(x: first, y: y, width: end - first, height: 1)
                    }
                    start = nil
                }
            }
        }
        guard bestCount > 50 else { return nil }
        return best.insetBy(dx: 0, dy: -2)
    }

    private func bp38C04ColorMatches(_ actual: NSColor, palette: BP38C04BarColor,
                                     appearance: NSAppearance) -> Bool {
        let target: NSColor?
        switch palette {
        case .normalBlue:
            target = NSColor(calibratedRed: 0.24, green: 0.43, blue: 0.96, alpha: 1)
        case .warningYellow:
            target = bp38C04ResolvedSystemColor(NSColor.systemYellow, appearance: appearance)
        case .criticalRed:
            target = bp38C04ResolvedSystemColor(NSColor.systemRed, appearance: appearance)
        }
        guard let target, let rgb = target.usingColorSpace(.deviceRGB) else { return false }
        return actual.alphaComponent > 0.8 &&
            abs(actual.redComponent - rgb.redComponent) < 0.13 &&
            abs(actual.greenComponent - rgb.greenComponent) < 0.13 &&
            abs(actual.blueComponent - rgb.blueComponent) < 0.13
    }

    private func bp38C04ResolvedSystemColor(_ color: NSColor, appearance: NSAppearance) -> NSColor? {
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB)
        }
        return resolved
    }

    private func bp38C04AddGreenFocusEdge(to image: NSImage, focusTarget: NSRect) throws -> NSImage {
        guard let copy = image.copy() as? NSImage else { throw XCTSkip("BLOCKED C38-04: cannot copy candidate render") }
        copy.lockFocus()
        NSColor.systemGreen.setStroke()
        let edge = NSBezierPath(roundedRect: focusTarget.insetBy(dx: -2, dy: -2), xRadius: 4, yRadius: 4)
        edge.lineWidth = 4
        edge.stroke()
        copy.unlockFocus()
        return copy
    }

    private func bp38C04RecolorQuotaBar(to image: NSImage, barTarget: NSRect) throws -> NSImage {
        guard let copy = image.copy() as? NSImage else { throw XCTSkip("BLOCKED C38-04: cannot copy candidate render") }
        copy.lockFocus()
        NSColor.systemRed.setFill()
        NSBezierPath(rect: barTarget).fill()
        copy.unlockFocus()
        return copy
    }

    private func bp38C04RecordMutation(_ image: NSImage, baseline: NSImage, name: String, appearance: String,
                                        derivedFrom: String, mutation: String, target: NSRect,
                                        candidateDirectory: URL) throws -> BP38C04RenderedCase {
        XCTAssertNotNil(Snapshotting<NSImage, NSImage>.image.diffing.diffV2(baseline, image),
            "negative control \(mutation) must independently differ from \(derivedFrom)")
        guard let png = bp38C04PNG(image) else { throw NSError(domain: "A38-04", code: 32) }
        try png.write(to: candidateDirectory.appendingPathComponent("\(name).png"), options: .atomic)
        return BP38C04RenderedCase(name: name, appearance: appearance, width: 460, height: 700,
            sha256: bp38C04SHA256(png), visibleText: [], ocrText: [], alertLevel: "negative-control",
            barStates: [], pixelTargets: [bp38C04RectString(target), "derivedFrom:\(derivedFrom)"],
            kind: "negative-control", mutation: mutation)
    }

    private func bp38C04RectString(_ rect: NSRect) -> String {
        "x=\(Int(rect.minX)) y=\(Int(rect.minY)) w=\(Int(rect.width)) h=\(Int(rect.height))"
    }

    private func bp38C04AlertLevel(_ color: NSColor) -> String {
        if color == .systemRed { return "critical" }
        if color == .systemYellow { return "warning" }
        return "none"
    }
}
#endif
