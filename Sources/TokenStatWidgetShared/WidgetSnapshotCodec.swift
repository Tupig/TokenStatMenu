import Foundation

/// 使用固定字段集合编解码 `WidgetQuotaSnapshot`。
///
/// 手动编解码以保持应用与小组件的格式一致。拒绝未知结构，
/// 可选值显式编码为 JSON `null`，区分数据缺失与格式错误。
public enum WidgetSnapshotCodec {

    public static let maximumBytes = 8192

    public enum CodecError: Error, Equatable {
        case empty, tooLarge, notUTF8, notAnObject
        case unexpectedKey(String), missingKey(String)
        case wrongSchemaVersion
        case wrongType(String), outOfRange(String)
        case invalidTimestamp(String)
    }

    private static let rootKeys: Set<String> = [
        "schemaVersion", "writtenAtMs", "observedAtMs", "validUntilMs",
        "hubSource", "hubState", "fiveHour", "sevenDay", "monthly", "local"
    ]
    private static let windowKeys: Set<String> = ["remainingPercent", "resetsAtMs"]
    private static let monthlyKeys: Set<String> = ["usedAmount", "limitAmount", "sourceSymbol"]
    private static let localKeys: Set<String> = [
        "inputTokens", "outputTokens", "totalTokens",
        "knownThreads", "unknownThreads", "isLimited"
    ]

    // MARK: - 编码

    public static func encode(_ snapshot: WidgetQuotaSnapshot) throws -> Data {
        // 序列化前先校验，避免应用写出小组件无法解码的数据。
        try validate(snapshot)
        var root: [String: Any] = [
            "schemaVersion": WidgetQuotaSnapshot.schemaVersion,
            "writtenAtMs": milliseconds(snapshot.writtenAt),
            "observedAtMs": snapshot.observedAt.map(milliseconds) ?? NSNull(),
            "validUntilMs": snapshot.validUntil.map(milliseconds) ?? NSNull(),
            "hubSource": snapshot.hubSource.rawValue,
            "hubState": snapshot.hubState.rawValue
        ]
        root["fiveHour"] = snapshot.fiveHour.map(encodeWindow) ?? NSNull()
        root["sevenDay"] = snapshot.sevenDay.map(encodeWindow) ?? NSNull()
        root["monthly"] = snapshot.monthly.map(encodeMonthly) ?? NSNull()
        root["local"] = snapshot.local.map(encodeLocal) ?? NSNull()
        // 字段排序且不添加排版空白，使相同数据生成相同字节，便于跳过重复写入。
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard data.count <= maximumBytes else { throw CodecError.tooLarge }
        return data
    }

    /// 写入前使用与解码器相同的取值范围校验。
    private static func validate(_ snapshot: WidgetQuotaSnapshot) throws {
        func validateWindow(_ window: WidgetQuotaSnapshot.Window?, _ label: String) throws {
            guard let window else { return }
            guard window.remainingPercent.isFinite,
                  (0...100).contains(window.remainingPercent)
            else { throw CodecError.outOfRange("\(label).remainingPercent") }
            if let reset = window.resetsAt {
                try validateTimestamp(reset, "\(label).resetsAtMs")
            }
        }
        try validateTimestamp(snapshot.writtenAt, "writtenAtMs")
        if let observed = snapshot.observedAt {
            try validateTimestamp(observed, "observedAtMs")
        }
        if let valid = snapshot.validUntil {
            try validateTimestamp(valid, "validUntilMs")
        }
        try validateWindow(snapshot.fiveHour, "fiveHour")
        try validateWindow(snapshot.sevenDay, "sevenDay")
        if let monthly = snapshot.monthly {
            guard monthly.usedAmount.isFinite, monthly.usedAmount >= 0 else {
                throw CodecError.outOfRange("monthly.usedAmount")
            }
            if let limit = monthly.limitAmount {
                guard limit.isFinite, limit >= 0 else {
                    throw CodecError.outOfRange("monthly.limitAmount")
                }
            }
            // 限制货币符号长度，避免异常字符串挤占小组件空间。
            guard monthly.sourceSymbol.count <= 4 else {
                throw CodecError.outOfRange("monthly.sourceSymbol")
            }
        }
        if let local = snapshot.local {
            for value in [local.inputTokens, local.outputTokens, local.totalTokens,
                          local.knownThreads, local.unknownThreads] {
                guard value >= 0, value <= 1_000_000_000_000_000 else {
                    throw CodecError.outOfRange("local")
                }
            }
        }
    }

