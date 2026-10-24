import AppKit
import SwiftUI

// XCTest 与产品调用同一个早入口；拒绝路径不进入 AppKit 或后台。
let audit = DevProbeAudit()
if let result = DevProbeHostRunner.run(Array(CommandLine.arguments.dropFirst()), audit: audit) {
    guard let event = result.terminalEvent else { exit(78) }
    DevProbeTelemetry.writeTerminalToStdout(event)
    exit(result.exitCode)
}
let ioAudit = DevProbeIOAudit()
// LaunchServices 启动时无人读取 stdout；仅向固定 OSLog 通道写入安全事件。
let now = Int64(floor(Date().timeIntervalSince1970 * 1000))
if let event = DevProbeController.startEvent(actor: "host", counts: audit.snapshot(),
                                              io: ioAudit.snapshot(), nowMs: now,
                                              pid: getpid()) {
    DevProbeTelemetry.writeTerminalToOSLog(event)
}

final class DevWidgetAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 210),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "TokenStatMenu 开发自测"
        window.center()
        window.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
            Text("合成检查").font(.title2.bold())
            Text("这是隔离的小组件开发候选，只显示合成数据。")
            Text("真实额度、Token 速度和正式安装仍需单独验证。")
                .foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.count == 1, DevWidgetIdentity.accepts(urls[0]) else { return }
        window?.makeKeyAndOrderFront(nil)
    }
}

let app = audit.entering(.application) { NSApplication.shared }
let delegate = audit.entering(.delegate) { DevWidgetAppDelegate() }
app.delegate = delegate
app.run()
