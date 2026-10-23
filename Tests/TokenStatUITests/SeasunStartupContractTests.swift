import AppKit
import SwiftUI
import XCTest
import TokenStatCore
import Vision
@testable import TokenStatMenu

/// BP10b executable checks for the formal app boundary. These intentionally
/// target the planned initializer/configuration API; do not weaken the tests
/// to match the current legacy proxy activation path. Run only after G4 and
/// PE approval, and after the product implementation provides this interface.
@MainActor
final class SeasunStartupContractTests: XCTestCase {
    private struct IsolatedConfig {
        let directory: URL
        let file: URL
        let calls = StartupCallCounts()

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("TokenStatMenu-BP10-\(UUID().uuidString)", isDirectory: true)
            file = directory.appendingPathComponent("config.plist")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func write(_ value: Any) throws -> Data {
            let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
            try data.write(to: file, options: .atomic)
            return data
        }

        func tearDown() { try? FileManager.default.removeItem(at: directory) }
    }

    private final class StartupCallCounts {
        private let lock = NSLock()
        private var loads = 0
        private var saves = 0
        private var gates = 0
        func noteLoad() { lock.lock(); loads += 1; lock.unlock() }
        func noteSave() { lock.lock(); saves += 1; lock.unlock() }
        func noteGate() { lock.lock(); gates += 1; lock.unlock() }
        func snapshot() -> (loads: Int, saves: Int, gates: Int) {
            lock.lock(); defer { lock.unlock() }; return (loads, saves, gates)
        }
    }

    private func makeModel(_ isolated: IsolatedConfig) -> AppModel {
        AppModel(preview: false, startup: startup(for: isolated))
    }

    private func startup(for isolated: IsolatedConfig, shouldStartBackgroundServices: Bool = false)
        -> AppModelStartupDependencies {
        startup(for: isolated, shouldStartBackgroundServices: shouldStartBackgroundServices,
                loadOverride: nil, saveOverride: nil)
    }

    private func startup(for isolated: IsolatedConfig, shouldStartBackgroundServices: Bool,
                         loadOverride: (() throws -> Data?)?,
                         saveOverride: ((SeasunPreferences) throws -> Void)?) -> AppModelStartupDependencies {
        AppModelStartupDependencies(
            loadPreferences: {
                isolated.calls.noteLoad()
                if let loadOverride { return try loadOverride() }
                return try ConfigStore.loadPreferences(at: isolated.file)
            },
            savePreferences: { preferences in
                isolated.calls.noteSave()
                if let saveOverride { try saveOverride(preferences) }
                else { try ConfigStore.savePreferences(preferences, at: isolated.file) }
            },
            shouldStartBackgroundServices: {
                isolated.calls.noteGate()
                return shouldStartBackgroundServices
            })
    }

    private func assertQuietSafeStartup(_ model: AppModel, file: URL, source: StaticString = #filePath,
                                        line: UInt = #line) {
        XCTAssertTrue(model.isSeasunOnly, "legacy data source must not select an active integration", file: source, line: line)
        assertNoBackgroundResources(model, file: source, line: line)
        XCTAssertNil(model.tokenHubQuotaSnapshot, "startup cannot fabricate an observed quota", file: source, line: line)
        XCTAssertFalse(model.hasRequestData, "startup cannot imply observed usage", file: source, line: line)
        XCTAssertFalse(model.userFacingStatus.contains(file.path), "status must not reveal a config path", file: source, line: line)
        XCTAssertFalse(model.userFacingStatus.contains("https://legacy.invalid"), "status must not expose an old endpoint", file: source, line: line)
    }

    private func assertNoBackgroundResources(_ model: AppModel, file: StaticString = #filePath, line: UInt = #line) {
        let resources = model.backgroundServiceResources
        XCTAssertEqual(resources.timerCount, 0, "disabled startup must own no repeating timer", file: file, line: line)
        XCTAssertEqual(resources.workspaceObserverCount, 0, "disabled startup must install no workspace observers", file: file, line: line)
        XCTAssertEqual(resources.localScanQueuedCount, 0, "disabled startup must queue no local scan", file: file, line: line)
        XCTAssertEqual(resources.axRefreshScheduledCount, 0, "disabled startup must schedule no AX refresh", file: file, line: line)
        XCTAssertEqual(resources.axScanInFlightCount, 0, "disabled startup must start no AX scan", file: file, line: line)
    }

