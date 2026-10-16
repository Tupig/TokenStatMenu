import CoreFoundation
import Foundation
@testable import TokenStatCore

extension CoreChecks {
    static func localCodexUsageChecks() throws {
        let now = Date(timeIntervalSince1970: 1_797_000_000)

        var refresh = LocalRefreshScheduler()
        let firstGeneration = refresh.begin(now: now)
        check(firstGeneration != nil && refresh.begin(now: now.addingTimeInterval(1)) == nil,
            "local scheduler allows one startup scan and never overlaps an in-flight scan")
        if let generation = firstGeneration {
            check(refresh.complete(generation: generation, now: now.addingTimeInterval(3)),
                "local scheduler accepts completion for the active generation")
            check(refresh.begin(now: now.addingTimeInterval(7.9)) == nil
                && refresh.begin(now: now.addingTimeInterval(8)) != nil,
                "next local scan is due five seconds after the prior scan completes")
        } else {
            check(false, "local scheduler accepts completion for the active generation")
            check(false, "next local scan is due five seconds after the prior scan completes")
        }
        var cancelledRefresh = LocalRefreshScheduler()
        let staleGeneration = cancelledRefresh.begin(now: now)
        _ = cancelledRefresh.invalidate()
        if let staleGeneration {
            check(!cancelledRefresh.complete(generation: staleGeneration, now: now.addingTimeInterval(10)),
                "mode/root invalidation rejects a late local scan result")
        } else {
            check(false, "mode/root invalidation rejects a late local scan result")
        }

        let aggregateRoot = try fixtureDirectory("aggregate")
        defer { try? FileManager.default.removeItem(at: aggregateRoot.deletingLastPathComponent()) }
        let firstID = "11111111-1111-4111-8111-111111111111"
        let secondID = "22222222-2222-4222-8222-222222222222"
        let firstEvents = try [
            tokenEvent(at: now.addingTimeInterval(-300), input: 20, output: 10, cached: 7, reasoning: 4),
            tokenEvent(at: now.addingTimeInterval(-200), input: 50, output: 20),
            tokenEvent(at: now.addingTimeInterval(-120), input: 2, output: 3, cached: 1, reasoning: 1)
        ]
        try writeSession(in: aggregateRoot, uuid: firstID, events: firstEvents, modified: now.addingTimeInterval(-100))
        try writeSession(in: aggregateRoot, uuid: secondID,
            events: [tokenEvent(at: now.addingTimeInterval(-60), input: 4, output: 6)], modified: now)
        let aggregate = try LocalCodexUsageReader.scan(directory: aggregateRoot, now: now)
        check(aggregate.input == 6 && aggregate.output == 9 && aggregate.total == 15,
            "local Codex totals use each session's last cumulative counter, including a lower reset value")
        check(aggregate.sessionCount == 2 && aggregate.latestEventAt == now.addingTimeInterval(-60),
            "local Codex reports unique session count and latest event timestamp")
        check(aggregate.input == 6 && aggregate.output == 9,
            "cached input and reasoning output subfields are not added twice")
        let rescanned = try LocalCodexUsageReader.scan(directory: aggregateRoot, now: now)
        check(rescanned.input == aggregate.input && rescanned.output == aggregate.output
            && rescanned.total == aggregate.total && rescanned.sessionCount == aggregate.sessionCount,
            "repeated local Codex scans replace the snapshot instead of accumulating it")
        let reflectedFields = Set(Mirror(reflecting: aggregate).children.compactMap(\.label))
        check(reflectedFields == Set(["input", "output", "total", "sessionCount", "filesScanned",
            "isLimited", "latestEventAt", "fiveHour", "sevenDay", "lastTurn"]),
            "local Codex snapshot exposes only bounded numeric turn and aggregate metadata")

        let turnRoot = try fixtureDirectory("completed-turn")
        let turnID = "abababab-abab-4bab-8bab-aaaaaaaaaaaa"
        try writeSession(in: turnRoot, uuid: turnID, events: [
            turnTokenEvent(at: now.addingTimeInterval(-2), output: 100),
            turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "turn-1"),
            turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 140),
            turnBoundary(at: now, type: "task_complete", id: "turn-1", durationMS: 1000)
        ], modified: now)
        let completedTurn = try LocalCodexUsageReader.scan(directory: turnRoot, now: now)
        check(completedTurn.lastTurn?.outputTokens == 40
            && completedTurn.lastTurn?.durationSeconds == 1
            && completedTurn.lastTurn?.outputTPS == 40,
            "completed local turn speed uses last in-turn cumulative output delta over whole turn duration")
        if let turn = completedTurn.lastTurn {
            let fields = Mirror(reflecting: turn).children
            let turnFields = Set(fields.compactMap(\.label))
            check(turnFields == Set(["outputTokens", "durationSeconds", "completedAt"])
                && fields.allSatisfy { !($0.value is String) && !($0.value is URL) && !($0.value is Data) },
                "turn reflection exposes only narrow numeric and timestamp fields, with no identifier or path")
        } else {
            check(false, "turn reflection exposes only narrow numeric and timestamp fields, with no identifier or path")
        }
        try? FileManager.default.removeItem(at: turnRoot.deletingLastPathComponent())

        let equalTimestampRoot = try fixtureDirectory("equal-turn-timestamps")
        try writeSession(in: equalTimestampRoot, uuid: "acacacac-acac-4cac-8cac-aaaaaaaaaaaa", events: [
            turnTokenEvent(at: now.addingTimeInterval(-1), output: 3),
            turnBoundary(at: now, type: "task_started", id: "turn-equal"),
            turnTokenEvent(at: now, output: 8),
            turnBoundary(at: now, type: "task_complete", id: "turn-equal", durationMS: 100)
        ], modified: now)
        let equalTimestamps = try LocalCodexUsageReader.scan(directory: equalTimestampRoot, now: now)
        check(equalTimestamps.lastTurn?.outputTokens == 5
            && equalTimestamps.lastTurn?.durationSeconds == 0.1,
            "equal adjacent timestamps are valid in JSONL order when duration_ms establishes a valid turn")
        try? FileManager.default.removeItem(at: equalTimestampRoot.deletingLastPathComponent())

        let invalidDurationRoot = try fixtureDirectory("invalid-turn-duration")
        try writeSession(in: invalidDurationRoot, uuid: "adadadad-adad-4dad-8dad-aaaaaaaaaaaa", events: [
            turnTokenEvent(at: now.addingTimeInterval(-2), output: 3),
            turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "turn-bad"),
            turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 8),
            turnBoundary(at: now, type: "task_complete", id: "turn-bad", durationLiteral: "true")
        ], modified: now)
        let invalidDuration = try LocalCodexUsageReader.scan(directory: invalidDurationRoot, now: now)
        check(invalidDuration.lastTurn == nil,
            "present invalid duration_ms rejects a turn instead of falling back to timestamps")
        try? FileManager.default.removeItem(at: invalidDurationRoot.deletingLastPathComponent())

        let laterBaselineRoot = try fixtureDirectory("late-timestamp-baseline")
        try writeSession(in: laterBaselineRoot, uuid: "bebebebe-bebe-4ebe-8ebe-aaaaaaaaaaaa", events: [
            turnTokenEvent(at: now.addingTimeInterval(-3), output: 1),
            turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 2),
            turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "late-baseline"),
            turnTokenEvent(at: now.addingTimeInterval(-0.25), output: 3),
            turnBoundary(at: now, type: "task_complete", id: "late-baseline", durationMS: 1000)
        ], modified: now)
        let lateBaseline = try LocalCodexUsageReader.scan(directory: laterBaselineRoot, now: now)
        check(lateBaseline.lastTurn == nil,
            "reader cannot skip a later-recorded baseline whose timestamp is after start to use an earlier baseline")
        try? FileManager.default.removeItem(at: laterBaselineRoot.deletingLastPathComponent())

        let nestedTurnsRoot = try fixtureDirectory("outer-incomplete-inner-complete")
        try writeSession(in: nestedTurnsRoot, uuid: "bebebebe-bebe-4ebe-8ebe-bbbbbbbbbbbb", events: [
            turnTokenEvent(at: now.addingTimeInterval(-4), output: 1),
            turnBoundary(at: now.addingTimeInterval(-3), type: "task_started", id: "outer"),
            turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "inner"),
            turnTokenEvent(at: now.addingTimeInterval(-1), output: 4),
            turnBoundary(at: now, type: "task_complete", id: "inner", durationMS: 1000)
        ], modified: now)
        let nestedTurns = try LocalCodexUsageReader.scan(directory: nestedTurnsRoot, now: now)
        check(nestedTurns.lastTurn == nil,
            "an inner complete turn cannot be accepted while an outer overlapping turn remains open")
        try? FileManager.default.removeItem(at: nestedTurnsRoot.deletingLastPathComponent())

        let malformedExplicitRoot = try fixtureDirectory("malformed-explicit-usage")
        try writeSession(in: malformedExplicitRoot, uuid: "bfbfbfbf-bfbf-4bfb-8bfb-aaaaaaaaaaaa", events: [
            turnTokenEvent(at: now.addingTimeInterval(-2), output: 1),
            turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "bad-usage"),
            turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 2),
            rawTokenEvent(at: now.addingTimeInterval(-0.25), inputLiteral: "null", outputLiteral: "3"),
            turnBoundary(at: now, type: "task_complete", id: "bad-usage", durationMS: 1000)
        ], modified: now)
        let malformedExplicit = try LocalCodexUsageReader.scan(directory: malformedExplicitRoot, now: now)
        check(malformedExplicit.lastTurn == nil,
            "explicit null or malformed cumulative usage cannot be ignored after valid in-turn usage")
        try? FileManager.default.removeItem(at: malformedExplicitRoot.deletingLastPathComponent())

        var oversizedPrefix = Data(repeating: 0x78, count: 256 * 1024 + 32)
        oversizedPrefix.append(10)
        let tailCompleteRoot = try fixtureDirectory("tail-complete-turn")
        try writeSession(in: tailCompleteRoot, uuid: "babababa-baba-4bab-8bab-aaaaaaaaaaaa", events: [
            turnTokenEvent(at: now.addingTimeInterval(-2), output: 2),
            turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "tail"),
            turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 5),
            turnBoundary(at: now, type: "task_complete", id: "tail", durationMS: 1000)
        ], modified: now, prefix: oversizedPrefix)
        let tailComplete = try LocalCodexUsageReader.scan(directory: tailCompleteRoot, now: now)
        check(tailComplete.lastTurn?.outputTokens == 3,
            "a complete turn retained within the bounded tail remains eligible")
        try? FileManager.default.removeItem(at: tailCompleteRoot.deletingLastPathComponent())

        let tailMissingBaselineRoot = try fixtureDirectory("tail-missing-baseline")
        try writeSession(in: tailMissingBaselineRoot, uuid: "bcbabcbc-bcbc-4bcb-8bcb-aaaaaaaaaaaa", events: [
            turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "tail"),
            turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 5),
            turnBoundary(at: now, type: "task_complete", id: "tail", durationMS: 1000)
        ], modified: now, prefix: oversizedPrefix)
        let tailMissingBaseline = try LocalCodexUsageReader.scan(directory: tailMissingBaselineRoot, now: now)
        check(tailMissingBaseline.lastTurn == nil,
            "a truncated tail missing the cumulative baseline cannot produce turn speed")
        try? FileManager.default.removeItem(at: tailMissingBaselineRoot.deletingLastPathComponent())

        let fallbackRoot = try fixtureDirectory("turn-duration-fallback")
        try writeSession(in: fallbackRoot, uuid: "afafafaf-afaf-4faf-8faf-aaaaaaaaaaaa", events: [
            turnTokenEvent(at: now.addingTimeInterval(-1), output: 10),
            turnBoundary(at: now.addingTimeInterval(-0.5), type: "task_started", id: "turn-fallback"),
            turnTokenEvent(at: now.addingTimeInterval(-0.25), output: 30),
            turnBoundary(at: now, type: "task_complete", id: "turn-fallback")
        ], modified: now)
        let fallback = try LocalCodexUsageReader.scan(directory: fallbackRoot, now: now)
        check(fallback.lastTurn?.outputTokens == 20 && fallback.lastTurn?.durationSeconds == 0.5,
            "absent duration_ms falls back to start-to-completion event timestamp duration")
        try? FileManager.default.removeItem(at: fallbackRoot.deletingLastPathComponent())

        let activeAfterCompletionRoot = try fixtureDirectory("completed-before-active")
        try writeSession(in: activeAfterCompletionRoot, uuid: "baababaa-baba-4bab-8bab-aaaaaaaaaaaa", events: [
            turnTokenEvent(at: now.addingTimeInterval(-4), output: 10),
            turnBoundary(at: now.addingTimeInterval(-3), type: "task_started", id: "completed"),
            turnTokenEvent(at: now.addingTimeInterval(-2), output: 30),
            turnBoundary(at: now.addingTimeInterval(-1), type: "task_complete", id: "completed", durationMS: 2000),
            turnTokenEvent(at: now.addingTimeInterval(-0.9), output: 30),
            turnBoundary(at: now.addingTimeInterval(-0.8), type: "task_started", id: "latest"),
            turnTokenEvent(at: now.addingTimeInterval(-0.6), output: 50),
            turnBoundary(at: now.addingTimeInterval(-0.3), type: "task_complete", id: "latest", durationMS: 500),
            turnBoundary(at: now.addingTimeInterval(-0.2), type: "task_started", id: "still-active"),
            turnTokenEvent(at: now, output: 80)
        ], modified: now)
        let retainedCompleted = try LocalCodexUsageReader.scan(directory: activeAfterCompletionRoot, now: now)
        check(retainedCompleted.lastTurn?.outputTokens == 20 && retainedCompleted.lastTurn?.durationSeconds == 0.5,
            "the most recent completed turn wins, and a still-active turn does not replace it")
        try? FileManager.default.removeItem(at: activeAfterCompletionRoot.deletingLastPathComponent())

        let rejectedTurnCases: [(String, [Data])] = try [
            ("missing-baseline", [turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnTokenEvent(at: now, output: 2), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)]),
            ("invalid-explicit-baseline", [rawTokenEvent(at: now.addingTimeInterval(-2), inputLiteral: "0", outputLiteral: "-1"), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 2), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)]),
            ("invalid-later-in-turn-usage", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-0.75), output: 2), rawTokenEvent(at: now.addingTimeInterval(-0.5), inputLiteral: "0", outputLiteral: "-1"), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)]),
            ("missing-start", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1), turnTokenEvent(at: now.addingTimeInterval(-1), output: 2), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)]),
            ("missing-complete", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnTokenEvent(at: now, output: 2)]),
            ("missing-in-turn-usage", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)]),
            ("overlap", [turnTokenEvent(at: now.addingTimeInterval(-4), output: 1), turnBoundary(at: now.addingTimeInterval(-3), type: "task_started", id: "x"), turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "y"), turnTokenEvent(at: now.addingTimeInterval(-1), output: 2), turnBoundary(at: now.addingTimeInterval(-0.5), type: "task_complete", id: "x", durationMS: 2000), turnBoundary(at: now, type: "task_complete", id: "y", durationMS: 1000)]),
            ("reused-id", [turnTokenEvent(at: now.addingTimeInterval(-5), output: 1), turnBoundary(at: now.addingTimeInterval(-4), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-3), output: 2), turnBoundary(at: now.addingTimeInterval(-2), type: "task_complete", id: "x", durationMS: 1000), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnTokenEvent(at: now, output: 3), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)]),
            ("post-complete-usage", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000), turnTokenEvent(at: now, output: 4)]),
            ("mismatched-id", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 2), turnBoundary(at: now, type: "task_complete", id: "y", durationMS: 1000)]),
            ("aborted", [turnTokenEvent(at: now.addingTimeInterval(-3), output: 1), turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-1), output: 2), turnBoundary(at: now.addingTimeInterval(-0.5), type: "turn_aborted", id: "x"), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)]),
            ("future-complete", [turnTokenEvent(at: now.addingTimeInterval(-3), output: 1), turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-1), output: 2), turnBoundary(at: now.addingTimeInterval(1), type: "task_complete", id: "x", durationMS: 1000)]),
            ("timestamp-regression", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-1.5), output: 2), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)]),
            ("null-duration", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 2), turnBoundary(at: now, type: "task_complete", id: "x", durationLiteral: "null")]),
            ("negative-duration", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 2), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: -1)]),
            ("too-short-duration", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1), turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 2), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 99)]),
            ("rollback", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 10), turnBoundary(at: now.addingTimeInterval(-1.5), type: "task_started", id: "x"), turnTokenEvent(at: now.addingTimeInterval(-1), output: 15), turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 12), turnTokenEvent(at: now.addingTimeInterval(-0.25), output: 18), turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)])
        ]
        for (label, events) in rejectedTurnCases {
            let root = try fixtureDirectory("turn-reject-\(label)")
            let uuid = UUID().uuidString.lowercased()
            try writeSession(in: root, uuid: uuid, events: events, modified: now)
            let result = try LocalCodexUsageReader.scan(directory: root, now: now)
            check(result.lastTurn == nil, "invalid turn evidence is rejected: \(label)")
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
        let duplicateCompletionRoot = try fixtureDirectory("duplicate-turn-completion")
        try writeSession(in: duplicateCompletionRoot, uuid: "bbabbbab-babb-4bab-8bab-aaaaaaaaaaaa", events: [
            turnTokenEvent(at: now.addingTimeInterval(-3), output: 1),
            turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "once"),
            turnTokenEvent(at: now.addingTimeInterval(-1), output: 2),
            turnBoundary(at: now.addingTimeInterval(-0.5), type: "task_complete", id: "once", durationMS: 1000),
            turnBoundary(at: now, type: "task_complete", id: "once", durationMS: 1000)
        ], modified: now)
        let duplicateCompletion = try LocalCodexUsageReader.scan(directory: duplicateCompletionRoot, now: now)
        check(duplicateCompletion.lastTurn?.outputTokens == 1,
            "duplicate completion does not double-count the same completed turn")
        try? FileManager.default.removeItem(at: duplicateCompletionRoot.deletingLastPathComponent())

        let cacheRoot = try fixtureDirectory("warm-cache")
        try writeSession(in: cacheRoot, uuid: "aeaeaeae-aeae-4eae-8eae-aaaaaaaaaaaa",
            events: [tokenEvent(at: now, input: 2, output: 3)], modified: now)
        let cache = LocalCodexUsageReader.Cache()
        _ = try LocalCodexUsageReader.scan(directory: cacheRoot, now: now, cache: cache)
        _ = try LocalCodexUsageReader.scan(directory: cacheRoot, now: now, cache: cache)
        let diagnostics = cache.diagnostics
        check(diagnostics.cacheHits == 1 && diagnostics.bytesRead == 0
            && diagnostics.parsedFiles == 0 && diagnostics.safeOpens == 1,
            "unchanged local session is safely reopened and served from numeric cache without reading or parsing bytes")
        let freshnessRoot = try fixtureDirectory("cache-quota-freshness")
        try writeSession(in: freshnessRoot, uuid: "c3c3c3c3-c3c3-4c3c-8c3c-aaaaaaaaaaaa", events: [
            tokenEvent(at: now, input: 1, output: 1,
                rateLimits: rateLimits(fiveHour: 20, sevenDay: nil, reset: now.addingTimeInterval(3600)))
        ], modified: now)
        let freshnessCache = LocalCodexUsageReader.Cache()
        let freshSnapshot = try LocalCodexUsageReader.scan(directory: freshnessRoot, now: now, cache: freshnessCache)
        let staleSnapshot = try LocalCodexUsageReader.scan(directory: freshnessRoot, now: now.addingTimeInterval(180), cache: freshnessCache)
        check(freshSnapshot.fiveHour?.isFresh(at: now, refreshSeconds: 60) == true
            && staleSnapshot.fiveHour?.isFresh(at: now.addingTimeInterval(180), refreshSeconds: 60) == false
            && freshnessCache.diagnostics.cacheHits == 1,
            "cache hit reevaluates quota freshness against the current scan time")
        try? FileManager.default.removeItem(at: freshnessRoot.deletingLastPathComponent())

        let futureOnRollbackRoot = try fixtureDirectory("cache-now-rollback")
        let futureCompletion = now.addingTimeInterval(10)
        try writeSession(in: futureOnRollbackRoot, uuid: "c5c5c5c5-c5c5-4c5c-8c5c-aaaaaaaaaaaa", events: [
            turnTokenEvent(at: now.addingTimeInterval(-2), output: 1),
            turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "future"),
            turnTokenEvent(at: now, output: 2),
            turnBoundary(at: futureCompletion, type: "task_complete", id: "future", durationMS: 1000)
        ], modified: now)
        let rollbackCache = LocalCodexUsageReader.Cache()
        _ = try LocalCodexUsageReader.scan(directory: futureOnRollbackRoot, now: futureCompletion.addingTimeInterval(1), cache: rollbackCache)
        let afterRollback = try LocalCodexUsageReader.scan(directory: futureOnRollbackRoot, now: now, cache: rollbackCache)
        check(afterRollback.lastTurn == nil && rollbackCache.diagnostics.cacheHits == 1,
            "warm numeric cache revalidates completion time when the scan clock moves backward")
        try? FileManager.default.removeItem(at: futureOnRollbackRoot.deletingLastPathComponent())
        let cachedPath = sessionURL(in: cacheRoot, uuid: "aeaeaeae-aeae-4eae-8eae-aaaaaaaaaaaa")
        var appended = try Data(contentsOf: cachedPath)
        appended.append(try tokenEvent(at: now, input: 3, output: 4)); appended.append(10)
        try appended.write(to: cachedPath)
        let changedCache = try LocalCodexUsageReader.scan(directory: cacheRoot, now: now, cache: cache)
        check(changedCache.input == 3 && changedCache.output == 4
            && cache.diagnostics.cacheHits == 0 && cache.diagnostics.bytesRead > 0,
            "appending to a cached local session invalidates its prior numeric summary")
        var sameSizeRewrite = try Data(contentsOf: cachedPath)
        // Keep the JSONL byte count stable while changing its numeric payload.
        let originalBytes = Data("\"input_tokens\":3".utf8)
        let rewrittenBytes = Data("\"input_tokens\":4".utf8)
        if let range = sameSizeRewrite.range(of: originalBytes) {
            sameSizeRewrite.replaceSubrange(range, with: rewrittenBytes)
        } else {
            check(false, "same-size cache rewrite fixture locates the input count")
        }
        let originalFileSize = try Data(contentsOf: cachedPath).count
        check(sameSizeRewrite.count == originalFileSize,
            "same-size cache rewrite fixture preserves byte count")
        try sameSizeRewrite.write(to: cachedPath)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(2)], ofItemAtPath: cachedPath.path)
        let rewrittenCache = try LocalCodexUsageReader.scan(directory: cacheRoot, now: now, cache: cache)
        check(rewrittenCache.input == 4 && rewrittenCache.output == 4 && cache.diagnostics.cacheHits == 0,
            "same-size rewrite with changed file metadata invalidates cached summary")
        var truncatedBytes = try Data(contentsOf: cachedPath)
        truncatedBytes.removeLast(min(10, truncatedBytes.count))
        try truncatedBytes.write(to: cachedPath)
        let truncatedCache = try LocalCodexUsageReader.scan(directory: cacheRoot, now: now, cache: cache)
        check(truncatedCache.input == 2 && truncatedCache.output == 3
            && cache.diagnostics.cacheHits == 0 && cache.diagnostics.bytesRead > 0,
            "truncating a cached file reparses and falls back to its remaining valid line")
        let otherRoot = try fixtureDirectory("cache-other-root")
        try writeSession(in: otherRoot, uuid: "aeaeaeae-aeae-4eae-8eae-aaaaaaaaaaaa",
            events: [tokenEvent(at: now, input: 9, output: 9)], modified: now)
        let rootIsolated = try LocalCodexUsageReader.scan(directory: otherRoot, now: now, cache: cache)
        check(rootIsolated.input == 9 && rootIsolated.output == 9
            && cache.diagnostics.cacheHits == 0 && cache.entryCount <= 32,
            "same UUID, size and mtime under another root do not hit prior root's cache")
        try? FileManager.default.removeItem(at: otherRoot.deletingLastPathComponent())
        let sameRootA = try fixtureDirectory("same-identity-root-a")
        let sameRootB = try fixtureDirectory("same-identity-root-b")
        let sharedUUID = "c1c1c1c1-c1c1-4c1c-8c1c-aaaaaaaaaaaa"
        try writeSession(in: sameRootA, uuid: sharedUUID,
            events: [tokenEvent(at: now, input: 5, output: 6)], modified: now)
        try writeSession(in: sameRootB, uuid: sharedUUID,
            events: [tokenEvent(at: now, input: 7, output: 8)], modified: now)
        let rootProofCache = LocalCodexUsageReader.Cache()
        _ = try LocalCodexUsageReader.scan(directory: sameRootA, now: now, cache: rootProofCache)
        let rootProofResult = try LocalCodexUsageReader.scan(directory: sameRootB, now: now, cache: rootProofCache)
        check(rootProofResult.input == 7 && rootProofResult.output == 8
            && rootProofCache.diagnostics.cacheHits == 0,
            "identical UUID, byte size and modification time remain isolated by root identity")
        try? FileManager.default.removeItem(at: sameRootA.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: sameRootB.deletingLastPathComponent())
        let inodeRoot = try fixtureDirectory("inode-replacement")
        let inodeUUID = "c2c2c2c2-c2c2-4c2c-8c2c-aaaaaaaaaaaa"
        try writeSession(in: inodeRoot, uuid: inodeUUID,
            events: [tokenEvent(at: now, input: 1, output: 2)], modified: now)
        let inodeCache = LocalCodexUsageReader.Cache()
        _ = try LocalCodexUsageReader.scan(directory: inodeRoot, now: now, cache: inodeCache)
        try Data("replacement".utf8).write(to: sessionURL(in: inodeRoot, uuid: inodeUUID), options: .atomic)
        let inodeReplaced = try LocalCodexUsageReader.scan(directory: inodeRoot, now: now, cache: inodeCache)
        check(inodeReplaced.input == 0 && inodeCache.diagnostics.cacheHits == 0,
            "atomic same-path replacement invalidates cached descriptor identity")
        try? FileManager.default.removeItem(at: inodeRoot.deletingLastPathComponent())
        let isolatedCache = LocalCodexUsageReader.Cache()
        _ = try LocalCodexUsageReader.scan(directory: cacheRoot, now: now, cache: isolatedCache)
        check(isolatedCache.entryCount == 1 && cache.entryCount == 1,
            "reader cache instances isolate roots and retain only bounded numeric summaries")
        _ = try LocalCodexUsageReader.scan(directory: cacheRoot, now: now, cache: cache)
        try FileManager.default.removeItem(at: cachedPath)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-cache-outside-\(UUID().uuidString).jsonl")
        try Data("secret".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: cachedPath, withDestinationURL: outside)
        let replacedBySymlink = try LocalCodexUsageReader.scan(directory: cacheRoot, now: now, cache: cache)
        check(replacedBySymlink.input == 0 && replacedBySymlink.output == 0,
            "deleted cached file replaced by symlink is not served from stale cache")
        try? FileManager.default.removeItem(at: outside)
        try? FileManager.default.removeItem(at: cacheRoot.deletingLastPathComponent())

        let cappedCacheRoot = try fixtureDirectory("cache-cap")
        for index in 0..<33 {
            let uuid = String(format: "bcbcbcbc-bcbc-4bcb-8bcb-%012d", index + 1)
            try writeSession(in: cappedCacheRoot, uuid: uuid,
                events: [tokenEvent(at: now, input: 1, output: 1)], modified: now.addingTimeInterval(Double(index)))
        }
        let cappedCache = LocalCodexUsageReader.Cache()
        _ = try LocalCodexUsageReader.scan(directory: cappedCacheRoot, now: now, cache: cappedCache)
        check(cappedCache.entryCount <= 32, "per-reader numeric cache retains at most 32 summaries")
        try? FileManager.default.removeItem(at: cappedCacheRoot.deletingLastPathComponent())

        let raceRoot = try fixtureDirectory("metadata-race")
        let racedURL = sessionURL(in: raceRoot, uuid: "bdcdbdcd-bdcd-4bcd-8bcd-aaaaaaaaaaaa")
        try writeSession(in: raceRoot, uuid: "bdcdbdcd-bdcd-4bcd-8bcd-aaaaaaaaaaaa",
            events: [tokenEvent(at: now, input: 100, output: 100)], modified: now)
        try writeSession(in: raceRoot, uuid: "bebdbebd-bebd-4beb-8beb-aaaaaaaaaaaa",
            events: [tokenEvent(at: now, input: 7, output: 8)], modified: now)
        var raced = false
        let raceCache = LocalCodexUsageReader.Cache(beforePostReadValidation: {
            guard !raced else { return }
            raced = true
            try? Data("replacement".utf8).write(to: racedURL)
        })
        let raceResult = try LocalCodexUsageReader.scan(directory: raceRoot, now: now, cache: raceCache)
        check(raceResult.input == 7 && raceResult.output == 8,
            "metadata change during read drops only that file while retaining other safe file results")
        try? FileManager.default.removeItem(at: raceRoot.deletingLastPathComponent())

        let duplicateRoot = try fixtureDirectory("duplicate")
        let duplicateID = "abc33333-3333-4333-8333-333333333333"
        try writeSession(in: duplicateRoot, uuid: duplicateID,
            events: [tokenEvent(at: now.addingTimeInterval(-30), input: 1, output: 1)], modified: now.addingTimeInterval(-20))
        let lowercaseFixture = sessionURL(in: duplicateRoot, uuid: duplicateID)
        try FileManager.default.moveItem(at: lowercaseFixture,
            to: duplicateRoot.appendingPathComponent("rollout-primary-\(duplicateID).jsonl"))
        try writeSession(in: duplicateRoot, uuid: duplicateID.uppercased(),
            events: [tokenEvent(at: now.addingTimeInterval(-10), input: 8, output: 9)], modified: now)
        let uppercaseFixture = sessionURL(in: duplicateRoot, uuid: duplicateID.uppercased())
        try FileManager.default.moveItem(at: uppercaseFixture,
            to: duplicateRoot.appendingPathComponent("rollout-alias-\(duplicateID.uppercased()).jsonl"))
        let duplicate = try LocalCodexUsageReader.scan(directory: duplicateRoot, now: now)
        check(duplicate.sessionCount == 1 && duplicate.input == 8 && duplicate.output == 9,
            "UUID suffix aliases canonicalize and newest modified duplicate contributes once")
        try? FileManager.default.removeItem(at: duplicateRoot.deletingLastPathComponent())

        let invalidRoot = try fixtureDirectory("invalid-counts")
        let validID = "44444444-4444-4444-8444-444444444444"
        try writeSession(in: invalidRoot, uuid: validID,
            events: [tokenEvent(at: now, input: 5, output: 7)], modified: now)
        let invalidLiterals = ["-1", "1.5", "true", "9223372036854775808", "1e999"]
        for (index, literal) in invalidLiterals.enumerated() {
            let uuid = String(format: "55555555-5555-4555-8555-%012d", index + 1)
            try writeSession(in: invalidRoot, uuid: uuid,
                events: [rawTokenEvent(at: now, inputLiteral: literal, outputLiteral: "1")], modified: now)
        }
        let invalid = try LocalCodexUsageReader.scan(directory: invalidRoot, now: now)
        check(invalid.input == 5 && invalid.output == 7 && invalid.sessionCount == 1,
            "negative, fractional, boolean, overflowing and non-finite counters are rejected")
        try? FileManager.default.removeItem(at: invalidRoot.deletingLastPathComponent())

        let exactRoot = try fixtureDirectory("exact-large-integer")
        try writeSession(in: exactRoot, uuid: "14141414-1414-4414-8414-141414141414",
            events: [rawTokenEvent(at: now, inputLiteral: "9007199254740993", outputLiteral: "0")], modified: now)
        let exactLarge = try LocalCodexUsageReader.scan(directory: exactRoot, now: now)
        check(exactLarge.input == 9_007_199_254_740_993,
            "large JSON integer above 2^53 is parsed without floating point rounding")
        try? FileManager.default.removeItem(at: exactRoot.deletingLastPathComponent())

        let truncatedRoot = try fixtureDirectory("truncated-tail")
        let longPrefix = Data(repeating: 0x78, count: 256 * 1024 + 32)
        let complete = try tokenEvent(at: now, input: 12, output: 13)
        var paddedPrefix = longPrefix
        paddedPrefix.append(10)
        try writeSession(in: truncatedRoot, uuid: "66666666-6666-4666-8666-666666666666",
            events: [complete], modified: now, prefix: paddedPrefix, suffix: Data("{\"partial\":".utf8))
        let truncated = try LocalCodexUsageReader.scan(directory: truncatedRoot, now: now)
        check(truncated.input == 12 && truncated.output == 13,
            "tail scan ignores the truncated first fragment and incomplete final JSON line")
        try? FileManager.default.removeItem(at: truncatedRoot.deletingLastPathComponent())

        let quotaRoot = try fixtureDirectory("quota-snapshots")
        let oldTime = now.addingTimeInterval(-600), latestTime = now.addingTimeInterval(-60)
        try writeSession(in: quotaRoot, uuid: "77777777-7777-4777-8777-777777777777",
            events: [tokenEvent(at: oldTime, input: 1, output: 1,
                rateLimits: rateLimits(fiveHour: 10, sevenDay: 20, reset: now.addingTimeInterval(3600)))],
            modified: now)
        try writeSession(in: quotaRoot, uuid: "88888888-8888-4888-8888-888888888888",
            events: [tokenEvent(at: latestTime, input: 2, output: 2,
                rateLimits: rateLimits(fiveHour: 30, sevenDay: 40, reset: now.addingTimeInterval(7200)))],
            modified: now.addingTimeInterval(-500))
        let quotaSnapshot = try LocalCodexUsageReader.scan(directory: quotaRoot, now: now)
        check(quotaSnapshot.latestEventAt == latestTime && quotaSnapshot.fiveHour?.usedPercent == 30
            && quotaSnapshot.sevenDay?.usedPercent == 40,
            "quota windows come from one latest event timestamp, not file modification order")
        check(quotaSnapshot.fiveHour?.fetchedAt == latestTime && quotaSnapshot.sevenDay?.fetchedAt == latestTime,
            "local quota freshness preserves the source event timestamp")
        try? FileManager.default.removeItem(at: quotaRoot.deletingLastPathComponent())

        let reverseQuotaRoot = try fixtureDirectory("quota-event-timestamps")
        try writeSession(in: reverseQuotaRoot, uuid: "c4c4c4c4-c4c4-4c4c-8c4c-aaaaaaaaaaaa", events: [
            tokenEvent(at: now.addingTimeInterval(-10), input: 1, output: 1,
                rateLimits: rateLimits(fiveHour: 61, sevenDay: 71, reset: now.addingTimeInterval(3600))),
            tokenEvent(at: now.addingTimeInterval(-20), input: 1, output: 1,
                rateLimits: rateLimits(fiveHour: 11, sevenDay: 21, reset: now.addingTimeInterval(3600)))
        ], modified: now)
        let reverseQuota = try LocalCodexUsageReader.scan(directory: reverseQuotaRoot, now: now)
        check(reverseQuota.fiveHour?.usedPercent == 61 && reverseQuota.sevenDay?.usedPercent == 71,
            "older timestamp appearing later in the file cannot replace the newest quota snapshot")
        try? FileManager.default.removeItem(at: reverseQuotaRoot.deletingLastPathComponent())

        let equalQuotaRoot = try fixtureDirectory("quota-equal-timestamp-clear")
        let equalQuotaTime = now.addingTimeInterval(-10)
        try writeSession(in: equalQuotaRoot, uuid: "c6c6c6c6-c6c6-4c6c-8c6c-aaaaaaaaaaaa", events: [
            tokenEvent(at: equalQuotaTime, input: 1, output: 1,
                rateLimits: rateLimits(fiveHour: 61, sevenDay: 71, reset: now.addingTimeInterval(3600))),
            tokenEvent(at: equalQuotaTime, input: 1, output: 1, rateLimits: [:])
        ], modified: now)
        let equalQuota = try LocalCodexUsageReader.scan(directory: equalQuotaRoot, now: now)
        check(equalQuota.fiveHour == nil && equalQuota.sevenDay == nil,
            "same-timestamp later snapshot with missing windows clears older quota data")
        try? FileManager.default.removeItem(at: equalQuotaRoot.deletingLastPathComponent())

        let missingWindowRoot = try fixtureDirectory("missing-window")
        try writeSession(in: missingWindowRoot, uuid: "99999999-9999-4999-8999-999999999999",
            events: [tokenEvent(at: now.addingTimeInterval(-40), input: 1, output: 1,
                rateLimits: rateLimits(fiveHour: 25, sevenDay: nil, reset: now.addingTimeInterval(3600)))],
            modified: now)
        try writeSession(in: missingWindowRoot, uuid: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaab",
            events: [tokenEvent(at: now.addingTimeInterval(-20), input: 1, output: 1,
                rateLimits: rateLimits(fiveHour: nil, sevenDay: 55, reset: now.addingTimeInterval(3600)))], modified: now)
        let missingWindow = try LocalCodexUsageReader.scan(directory: missingWindowRoot, now: now)
        check(missingWindow.fiveHour == nil && missingWindow.sevenDay?.usedPercent == 55,
            "missing 5-hour quota stays unknown without combining another event")
        try? FileManager.default.removeItem(at: missingWindowRoot.deletingLastPathComponent())

        let clearedWindowRoot = try fixtureDirectory("cleared-window")
        try writeSession(in: clearedWindowRoot, uuid: "12121212-1212-4212-8212-121212121212",
            events: [tokenEvent(at: now.addingTimeInterval(-60), input: 1, output: 1,
                rateLimits: rateLimits(fiveHour: 45, sevenDay: 65, reset: now.addingTimeInterval(3600)))], modified: now)
        try writeSession(in: clearedWindowRoot, uuid: "13131313-1313-4313-8313-131313131313",
            events: [tokenEvent(at: now.addingTimeInterval(-10), input: 1, output: 1, rateLimits: [:])], modified: now)
        let clearedWindow = try LocalCodexUsageReader.scan(directory: clearedWindowRoot, now: now)
        check(clearedWindow.fiveHour == nil && clearedWindow.sevenDay == nil,
            "newest event with empty rate_limits clears older quota snapshot")
        try? FileManager.default.removeItem(at: clearedWindowRoot.deletingLastPathComponent())

        let futureRoot = try fixtureDirectory("future-event")
        let future = now.addingTimeInterval(3600)
        try writeSession(in: futureRoot, uuid: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            events: [tokenEvent(at: future, input: 1, output: 1,
                rateLimits: rateLimits(fiveHour: 25, sevenDay: 35, reset: future.addingTimeInterval(3600)))], modified: now)
        let futureSnapshot = try LocalCodexUsageReader.scan(directory: futureRoot, now: now)
        check(futureSnapshot.latestEventAt == future
            && futureSnapshot.fiveHour?.isFresh(at: now, refreshSeconds: 60) == false,
            "future-dated local quota retains its timestamp but is not treated as current")
        try? FileManager.default.removeItem(at: futureRoot.deletingLastPathComponent())

        let symlinkRoot = try fixtureDirectory("symlink-root")
        let outsideRoot = try fixtureDirectory("symlink-outside")
        try writeSession(in: outsideRoot, uuid: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            events: [tokenEvent(at: now, input: 100, output: 200)], modified: now)
        let target = sessionURL(in: outsideRoot, uuid: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        try FileManager.default.createSymbolicLink(at: sessionURL(in: symlinkRoot, uuid: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"),
            withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: symlinkRoot.appendingPathComponent("linked-directory"),
            withDestinationURL: outsideRoot)
        let symlink = try LocalCodexUsageReader.scan(directory: symlinkRoot, now: now)
        check(symlink.input == 0 && symlink.output == 0 && symlink.sessionCount == 0,
            "file and directory symlinks outside the sessions root are not followed")
        try? FileManager.default.removeItem(at: symlinkRoot.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: outsideRoot.deletingLastPathComponent())

        let missingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-missing-\(UUID().uuidString)")
        let empty = try LocalCodexUsageReader.scan(directory: missingRoot, now: now)
        check(empty.input == 0 && empty.output == 0 && empty.total == 0 && empty.sessionCount == 0
            && empty.latestEventAt == nil,
            "missing sessions root returns an empty snapshot")

        let nestedRoot = try fixtureDirectory("nested-sessions")
        let nestedID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        try writeSession(in: nestedRoot, uuid: nestedID,
            events: [tokenEvent(at: now, input: 17, output: 19)], modified: now)
        let nestedDirectory = nestedRoot.appendingPathComponent("2026/10/17", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: sessionURL(in: nestedRoot, uuid: nestedID),
            to: nestedDirectory.appendingPathComponent("rollout-fixture-\(nestedID).jsonl"))
        let nested = try LocalCodexUsageReader.scan(directory: nestedRoot, now: now)
        check(nested.input == 17 && nested.output == 19 && nested.sessionCount == 1,
            "nested Codex YYYY/MM/DD session files are discovered")
        try? FileManager.default.removeItem(at: nestedRoot.deletingLastPathComponent())

        let overflowRoot = try fixtureDirectory("aggregate-overflow")
        try writeSession(in: overflowRoot, uuid: "ffffffff-ffff-4fff-8fff-ffffffffffff",
            events: [rawTokenEvent(at: now, inputLiteral: String(Int.max), outputLiteral: "0")], modified: now)
        try writeSession(in: overflowRoot, uuid: "abababab-abab-4bab-8bab-abababababab",
            events: [rawTokenEvent(at: now, inputLiteral: "1", outputLiteral: "0")], modified: now)
        do {
            _ = try LocalCodexUsageReader.scan(directory: overflowRoot, now: now)
            check(false, "aggregate Int overflow is rejected")
        } catch {
            check(true, "aggregate Int overflow is rejected")
        }
        try? FileManager.default.removeItem(at: overflowRoot.deletingLastPathComponent())

        let boundedRoot = try fixtureDirectory("bounded-sessions")
        var pad = Data(repeating: 0x78, count: 256 * 1024 + 8)
        pad.append(10)
        for index in 0..<33 {
            let uuid = String(format: "dddddddd-dddd-4ddd-8ddd-%012d", index + 1)
            try writeSession(in: boundedRoot, uuid: uuid,
                events: [tokenEvent(at: now, input: 1, output: 1)],
                modified: now.addingTimeInterval(Double(index)), prefix: pad)
        }
        let boundedCache = LocalCodexUsageReader.Cache()
        let bounded = try LocalCodexUsageReader.scan(directory: boundedRoot, now: now, cache: boundedCache)
        check(bounded.sessionCount == 32 && bounded.isLimited,
            "scan selects at most 32 sessions, reads only each bounded tail, and marks omitted history")
        let warmBounded = try LocalCodexUsageReader.scan(directory: boundedRoot, now: now, cache: boundedCache)
        check(boundedCache.diagnostics.cacheHits == 32 && boundedCache.diagnostics.bytesRead == 0
            && boundedCache.entryCount == 32 && warmBounded.isLimited,
            "warm cache hits all 32 retained sessions without content reads and preserves tail limitation")
        try? FileManager.default.removeItem(at: boundedRoot.deletingLastPathComponent())

        let entryRoot = try fixtureDirectory("bounded-entries")
        for _ in 0..<5001 {
            let name = "rollout-fixture-\(UUID().uuidString).jsonl"
            try Data().write(to: entryRoot.appendingPathComponent(name))
        }
        let entryBound = try LocalCodexUsageReader.scan(directory: entryRoot, now: now)
        check(entryBound.isLimited && entryBound.filesScanned <= 5000,
            "directory enumeration beyond 5000 entries is bounded and reported")
        try? FileManager.default.removeItem(at: entryRoot.deletingLastPathComponent())

        let defaultConfiguration = AppConfiguration()
        check(defaultConfiguration.dataSource == "localCodex", "fresh desktop configuration defaults to local Codex data")
        let syntheticHome = FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-home-\(UUID().uuidString)")
        let syntheticCodex = FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-codex-\(UUID().uuidString)")
        let defaultLocalDirectory = LocalCodexUsageReader.defaultSessionsDirectory(environment: [:], home: syntheticHome)
        let overrideLocalDirectory = LocalCodexUsageReader.defaultSessionsDirectory(environment: ["CODEX_HOME": syntheticCodex.path], home: syntheticHome)
        check(defaultLocalDirectory.standardizedFileURL.path == syntheticHome.appendingPathComponent(".codex/sessions").standardizedFileURL.path
            && overrideLocalDirectory.standardizedFileURL.path == syntheticCodex.appendingPathComponent("sessions").standardizedFileURL.path,
            "local source resolves only the synthetic home or explicit absolute CODEX_HOME sessions path")
        let legacyPlist: [String: Any] = ["endpoint": "https://gateway.example/v1/chat/completions",
            "usageURL": "https://gateway.example/usage", "port": 18888]
        let legacyData = try PropertyListSerialization.data(fromPropertyList: legacyPlist, format: .xml, options: 0)
        let legacy = try PropertyListDecoder().decode(AppConfiguration.self, from: legacyData)
        check(legacy.dataSource == "proxy", "legacy explicit proxy configuration without source preserves proxy mode")
    }

    private static func fixtureDirectory(_ label: String) throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-\(label)-\(UUID().uuidString)", isDirectory: true)
        let directory = parent.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func sessionURL(in directory: URL, uuid: String) -> URL {
        directory.appendingPathComponent("rollout-fixture-\(uuid).jsonl")
    }

    private static func writeSession(in directory: URL, uuid: String, events: [Data], modified: Date,
                                     prefix: Data = Data(), suffix: Data = Data()) throws {
        var data = prefix
        for event in events { data.append(event); data.append(10) }
        data.append(suffix)
        let url = sessionURL(in: directory, uuid: uuid)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private static func tokenEvent(at timestamp: Date, input: Int, output: Int, cached: Int = 0,
                                   reasoning: Int = 0, rateLimits: [String: Any]? = nil) throws -> Data {
        var usage: [String: Any] = ["input_tokens": input, "output_tokens": output, "total_tokens": input + output]
        if cached > 0 { usage["cached_input_tokens"] = cached }
        if reasoning > 0 { usage["reasoning_output_tokens"] = reasoning }
        let info: [String: Any] = ["total_token_usage": usage]
        let event: [String: Any] = ["timestamp": iso(timestamp), "type": "event_msg",
            "payload": ["type": "token_count", "info": info, "rate_limits": rateLimits ?? [:]]]
        return try JSONSerialization.data(withJSONObject: event)
    }

    private static func rawTokenEvent(at timestamp: Date, inputLiteral: String, outputLiteral: String) -> Data {
        let time = iso(timestamp)
        return Data("{\"timestamp\":\"\(time)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(inputLiteral),\"output_tokens\":\(outputLiteral),\"total_tokens\":1}}}}".utf8)
    }

    private static func turnTokenEvent(at timestamp: Date, output: Int) throws -> Data {
        let event: [String: Any] = ["timestamp": iso(timestamp), "type": "event_msg",
            "payload": ["type": "token_count", "info": ["total_token_usage": [
                "input_tokens": 0, "output_tokens": output, "total_tokens": output]]]]
        return try JSONSerialization.data(withJSONObject: event)
    }

    private static func turnBoundary(at timestamp: Date, type: String, id: String,
                                     durationMS: Int? = nil, durationLiteral: String? = nil) throws -> Data {
        var payload: [String: Any] = ["type": type, "turn_id": id]
        if let durationMS { payload["duration_ms"] = durationMS }
        if durationLiteral == "true" { payload["duration_ms"] = true }
        else if durationLiteral == "null" { payload["duration_ms"] = NSNull() }
        else if let durationLiteral { payload["duration_ms"] = durationLiteral }
        let event: [String: Any] = ["timestamp": iso(timestamp), "type": "event_msg", "payload": payload]
        return try JSONSerialization.data(withJSONObject: event)
    }

    private static func rateLimits(fiveHour: Int?, sevenDay: Int?, reset: Date) -> [String: Any] {
        var value: [String: Any] = [:]
        if let fiveHour { value["primary"] = ["used_percent": fiveHour, "window_minutes": 300, "resets_at": reset.timeIntervalSince1970] }
        if let sevenDay { value["secondary"] = ["used_percent": sevenDay, "window_minutes": 10080, "resets_at": reset.timeIntervalSince1970] }
        return value
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
