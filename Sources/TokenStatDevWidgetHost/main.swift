import AppKit
import SwiftUI

// The same decision function is used by the memory check. Its lazy identity
// inputs are not evaluated for a malformed argv or for normal startup.
let decision = DevProbeController.decide(Array(CommandLine.arguments.dropFirst()),
                                         configured: { DevWidgetIdentity.group() },
                                         entitlements: { DevGroupGuard.currentEntitlements() },
                                         authorizationMatches: true)
let audit = DevProbeAudit()
let ioAudit = DevProbeIOAudit()
func finishProbe(_ code: Int32, reason: String, sample: Int?) -> Never {
    let now = Int64(floor(Date().timeIntervalSince1970 * 1000))
    guard let event = DevProbeController.terminalEvent(actor: "host", sample: sample,
                                                       exitCode: code, reason: reason,
                                                       counts: audit.snapshot(), io: ioAudit.snapshot(),
                                                       nowMs: now, pid: getpid(),
                                                       payloadMatched: code == 0) else { exit(78) }
    DevProbeTelemetry.writeTerminalToStdout(event)
    exit(code)
}
switch decision {
case let .reject(code, reason):
    finishProbe(code, reason: reason, sample: nil)
case let .sample(number):
    let now = Int64(floor(Date().timeIntervalSince1970 * 1000))
    guard let sample = DevWidgetSnapshot.sample(number, atMs: now),
          DevWidgetSnapshot.decode(sample, nowMs: now) != nil else {
        finishProbe(78, reason: "invalidSchema", sample: number)
    }
    do {
        // First generation is no-clobber. A later run may replace only the
        // snapshot whose ownership this process can still prove; an unknown or
        // unsafe object is never opened for writing. Both decisions share one
        // container lookup so the host audit stays at exactly one.
        try DevWidgetSnapshotStore.writeFirstOrReplace(sample, io: ioAudit)
        finishProbe(0, reason: "none", sample: number)
    } catch DevWidgetSnapshotStore.StoreError.unavailable {
        finishProbe(74, reason: "containerUnavailable", sample: number)
    } catch DevWidgetSnapshotStore.StoreError.existingObject {
        finishProbe(74, reason: "unsafeExistingObject", sample: number)
    } catch DevWidgetSnapshotStore.StoreError.unsafeObject {
        finishProbe(74, reason: "unsafeExistingObject", sample: number)
    } catch {
        finishProbe(74, reason: "ioFailure", sample: number)
    }
case .normal:
    // A LaunchServices start has no stdout consumer. Emit only the bounded
    // safe event to the fixed OSLog channel before AppKit initialization.
    let now = Int64(floor(Date().timeIntervalSince1970 * 1000))
    if let event = DevProbeController.startEvent(actor: "host", counts: audit.snapshot(),
                                                  io: ioAudit.snapshot(), nowMs: now,
                                                  pid: getpid()) {
        DevProbeTelemetry.writeTerminalToOSLog(event)
    }
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
