import Darwin
import XCTest
@testable import TokenStatDevWidgetShared

final class DevWidgetProbeTests: XCTestCase {
    private let team = "ABCDE12345.com.tupig.TokenStatMenu.DevWidgetTest"
    private let nowMs: Int64 = 1_800_000_000_000

    func testDevelopmentRefreshPolicyIsBoundedAndSchedulesExpiry() throws {
        let now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        XCTAssertEqual(DevWidgetRefreshPolicy.nextRefresh(after: now), now.addingTimeInterval(300))
        let bytes = try XCTUnwrap(DevWidgetSnapshot.sample(1, atMs: nowMs))
        let snapshot = try XCTUnwrap(DevWidgetSnapshot.decode(bytes, nowMs: nowMs))
        let dates = DevWidgetRefreshPolicy.expiryDates(snapshot: snapshot, after: now)
        XCTAssertEqual(try XCTUnwrap(dates.first).timeIntervalSince(now), 120.001, accuracy: 0.000001)
        XCTAssertEqual(dates.last, now.addingTimeInterval(3600))
        XCTAssertTrue(DevWidgetRefreshPolicy.expiryDates(snapshot: nil, after: now).isEmpty)
    }

    func testSignatureAuthorizationRejectsMissingAdhocAndWrongTeam() {
        XCTAssertTrue(DevGroupGuard.authorizationMatches(group: team, team: "ABCDE12345", flags: 0))
        XCTAssertFalse(DevGroupGuard.authorizationMatches(group: team, team: nil, flags: 0))
        XCTAssertFalse(DevGroupGuard.authorizationMatches(group: team, team: "OTHER12345", flags: 0))
        XCTAssertFalse(DevGroupGuard.authorizationMatches(group: team, team: "ABCDE12345", flags: 2))
        XCTAssertFalse(DevGroupGuard.authorizationMatches(group: team, team: "ABCDE12345", flags: nil))
        var checks = 0
        func authorize() -> Bool { checks += 1; return false }
        _ = DevProbeController.decide(["--widget-probe=9"], configured: { self.team },
            entitlements: { [self.team] }, authorizationMatches: authorize())
        XCTAssertEqual(checks, 0, "坏参数在签名查询前返回")
        _ = DevProbeController.decide(["--widget-probe=1"], configured: { nil },
            entitlements: { nil }, authorizationMatches: authorize())
        XCTAssertEqual(checks, 0, "缺组不查询签名")
        let result = DevProbeController.decide(["--widget-probe=1"], configured: { self.team },
            entitlements: { [self.team] }, authorizationMatches: authorize())
        guard case let .reject(code, reason) = result else { return XCTFail("授权不匹配必须拒绝") }
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(code, 77)
        XCTAssertEqual(reason, "profileAuthorizationMismatch")
    }

    func testPercentEndpointsAndFreshnessBoundaries() throws {
        let sample = try XCTUnwrap(DevWidgetSnapshot.sample(1, atMs: nowMs))
        let text = try XCTUnwrap(String(data: sample, encoding: .utf8))
        for literal in ["0", "100", "12.34", "1e1"] {
            let changed = Data(text.replacingOccurrences(of: "87.66", with: literal).utf8)
            let value = try XCTUnwrap(DevWidgetSnapshot.decode(changed, nowMs: nowMs), literal)
            XCTAssertEqual(value.remainingPercent, Decimal(string: literal), literal)
        }
        for literal in ["-1", "100.01", "true", "\"50\"", "1e999"] {
            XCTAssertNil(DevWidgetSnapshot.decode(Data(text.replacingOccurrences(of: "87.66", with: literal).utf8), nowMs: nowMs), literal)
        }
        XCTAssertNotNil(DevWidgetSnapshot.decode(sample, nowMs: nowMs + 120_000))
        XCTAssertNil(DevWidgetSnapshot.decode(sample, nowMs: nowMs + 120_001))
        XCTAssertNil(DevWidgetSnapshot.decode(sample, nowMs: nowMs - 1))
        let reset = text.replacingOccurrences(of: "\"atMs\":\(nowMs + 3_600_000)", with: "\"atMs\":\(nowMs)")
        XCTAssertNil(try XCTUnwrap(DevWidgetSnapshot.decode(Data(reset.utf8), nowMs: nowMs)).remainingPercent)
    }