    /// 编码后的数据不能超出小组件的字节上限。
    private static func validatePayloadSize(_ data: Data) throws {
        guard data.count <= maximumBytes else { throw CodecError.tooLarge }
    }

    /// 协议使用的 Unix 毫秒时间戳。
    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func validateTimestamp(_ date: Date, _ label: String) throws {
        let ms = date.timeIntervalSince1970 * 1000
        guard ms.isFinite, ms >= 0, ms <= 253_402_300_799_999 else {
            throw CodecError.invalidTimestamp(label)
        }
    }

    private static func encodeWindow(_ window: WidgetQuotaSnapshot.Window) -> [String: Any] {
        ["remainingPercent": window.remainingPercent,
         "resetsAtMs": window.resetsAt.map(milliseconds) ?? NSNull()]
    }

    private static func encodeMonthly(_ monthly: WidgetQuotaSnapshot.Monthly) -> [String: Any] {
        ["usedAmount": monthly.usedAmount,
         "limitAmount": monthly.limitAmount ?? NSNull(),
         "sourceSymbol": monthly.sourceSymbol]
    }

    private static func encodeLocal(_ local: WidgetQuotaSnapshot.Local) -> [String: Any] {
        ["inputTokens": local.inputTokens,
         "outputTokens": local.outputTokens,
         "totalTokens": local.totalTokens,
         "knownThreads": local.knownThreads,
         "unknownThreads": local.unknownThreads,
         "isLimited": local.isLimited]
    }

    // MARK: - 解码

    public static func decode(_ data: Data, now: Date = Date()) throws -> WidgetQuotaSnapshot {
        guard !data.isEmpty else { throw CodecError.empty }
        guard data.count <= maximumBytes else { throw CodecError.tooLarge }
        guard !data.starts(with: [0xef, 0xbb, 0xbf]) else { throw CodecError.notUTF8 }
        guard String(data: data, encoding: .utf8) != nil else { throw CodecError.notUTF8 }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { throw CodecError.notAnObject }

        try requireClosed(root, keys: rootKeys)
        // 比较精确值，不能用 `intValue` 把 1.5 截断为版本 1。
        guard let version = root["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == Double(WidgetQuotaSnapshot.schemaVersion) else {
            throw CodecError.wrongSchemaVersion
        }
        // `writtenAtMs` 是小组件的绝对时间基准，必须为整数毫秒，不做舍入。
        guard let written = root["writtenAtMs"] else {
            throw CodecError.missingKey("writtenAtMs")
        }
        guard let writtenNumber = written as? NSNumber,
              CFGetTypeID(writtenNumber) != CFBooleanGetTypeID() else {
            throw CodecError.wrongType("writtenAtMs")
        }
        guard writtenNumber.doubleValue == writtenNumber.doubleValue.rounded(),
              let writtenAt = try date(root, "writtenAtMs") else {
            throw CodecError.wrongType("writtenAtMs")
        }
        let observedAt = try date(root, "observedAtMs")
        let validUntil = try date(root, "validUntilMs")
        guard let hubSource = WidgetQuotaSnapshot.HubSource(rawValue: try string(root, "hubSource")),
              let hubState = WidgetQuotaSnapshot.HubState(rawValue: try string(root, "hubState")) else {
            throw CodecError.wrongType("hubSource/hubState")
        }
        let fiveHour = try window(root, "fiveHour")
        let sevenDay = try window(root, "sevenDay")
        let monthly = try monthlyValue(root, "monthly")
        let local = try localValue(root, "local")
        let snapshot = WidgetQuotaSnapshot(
            writtenAt: writtenAt, observedAt: observedAt, validUntil: validUntil,
            hubSource: hubSource, hubState: hubState,
            fiveHour: fiveHour, sevenDay: sevenDay, monthly: monthly, local: local)
        // 这里只拒绝不可能的时间区间。未来的 `writtenAt` 由 `hubIsCurrent`
        // 按时钟回拨处理，不丢弃与绝对时间无关的 `local` 用量。
        if let validUntil, let observedAt, validUntil < observedAt {
            throw CodecError.outOfRange("validUntilMs")
        }
        return snapshot
    }

