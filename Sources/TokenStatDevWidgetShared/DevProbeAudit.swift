import Foundation
import os
import Security

enum DevProbeBoundary: String, CaseIterable {
    case application, delegate, models, preferences, sources, background
    case permissions, environmentReads
}

// 包装器在执行操作前递增计数；纯内存测试可传入失败闭包，检查计数器是否实际接入。
final class DevProbeAudit {
    private var counts: [DevProbeBoundary: UInt64] = [:]

    @discardableResult
    func entering<T>(_ boundary: DevProbeBoundary, perform: () throws -> T) rethrows -> T {
        counts[boundary, default: 0] += 1
        return try perform()
    }

    func snapshot() -> [String: UInt64] {
        Dictionary(uniqueKeysWithValues: DevProbeBoundary.allCases.map {
            ($0.rawValue, counts[$0, default: 0])
        })
    }
}

// 在操作入口统计逻辑 I/O，不根据预期结果计数；容器查找失败不算快照读写。
final class DevProbeIOAudit {
    private(set) var containerLookups: UInt64 = 0
    private(set) var snapshotWrites: UInt64 = 0
    private(set) var snapshotReads: UInt64 = 0

    func enteringContainerLookup() { containerLookups += 1 }
    func enteringSnapshotWrite() { snapshotWrites += 1 }
    func enteringSnapshotRead() { snapshotReads += 1 }

    func snapshot() -> [String: UInt64] {
        ["containerLookups": containerLookups,
         "snapshotWrites": snapshotWrites,
         "snapshotReads": snapshotReads]
    }
}

enum DevGroupGuard {
    static func reason(configured: String?, entitlements: [String]?,
                       authorizationMatches: Bool) -> String? {
        guard let configured else { return "missingGroupEntitlement" }
        guard DevWidgetIdentity.hasExactGroupShape(configured, allowSynthetic: true) else {
            return "wrongGroupEntitlement"
        }
        guard let entitlements else { return "missingGroupEntitlement" }
        guard entitlements == [configured] else { return "wrongGroupEntitlement" }
        guard authorizationMatches else { return "profileAuthorizationMismatch" }
        return nil
    }

    // 只检查签名进程自身的权限，不读取描述文件，也不据此认定授权有效；C51c-S01 单独验证。
    static func currentEntitlements() -> [String]? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task, "com.apple.security.application-groups" as CFString, nil),
              let groups = value as? [String] else { return nil }
        return groups
    }

    static func currentReason() -> String? {
        DevProbeController.groupRejection(configured: { DevWidgetIdentity.group() },
                                          entitlements: { currentEntitlements() },
                                          authorizationMatches: currentAuthorizationMatches())
    }

    /// 只检查本进程的签名身份，不读取用户凭据或其他应用。这个开发候选
    /// 只接受 TEAMID.* 组名，因此签名团队必须与前缀一致；ad hoc 直接拒绝。
    /// 静态签名检查不代替系统容器读回与分发授权验收。
    static func currentAuthorizationMatches() -> Bool {
        guard let group = DevWidgetIdentity.group() else { return false }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                           &information) == errSecSuccess,
              let info = information as? [String: Any] else { return false }
        return authorizationMatches(group: group,
            team: info[kSecCodeInfoTeamIdentifier as String] as? String,
            flags: (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value)
    }

    static func authorizationMatches(group: String, team: String?, flags: UInt32?) -> Bool {
        guard DevWidgetIdentity.hasExactGroupShape(group), let team, let flags,
              flags & 0x0002 == 0 else { return false } // CSCommon.h: kSecCodeSignatureAdhoc
        return group.hasPrefix(team + ".") && team.count == 10
    }
}

enum DevProbeDecision {
    case normal
    case reject(Int32, String)
    case sample(Int)
}

struct DevProbeResult {
    let exitCode: Int32
    let reason: String
    let counts: [String: UInt64]
    let io: [String: UInt64]
    let trace: [String]
    let payload: Data?
    let terminalEvent: Data?
}