    func testInitAndReloadKeepLegacyFilesUntouchedAndSelectSeasunSafeDefault() throws {
        let cases: [(String, Data?)] = [
            ("absent", nil),
            ("legacy proxy with arbitrary endpoint", try PropertyListSerialization.data(fromPropertyList: [
                "dataSource": "proxy", "endpoint": "https://legacy.invalid/v1/chat/completions",
                "usageURL": "https://quota.invalid/api", "model": "old-model", "port": 18765,
                "monthlyLimit": 900_000, "inputPrice": 1.25
            ], format: .xml, options: 0)),
            ("invalid legacy endpoint", try PropertyListSerialization.data(fromPropertyList: [
                "dataSource": "proxy", "endpoint": "file:///private/legacy",
                "usageURL": "https://quota.invalid/api"
            ], format: .xml, options: 0)),
            ("malformed plist", Data("not a plist".utf8)),
            ("non-dictionary root", try PropertyListSerialization.data(fromPropertyList: ["legacy", "array"], format: .xml, options: 0))
        ]

        for (name, bytes) in cases {
            let isolated = try IsolatedConfig()
            defer { isolated.tearDown() }
            if let bytes { try bytes.write(to: isolated.file, options: .atomic) }
            let before = try? Data(contentsOf: isolated.file)

            let model = makeModel(isolated)
            defer { model.shutdown() }
            assertQuietSafeStartup(model, file: isolated.file)
            let afterInit = isolated.calls.snapshot()
            XCTAssertEqual(afterInit.loads, 1, "init reads only the isolated preference file: \(name)")
            XCTAssertEqual(afterInit.saves, 0, "init never writes preferences: \(name)")
            XCTAssertGreaterThan(afterInit.gates, 0, "init consults the unified background gate: \(name)")
            XCTAssertEqual(try? Data(contentsOf: isolated.file), before,
                           "init must not migrate, normalize, or rewrite case: \(name)")

            model.reload()
            assertQuietSafeStartup(model, file: isolated.file)
            let afterReload = isolated.calls.snapshot()
            XCTAssertEqual(afterReload.loads, 2, "reload reads once from the isolated preference path: \(name)")
            XCTAssertEqual(afterReload.saves, 0, "reload never writes preferences: \(name)")
            XCTAssertGreaterThan(afterReload.gates, afterInit.gates,
                                 "reload reuses the unified background gate: \(name)")
            XCTAssertEqual(try? Data(contentsOf: isolated.file), before,
                           "reload must not migrate, normalize, or rewrite case: \(name)")
        }
    }

