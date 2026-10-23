import CoreFoundation
import Foundation
@testable import TokenStatCore

extension CoreChecks {
    static func localCodexUsageChecks() throws {
#if TOKENSTAT_BP38_C01
        try bp38C01LocalRefreshChecks()
#endif
        let now = Date(timeIntervalSince1970: 1_797_000_000)
        try bp39D01TypedChecks(now: now)

        // Seasun production mode must fail closed when the active Codex route
        // cannot be tied to Token Hub.  The legacy no-context scan below is
        // intentionally retained for source-independent fixtures.
        let routeRoot = try fixtureDirectory("seasun-route-filter")
        let routeMatchingID = "31313131-3131-4131-8131-313131313131"
        let routeOtherID = "32323232-3232-4232-8232-323232323232"
        try writeSession(in: routeRoot, uuid: routeMatchingID,
            events: [tokenEvent(at: now, input: 10, output: 5)], modified: now,
            metadataFields: ["model_provider": "seasun"])
        try writeSession(in: routeRoot, uuid: routeOtherID,
            events: [tokenEvent(at: now, input: 100, output: 50)], modified: now,
            metadataFields: ["model_provider": "other"])
        let verifiedRoute = LocalCodexRouteContext.verified(provider: "seasun", origin: "https://gateway.example")
        let routeFiltered = try LocalCodexUsageReader.scan(directory: routeRoot, now: now,
            cache: nil, routeContext: verifiedRoute)
        check(routeFiltered.input == 10 && routeFiltered.output == 5
            && routeFiltered.knownThreadCount == 1 && routeFiltered.unidentifiedFileCount == 1,
            "verified Seasun route includes only the matching Codex provider")
        let unverifiedRoute = try LocalCodexUsageReader.scan(directory: routeRoot, now: now,
            cache: nil, routeContext: .unverified)
        check(unverifiedRoute.total == 0 && unverifiedRoute.knownThreadCount == 0
            && !unverifiedRoute.hasCompleteAccounting,
            "unproven Seasun route never mixes local Codex totals")
        try? FileManager.default.removeItem(at: routeRoot.deletingLastPathComponent())

        let liveRoot = try fixtureDirectory("live-output-speed")
        try writeSession(in: liveRoot, uuid: "33333333-3333-4333-8333-333333333333", events: [
            turnTokenEvent(at: now.addingTimeInterval(-5), output: 10),
            turnBoundary(at: now.addingTimeInterval(-4), type: "task_started", id: "live"),
            turnTokenEvent(at: now.addingTimeInterval(-2), output: 30),
            turnTokenEvent(at: now.addingTimeInterval(-1), output: 50)
        ], modified: now)
        let liveCache = LocalCodexUsageReader.Cache()
        let live = try LocalCodexUsageReader.scan(directory: liveRoot, now: now, cache: liveCache)
        check(live.liveTurn?.outputTPS == 20 && live.liveTurn?.inputTPS == 0,
            "active cumulative token_count events produce a live output TPS estimate")
        let staleLive = try LocalCodexUsageReader.scan(directory: liveRoot,
            now: now.addingTimeInterval(20), cache: liveCache)
        check(staleLive.liveTurn == nil,
            "live output TPS expires when the latest token_count event is stale")
        try? FileManager.default.removeItem(at: liveRoot.deletingLastPathComponent())

        let malformedLiveRoot = try fixtureDirectory("live-output-malformed")
        try writeSession(in: malformedLiveRoot, uuid: "34343434-3434-4434-8434-343434343434", events: [
            turnTokenEvent(at: now.addingTimeInterval(-3), output: 10),
            turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "malformed-live"),
            turnTokenEvent(at: now.addingTimeInterval(-1.5), output: 20),
            turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 25),
            rawTokenEvent(at: now, inputLiteral: "null", outputLiteral: "30")
        ], modified: now)
        let malformedLive = try LocalCodexUsageReader.scan(directory: malformedLiveRoot, now: now)
        check(malformedLive.liveTurn == nil,
            "malformed cumulative usage in an active turn keeps live speed unknown")
        try? FileManager.default.removeItem(at: malformedLiveRoot.deletingLastPathComponent())

        try localLiveIntegrityChecks(now: now)

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
        check(aggregate.input == 4 && aggregate.output == 6 && aggregate.total == 10,
            "a root counter reset is excluded instead of being reported as complete accounting")
        check(aggregate.sessionCount == 2 && aggregate.latestEventAt == now.addingTimeInterval(-60),
            "local Codex reports metadata-backed top-level count and latest event timestamp")
        check(aggregate.knownThreadCount == 1 && aggregate.unknownThreadCount == 1
            && aggregate.unidentifiedFileCount == 0 && !aggregate.hasCompleteAccounting,
            "a root reset marks only the affected thread unknown")
        check(aggregate.input == 4 && aggregate.output == 6,
            "cached input and reasoning output subfields are not added twice")
        let rescanned = try LocalCodexUsageReader.scan(directory: aggregateRoot, now: now)
        check(rescanned.input == aggregate.input && rescanned.output == aggregate.output
            && rescanned.total == aggregate.total && rescanned.sessionCount == aggregate.sessionCount,
            "repeated local Codex scans replace the snapshot instead of accumulating it")
        let reflectedFields = Set(Mirror(reflecting: aggregate).children.compactMap(\.label))
        check(reflectedFields == Set(["input", "output", "total", "sessionCount", "filesScanned",
            "isLimited", "latestEventAt", "fiveHour", "sevenDay", "lastTurn", "liveTurn", "knownThreadCount",
            "unknownThreadCount", "unidentifiedFileCount", "subagentCount", "forkCount", "readAt", "details",
            "cacheCoverage", "detailLimited", "quotaDate"]),
            "DM-A06 local Codex snapshot reflection exposes only the bounded metadata plus four DM-A fields")

        let exactZeroRoot = try fixtureDirectory("metadata-backed-exact-zero")
        try writeSession(in: exactZeroRoot, uuid: "12121212-1212-4212-8212-121212121213",
            events: [tokenEvent(at: now, input: 0, output: 0)], modified: now)
        let exactZero = try LocalCodexUsageReader.scan(directory: exactZeroRoot, now: now)
        check(exactZero.knownThreadCount == 1 && exactZero.hasCompleteAccounting
            && exactZero.total == 0,
            "a metadata-backed known zero is distinguishable from absence of any known thread")
        try? FileManager.default.removeItem(at: exactZeroRoot.deletingLastPathComponent())

        let noFinalLFRoot = try fixtureDirectory("complete-no-final-lf")
        let noFinalLFID = "13131313-1313-4313-8313-131313131313"
        try writeSession(in: noFinalLFRoot, uuid: noFinalLFID,
            events: [tokenEvent(at: now.addingTimeInterval(-1), input: 7, output: 5)],
            modified: now, finalNewline: false)
        let noFinalLF = try LocalCodexUsageReader.scan(directory: noFinalLFRoot, now: now)
        check(noFinalLF.input == 7 && noFinalLF.output == 5 && noFinalLF.total == 12
            && noFinalLF.knownThreadCount == 1 && noFinalLF.hasCompleteAccounting,
            "a complete final JSONL event is retained without a trailing LF")
        try? FileManager.default.removeItem(at: noFinalLFRoot.deletingLastPathComponent())

        let truncatedFinalRoot = try fixtureDirectory("truncated-final-no-lf")
        let truncatedFinalID = "14141414-1414-4414-8414-141414141414"
        try writeSession(in: truncatedFinalRoot, uuid: truncatedFinalID,
            events: [tokenEvent(at: now.addingTimeInterval(-2), input: 3, output: 2)],
            modified: now, suffix: Data("{\"type\":\"event_msg\"".utf8), finalNewline: false)
        let truncatedFinal = try LocalCodexUsageReader.scan(directory: truncatedFinalRoot, now: now)
        check(truncatedFinal.input == 0 && truncatedFinal.output == 0 && truncatedFinal.total == 0
            && !truncatedFinal.hasCompleteAccounting,
            "a malformed final no-LF fragment remains unknown instead of being counted")
        try? FileManager.default.removeItem(at: truncatedFinalRoot.deletingLastPathComponent())

        let noEvidenceRoot = try fixtureDirectory("no-accounting-evidence")
        let noEvidence = try LocalCodexUsageReader.scan(directory: noEvidenceRoot, now: now)
        check(noEvidence.knownThreadCount == 0 && noEvidence.unknownThreadCount == 0
            && noEvidence.unidentifiedFileCount == 0 && !noEvidence.hasCompleteAccounting,
            "no files is unknown coverage, not a complete exact zero")
        try? FileManager.default.removeItem(at: noEvidenceRoot.deletingLastPathComponent())

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
            ("missing-start-timestamp-with-duration", [turnTokenEvent(at: now.addingTimeInterval(-2), output: 1),
                turnBoundaryWithoutTimestamp(type: "task_started", id: "x"),
                turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 2),
                turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)]),
            ("missing-baseline-timestamp-with-duration", [turnTokenEventWithoutTimestamp(output: 1),
                turnBoundary(at: now.addingTimeInterval(-1), type: "task_started", id: "x"),
                turnTokenEvent(at: now.addingTimeInterval(-0.5), output: 2),
                turnBoundary(at: now, type: "task_complete", id: "x", durationMS: 1000)]),
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
        check(afterRollback.lastTurn == nil && rollbackCache.diagnostics.cacheHits == 0
            && rollbackCache.diagnostics.parsedFiles == 1,
            "clock rollback reparses cached evidence and revalidates completion time")
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
        if let range = sameSizeRewrite.range(of: Data("\"total_tokens\":7".utf8)) {
            sameSizeRewrite.replaceSubrange(range, with: Data("\"total_tokens\":8".utf8))
        } else {
            check(false, "same-size cache rewrite fixture locates the matching total count")
        }
        try sameSizeRewrite.write(to: cachedPath)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(2)], ofItemAtPath: cachedPath.path)
        let rewrittenCache = try LocalCodexUsageReader.scan(directory: cacheRoot, now: now, cache: cache)
        check(rewrittenCache.input == 4 && rewrittenCache.output == 4 && cache.diagnostics.cacheHits == 0,
            "same-size rewrite with changed file metadata invalidates cached summary")
        var truncatedBytes = try Data(contentsOf: cachedPath)
        truncatedBytes.removeLast(min(10, truncatedBytes.count))
        try truncatedBytes.write(to: cachedPath)
        let truncatedCache = try LocalCodexUsageReader.scan(directory: cacheRoot, now: now, cache: cache)
        check(truncatedCache.input == 0 && truncatedCache.output == 0
            && truncatedCache.knownThreadCount == 0 && truncatedCache.unknownThreadCount == 1
            && !truncatedCache.hasCompleteAccounting
            && cache.diagnostics.cacheHits == 0 && cache.diagnostics.bytesRead > 0,
            "truncating a cached latest cumulative line reparses and makes the thread unknown")
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
            events: [tokenEvent(at: now.addingTimeInterval(-10), input: 8, output: 9)], modified: now,
            metadataID: duplicateID.uppercased())
        let uppercaseFixture = sessionURL(in: duplicateRoot, uuid: duplicateID.uppercased())
        try FileManager.default.moveItem(at: uppercaseFixture,
            to: duplicateRoot.appendingPathComponent("rollout-alias-\(duplicateID.uppercased()).jsonl"))
        let duplicate = try LocalCodexUsageReader.scan(directory: duplicateRoot, now: now)
        check(duplicate.sessionCount == 0 && duplicate.knownThreadCount == 0
            && duplicate.unknownThreadCount == 1 && !duplicate.hasCompleteAccounting,
            "same metadata UUID with non-identical rollouts is an unknown conflict group, never an mtime winner")
        try? FileManager.default.removeItem(at: duplicateRoot.deletingLastPathComponent())

        let identicalRoot = try fixtureDirectory("byte-identical-rollout-copy")
        let identicalID = "abab2222-2222-4222-8222-222222222222"
        try writeSession(in: identicalRoot, uuid: identicalID,
            events: [tokenEvent(at: now, input: 8, output: 9)], modified: now)
        let original = sessionURL(in: identicalRoot, uuid: identicalID)
        let copy = identicalRoot.appendingPathComponent("rollout-copy-ffffffff-ffff-4fff-8fff-ffffffffffff.jsonl")
        try FileManager.default.copyItem(at: original, to: copy)
        let identical = try LocalCodexUsageReader.scan(directory: identicalRoot, now: now)
        check(identical.knownThreadCount == 1 && identical.unknownThreadCount == 0
            && identical.input == 8 && identical.output == 9,
            "complete byte-identical physical rollouts collapse to one known logical thread")
        let hardlink = identicalRoot.appendingPathComponent("rollout-hardlink.jsonl")
        try FileManager.default.linkItem(at: original, to: hardlink)
        let hardlinked = try LocalCodexUsageReader.scan(directory: identicalRoot, now: now)
        check(hardlinked.knownThreadCount == 1 && hardlinked.unknownThreadCount == 0
            && hardlinked.input == 8 && hardlinked.output == 9,
            "hardlinked physical paths collapse by inode identity")
        try? FileManager.default.removeItem(at: identicalRoot.deletingLastPathComponent())

        let unprovenDuplicateRoot = try fixtureDirectory("duplicate-unproven-middle")
        let unprovenID = "abab2323-2323-4323-8323-232323232323"
        var firstMiddle = Data(repeating: 0x61, count: 400 * 1024)
        var secondMiddle = firstMiddle
        secondMiddle.replaceSubrange(100 * 1024..<100 * 1024 + 1, with: [0x62])
        firstMiddle.append(10)
        secondMiddle.append(10)
        let unprovenSecondName = "rollout-copy-\(unprovenID).jsonl"
        let unprovenFirstName = "rollout-primary-\(unprovenID).jsonl"
        try writeSession(in: unprovenDuplicateRoot, uuid: unprovenID,
            events: [tokenEvent(at: now, input: 8, output: 9)], modified: now,
            prefix: firstMiddle)
        try FileManager.default.moveItem(at: sessionURL(in: unprovenDuplicateRoot, uuid: unprovenID),
            to: unprovenDuplicateRoot.appendingPathComponent(unprovenFirstName))
        try writeSession(in: unprovenDuplicateRoot, uuid: unprovenID.uppercased(),
            events: [tokenEvent(at: now, input: 8, output: 9)], modified: now,
            prefix: secondMiddle, metadataID: unprovenID)
        try FileManager.default.moveItem(at: sessionURL(in: unprovenDuplicateRoot, uuid: unprovenID.uppercased()),
            to: unprovenDuplicateRoot.appendingPathComponent(unprovenSecondName))
        let unprovenDuplicate = try LocalCodexUsageReader.scan(directory: unprovenDuplicateRoot, now: now)
        check(unprovenDuplicate.knownThreadCount == 0 && unprovenDuplicate.unknownThreadCount == 1,
            "matching bounded head and tail cannot prove whole-file identity when middle bytes differ")
        try? FileManager.default.removeItem(at: unprovenDuplicateRoot.deletingLastPathComponent())

        let identityRoot = try fixtureDirectory("metadata-identity-and-classification")
        let identities = [
            ("15151515-1515-4515-8515-151515151515", "cli" as Any?),
            ("16161616-1616-4616-8616-161616161616", "vscode" as Any?),
            ("17171717-1717-4717-8717-171717171717", "exec" as Any?),
            ("18181818-1818-4818-8818-181818181818", "mcp" as Any?)
        ]
        for item in identities {
            try writeSession(in: identityRoot, uuid: item.0,
                events: [tokenEvent(at: now, input: 1, output: 2)], modified: now,
                metadataSource: item.1)
        }
        let laterAncestorID = "19191919-1919-4919-8919-191919191919"
        let childID = "20202020-2020-4020-8020-202020202020"
        let ancestorMeta = sessionMetadata(id: laterAncestorID, source: "cli")
        try writeSession(in: identityRoot, uuid: "21212121-2121-4121-8121-212121212121",
            events: [ancestorMeta, tokenEvent(at: now, input: 3, output: 4)], modified: now,
            metadataID: childID, metadataSource: ["subagent": "review"],
            metadataFields: ["parent_thread_id": firstID])
        let unidentifiedMetadata = try fixtureDirectory("metadata-unidentified-files")
        try writeSession(in: unidentifiedMetadata, uuid: "22222222-2222-4222-8222-222222222222",
            events: [tokenEvent(at: now, input: 9, output: 9)], modified: now,
            metadata: sessionMetadata(id: nil, source: "cli"))
        try writeSession(in: unidentifiedMetadata, uuid: "23232323-2323-4323-8323-232323232323",
            events: [tokenEvent(at: now, input: 8, output: 8)], modified: now,
            metadata: tokenEvent(at: now, input: 0, output: 0))
        try writeSession(in: unidentifiedMetadata, uuid: "24242424-2424-4424-8424-242424242424",
            events: [tokenEvent(at: now, input: 7, output: 7)], modified: now,
            metadataID: "not-a-uuid", metadataSource: "cli")
        try writeSession(in: unidentifiedMetadata, uuid: "25252525-2525-4525-8525-252525252525",
            events: [tokenEvent(at: now, input: 6, output: 6)], modified: now,
            metadataSource: "futureSource")
        try writeSession(in: unidentifiedMetadata, uuid: "26262626-2626-4626-8626-262626262626",
            events: [tokenEvent(at: now, input: 5, output: 5)], modified: now, metadataSource: nil)
        try writeSession(in: unidentifiedMetadata, uuid: "27272727-2727-4727-8727-272727272727",
            events: [tokenEvent(at: now, input: 4, output: 4)], modified: now,
            metadataSource: ["custom": ["name": "fixture"]])
        try writeSession(in: unidentifiedMetadata, uuid: "28282828-2828-4828-8828-282828282828",
            events: [tokenEvent(at: now, input: 3, output: 3)], modified: now,
            metadataSource: ["internal": "fixture"])
        try writeSession(in: unidentifiedMetadata, uuid: "29292929-2929-4929-8929-292929292929",
            events: [tokenEvent(at: now, input: 2, output: 2)], modified: now,
            metadataSource: ["subagent": "unsupported_kind"])
        let classified = try LocalCodexUsageReader.scan(directory: identityRoot, now: now)
        let unclassified = try LocalCodexUsageReader.scan(directory: unidentifiedMetadata, now: now)
        check(classified.knownThreadCount == 4 && classified.subagentCount == 1
            && classified.sessionCount == 4 && classified.input == 4 && classified.output == 8
            && classified.unknownThreadCount == 1,
            "recognized child source without a provable fork baseline remains unknown while first metadata identity is retained")
        check(unclassified.knownThreadCount == 0 && unclassified.unknownThreadCount == 5
            && unclassified.unidentifiedFileCount == 3
            && unclassified.sessionCount == 0 && !unclassified.hasCompleteAccounting,
            "missing, invalid, non-first, and unknown-source metadata never falls back to filename identity or root classification")
        let optionalSubagentRoot = try fixtureDirectory("subagent-optional-display-metadata")
        let optionalSubagentID = "2d2d2d2d-2d2d-4d2d-8d2d-2d2d2d2d2d2d"
        try writeSession(in: optionalSubagentRoot, uuid: optionalSubagentID,
            events: [tokenEvent(at: now, input: 4, output: 5)], modified: now,
            metadataID: optionalSubagentID, metadataSource: ["subagent": "review"],
            metadataFields: ["agent_nickname": "Synthetic Reviewer", "agent_role": "review"])
        let optionalSubagent = try LocalCodexUsageReader.scan(directory: optionalSubagentRoot, now: now)
        check(optionalSubagent.knownThreadCount == 0 && optionalSubagent.unknownThreadCount == 1
            && optionalSubagent.subagentCount == 1 && optionalSubagent.sessionCount == 0
            && optionalSubagent.input == 0 && optionalSubagent.output == 0,
            "recognized child classification with optional display metadata remains a subagent while missing lineage baseline is unknown")
        try? FileManager.default.removeItem(at: optionalSubagentRoot.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: identityRoot.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: unidentifiedMetadata.deletingLastPathComponent())

        let strictSourceCases: [(String, Any)] = [
            ("uppercase root source", "CLI"),
            ("subagent-like root string", "subagent_review"),
            ("internal-like root string", "internal_guardian"),
            ("object root source", ["cli": true]),
            ("invalid nested parent UUID", ["subagent": ["thread_spawn": ["parent_thread_id": "badUUID", "depth": 1]]]),
            ("boolean nested depth", ["subagent": ["thread_spawn": ["parent_thread_id": firstID, "depth": true]]]),
            ("overflow nested depth", ["subagent": ["thread_spawn": ["parent_thread_id": firstID, "depth": 2_147_483_648]]]),
            ("uint64 maximum nested depth", ["subagent": ["thread_spawn": ["parent_thread_id": firstID, "depth": NSNumber(value: UInt64.max)]]])
        ]
        for (index, testCase) in strictSourceCases.enumerated() {
            let strictSourceRoot = try fixtureDirectory("strict-source-\(index)")
            let id = String(format: "2c2c2c2c-2c2c-4c2c-8c2c-%012d", index + 1)
            try writeSession(in: strictSourceRoot, uuid: id,
                events: [tokenEvent(at: now, input: 4, output: 5)], modified: now,
                metadataID: id, metadataSource: testCase.1)
            let strictSource = try LocalCodexUsageReader.scan(directory: strictSourceRoot, now: now)
            check(strictSource.knownThreadCount == 0 && strictSource.unknownThreadCount == 1
                && strictSource.sessionCount == 0 && strictSource.subagentCount == 0,
                "strict metadata source rejects \(testCase.0) instead of classifying a root")
            try? FileManager.default.removeItem(at: strictSourceRoot.deletingLastPathComponent())
        }

        let lateMetadataRoot = try fixtureDirectory("metadata-after-head-limit")
        let lateMetadataRecord = sessionMetadata(id: "2a2a2a2a-2a2a-4a2a-8a2a-2a2a2a2a2a2a", source: "cli")
        var firstCompleteRecord = Data("{\"type\":\"unrelated\",\"padding\":\"".utf8)
        firstCompleteRecord.append(Data(repeating: 0x61, count: 70 * 1024))
        firstCompleteRecord.append(Data("\"}\n".utf8))
        var oversizedMetadata = lateMetadataRecord
        oversizedMetadata.append(10)
        firstCompleteRecord.append(oversizedMetadata)
        try writeSession(in: lateMetadataRoot, uuid: "2a2a2a2a-2a2a-4a2a-8a2a-2a2a2a2a2a2a",
            events: [tokenEvent(at: now, input: 1, output: 1)], modified: now,
            metadata: firstCompleteRecord)
        let lateMetadataSnapshot = try LocalCodexUsageReader.scan(directory: lateMetadataRoot, now: now)
        check(lateMetadataSnapshot.unidentifiedFileCount == 1 && lateMetadataSnapshot.knownThreadCount == 0,
            "first metadata outside the bounded head cannot establish identity by later search")
        try? FileManager.default.removeItem(at: lateMetadataRoot.deletingLastPathComponent())

        for (label, firstRecord) in [("blank", Data(" \n".utf8)),
                                     ("non-meta", try tokenEvent(at: now, input: 0, output: 0))] {
            let firstRecordRoot = try fixtureDirectory("first-record-\(label)")
            try writeSession(in: firstRecordRoot, uuid: "2b2b2b2b-2b2b-4b2b-8b2b-2b2b2b2b2b2b",
                events: [tokenEvent(at: now, input: 1, output: 1)], modified: now,
                metadata: firstRecord)
            let firstRecordSnapshot = try LocalCodexUsageReader.scan(directory: firstRecordRoot, now: now)
            check(firstRecordSnapshot.unidentifiedFileCount == 1 && firstRecordSnapshot.knownThreadCount == 0,
                "\(label) first complete physical record is not skipped to recover a later metadata identity")
            try? FileManager.default.removeItem(at: firstRecordRoot.deletingLastPathComponent())
        }

        let forkRoot = try fixtureDirectory("fork-explicit-boundary")
        let parentID = "30303030-3030-4030-8030-303030303030"
        let forkID = "31313131-3131-4131-8131-313131313131"
        try writeSession(in: forkRoot, uuid: parentID,
            events: [tokenEvent(at: now.addingTimeInterval(-5), input: 100, output: 50)], modified: now,
            metadataSource: "cli")
        let spawnSource: [String: Any] = ["subagent": ["thread_spawn": ["parent_thread_id": parentID, "depth": 1]]]
        try writeSession(in: forkRoot, uuid: forkID, events: [
            tokenEvent(at: now.addingTimeInterval(-4), input: 100, output: 50), // ordinal 1: inherited
            ordinaryEvent(at: now.addingTimeInterval(-3), type: "user_message"), // ordinal 2
            tokenEvent(at: now.addingTimeInterval(-2), input: 110, output: 55), // ordinal 3: exclusive boundary is first own record
            tokenEvent(at: now.addingTimeInterval(-1), input: 120, output: 60), // ordinal 4: child continues
            sessionMetadata(id: parentID, source: "cli"), // copied ancestor must not replace ordinal-0 child identity
            tokenEvent(at: now, input: 130, output: 65)
        ], modified: now, metadataID: forkID, metadataSource: spawnSource,
            metadataFields: ["parent_thread_id": parentID, "subagent_history_start_ordinal": 3])
        let forked = try LocalCodexUsageReader.scan(directory: forkRoot, now: now)
        check(forked.input == 130 && forked.output == 65 && forked.total == 195
            && forked.knownThreadCount == 2 && forked.subagentCount == 1 && forked.forkCount == 1
            && forked.sessionCount == 1 && forked.hasCompleteAccounting,
            "parent plus explicit copied-fork delta excludes inherited baseline once and preserves first metadata identity")
        try? FileManager.default.removeItem(at: forkRoot.deletingLastPathComponent())

        let settingsForkRoot = try fixtureDirectory("fork-thread-settings-boundary")
        let settingsForkID = "32323232-3232-4232-8232-323232323232"
        let settingsBoundary = try threadSettingsApplied(at: now.addingTimeInterval(-2), threadID: settingsForkID)
        try writeSession(in: settingsForkRoot, uuid: settingsForkID, events: [
            tokenEvent(at: now.addingTimeInterval(-3), input: 40, output: 20), // baseline before boundary
            settingsBoundary, // own thread boundary
            tokenEvent(at: now.addingTimeInterval(-1), input: 55, output: 30),
            tokenEvent(at: now, input: 60, output: 32)
        ], modified: now, metadataID: settingsForkID, metadataSource: spawnSource,
            metadataFields: ["parent_thread_id": parentID])
        let settingsFork = try LocalCodexUsageReader.scan(directory: settingsForkRoot, now: now)
        check(settingsFork.input == 20 && settingsFork.output == 12 && settingsFork.total == 32
            && settingsFork.knownThreadCount == 1 && settingsFork.subagentCount == 1
            && settingsFork.forkCount == 1 && settingsFork.sessionCount == 0,
            "thread_settings_applied boundary matches current thread and counts only post-baseline delta")
        try? FileManager.default.removeItem(at: settingsForkRoot.deletingLastPathComponent())

        let quotaOnlyForkRoot = try fixtureDirectory("fork-quota-only-token-event")
        let quotaOnlyForkID = "32323232-3232-4232-8232-323232323233"
        let forkQuotaLimits: [String: Any] = ["primary": ["used_percent": 45, "window_minutes": 300]]
        try writeSession(in: quotaOnlyForkRoot, uuid: quotaOnlyForkID, events: [
            tokenEvent(at: now.addingTimeInterval(-4), input: 100, output: 50),
            ordinaryEvent(at: now.addingTimeInterval(-3), type: "user_message"),
            tokenEvent(at: now.addingTimeInterval(-2), input: 110, output: 55),
            quotaOnlyEvent(at: now.addingTimeInterval(-1), rateLimits: forkQuotaLimits),
            tokenEvent(at: now, input: 120, output: 60)
        ], modified: now, metadataID: quotaOnlyForkID, metadataSource: "cli",
            metadataFields: ["parent_thread_id": parentID, "subagent_history_start_ordinal": 2])
        let quotaOnlyFork = try LocalCodexUsageReader.scan(directory: quotaOnlyForkRoot, now: now)
        check(quotaOnlyFork.input == 20 && quotaOnlyFork.output == 10 && quotaOnlyFork.total == 30
            && quotaOnlyFork.knownThreadCount == 1 && quotaOnlyFork.unknownThreadCount == 0
            && quotaOnlyFork.forkCount == 1 && quotaOnlyFork.sessionCount == 0
            && quotaOnlyFork.fiveHour?.usedPercent == 45,
            "quota-only token_count between cumulative fork counters does not poison the child delta")
        try? FileManager.default.removeItem(at: quotaOnlyForkRoot.deletingLastPathComponent())

        let resumeSettingsRoot = try fixtureDirectory("fork-resume-settings")
        let resumeID = "33333333-3333-4333-8333-333333333334"
        try writeSession(in: resumeSettingsRoot, uuid: resumeID, events: [
            tokenEvent(at: now.addingTimeInterval(-4), input: 40, output: 20),
            threadSettingsApplied(at: now.addingTimeInterval(-3), threadID: resumeID),
            tokenEvent(at: now.addingTimeInterval(-2), input: 55, output: 30),
            threadSettingsApplied(at: now.addingTimeInterval(-1), threadID: resumeID), // resume is not a new boundary
            tokenEvent(at: now, input: 60, output: 32)
        ], modified: now, metadataID: resumeID, metadataSource: spawnSource,
            metadataFields: ["parent_thread_id": parentID])
        let resumedSettingsFork = try LocalCodexUsageReader.scan(directory: resumeSettingsRoot, now: now)
        check(resumedSettingsFork.input == 20 && resumedSettingsFork.output == 12
            && resumedSettingsFork.knownThreadCount == 1 && resumedSettingsFork.unknownThreadCount == 0,
            "later matching resume settings do not invalidate the first own initialization boundary")
        try? FileManager.default.removeItem(at: resumeSettingsRoot.deletingLastPathComponent())

        let wrongSettingsRoot = try fixtureDirectory("fork-wrong-settings-thread")
        let wrongSettingsID = "33333333-3333-4333-8333-333333333335"
        try writeSession(in: wrongSettingsRoot, uuid: wrongSettingsID, events: [
            tokenEvent(at: now.addingTimeInterval(-3), input: 40, output: 20),
            threadSettingsApplied(at: now.addingTimeInterval(-2), threadID: parentID),
            tokenEvent(at: now.addingTimeInterval(-1), input: 55, output: 30),
            threadSettingsApplied(at: now, threadID: wrongSettingsID),
            tokenEvent(at: now.addingTimeInterval(1), input: 60, output: 32)
        ], modified: now, metadataID: wrongSettingsID, metadataSource: spawnSource,
            metadataFields: ["parent_thread_id": parentID])
        let wrongSettingsFork = try LocalCodexUsageReader.scan(directory: wrongSettingsRoot, now: now.addingTimeInterval(1))
        check(wrongSettingsFork.input == 5 && wrongSettingsFork.output == 2
            && wrongSettingsFork.knownThreadCount == 1,
            "thread settings for another thread are ignored and preceding cumulative usage remains the baseline")
        try? FileManager.default.removeItem(at: wrongSettingsRoot.deletingLastPathComponent())

        let contradictoryBoundaryRoot = try fixtureDirectory("fork-contradictory-boundary")
        let contradictoryID = "33333333-3333-4333-8333-333333333336"
        try writeSession(in: contradictoryBoundaryRoot, uuid: contradictoryID, events: [
            tokenEvent(at: now.addingTimeInterval(-3), input: 40, output: 20),
            threadSettingsApplied(at: now.addingTimeInterval(-2), threadID: contradictoryID),
            tokenEvent(at: now.addingTimeInterval(-1), input: 55, output: 30),
            tokenEvent(at: now, input: 60, output: 32)
        ], modified: now, metadataID: contradictoryID, metadataSource: spawnSource,
            metadataFields: ["parent_thread_id": parentID, "subagent_history_start_ordinal": 3])
        let contradictoryBoundary = try LocalCodexUsageReader.scan(directory: contradictoryBoundaryRoot, now: now)
        check(contradictoryBoundary.knownThreadCount == 0 && contradictoryBoundary.unknownThreadCount == 1,
            "explicit ordinal and first matching own settings boundary disagreement makes the fork unknown")
        try? FileManager.default.removeItem(at: contradictoryBoundaryRoot.deletingLastPathComponent())

        let gapForkRoot = try fixtureDirectory("fork-unobserved-middle-gap")
        let gapForkID = "34343434-3434-4434-8434-343434343434"
        var gapPrefix = Data()
        gapPrefix.append(try ordinaryEvent(at: now.addingTimeInterval(-10), type: "user_message")) // ordinal 1
        gapPrefix.append(10)
        gapPrefix.append(try tokenEvent(at: now.addingTimeInterval(-9), input: 100, output: 50)) // ordinal 2 baseline
        gapPrefix.append(10)
        gapPrefix.append(try tokenEvent(at: now.addingTimeInterval(-8.5), input: 101, output: 51)) // ordinal 3 first own record
        gapPrefix.append(10)
        for index in 0..<5_000 {
            gapPrefix.append(try tokenEvent(at: now.addingTimeInterval(-8 + Double(index) / 10_000),
                input: 102 + index, output: 52 + index))
            gapPrefix.append(10)
        }
        try writeSession(in: gapForkRoot, uuid: gapForkID,
            events: [tokenEvent(at: now, input: 5_101, output: 5_051)], modified: now,
            prefix: gapPrefix, metadataID: gapForkID, metadataSource: spawnSource,
            metadataFields: ["parent_thread_id": parentID, "subagent_history_start_ordinal": 3])
        let gapFork = try LocalCodexUsageReader.scan(directory: gapForkRoot, now: now)
        check(gapFork.knownThreadCount == 0 && gapFork.unknownThreadCount == 1
            && gapFork.isLimited && !gapFork.hasCompleteAccounting,
            "fork contribution is unknown when bounded head/tail reads leave an unobserved cumulative gap")
        try? FileManager.default.removeItem(at: gapForkRoot.deletingLastPathComponent())

        let invalidForkEvidence: [(String, [Data])] = try [
            ("missing", [ordinaryEvent(at: now.addingTimeInterval(-2), type: "user_message"),
                ordinaryEvent(at: now.addingTimeInterval(-1), type: "assistant_reasoning"),
                tokenEvent(at: now, input: 55, output: 65)]),
            ("input rollback", [tokenEvent(at: now.addingTimeInterval(-3), input: 40, output: 20),
                tokenEvent(at: now.addingTimeInterval(-1), input: 39, output: 21),
                tokenEvent(at: now, input: 45, output: 25)]),
            ("output rollback", [tokenEvent(at: now.addingTimeInterval(-3), input: 40, output: 20),
                tokenEvent(at: now.addingTimeInterval(-1), input: 41, output: 19),
                tokenEvent(at: now, input: 45, output: 25)]),
            ("input missing", [tokenEvent(at: now.addingTimeInterval(-3), input: 40, output: 20),
                rawTokenEvent(at: now.addingTimeInterval(-1), inputLiteral: "null", outputLiteral: "21", totalLiteral: "42"),
                tokenEvent(at: now, input: 45, output: 25)]),
            ("output missing", [tokenEvent(at: now.addingTimeInterval(-3), input: 40, output: 20),
                rawTokenEvent(at: now.addingTimeInterval(-1), inputLiteral: "41", outputLiteral: "null", totalLiteral: "42"),
                tokenEvent(at: now, input: 45, output: 25)]),
            ("total missing", [tokenEvent(at: now.addingTimeInterval(-3), input: 40, output: 20),
                rawTokenEvent(at: now.addingTimeInterval(-1), inputLiteral: "41", outputLiteral: "21", totalLiteral: "null"),
                tokenEvent(at: now, input: 45, output: 25)]),
            ("total rollback", [tokenEvent(at: now.addingTimeInterval(-3), input: 40, output: 20),
                rawTokenEvent(at: now.addingTimeInterval(-1), inputLiteral: "41", outputLiteral: "21", totalLiteral: "1"),
                tokenEvent(at: now, input: 45, output: 25)])
        ]
        for (label, records) in invalidForkEvidence {
            let missingBaselineRoot = try fixtureDirectory("fork-invalid-baseline-\(label)")
            let missingBaselineID = "35353535-3535-4535-8535-353535353535"
            try writeSession(in: missingBaselineRoot, uuid: missingBaselineID, events: records, modified: now,
                metadataID: missingBaselineID, metadataSource: spawnSource,
                metadataFields: ["parent_thread_id": parentID, "subagent_history_start_ordinal": 3])
            let missingBaseline = try LocalCodexUsageReader.scan(directory: missingBaselineRoot, now: now)
            check(missingBaseline.knownThreadCount == 0 && missingBaseline.unknownThreadCount == 1
                && missingBaseline.input == 0,
                "fork with \(label) baseline evidence is unknown, not a guessed contribution")
            try? FileManager.default.removeItem(at: missingBaselineRoot.deletingLastPathComponent())
        }

        let quotaUpdateRoot = try fixtureDirectory("quota-update-contract")
        let quotaTime = now.addingTimeInterval(-30)
        let validLimits: [String: Any] = [
            "primary": ["used_percent": 25, "window_minutes": 300, "resets_at": Int(now.timeIntervalSince1970) + 3600],
            "secondary": ["used_percent": 70, "window_minutes": 10080, "resets_at": Int(now.timeIntervalSince1970) + 7200]
        ]
        let duplicateDurations: [String: Any] = [
            "primary": ["used_percent": 10, "window_minutes": 300],
            "secondary": ["used_percent": 90, "window_minutes": 300]
        ]
        try writeSession(in: quotaUpdateRoot, uuid: "36363636-3636-4636-8636-363636363636", events: [
            tokenEvent(at: quotaTime, input: 1, output: 1, rateLimits: validLimits)
        ], modified: now)
        func appendQuotaFixture(_ suffix: Int, _ timestamp: Date, _ value: Any?) throws -> LocalCodexSnapshot {
            let uuid = String(format: "37373737-3737-4737-8737-%012d", suffix)
            try writeSession(in: quotaUpdateRoot, uuid: uuid, events: [
                tokenEvent(at: timestamp, input: suffix, output: suffix, rateLimits: value)
            ], modified: now, metadataID: uuid)
            return try LocalCodexUsageReader.scan(directory: quotaUpdateRoot, now: now)
        }
        let preservedCases: [(String, Any?)] = [
            ("missing", nil), ("null", NSNull()), ("non-object", "not-an-object"),
            ("unrelated", ["other": ["used_percent": 99]]),
            ("boolean percent", ["primary": ["used_percent": true, "window_minutes": 300]]),
            ("out-of-range percent", ["primary": ["used_percent": 101, "window_minutes": 300]]),
            ("boolean duration", ["primary": ["used_percent": 40, "window_minutes": true]]),
            ("duplicate duration", duplicateDurations),
            ("negative reset", ["primary": ["used_percent": 40, "window_minutes": 300, "resets_at": -1]]),
            ("fractional reset", ["primary": ["used_percent": 40, "window_minutes": 300, "resets_at": 1.5]]),
            ("null slot", ["primary": NSNull(), "secondary": NSNull()]),
            ("non-object slot", ["primary": "invalid"]),
            ("missing used percent", ["primary": ["window_minutes": 300]])
        ]
        var quotaCheckIndex = 0
        for (label, value) in preservedCases {
            if label == "null slot" {
                quotaCheckIndex += 1
                let clearID = String(format: "37373737-3737-4737-8737-%012d", quotaCheckIndex)
                try writeSession(in: quotaUpdateRoot, uuid: clearID, events: [
                    tokenEvent(at: quotaTime.addingTimeInterval(Double(quotaCheckIndex)), input: 1, output: 1,
                        rateLimits: [:])
                ], modified: now, metadataID: clearID)
                let cleared = try LocalCodexUsageReader.scan(directory: quotaUpdateRoot, now: now)
                check(cleared.fiveHour == nil && cleared.sevenDay == nil,
                    "valid empty object clears quota before nullable-window case")
                quotaCheckIndex += 1
                let restoreID = String(format: "37373737-3737-4737-8737-%012d", quotaCheckIndex)
                try writeSession(in: quotaUpdateRoot, uuid: restoreID, events: [
                    tokenEvent(at: quotaTime.addingTimeInterval(Double(quotaCheckIndex)), input: 1, output: 1,
                        rateLimits: validLimits)
                ], modified: now, metadataID: restoreID)
                quotaCheckIndex += 1
                let nullSlotsID = String(format: "37373737-3737-4737-8737-%012d", quotaCheckIndex)
                try writeSession(in: quotaUpdateRoot, uuid: nullSlotsID, events: [
                    tokenEvent(at: quotaTime.addingTimeInterval(Double(quotaCheckIndex)), input: 1, output: 1,
                        rateLimits: ["primary": NSNull(), "secondary": NSNull()])
                ], modified: now, metadataID: nullSlotsID)
                let nullSlots = try LocalCodexUsageReader.scan(directory: quotaUpdateRoot, now: now)
                check(nullSlots.fiveHour == nil && nullSlots.sevenDay == nil,
                    "valid null windows replace the prior snapshot with an empty snapshot")
                quotaCheckIndex += 1
                let nullRestoreID = String(format: "37373737-3737-4737-8737-%012d", quotaCheckIndex)
                try writeSession(in: quotaUpdateRoot, uuid: nullRestoreID, events: [
                    tokenEvent(at: quotaTime.addingTimeInterval(Double(quotaCheckIndex)), input: 1, output: 1,
                        rateLimits: validLimits)
                ], modified: now, metadataID: nullRestoreID)
                quotaCheckIndex += 1
                continue
            }
            quotaCheckIndex += 1
            let before = try LocalCodexUsageReader.scan(directory: quotaUpdateRoot, now: now)
            check(before.fiveHour?.usedPercent == 25 && before.sevenDay?.usedPercent == 70,
                "known quota snapshot restored before \(label) case")
            let snapshot = try appendQuotaFixture(quotaCheckIndex,
                quotaTime.addingTimeInterval(Double(quotaCheckIndex)), value)
            check(snapshot.fiveHour?.usedPercent == 25 && snapshot.sevenDay?.usedPercent == 70,
                "\(label) quota update preserves previous valid snapshot")
        }
        quotaCheckIndex += 1
        let replacementTime = quotaTime.addingTimeInterval(Double(quotaCheckIndex))
        let replacementFixture = String(format: "37373737-3737-4737-8737-%012d", quotaCheckIndex)
        try writeSession(in: quotaUpdateRoot, uuid: replacementFixture, events: [
            tokenEvent(at: replacementTime, input: 8, output: 8,
                rateLimits: ["primary": ["used_percent": 35, "window_minutes": 300, "resets_at": NSNull()]])
        ], modified: now, metadataID: replacementFixture)
        let wholeReplacement = try LocalCodexUsageReader.scan(directory: quotaUpdateRoot, now: now)
        check(wholeReplacement.fiveHour?.usedPercent == 35 && wholeReplacement.fiveHour?.resetsAt == nil
            && wholeReplacement.sevenDay == nil,
            "valid partial quota object replaces its sibling instead of merging windows across events")
        quotaCheckIndex += 1
        let unsupportedTime = quotaTime.addingTimeInterval(Double(quotaCheckIndex))
        let unsupportedFixture = String(format: "37373737-3737-4737-8737-%012d", quotaCheckIndex)
        try writeSession(in: quotaUpdateRoot, uuid: unsupportedFixture, events: [
            tokenEvent(at: unsupportedTime, input: 9, output: 9,
                rateLimits: ["primary": ["used_percent": 45]])
        ], modified: now, metadataID: unsupportedFixture)
        let unsupportedDuration = try LocalCodexUsageReader.scan(directory: quotaUpdateRoot, now: now)
        check(unsupportedDuration.fiveHour == nil && unsupportedDuration.sevenDay == nil,
            "valid window lacking optional duration replaces snapshot but cannot map to a supported bucket")
        quotaCheckIndex += 1
        let epochTime = quotaTime.addingTimeInterval(Double(quotaCheckIndex))
        let epochFixture = String(format: "37373737-3737-4737-8737-%012d", quotaCheckIndex)
        try writeSession(in: quotaUpdateRoot, uuid: epochFixture, events: [
            tokenEvent(at: epochTime, input: 10, output: 10,
                rateLimits: ["primary": ["used_percent": 45, "window_minutes": 300, "resets_at": 0]])
        ], modified: now, metadataID: epochFixture)
        let epochReset = try LocalCodexUsageReader.scan(directory: quotaUpdateRoot, now: now)
        check(epochReset.fiveHour?.resetsAt == Date(timeIntervalSince1970: 0)
            && epochReset.fiveHour?.isFresh(at: now, refreshSeconds: 60) == false,
            "nonnegative integer epoch reset is retained as historical time, not current quota")
        quotaCheckIndex += 1
        let clearTime = quotaTime.addingTimeInterval(Double(quotaCheckIndex))
        let clearFixture = String(format: "37373737-3737-4737-8737-%012d", quotaCheckIndex)
        try writeSession(in: quotaUpdateRoot, uuid: clearFixture, events: [
            tokenEvent(at: clearTime, input: 11, output: 11, rateLimits: [:])
        ], modified: now, metadataID: clearFixture)
        let explicitlyCleared = try LocalCodexUsageReader.scan(directory: quotaUpdateRoot, now: now)
        check(explicitlyCleared.fiveHour == nil && explicitlyCleared.sevenDay == nil,
            "explicit valid empty quota object clears prior snapshot")
        try? FileManager.default.removeItem(at: quotaUpdateRoot.deletingLastPathComponent())

        let quotaOnlyRoot = try fixtureDirectory("quota-only-event-does-not-clear-usage")
        let quotaOnlyID = "40404040-4040-4040-8040-404040404041"
        try writeSession(in: quotaOnlyRoot, uuid: quotaOnlyID, events: [
            tokenEvent(at: now.addingTimeInterval(-1), input: 20, output: 10),
            quotaOnlyEvent(at: now, rateLimits: validLimits)
        ], modified: now)
        let quotaOnly = try LocalCodexUsageReader.scan(directory: quotaOnlyRoot, now: now)
        check(quotaOnly.input == 20 && quotaOnly.output == 10 && quotaOnly.total == 30
            && quotaOnly.knownThreadCount == 1 && quotaOnly.unknownThreadCount == 0
            && quotaOnly.fiveHour?.usedPercent == 25 && quotaOnly.sevenDay?.usedPercent == 70,
            "quota update without cumulative usage preserves the thread's last valid token counters")
        try? FileManager.default.removeItem(at: quotaOnlyRoot.deletingLastPathComponent())

        let unknownSourceForkRoot = try fixtureDirectory("unknown-source-fork-not-root")
        let unknownSourceForkID = "40404040-4040-4040-8040-404040404042"
        try writeSession(in: unknownSourceForkRoot, uuid: unknownSourceForkID, events: [
            tokenEvent(at: now.addingTimeInterval(-2), input: 10, output: 5),
            ordinaryEvent(at: now.addingTimeInterval(-1), type: "user_message"),
            tokenEvent(at: now, input: 12, output: 6)
        ], modified: now, metadataID: unknownSourceForkID, metadataSource: nil,
            metadataFields: ["parent_thread_id": parentID, "subagent_history_start_ordinal": 2])
        let unknownSourceFork = try LocalCodexUsageReader.scan(directory: unknownSourceForkRoot, now: now)
        check(unknownSourceFork.knownThreadCount == 0 && unknownSourceFork.unknownThreadCount == 1
            && unknownSourceFork.sessionCount == 0 && unknownSourceFork.subagentCount == 0
            && unknownSourceFork.input == 0,
            "unknown source with otherwise valid fork baseline remains unknown and cannot become a root")
        try? FileManager.default.removeItem(at: unknownSourceForkRoot.deletingLastPathComponent())

        let cliDisplayRoot = try fixtureDirectory("cli-display-metadata-not-subagent")
        let cliDisplayID = "40404040-4040-4040-8040-404040404043"
        try writeSession(in: cliDisplayRoot, uuid: cliDisplayID,
            events: [tokenEvent(at: now, input: 3, output: 4)], modified: now,
            metadataID: cliDisplayID, metadataSource: "cli",
            metadataFields: ["agent_nickname": "Synthetic CLI", "agent_role": "review", "thread_source": "user"])
        let cliDisplay = try LocalCodexUsageReader.scan(directory: cliDisplayRoot, now: now)
        check(cliDisplay.knownThreadCount == 0 && cliDisplay.unknownThreadCount == 1
            && cliDisplay.sessionCount == 0 && cliDisplay.subagentCount == 0
            && cliDisplay.input == 0 && cliDisplay.output == 0,
            "CLI source with child display metadata is unknown rather than a trusted root or a subagent")
        try? FileManager.default.removeItem(at: cliDisplayRoot.deletingLastPathComponent())

        let nonUserChildRoot = try fixtureDirectory("subagent-nonuser-thread-source")
        let nonUserChildID = "40404040-4040-4040-8040-404040404044"
        try writeSession(in: nonUserChildRoot, uuid: nonUserChildID,
            events: [tokenEvent(at: now, input: 6, output: 4)], modified: now,
            metadataID: nonUserChildID, metadataSource: ["subagent": "review"],
            metadataFields: ["thread_source": "automation", "agent_role": "review"])
        let nonUserChild = try LocalCodexUsageReader.scan(directory: nonUserChildRoot, now: now)
        check(nonUserChild.knownThreadCount == 0 && nonUserChild.unknownThreadCount == 1
            && nonUserChild.sessionCount == 0 && nonUserChild.subagentCount == 1
            && nonUserChild.input == 0 && nonUserChild.output == 0,
            "recognized subagent source with non-user thread_source remains classified as child while missing baseline is unknown")
        try? FileManager.default.removeItem(at: nonUserChildRoot.deletingLastPathComponent())

        for (label, historyBase) in [
            ("integer", 123 as Any), ("object", ["ordinal": 5] as Any),
            ("schema-valid reference", ["thread_id": parentID, "end_ordinal_exclusive": 4,
                                        "end_byte_offset": 1024] as Any)
        ] {
            let unknownLineageRoot = try fixtureDirectory("unknown-parent-lineage-\(label)")
            try writeSession(in: unknownLineageRoot, uuid: "33333333-3333-4333-8333-333333333333",
                events: [tokenEvent(at: now, input: 55, output: 66)], modified: now,
                metadataFields: ["history_base": historyBase])
            let unknownLineage = try LocalCodexUsageReader.scan(directory: unknownLineageRoot, now: now)
            check(unknownLineage.knownThreadCount == 0 && unknownLineage.unknownThreadCount == 1
                && unknownLineage.input == 0 && !unknownLineage.hasCompleteAccounting,
                "Referenced/history_base \(label) lineage is unknown without cross-file subtraction")
            try? FileManager.default.removeItem(at: unknownLineageRoot.deletingLastPathComponent())
        }

        let referencedSubagentRoot = try fixtureDirectory("referenced-history-classifies-child")
        let referencedSubagentID = "33333333-3333-4333-8333-333333333339"
        try writeSession(in: referencedSubagentRoot, uuid: referencedSubagentID,
            events: [tokenEvent(at: now, input: 55, output: 66)], modified: now,
            metadataID: referencedSubagentID, metadataSource: ["subagent": "review"],
            metadataFields: ["history_base": ["thread_id": parentID,
                "end_ordinal_exclusive": 4, "end_byte_offset": 1024]])
        let referencedSubagent = try LocalCodexUsageReader.scan(directory: referencedSubagentRoot, now: now)
        check(referencedSubagent.knownThreadCount == 0 && referencedSubagent.unknownThreadCount == 1
            && referencedSubagent.subagentCount == 1 && referencedSubagent.sessionCount == 0
            && referencedSubagent.input == 0,
            "trusted source plus history_base classifies child while its unsupported contribution remains unknown")
        try? FileManager.default.removeItem(at: referencedSubagentRoot.deletingLastPathComponent())

        let cliForkRoot = try fixtureDirectory("cli-with-fork-marker")
        let cliForkID = "33333333-3333-4333-8333-333333333337"
        try writeSession(in: cliForkRoot, uuid: cliForkID, events: [
            tokenEvent(at: now.addingTimeInterval(-3), input: 100, output: 50), // inherited baseline
            ordinaryEvent(at: now.addingTimeInterval(-2), type: "user_message"), // explicit ordinal 2 boundary
            tokenEvent(at: now.addingTimeInterval(-1), input: 110, output: 55), // first own usage
            tokenEvent(at: now, input: 120, output: 60)
        ], modified: now, metadataID: cliForkID, metadataSource: "cli",
            metadataFields: ["forked_from_id": parentID, "parent_thread_id": parentID,
                             "subagent_history_start_ordinal": 2])
        let cliFork = try LocalCodexUsageReader.scan(directory: cliForkRoot, now: now)
        check(cliFork.input == 20 && cliFork.output == 10 && cliFork.total == 30
            && cliFork.sessionCount == 0 && cliFork.forkCount == 1 && cliFork.knownThreadCount == 1,
            "cli source plus proven parent/fork markers contributes only its delta, never root full cumulative")
        try? FileManager.default.removeItem(at: cliForkRoot.deletingLastPathComponent())

        let cliForkMissingBaselineRoot = try fixtureDirectory("cli-fork-missing-baseline")
        let cliForkMissingID = "33333333-3333-4333-8333-333333333338"
        try writeSession(in: cliForkMissingBaselineRoot, uuid: cliForkMissingID, events: [
            ordinaryEvent(at: now.addingTimeInterval(-2), type: "user_message"),
            tokenEvent(at: now.addingTimeInterval(-1), input: 110, output: 55),
            tokenEvent(at: now, input: 120, output: 60)
        ], modified: now, metadataID: cliForkMissingID, metadataSource: "cli",
            metadataFields: ["forked_from_id": parentID, "parent_thread_id": parentID,
                             "subagent_history_start_ordinal": 2])
        let cliForkMissingBaseline = try LocalCodexUsageReader.scan(directory: cliForkMissingBaselineRoot, now: now)
        check(cliForkMissingBaseline.knownThreadCount == 0 && cliForkMissingBaseline.unknownThreadCount == 1
            && cliForkMissingBaseline.sessionCount == 0 && cliForkMissingBaseline.input == 0,
            "cli source cannot override a valid fork marker when its required baseline is missing")
        try? FileManager.default.removeItem(at: cliForkMissingBaselineRoot.deletingLastPathComponent())

        let illegalLineageRoot = try fixtureDirectory("illegal-lineage-not-root")
        for (index, fields) in [
            ["forked_from_id": "parent"], ["parent_thread_id": "parent"],
            ["subagent": "unknown"], ["subagent_history_start_ordinal": -1]
        ].enumerated() {
            let id = String(format: "33333333-3333-4333-8333-%012d", index + 10)
            try writeSession(in: illegalLineageRoot, uuid: id,
                events: [tokenEvent(at: now, input: 55, output: 66)], modified: now,
                metadataID: id, metadataFields: fields)
        }
        let illegalLineage = try LocalCodexUsageReader.scan(directory: illegalLineageRoot, now: now)
        check(illegalLineage.knownThreadCount == 0 && illegalLineage.unknownThreadCount == 4
            && illegalLineage.sessionCount == 0 && !illegalLineage.hasCompleteAccounting,
            "invalid parent, fork, source, and ordinal markers cannot silently classify as roots")
        try? FileManager.default.removeItem(at: illegalLineageRoot.deletingLastPathComponent())

        let corruptLatestRoot = try fixtureDirectory("root-corrupt-latest-counter")
        let corruptID = "41414141-4141-4141-8141-414141414141"
        try writeSession(in: corruptLatestRoot, uuid: corruptID, events: [
            tokenEvent(at: now.addingTimeInterval(-1), input: 50, output: 60),
            rawTokenEvent(at: now, inputLiteral: "true", outputLiteral: "70")
        ], modified: now)
        let corruptLatest = try LocalCodexUsageReader.scan(directory: corruptLatestRoot, now: now)
        check(corruptLatest.knownThreadCount == 0 && corruptLatest.unknownThreadCount == 1
            && corruptLatest.input == 0 && corruptLatest.output == 0,
            "malformed latest cumulative record makes root contribution unknown instead of reverting")
        try? FileManager.default.removeItem(at: corruptLatestRoot.deletingLastPathComponent())

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
        check(invalid.input == 5 && invalid.output == 7 && invalid.sessionCount == 6
            && invalid.knownThreadCount == 1 && invalid.unknownThreadCount == 5
            && !invalid.hasCompleteAccounting,
            "negative, fractional, boolean, overflowing and non-finite counters are unknown without invalidating known subtotal")
        try? FileManager.default.removeItem(at: invalidRoot.deletingLastPathComponent())

        let exactRoot = try fixtureDirectory("exact-large-integer")
        try writeSession(in: exactRoot, uuid: "14141414-1414-4414-8414-141414141414",
            events: [rawTokenEvent(at: now, inputLiteral: "9007199254740993", outputLiteral: "0",
                                   totalLiteral: "9007199254740993")], modified: now)
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
        check(truncated.knownThreadCount == 0 && truncated.unknownThreadCount == 1
            && truncated.input == 0 && truncated.output == 0 && !truncated.hasCompleteAccounting,
            "a nonempty incomplete final physical record makes the latest thread contribution unknown")
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
            "same-timestamp explicit empty rate_limits object clears older quota data")
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
            events: [rawTokenEvent(at: now, inputLiteral: String(Int.max), outputLiteral: "0",
                                   totalLiteral: String(Int.max))], modified: now)
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
        check(bounded.sessionCount == 32 && bounded.knownThreadCount == 32 && bounded.isLimited
            && !bounded.hasCompleteAccounting,
            "scan selects at most 32 metadata-classified roots and marks bounded coverage incomplete")
        let warmBounded = try LocalCodexUsageReader.scan(directory: boundedRoot, now: now, cache: boundedCache)
        check(boundedCache.diagnostics.cacheHits == 32 && boundedCache.diagnostics.bytesRead == 0
            && boundedCache.entryCount == 32 && warmBounded.isLimited,
            "warm cache hits all 32 retained file summaries without content reads and preserves limitation")
        try? FileManager.default.removeItem(at: boundedRoot.deletingLastPathComponent())

        let readBudgetRoot = try fixtureDirectory("head-tail-10mib-budget")
        var largePadding = Data(repeating: 0x78, count: 400 * 1024)
        largePadding.append(10)
        for index in 0..<32 {
            let uuid = String(format: "45454545-4545-4545-8545-%012d", index + 1)
            try writeSession(in: readBudgetRoot, uuid: uuid,
                events: [tokenEvent(at: now, input: 2, output: 3)], modified: now,
                prefix: largePadding)
        }
        let budgetCache = LocalCodexUsageReader.Cache()
        let budgetSnapshot = try LocalCodexUsageReader.scan(directory: readBudgetRoot, now: now, cache: budgetCache)
        check(budgetCache.diagnostics.bytesRead <= 10 * 1024 * 1024
            && budgetCache.diagnostics.bytesRead > 8 * 1024 * 1024
            && budgetSnapshot.knownThreadCount == 32 && budgetSnapshot.isLimited
            && !budgetSnapshot.hasCompleteAccounting,
            "32 files read only within aggregate 10 MiB head+tail budget and cannot claim complete totals")
        try? FileManager.default.removeItem(at: readBudgetRoot.deletingLastPathComponent())

        let continuousBoundaryRoot = try fixtureDirectory("continuous-records-cross-head-boundary")
        let continuousID = "46464646-4646-4646-8646-464646464646"
        let oneRecord = try ordinaryEvent(at: now.addingTimeInterval(-2), type: "user_message")
        var continuousPrefix = Data()
        continuousPrefix.append(try tokenEvent(at: now.addingTimeInterval(-3), input: 4, output: 2))
        continuousPrefix.append(10)
        continuousPrefix.append(try ordinaryEvent(at: now.addingTimeInterval(-2.5), type: "user_message"))
        continuousPrefix.append(10)
        while continuousPrefix.count < 70 * 1024 {
            continuousPrefix.append(oneRecord)
            continuousPrefix.append(10)
        }
        try writeSession(in: continuousBoundaryRoot, uuid: continuousID,
            events: [tokenEvent(at: now, input: 10, output: 5)], modified: now,
            prefix: continuousPrefix, metadataID: continuousID,
            metadataFields: ["parent_thread_id": parentID, "subagent_history_start_ordinal": 2])
        let continuousFileBytes = try Data(contentsOf: sessionURL(in: continuousBoundaryRoot, uuid: continuousID))
        check(continuousFileBytes[64 * 1024 - 1] != 10,
            "continuous boundary fixture places the actual file head cutoff inside a complete JSON record")
        let continuousBoundary = try LocalCodexUsageReader.scan(directory: continuousBoundaryRoot, now: now)
        check(!continuousBoundary.isLimited && continuousBoundary.input == 6
            && continuousBoundary.output == 3 && continuousBoundary.total == 9
            && continuousBoundary.knownThreadCount == 1 && continuousBoundary.unknownThreadCount == 0,
            "a fully retained 64-320KiB file with valid records crossing the head boundary is not a read gap")
        try? FileManager.default.removeItem(at: continuousBoundaryRoot.deletingLastPathComponent())

        let emptyThenValidRoot = try fixtureDirectory("empty-file-does-not-stop-scan")
        let emptyFirstPath = emptyThenValidRoot.appendingPathComponent("rollout-empty-00000000-0000-4000-8000-000000000000.jsonl")
        try Data().write(to: emptyFirstPath)
        try writeSession(in: emptyThenValidRoot, uuid: "47474747-4747-4747-8747-474747474747",
            events: [tokenEvent(at: now, input: 7, output: 9)], modified: now)
        let emptyThenValid = try LocalCodexUsageReader.scan(directory: emptyThenValidRoot, now: now)
        check(emptyThenValid.knownThreadCount == 1 && emptyThenValid.input == 7 && emptyThenValid.output == 9
            && emptyThenValid.unidentifiedFileCount == 1 && emptyThenValid.sessionCount == 1,
            "an empty invalid file does not prevent discovery and accounting of a later valid file")
        try? FileManager.default.removeItem(at: emptyThenValidRoot.deletingLastPathComponent())

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
        let archiveRoot = try fixtureDirectory("archived-sibling")
        let active = archiveRoot.appendingPathComponent("sessions", isDirectory: true)
        let archived = archiveRoot.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let activeID = "41414141-4141-4141-8141-414141414141"
        let archivedID = "42424242-4242-4242-8242-424242424242"
        try writeSession(in: active, uuid: activeID, events: [tokenEvent(at: now, input: 3, output: 4)], modified: now)
        try writeSession(in: archived, uuid: archivedID, events: [tokenEvent(at: now, input: 5, output: 6)], modified: now)
        let combined = try LocalCodexUsageReader.scanCodexHome(sessions: active, now: now)
        check(combined.input == 8 && combined.output == 10 && combined.knownThreadCount == 2,
              "archived sibling sessions contribute to the local total without replacing active files")
        let activeOnly = try LocalCodexUsageReader.scan(directory: active, now: now)
        check(activeOnly.input == 3 && activeOnly.knownThreadCount == 1,
              "scanning the active directory alone does not invent archived usage")
        let sameUsageID = "43434343-4343-4343-8343-434343434343"
        try writeSession(in: archived, uuid: sameUsageID, events: [tokenEvent(at: now, input: 3, output: 4)], modified: now)
        let equalTotals = try LocalCodexUsageReader.scanCodexHome(sessions: active, now: now)
        check(equalTotals.input == 11 && equalTotals.knownThreadCount == 3
            && equalTotals.details.count == 3,
              "equal token totals in different archived threads are not collapsed")
        // Codex may hard-link a rollout into the archive before removing it
        // from the active directory. Both paths then name one physical file
        // and must contribute one total, not two.
        let linkedID = "44444444-4444-4444-8444-444444444444"
        try writeSession(in: active, uuid: linkedID, events: [tokenEvent(at: now, input: 7, output: 2)], modified: now)
        try FileManager.default.linkItem(at: sessionURL(in: active, uuid: linkedID),
                                         to: sessionURL(in: archived, uuid: linkedID))
        let hardLinked = try LocalCodexUsageReader.scanCodexHome(sessions: active, now: now)
        check(hardLinked.input == 18 && hardLinked.output == 16 && hardLinked.knownThreadCount == 4
            && hardLinked.details.count == 4,
              "a rollout hard-linked into the archive is one physical history and is counted once")
        let sharedCache = LocalCodexUsageReader.Cache()
        let warm = try LocalCodexUsageReader.scanCodexHome(sessions: active, now: now, cache: sharedCache)
        let hardLinkedOnce = try LocalCodexUsageReader.scanCodexHome(sessions: active, now: now, cache: sharedCache)
        check(warm.input == 18 && hardLinkedOnce.input == 18 && hardLinkedOnce.output == 16
            && hardLinkedOnce.details.count == 4,
              "cached scans keep the sibling hard-link exclusion stable")
        // A *copy* (distinct inode, same thread identity) in the archive must
        // not double-count either: it is one logical history under two paths.
        let copiedID = "55555555-5555-5555-8555-555555555555"
        try writeSession(in: active, uuid: copiedID, events: [tokenEvent(at: now, input: 11, output: 1)], modified: now)
        try FileManager.default.copyItem(at: sessionURL(in: active, uuid: copiedID),
                                         to: sessionURL(in: archived, uuid: copiedID))
        let copied = try LocalCodexUsageReader.scanCodexHome(sessions: active, now: now)
        check(copied.input == 29 && copied.output == 17 && copied.knownThreadCount == 5
            && copied.details.count == 5,
              "a rollout copied into the archive is one logical thread and is counted once")
        try? FileManager.default.removeItem(at: archiveRoot)
        let legacyPlist: [String: Any] = ["endpoint": "https://gateway.example/v1/chat/completions",
            "usageURL": "https://gateway.example/usage", "port": 18888]
        let legacyData = try PropertyListSerialization.data(fromPropertyList: legacyPlist, format: .xml, options: 0)
        let legacy = try PropertyListDecoder().decode(AppConfiguration.self, from: legacyData)
        check(legacy.dataSource == "proxy", "legacy explicit proxy configuration without source preserves proxy mode")
    }

    /// Live estimates require an intact final record segment and an unambiguous,
    /// current lifecycle. These fixtures never inspect actual local sessions.
    private static func localLiveIntegrityChecks(now: Date) throws {
        let id = "35353535-3535-4535-8535-353535353535"
        func assertUnknown(_ label: String, events: [Data], suffix: Data = Data(),
                           incompleteAccounting: Bool = false) throws {
            let root = try fixtureDirectory("live-integrity-\(label)")
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            try writeSession(in: root, uuid: id, events: events, modified: now, suffix: suffix)
            let cache = LocalCodexUsageReader.Cache()
            let cold = try LocalCodexUsageReader.scan(directory: root, now: now, cache: cache)
            let warm = try LocalCodexUsageReader.scan(directory: root, now: now, cache: cache)
            check(cold.liveTurn == nil && warm.liveTurn == nil,
                "live integrity rejects \(label) on cold and cached scans")
            if incompleteAccounting {
                check(cold.total == 0 && !cold.hasCompleteAccounting && warm.total == 0 && !warm.hasCompleteAccounting,
                    "future counters never enter complete accounting for \(label)")
            }
        }
        let start = try turnBoundary(at: now.addingTimeInterval(-5), type: "task_started", id: "A")
        let first = try turnTokenEvent(at: now.addingTimeInterval(-3), output: 10)
        let second = try turnTokenEvent(at: now.addingTimeInterval(-2), output: 30)
        try assertUnknown("truncated-tail", events: [start, first, second], suffix: json("{\"type\":\"event_msg\","))
        try assertUnknown("damaged-record-between-counters", events: [start, first, json("{BROKEN}"), second])
        try assertUnknown("damaged-record-after-counters", events: [start, first, second, json("{BROKEN}")])
        try assertUnknown("invalid-event-payload", events: [start, first, json("{\"type\":\"event_msg\",\"payload\":null}"), second])
        try assertUnknown("missing-event-kind", events: [start, first, json("{\"type\":\"event_msg\",\"payload\":{}}"), second])
        try assertUnknown("overlapping-tasks", events: [start,
            turnBoundary(at: now.addingTimeInterval(-4), type: "task_started", id: "B"), first, second,
            turnBoundary(at: now.addingTimeInterval(-1), type: "task_complete", id: "A")])
        try assertUnknown("unmatched-completion", events: [start, first, second,
            turnBoundary(at: now.addingTimeInterval(-1), type: "task_complete", id: "B")])
        try assertUnknown("reused-task-id", events: [
            turnBoundary(at: now.addingTimeInterval(-9), type: "task_started", id: "A"),
            turnBoundary(at: now.addingTimeInterval(-8), type: "task_complete", id: "A"), start, first, second])
        try assertUnknown("future-task-start", events: [
            turnBoundary(at: now.addingTimeInterval(10), type: "task_started", id: "A"), first, second])
        let missingStartDate = try JSONSerialization.data(withJSONObject: ["type": "event_msg",
            "payload": ["type": "task_started", "turn_id": "A"]])
        try assertUnknown("missing-task-start-time", events: [missingStartDate, first, second])
        try assertUnknown("backwards-lifecycle-time", events: [
            turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "A"), first,
            turnTokenEvent(at: now.addingTimeInterval(-1), output: 30)])
        try assertUnknown("earlier-counter-reset", events: [start,
            turnTokenEvent(at: now.addingTimeInterval(-4), output: 40), first, second])
        try assertUnknown("earlier-counter-time-reversal", events: [start,
            turnTokenEvent(at: now.addingTimeInterval(-2), output: 5), first,
            turnTokenEvent(at: now.addingTimeInterval(-1), output: 30)])
        try assertUnknown("future-final-counter", events: [start, first, second,
            turnTokenEvent(at: now.addingTimeInterval(1), output: 50)], incompleteAccounting: true)
        try assertUnknown("future-earlier-counter", events: [start,
            turnTokenEvent(at: now.addingTimeInterval(1), output: 5), first, second], incompleteAccounting: true)

        let paddingA = try JSONSerialization.data(withJSONObject: ["type": "padding", "text": String(repeating: "a", count: 130_000)])
        let paddingB = try JSONSerialization.data(withJSONObject: ["type": "padding", "text": String(repeating: "b", count: 300_000)])
        try assertUnknown("unread-middle-task-completion", events: [start, paddingA,
            turnBoundary(at: now.addingTimeInterval(-4), type: "task_complete", id: "A"), paddingB, first, second])

        let recoveryRoot = try fixtureDirectory("live-integrity-final-segment-recovery")
        defer { try? FileManager.default.removeItem(at: recoveryRoot.deletingLastPathComponent()) }
        try writeSession(in: recoveryRoot, uuid: id, events: [start, paddingA,
            turnBoundary(at: now.addingTimeInterval(-4), type: "task_complete", id: "A"), paddingB,
            turnBoundary(at: now.addingTimeInterval(-4), type: "task_started", id: "B"), first, second], modified: now)
        let recovered = try LocalCodexUsageReader.scan(directory: recoveryRoot, now: now)
        check(recovered.isLimited && recovered.liveTurn?.outputTPS == 20,
            "complete independent task in the retained tail can recover a live estimate after a read gap")

        let futureRoot = try fixtureDirectory("live-integrity-cache-time-revalidation")
        defer { try? FileManager.default.removeItem(at: futureRoot.deletingLastPathComponent()) }
        try writeSession(in: futureRoot, uuid: id, events: [start, first, second,
            turnTokenEvent(at: now.addingTimeInterval(1), output: 50)], modified: now)
        let futureCache = LocalCodexUsageReader.Cache()
        _ = try LocalCodexUsageReader.scan(directory: futureRoot, now: now, cache: futureCache)
        let caughtUp = try LocalCodexUsageReader.scan(directory: futureRoot, now: now.addingTimeInterval(2), cache: futureCache)
        let caughtUpCold = try LocalCodexUsageReader.scan(directory: futureRoot, now: now.addingTimeInterval(2))
        check(bp39SemanticProjection(caughtUp) == bp39SemanticProjection(caughtUpCold)
            && caughtUp.hasCompleteAccounting && caughtUp.liveTurn != nil,
            "unchanged cached file is rejudged when a future counter becomes current")
        let rewound = try LocalCodexUsageReader.scan(directory: futureRoot, now: now, cache: futureCache)
        let rewoundCold = try LocalCodexUsageReader.scan(directory: futureRoot, now: now)
        check(bp39SemanticProjection(rewound) == bp39SemanticProjection(rewoundCold)
            && rewound.liveTurn == nil && !rewound.hasCompleteAccounting,
            "clock rollback cannot reuse counters or live estimates that are now in the future")

        let aggregateRoot = try fixtureDirectory("live-integrity-aggregate-expiry")
        defer { try? FileManager.default.removeItem(at: aggregateRoot.deletingLastPathComponent()) }
        try writeSession(in: aggregateRoot, uuid: id, events: [
            turnBoundary(at: now.addingTimeInterval(-17), type: "task_started", id: "older"),
            turnTokenEvent(at: now.addingTimeInterval(-16), output: 10),
            turnTokenEvent(at: now.addingTimeInterval(-14), output: 30)], modified: now)
        try writeSession(in: aggregateRoot, uuid: "36363636-3636-4636-8636-363636363636", events: [
            turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "newer"),
            turnTokenEvent(at: now.addingTimeInterval(-1), output: 10),
            turnTokenEvent(at: now, output: 30)], modified: now)
        let aggregateCache = LocalCodexUsageReader.Cache()
        let coldAggregate = try LocalCodexUsageReader.scan(directory: aggregateRoot, now: now, cache: aggregateCache)
        let warmAggregate = try LocalCodexUsageReader.scan(directory: aggregateRoot, now: now, cache: aggregateCache)
        check(coldAggregate.liveTurn?.outputTPS == 30 && warmAggregate == coldAggregate
            && coldAggregate.liveTurn?.observedAt == now.addingTimeInterval(-14),
            "aggregate live freshness uses its oldest component so one newer session cannot extend an older rate")
        let afterComponentExpiry = try LocalCodexUsageReader.scan(directory: aggregateRoot,
            now: now.addingTimeInterval(1.001), cache: aggregateCache)
        check(afterComponentExpiry.liveTurn?.outputTPS == 20 && afterComponentExpiry.liveTurn?.observedAt == now,
            "next cached scan drops the expired aggregate component and restores the remaining fresh session")
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
                                     prefix: Data = Data(), suffix: Data = Data(),
                                     metadataID: String? = nil, metadataSource: Any? = "cli",
                                     metadataFields: [String: Any] = [:], metadata: Data? = nil,
                                     finalNewline: Bool = true) throws {
        var data = metadata ?? sessionMetadata(id: metadataID ?? uuid, source: metadataSource, fields: metadataFields)
        if !data.isEmpty { data.append(10) }
        data.append(contentsOf: prefix)
        for (index, event) in events.enumerated() {
            data.append(contentsOf: event)
            if finalNewline || index < events.count - 1 || !suffix.isEmpty { data.append(10) }
        }
        data.append(contentsOf: suffix)
        let url = sessionURL(in: directory, uuid: uuid)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    private static func tokenEvent(at timestamp: Date, input: Int, output: Int, cached: Int = 0,
                                   reasoning: Int = 0, rateLimits: Any? = nil) throws -> Data {
        var usage: [String: Any] = ["input_tokens": input, "output_tokens": output, "total_tokens": input + output]
        if cached > 0 { usage["cached_input_tokens"] = cached }
        if reasoning > 0 { usage["reasoning_output_tokens"] = reasoning }
        let info: [String: Any] = ["total_token_usage": usage]
        var payload: [String: Any] = ["type": "token_count", "info": info]
        if let rateLimits { payload["rate_limits"] = rateLimits }
        let event: [String: Any] = ["timestamp": iso(timestamp), "type": "event_msg", "payload": payload]
        return try JSONSerialization.data(withJSONObject: event)
    }

    private static func quotaOnlyEvent(at timestamp: Date, rateLimits: Any) throws -> Data {
        let event: [String: Any] = ["timestamp": iso(timestamp), "type": "event_msg",
            "payload": ["type": "token_count", "info": [:], "rate_limits": rateLimits]]
        return try JSONSerialization.data(withJSONObject: event)
    }

    private static func ordinaryEvent(at timestamp: Date, type: String) throws -> Data {
        let event: [String: Any] = ["timestamp": iso(timestamp), "type": "event_msg",
            "payload": ["type": type]]
        return try JSONSerialization.data(withJSONObject: event)
    }

    private static func threadSettingsApplied(at timestamp: Date, threadID: String) throws -> Data {
        let event: [String: Any] = ["timestamp": iso(timestamp), "type": "event_msg",
            "payload": ["type": "thread_settings_applied", "thread_id": threadID,
                        "thread_settings": ["model": "synthetic"]]]
        return try JSONSerialization.data(withJSONObject: event)
    }

    private static func sessionMetadata(id: String?, source: Any?, fields: [String: Any] = [:]) -> Data {
        var payload = fields
        if let id { payload["id"] = id }
        if let source { payload["source"] = source }
        let object: [String: Any] = ["type": "session_meta", "payload": payload]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func rawTokenEvent(at timestamp: Date, inputLiteral: String, outputLiteral: String,
                                     totalLiteral: String? = nil) -> Data {
        let time = iso(timestamp)
        let totalJSON = totalLiteral ?? "1"
        return Data("{\"timestamp\":\"\(time)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(inputLiteral),\"output_tokens\":\(outputLiteral),\"total_tokens\":\(totalJSON)}}}}".utf8)
    }

    private static func turnTokenEvent(at timestamp: Date, output: Int) throws -> Data {
        let event: [String: Any] = ["timestamp": iso(timestamp), "type": "event_msg",
            "payload": ["type": "token_count", "info": ["total_token_usage": [
                "input_tokens": 0, "output_tokens": output, "total_tokens": output]]]]
        return try JSONSerialization.data(withJSONObject: event)
    }

    private static func turnTokenEventWithoutTimestamp(output: Int) throws -> Data {
        let event: [String: Any] = ["type": "event_msg",
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

    private static func turnBoundaryWithoutTimestamp(type: String, id: String) throws -> Data {
        let event: [String: Any] = ["type": "event_msg",
            "payload": ["type": type, "turn_id": id]]
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

    /// DM-A typed checks are intentionally behind a source flag.  The first
    /// D39-01 run exercises the reflection contract on the pre-implementation
    /// API; the flag is enabled only after the coder adds the frozen r4 API.
    private enum BP39CacheLiteral {
        case missing
        case null
        case raw(String)
    }

    private static func bp39TokenEvent(at timestamp: Date, input: Int, output: Int,
                                       total: Int? = nil, cache: BP39CacheLiteral = .missing) -> Data {
        let total = total ?? input + output
        let cacheField: String
        switch cache {
        case .missing: cacheField = ""
        case .null: cacheField = ",\"cached_input_tokens\":null"
        case .raw(let literal): cacheField = ",\"cached_input_tokens\":\(literal)"
        }
        return Data("{\"timestamp\":\"\(iso(timestamp))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),\"total_tokens\":\(total)\(cacheField)}}}}".utf8)
    }

    private static func bp39Detail(_ snapshot: LocalCodexSnapshot,
                                   input: Int? = nil,
                                   output: Int? = nil) -> LocalCodexThreadDetail? {
        snapshot.details.first { detail in
            (input == nil || detail.usage.input == input) &&
            (output == nil || detail.usage.output == output)
        }
    }

    private static func bp39CacheState(_ usage: LocalCodexUsageDetail) -> LocalCacheInput {
        usage.cache
    }

    /// Separate Cache lifecycles do not share opaque-key identity. This
    /// comparison-only projection preserves every value except scoped keys.
    private static func bp39SemanticProjection(_ snapshot: LocalCodexSnapshot) -> LocalCodexSnapshot {
        let details: [LocalCodexThreadDetail] = snapshot.details.map { thread in
            let turns: [LocalCodexTurnDetail] = thread.turns.map { turn in
                LocalCodexTurnDetail(opaqueKey: 0, ordinal: turn.ordinal, usage: turn.usage,
                                    durationSeconds: turn.durationSeconds, completedAt: turn.completedAt)
            }
            return LocalCodexThreadDetail(opaqueKey: 0, ordinal: thread.ordinal, kind: thread.kind,
                                          usage: thread.usage, turns: turns)
        }
        return LocalCodexSnapshot(input: snapshot.input, output: snapshot.output, total: snapshot.total,
            sessionCount: snapshot.sessionCount, filesScanned: snapshot.filesScanned,
            isLimited: snapshot.isLimited, latestEventAt: snapshot.latestEventAt,
            fiveHour: snapshot.fiveHour, sevenDay: snapshot.sevenDay,
            knownThreadCount: snapshot.knownThreadCount, unknownThreadCount: snapshot.unknownThreadCount,
            unidentifiedFileCount: snapshot.unidentifiedFileCount, subagentCount: snapshot.subagentCount,
            forkCount: snapshot.forkCount, lastTurn: snapshot.lastTurn, liveTurn: snapshot.liveTurn,
            readAt: snapshot.readAt, details: details, cacheCoverage: snapshot.cacheCoverage,
            detailLimited: snapshot.detailLimited)
    }

    private static func bp39AssertWarmScan(_ root: URL, now: Date,
                                           cache: LocalCodexUsageReader.Cache,
                                           cold: LocalCodexSnapshot,
                                           label: String,
                                           routeContext: LocalCodexRouteContext? = nil) throws {
        let warm = try LocalCodexUsageReader.scan(directory: root, now: now, cache: cache,
                                                   routeContext: routeContext)
        check(warm == cold, "\(label) warm scan preserves base/detail/cache state and coverage")
    }

    private static func bp39CompleteTurnEvents(now: Date, turnCount: Int,
                                                inputBase: Int = 0,
                                                outputBase: Int = 0,
                                                cacheBase: Int = 0,
                                                varyingOutput: Bool = false,
                                                timeOffset: TimeInterval = 0) -> [Data] {
        let origin = now.addingTimeInterval(-Double(turnCount * 4 + 4) + timeOffset)
        var input = inputBase, output = outputBase, cache = cacheBase
        var events: [Data] = [bp39TokenEvent(at: origin, input: input, output: output,
                                              cache: .raw(String(cache)))]
        for index in 0..<turnCount {
            let start = origin.addingTimeInterval(Double(index * 4 + 1))
            let token = start.addingTimeInterval(1)
            let complete = start.addingTimeInterval(2)
            input += 10
            output += varyingOutput ? index + 1 : 20
            cache += 5
            events.append(try! turnBoundary(at: start, type: "task_started", id: "bp39-turn-\(index)"))
            events.append(bp39TokenEvent(at: token, input: input, output: output,
                                         cache: .raw(String(cache))))
            events.append(try! turnBoundary(at: complete, type: "task_complete",
                                             id: "bp39-turn-\(index)", durationMS: 1000))
        }
        return events
    }

    private static func bp39D01TypedChecks(now: Date) throws {
        // DM-A01: explicit zero, inclusive input, null/missing/invalid and no
        // stale-cache fallback all preserve independently valid base totals.
        let typeRoot = try fixtureDirectory("bp39-a01-types")
        defer { try? FileManager.default.removeItem(at: typeRoot.deletingLastPathComponent()) }
        let validID = "a0010001-0001-4001-8001-000000000001"
        let zeroID = "a0010001-0001-4001-8001-000000000002"
        try writeSession(in: typeRoot, uuid: validID, events: [
            bp39TokenEvent(at: now.addingTimeInterval(-2), input: 100, output: 20, total: 120,
                           cache: .raw("35"))], modified: now.addingTimeInterval(-1))
        try writeSession(in: typeRoot, uuid: zeroID, events: [
            bp39TokenEvent(at: now.addingTimeInterval(-1), input: 0, output: 0, total: 0,
                           cache: .raw("0"))], modified: now)
        let coldCache = LocalCodexUsageReader.Cache()
        let typed = try LocalCodexUsageReader.scan(directory: typeRoot, now: now, cache: coldCache)
        check(typed.input == 100 && typed.output == 20 && typed.total == 120,
              "DM-A01 valid cached input retains inclusive base accounting")
        check(typed.cacheCoverage.state == .complete && typed.cacheCoverage.baseRows == 2
            && typed.cacheCoverage.cacheKnownRows == 2 && typed.cacheCoverage.cacheMissingRows == 0
            && typed.cacheCoverage.cacheInvalidRows == 0 && typed.cacheCoverage.cachedInputTokens == 35
            && typed.cacheCoverage.uncachedInputTokens == 65
            && typed.cacheCoverage.hitRate.map { abs($0 - 0.35) < 0.000_001 } == true,
              "DM-A01 coverage sums C/I and derives U without double-counting")
        if let valid = bp39Detail(typed, input: 100), let zero = bp39Detail(typed, input: 0) {
            if case .value(35) = bp39CacheState(valid.usage) {
                check(valid.usage.uncachedInput == 65, "DM-A01 valid row derives uncached input")
            } else { check(false, "DM-A01 valid row has value(35) cache state") }
            if case .value(0) = bp39CacheState(zero.usage) {
                check(zero.usage.uncachedInput == 0, "DM-A01 explicit zero is known and derives U=0")
            } else { check(false, "DM-A01 explicit zero is not missing") }
        } else { check(false, "DM-A01 keeps both known thread detail rows") }
        try bp39AssertWarmScan(typeRoot, now: now, cache: coldCache, cold: typed,
                               label: "DM-A01 valid cache coverage")
        check(coldCache.diagnostics.cacheHits == 2 && coldCache.diagnostics.bytesRead == 0,
              "DM-A01 cold and warm scans keep file-cache reuse separate from model cache")

        let invalidCases: [(String, BP39CacheLiteral, LocalCacheInput, LocalCacheAggregateState)] = [
            ("missing", .missing, .notReported, .missing),
            ("null", .null, .notReported, .missing),
            ("bool", .raw("true"), .invalid, .invalid),
            ("fraction", .raw("35.5"), .invalid, .invalid),
            ("negative", .raw("-1"), .invalid, .invalid),
            ("overflow", .raw("9223372036854775808"), .invalid, .invalid),
            ("greater", .raw("101"), .invalid, .invalid)
        ]
        for (label, literal, expectedRow, expectedAggregate) in invalidCases {
            let root = try fixtureDirectory("bp39-a01-\(label)")
            let cache = LocalCodexUsageReader.Cache()
            try writeSession(in: root, uuid: "a0010001-0001-4001-8001-\(String(format: "%012d", invalidCases.firstIndex { $0.0 == label }! + 10))",
                events: [bp39TokenEvent(at: now, input: 100, output: 20, total: 120, cache: literal)], modified: now)
            let snapshot = try LocalCodexUsageReader.scan(directory: root, now: now, cache: cache)
            let detail = bp39Detail(snapshot, input: 100)
            check(snapshot.input == 100 && snapshot.output == 20 && snapshot.total == 120,
                  "DM-A01 (label) retains valid base counters")
            check(detail.map { bp39CacheState($0.usage) == expectedRow } == true,
                  "DM-A01 (label) maps to the exact row cache state")
            check(snapshot.cacheCoverage.state == expectedAggregate
                && snapshot.cacheCoverage.cachedInputTokens == nil
                && snapshot.cacheCoverage.uncachedInputTokens == nil,
                  "DM-A01 (label) does not treat unknown cache as zero")
            let warm = try LocalCodexUsageReader.scan(directory: root, now: now, cache: cache)
            check(warm.input == snapshot.input && warm.output == snapshot.output && warm.total == snapshot.total
                && warm.details == snapshot.details && warm.cacheCoverage == snapshot.cacheCoverage
                && cache.diagnostics.cacheHits == 1 && cache.diagnostics.bytesRead == 0,
                  "DM-A01 (label) warm scan preserves all metrics, not only a cache-hit counter")
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
        let staleRoot = try fixtureDirectory("bp39-a01-no-forward-fill")
        defer { try? FileManager.default.removeItem(at: staleRoot.deletingLastPathComponent()) }
        try writeSession(in: staleRoot, uuid: "a0010001-0001-4001-8001-000000000099", events: [
            bp39TokenEvent(at: now.addingTimeInterval(-2), input: 100, output: 20, total: 120, cache: .raw("35")),
            bp39TokenEvent(at: now, input: 110, output: 25, total: 135, cache: .missing)], modified: now)
        let staleCache = LocalCodexUsageReader.Cache()
        let stale = try LocalCodexUsageReader.scan(directory: staleRoot, now: now, cache: staleCache)
        check(stale.cacheCoverage.state == .missing && stale.cacheCoverage.cachedInputTokens == nil
            && bp39Detail(stale, input: 110).map { bp39CacheState($0.usage) == .notReported } == true,
              "DM-A01 missing latest cache never forward-fills an earlier value")
        try bp39AssertWarmScan(staleRoot, now: now, cache: staleCache, cold: stale,
                               label: "DM-A01 missing latest cache")

        // DM-A02: cumulative cache chains are independently validated and only
        // mixed known/unknown aggregate coverage becomes partial.
        let chainRoot = try fixtureDirectory("bp39-a02-chains")
        defer { try? FileManager.default.removeItem(at: chainRoot.deletingLastPathComponent()) }
        try writeSession(in: chainRoot, uuid: "a0020002-0002-4002-8002-000000000001", events: [
            bp39TokenEvent(at: now.addingTimeInterval(-3), input: 100, output: 20, cache: .raw("40")),
            bp39TokenEvent(at: now.addingTimeInterval(-2), input: 120, output: 30, cache: .raw("50")),
            bp39TokenEvent(at: now.addingTimeInterval(-1), input: 120, output: 30, cache: .raw("50"))], modified: now)
        let chainCache = LocalCodexUsageReader.Cache()
        let chain = try LocalCodexUsageReader.scan(directory: chainRoot, now: now, cache: chainCache)
        check(chain.cacheCoverage.state == .complete && chain.cacheCoverage.cachedInputTokens == 50
            && bp39Detail(chain, input: 120).map { bp39CacheState($0.usage) == .value(50) } == true,
              "DM-A02 monotonic and equal cache increments end at the final cumulative value")
        try bp39AssertWarmScan(chainRoot, now: now, cache: chainCache, cold: chain,
                               label: "DM-A02 monotonic chain")
        check(chainCache.diagnostics.cacheHits == 1 && chainCache.diagnostics.bytesRead == 0,
              "DM-A02 warm scan reuses complete chain file summaries")
        let missingThenInvalidRoot = try fixtureDirectory("bp39-a02-missing-invalid-priority")
        defer { try? FileManager.default.removeItem(at: missingThenInvalidRoot.deletingLastPathComponent()) }
        try writeSession(in: missingThenInvalidRoot, uuid: "a0020002-0002-4002-8002-000000000030", events: [
            bp39TokenEvent(at: now.addingTimeInterval(-3), input: 100, output: 20, cache: .raw("40")),
            bp39TokenEvent(at: now.addingTimeInterval(-2), input: 110, output: 25, cache: .missing),
            bp39TokenEvent(at: now, input: 120, output: 30, cache: .raw("true"))], modified: now)
        let missingThenInvalidCache = LocalCodexUsageReader.Cache()
        let missingThenInvalid = try LocalCodexUsageReader.scan(directory: missingThenInvalidRoot, now: now,
                                                                 cache: missingThenInvalidCache)
        check(missingThenInvalid.input == 120 && missingThenInvalid.output == 30
            && missingThenInvalid.cacheCoverage.state == .invalid
            && bp39Detail(missingThenInvalid, input: 120).map { bp39CacheState($0.usage) == .invalid } == true,
              "DM-A02 an invalid cache later in a chain takes priority over an earlier missing value")
        try bp39AssertWarmScan(missingThenInvalidRoot, now: now, cache: missingThenInvalidCache,
                               cold: missingThenInvalid, label: "DM-A02 missing then invalid")
        let missingOnlyRoot = try fixtureDirectory("bp39-a02-mid-chain-missing")
        defer { try? FileManager.default.removeItem(at: missingOnlyRoot.deletingLastPathComponent()) }
        try writeSession(in: missingOnlyRoot, uuid: "a0020002-0002-4002-8002-000000000031", events: [
            bp39TokenEvent(at: now.addingTimeInterval(-2), input: 100, output: 20, cache: .raw("40")),
            bp39TokenEvent(at: now, input: 110, output: 25, cache: .missing)], modified: now)
        let missingOnlyCache = LocalCodexUsageReader.Cache()
        let missingOnly = try LocalCodexUsageReader.scan(directory: missingOnlyRoot, now: now,
                                                          cache: missingOnlyCache)
        check(missingOnly.cacheCoverage.state == .missing
            && bp39Detail(missingOnly, input: 110).map { bp39CacheState($0.usage) == .notReported } == true,
              "DM-A02 a mid-chain missing cache stays notReported when no invalid value exists")
        try bp39AssertWarmScan(missingOnlyRoot, now: now, cache: missingOnlyCache,
                               cold: missingOnly, label: "DM-A02 mid-chain missing")
        for (label, records) in [
            ("rollback", [
                bp39TokenEvent(at: now.addingTimeInterval(-2), input: 100, output: 20, cache: .raw("40")),
                bp39TokenEvent(at: now, input: 110, output: 25, cache: .raw("30"))]),
            ("delta-too-large", [
                bp39TokenEvent(at: now.addingTimeInterval(-2), input: 100, output: 20, cache: .raw("40")),
                bp39TokenEvent(at: now, input: 110, output: 25, cache: .raw("60"))])
        ] {
            let root = try fixtureDirectory("bp39-a02-\(label)")
            defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
            try writeSession(in: root, uuid: "a0020002-0002-4002-8002-\(label == "rollback" ? "000000000010" : "000000000011")",
                events: records, modified: now)
            let cache = LocalCodexUsageReader.Cache()
            let result = try LocalCodexUsageReader.scan(directory: root, now: now, cache: cache)
            check(result.input == 110 && result.output == 25 && result.cacheCoverage.state == .invalid
                && bp39Detail(result, input: 110).map { bp39CacheState($0.usage) == .invalid } == true,
                  "DM-A02 \(label) invalidates only the cache chain and preserves base counters")
            try bp39AssertWarmScan(root, now: now, cache: cache, cold: result,
                                   label: "DM-A02 \(label)")
        }
        let partialRoot = try fixtureDirectory("bp39-a02-partial")
        defer { try? FileManager.default.removeItem(at: partialRoot.deletingLastPathComponent()) }
        try writeSession(in: partialRoot, uuid: "a0020002-0002-4002-8002-000000000020",
            events: [bp39TokenEvent(at: now.addingTimeInterval(-1), input: 100, output: 20, cache: .raw("90"))], modified: now.addingTimeInterval(-1))
        try writeSession(in: partialRoot, uuid: "a0020002-0002-4002-8002-000000000021",
            events: [bp39TokenEvent(at: now, input: 900, output: 30, cache: .missing)], modified: now)
        let partialCache = LocalCodexUsageReader.Cache()
        let partial = try LocalCodexUsageReader.scan(directory: partialRoot, now: now, cache: partialCache)
        check(partial.input == 1000 && partial.cacheCoverage.state == .partial
            && partial.cacheCoverage.matchedInputTokens == 100
            && partial.cacheCoverage.matchedCachedInputTokens == 90
            && partial.cacheCoverage.cachedInputTokens == nil,
              "DM-A02 aggregate partial coverage exposes only its matched C/I subset")
        try bp39AssertWarmScan(partialRoot, now: now, cache: partialCache, cold: partial,
                               label: "DM-A02 partial aggregate")

        // DM-A03: fork contribution and complete-turn cache baselines are
        // separate; old R12 input rollback compatibility remains explicit.
        let forkRoot = try fixtureDirectory("bp39-a03-fork")
        defer { try? FileManager.default.removeItem(at: forkRoot.deletingLastPathComponent()) }
        let parentID = "a0030003-0003-4003-8003-000000000001"
        let childID = "a0030003-0003-4003-8003-000000000002"
        try writeSession(in: forkRoot, uuid: parentID, events: [
            bp39TokenEvent(at: now.addingTimeInterval(-5), input: 100, output: 20, total: 120, cache: .raw("40"))], modified: now.addingTimeInterval(-4))
        let source: [String: Any] = ["subagent": ["thread_spawn": ["parent_thread_id": parentID, "depth": 1]]]
        try writeSession(in: forkRoot, uuid: childID, events: [
            bp39TokenEvent(at: now.addingTimeInterval(-4), input: 100, output: 20, total: 120, cache: .raw("40")),
            ordinaryEvent(at: now.addingTimeInterval(-3), type: "user_message"),
            bp39TokenEvent(at: now.addingTimeInterval(-2), input: 120, output: 30, total: 150, cache: .raw("50")),
            bp39TokenEvent(at: now.addingTimeInterval(-1), input: 160, output: 50, total: 210, cache: .raw("70"))], modified: now,
            metadataID: childID, metadataSource: source,
            metadataFields: ["parent_thread_id": parentID, "subagent_history_start_ordinal": 3])
        let forkCache = LocalCodexUsageReader.Cache()
        let fork = try LocalCodexUsageReader.scan(directory: forkRoot, now: now, cache: forkCache)
        check(fork.input == 160 && fork.output == 50 && fork.total == 210
            && fork.cacheCoverage.cachedInputTokens == 70
            && bp39Detail(fork, input: 60).map { $0.usage.output == 30 && bp39CacheState($0.usage) == .value(30) } == true,
              "DM-A03 fork contribution subtracts one cache baseline and does not subtract parent twice")
        try bp39AssertWarmScan(forkRoot, now: now, cache: forkCache, cold: fork,
                               label: "DM-A03 fork contribution")

        let forkMissingCacheRoot = try fixtureDirectory("bp39-a03-fork-missing-cache-baseline")
        defer { try? FileManager.default.removeItem(at: forkMissingCacheRoot.deletingLastPathComponent()) }
        let missingChildID = "a0030003-0003-4003-8003-000000000006"
        try writeSession(in: forkMissingCacheRoot, uuid: parentID, events: [
            bp39TokenEvent(at: now.addingTimeInterval(-3), input: 100, output: 20, total: 120,
                           cache: .raw("40"))], modified: now.addingTimeInterval(-3))
        try writeSession(in: forkMissingCacheRoot, uuid: missingChildID, events: [
            bp39TokenEvent(at: now.addingTimeInterval(-4), input: 100, output: 20, total: 120,
                           cache: .missing),
            try turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "bp39-fork-missing-cache"),
            bp39TokenEvent(at: now.addingTimeInterval(-1), input: 160, output: 50, total: 210,
                           cache: .raw("70"))], modified: now,
            metadataID: missingChildID, metadataSource: source,
            metadataFields: ["parent_thread_id": parentID, "subagent_history_start_ordinal": 3])
        let forkMissingCacheCache = LocalCodexUsageReader.Cache()
        let forkMissingCache = try LocalCodexUsageReader.scan(directory: forkMissingCacheRoot, now: now,
                                                               cache: forkMissingCacheCache)
        check(bp39Detail(forkMissingCache, input: 60).map { bp39CacheState($0.usage) == .notReported } == true
            && forkMissingCache.cacheCoverage.cachedInputTokens == nil
            && forkMissingCache.input == 160 && forkMissingCache.output == 50
            && forkMissingCache.total == 210,
              "DM-A03 missing fork cache baseline stays unknown and never substitutes zero")
        try bp39AssertWarmScan(forkMissingCacheRoot, now: now, cache: forkMissingCacheCache,
                               cold: forkMissingCache, label: "DM-A03 missing fork cache baseline")

        let turnRoot = try fixtureDirectory("bp39-a03-turn-baseline")
        defer { try? FileManager.default.removeItem(at: turnRoot.deletingLastPathComponent()) }
        try writeSession(in: turnRoot, uuid: "a0030003-0003-4003-8003-000000000003", events: [
            bp39TokenEvent(at: now.addingTimeInterval(-3), input: 100, output: 20, total: 120, cache: .raw("40")),
            try turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "bp39-turn-baseline"),
            bp39TokenEvent(at: now.addingTimeInterval(-1), input: 160, output: 50, total: 210, cache: .raw("70")),
            try turnBoundary(at: now, type: "task_complete", id: "bp39-turn-baseline", durationMS: 1000)], modified: now)
        let turnCache = LocalCodexUsageReader.Cache()
        let turnBaseline = try LocalCodexUsageReader.scan(directory: turnRoot, now: now, cache: turnCache)
        check(turnBaseline.lastTurn?.outputTokens == 30
            && turnBaseline.details.flatMap { $0.turns }.first.map { $0.usage.input == 60 && bp39CacheState($0.usage) == .value(30) } == true,
              "DM-A03 complete-turn cache uses its own baseline and shares lastTurn projection")
        try bp39AssertWarmScan(turnRoot, now: now, cache: turnCache, cold: turnBaseline,
                               label: "DM-A03 complete-turn baseline")

        let turnInChainMissingRoot = try fixtureDirectory("bp39-a03-turn-in-chain-missing")
        defer { try? FileManager.default.removeItem(at: turnInChainMissingRoot.deletingLastPathComponent()) }
        try writeSession(in: turnInChainMissingRoot, uuid: "a0030003-0003-4003-8003-000000000009", events: [
            bp39TokenEvent(at: now.addingTimeInterval(-4), input: 100, output: 20, total: 120,
                           cache: .raw("40")),
            try turnBoundary(at: now.addingTimeInterval(-3), type: "task_started", id: "bp39-turn-missing-cache"),
            bp39TokenEvent(at: now.addingTimeInterval(-2), input: 120, output: 30, total: 150,
                           cache: .missing),
            bp39TokenEvent(at: now.addingTimeInterval(-1), input: 160, output: 50, total: 210,
                           cache: .raw("70")),
            try turnBoundary(at: now, type: "task_complete", id: "bp39-turn-missing-cache", durationMS: 1000)], modified: now)
        let turnInChainMissingStore = LocalCodexUsageReader.Cache()
        let turnInChainMissing = try LocalCodexUsageReader.scan(directory: turnInChainMissingRoot, now: now,
                                                                cache: turnInChainMissingStore)
        let turnInChainMissingDetail = bp39Detail(turnInChainMissing, input: 160)
        check(turnInChainMissingDetail.map { bp39CacheState($0.usage) == .notReported
                && $0.usage.input == 160 && $0.usage.output == 50 && $0.usage.total == 210 } == true
            && turnInChainMissingDetail?.turns.first.map { $0.usage.input == 60
                && $0.usage.output == 30 && $0.usage.total == 90
                && bp39CacheState($0.usage) == .notReported } == true,
              "DM-A03 an in-turn missing cache marks both the root chain and turn unknown while preserving base totals")
        try bp39AssertWarmScan(turnInChainMissingRoot, now: now, cache: turnInChainMissingStore,
                               cold: turnInChainMissing, label: "DM-A03 in-turn missing cache")

        let rootMissingTurnKnownRoot = try fixtureDirectory("bp39-a03-root-missing-turn-known-cache")
        defer { try? FileManager.default.removeItem(at: rootMissingTurnKnownRoot.deletingLastPathComponent()) }
        try writeSession(in: rootMissingTurnKnownRoot, uuid: "a0030003-0003-4003-8003-000000000010", events: [
            bp39TokenEvent(at: now.addingTimeInterval(-4), input: 80, output: 10, total: 90,
                           cache: .missing),
            bp39TokenEvent(at: now.addingTimeInterval(-3), input: 100, output: 20, total: 120,
                           cache: .raw("40")),
            try turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "bp39-root-missing-turn-known"),
            bp39TokenEvent(at: now.addingTimeInterval(-1), input: 160, output: 50, total: 210,
                           cache: .raw("70")),
            try turnBoundary(at: now, type: "task_complete", id: "bp39-root-missing-turn-known", durationMS: 1000)], modified: now)
        let rootMissingTurnKnownStore = LocalCodexUsageReader.Cache()
        let rootMissingTurnKnown = try LocalCodexUsageReader.scan(directory: rootMissingTurnKnownRoot, now: now,
                                                                   cache: rootMissingTurnKnownStore)
        let rootMissingTurnKnownDetail = bp39Detail(rootMissingTurnKnown, input: 160)
        check(rootMissingTurnKnownDetail.map { bp39CacheState($0.usage) == .notReported } == true
            && rootMissingTurnKnownDetail?.turns.first.map { $0.usage.input == 60
                && $0.usage.output == 30 && $0.usage.total == 90
                && bp39CacheState($0.usage) == .value(30) } == true,
              "DM-A03 an early root cache gap does not poison a later complete turn cache baseline")
        try bp39AssertWarmScan(rootMissingTurnKnownRoot, now: now, cache: rootMissingTurnKnownStore,
                               cold: rootMissingTurnKnown, label: "DM-A03 root missing with known turn")

        let turnBaselineMissingRoot = try fixtureDirectory("bp39-a03-turn-baseline-missing")
        defer { try? FileManager.default.removeItem(at: turnBaselineMissingRoot.deletingLastPathComponent()) }
        try writeSession(in: turnBaselineMissingRoot, uuid: "a0030003-0003-4003-8003-000000000011", events: [
            bp39TokenEvent(at: now.addingTimeInterval(-4), input: 80, output: 10, total: 90,
                           cache: .raw("40")),
            bp39TokenEvent(at: now.addingTimeInterval(-3), input: 100, output: 20, total: 120,
                           cache: .missing),
            try turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "bp39-turn-baseline-missing"),
            bp39TokenEvent(at: now.addingTimeInterval(-1), input: 160, output: 50, total: 210,
                           cache: .raw("70")),
            try turnBoundary(at: now, type: "task_complete", id: "bp39-turn-baseline-missing", durationMS: 1000)], modified: now)
        let turnBaselineMissingStore = LocalCodexUsageReader.Cache()
        let turnBaselineMissing = try LocalCodexUsageReader.scan(directory: turnBaselineMissingRoot, now: now,
                                                                   cache: turnBaselineMissingStore)
        let turnBaselineMissingDetail = bp39Detail(turnBaselineMissing, input: 160)
        check(turnBaselineMissingDetail.map { bp39CacheState($0.usage) == .notReported } == true
            && turnBaselineMissingDetail?.turns.first.map { $0.usage.input == 60
                && $0.usage.output == 30 && $0.usage.total == 90
                && $0.durationSeconds == 1 && bp39CacheState($0.usage) == .notReported } == true
            && turnBaselineMissing.lastTurn?.outputTokens == 30,
              "DM-A03 a missing turn baseline keeps legal input/output/elapsed evidence while cache stays unknown")
        try bp39AssertWarmScan(turnBaselineMissingRoot, now: now, cache: turnBaselineMissingStore,
                               cold: turnBaselineMissing, label: "DM-A03 missing turn baseline")

        let rollbackRoot = try fixtureDirectory("bp39-a03-input-rollback")
        defer { try? FileManager.default.removeItem(at: rollbackRoot.deletingLastPathComponent()) }
        try writeSession(in: rollbackRoot, uuid: "a0030003-0003-4003-8003-000000000004", events: [
            bp39TokenEvent(at: now.addingTimeInterval(-3), input: 100, output: 20, total: 120, cache: .raw("40")),
            try turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "bp39-turn-rollback"),
            bp39TokenEvent(at: now.addingTimeInterval(-1), input: 90, output: 30, total: 150, cache: .raw("40")),
            try turnBoundary(at: now, type: "task_complete", id: "bp39-turn-rollback", durationMS: 1000)], modified: now)
        let rollbackCache = LocalCodexUsageReader.Cache()
        let rolledInput = try LocalCodexUsageReader.scan(directory: rollbackRoot, now: now, cache: rollbackCache)
        let rolledTurn: LocalCodexTurnDetail? = rolledInput.details.flatMap { $0.turns }.first
        let rolledUsageMatches: Bool = rolledTurn.map {
            $0.usage.input == nil && $0.usage.output == 10 && $0.usage.total == 30
        } == true
        check(rolledInput.lastTurn?.outputTokens == 10
            && rolledUsageMatches,
              "DM-A03 legal input rollback preserves old output/total/duration turn evidence")
        try bp39AssertWarmScan(rollbackRoot, now: now, cache: rollbackCache, cold: rolledInput,
                               label: "DM-A03 input rollback")

        let missingInputRoot = try fixtureDirectory("bp39-a03-input-missing")
        defer { try? FileManager.default.removeItem(at: missingInputRoot.deletingLastPathComponent()) }
        try writeSession(in: missingInputRoot, uuid: "a0030003-0003-4003-8003-000000000005", events: [
            bp39TokenEvent(at: now.addingTimeInterval(-3), input: 100, output: 20, total: 120, cache: .raw("40")),
            try turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "bp39-turn-missing"),
            rawTokenEvent(at: now.addingTimeInterval(-1), inputLiteral: "null", outputLiteral: "30", totalLiteral: "150"),
            try turnBoundary(at: now, type: "task_complete", id: "bp39-turn-missing", durationMS: 1000)], modified: now)
        let missingInputCache = LocalCodexUsageReader.Cache()
        let missingInput = try LocalCodexUsageReader.scan(directory: missingInputRoot, now: now,
                                                           cache: missingInputCache)
        check(missingInput.lastTurn == nil,
              "DM-A03 missing input keeps the existing whole-usage parser rejection")
        try bp39AssertWarmScan(missingInputRoot, now: now, cache: missingInputCache, cold: missingInput,
                               label: "DM-A03 missing input")

        let crossChainRoot = try fixtureDirectory("bp39-a03-cross-chain-isolation")
        defer { try? FileManager.default.removeItem(at: crossChainRoot.deletingLastPathComponent()) }
        let validRootID = "a0030003-0003-4003-8003-000000000007"
        let invalidTurnID = "a0030003-0003-4003-8003-000000000008"
        try writeSession(in: crossChainRoot, uuid: validRootID, events: [
            bp39TokenEvent(at: now.addingTimeInterval(-2), input: 100, output: 20, cache: .raw("40")),
            bp39TokenEvent(at: now, input: 110, output: 25, cache: .raw("50"))], modified: now)
        try writeSession(in: crossChainRoot, uuid: invalidTurnID, events: [
            bp39TokenEvent(at: now.addingTimeInterval(-3), input: 100, output: 20, cache: .raw("40")),
            try turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "bp39-cross-chain"),
            bp39TokenEvent(at: now.addingTimeInterval(-1), input: 120, output: 30, cache: .raw("true")),
            try turnBoundary(at: now, type: "task_complete", id: "bp39-cross-chain", durationMS: 1000)], modified: now)
        let crossChainCache = LocalCodexUsageReader.Cache()
        let crossChain = try LocalCodexUsageReader.scan(directory: crossChainRoot, now: now,
                                                         cache: crossChainCache)
        let validRootDetail = crossChain.details.first { $0.turns.isEmpty && $0.usage.input == 110 }
        let invalidTurnDetail = crossChain.details.first { !$0.turns.isEmpty }
        check(validRootDetail.map { bp39CacheState($0.usage) == .value(50) } == true
            && invalidTurnDetail?.turns.first.map { bp39CacheState($0.usage) == .invalid } == true,
              "DM-A03 root and complete-turn cache chains retain independent baselines and coverage")
        try bp39AssertWarmScan(crossChainRoot, now: now, cache: crossChainCache, cold: crossChain,
                               label: "DM-A03 cross-chain isolation")

        // A source that cannot establish root contribution must not gate an
        // independently complete turn. Pair the same chain with a known root.
        for (label, source, uuid, isKnownRoot) in [
            ("root", "cli", "a0030003-0003-4003-8003-000000000012", true),
            ("unknown-source", "futureSource", "a0030003-0003-4003-8003-000000000013", false)
        ] {
            let independentTurnRoot = try fixtureDirectory("bp39-a03-independent-turn-\(label)")
            defer { try? FileManager.default.removeItem(at: independentTurnRoot.deletingLastPathComponent()) }
            try writeSession(in: independentTurnRoot, uuid: uuid, events: [
                bp39TokenEvent(at: now.addingTimeInterval(-3), input: 100, output: 20,
                               total: 120, cache: .raw("40")),
                try turnBoundary(at: now.addingTimeInterval(-2), type: "task_started",
                                 id: "bp39-independent-turn"),
                bp39TokenEvent(at: now.addingTimeInterval(-1), input: 160, output: 50,
                               total: 210, cache: .raw("70")),
                try turnBoundary(at: now, type: "task_complete", id: "bp39-independent-turn",
                                 durationMS: 1000)], modified: now, metadataSource: source)
            let independentTurnCache = LocalCodexUsageReader.Cache()
            let independentTurn = try LocalCodexUsageReader.scan(directory: independentTurnRoot,
                                                                  now: now, cache: independentTurnCache)
            let independentDetail = independentTurn.details.first
            if isKnownRoot {
                check(independentTurn.input == 160 && independentTurn.output == 50
                    && independentTurn.total == 210 && independentTurn.knownThreadCount == 1
                    && independentTurn.unknownThreadCount == 0 && independentTurn.hasCompleteAccounting,
                      "DM-A03 paired root source preserves known base contribution")
                check(independentTurn.details.count == 1 && independentDetail?.kind == .root
                    && independentDetail?.usage.input == 160 && independentDetail?.usage.output == 50
                    && independentDetail?.usage.total == 210,
                      "DM-A03 paired root source retains its known base detail")
            } else {
                check(independentTurn.input == 0 && independentTurn.output == 0
                    && independentTurn.total == 0 && independentTurn.knownThreadCount == 0
                    && independentTurn.unknownThreadCount == 1 && !independentTurn.hasCompleteAccounting,
                      "DM-A03 unknown source keeps base contribution unknown without borrowing the turn")
                check(independentTurn.details.count == 1 && independentDetail?.kind == .unknown
                    && independentDetail?.usage.input == nil && independentDetail?.usage.output == nil
                    && independentDetail?.usage.total == nil,
                      "DM-A03 unknown source retains an unknown base detail row")
            }
            let independentCompleteTurn = independentDetail?.turns.first
            check(independentDetail?.turns.count == 1
                && independentCompleteTurn.map { $0.usage.input == 60 && $0.usage.output == 30
                    && $0.usage.total == 90 && bp39CacheState($0.usage) == .value(30)
                    && $0.usage.uncachedInput == 30 && $0.durationSeconds == 1
                    && $0.outputTPS == 30 && $0.completedAt == now } == true,
                  "DM-A03 \(label) independently complete turn preserves input/output/total/cache/elapsed")
            check(independentTurn.lastTurn?.outputTokens == 30
                && independentTurn.lastTurn?.durationSeconds == 1
                && independentTurn.lastTurn?.outputTPS == 30
                && independentTurn.lastTurn?.completedAt == independentCompleteTurn?.completedAt,
                  "DM-A03 \(label) lastTurn aliases the same independent complete-turn projection")
            try bp39AssertWarmScan(independentTurnRoot, now: now, cache: independentTurnCache,
                                   cold: independentTurn, label: "DM-A03 independent turn \(label)")
        }

        // DM-A04: aggregate ratio-of-sums, zero denominator, exact integer
        // controls and matched-subset disclosure.
        let ratioRoot = try fixtureDirectory("bp39-a04-ratio")
        defer { try? FileManager.default.removeItem(at: ratioRoot.deletingLastPathComponent()) }
        try writeSession(in: ratioRoot, uuid: "a0040004-0004-4004-8004-000000000001", events: [
            bp39TokenEvent(at: now.addingTimeInterval(-1), input: 100, output: 1, cache: .raw("90"))], modified: now.addingTimeInterval(-1))
        try writeSession(in: ratioRoot, uuid: "a0040004-0004-4004-8004-000000000002", events: [
            bp39TokenEvent(at: now, input: 900, output: 1, cache: .raw("90"))], modified: now)
        let ratioCache = LocalCodexUsageReader.Cache()
        let ratio = try LocalCodexUsageReader.scan(directory: ratioRoot, now: now, cache: ratioCache)
        check(ratio.cacheCoverage.cachedInputTokens == 180 && ratio.cacheCoverage.uncachedInputTokens == 820
            && ratio.cacheCoverage.hitRate.map { abs($0 - 0.18) < 0.000_001 } == true,
              "DM-A04 cache hit rate is weighted by exact input sums")
        try bp39AssertWarmScan(ratioRoot, now: now, cache: ratioCache, cold: ratio,
                               label: "DM-A04 weighted ratio")
        let zeroRateRoot = try fixtureDirectory("bp39-a04-zero-rate")
        defer { try? FileManager.default.removeItem(at: zeroRateRoot.deletingLastPathComponent()) }
        try writeSession(in: zeroRateRoot, uuid: "a0040004-0004-4004-8004-000000000003", events: [
            bp39TokenEvent(at: now, input: 0, output: 1, cache: .raw("0"))], modified: now)
        let zeroRateCache = LocalCodexUsageReader.Cache()
        let zeroRate = try LocalCodexUsageReader.scan(directory: zeroRateRoot, now: now, cache: zeroRateCache)
        check(zeroRate.cacheCoverage.cachedInputTokens == 0 && zeroRate.cacheCoverage.uncachedInputTokens == 0
            && zeroRate.cacheCoverage.hitRate == nil,
              "DM-A04 zero input has no applicable ratio while preserving known zero")
        try bp39AssertWarmScan(zeroRateRoot, now: now, cache: zeroRateCache, cold: zeroRate,
                               label: "DM-A04 zero denominator")
        let extremeRoot = try fixtureDirectory("bp39-a04-extreme")
        defer { try? FileManager.default.removeItem(at: extremeRoot.deletingLastPathComponent()) }
        try writeSession(in: extremeRoot, uuid: "a0040004-0004-4004-8004-000000000004", events: [
            bp39TokenEvent(at: now, input: Int.max, output: 0, total: Int.max,
                           cache: .raw(String(Int.max - 1)))], modified: now)
        let extremeCache = LocalCodexUsageReader.Cache()
        let extreme = try LocalCodexUsageReader.scan(directory: extremeRoot, now: now, cache: extremeCache)
        check(extreme.cacheCoverage.cachedInputTokens == Int.max - 1
            && extreme.cacheCoverage.uncachedInputTokens == 1
            && extreme.cacheCoverage.matchedInputTokens == Int.max
            && extreme.cacheCoverage.matchedCachedInputTokens == Int.max - 1
            && extreme.cacheCoverage.hitRate != nil,
              "DM-A04 Int.max minus one is not exact full hit")
        try bp39AssertWarmScan(extremeRoot, now: now, cache: extremeCache, cold: extreme,
                               label: "DM-A04 Int.max boundary")
        let fullHitRoot = try fixtureDirectory("bp39-a04-full-hit")
        defer { try? FileManager.default.removeItem(at: fullHitRoot.deletingLastPathComponent()) }
        try writeSession(in: fullHitRoot, uuid: "a0040004-0004-4004-8004-000000000007", events: [
            bp39TokenEvent(at: now, input: 10, output: 1, total: 11, cache: .raw("10"))], modified: now)
        let fullHitCache = LocalCodexUsageReader.Cache()
        let fullHit = try LocalCodexUsageReader.scan(directory: fullHitRoot, now: now, cache: fullHitCache)
        check(fullHit.cacheCoverage.cachedInputTokens == 10
            && fullHit.cacheCoverage.uncachedInputTokens == 0
            && fullHit.cacheCoverage.hitRate == 1,
              "DM-A04 exact full-hit control remains 100 percent rather than an approximate near-one")
        try bp39AssertWarmScan(fullHitRoot, now: now, cache: fullHitCache, cold: fullHit,
                               label: "DM-A04 full hit")
        let partialRatioRoot = try fixtureDirectory("bp39-a04-matched-subset")
        defer { try? FileManager.default.removeItem(at: partialRatioRoot.deletingLastPathComponent()) }
        try writeSession(in: partialRatioRoot, uuid: "a0040004-0004-4004-8004-000000000005", events: [
            bp39TokenEvent(at: now.addingTimeInterval(-1), input: 100, output: 1, cache: .raw("90"))], modified: now.addingTimeInterval(-1))
        try writeSession(in: partialRatioRoot, uuid: "a0040004-0004-4004-8004-000000000006", events: [
            bp39TokenEvent(at: now, input: 900, output: 1, cache: .missing)], modified: now)
        let matchedSubsetCache = LocalCodexUsageReader.Cache()
        let matchedSubset = try LocalCodexUsageReader.scan(directory: partialRatioRoot, now: now,
                                                            cache: matchedSubsetCache)
        check(matchedSubset.input == 1000 && matchedSubset.cacheCoverage.state == .partial
            && matchedSubset.cacheCoverage.matchedInputTokens == 100
            && matchedSubset.cacheCoverage.matchedCachedInputTokens == 90
            && matchedSubset.cacheCoverage.hitRate == nil,
              "DM-A04 partial cache never borrows a denominator from unknown rows")
        try bp39AssertWarmScan(partialRatioRoot, now: now, cache: matchedSubsetCache,
                               cold: matchedSubset, label: "DM-A04 matched subset")

        // DM-A05: eligibility is calculated before deterministic per-thread and
        // global display caps; latest lastTurn survives both caps.
        let perThreadRoot = try fixtureDirectory("bp39-a05-per-thread")
        defer { try? FileManager.default.removeItem(at: perThreadRoot.deletingLastPathComponent()) }
        try writeSession(in: perThreadRoot, uuid: "a0050005-0005-4005-8005-000000000001",
            events: bp39CompleteTurnEvents(now: now, turnCount: 17, varyingOutput: true), modified: now)
        let perThreadCache = LocalCodexUsageReader.Cache()
        let perThread = try LocalCodexUsageReader.scan(directory: perThreadRoot, now: now, cache: perThreadCache)
        check(perThread.details.count == 1 && perThread.details[0].turns.count == 16
            && perThread.input == 170 && perThread.output == 153 && perThread.total == 323
            && perThread.detailLimited && perThread.lastTurn?.outputTokens == 17,
              "DM-A05 per-thread 16-row cap keeps the newest complete turn and marks detailLimited")
        check(perThread.details[0].turns == perThread.details[0].turns.sorted {
            $0.completedAt == $1.completedAt ? $0.ordinal < $1.ordinal : $0.completedAt < $1.completedAt
        }, "DM-A05 detail turns return in completed-time/source-order ascending")
        let retainedPerThreadTurns = perThread.details[0].turns
        check(retainedPerThreadTurns.first?.usage.output == 2
            && retainedPerThreadTurns.last?.usage.output == 17
            && retainedPerThreadTurns.allSatisfy { $0.usage.output != 1 }
            && retainedPerThreadTurns.map(\.completedAt).min() == now.addingTimeInterval(-65)
            && retainedPerThreadTurns.map(\.completedAt).max() == now.addingTimeInterval(-5),
              "DM-A05 per-thread cap drops the oldest dated row while preserving distinct numeric rows and base totals")
        try bp39AssertWarmScan(perThreadRoot, now: now, cache: perThreadCache, cold: perThread,
                               label: "DM-A05 per-thread cap")

        let globalRoot = try fixtureDirectory("bp39-a05-global")
        defer { try? FileManager.default.removeItem(at: globalRoot.deletingLastPathComponent()) }
        for thread in 0..<9 {
            let uuid = String(format: "a0050005-0005-4005-8005-%012d", thread + 10)
            try writeSession(in: globalRoot, uuid: uuid,
                events: bp39CompleteTurnEvents(now: now, turnCount: 16, varyingOutput: true,
                                               timeOffset: Double(thread) - 8),
                modified: now.addingTimeInterval(Double(thread) - 8))
        }
        let globalCache = LocalCodexUsageReader.Cache()
        let global = try LocalCodexUsageReader.scan(directory: globalRoot, now: now, cache: globalCache)
        check(global.details.reduce(0) { $0 + $1.turns.count } == 128 && global.detailLimited
            && global.input == 1440 && global.output == 1224 && global.total == 2664
            && global.lastTurn?.outputTokens == 16,
              "DM-A05 global 128-row cap is independent of base accounting and lastTurn")
        for detail in global.details { check(detail.turns.count <= 16, "DM-A05 each global-cap thread remains within 16 rows") }
        let globalTurns = global.details.flatMap(\.turns)
        check(globalTurns.map(\.completedAt).min() == now.addingTimeInterval(-64)
            && globalTurns.map(\.completedAt).max() == now.addingTimeInterval(-5)
            && globalTurns.allSatisfy { $0.usage.output != 1 }
            && globalTurns.contains { $0.usage.output == 16 }
            && globalTurns.contains { $0.completedAt == now.addingTimeInterval(-64) && $0.usage.output == 3 }
            && !globalTurns.contains { $0.completedAt == now.addingTimeInterval(-64) && $0.usage.output == 2 },
              "DM-A05 global cap keeps the newest 128 interleaved rows and resolves the -64 tie by source order")
        try bp39AssertWarmScan(globalRoot, now: now, cache: globalCache, cold: global,
                               label: "DM-A05 global cap")

        let exactFilesRoot = try fixtureDirectory("bp39-a05-exact-32-files")
        defer { try? FileManager.default.removeItem(at: exactFilesRoot.deletingLastPathComponent()) }
        for index in 0..<32 {
            let uuid = String(format: "a0050005-0005-4005-8005-%012d", index + 100)
            try writeSession(in: exactFilesRoot, uuid: uuid,
                events: bp39CompleteTurnEvents(now: now, turnCount: 1),
                modified: now.addingTimeInterval(-Double(index)))
        }
        let exactFilesCache = LocalCodexUsageReader.Cache()
        let exactFiles = try LocalCodexUsageReader.scan(directory: exactFilesRoot, now: now,
                                                         cache: exactFilesCache)
        check(exactFiles.filesScanned == 32 && exactFiles.details.count <= 32 && !exactFiles.isLimited,
              "DM-A05 exactly 32 physical files does not invent a 33rd limitation")
        try bp39AssertWarmScan(exactFilesRoot, now: now, cache: exactFilesCache, cold: exactFiles,
                               label: "DM-A05 exact 32 files")

        let overFilesRoot = try fixtureDirectory("bp39-a05-33-files")
        defer { try? FileManager.default.removeItem(at: overFilesRoot.deletingLastPathComponent()) }
        for index in 0..<33 {
            let uuid = String(format: "a0050005-0005-4005-8005-%012d", index + 200)
            try writeSession(in: overFilesRoot, uuid: uuid,
                events: bp39CompleteTurnEvents(now: now, turnCount: 1),
                modified: now.addingTimeInterval(-Double(index)))
        }
        let overFilesCache = LocalCodexUsageReader.Cache()
        let overFiles = try LocalCodexUsageReader.scan(directory: overFilesRoot, now: now,
                                                        cache: overFilesCache)
        check(overFiles.isLimited && overFiles.filesScanned <= 32 && overFiles.details.count <= 32
            && Set(overFiles.details.map(\.opaqueKey)).count == overFiles.details.count
            && !overFiles.detailLimited,
              "DM-A05 33rd physical file sets existing isLimited without fabricating detail coverage")
        try bp39AssertWarmScan(overFilesRoot, now: now, cache: overFilesCache, cold: overFiles,
                               label: "DM-A05 33 files")

        let opaqueBatchRoot = try fixtureDirectory("bp39-a06-opaque-batch-a")
        defer { try? FileManager.default.removeItem(at: opaqueBatchRoot.deletingLastPathComponent()) }
        for index in 0..<32 {
            let uuid = String(format: "a0060006-0006-4006-8006-%012d", index + 100)
            try writeSession(in: opaqueBatchRoot, uuid: uuid, events: [
                bp39TokenEvent(at: now.addingTimeInterval(-Double(index + 1)), input: index + 1,
                               output: 2, total: index + 3, cache: .raw("0"))],
                modified: now.addingTimeInterval(-Double(index + 1)))
        }
        let opaqueCache = LocalCodexUsageReader.Cache()
        let opaqueBatch = try LocalCodexUsageReader.scan(directory: opaqueBatchRoot, now: now, cache: opaqueCache)
        let batchKeys = Set(opaqueBatch.details.map(\.opaqueKey))
        check(opaqueBatch.details.count == 32 && batchKeys.count == 32
            && opaqueBatch.knownThreadCount == 32
            && opaqueBatch.input == 528 && opaqueBatch.output == 64 && opaqueBatch.total == 592,
              "DM-A06 opaque mapping keeps 32 known positive base rows with unique bounded keys")
        check(bp39MirrorContainsString(opaqueCache, "a0060006-0006-4006-8006-000000000100")
            && bp39MirrorContainsString(opaqueCache, "a0060006-0006-4006-8006-000000000101"),
              "DM-A06 private cache mapping retains current synthetic identities for bounded lookup")
        try bp39AssertWarmScan(opaqueBatchRoot, now: now, cache: opaqueCache, cold: opaqueBatch,
                               label: "DM-A06 opaque mapping")
        let removedURL = sessionURL(in: opaqueBatchRoot,
            uuid: "a0060006-0006-4006-8006-000000000100")
        try FileManager.default.removeItem(at: removedURL)
        let afterDelete = try LocalCodexUsageReader.scan(directory: opaqueBatchRoot, now: now, cache: opaqueCache)
        check(afterDelete.details.count == 31
            && bp39Detail(afterDelete, input: 1) == nil
            && Set(afterDelete.details.map(\.opaqueKey)).count == 31,
              "DM-A06 deleting a physical file removes its detail and opaque mapping on replacement")
        check(!bp39MirrorContainsString(opaqueCache, "a0060006-0006-4006-8006-000000000100")
            && bp39MirrorContainsString(opaqueCache, "a0060006-0006-4006-8006-000000000101"),
              "DM-A06 deleting a file releases its private synthetic identity while retaining a live control")
        try bp39AssertWarmScan(opaqueBatchRoot, now: now, cache: opaqueCache, cold: afterDelete,
                               label: "DM-A06 deleted opaque mapping")
        let opaqueBatchRootB = try fixtureDirectory("bp39-a06-opaque-batch-b")
        defer { try? FileManager.default.removeItem(at: opaqueBatchRootB.deletingLastPathComponent()) }
        try writeSession(in: opaqueBatchRootB, uuid: "a0060006-0006-4006-8006-000000000200", events: [
            bp39TokenEvent(at: now, input: 77, output: 8, total: 85, cache: .raw("7"))], modified: now,
            metadataFields: ["model_provider": "synthetic"])
        let switchedRoot = try LocalCodexUsageReader.scan(directory: opaqueBatchRootB, now: now, cache: opaqueCache)
        check(switchedRoot.details.count == 1 && bp39Detail(switchedRoot, input: 77) != nil
            && Set(switchedRoot.details.map(\.opaqueKey)).count == 1
            && switchedRoot.details.allSatisfy { $0.usage.input != 1 },
              "DM-A06 changing the synthetic root drops the prior batch without retaining stale rows")
        check(!bp39MirrorContainsString(opaqueCache, "a0060006-0006-4006-8006-000000000101")
            && bp39MirrorContainsString(opaqueCache, "a0060006-0006-4006-8006-000000000200"),
              "DM-A06 changing roots releases the old private batch and retains the current identity")
        try bp39AssertWarmScan(opaqueBatchRootB, now: now, cache: opaqueCache, cold: switchedRoot,
                               label: "DM-A06 switched synthetic root")
        let switchedRoute = try LocalCodexUsageReader.scan(directory: opaqueBatchRootB, now: now,
            cache: opaqueCache, routeContext: .verified(provider: "synthetic", origin: "https://synthetic.example"))
        check(bp39MirrorContainsString(opaqueCache, "a0060006-0006-4006-8006-000000000200"),
              "DM-A06 matching route retains the current private identity before route rejection")
        try bp39AssertWarmScan(opaqueBatchRootB, now: now, cache: opaqueCache, cold: switchedRoute,
                               label: "DM-A06 matching route", routeContext: .verified(provider: "synthetic", origin: "https://synthetic.example"))
        let mismatchedRoute = try LocalCodexUsageReader.scan(directory: opaqueBatchRootB, now: now,
            cache: opaqueCache, routeContext: .verified(provider: "other", origin: "https://other.example"))
        check(switchedRoute.details.count == 1 && bp39Detail(switchedRoute, input: 77) != nil
            && mismatchedRoute.knownThreadCount == 0 && mismatchedRoute.total == 0,
              "DM-A06 route changes clear opaque state and cannot restore rows from another source")
        check(mismatchedRoute.details.isEmpty,
              "DM-A06 mismatched route exposes no stale detail rows")
        try bp39AssertWarmScan(opaqueBatchRootB, now: now, cache: opaqueCache, cold: mismatchedRoute,
                               label: "DM-A06 mismatched route", routeContext: .verified(provider: "other", origin: "https://other.example"))
        check(!bp39MirrorContainsString(opaqueCache, "a0060006-0006-4006-8006-000000000200"),
              "DM-A06 mismatched route releases the prior private identity")

        // DM-A06: snapshot/detail reflection and serialized descriptions cannot
        // expose raw source identity, path, body, account or tool canaries.
        let privacyRoot = try fixtureDirectory("bp39-a06-privacy")
        defer { try? FileManager.default.removeItem(at: privacyRoot.deletingLastPathComponent()) }
        try writeSession(in: privacyRoot, uuid: "a0060006-0006-4006-8006-000000000001", events: [
            bp39TokenEvent(at: now.addingTimeInterval(-3), input: 100, output: 20, total: 120,
                           cache: .raw("40")),
            try turnBoundary(at: now.addingTimeInterval(-2), type: "task_started", id: "bp39-privacy-turn"),
            bp39TokenEvent(at: now.addingTimeInterval(-1), input: 160, output: 50, total: 210,
                           cache: .raw("70")),
            try turnBoundary(at: now, type: "task_complete", id: "bp39-privacy-turn", durationMS: 1000)], modified: now,
            metadataFields: ["account": "bp39-account-canary", "tool": "bp39-tool-canary",
                             "body": "bp39-body-canary", "origin": "bp39-origin-canary"])
        let privacyCache = LocalCodexUsageReader.Cache()
        let privacy = try LocalCodexUsageReader.scan(directory: privacyRoot, now: now, cache: privacyCache)
        let printed = String(describing: privacy)
        for canary in ["a0060006-0006-4006-8006-000000000001", "bp39-account-canary",
                       "bp39-tool-canary", "bp39-body-canary", "bp39-origin-canary", privacyRoot.path] {
            check(!printed.contains(canary), "DM-A06 public snapshot omits (canary) privacy canary")
        }
        check(!bp39MirrorContainsForbiddenValue(privacy),
              "DM-A06 public snapshot/detail mirror contains no String, URL, Data or raw JSON")
        try bp39AssertWarmScan(privacyRoot, now: now, cache: privacyCache, cold: privacy,
                               label: "DM-A06 privacy reflection")

        let snapshotFields = Set(Mirror(reflecting: privacy).children.compactMap(\.label))
        check(snapshotFields == Set(["input", "output", "total", "sessionCount", "filesScanned",
            "isLimited", "latestEventAt", "fiveHour", "sevenDay", "lastTurn", "liveTurn",
            "knownThreadCount", "unknownThreadCount", "unidentifiedFileCount", "subagentCount",
            "forkCount", "readAt", "details", "cacheCoverage", "detailLimited", "quotaDate"]),
              "DM-A06 snapshot reflection exposes only the exact bounded public fields")
        if let thread = privacy.details.first, let turn = thread.turns.first {
            let threadFields = Set(Mirror(reflecting: thread).children.compactMap(\.label))
            let turnFields = Set(Mirror(reflecting: turn).children.compactMap(\.label))
            let usageFields = Set(Mirror(reflecting: thread.usage).children.compactMap(\.label))
            check(threadFields == Set(["opaqueKey", "ordinal", "kind", "usage", "turns"])
                && turnFields == Set(["opaqueKey", "ordinal", "usage", "durationSeconds", "completedAt"])
                && usageFields == Set(["input", "output", "total", "cache"]),
                  "DM-A06 thread, turn and usage reflection exposes only opaque numeric bounded fields")
            check(privacy.input == 160 && privacy.output == 50 && privacy.total == 210
                && thread.usage.input == 160 && thread.usage.output == 50 && thread.usage.total == 210
                && thread.usage.uncachedInput == 90
                && turn.usage.input == 60 && turn.usage.output == 30 && turn.usage.total == 90
                && turn.usage.uncachedInput == 30 && turn.durationSeconds == 1
                && turn.outputTPS == 30 && turn.opaqueKey != 0 && thread.opaqueKey != 0,
                  "DM-A06 privacy fixture carries a non-empty positive thread and complete-turn control")
        } else {
            check(false, "DM-A06 privacy fixture carries a complete public turn row")
            check(false, "DM-A06 privacy fixture carries a complete positive numeric control")
        }

        // DM-A07/A08: UI consumes source/coverage/unknown labels, while the
        // existing completion-relative scheduler remains the only refresh path.
        check(privacy.readAt == now && privacy.details.allSatisfy { $0.kind == .root },
              "DM-A07 snapshot carries observation time and finite lineage only")
        var scheduler = LocalRefreshScheduler()
        if let generation = scheduler.begin(monotonicNow: 10) {
            check(scheduler.complete(generation: generation, monotonicNow: 20)
                && scheduler.begin(monotonicNow: 24.999) == nil
                && scheduler.begin(monotonicNow: 25) != nil,
                  "DM-A08 detailed metrics retains the existing five-second serial schedule")
        } else { check(false, "DM-A08 detailed metrics retains the existing five-second serial schedule") }
    }

    private static func bp39MirrorContainsForbiddenValue(_ value: Any) -> Bool {
        if value is String || value is URL || value is Data { return true }
        return Mirror(reflecting: value).children.contains { bp39MirrorContainsForbiddenValue($0.value) }
    }

    private static func bp39MirrorContainsString(_ value: Any, _ needle: String) -> Bool {
        if let string = value as? String { return string.contains(needle) }
        return Mirror(reflecting: value).children.contains {
            bp39MirrorContainsString($0.value, needle)
        }
    }

