import AppKit
import SnapshotTesting
import SwiftUI
import XCTest
import TokenStatCore
@testable import TokenStatMenu

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

    func testLocalStatusTitleUsesCompletedTurnAndRecordedSessionTotal() throws {
        let model = AppModel(preview: true)
        defer { model.shutdown() }
        model.localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0,
            filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
            knownThreadCount: 0, unknownThreadCount: 0, unidentifiedFileCount: 0,
            subagentCount: 0, forkCount: 0)
        XCTAssertTrue(model.title.contains("上轮均:—"))
        model.localSnapshot = LocalCodexSnapshot(input: 125, output: 300, total: 425,
            sessionCount: 2, filesScanned: 2, isLimited: false,
            latestEventAt: Date(timeIntervalSince1970: 1_797_000_000), fiveHour: nil, sevenDay: nil,
            knownThreadCount: 2, unknownThreadCount: 0, unidentifiedFileCount: 0,
            subagentCount: 0, forkCount: 0,
            lastTurn: LocalTurnSummary(outputTokens: 75, durationSeconds: 5,
                completedAt: Date(timeIntervalSince1970: 1_797_000_000)))
        XCTAssertEqual(model.title, "上轮均:15.0tok/s · Σ425 · 2顶层对话")
        XCTAssertTrue(model.dataNotice.contains("当前扫描范围记录小计"))
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
        XCTAssertTrue(model.title.hasPrefix("上轮均:15.0tok/s · Σ"))
        XCTAssertFalse(model.title.contains("Σ" + fullTotal), "status title should compact large totals")
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
        XCTAssertTrue(model.title.contains("小计50"))
        XCTAssertTrue(model.title.contains("未核验3"))
        XCTAssertFalse(model.title.contains("Σ50"))
        XCTAssertTrue(model.menuTooltip.contains("输入 30"))
        XCTAssertTrue(model.menuTooltip.contains("输出 20"))
        XCTAssertTrue(model.menuTooltip.contains("总计 50"))
        XCTAssertTrue(model.menuTooltip.contains("未核验线程 2"))
        XCTAssertTrue(model.menuTooltip.contains("未识别文件 1"))
        XCTAssertFalse(model.menuTooltip.contains("本次扫描记录量 50"))

        model.localSnapshot = LocalCodexSnapshot(input: 8, output: 2, total: 10, sessionCount: 0,
            filesScanned: 1, isLimited: true, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
            knownThreadCount: 1, unknownThreadCount: 0, unidentifiedFileCount: 0,
            subagentCount: 0, forkCount: 0)
        XCTAssertFalse(model.localSnapshot.hasCompleteAccounting, "a scan limit prevents complete accounting")
        XCTAssertTrue(model.title.contains("小计10"))
        XCTAssertFalse(model.title.contains("Σ10"))

        model.localSnapshot = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0,
            filesScanned: 2, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
            knownThreadCount: 0, unknownThreadCount: 0, unidentifiedFileCount: 2,
            subagentCount: 0, forkCount: 0)
        XCTAssertTrue(model.title.contains("Σ—"), "without any known thread, zero is unknown rather than an exact total")

        model.localSnapshot = LocalCodexSnapshot(input: 30, output: 20, total: 50, sessionCount: 1,
            filesScanned: 1, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil,
            knownThreadCount: 1, unknownThreadCount: 0, unidentifiedFileCount: 0,
            subagentCount: 0, forkCount: 0)
        XCTAssertTrue(model.localSnapshot.hasCompleteAccounting)
        XCTAssertTrue(model.title.contains("Σ50"), "complete metadata-backed accounting may show exact total")
        XCTAssertTrue(model.menuTooltip.contains("本次扫描记录量 50"))
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
        XCTAssertTrue(local.menuTooltip.contains("99.0%"), "local tooltip retains the original percentage")
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
        XCTAssertTrue(enterprise.menuTooltip.contains("96.0%"), "proxy tooltip retains the original percentage")
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
        let root = DashboardView(model: model, settings: settings)
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