enum DevProbeController {
    static func groupRejection(configured: () -> String?,
                               entitlements: () -> [String]?,
                               authorizationMatches: @autoclosure () -> Bool) -> String? {
        let group = configured()
        let groups = entitlements()
        if let reason = DevGroupGuard.reason(configured: group, entitlements: groups,
                                            authorizationMatches: true) { return reason }
        return DevGroupGuard.reason(configured: group, entitlements: groups,
                                    authorizationMatches: authorizationMatches())
    }

    // 身份信息延迟加载，参数错误时先拒绝，再进行包或签名查找；宿主和内存适配器共用此入口。
    static func decide(_ arguments: [String], configured: () -> String?,
                       entitlements: () -> [String]?,
                        authorizationMatches: @autoclosure () -> Bool) -> DevProbeDecision {
        switch DevProbeArguments.classify(arguments) {
        case .normal: return .normal
        case .reject: return .reject(64, "invalidArguments")
        case let .sample(number):
            if let reason = groupRejection(configured: configured,
                                           entitlements: entitlements,
                                            authorizationMatches: authorizationMatches()) {
                return .reject(77, reason)
            }
            return .sample(number)
        }
    }

    static func terminalEvent(actor: String, sample: Int?, exitCode: Int32,
                              reason: String, counts: [String: UInt64],
                              io: [String: UInt64], nowMs: Int64,
                              pid: Int32, payloadMatched: Bool) -> Data? {
        let event: String
        switch exitCode {
        case 0: event = actor == "host" ? "writeSucceeded" : "readSucceeded"
        case 64: event = "argvRejected"
        case 77: event = "guardRejected"
        default: event = "failure"
        }
        return DevProbeSafeEvent.make(actor: actor, event: event, sample: sample,
                                      reason: reason, pid: pid, timeMs: nowMs,
                                      counts: counts, io: io,
                                      payloadMatched: payloadMatched)
    }

    static func startEvent(actor: String, counts: [String: UInt64],
                           io: [String: UInt64], nowMs: Int64, pid: Int32) -> Data? {
        DevProbeSafeEvent.make(actor: actor, event: "start", sample: nil,
                               reason: "none", pid: pid, timeMs: nowMs,
                               counts: counts, io: io, payloadMatched: false)
    }

    // 注入路径不访问 AppKit、URL、文件、网络、偏好或环境，I/O 计数仅表示逻辑调用。
    static func memoryRun(_ arguments: [String], actor: String,
                          configuredGroup: String, entitlements: [String]?,
                          authorizationMatches: Bool, incoming: Data?,
                          containerAvailable: Bool = true,
                          nowMs: Int64 = 1_800_000_000_000,
                          audit: DevProbeAudit = DevProbeAudit()) -> DevProbeResult {
        let ioAudit = DevProbeIOAudit()
        var trace = ["classify"]
        var currentSample: Int?
        func result(_ exit: Int32, _ reason: String, _ payload: Data? = nil) -> DevProbeResult {
            DevProbeResult(exitCode: exit, reason: reason, counts: audit.snapshot(),
                           io: ioAudit.snapshot(), trace: trace, payload: payload,
                           terminalEvent: terminalEvent(actor: actor, sample: currentSample,
                                                        exitCode: exit, reason: reason,
                                                        counts: audit.snapshot(), io: ioAudit.snapshot(),
                                                        nowMs: nowMs, pid: 1,
                                                        payloadMatched: exit == 0))
        }
        let sample: Int
        let decision = decide(arguments, configured: { configuredGroup },
                              entitlements: { entitlements },
                              authorizationMatches: authorizationMatches)
        switch decision {
        case .normal: return result(64, "invalidArguments")
        case let .reject(exit, reason):
            if exit == 77 { trace.append("guard") }
            return result(exit, reason)
        case let .sample(number):
            sample = number
            currentSample = number
            trace.append("guard")
        }
        if actor == "host" {
            guard let data = DevWidgetSnapshot.sample(sample, atMs: nowMs) else {
                return result(78, "invalidSchema")
            }
            ioAudit.enteringContainerLookup()
            trace.append("lookup")
            guard containerAvailable else { return result(74, "containerUnavailable") }
            ioAudit.enteringSnapshotWrite()
            trace.append("write")
            return result(0, "none", data)
        }
        guard actor == "appex" else { return result(78, "invalidSchema") }
        ioAudit.enteringContainerLookup()
        trace.append("lookup")
        guard containerAvailable else { return result(74, "containerUnavailable") }
        ioAudit.enteringSnapshotRead()
        trace.append("read")
        guard let incoming,
              let snapshot = DevWidgetSnapshot.decode(incoming, nowMs: nowMs),
              snapshot.remainingPercent == Decimal(string: sample == 1 ? "87.66" : "43.22")
        else { return result(78, "invalidSchema") }
        return result(0, "none")
    }
}

