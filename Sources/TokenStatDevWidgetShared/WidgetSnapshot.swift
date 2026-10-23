import Foundation

// This file is compiled into the isolated development host and extension only.
// It has no dependency on the normal collector or on an account credential.
enum DevProbeArguments {
    enum Mode { case normal, sample(Int), reject }

    static func classify(_ arguments: [String]) -> Mode {
        if arguments == ["--widget-probe=1"] { return .sample(1) }
        if arguments == ["--widget-probe=2"] { return .sample(2) }
        if arguments.contains(where: { $0.hasPrefix("--widget-probe") }) { return .reject }
        return .normal
    }
}

enum DevWidgetIdentity {
    static let kind = "com.tupig.TokenStatMenu.DevWidgetTest.WidgetKind"
    static let route = "tokenstatmenu-devwidgettest://overview"
    static let file = "widget-snapshot-v1.json"
    static let temporaryFile = "widget-snapshot-v1.json.tmp"

    static func hasExactGroupShape(_ value: String, allowSynthetic: Bool = false) -> Bool {
        let suffix = ".com.tupig.TokenStatMenu.DevWidgetTest"
        // Team ID is exactly 10 characters. Anything between it and the fixed
        // suffix, including an extra dotted segment, is a different group.
        return value.count == 10 + suffix.count
              && value.dropFirst(10) == suffix
              && !value.contains("$(") && !value.hasPrefix("UNRESOLVED")
              && (allowSynthetic || !value.hasPrefix("FICTEAM"))
              && value.prefix(10).allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) })
    }

    // Never use an unresolved build variable as an actual App Group.
    static func group(in bundle: Bundle = .main) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: "C51CDevGroup") as? String,
              hasExactGroupShape(value)
        else { return nil }
        return value
    }

    static func accepts(_ url: URL) -> Bool {
        url.absoluteString == route
    }
}

struct DevWidgetSnapshot {
    let writtenAtMs: Int64
    let observedAtMs: Int64?
    let validUntilMs: Int64?
    let remainingPercent: Decimal?
    let resetAtMs: Int64?
    let hubVisible: Bool

    static func sample(_ number: Int, atMs time: Int64) -> Data? {
        guard (number == 1 || number == 2), time >= 0,
              time <= 253_402_297_079_999 - 3_600_000 else { return nil }
        let percent = number == 1 ? "87.66" : "43.22"
        let json = """
        {"schemaVersion":1,"writtenAtMs":\(time),"hub":{"source":"synthetic","state":"ready","observedAtMs":\(time),"validUntilMs":\(time + 120000),"fiveHour":{"remainingPercent":\(percent),"reset":{"kind":"absolute","atMs":\(time + 3600000)}},"sevenDay":null,"monthly":null},"local":{"source":"none","state":"unavailable","readAtMs":null,"latestEventAtMs":null,"validUntilMs":null,"inputTokens":null,"outputTokens":null,"totalTokens":null,"knownThreads":null,"unknownThreads":null,"unidentifiedFiles":null,"topLevelThreads":null,"isLimited":null,"detailLimited":null,"cache":null}}
        """
        return Data(json.utf8)
    }