    func testSnapshotObjectsRejectEveryMissingAndExtraField() throws {
        let sample = try XCTUnwrap(DevWidgetSnapshot.sample(1, atMs: nowMs))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: sample) as? [String: Any])
        for section in ["root", "hub", "local", "fiveHour", "reset"] {
            let hub = try XCTUnwrap(root["hub"] as? [String: Any])
            let window = try XCTUnwrap(hub["fiveHour"] as? [String: Any])
            let object: [String: Any]
            switch section {
            case "root": object = root
            case "hub": object = hub
            case "local": object = try XCTUnwrap(root["local"] as? [String: Any])
            case "fiveHour": object = window
            default: object = try XCTUnwrap(window["reset"] as? [String: Any])
            }
            for key in Array(object.keys) + ["extra"] {
                var changed = object
                if key == "extra" { changed[key] = 1 } else { changed.removeValue(forKey: key) }
                var payload = root
                if section == "root" { payload = changed }
                else if section == "hub" || section == "local" { payload[section] = changed }
                else {
                    var changedHub = hub
                    if section == "fiveHour" { changedHub["fiveHour"] = changed }
                    else { var changedWindow = window; changedWindow["reset"] = changed; changedHub["fiveHour"] = changedWindow }
                    payload["hub"] = changedHub
                }
                let data = try JSONSerialization.data(withJSONObject: payload)
                XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
                XCTAssertNil(DevWidgetSnapshot.decode(data, nowMs: nowMs), "\(section).\(key)")
            }
        }
    }

    func testMissingGroupPathsRejectBeforeAnyContainerIO() {
        for (configured, entitlements): (String?, [String]?) in [(nil, nil), (team, nil)] {
            let decision = DevProbeController.decide(["--widget-probe=1"], configured: { configured },
                entitlements: { entitlements }, authorizationMatches: true)
            guard case let .reject(code, reason) = decision else { return XCTFail("必须早拒绝") }
            XCTAssertEqual(code, 77)
            XCTAssertEqual(reason, "missingGroupEntitlement")
        }
        let result = DevProbeController.memoryRun(["--widget-probe=1"], actor: "host",
            configuredGroup: team, entitlements: nil, authorizationMatches: true, incoming: nil)
        XCTAssertTrue(result.io.values.allSatisfy { $0 == 0 })
        XCTAssertTrue(result.counts.values.allSatisfy { $0 == 0 })
        XCTAssertNotNil(result.terminalEvent)
    }

    func testReadyMonthlySevenDayAndLocalCacheRejectMissingAndExtraFields() throws {
        let sample = try XCTUnwrap(DevWidgetSnapshot.sample(1, atMs: nowMs))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: sample) as? [String: Any])
        var hub = try XCTUnwrap(root["hub"] as? [String: Any])
        // JSONSerialization的Double往返可能把87.66改为87.659999999999997；
        // 本矩阵验证对象结构，金额/百分比使用十进制字面量避免夹具漂移。
        var five = try XCTUnwrap(hub["fiveHour"] as? [String: Any])
        five["remainingPercent"] = NSDecimalNumber(string: "87.66")
        hub["fiveHour"] = five
        let partialReset: [String: Any] = ["kind": "partial", "month": 2, "day": 29, "hour": 12, "minute": 34]
        let seven: [String: Any] = ["remainingPercent": NSDecimalNumber(string: "12.34"), "reset": partialReset]
        let monthly: [String: Any] = ["usedAmount": NSDecimalNumber(string: "12.34"), "limitAmount": 100, "symbol": "dollar"]
        let cache: [String: Any] = ["state": "complete", "baseRows": 1, "knownRows": 1,
            "missingRows": 0, "invalidRows": 0, "matchedInputTokens": 10, "matchedCachedInputTokens": 4]
        let local: [String: Any] = ["source": "synthetic", "state": "ready", "readAtMs": nowMs,
            "latestEventAtMs": nowMs, "validUntilMs": nowMs + 120_000,
            "inputTokens": 10, "outputTokens": 5, "totalTokens": 15,
            "knownThreads": 1, "unknownThreads": 0, "unidentifiedFiles": 0, "topLevelThreads": 1,
            "isLimited": false, "detailLimited": false, "cache": cache]
        hub["sevenDay"] = seven
        hub["monthly"] = monthly
        root["hub"] = hub
        root["local"] = local
        func decode(_ payload: [String: Any]) throws -> DevWidgetSnapshot? {
            let bytes = try JSONSerialization.data(withJSONObject: payload)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: bytes))
            return DevWidgetSnapshot.decode(bytes, nowMs: nowMs)
        }
        XCTAssertNotNil(try decode(root), "完整ready分区必须先证明可接受")
        for (section, object) in [("sevenDay", seven), ("monthly", monthly), ("local", local), ("cache", cache), ("partialReset", partialReset)] {
            for field in Array(object.keys) + ["extra"] {
                var changed = object
                if field == "extra" { changed[field] = 1 } else { changed.removeValue(forKey: field) }
                var payload = root
                if section == "partialReset" {
                    var changedSeven = seven; changedSeven["reset"] = changed
                    var changedHub = hub; changedHub["sevenDay"] = changedSeven; payload["hub"] = changedHub
                } else if section == "local" { payload["local"] = changed }
                else if section == "cache" {
                    var changedLocal = local; changedLocal["cache"] = changed; payload["local"] = changedLocal
                } else {
                    var changedHub = hub; changedHub[section] = changed; payload["hub"] = changedHub
                }
                XCTAssertNil(try decode(payload), "\(section).\(field)")
            }
        }
        var expiredHub = hub
        expiredHub["observedAtMs"] = nowMs - 1_001
        expiredHub["validUntilMs"] = nowMs - 1
        var payload = root; payload["hub"] = expiredHub
        let hidden = try XCTUnwrap(decode(payload))
        XCTAssertFalse(hidden.hubVisible, "Hub过期不拒绝形状合法的独立local分区")
        XCTAssertNil(hidden.remainingPercent)
        var expiredLocal = local
        expiredLocal["readAtMs"] = nowMs - 1_001
        expiredLocal["latestEventAtMs"] = nowMs - 1_001
        expiredLocal["validUntilMs"] = nowMs - 1
        payload = root; payload["local"] = expiredLocal
        let visible = try XCTUnwrap(decode(payload))
        XCTAssertTrue(visible.hubVisible, "local到期不能连带隐藏有效Hub")
        XCTAssertEqual(visible.remainingPercent, Decimal(string: "87.66"))
        for (field, value) in [("month", 0), ("month", 13), ("day", 30), ("hour", 24), ("minute", 60)] {
            var invalidReset = partialReset; invalidReset[field] = value
            var invalidSeven = seven; invalidSeven["reset"] = invalidReset
            var invalidHub = hub; invalidHub["sevenDay"] = invalidSeven
            payload = root; payload["hub"] = invalidHub
            XCTAssertNil(try decode(payload), "partial reset \(field)=\(value)")
        }
    }

    func testGroupShapeRejectsAnExtraMiddleSegment() {
        XCTAssertTrue(DevWidgetIdentity.hasExactGroupShape(team, allowSynthetic: true))
        XCTAssertFalse(DevWidgetIdentity.hasExactGroupShape(
            "ABCDE12345.extra.com.tupig.TokenStatMenu.DevWidgetTest", allowSynthetic: true))
        XCTAssertFalse(DevWidgetIdentity.hasExactGroupShape("$(C51C_PERSONAL_TEAM_ID)" + team.dropFirst(10)))
        XCTAssertFalse(DevWidgetIdentity.hasExactGroupShape("FICTEAM001" + team.dropFirst(10)))
        XCTAssertTrue(DevWidgetIdentity.hasExactGroupShape("FICTEAM001" + team.dropFirst(10),
                                                           allowSynthetic: true))
    }

    func testMalformedArgumentsNeverAskForTheGroup() {
        var asked = false
        let decision = DevProbeController.decide(["--widget-probe=9"],
                                                 configured: { asked = true; return team },
                                                 entitlements: { asked = true; return [team] },
                                                 authorizationMatches: true)
        guard case let .reject(code, reason) = decision else {
            return XCTFail("malformed argv must reject")
        }
        XCTAssertEqual(code, 64)
        XCTAssertEqual(reason, "invalidArguments")
        XCTAssertFalse(asked)
    }

    func testMissingWrongAndUnauthorizedGroupsRejectBeforeLookup() {
        let cases: [(String, [String]?, Bool, String)] = [
            ("NOTAGROUP", nil, true, "wrongGroupEntitlement"),
            (team, ["other.group"], true, "wrongGroupEntitlement"),
            (team, [team], false, "profileAuthorizationMismatch"),
        ]
        for (configured, entitlements, authorized, expected) in cases {
            let result = DevProbeController.memoryRun(["--widget-probe=1"], actor: "host",
                                                      configuredGroup: configured,
                                                      entitlements: entitlements,
                                                      authorizationMatches: authorized,
                                                      incoming: nil)
            XCTAssertEqual(result.exitCode, 77, expected)
            XCTAssertEqual(result.reason, expected)
            XCTAssertFalse(result.trace.contains("lookup"), expected)
        }
    }

    func testExactPercentsAndPartitionExpiry() {
        guard let sample = DevWidgetSnapshot.sample(1, atMs: nowMs),
              let current = DevWidgetSnapshot.decode(sample, nowMs: nowMs) else {
            return XCTFail("synthetic sample must decode")
        }
        XCTAssertEqual(current.remainingPercent, Decimal(string: "87.66"))
        XCTAssertTrue(current.hubVisible)
        XCTAssertNil(DevWidgetSnapshot.decode(sample, nowMs: nowMs + 120_001),
                     "a snapshot older than two minutes is not current evidence")
    }

    func testTwoGenerationReplacementRequiresTheClaimedFirstGeneration() throws {
        let (root, dirfd) = try temporaryDirectory()
        defer { close(dirfd); try? FileManager.default.removeItem(at: root) }
        let io = DevProbeIOAudit()
        guard let first = DevWidgetSnapshot.sample(1, atMs: nowMs),
              let second = DevWidgetSnapshot.sample(2, atMs: nowMs) else {
            return XCTFail("synthetic samples must exist")
        }
        XCTAssertNil(try DevWidgetSnapshotStore.claimExisting(directory: dirfd, io: io),
                     "an empty container has nothing to claim")

        let owned = try DevWidgetSnapshotStore.writeIfAbsent(first, directory: dirfd, io: io)
        let claimed = try DevWidgetSnapshotStore.claimExisting(directory: dirfd, io: io)
        XCTAssertEqual(claimed, owned, "the first generation is claimable by its own metadata")
        guard let claimed else { return XCTFail("the first generation must be claimable") }

        let replaced = try DevWidgetSnapshotStore.replaceIfOwned(second, expected: claimed,
                                                                 directory: dirfd, io: io)
        XCTAssertNotEqual(replaced.inode, owned.inode, "replacement installs a fresh inode")
        let stored = try Data(contentsOf: root.appendingPathComponent(DevWidgetIdentity.file))
        XCTAssertEqual(stored, second)
        XCTAssertEqual(try DevWidgetSnapshotStore.claimExisting(directory: dirfd, io: io), replaced)

        XCTAssertThrowsError(try DevWidgetSnapshotStore.replaceIfOwned(second, expected: owned,
                                                                       directory: dirfd, io: io)) { error in
            XCTAssertEqual(error as? DevWidgetSnapshotStore.StoreError, .existingObject)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(DevWidgetIdentity.file)), second,
                       "a stale ownership proof never scratches the current generation")
    }

    func testWriteFirstOrReplaceHandlesBothGenerations() throws {
        let (root, dirfd) = try temporaryDirectory()
        defer { close(dirfd); try? FileManager.default.removeItem(at: root) }
        guard let first = DevWidgetSnapshot.sample(1, atMs: nowMs),
              let second = DevWidgetSnapshot.sample(2, atMs: nowMs) else {
            return XCTFail("synthetic samples must exist")
        }
        let initial = try DevWidgetSnapshotStore.writeFirstOrReplace(first, directory: dirfd)
        let replaced = try DevWidgetSnapshotStore.writeFirstOrReplace(second, directory: dirfd)
        XCTAssertNotEqual(initial.inode, replaced.inode,
                          "the second generation replaces the first instead of failing")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(DevWidgetIdentity.file)), second)
    }

    func testClaimRejectsAnUnsafeExistingObjectBeforeWriting() throws {
        let (root, dirfd) = try temporaryDirectory()
        defer { close(dirfd); try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(DevWidgetIdentity.file)
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try DevWidgetSnapshotStore.claimExisting(directory: dirfd)) { error in
            XCTAssertEqual(error as? DevWidgetSnapshotStore.StoreError, .unsafeObject)
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("{}".utf8),
                       "an unowned object is never rewritten")
    }

    private func temporaryDirectory() throws -> (URL, Int32) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenstat-dev-widget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dirfd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dirfd >= 0 else {
            try? FileManager.default.removeItem(at: root)
            throw DevWidgetSnapshotStore.StoreError.ioFailure
        }
        return (root, dirfd)
    }
}