    private static func window(_ root: [String: Any], _ key: String) throws
        -> WidgetQuotaSnapshot.Window? {
        guard let raw = root[key] else { throw CodecError.missingKey(key) }
        if raw is NSNull { return nil }
        guard let object = raw as? [String: Any] else { throw CodecError.wrongType(key) }
        try requireClosed(object, keys: windowKeys)
        let percent = try number(object, "remainingPercent").doubleValue
        guard percent.isFinite, (0...100).contains(percent) else {
            throw CodecError.outOfRange("remainingPercent")
        }
        let resetsAt = try date(object, "resetsAtMs")
        return WidgetQuotaSnapshot.Window(remainingPercent: percent, resetsAt: resetsAt)
    }

    private static func monthlyValue(_ root: [String: Any], _ key: String) throws
        -> WidgetQuotaSnapshot.Monthly? {
        guard let raw = root[key] else { throw CodecError.missingKey(key) }
        if raw is NSNull { return nil }
        guard let object = raw as? [String: Any] else { throw CodecError.wrongType(key) }
        try requireClosed(object, keys: monthlyKeys)
        let used = try number(object, "usedAmount").doubleValue
        guard used.isFinite, used >= 0 else { throw CodecError.outOfRange("usedAmount") }
        var limit: Double?
        if let rawLimit = object["limitAmount"], !(rawLimit is NSNull) {
            guard let value = rawLimit as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue >= 0 else {
                throw CodecError.outOfRange("limitAmount")
            }
            limit = value.doubleValue
        }
        let symbol = try string(object, "sourceSymbol")
        guard symbol.count <= 4 else { throw CodecError.outOfRange("sourceSymbol") }
        return WidgetQuotaSnapshot.Monthly(usedAmount: used, limitAmount: limit, sourceSymbol: symbol)
    }

    private static func localValue(_ root: [String: Any], _ key: String) throws
        -> WidgetQuotaSnapshot.Local? {
        guard let raw = root[key] else { throw CodecError.missingKey(key) }
        if raw is NSNull { return nil }
        guard let object = raw as? [String: Any] else { throw CodecError.wrongType(key) }
        try requireClosed(object, keys: localKeys)
        let input = try integer(object, "inputTokens")
        let output = try integer(object, "outputTokens")
        let total = try integer(object, "totalTokens")
        let known = try integer(object, "knownThreads")
        let unknown = try integer(object, "unknownThreads")
        guard let limitedNumber = object["isLimited"] as? NSNumber,
              CFGetTypeID(limitedNumber) == CFBooleanGetTypeID() else {
            throw CodecError.wrongType("isLimited")
        }
        let limited = limitedNumber.boolValue
        return WidgetQuotaSnapshot.Local(inputTokens: input, outputTokens: output,
            totalTokens: total, knownThreads: known, unknownThreads: unknown,
            isLimited: limited)
    }

    // MARK: - 字段辅助方法

    private static func requireClosed(_ object: [String: Any], keys: Set<String>) throws {
        for key in object.keys where !keys.contains(key) {
            throw CodecError.unexpectedKey(key)
        }
        for key in keys where object[key] == nil {
            throw CodecError.missingKey(key)
        }
    }

    private static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw CodecError.wrongType(key) }
        return value
    }

    private static func number(_ object: [String: Any], _ key: String) throws -> NSNumber {
        guard let value = object[key] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else { throw CodecError.wrongType(key) }
        return value
    }

    private static func integer(_ object: [String: Any], _ key: String) throws -> Int {
        let value = try number(object, key)
        let rounded = value.doubleValue
        guard rounded.isFinite, rounded >= 0, rounded <= 1e15,
              rounded == rounded.rounded() else { throw CodecError.outOfRange(key) }
        return Int(rounded)
    }

    /// JSON null 或字段缺失时返回 nil，其他非整数值抛出错误。
    private static func date(_ object: [String: Any], _ key: String) throws -> Date? {
        guard let raw = object[key], !(raw is NSNull) else { return nil }
        let value = try number(object, key)
        let ms = value.doubleValue
        guard ms.isFinite, ms >= 0, ms <= 253_402_300_799_999 else {
            throw CodecError.invalidTimestamp(key)
        }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