    // The development extension deliberately accepts only the exact synthetic
    // projection. It cannot turn a production gateway response into a display.
    static func decode(_ data: Data, nowMs: Int64) -> DevWidgetSnapshot? {
        guard nowMs >= 0, nowMs <= 253_402_300_799_999,
              data.count <= 8192, data.count > 0,
              !data.starts(with: [0xef, 0xbb, 0xbf]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var parser = DevJSONParser(text)
        guard let parsed = parser.parse(), case let .object(top) = parsed,
              top.hasExactly(["schemaVersion", "writtenAtMs", "hub", "local"]),
              top["schemaVersion"] == DevJSON.number("1"),
              let written = top["writtenAtMs"]?.time,
              written <= nowMs, nowMs - written <= 120_000,
              let hub = top["hub"], let local = top["local"],
              let acceptedHub = parseHub(hub, written: written, now: nowMs),
              validateLocal(local, written: written, now: nowMs)
        else { return nil }
        let visible = acceptedHub.visible
        let window = acceptedHub.fiveHour
        let resetAt = acceptedHub.resetAt
        return DevWidgetSnapshot(writtenAtMs: written, observedAtMs: acceptedHub.observed,
                                 validUntilMs: acceptedHub.valid, remainingPercent: visible ? window : nil,
                                 resetAtMs: resetAt, hubVisible: visible)
    }

    private static func parseHub(_ value: DevJSON, written: Int64, now: Int64)
        -> (visible: Bool, fiveHour: Decimal?, resetAt: Int64?, observed: Int64?, valid: Int64?)? {
        guard case let .object(hub) = value,
              hub.hasExactly(["source", "state", "observedAtMs", "validUntilMs", "fiveHour", "sevenDay", "monthly"]),
              let source = hub["source"]?.string, ["none", "synthetic"].contains(source),
              let state = hub["state"]?.string,
              ["ready", "unavailable", "disabled", "stale", "invalid"].contains(state),
              !(source == "none" && state == "ready") else { return nil }
        if state != "ready" {
            guard hub.except(["source", "state"]).values.allSatisfy({ $0 == .null }) else { return nil }
            return (false, nil, nil, nil, nil)
        }
        guard let observed = hub["observedAtMs"]?.time,
              let valid = hub["validUntilMs"]?.time,
              observed <= written, written <= now,
              valid >= observed, valid - observed <= 120_000,
              let five = hub["fiveHour"], let seven = hub["sevenDay"],
              let monthly = hub["monthly"],
              [five, seven, monthly].contains(where: { $0 != .null }),
              let fiveResult = parseWindow(five, source: source),
              parseWindow(seven, source: source) != nil,
              validateMonthly(monthly) else { return nil }
        let resetAt = fiveResult.resetAt
        let partitionVisible = now <= valid
        let windowVisible = partitionVisible && (resetAt == nil || resetAt! > now)
        return (partitionVisible, windowVisible ? fiveResult.percent : nil, resetAt, observed, valid)
    }

    private static func parseWindow(_ value: DevJSON, source: String)
        -> (percent: Decimal?, resetAt: Int64?)? {
        if value == .null { return (nil, nil) }
        guard case let .object(window) = value,
              window.hasExactly(["remainingPercent", "reset"]),
              let percent = window["remainingPercent"]?.decimal(maximum: 100),
              let reset = window["reset"] else { return nil }
        if reset == .null { return (percent, nil) }
        guard case let .object(fields) = reset,
              let kind = fields["kind"]?.string else { return nil }
        if kind == "absolute" {
            guard fields.hasExactly(["kind", "atMs"]),
                  let at = fields["atMs"]?.time else { return nil }
            return (percent, at)
        }
        guard kind == "partial", source == "synthetic",
              fields.hasExactly(["kind", "month", "day", "hour", "minute"]),
              let month = fields["month"]?.integer(maximum: 12), month >= 1,
              let day = fields["day"]?.integer(maximum: 31), day >= 1,
              let hour = fields["hour"]?.integer(maximum: 23),
              let minute = fields["minute"]?.integer(maximum: 59),
              day <= [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][Int(month - 1)]
        else { return nil }
        _ = hour
        _ = minute
        return (percent, nil)
    }

    private static func validateMonthly(_ value: DevJSON) -> Bool {
        if value == .null { return true }
        guard case let .object(month) = value,
              month.hasExactly(["usedAmount", "limitAmount", "symbol"]),
              let used = month["usedAmount"]?.decimal(maximum: 1_000_000_000_000_000_000),
              let symbol = month["symbol"]?.string,
              ["dollar", "yuan", "euro", "pound", "unknown"].contains(symbol),
              let limitValue = month["limitAmount"] else { return false }
        if limitValue == .null { return true }
        guard let limit = limitValue.decimal(maximum: 1_000_000_000_000_000_000) else { return false }
        return limit > 0 && used <= limit
    }

    private static func validateLocal(_ value: DevJSON, written: Int64, now: Int64) -> Bool {
        guard case let .object(local) = value,
              local.hasExactly(["source", "state", "readAtMs", "latestEventAtMs", "validUntilMs", "inputTokens", "outputTokens", "totalTokens", "knownThreads", "unknownThreads", "unidentifiedFiles", "topLevelThreads", "isLimited", "detailLimited", "cache"]),
              let source = local["source"]?.string, ["none", "synthetic"].contains(source),
              let state = local["state"]?.string,
              ["ready", "unavailable", "disabled", "stale", "invalid"].contains(state),
              !(source == "none" && state == "ready") else { return false }
        if state != "ready" {
            return local.except(["source", "state"]).values.allSatisfy({ $0 == .null })
        }
        guard let read = local["readAtMs"]?.time,
              let valid = local["validUntilMs"]?.time,
              read <= written, written <= now,
              valid >= read, valid - read <= 120_000,
              let known = local["knownThreads"]?.integer(maximum: 32),
              let unknown = local["unknownThreads"]?.integer(maximum: 32),
              local["unidentifiedFiles"]?.integer(maximum: 32) != nil,
              let top = local["topLevelThreads"]?.integer(maximum: 32),
              top <= known + unknown,
              local["isLimited"]?.bool != nil,
              local["detailLimited"]?.bool != nil,
              let latest = local["latestEventAtMs"],
              latest == .null || (latest.time.map({ $0 <= read }) ?? false),
              let cache = local["cache"], validateCache(cache)
        else { return false }
        let amounts = [local["inputTokens"], local["outputTokens"], local["totalTokens"]]
        if known == 0 { return amounts.allSatisfy({ $0 == .null }) }
        guard let input = amounts[0]?.integer(),
              let output = amounts[1]?.integer(),
              let total = amounts[2]?.integer(),
              input <= Int64.max - output else { return false }
        return total >= input + output
    }

    private static func validateCache(_ value: DevJSON) -> Bool {
        guard case let .object(cache) = value,
              cache.hasExactly(["state", "baseRows", "knownRows", "missingRows", "invalidRows", "matchedInputTokens", "matchedCachedInputTokens"]),
              let state = cache["state"]?.string,
              ["complete", "partial", "missing", "invalid"].contains(state),
              let base = cache["baseRows"]?.integer(maximum: 32),
              let known = cache["knownRows"]?.integer(maximum: 32),
              let missing = cache["missingRows"]?.integer(maximum: 32),
              let invalid = cache["invalidRows"]?.integer(maximum: 33),
              known <= base, missing <= base, invalid <= base + 1,
              let inputValue = cache["matchedInputTokens"],
              let cachedValue = cache["matchedCachedInputTokens"] else { return false }
        let bothNull = inputValue == .null && cachedValue == .null
        var matched = false
        if !bothNull {
            guard let input = inputValue.integer(),
                  let cached = cachedValue.integer(), cached <= input else { return false }
            matched = true
        }
        let complete = base > 0 && known == base && missing == 0 && invalid == 0 && matched
        if state == "complete" { return complete }
        if state == "partial" { return known > 0 && !complete }
        return true
    }
}

private enum DevJSON: Equatable {
    case object([String: DevJSON]), string(String), number(String), bool(Bool), null

