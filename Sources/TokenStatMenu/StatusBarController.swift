import AppKit
import SwiftUI

@MainActor final class StatusBarController: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let model: AppModel
    private var lastTitle = ""
    private var lastColor: NSColor?
    private var lastDiagnostic = Date.distantPast
    init(model: AppModel) {
        self.model = model
        // Keep a strong reference: a local NSStatusItem vanishes when deallocated.
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.autosaveName = "TokenStatMenu.Metrics"
        popover.behavior = .transient; popover.animates = false; popover.delegate = self
        popover.contentSize = NSSize(width: 460, height: 700)
        popover.contentViewController = NSHostingController(rootView: DashboardView(model: model))
        if let button = item.button {
            button.target = self; button.action = #selector(toggle)
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.setAccessibilityLabel("TokenStatMenu 实时 Token 速度")
        }
        model.onTick = { [weak self] in self?.refreshTitle() }
        refreshTitle()
    }
    func refreshTitle() {
        let title = model.title, color = model.alertColor
        if title != lastTitle || color != lastColor {
            lastTitle = title; lastColor = color
            item.button?.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: color
            ])
        }
        item.button?.toolTip = model.menuTooltip
        writeDiagnosticsIfRequested()
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) } else { show() }
    }
    func show() {
        guard let button = item.button else { return }
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
    private func writeDiagnosticsIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--diagnostics-output"), args.indices.contains(index + 1),
              Date().timeIntervalSince(lastDiagnostic) >= 1 else { return }
        lastDiagnostic = Date()
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
        let snapshot = model.freshTokenHubQuota(at: Date())
        func hasReset(_ value: String?) -> Bool {
            guard let value else { return false }
            return !value.isEmpty && value != "未知"
        }
        let fiveHourResetPresent = hasReset(snapshot?.fiveHour?.resetDisplay)
        let sevenDayResetPresent = hasReset(snapshot?.sevenDay?.resetDisplay)
        let resetTimePresent = fiveHourResetPresent || sevenDayResetPresent
        let report = Report(
            seasunOnlyMode: model.isSeasunOnly,
            backgroundServicesStarted: model.backgroundServicesStarted,
            statusItemVisible: item.isVisible,
            permissionPromptRequested: model.permissionPromptRequested,
            quotaPresent: snapshot != nil || model.quota != nil || model.fiveHourQuota != nil || model.sevenDayQuota != nil,
            directQuotaPresent: model.tokenHubQuotaIsDirect && snapshot != nil,
            directQuotaStatus: model.tokenHubQuotaStatusText,
            fiveHourPresent: snapshot?.fiveHour != nil,
            sevenDayPresent: snapshot?.sevenDay != nil,
            fiveHourResetPresent: fiveHourResetPresent,
            sevenDayResetPresent: sevenDayResetPresent,
            resetTimePresent: resetTimePresent,
            monthlyUsagePresent: snapshot?.monthly != nil || model.quota?.used != nil,
            liveTokenSpeedPresent: model.config.dataSource == "localCodex"
                ? model.freshLocalLiveTurn != nil : model.stats.active > 0,
            sourceStatus: model.sourceStatus,
            backgroundServiceResources: model.backgroundServiceResources)
        if let data = try? JSONEncoder().encode(report) {
            let url = URL(fileURLWithPath: args[index + 1])
            DispatchQueue.global(qos: .utility).async { try? data.write(to: url, options: .atomic) }
        }
    }
}
