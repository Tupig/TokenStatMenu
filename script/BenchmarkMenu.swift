import AppKit
import Combine
import Foundation
import TokenStatCore
@testable import TokenStatMenu

/// An isolated menu-update workload, never an application launch. Preview mode
/// disables configuration loading, Hub discovery and every background service.
/// The wrapper links this same harness against both source variants.
@main
struct BenchmarkMenu {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2,
              let iterations = Int(CommandLine.arguments[1]),
              (1...1_000_000).contains(iterations) else { exit(2) }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let model = AppModel(preview: true)
        model.config.dataSource = "localCodex"
        let syntheticDate = Date(timeIntervalSince1970: 1_800_000_000)
        model.tokenHubNow = { syntheticDate }
        model.localSnapshot = LocalCodexSnapshot(input: 125, output: 300, total: 425,
            sessionCount: 2, filesScanned: 2, isLimited: false, latestEventAt: syntheticDate,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 2,
            lastTurn: LocalTurnSummary(outputTokens: 75, durationSeconds: 5, completedAt: syntheticDate))
        let controller = StatusBarController(model: model)
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        let startedAt = ProcessInfo.processInfo.systemUptime
        for _ in 0..<iterations { autoreleasepool { model.tick() } }
        let elapsedMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        let tickPublications = publications // Exclude shutdown notifications.
        withExtendedLifetime(controller) {}
        withExtendedLifetime(subscription) {}
        model.shutdown()
        let report: [String: Any] = ["iterations": iterations, "elapsedMS": elapsedMS,
                                     "objectWillChange": tickPublications]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}