    var string: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var bool: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    func integer(maximum: Int64 = Int64.max) -> Int64? {
        guard case let .number(raw) = self, !raw.isEmpty,
              raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              (raw == "0" || !raw.hasPrefix("0")),
              let value = Int64(raw), value >= 0, value <= maximum else { return nil }
        return value
    }

    var time: Int64? {
        integer(maximum: 253_402_300_799_999)
    }

    func decimal(maximum: Decimal) -> Decimal? {
        guard case let .number(raw) = self,
              let normalized = DecimalLexeme(raw),
              let result = normalized.exactDecimal(),
              result >= 0, result <= maximum else { return nil }
        return result
    }
}

private extension Dictionary where Key == String, Value == DevJSON {
    func hasExactly(_ keys: Set<String>) -> Bool { Set(self.keys) == keys }
    func except(_ keys: Set<String>) -> [String: DevJSON] {
        filter { !keys.contains($0.key) }
    }
}

// Decimal is a 128-bit coefficient with an 8-bit exponent. Normalize the
// lexical value first, then verify Foundation has preserved that exact value.
private struct DecimalLexeme {
    let digits: String
    let exponent: Int
    static let maxCoefficient = "340282366920938463463374607431768211455"

    init?(_ raw: String, maxBytes: Int = 128) {
        guard raw.utf8.count <= maxBytes else { return nil }
        let negative = raw.hasPrefix("-")
        let positiveForm = negative ? String(raw.dropFirst()) : raw
        let parts = positiveForm.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let mantissa = String(parts[0])
        let exponentText = parts.count == 2 ? String(parts[1]) : "0"
        guard !mantissa.isEmpty else { return nil }
        let pieces = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2,
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) })
        else { return nil }
        var combined = pieces.joined()
        while combined.first == "0" { combined.removeFirst() }
        if combined.isEmpty {
            self.digits = "0"
            self.exponent = 0
            return
        }
        guard !negative, let power = Int(exponentText),
              power > -100_000, power < 100_000 else { return nil }
        var adjusted = power - (pieces.count == 2 ? pieces[1].count : 0)
        while combined.last == "0" {
            combined.removeLast()
            adjusted += 1
        }
        guard combined.count <= 38 else { return nil }
        self.digits = combined
        self.exponent = adjusted
    }

    func exactDecimal() -> Decimal? {
        if digits == "0" { return .zero }
        guard exponent >= -128 else { return nil }
        var coefficient = digits
        var power = exponent
        if power > 127 {
            let shift = power - 127
            guard shift <= 39 - coefficient.count else { return nil }
            coefficient += String(repeating: "0", count: shift)
            power = 127
        }
        guard coefficient.count < 39 ||
              (coefficient.count == 39 && coefficient <= Self.maxCoefficient) else { return nil }
        let safeLexeme = "\(coefficient)e\(power)"
        guard let value = Decimal(string: safeLexeme, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let rendered = NSDecimalNumber(decimal: value).stringValue
        guard let roundTrip = DecimalLexeme(rendered, maxBytes: 256),
              roundTrip.digits == digits, roundTrip.exponent == exponent else { return nil }
        return value
    }
}