private struct DevProbeSafeEvent: Encodable {
    let schemaVersion: Int
    let actor: String
    let event: String
    let sample: Int?
    let reason: String
    let pid: Int32
    let timeMs: Int64
    let counts: [String: UInt64]
    let io: [String: UInt64]
    let payloadMatched: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, actor, event, sample, reason, pid, timeMs
        case counts, io, payloadMatched
    }

    func encode(to encoder: Encoder) throws {
        var output = encoder.container(keyedBy: CodingKeys.self)
        try output.encode(schemaVersion, forKey: .schemaVersion)
        try output.encode(actor, forKey: .actor)
        try output.encode(event, forKey: .event)
        if let sample {
            try output.encode(sample, forKey: .sample)
        } else {
            try output.encodeNil(forKey: .sample)
        }
        try output.encode(reason, forKey: .reason)
        try output.encode(pid, forKey: .pid)
        try output.encode(timeMs, forKey: .timeMs)
        try output.encode(counts, forKey: .counts)
        try output.encode(io, forKey: .io)
        try output.encode(payloadMatched, forKey: .payloadMatched)
    }

    static func make(actor: String, event: String, sample: Int?, reason: String,
                     pid: Int32, timeMs: Int64, counts: [String: UInt64],
                     io: [String: UInt64], payloadMatched: Bool) -> Data? {
        let actors = ["host", "appex"]
        let events = ["start", "argvRejected", "writeSucceeded", "readSucceeded", "guardRejected", "failure"]
        let reasons = ["none", "invalidArguments", "missingGroupEntitlement", "wrongGroupEntitlement",
                       "profileAuthorizationMismatch", "containerUnavailable", "containerDenied",
                       "unsafeExistingObject", "invalidSchema", "oversize", "futureTimestamp",
                       "expired", "ioFailure"]
        guard actors.contains(actor), events.contains(event), reasons.contains(reason),
              sample == nil || sample == 1 || sample == 2,
              pid > 0, timeMs >= 0, timeMs <= 253_402_300_799_999,
              Set(counts.keys) == Set(DevProbeBoundary.allCases.map(\.rawValue)),
              Set(io.keys) == Set(["containerLookups", "snapshotWrites", "snapshotReads"]),
              io.values.allSatisfy({ $0 <= 1 })
        else { return nil }
        let record = DevProbeSafeEvent(schemaVersion: 1, actor: actor, event: event,
                                       sample: sample, reason: reason, pid: pid,
                                       timeMs: timeMs, counts: counts, io: io,
                                       payloadMatched: payloadMatched)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record), data.count <= 2048 else { return nil }
        return data
    }
}

enum DevProbeTelemetry {
    private static let logger = Logger(
        subsystem: "com.tupig.TokenStatMenu.DevWidgetTest.WidgetValidation",
        category: "C51cProbe")

    static func writeTerminalToStdout(_ data: Data) {
        FileHandle.standardOutput.write(data + Data([10]))
    }

    static func writeTerminalToOSLog(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        logger.info("\(text, privacy: .public)")
    }
}
