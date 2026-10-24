import Foundation

/// 真正的宿主早入口；测试仅替换外部边界，不复制决策、写入和错误映射。
enum DevProbeHostRunner {
    static func run(_ arguments: [String],
                    configured: () -> String? = { DevWidgetIdentity.group() },
                    entitlements: () -> [String]? = { DevGroupGuard.currentEntitlements() },
                    authorize: () -> Bool = { DevGroupGuard.currentAuthorizationMatches() },
                    nowMs: () -> Int64 = { Int64(floor(Date().timeIntervalSince1970 * 1000)) },
                    pid: Int32 = getpid(),
                    audit: DevProbeAudit = DevProbeAudit(),
                    makeSample: (Int, Int64) -> Data? = { DevWidgetSnapshot.sample($0, atMs: $1) },
                    write: (Data, DevProbeIOAudit) throws -> Void = {
                        try DevWidgetSnapshotStore.writeFirstOrReplace($0, io: $1)
                    }) -> DevProbeResult? {
        let io = DevProbeIOAudit()
        var trace = ["classify"]
        var sample: Int?
        var timestamp: Int64?
        func finish(_ code: Int32, _ reason: String) -> DevProbeResult {
            let time = timestamp ?? nowMs()
            return DevProbeResult(exitCode: code, reason: reason, counts: audit.snapshot(),
                io: io.snapshot(), trace: trace, payload: nil,
                terminalEvent: DevProbeController.terminalEvent(actor: "host", sample: sample,
                    exitCode: code, reason: reason, counts: audit.snapshot(), io: io.snapshot(),
                    nowMs: time, pid: pid, payloadMatched: code == 0))
        }
        let decision = DevProbeController.decide(arguments, configured: configured,
            entitlements: entitlements, authorizationMatches: authorize())
        switch decision {
        case .normal: return nil
        case let .reject(code, reason): return finish(code, reason)
        case let .sample(number): sample = number
        }
        guard let sample else { return finish(78, "invalidSchema") }
        trace.append("guard")
        let time = nowMs()
        timestamp = time
        guard let data = makeSample(sample, time),
              DevWidgetSnapshot.decode(data, nowMs: time) != nil else {
            return finish(78, "invalidSchema")
        }
        do {
            trace.append("write")
            try write(data, io)
            return finish(0, "none")
        } catch {
            return finish(74, DevProbeStoreFailure.reason(error))
        }
    }
}

/// 与真实 Provider 共用读取、验证和事件生成，失败时不保存或回退到旧快照。
enum DevProbeSnapshotReader {
    static func read(guardReason: () -> String? = { DevGroupGuard.currentReason() },
                     nowMs: Int64, pid: Int32 = getpid(),
                     audit: DevProbeAudit = DevProbeAudit(),
                     read: (DevProbeIOAudit) throws -> Data = { try DevWidgetSnapshotStore.read(io: $0) })
        -> (snapshot: DevWidgetSnapshot?, event: Data?) {
        let io = DevProbeIOAudit()
        func finish(_ snapshot: DevWidgetSnapshot?, code: Int32, reason: String)
            -> (snapshot: DevWidgetSnapshot?, event: Data?) {
            let sample: Int?
            switch snapshot?.remainingPercent {
            case Decimal(string: "87.66"): sample = 1
            case Decimal(string: "43.22"): sample = 2
            default: sample = nil
            }
            return (snapshot, DevProbeController.terminalEvent(actor: "appex", sample: sample,
                exitCode: code, reason: reason, counts: audit.snapshot(), io: io.snapshot(),
                nowMs: nowMs, pid: pid, payloadMatched: code == 0 && sample != nil))
        }
        if let reason = guardReason() { return finish(nil, code: 77, reason: reason) }
        do {
            let data = try read(io)
            guard let snapshot = DevWidgetSnapshot.decode(data, nowMs: nowMs) else {
                return finish(nil, code: 78, reason: "invalidSchema")
            }
            return finish(snapshot, code: 0, reason: "none")
        } catch {
            return finish(nil, code: 74, reason: DevProbeStoreFailure.reason(error))
        }
    }
}

private enum DevProbeStoreFailure {
    static func reason(_ error: Error) -> String {
        switch error {
        case DevWidgetSnapshotStore.StoreError.unavailable: return "containerUnavailable"
        case DevWidgetSnapshotStore.StoreError.existingObject,
             DevWidgetSnapshotStore.StoreError.unsafeObject: return "unsafeExistingObject"
        default: return "ioFailure"
        }
    }
}
