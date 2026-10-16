import Foundation
import CoreFoundation

public struct QuotaSnapshot: Codable {
    public var used: Double
    public var limit: Double?
    public var month: String
    public var fetchedAt: Date
    public var fraction: Double? { limit.flatMap { $0 > 0 ? used / $0 : nil } }
    public var remaining: Double? { limit.map { max(0, $0 - used) } }
    public static func currentMonth(at date: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"; return formatter.string(from: date)
    }
    public static func parse(_ data: Data, config: AppConfiguration, now: Date = Date()) throws -> QuotaSnapshot {
        let object = try JSONSerialization.jsonObject(with: data)
        func value(_ path: String) -> Any? {
            guard !path.isEmpty else { return nil }
            return path.split(separator: ".").reduce(Optional(object)) { node, key in
                if let dict = node as? [String: Any] { return dict[String(key)] }
                if let array = node as? [Any], let i = Int(key), array.indices.contains(i) { return array[i] }
                return nil
            }
        }
        func number(_ v: Any?) -> Double? {
            let n: Double?
            if let raw = v as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID() { n = raw.doubleValue }
            else if let raw = v as? String { n = Double(raw) }
            else { n = nil }
            guard let n, n.isFinite, n >= 0, n <= 1e15 else { return nil }
            return n
        }
        guard let used = number(value(config.usedPath)) else { throw StatError.message("企业用量响应缺少有效已用 Token 字段") }
        let month = currentMonth(at: now)
        if !config.periodPath.isEmpty {
            guard value(config.periodPath) as? String == month else { throw StatError.message("企业接口月份缺失或不是本月（需要 yyyy-MM）") }
        }
        let apiLimit = number(value(config.limitPath))
        if !config.limitPath.isEmpty, apiLimit == nil, config.monthlyLimit == 0 { throw StatError.message("配额字段无效，且未设置手动上限") }
        let limit = config.monthlyLimit > 0 ? config.monthlyLimit : apiLimit
        return QuotaSnapshot(used: used, limit: limit, month: month, fetchedAt: now)
    }
}
