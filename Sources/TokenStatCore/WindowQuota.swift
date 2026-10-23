import Foundation
import CoreFoundation

public struct WindowQuota: Codable, Equatable, Sendable {
    public let minutes: Int
    public let usedPercent: Double
    public let resetsAt: Date?
    public let fetchedAt: Date
    public var remainingPercent: Double { max(0, 100 - usedPercent) }
    public func isFresh(at now: Date = Date(), refreshSeconds: Double) -> Bool {
        fetchedAt <= now && now.timeIntervalSince(fetchedAt) < max(120, refreshSeconds * 2)
            && (resetsAt.map { $0 > now } ?? true)
    }
}

/// 月度与滚动窗口额度是相互独立的事实；缺失其一不应
/// 抹掉其余。不会从本地 token/请求计数器推断任何额度。
public struct QuotaReport {
    public let monthly: QuotaSnapshot?
    public let monthlyMessage: String
    public let fiveHour: WindowQuota?
    public let sevenDay: WindowQuota?

    public static func parse(_ data: Data, config: AppConfiguration, now: Date = Date()) throws -> QuotaReport {
        let object = try JSONSerialization.jsonObject(with: data)
        var monthly: QuotaSnapshot?, monthlyMessage = ""
        do { monthly = try QuotaSnapshot.parse(data, config: config, now: now) }
        catch { monthlyMessage = "月度用量未提供，或月度字段 / 月份未匹配" }
        func value(_ path: String) -> Any? {
            guard !path.isEmpty else { return nil }
            return path.split(separator: ".").reduce(Optional(object)) { node, key in
                if let dict = node as? [String: Any] { return dict[String(key)] }
                if let array = node as? [Any], let i = Int(key), array.indices.contains(i) { return array[i] }
                return nil
            }
        }
        func configured(_ minutes: Int, percentPath: String, resetPath: String) -> WindowQuota? {
            if let raw = value(percentPath), !(raw is NSNull) {
                guard let percent = number(raw), (0...100).contains(percent) else { return nil }
                return WindowQuota(minutes: minutes, usedPercent: percent,
                    resetsAt: resetDate(value(resetPath)), fetchedAt: now)
            }
            // 同时也接受来自同一已配置 endpoint 的 Codex 发布的 rateLimits 结构。
            // 由时长而非 primary/secondary 顺序决定窗口。
            let root = object as? [String: Any] ?? [:]
            let payload = root["result"] as? [String: Any] ?? root
            guard let limits = payload["rateLimits"] as? [String: Any] else { return nil }
            let matches = ["primary", "secondary"].compactMap { limits[$0] as? [String: Any] }
                .filter { number($0["windowDurationMins"]) == Double(minutes) }
            guard matches.count == 1, let window = matches.first,
                  let percent = number(window["usedPercent"]), (0...100).contains(percent) else { return nil }
            return WindowQuota(minutes: minutes, usedPercent: percent,
                resetsAt: resetDate(window["resetsAt"]), fetchedAt: now)
        }
        let five = configured(300, percentPath: config.fiveHourUsedPercentPath, resetPath: config.fiveHourResetPath)
        let seven = configured(10080, percentPath: config.sevenDayUsedPercentPath, resetPath: config.sevenDayResetPath)
        guard monthly != nil || five != nil || seven != nil else {
            throw StatError.message("接口未返回有效月度、5 小时或 7 天额度；请检查字段映射和单位")
        }
        return QuotaReport(monthly: monthly, monthlyMessage: monthlyMessage, fiveHour: five, sevenDay: seven)
    }
    private static func number(_ value: Any?) -> Double? {
        let result: Double?
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { result = n.doubleValue }
        else if let text = value as? String { result = Double(text) }
        else { return nil }
        guard let result, result.isFinite else { return nil }
        return result
    }
    private static func resetDate(_ value: Any?) -> Date? {
        // 数字时间戳为 Unix 秒，绝不会被猜测成毫秒。
        if let seconds = number(value), seconds > 0, seconds < 100_000_000_000 {
            return Date(timeIntervalSince1970: seconds)
        }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }
}