    func testPreferenceDefaultsValidationAndCompatibilityKeyPrecedence() throws {
        let fixtures: [(String, [String: Any], Double, Bool)] = [
            ("no preferences", [:], 60, true),
            ("valid minimum and new true overrides old false", [
                "refreshSeconds": 15.0, "tokenHubCompatibilityReadEnabled": true,
                "tokenHubAutomaticReadingEnabled": false
            ], 15, true),
            ("valid maximum and new false overrides old true", [
                "refreshSeconds": 3600.0, "tokenHubCompatibilityReadEnabled": false,
                "tokenHubAutomaticReadingEnabled": true
            ], 3600, false),
            ("legacy key used only when new key is absent", [
                "tokenHubAutomaticReadingEnabled": false
            ], 60, false),
            ("invalid current key defaults true without legacy fallback", [
                "tokenHubCompatibilityReadEnabled": "invalid", "tokenHubAutomaticReadingEnabled": false
            ], 60, true),
            ("numeric current key defaults true without legacy fallback", [
                "tokenHubCompatibilityReadEnabled": NSNumber(value: 0), "tokenHubAutomaticReadingEnabled": false
            ], 60, true),
            ("out of range refresh defaults to 60", ["refreshSeconds": 3601.0], 60, true),
            ("below range refresh defaults to 60", ["refreshSeconds": 14.9], 60, true),
            ("wrong-type refresh defaults to 60", ["refreshSeconds": "15"], 60, true),
            ("boolean refresh defaults to 60", ["refreshSeconds": true], 60, true)
        ]

        for (name, plist, expectedRefresh, expectedCompatibility) in fixtures {
            let isolated = try IsolatedConfig()
            defer { isolated.tearDown() }
            let original = try isolated.write(plist)
            let model = makeModel(isolated)
            defer { model.shutdown() }
            XCTAssertEqual(model.preferences.refreshSeconds, expectedRefresh, name)
            XCTAssertEqual(model.preferences.tokenHubCompatibilityReadEnabled, expectedCompatibility, name)
            XCTAssertEqual(try? Data(contentsOf: isolated.file), original,
                           "preference decoding at startup is read-only: \(name)")
            XCTAssertFalse(model.permissionPromptRequested,
                           "default-enabled AX compatibility must not prompt automatically: \(name)")
            XCTAssertEqual(isolated.calls.snapshot().saves, 0, "decoding must never persist normalized values: \(name)")
            assertNoBackgroundResources(model)
        }
    }

    func testPreferenceSaveNormalizesNonFiniteAndOutOfRangeRefreshValues() throws {
        let isolated = try IsolatedConfig()
        defer { isolated.tearDown() }
        let model = makeModel(isolated)
        defer { model.shutdown() }
        for invalid in [Double.nan, Double.infinity, -Double.infinity, 14.9, 3601] {
            XCTAssertTrue(model.savePreferences(SeasunPreferences(refreshSeconds: invalid,
                tokenHubCompatibilityReadEnabled: true)))
            model.reload()
            XCTAssertEqual(model.preferences.refreshSeconds, 60,
                           "non-finite or out-of-range refresh interval must normalize to 60")
        }
    }

    func testPreviewReturnsBeforeCallingPreferenceLoader() throws {
        let isolated = try IsolatedConfig()
        defer { isolated.tearDown() }
        let startup = AppModelStartupDependencies(
            loadPreferences: {
                isolated.calls.noteLoad()
                throw NSError(domain: "BP10PreviewMustNotLoad", code: 1)
            },
            savePreferences: { _ in isolated.calls.noteSave() },
            shouldStartBackgroundServices: {
                isolated.calls.noteGate()
                return true
            })
        let model = AppModel(preview: true, startup: startup)
        defer { model.shutdown() }
        let calls = isolated.calls.snapshot()
        XCTAssertEqual(calls.loads, 0, "preview must return before calling the preference loader")
        XCTAssertEqual(calls.saves, 0)
        XCTAssertEqual(calls.gates, 0, "preview returns before consulting the service gate")
        assertNoBackgroundResources(model)
    }

