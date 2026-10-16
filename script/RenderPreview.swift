import AppKit
import SwiftUI

/// Offline rendering of the actual SwiftUI views, not a screen capture.
@main struct RenderPreview {
    @MainActor static func main() throws {
        guard CommandLine.arguments.contains("--test-fixture"), CommandLine.arguments.count > 2 else { exit(2) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let model = AppModel(preview: true)
        model.panelVisible = true
        model.stats.requests = 12; model.stats.input = 64000; model.stats.output = 12000
        model.stats.active = 1; model.stats.outputTPS = 24.5; model.stats.inputWaitTPS = 3800
        model.stats.estimatedRequests = 1; model.stats.costUSD = 0.088
        model.config.inputPrice = 1; model.config.outputPrice = 2
        model.config.usageURL = "https://gateway.example/usage"
        let month = QuotaSnapshot.currentMonth()
        model.quota = try QuotaSnapshot.parse(Data("{\"data\":{\"used_tokens\":640000,\"total_tokens\":1000000,\"month\":\"\(month)\"}}".utf8), config: model.config)
        model.quotaError = ""
        model.gateways = [GatewayDiscovery.candidate(baseURL: "https://gateway.example/route", provider: "示例网关", source: "虚构本机配置", model: "example-model", isActive: true)!]
        model.discoveryStatus = "模拟候选 · 不读取实际配置"
        model.history = (0..<60).map { i in SpeedPoint(date: Date().addingTimeInterval(Double(i - 60)), value: 20 + sin(Double(i) * 0.3) * 6) }
        for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", .dark, .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            for settings in [false, true] {
                let content = DashboardView(model: model, settings: settings)
                    .environment(\.colorScheme, scheme)
                    .background(scheme == .dark ? Color(red: 0.13, green: 0.14, blue: 0.17) : Color(red: 0.96, green: 0.97, blue: 0.99))
                // NSHostingView also renders AppKit-backed ScrollView/TextField/Button,
                // which ImageRenderer intentionally omits. This window stays off screen.
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
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else { throw NSError(domain: "Preview", code: 1) }
                host.cacheDisplay(in: bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "Preview", code: 2) }
                window.close()
                try png.write(to: output.appendingPathComponent("\(name)-\(settings ? "settings" : "dashboard").png"))
            }
        }
        print("Rendered four offline fixture previews; no configuration, credentials or network accessed")
    }
}
