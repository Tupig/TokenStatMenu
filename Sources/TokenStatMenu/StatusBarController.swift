import AppKit
import Combine
import SwiftUI

/// Native content factories keep expensive view construction at the UI
/// boundary; tests can wrap the real builders using synthetic models.
struct StatusBarContentFactories {
    let dashboard: @MainActor (AppModel) -> NSViewController
    let tooltip: @MainActor (AppModel) -> String
    let projectedTooltip: (@MainActor (AppModel, Date, TokenHubQuotaPresentation) -> String)?
    init(dashboard: @escaping @MainActor (AppModel) -> NSViewController,
         tooltip: @escaping @MainActor (AppModel) -> String,
         projectedTooltip: (@MainActor (AppModel, Date, TokenHubQuotaPresentation) -> String)? = nil) {
        self.dashboard = dashboard; self.tooltip = tooltip; self.projectedTooltip = projectedTooltip
    }
    static var production: StatusBarContentFactories {
        StatusBarContentFactories(dashboard: { NSHostingController(rootView: DashboardView(model: $0)) },
            tooltip: { $0.menuTooltip },
            projectedTooltip: { model, now, projection in
                model.menuTooltip(at: now, quotaPresentation: projection)
            })
    }
}

@MainActor final class StatusBarController: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let model: AppModel
    private let factories: StatusBarContentFactories
    private var tooltipNeedsRefresh = true
    private var lastTooltipTimeState: PresentationTimeState?
    private var presentationObservers = Set<AnyCancellable>()
    private var lastTitle = ""
    private var lastColor: NSColor?
    private var lastDiagnostic = Date.distantPast
    private let diagnosticsURL: URL?
    init(model: AppModel, factories: StatusBarContentFactories = .production,
         diagnosticsURL: URL? = StatusBarController.commandLineDiagnosticsURL()) {
        self.model = model
        self.factories = factories
        self.diagnosticsURL = diagnosticsURL
        // Keep a strong reference: a local NSStatusItem vanishes when deallocated.
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.autosaveName = "TokenStatMenu.Metrics"
        popover.behavior = .transient; popover.animates = false; popover.delegate = self
        popover.contentSize = NSSize(width: 460, height: 700)
        if let button = item.button {
            button.target = self; button.action = #selector(toggle)
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.setAccessibilityLabel("TokenStatMenu 实时 Token 速度")
        }
        // Published measurements/preferences invalidate the expensive tooltip;
        // the half-second timer separately checks cheap freshness boundaries.
        model.objectWillChange.sink { [weak self] in self?.tooltipNeedsRefresh = true }
            .store(in: &presentationObservers)
        NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.tooltipNeedsRefresh = true }
            .store(in: &presentationObservers)
        model.onTick = { [weak self] in self?.refreshTitle() }
        refreshTitle()
    }
    func refreshTitle() {
        let now = model.tokenHubNow()
        let projection = model.quotaPresentation(at: now)
        let title = model.title(at: now, quotaPresentation: projection)
        let color = model.alertColor(for: projection)
        if title != lastTitle || color != lastColor {
            lastTitle = title; lastColor = color
            item.button?.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: color
            ])
        }
        let timeState = model.presentationTimeState(at: now, quotaPresentation: projection)
        if tooltipNeedsRefresh || lastTooltipTimeState != timeState {
            item.button?.toolTip = factories.projectedTooltip?(model, now, projection) ?? factories.tooltip(model)
            tooltipNeedsRefresh = false
            lastTooltipTimeState = timeState
        }
        writeDiagnosticsIfRequested(at: now, projection: projection)
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) } else { show() }
    }
    func show() {
        guard let button = item.button else { return }
        model.pruneHistoryBeforePanelDisplay()
        // Do not allocate SwiftUI's dashboard/layout graph for users who only
        // need the menu title. Keep it after first open so settings state lives.
        if popover.contentViewController == nil {
            popover.contentViewController = factories.dashboard(model)
        }
        model.panelVisible = true
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            window.makeKey()
            // Avoid a green default-button focus ring on open. Native keyboard
            // traversal still establishes and displays focus when the user tabs.
            window.makeFirstResponder(nil)
        }
    }
    func popoverDidClose(_ notification: Notification) { model.panelVisible = false }
    /// Opt-in local diagnostic output for integration tests; contains only approved booleans and resource counts.
    private func writeDiagnosticsIfRequested(at now: Date, projection: TokenHubQuotaPresentation) {
        guard let url = diagnosticsURL, now.timeIntervalSince(lastDiagnostic) >= 1 else { return }
        lastDiagnostic = now
        struct Report: Encodable {
            let seasunOnlyMode: Bool
            let backgroundServicesStarted: Bool
            let statusItemVisible: Bool
            let permissionPromptRequested: Bool
            let quotaPresent: Bool
            let directQuotaPresent: Bool
            let directQuotaStatus: String
            let fiveHourPresent: Bool
            let sevenDayPresent: Bool
            let fiveHourResetPresent: Bool
            let sevenDayResetPresent: Bool
            let resetTimePresent: Bool
            let monthlyUsagePresent: Bool
            let liveTokenSpeedPresent: Bool
            let sourceStatus: String
            let backgroundServiceResources: BackgroundServiceResources
        }
        let fiveHourResetPresent = projection.fiveHourCurrent.map { !$0.resetDisplay.isEmpty && $0.resetDisplay != "未知" } ?? false
        let sevenDayResetPresent = projection.sevenDayCurrent.map { !$0.resetDisplay.isEmpty && $0.resetDisplay != "未知" } ?? false
        let resetTimePresent = fiveHourResetPresent || sevenDayResetPresent
        let report = Report(
            seasunOnlyMode: model.isSeasunOnly,
            backgroundServicesStarted: model.backgroundServicesStarted,
            statusItemVisible: item.isVisible,
            permissionPromptRequested: model.permissionPromptRequested,
            quotaPresent: projection.fiveHourCurrent != nil || projection.sevenDayCurrent != nil || projection.monthlyCurrent != nil
                || model.quota != nil || model.fiveHourQuota != nil || model.sevenDayQuota != nil,
            directQuotaPresent: model.tokenHubQuotaIsDirect && projection.snapshotFresh,
            directQuotaStatus: model.tokenHubQuotaStatusText,
            fiveHourPresent: projection.fiveHourCurrent != nil,
            sevenDayPresent: projection.sevenDayCurrent != nil,
            fiveHourResetPresent: fiveHourResetPresent,
            sevenDayResetPresent: sevenDayResetPresent,
            resetTimePresent: resetTimePresent,
            monthlyUsagePresent: projection.monthlyCurrent != nil || model.quota?.used != nil,
            liveTokenSpeedPresent: model.config.dataSource == "localCodex"
                ? model.freshLocalLiveTurn(at: now) != nil : model.stats.active > 0,
            sourceStatus: model.sourceStatus,
            backgroundServiceResources: model.backgroundServiceResources)
        if let data = try? JSONEncoder().encode(report) {
            DispatchQueue.global(qos: .utility).async { try? data.write(to: url, options: .atomic) }
        }
    }

    private nonisolated static func commandLineDiagnosticsURL() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--diagnostics-output"),
              arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }
}