#if TOKENSTAT_BP38_C01
    /// Exercises the production scheduler's monotonic API directly. The test
    /// controls both clocks; no wall-clock sleep or external session path is used.
    private static func bp38C01LocalRefreshChecks() throws {
        var scheduler = LocalRefreshScheduler()
        let generation = scheduler.begin(monotonicNow: 10.0)
        check(generation != nil, "BP38 C01 starts a due local read")
        check(scheduler.begin(monotonicNow: 11.0) == nil,
              "BP38 C01 refuses overlapping local reads while one generation is in flight")
        if let generation {
            check(scheduler.complete(generation: generation, monotonicNow: 20.0),
                  "BP38 C01 accepts completion of the active generation")
            check(scheduler.begin(monotonicNow: 24.999) == nil,
                  "BP38 C01 completion plus 4.999 monotonic seconds remains throttled")
            let nextGeneration = scheduler.begin(monotonicNow: 25.0)
            check(nextGeneration != nil,
                  "BP38 C01 permits the next read at completion plus five monotonic seconds")
            if let nextGeneration {
                check(scheduler.complete(generation: nextGeneration, monotonicNow: 30.0),
                      "BP38 C01 releases the second completed generation")
            }
        }

        var canceled = LocalRefreshScheduler()
        let canceledGeneration = canceled.begin(monotonicNow: 100.0)
        _ = canceled.invalidate()
        let newerGeneration = canceled.begin(monotonicNow: 200.0)
        if let canceledGeneration {
            check(!canceled.complete(generation: canceledGeneration, monotonicNow: 200.0),
                  "BP38 C01 old completion cannot complete after invalidation")
        }
        check(newerGeneration != nil && canceled.begin(monotonicNow: 201.0) == nil,
              "BP38 C01 old completion leaves a newer in-flight generation locked")
        if let newerGeneration {
            check(canceled.complete(generation: newerGeneration, monotonicNow: 202.0),
                  "BP38 C01 the newer generation completes only on its own completion")
        }

        var rolledBackWall = Date(timeIntervalSince1970: 2_000_000_000)
        let wallBefore = rolledBackWall
        rolledBackWall = rolledBackWall.addingTimeInterval(-3_600)
        check(rolledBackWall < wallBefore && scheduler.begin(monotonicNow: 34.999) == nil,
              "BP38 C01 wall-clock rollback does not make the monotonic deadline due before +5s")
        check(scheduler.begin(monotonicNow: 35.0) != nil,
              "BP38 C01 monotonic deadline becomes due at +5s despite wall-clock rollback")
    }
#endif
}