// Small strict JSON reader: duplicate names, arrays, trailing bytes, and free
// strings are rejected before a snapshot can reach the view.
private struct DevJSONParser {
    private let bytes: [UInt8]
    private var offset = 0
    init(_ text: String) { bytes = Array(text.utf8) }

    mutating func parse() -> DevJSON? {
        guard let value = item(depth: 0) else { return nil }
        space()
        return offset == bytes.count ? value : nil
    }

    private mutating func space() {
        while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }

    private mutating func take(_ byte: UInt8) -> Bool {
        guard offset < bytes.count, bytes[offset] == byte else { return false }
        offset += 1
        return true
    }

    private mutating func item(depth: Int) -> DevJSON? {
        guard depth <= 4 else { return nil }
        space()
        guard offset < bytes.count else { return nil }
        if take(123) {
            var result: [String: DevJSON] = [:]
            space()
            if take(125) { return .object(result) }
            while true {
                space()
                guard let key = quoted(), result[key] == nil else { return nil }
                space()
                guard take(58), let value = item(depth: depth + 1) else { return nil }
                result[key] = value
                space()
                if take(125) { return .object(result) }
                guard take(44) else { return nil }
            }
        }
        if bytes[offset] == 34 { return quoted().map(DevJSON.string) }
        for (literal, value) in [("true", DevJSON.bool(true)), ("false", .bool(false)), ("null", .null)] {
            if bytes[offset...].starts(with: literal.utf8) {
                offset += literal.utf8.count
                return value
            }
        }
        let start = offset
        if take(45) { guard offset < bytes.count else { return nil } }
        if take(48) {
            if offset < bytes.count && bytes[offset] >= 48 && bytes[offset] <= 57 { return nil }
        } else {
            guard offset < bytes.count, bytes[offset] >= 49, bytes[offset] <= 57 else { return nil }
            repeat { offset += 1 } while offset < bytes.count && bytes[offset] >= 48 && bytes[offset] <= 57
        }
        if take(46) {
            let fractionStart = offset
            while offset < bytes.count && bytes[offset] >= 48 && bytes[offset] <= 57 { offset += 1 }
            guard offset > fractionStart else { return nil }
        }
        if take(101) || take(69) {
            _ = take(43) || take(45)
            let exponentStart = offset
            while offset < bytes.count && bytes[offset] >= 48 && bytes[offset] <= 57 { offset += 1 }
            guard offset > exponentStart else { return nil }
        }
        return .number(String(decoding: bytes[start..<offset], as: UTF8.self))
    }

    private mutating func quoted() -> String? {
        guard take(34) else { return nil }
        let start = offset - 1
        var escaped = false
        while offset < bytes.count {
            let byte = bytes[offset]
            if escaped {
                escaped = false
                offset += 1
                continue
            }
            if byte == 92 {
                escaped = true
                offset += 1
                continue
            }
            if byte == 34 {
                offset += 1
                let data = Data(bytes[start..<offset])
                return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String
            }
            if byte < 32 { return nil }
            offset += 1
        }
        return nil
    }
}
