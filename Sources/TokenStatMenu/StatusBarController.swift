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
        let measurement = model.config.dataSource == "localCodex" ? "本地历史快照 · 速度缺少可靠计时" : "输出估算速度（5 秒窗口）"
        item.button?.toolTip = "\(model.dataNotice) · \(measurement) · \(model.proxyStatus)"
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
    /// Opt-in local diagnostic output for integration tests; no credentials or content.
    /// Reports actual AppKit title and popover state, not a separately simulated UI.
    private func writeDiagnosticsIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--diagnostics-output"), args.indices.contains(index + 1),
              Date().timeIntervalSince(lastDiagnostic) >= 1 else { return }
        lastDiagnostic = Date()
        struct Report: Encodable {
            let isTestFixture: Bool
            let hasRequestData: Bool
            let dataNotice: String
            let discoveredGateways: Int
            let title: String
            let popoverShown: Bool
            let statusItemVisible: Bool
            let active: Int
            let quotaUsed: Double?
            let quotaFraction: Double?
            let fiveHourUsedPercent: Double?
            let sevenDayUsedPercent: Double?
            let quotaError: String
            let alert: String
        }
        let appliedColor = (item.button?.attributedTitle.length ?? 0) > 0
            ? item.button?.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            : nil
        let report = Report(isTestFixture: model.isTestFixture, hasRequestData: model.hasRequestData,
            dataNotice: model.dataNotice, discoveredGateways: model.gateways.count,
            title: item.button?.attributedTitle.string ?? "", popoverShown: popover.isShown,
            statusItemVisible: item.isVisible, active: model.stats.active,
            quotaUsed: model.quota?.used, quotaFraction: model.quota?.fraction,
            fiveHourUsedPercent: model.fiveHourQuota?.usedPercent, sevenDayUsedPercent: model.sevenDayQuota?.usedPercent,
            quotaError: model.quotaError,
            alert: appliedColor == .systemRed ? "red" : appliedColor == .systemYellow ? "yellow" : "normal")
        if let data = try? JSONEncoder().encode(report) {
            let url = URL(fileURLWithPath: args[index + 1])
            DispatchQueue.global(qos: .utility).async { try? data.write(to: url, options: .atomic) }
        }
    }
}