    func testExplicitSaveWritesOnlyAllowlistedPreferencesAndReloadsThem() throws {
        let isolated = try IsolatedConfig()
        defer { isolated.tearDown() }
        _ = try isolated.write([
            "dataSource": "proxy", "endpoint": "https://legacy.invalid/v1/chat/completions",
            "usageURL": "https://quota.invalid/api", "apiKey": "never persist or read",
            "model": "old-model", "monthlyLimit": 900_000,
            "tokenHubAutomaticReadingEnabled": false
        ])
        let model = makeModel(isolated)
        defer { model.shutdown() }

        let gateCountBeforeSave = isolated.calls.snapshot().gates
        XCTAssertTrue(model.savePreferences(SeasunPreferences(refreshSeconds: 120,
            tokenHubCompatibilityReadEnabled: false)))
        assertNoBackgroundResources(model)
        let afterSave = isolated.calls.snapshot()
        XCTAssertEqual(afterSave.saves, 1)
        XCTAssertGreaterThan(afterSave.gates, gateCountBeforeSave,
                             "save must consult the same background gate as init/reload")
        let saved = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: isolated.file), format: nil) as? [String: Any])
        XCTAssertEqual(Set(saved.keys), Set(["refreshSeconds", "tokenHubCompatibilityReadEnabled"]))
        XCTAssertEqual(saved["refreshSeconds"] as? Double, 120)
        XCTAssertEqual(saved["tokenHubCompatibilityReadEnabled"] as? Bool, false)
        model.reload()
        XCTAssertTrue(model.isSeasunOnly, "reload of the reduced schema remains Seasun-only")
        assertNoBackgroundResources(model)
        XCTAssertGreaterThan(isolated.calls.snapshot().gates, afterSave.gates,
                             "reload must consult the unified background gate")
        XCTAssertEqual(model.preferences.refreshSeconds, 120)
        XCTAssertFalse(model.preferences.tokenHubCompatibilityReadEnabled)
        XCTAssertEqual(isolated.calls.snapshot().saves, 1, "reload must not save")
    }

    func testFailedExplicitSavePreservesMemoryAndDoesNotExposeFilesystemDetails() throws {
        let isolated = try IsolatedConfig()
        defer { isolated.tearDown() }
        _ = try isolated.write(["refreshSeconds": 90.0, "tokenHubCompatibilityReadEnabled": true])
        let model = makeModel(isolated)
        defer { model.shutdown() }
        let originalStatus = model.userFacingStatus
        let originalRefresh = model.preferences.refreshSeconds
        let originalCompatibility = model.preferences.tokenHubCompatibilityReadEnabled

        try FileManager.default.removeItem(at: isolated.file)
        try FileManager.default.createDirectory(at: isolated.file, withIntermediateDirectories: false)
        XCTAssertFalse(model.savePreferences(SeasunPreferences(refreshSeconds: 300,
            tokenHubCompatibilityReadEnabled: false)))
        XCTAssertEqual(model.preferences.refreshSeconds, originalRefresh)
        XCTAssertEqual(model.preferences.tokenHubCompatibilityReadEnabled, originalCompatibility)
        XCTAssertEqual(model.userFacingStatus, originalStatus,
                       "failed save leaves active runtime state unchanged")
        assertNoBackgroundResources(model)
        XCTAssertFalse(model.message.contains(isolated.directory.path), "raw path must not be exposed")
        XCTAssertFalse(model.message.localizedCaseInsensitiveContains("no such file"),
                       "raw filesystem errors must not be exposed")
    }

    func testReloadLoaderFailurePreservesPreferencesAndShowsSafeStatus() throws {
        let isolated = try IsolatedConfig()
        defer { isolated.tearDown() }
        let original = try isolated.write(["refreshSeconds": 90.0, "tokenHubCompatibilityReadEnabled": false])
        var attempts = 0
        let startup = startup(for: isolated, shouldStartBackgroundServices: false, loadOverride: {
            attempts += 1
            if attempts > 1 {
                throw NSError(domain: "BP10ReloadFixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "secret raw path \(isolated.file.path)"])
            }
            return try ConfigStore.loadPreferences(at: isolated.file)
        }, saveOverride: nil)
        let model = AppModel(preview: false, startup: startup)
        defer { model.shutdown() }
        let initialStatus = model.userFacingStatus
        XCTAssertEqual(model.preferences.refreshSeconds, 90)
        XCTAssertFalse(model.preferences.tokenHubCompatibilityReadEnabled)

        model.reload()
        XCTAssertEqual(model.preferences.refreshSeconds, 90)
        XCTAssertFalse(model.preferences.tokenHubCompatibilityReadEnabled)
        XCTAssertEqual(model.userFacingStatus, initialStatus,
                       "failed reload keeps the last accepted runtime settings")
        XCTAssertFalse(model.message.contains(isolated.file.path))
        XCTAssertFalse(model.message.contains("secret raw path"))
        XCTAssertEqual(isolated.calls.snapshot().loads, 2)
        XCTAssertEqual(isolated.calls.snapshot().saves, 0)
        XCTAssertEqual(try Data(contentsOf: isolated.file), original)
        assertNoBackgroundResources(model)
    }

    func testDeterministicPreferenceSaveFailurePreservesTheOldFileAndRuntimeState() throws {
        let isolated = try IsolatedConfig()
        defer { isolated.tearDown() }
        let original = try isolated.write(["refreshSeconds": 90.0, "tokenHubCompatibilityReadEnabled": true])
        let startup = startup(for: isolated, shouldStartBackgroundServices: false, loadOverride: nil,
                              saveOverride: { _ in
            throw NSError(domain: "BP10SaveFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "secret raw path \(isolated.file.path)"])
        })
        let model = AppModel(preview: false, startup: startup)
        defer { model.shutdown() }
        let status = model.userFacingStatus

        XCTAssertFalse(model.savePreferences(SeasunPreferences(refreshSeconds: 300,
            tokenHubCompatibilityReadEnabled: false)))
        XCTAssertEqual(model.preferences.refreshSeconds, 90)
        XCTAssertTrue(model.preferences.tokenHubCompatibilityReadEnabled)
        XCTAssertEqual(model.userFacingStatus, status)
        XCTAssertFalse(model.message.contains(isolated.file.path))
        XCTAssertFalse(model.message.contains("secret raw path"))
        XCTAssertEqual(try Data(contentsOf: isolated.file), original,
                       "a deterministic save closure failure cannot delete or alter the old fixture")
        XCTAssertEqual(isolated.calls.snapshot().saves, 1)
        assertNoBackgroundResources(model)
    }

    func testFormalStartupTooltipPreservesSyntheticLocalHistoryAlongsideUnknownSeasunSource() throws {
        let isolated = try IsolatedConfig()
        defer { isolated.tearDown() }
        let model = makeModel(isolated)
        defer { model.shutdown() }
        XCTAssertFalse(model.sourceStatus.isEmpty)
        XCTAssertEqual(model.sourceStatus, "unknown")

        let cases: [(String, LocalCodexSnapshot, [String])] = [
            ("complete", LocalCodexSnapshot(input: 120, output: 80, total: 200,
                sessionCount: 2, filesScanned: 3, isLimited: false,
                latestEventAt: Date(timeIntervalSince1970: 1_797_000_000), fiveHour: nil, sevenDay: nil,
                knownThreadCount: 2, unknownThreadCount: 0, unidentifiedFileCount: 0,
                subagentCount: 1, forkCount: 1,
                lastTurn: LocalTurnSummary(outputTokens: 75, durationSeconds: 5,
                    completedAt: Date(timeIntervalSince1970: 1_797_000_000))),
             ["输入 120", "输出 80", "总计 200 tokens", "本次扫描记录量 200 tokens",
              "线程 2", "子代理 1", "分叉 1", "顶层对话 2", "上轮记录均速：15.0 tok/s",
              "5 小时额度：本地", "7 天额度：本地"]),
            ("partial", LocalCodexSnapshot(input: 30, output: 20, total: 50,
                sessionCount: 1, filesScanned: 4, isLimited: false,
                latestEventAt: nil, fiveHour: nil, sevenDay: nil,
                knownThreadCount: 1, unknownThreadCount: 2, unidentifiedFileCount: 1,
                subagentCount: 1, forkCount: 2),
             ["输入 30", "输出 20", "总计 50 tokens", "本次记录合计 50 tokens",
              "线程 1", "其他线程 2", "未识别文件 1", "子代理 1", "分叉 2", "最多32个物理文件"]),
            ("unknown", LocalCodexSnapshot(input: 0, output: 0, total: 0,
                sessionCount: 0, filesScanned: 2, isLimited: false,
                latestEventAt: nil, fiveHour: nil, sevenDay: nil,
                knownThreadCount: 0, unknownThreadCount: 2, unidentifiedFileCount: 0,
                subagentCount: 0, forkCount: 0),
             ["输入 未知", "输出 未知", "总计 未知 tokens", "本次记录合计 未知 tokens",
              "其他线程 2", "上轮记录均速：未知"])
        ]

        for (name, snapshot, expectedLocalDetails) in cases {
            model.localSnapshot = snapshot
            let tooltip = model.menuTooltip
            for detail in expectedLocalDetails {
                XCTAssertTrue(tooltip.contains(detail), "\(name) formal tooltip preserves local history detail: \(detail)")
            }
            XCTAssertTrue(tooltip.contains("不是模型瞬时生成速度"), "\(name) tooltip keeps the non-instantaneous speed qualification")
            XCTAssertTrue(tooltip.contains("Seasun Token Hub"), "\(name) tooltip identifies the enterprise direct source")
            let directLine = tooltip.split(separator: "\n").first { $0.contains("企业后台直接来源") }
            XCTAssertNotNil(directLine, "\(name) tooltip labels the enterprise direct source explicitly")
            XCTAssertTrue(directLine?.contains("尚未连接") == true || directLine?.contains("尚未接通") == true,
                          "\(name) tooltip keeps the enterprise direct source disconnected")
            XCTAssertTrue(directLine?.contains("额度、重置时间、月度用量和实时速度均未知") == true,
                          "\(name) tooltip scopes unknown quota and usage fields to the disconnected direct source")
        }
    }

    func testSettingsVisibleContentShowsSeasunPreferencesWithoutGenericIntegration() async throws {
        let isolated = try IsolatedConfig()
        defer { isolated.tearDown() }
        let model = makeModel(isolated)
        defer { model.shutdown() }
        let bounds = NSRect(x: 0, y: 0, width: 460, height: 700)
        let hostingView = NSHostingView(rootView: SettingsView(model: model)
            .environment(\.colorScheme, .light)
            .frame(width: 460, height: 700).background(Color.white))
        hostingView.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hostingView
        window.appearance = NSAppearance(named: .aqua)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.displayIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try settingsBitmap(bounds)
        hostingView.cacheDisplay(in: bounds, to: bitmap)
        let visibleText = try recognizedText(in: bitmap).joined(separator: "\n")
        XCTAssertTrue(visibleText.contains("Seasun Token Hub") || visibleText.contains("Token Hub"),
                       "the rendered Settings surface names the intended source; OCR: \(visibleText)")
        XCTAssertTrue(visibleText.contains("刷新"), "the rendered surface exposes an optional refresh preference; OCR: \(visibleText)")
        XCTAssertTrue(visibleText.contains("兼容"), "the rendered surface exposes the optional compatibility preference; OCR: \(visibleText)")
        for forbidden in ["上游完整 Endpoint", "API Key", "模型覆盖", "自定义价格", "企业额度接口", "手动月度 Token 上限"] {
            XCTAssertFalse(visibleText.contains(forbidden),
                           "the rendered Settings surface must not expose \(forbidden)")
        }
        XCTAssertFalse(visibleText.localizedCaseInsensitiveContains("填入企业") || visibleText.contains("连接成功"),
                       "Settings must not imply that a generic endpoint or credential connects the Seasun source")
    }

    func testSettingsSourceStatusFollowsFreshDirectObservationAndFailure() async throws {
        let now = Date(timeIntervalSince1970: 1_797_000_000)
        let identity = TokenHubIdentity(pid: 944, bundleID: TokenHubTarget.bundleID,
            executablePath: "/Applications/Synthetic Settings Hub.app/Contents/MacOS/Hub")
        let snapshot = TokenHubQuotaSnapshot(identity: identity,
            fiveHour: TokenHubWindowQuota(kind: .fiveHour, usedAmount: 25, limitAmount: 100,
                sourceSymbol: "$", usedPercent: 25, resetDisplay: "合成重置时间"),
            sevenDay: nil, monthly: nil, observedAt: now)
        var failure: TokenHubDirectQuotaFailure?
        var clock = now
        let direct = TokenHubDirectQuotaDependencies(discoverTarget: { identity },
            identityIsCurrent: { $0 == identity }, fetch: { _, _ in
                if let failure { throw failure }
                return snapshot
            })
        let model = AppModel(preview: true, directQuota: direct)
        defer { model.shutdown() }
        model.config.dataSource = "localCodex"
        model.tokenHubAutomaticReadingEnabled = false
        model.tokenHubNow = { clock }
        let settings = SettingsView(model: model)

        XCTAssertTrue(settings.sourceStatusText.contains("尚未连接"),
                      "unobserved source cannot claim a connected enterprise backend")
        model.refreshTokenHubQuota()
        for _ in 0..<100 where !model.tokenHubQuotaIsDirect { await Task.yield() }
        XCTAssertTrue(model.tokenHubQuotaIsDirect, "synthetic direct observation must be accepted")
        XCTAssertTrue(settings.sourceStatusText.contains("已直接读取"),
                      "Settings must reflect the same direct observation as the dashboard")
        XCTAssertFalse(settings.sourceStatusText.contains("尚不可用"))
        XCTAssertFalse(model.tokenHubAutomaticReadingEnabled,
                       "optional AX compatibility is disabled throughout this direct-only check")

        clock = now.addingTimeInterval(121)
        XCTAssertTrue(settings.sourceStatusText.contains("过期"),
                      "Settings cannot describe an expired direct snapshot as connected")
        failure = .credentialExpired
        model.refreshTokenHubQuota()
        for _ in 0..<100 where model.tokenHubDirectFailure == nil { await Task.yield() }
        XCTAssertEqual(model.tokenHubDirectFailure, .credentialExpired)
        XCTAssertTrue(settings.sourceStatusText.contains("会话已过期"),
                      "Settings must preserve the actual sanitized direct failure")
        XCTAssertFalse(settings.sourceStatusText.contains("已直接读取"))
    }

    func testSettingsLightAndDarkRendersAreAvailableForIndependentVisualReview() async throws {
        let isolated = try IsolatedConfig()
        defer { isolated.tearDown() }
        let model = makeModel(isolated)
        defer { model.shutdown() }
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/bp10-settings-review", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bounds = NSRect(x: 0, y: 0, width: 460, height: 700)
        for (name, appearance, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light),
                                           ("dark", NSAppearance.Name.darkAqua, ColorScheme.dark)] {
            let background = scheme == .dark
                ? Color(red: 0.13, green: 0.14, blue: 0.17)
                : Color(red: 0.96, green: 0.97, blue: 0.99)
            let root = DashboardView(model: model, settings: true)
                .environment(\.colorScheme, scheme)
                .frame(width: 460, height: 700)
                .background(background)
            let hostingView = NSHostingView(rootView: root)
            hostingView.frame = bounds
            hostingView.appearance = NSAppearance(named: appearance)
            let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hostingView
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            hostingView.frame = bounds
            window.displayIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            window.displayIfNeeded()
            hostingView.needsDisplay = true
            hostingView.layoutSubtreeIfNeeded()
            let bitmap = try settingsBitmap(bounds)
            hostingView.cacheDisplay(in: bounds, to: bitmap)
            let renderedText = try recognizedText(in: bitmap).joined(separator: "\n")
            XCTAssertTrue(renderedText.contains("Seasun Token Hub") || renderedText.contains("Token Hub"),
                          "\(name) review render contains the intended source text")
            XCTAssertTrue(renderedText.contains("刷新"), "\(name) review render contains the refresh preference")
            XCTAssertTrue(renderedText.contains("兼容"), "\(name) review render contains the compatibility preference")
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 0)
            try png.write(to: output.appendingPathComponent("seasun-settings-\(name).png"), options: .atomic)
        }
        print("BP10 Seasun Settings light/dark visual review files: \(output.path)")
    }

    private func settingsBitmap(_ bounds: NSRect) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * 4), pixelsHigh: Int(bounds.height * 4),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = bounds.size
        return bitmap
    }

    private func recognizedText(in bitmap: NSBitmapImageRep) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage), options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}
