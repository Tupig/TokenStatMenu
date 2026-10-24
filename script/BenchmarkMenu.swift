import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import TokenStatCore
@testable import TokenStatMenu

/// Never launches an application. Preview mode disables configuration loading,
/// Hub discovery and background services; scan inputs are created here, not supplied.
@main
struct BenchmarkMenu {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 3,
              ["tick", "monthly", "scan"].contains(CommandLine.arguments[1]),
              let iterations = Int(CommandLine.arguments[2]),
              (1...1_000_000).contains(iterations) else { exit(2) }
        let workload = CommandLine.arguments[1]
        let result: (Double, [String: Any])
        switch workload {
        case "scan": result = try scan(iterations: iterations)
        case "monthly": result = monthly(iterations: iterations)
        default: result = tick(iterations: iterations)
        }
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { exit(3) }
        let report: [String: Any] = ["iterations": iterations, "workload": workload,
            "elapsedMS": result.0, "peakRSSBytes": usage.ru_maxrss, "evidence": result.1]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }

    @MainActor static func tick(iterations: Int) -> (Double, [String: Any]) {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let model = AppModel(preview: true)
        model.config.dataSource = "localCodex"
        model.tokenHubNow = { now }
        model.localSnapshot = LocalCodexSnapshot(input: 125, output: 300, total: 425,
            sessionCount: 2, filesScanned: 2, isLimited: false, latestEventAt: now,
            fiveHour: nil, sevenDay: nil, knownThreadCount: 2,
            lastTurn: LocalTurnSummary(outputTokens: 75, durationSeconds: 5, completedAt: now))
        let controller = StatusBarController(model: model)
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        let startedAt = ProcessInfo.processInfo.systemUptime
        for _ in 0..<iterations { autoreleasepool { model.tick() } }
        let elapsedMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        let tickPublications = publications
        withExtendedLifetime(controller) {}
        withExtendedLifetime(subscription) {}
        let title = model.title
        model.shutdown()
        return (elapsedMS, ["objectWillChange": tickPublications, "title": title])
    }

    @MainActor static func monthly(iterations: Int) -> (Double, [String: Any]) {
        let model = AppModel(preview: true)
        let amounts = ["0", "1.005", "999.995", "1234567.89", "-12.345", "999999999999.99"]
        let presentations = amounts.map { value in
            TokenHubQuotaPresentation.project(snapshot: TokenHubQuotaSnapshot(
                identity: TokenHubIdentity(pid: 0, bundleID: "synthetic.benchmark", executablePath: "/synthetic"),
                fiveHour: nil, sevenDay: nil,
                monthly: TokenHubMonthlyUsage(usedAmount: Decimal(string: value)!, sourceSymbol: "$"),
                observedAt: now), now: now, refreshSeconds: 60)
        }
        let expected = presentations.map { model.title(at: now, quotaPresentation: $0) }
        precondition(expected[0] == "— | — | $0.00" && expected[3] == "— | — | $1,234,567.89")
        let startedAt = ProcessInfo.processInfo.systemUptime
        var bytes = 0
        for index in 0..<iterations {
            autoreleasepool {
                let slot = index % presentations.count
                let title = model.title(at: now, quotaPresentation: presentations[slot])
                precondition(title == expected[slot])
                bytes += title.utf8.count
            }
        }
        let elapsedMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        let stale = TokenHubQuotaPresentation.project(snapshot: presentations[0].snapshot,
            now: now.addingTimeInterval(121), refreshSeconds: 60)
        precondition(model.title(at: now, quotaPresentation: stale) == "— | — | —")
        model.shutdown()
        return (elapsedMS, ["titles": expected, "utf8Bytes": bytes, "staleTitle": "— | — | —"])
    }

    static func scan(iterations: Int) throws -> (Double, [String: Any]) {
        guard iterations <= 100 else { exit(2) }
        // No caller-controlled root and no defaultSessionsDirectory/config lookup.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic-scan-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let formatter = ISO8601DateFormatter()
        var inputBytes = 0
        for file in 0..<32 {
            let identity = String(format: "00000000-0000-4000-8000-%012d", file)
            var records: [[String: Any]] = [["type": "session_meta", "payload": ["id": identity, "source": "cli"]]]
            for turn in 0..<40 {
                let start = now.addingTimeInterval(Double(-200 + turn * 4))
                records.append(["type": "event_msg", "timestamp": formatter.string(from: start),
                    "payload": ["type": "task_started", "turn_id": "turn-\(turn)"]])
                for step in 0..<2 {
                    let count = turn * 2 + step + 1
                    records.append(["type": "event_msg", "timestamp": formatter.string(from: start.addingTimeInterval(Double(step + 1))),
                        "payload": ["type": "token_count", "info": ["total_token_usage": [
                            "input_tokens": count * 100, "output_tokens": count * 25,
                            "total_tokens": count * 125, "cached_input_tokens": count * 40]]]])
                }
                records.append(["type": "event_msg", "timestamp": formatter.string(from: start.addingTimeInterval(3)),
                    "payload": ["type": "task_complete", "turn_id": "turn-\(turn)", "duration_ms": 3000]])
            }
            var data = Data()
            for record in records {
                data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
                data.append(10)
            }
            inputBytes += data.count
            try data.write(to: root.appendingPathComponent("rollout-\(identity).jsonl"), options: .atomic)
        }
        var reference: LocalCodexSnapshot?
        var parsedFiles = 0
        var bytesRead = 0
        let startedAt = ProcessInfo.processInfo.systemUptime
        for _ in 0..<iterations {
            try autoreleasepool {
                let cache = LocalCodexUsageReader.Cache() // Intentionally cold reader cache, not OS cache.
                let snapshot = try LocalCodexUsageReader.scan(directory: root, now: now, cache: cache)
                precondition(snapshot.input == 256_000 && snapshot.output == 64_000 && snapshot.total == 320_000)
                precondition(snapshot.knownThreadCount == 32 && snapshot.filesScanned == 32 && !snapshot.isLimited)
                precondition(cache.diagnostics.cacheHits == 0 && cache.diagnostics.parsedFiles == 32)
                precondition(cache.diagnostics.bytesRead == inputBytes)
                if let reference { precondition(snapshot == reference) } else { reference = snapshot }
                parsedFiles += cache.diagnostics.parsedFiles
                bytesRead += cache.diagnostics.bytesRead
            }
        }
        let elapsedMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        let digest = SHA256.hash(data: Data(String(reflecting: reference!).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return (elapsedMS, ["snapshotSHA256": digest, "input": reference!.input,
            "output": reference!.output, "total": reference!.total, "files": 32,
            "inputBytes": inputBytes, "parsedFiles": parsedFiles, "bytesRead": bytesRead,
            "cacheHits": 0])
    }
}
