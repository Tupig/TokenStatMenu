import AppKit
import SwiftUI

/// 离线渲染实际 SwiftUI 视图，不截取桌面内容。
@main struct RenderPreview {
    @MainActor static func main() throws {
        guard CommandLine.arguments.contains("--test-fixture"), CommandLine.arguments.count > 2 else { exit(2) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let model = AppModel(preview: true)
        model.config.dataSource = "proxy"
        model.panelVisible = true
        model.stats.requests = 12; model.stats.input = 64000; model.stats.output = 12000
        model.stats.active = 1; model.stats.outputTPS = 24.5; model.stats.inputWaitTPS = 3800
        model.stats.estimatedRequests = 1; model.stats.costUSD = 0.088
        model.config.inputPrice = 1; model.config.outputPrice = 2
        model.config.usageURL = "https://gateway.example/usage"
        let month = QuotaSnapshot.currentMonth()
        model.quota = try QuotaSnapshot.parse(Data("{\"data\":{\"used_tokens\":640000,\"total_tokens\":1000000,\"month\":\"\(month)\"}}".utf8), config: model.config)
        model.quotaError = ""
        let windows = try QuotaReport.parse(JSONSerialization.data(withJSONObject: ["data": [
            "five_hour": ["used_percent": 25, "resets_at": Date().addingTimeInterval(7200).timeIntervalSince1970],
            "seven_day": ["used_percent": 70, "resets_at": Date().addingTimeInterval(172800).timeIntervalSince1970]
        ]]), config: model.config)
        model.fiveHourQuota = windows.fiveHour; model.sevenDayQuota = windows.sevenDay
        model.history = (0..<60).map { i in SpeedPoint(date: Date().addingTimeInterval(Double(i - 60)), value: 20 + sin(Double(i) * 0.3) * 6) }
        if CommandLine.arguments.contains("--focus-diagnostic") {
            try renderFocusedPopovers(model, to: output)
            return
        }
        let normalWindows = (model.fiveHourQuota, model.sevenDayQuota)
        for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", .dark, .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            model.fiveHourQuota = normalWindows.0; model.sevenDayQuota = normalWindows.1
            for settings in [false, true] {
                try render(model, settings: settings, scheme: scheme, appearance: appearance,
                    name: "\(name)-\(settings ? "settings" : "dashboard")", to: output)
            }

            model.fiveHourQuota = nil; model.sevenDayQuota = nil
            try render(model, settings: false, scheme: scheme, appearance: appearance,
                name: "\(name)-dashboard-quota-missing", to: output)

            let staleNow = Date().addingTimeInterval(-1000)
            let staleWindows = try QuotaReport.parse(JSONSerialization.data(withJSONObject: ["data": [
                "five_hour": ["used_percent": 25, "resets_at": Date().addingTimeInterval(3600).timeIntervalSince1970],
                "seven_day": ["used_percent": 70, "resets_at": Date().addingTimeInterval(86400).timeIntervalSince1970]
            ]]), config: model.config, now: staleNow)
            model.fiveHourQuota = staleWindows.fiveHour; model.sevenDayQuota = staleWindows.sevenDay
            try render(model, settings: false, scheme: scheme, appearance: appearance,
                name: "\(name)-dashboard-quota-expired", to: output)
        }
        model.config.dataSource = "localCodex"
        model.localSnapshot = LocalCodexSnapshot(input: 12_345, output: 6_789, total: 19_134,
            sessionCount: 3, filesScanned: 3, isLimited: false, latestEventAt: Date(),
            fiveHour: normalWindows.0, sevenDay: normalWindows.1, knownThreadCount: 3)
        for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", .dark, .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            try render(model, settings: false, scheme: scheme, appearance: appearance,
                name: "local-codex-\(name)-dashboard", to: output)
        }
        print("Rendered proxy and populated local Codex views from offline synthetic fixtures; no configuration, credentials or network accessed")
    }

    @MainActor private static func render(_ model: AppModel, settings: Bool, scheme: ColorScheme,
                                          appearance: NSAppearance.Name, name: String, to output: URL) throws {
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
        if settings { verifySettingsScroll(in: host, panelWidth: bounds.width) }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else { throw NSError(domain: "Preview", code: 1) }
        host.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "Preview", code: 2) }
        window.close()
        try png.write(to: output.appendingPathComponent("\(name).png"))
    }

    @MainActor private static func verifySettingsScroll(in host: NSView, panelWidth: CGFloat) {
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let candidates = descendants(host).compactMap { $0 as? NSScrollView }.filter { scroll in
            guard let document = scroll.documentView else { return false }
            return scroll.frame.width >= panelWidth * 0.8
                && document.bounds.height > scroll.contentView.bounds.height + 1
        }
        guard let scroll = candidates.max(by: { $0.frame.width < $1.frame.width }),
              let document = scroll.documentView else {
            print("UNVERIFIED settings scroll: no wide native NSScrollView with vertical overflow was exposed")
            return
        }

        let clip = scroll.contentView
        let originalOrigin = clip.bounds.origin
        let originalVisible = scroll.documentVisibleRect
        let viewportSize = clip.bounds.size
        let documentSize = document.bounds.size
        let targetY: CGFloat = document.isFlipped
            ? max(document.bounds.minY, document.bounds.maxY - viewportSize.height)
            : document.bounds.minY
        clip.scroll(to: NSPoint(x: originalOrigin.x, y: targetY))
        scroll.reflectScrolledClipView(clip)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()

        let bottomVisible = scroll.documentVisibleRect
        let reachedBottom = document.isFlipped
            ? bottomVisible.maxY >= document.bounds.maxY - 1
            : bottomVisible.minY <= document.bounds.minY + 1
        let moved = abs(bottomVisible.origin.y - originalVisible.origin.y) > 1

        clip.scroll(to: originalOrigin)
        scroll.reflectScrolledClipView(clip)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        let restoredVisible = scroll.documentVisibleRect
        let restored = abs(restoredVisible.origin.y - originalVisible.origin.y) <= 1
            && abs(restoredVisible.origin.x - originalVisible.origin.x) <= 1
        print(String(format: "Settings scroll: viewport %.1f×%.1f, document %.1f×%.1f, moved=%@, bottomReached=%@, restoredTop=%@",
            viewportSize.width, viewportSize.height, documentSize.width, documentSize.height,
            moved ? "yes" : "no", reachedBottom ? "yes" : "no", restored ? "yes" : "no"))
        guard moved && reachedBottom && restored else {
            fatalError("Settings scroll did not reach the bottom and restore its original position")
        }
    }

    @MainActor private static func renderFocusedPopovers(_ model: AppModel, to output: URL) throws {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            let anchorWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 48, height: 32),
                styleMask: [.titled], backing: .buffered, defer: false)
            anchorWindow.isReleasedWhenClosed = false
            anchorWindow.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            let anchor = NSButton(frame: NSRect(x: 8, y: 6, width: 32, height: 20))
            anchor.title = "Fixture"
            anchorWindow.contentView = anchor
            anchorWindow.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))

            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentSize = NSSize(width: 460, height: 700)
            popover.contentViewController = NSHostingController(rootView:
                DashboardView(model: model).environment(\.colorScheme, name == "dark" ? .dark : .light))
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))

            guard let popoverWindow = popover.contentViewController?.view.window,
                  let contentView = popover.contentViewController?.view else {
                print("UNVERIFIED \(name) popover focus: no NSPopover window was exposed")
                anchorWindow.close()
                continue
            }
            let views = descendants(of: contentView)
            let settingsButton = views.compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel()?.contains("连接与设置") == true
            }
            let responder = popoverWindow.firstResponder
            let responderLabel = (responder as? NSView)?.accessibilityLabel() ?? "<unavailable>"
            let settingsFocused = settingsButton.map { responder === $0 } ?? false
            let focusRing = settingsButton.map { String(describing: $0.focusRingType) } ?? "unavailable"
            print("Focus diagnostic \(name): appActive=\(NSApp.isActive), anchorKey=\(anchorWindow.isKeyWindow), keyWindow=\(popoverWindow.isKeyWindow), firstResponder=\(String(describing: type(of: responder))), responderLabel=\(responderLabel), settingsButtonFound=\(settingsButton != nil), settingsButtonFirstResponder=\(settingsFocused), focusRing=\(focusRing)")

            let bounds = contentView.bounds
            contentView.layoutSubtreeIfNeeded()
            guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else { throw NSError(domain: "FocusPreview", code: 1) }
            contentView.cacheDisplay(in: bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "FocusPreview", code: 2) }
            try png.write(to: output.appendingPathComponent("\(name)-focused-popover.png"))
            popover.performClose(nil)
            anchorWindow.close()
        }
        print("Rendered natural key-window NSPopover focus diagnostics from simulated fixtures only; first responder was not forced")
    }

    @MainActor private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
