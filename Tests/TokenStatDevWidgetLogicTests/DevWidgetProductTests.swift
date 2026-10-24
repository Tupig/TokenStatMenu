import Darwin
import Foundation
import WidgetKit
import XCTest

/// 原生 hostless XCTest：编译真实 runner、Store 和 Provider；不启动 App、
/// 不查询真实组或签名，只使用固定虚构身份和测试拥有的临时目录。
final class DevWidgetProductTests: XCTestCase {
    private let group = "ABCDE12345.com.tupig.TokenStatMenu.DevWidgetTest"
    private let time: Int64 = 1_800_000_000_000

    private func report(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    private func assertCounters(_ event: [String: Any], lookups: Int, reads: Int, writes: Int,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let counts = try XCTUnwrap(event["counts"] as? [String: Int], file: file, line: line)
        XCTAssertEqual(Set(counts.keys), Set(DevProbeBoundary.allCases.map(\.rawValue)), file: file, line: line)
        XCTAssertTrue(counts.values.allSatisfy { $0 == 0 }, file: file, line: line)
        let io = try XCTUnwrap(event["io"] as? [String: Int], file: file, line: line)
        XCTAssertEqual(io, ["containerLookups": lookups, "snapshotReads": reads, "snapshotWrites": writes], file: file, line: line)
    }

    private func directory(_ body: (Int32) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        try body(fd)
    }

    func testRealHostRunnerRejectsBeforeIdentityAndIO() throws {
        var identities = 0
        var writes = 0
        let rejected = try XCTUnwrap(DevProbeHostRunner.run(["--widget-probe=9"],
            configured: { identities += 1; return self.group },
            entitlements: { identities += 1; return [self.group] },
            authorize: { identities += 1; return true }, nowMs: { self.time }, pid: 1,
            write: { _, _ in writes += 1 }))
        XCTAssertEqual(rejected.exitCode, 64)
        XCTAssertEqual(identities, 0)
        XCTAssertEqual(writes, 0)
        let event = try report(rejected.terminalEvent)
        XCTAssertEqual(event["event"] as? String, "argvRejected")
        try assertCounters(event, lookups: 0, reads: 0, writes: 0)
        let normal = DevProbeHostRunner.run([], configured: { identities += 1; return nil },
            entitlements: { identities += 1; return nil }, authorize: { identities += 1; return false },
            nowMs: { XCTFail("正常启动不需要探针时钟"); return self.time },
            write: { _, _ in XCTFail("正常启动不写快照") })
        XCTAssertNil(normal)
        XCTAssertEqual(identities, 0)
    }

    func testRealHostRunnerSeparatesGroupAndAuthorizationFailures() throws {
        for (configured, groups, authorized, reason): (String?, [String]?, Bool, String) in [
            (nil, nil, false, "missingGroupEntitlement"),
            (group, nil, false, "missingGroupEntitlement"),
            (group, [group + ".extra"], false, "wrongGroupEntitlement"),
            (group, [group], false, "profileAuthorizationMismatch"),
        ] {
            var authorizationChecks = 0
            let result = try XCTUnwrap(DevProbeHostRunner.run(["--widget-probe=1"],
                configured: { configured }, entitlements: { groups }, authorize: { authorizationChecks += 1; return authorized },
                nowMs: { self.time }, pid: 1, write: { _, _ in XCTFail("拒绝前不能写入") }))
            XCTAssertEqual(result.exitCode, 77)
            XCTAssertEqual(result.reason, reason)
            XCTAssertEqual(authorizationChecks, reason == "profileAuthorizationMismatch" ? 1 : 0)
            try assertCounters(report(result.terminalEvent), lookups: 0, reads: 0, writes: 0)
        }
    }

    func testRealHostRunnerWritesTwoGenerationsAndProviderReadsCommittedBytes() throws {
        try directory { fd in
            for sample in [1, 2] {
                let result = try XCTUnwrap(DevProbeHostRunner.run(["--widget-probe=\(sample)"],
                    configured: { self.group }, entitlements: { [self.group] }, authorize: { true },
                    nowMs: { self.time }, pid: 1, write: { data, io in
                        // 替换的只有容器解析；实际读写由产品 Store 统计。
                        io.enteringContainerLookup()
                        try DevWidgetSnapshotStore.writeFirstOrReplace(data, directory: fd, io: io)
                    }))
                XCTAssertEqual(result.exitCode, 0)
                let event = try report(result.terminalEvent)
                XCTAssertEqual(event["event"] as? String, "writeSucceeded")
                XCTAssertEqual(event["sample"] as? Int, sample)
                XCTAssertEqual(event["payloadMatched"] as? Bool, true)
                try assertCounters(event, lookups: 1, reads: sample == 1 ? 0 : 1, writes: 1)
                let providerResult = DevProbeSnapshotReader.read(guardReason: { nil }, nowMs: time, pid: 1) { io in
                    io.enteringContainerLookup()
                    return try DevWidgetSnapshotStore.read(directory: fd, io: io)
                }
                XCTAssertEqual(providerResult.snapshot?.remainingPercent, Decimal(string: sample == 1 ? "87.66" : "43.22"))
                let readEvent = try report(providerResult.event)
                XCTAssertEqual(readEvent["event"] as? String, "readSucceeded")
                XCTAssertEqual(readEvent["sample"] as? Int, sample)
                try assertCounters(readEvent, lookups: 1, reads: 1, writes: 0)
            }
        }
    }

    func testRealHostRunnerReportsSchemaAndStoreFailures() throws {
        for (error, reason): (DevWidgetSnapshotStore.StoreError, String) in [
            (.unavailable, "containerUnavailable"), (.unsafeObject, "unsafeExistingObject"),
            (.existingObject, "unsafeExistingObject"), (.ioFailure, "ioFailure"),
        ] {
            let result = try XCTUnwrap(DevProbeHostRunner.run(["--widget-probe=1"],
                configured: { self.group }, entitlements: { [self.group] }, authorize: { true },
                nowMs: { self.time }, pid: 1, write: { _, io in
                    io.enteringContainerLookup()
                    throw error
                }))
            XCTAssertEqual(result.exitCode, 74)
            let event = try report(result.terminalEvent)
            XCTAssertEqual(event["event"] as? String, "failure")
            XCTAssertEqual(event["reason"] as? String, reason)
            XCTAssertEqual(event["payloadMatched"] as? Bool, false)
            try assertCounters(event, lookups: 1, reads: 0, writes: 0)
        }
        let schema = try XCTUnwrap(DevProbeHostRunner.run(["--widget-probe=1"],
            configured: { self.group }, entitlements: { [self.group] }, authorize: { true },
            nowMs: { self.time }, pid: 1, makeSample: { _, _ in Data("invalid".utf8) },
            write: { _, _ in XCTFail("非法样本不写盘") }))
        XCTAssertEqual(schema.exitCode, 78)
        try assertCounters(report(schema.terminalEvent), lookups: 0, reads: 0, writes: 0)
    }

    func testRealProviderReaderFailsClosedWithoutStaleFallback() throws {
        let denied = DevProbeSnapshotReader.read(guardReason: { "missingGroupEntitlement" }, nowMs: time, pid: 1) { _ in
            XCTFail("缺组不能读取"); return Data()
        }
        XCTAssertNil(denied.snapshot)
        try assertCounters(report(denied.event), lookups: 0, reads: 0, writes: 0)
        let valid = try XCTUnwrap(DevWidgetSnapshot.sample(1, atMs: time))
        for bytes in [valid, Data("broken".utf8), valid] {
            let now = bytes == valid ? time : time + 1
            let result = DevProbeSnapshotReader.read(guardReason: { nil }, nowMs: now, pid: 1) { io in
                io.enteringContainerLookup(); io.enteringSnapshotRead(); return bytes
            }
            XCTAssertEqual(result.snapshot != nil, bytes == valid)
        }
        let expired = DevProbeSnapshotReader.read(guardReason: { nil }, nowMs: time + 120_001, pid: 1) { _ in valid }
        XCTAssertNil(expired.snapshot)
        XCTAssertEqual(try report(expired.event)["reason"] as? String, "invalidSchema")
        for (error, reason): (DevWidgetSnapshotStore.StoreError, String) in [
            (.unavailable, "containerUnavailable"), (.unsafeObject, "unsafeExistingObject"),
            (.existingObject, "unsafeExistingObject"), (.ioFailure, "ioFailure"),
        ] {
            let failure = DevProbeSnapshotReader.read(guardReason: { nil }, nowMs: time, pid: 1) { _ in throw error }
            XCTAssertNil(failure.snapshot)
            XCTAssertEqual(try report(failure.event)["reason"] as? String, reason)
        }
    }

    func testInjectedAuditIsNotDiscardedByHostOrReader() throws {
        let audit = DevProbeAudit()
        let result = try XCTUnwrap(DevProbeHostRunner.run(["--widget-probe=1"],
            configured: { self.group }, entitlements: { [self.group] }, authorize: { true },
            nowMs: { self.time }, pid: 1, audit: audit, write: { _, _ in
                audit.entering(.background) {}
                throw DevWidgetSnapshotStore.StoreError.ioFailure
            }))
        XCTAssertEqual(try report(result.terminalEvent)["counts"] as? [String: UInt64], audit.snapshot())
        XCTAssertEqual(audit.snapshot()["background"], 1)
        let readerAudit = DevProbeAudit()
        let read = DevProbeSnapshotReader.read(guardReason: { nil }, nowMs: time, pid: 1, audit: readerAudit) { _ in
            readerAudit.entering(.permissions) {}
            throw DevWidgetSnapshotStore.StoreError.ioFailure
        }
        XCTAssertEqual(try report(read.event)["counts"] as? [String: UInt64], readerAudit.snapshot())
        XCTAssertEqual(readerAudit.snapshot()["permissions"], 1)
    }

    func testSameProviderRecordsEachAttemptAndNeverFallsBackAfterFailure() throws {
        let sample = try XCTUnwrap(DevWidgetSnapshot.sample(1, atMs: time))
        var attempts = 0
        var events: [Data] = []
        let provider = DevProvider(now: { Date(timeIntervalSince1970: Double(self.time) / 1000) }, load: { milliseconds in
            attempts += 1
            return DevProbeSnapshotReader.read(guardReason: { nil }, nowMs: milliseconds, pid: 1) { _ in
                if attempts == 1 { return sample }
                throw DevWidgetSnapshotStore.StoreError.ioFailure
            }
        }, record: { events.append($0) })
        XCTAssertNotNil(provider.entry().snapshot)
        XCTAssertNil(provider.entry().snapshot)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(try report(events[0])["event"] as? String, "readSucceeded")
        XCTAssertEqual(try report(events[1])["reason"] as? String, "ioFailure")
    }

    func testActualProviderBuildsOneLoadAndBoundedExpiryTimeline() throws {
        let date = Date(timeIntervalSince1970: Double(time) / 1000)
        let snapshot = try XCTUnwrap(DevWidgetSnapshot.decode(XCTUnwrap(DevWidgetSnapshot.sample(1, atMs: time)), nowMs: time))
        var loads = 0
        let provider = DevProvider(now: { date }, load: { milliseconds in
            XCTAssertEqual(milliseconds, self.time)
            loads += 1
            return (snapshot, nil)
        }, record: { _ in XCTFail("注入样本没有事件") })
        let timeline = provider.timeline()
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(timeline.entries.first?.snapshot?.remainingPercent, Decimal(string: "87.66"))
        XCTAssertTrue(timeline.entries.dropFirst().allSatisfy { $0.snapshot == nil })
        XCTAssertEqual(try XCTUnwrap(timeline.entries.dropFirst().first).date.timeIntervalSince(date), 120.001, accuracy: 0.000001)
        XCTAssertEqual(timeline.policy, .after(date.addingTimeInterval(300)))
        let missing = DevProvider(now: { date }, load: { _ in (nil, nil) }, record: { _ in })
        XCTAssertEqual(missing.timeline().entries.count, 1)
        XCTAssertNil(missing.entry().snapshot)
    }

    func testExpiryPolicyFiltersPastDatesAndHonorsEarlierResetAndValidity() throws {
        let sample = try XCTUnwrap(DevWidgetSnapshot.sample(1, atMs: time))
        let original = try XCTUnwrap(String(data: sample, encoding: .utf8))
        let date = Date(timeIntervalSince1970: Double(time) / 1000)
        let earlyReset = original.replacingOccurrences(of: "\"atMs\":\(time + 3_600_000)",
                                                        with: "\"atMs\":\(time + 1_000)")
        let snapshot = try XCTUnwrap(DevWidgetSnapshot.decode(Data(earlyReset.utf8), nowMs: time))
        XCTAssertEqual(DevWidgetRefreshPolicy.expiryDates(snapshot: snapshot, after: date).first,
                       date.addingTimeInterval(1))
        let earlyValidity = original.replacingOccurrences(of: "\"validUntilMs\":\(time + 120_000)",
                                                          with: "\"validUntilMs\":\(time + 1_000)")
        let shorter = try XCTUnwrap(DevWidgetSnapshot.decode(Data(earlyValidity.utf8), nowMs: time))
        XCTAssertEqual(try XCTUnwrap(DevWidgetRefreshPolicy.expiryDates(snapshot: shorter, after: date).first)
            .timeIntervalSince(date), 1.001, accuracy: 0.000001)
        let dates = DevWidgetRefreshPolicy.expiryDates(snapshot: snapshot, after: date.addingTimeInterval(2))
        XCTAssertTrue(dates.allSatisfy { $0 > date.addingTimeInterval(2) })
        XCTAssertEqual(Set(dates).count, dates.count)
        XCTAssertEqual(dates.count, 1, "相同的valid和整体TTL日期应去重")
        XCTAssertTrue(DevWidgetRefreshPolicy.expiryDates(snapshot: snapshot, after: date.addingTimeInterval(3601)).isEmpty)
    }

    func testRealStoreRejectsFIFOWithoutBlocking() throws {
        try directory { fd in
            XCTAssertEqual(mkfifoat(fd, DevWidgetIdentity.file, 0o600), 0)
            let start = Date()
            XCTAssertThrowsError(try DevWidgetSnapshotStore.read(directory: fd))
            XCTAssertThrowsError(try DevWidgetSnapshotStore.claimExisting(directory: fd))
            XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        }
    }

    func testReadRacingWithCommitRejectsOldFDThenReadsNewGeneration() throws {
        try directory { fd in
            let first = try XCTUnwrap(DevWidgetSnapshot.sample(1, atMs: time))
            let second = try XCTUnwrap(DevWidgetSnapshot.sample(2, atMs: time))
            let owned = try DevWidgetSnapshotStore.writeIfAbsent(first, directory: fd)
            var committed = false
            XCTAssertThrowsError(try DevWidgetSnapshotStore.read(directory: fd, beforeNameValidation: {
                _ = try DevWidgetSnapshotStore.replaceIfOwned(second, expected: owned, directory: fd)
                committed = true
            }))
            XCTAssertTrue(committed, "读到旧 fd 后第二代已提交")
            XCTAssertEqual(try DevWidgetSnapshotStore.read(directory: fd), second,
                           "提交完成后的新读取必须返回第二代，不能回退旧缓存")
            let result = DevProbeSnapshotReader.read(guardReason: { nil }, nowMs: time, pid: 1) { _ in
                let current = try XCTUnwrap(DevWidgetSnapshotStore.claimExisting(directory: fd))
                return try DevWidgetSnapshotStore.read(directory: fd, beforeNameValidation: {
                    _ = try DevWidgetSnapshotStore.replaceIfOwned(first, expected: current, directory: fd)
                })
            }
            XCTAssertNil(result.snapshot, "竞态拒绝后 Provider 不能返回旧值")
            XCTAssertEqual(try report(result.event)["event"] as? String, "failure")
        }
    }
}
