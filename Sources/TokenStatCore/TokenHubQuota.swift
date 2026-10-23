import Foundation
import Darwin

public enum TokenHubTarget {
    public static let bundleID = "com.seasun.tokenhub.desktop"
}

public struct TokenHubIdentity: Equatable, Sendable {
    public let pid: pid_t
    public let bundleID: String
    public let executablePath: String

    public init(pid: pid_t, bundleID: String, executablePath: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.executablePath = URL(fileURLWithPath: executablePath).standardizedFileURL.path
    }
}

public enum TokenHubWindowKind: String, Equatable, Sendable { case fiveHour, sevenDay }

public struct TokenHubWindowQuota: Equatable, Sendable {
    public let kind: TokenHubWindowKind
    public let usedAmount: Decimal
    public let limitAmount: Decimal
    public let sourceSymbol: String
    public let usedPercent: Decimal
    public var remainingPercent: Decimal { Decimal(100) - usedPercent }
    public let resetDisplay: String
    /// 来源重置时间戳，当直连接口提供了该值时。AX
    /// 仅显示的行将此值留空，而不是猜测一个日期。
    public let resetAt: Date?

    public init(kind: TokenHubWindowKind, usedAmount: Decimal, limitAmount: Decimal,
                sourceSymbol: String, usedPercent: Decimal, resetDisplay: String,
                resetAt: Date? = nil) {
        self.kind = kind; self.usedAmount = usedAmount; self.limitAmount = limitAmount
        self.sourceSymbol = sourceSymbol; self.usedPercent = usedPercent; self.resetDisplay = resetDisplay
        self.resetAt = resetAt
    }
}

public struct TokenHubMonthlyUsage: Equatable, Sendable {
    public let usedAmount: Decimal
    public let sourceSymbol: String
    /// 月度总量是可选的，因为部分企业响应会
    /// 只暴露用量而不含额度。此时派生值保持未知。
    public let limitAmount: Decimal?
    public var remainingAmount: Decimal? {
        guard let limitAmount, limitAmount > 0, usedAmount >= 0, usedAmount <= limitAmount else { return nil }
        return limitAmount - usedAmount
    }
    public var usedPercent: Decimal? {
        guard let limitAmount, limitAmount > 0, usedAmount >= 0, usedAmount <= limitAmount else { return nil }
        return (usedAmount / limitAmount) * Decimal(100)
    }
    public init(usedAmount: Decimal, sourceSymbol: String, limitAmount: Decimal? = nil) {
        self.usedAmount = usedAmount; self.sourceSymbol = sourceSymbol; self.limitAmount = limitAmount
    }
}

public struct TokenHubQuotaSnapshot: Equatable, Sendable {
    public let identity: TokenHubIdentity
    public let fiveHour: TokenHubWindowQuota?
    public let sevenDay: TokenHubWindowQuota?
    public let monthly: TokenHubMonthlyUsage?
    /// 可用重置券数量；接口未提供或读取失败时为 nil，不猜测为 0。
    public let resetVoucherCount: Int?
    public let observedAt: Date
    public init(identity: TokenHubIdentity, fiveHour: TokenHubWindowQuota?, sevenDay: TokenHubWindowQuota?,
                monthly: TokenHubMonthlyUsage?, resetVoucherCount: Int? = nil, observedAt: Date) {
        self.identity = identity; self.fiveHour = fiveHour; self.sevenDay = sevenDay
        self.monthly = monthly; self.resetVoucherCount = resetVoucherCount
        self.observedAt = observedAt
    }
}

public enum TokenHubQuotaStatus: Equatable, Sendable {
    case disabled, permissionRequired, targetNotRunning, ambiguousTarget
    case quotaGroupUnavailable, unsupportedLayout, accessFailed, stale, connected
}

public enum TokenHubQuotaField: Equatable, Sendable { case fiveHour, sevenDay, monthly }

public enum TokenHubQuotaFailure: Error, Equatable, Sendable {
    case permissionMissing, noTarget, multipleTargets, identityChanged, elementPIDMismatch
    case axError, nodeBudgetExceeded, depthBudgetExceeded, childBudgetExceeded
    case textBudgetExceeded, timeBudgetExceeded, elementTimeout
    case quotaGroupMissing, duplicateQuotaGroup, duplicateWindow(TokenHubWindowKind)
    case duplicateMonthlyContainer, malformedPresentField(TokenHubQuotaField)
    case doubleReadMismatch, noQuotaFields
}

public struct TokenHubQuotaResult: Equatable, Sendable {
    public let status: TokenHubQuotaStatus
    public let snapshot: TokenHubQuotaSnapshot?
    public let failure: TokenHubQuotaFailure?
    public init(status: TokenHubQuotaStatus, snapshot: TokenHubQuotaSnapshot?, failure: TokenHubQuotaFailure?) {
        self.status = status; self.snapshot = snapshot; self.failure = failure
    }
}

public enum TokenHubRunMode: Equatable, Sendable { case localCodex, proxy }

public struct TokenHubQuotaObservation: Equatable, Sendable {
    public let permissionTrusted: Bool
    public let targets: [TokenHubIdentity]
    public let before: TokenHubIdentity?
    public let after: TokenHubIdentity?
    public let first: TokenHubQuotaPass
    public let second: TokenHubQuotaPass
    public let traversal: TokenHubTraversalSummary
    public let accessTrace: [TokenHubReadEvent]
    public init(permissionTrusted: Bool, targets: [TokenHubIdentity], before: TokenHubIdentity?, after: TokenHubIdentity?,
                first: TokenHubQuotaPass, second: TokenHubQuotaPass, traversal: TokenHubTraversalSummary,
                accessTrace: [TokenHubReadEvent]) {
        self.permissionTrusted = permissionTrusted; self.targets = targets; self.before = before; self.after = after
        self.first = first; self.second = second; self.traversal = traversal; self.accessTrace = accessTrace
    }
}

public struct TokenHubQuotaPass: Equatable, Sendable {
    public let rootIdentity: TokenHubIdentity
    public let quotaGroupCount: Int
    public let fiveHourMarkerSeen: Bool
    public let fiveHour: TokenHubWindowObservation?
    public let sevenDayMarkerSeen: Bool
    public let sevenDay: TokenHubWindowObservation?
    public let monthlyContainerCount: Int
    public let monthly: TokenHubMonthlyObservation?
    public init(rootIdentity: TokenHubIdentity, quotaGroupCount: Int, fiveHourMarkerSeen: Bool,
                fiveHour: TokenHubWindowObservation?, sevenDayMarkerSeen: Bool,
                sevenDay: TokenHubWindowObservation?, monthlyContainerCount: Int,
                monthly: TokenHubMonthlyObservation?) {
        self.rootIdentity = rootIdentity; self.quotaGroupCount = quotaGroupCount
        self.fiveHourMarkerSeen = fiveHourMarkerSeen; self.fiveHour = fiveHour
        self.sevenDayMarkerSeen = sevenDayMarkerSeen; self.sevenDay = sevenDay
        self.monthlyContainerCount = monthlyContainerCount; self.monthly = monthly
    }
}

public struct TokenHubWindowObservation: Equatable, Sendable {
    public let titleSeen: Bool
    public let usedPercentText: String?
    public let amountText: String?
    public let progressLabel: String?
    public let progressValue: Decimal?
    public let resetLabelSeen: Bool
    public let resetText: String?
    public init(titleSeen: Bool, usedPercentText: String?, amountText: String?, progressLabel: String?,
                progressValue: Decimal?, resetLabelSeen: Bool, resetText: String?) {
        self.titleSeen = titleSeen; self.usedPercentText = usedPercentText; self.amountText = amountText
        self.progressLabel = progressLabel; self.progressValue = progressValue
        self.resetLabelSeen = resetLabelSeen; self.resetText = resetText
    }
}

public struct TokenHubMonthlyObservation: Equatable, Sendable {
    public let amountText: String?
    public init(amountText: String?) { self.amountText = amountText }
}

public struct TokenHubTraversalSummary: Equatable, Sendable {
    public let nodeVisits: Int
    public let maximumDepth: Int
    public let maximumChildrenForAnyNode: Int
    public let longestStringCharacters: Int
    public let textCharacters: Int
    public let elapsed: TimeInterval
    public let slowestElementMessage: TimeInterval
    public init(nodeVisits: Int, maximumDepth: Int, maximumChildrenForAnyNode: Int,
                longestStringCharacters: Int, textCharacters: Int, elapsed: TimeInterval,
                slowestElementMessage: TimeInterval) {
        self.nodeVisits = nodeVisits; self.maximumDepth = maximumDepth
        self.maximumChildrenForAnyNode = maximumChildrenForAnyNode
        self.longestStringCharacters = longestStringCharacters; self.textCharacters = textCharacters
        self.elapsed = elapsed; self.slowestElementMessage = slowestElementMessage
    }
}

public enum TokenHubQuotaParser {
    public static func parse(_ observation: TokenHubQuotaObservation, now: Date,
                             refreshSeconds: TimeInterval) -> TokenHubQuotaResult {
        func fail(_ failure: TokenHubQuotaFailure, _ status: TokenHubQuotaStatus = .unsupportedLayout) -> TokenHubQuotaResult {
            TokenHubQuotaResult(status: status, snapshot: nil, failure: failure)
        }
        guard observation.permissionTrusted else { return fail(.permissionMissing, .permissionRequired) }
        guard observation.targets.count == 1 else {
            return observation.targets.isEmpty ? fail(.noTarget, .targetNotRunning) : fail(.multipleTargets, .ambiguousTarget)
        }
        let identity = observation.targets[0]
        guard identity.bundleID == TokenHubTarget.bundleID else { return fail(.noTarget, .targetNotRunning) }
        guard identity.bundleID == TokenHubTarget.bundleID,
              identity.pid > 0,
              identity.executablePath.hasPrefix("/"),
              identity.executablePath == URL(fileURLWithPath: identity.executablePath).standardizedFileURL.path,
              observation.before == identity, observation.after == identity,
              observation.first.rootIdentity == identity, observation.second.rootIdentity == identity else {
            return fail(.identityChanged, .accessFailed)
        }
        let limits = observation.traversal
        guard limits.nodeVisits >= 0, limits.maximumDepth >= 0, limits.maximumChildrenForAnyNode >= 0,
              limits.longestStringCharacters >= 0, limits.textCharacters >= 0,
              limits.elapsed.isFinite, limits.slowestElementMessage.isFinite else {
            return fail(.axError, .accessFailed)
        }
        if limits.nodeVisits > 512 { return fail(.nodeBudgetExceeded, .accessFailed) }
        if limits.maximumDepth > 16 { return fail(.depthBudgetExceeded, .accessFailed) }
        if limits.maximumChildrenForAnyNode > 64 { return fail(.childBudgetExceeded, .accessFailed) }
        if limits.longestStringCharacters > 256 || limits.textCharacters > 8192 { return fail(.textBudgetExceeded, .accessFailed) }
        if limits.elapsed > 3 { return fail(.timeBudgetExceeded, .accessFailed) }
        if limits.slowestElementMessage > 0.15 { return fail(.elementTimeout, .accessFailed) }
        guard observation.first.quotaGroupCount == 1, observation.second.quotaGroupCount == 1 else {
            let count = max(observation.first.quotaGroupCount, observation.second.quotaGroupCount)
            return fail(count == 0 ? .quotaGroupMissing : .duplicateQuotaGroup,
                        count == 0 ? .quotaGroupUnavailable : .unsupportedLayout)
        }
        func checkedWindow(_ kind: TokenHubWindowKind, marker: Bool,
                           value: TokenHubWindowObservation?) -> Result<TokenHubWindowQuota?, TokenHubQuotaFailure> {
            guard marker || value != nil else { return .success(nil) }
            guard let value,
                  value.titleSeen,
                  let percentText = value.usedPercentText,
                  let amountText = value.amountText,
                  let progressLabel = value.progressLabel,
                  let progress = value.progressValue,
                  value.resetLabelSeen,
                  let reset = value.resetText,
                  progressLabel == (kind == .fiveHour ? "5 小时限额已用比例" : "7 天限额已用比例") else {
                return .failure(.malformedPresentField(kind == .fiveHour ? .fiveHour : .sevenDay))
            }
            guard let textPercent = parsePercent(percentText), textPercent >= 0, textPercent <= 100,
                  progress >= 0, progress <= 100, abs(textPercent - progress) <= Decimal(string: "0.1")!,
                  let amount = parseAmountPair(amountText), amount.used >= 0, amount.limit > 0,
                  amount.used <= amount.limit,
                  let resetText = validReset(reset) else {
                return .failure(.malformedPresentField(kind == .fiveHour ? .fiveHour : .sevenDay))
            }
            return .success(TokenHubWindowQuota(kind: kind, usedAmount: amount.used, limitAmount: amount.limit,
                                                 sourceSymbol: amount.symbol, usedPercent: progress, resetDisplay: resetText))
        }
        typealias ParsedPass = (five: TokenHubWindowQuota?, seven: TokenHubWindowQuota?, monthly: TokenHubMonthlyUsage?)
        func parse(_ pass: TokenHubQuotaPass) -> Result<ParsedPass, TokenHubQuotaFailure> {
            if pass.monthlyContainerCount > 1 { return .failure(.duplicateMonthlyContainer) }
            if pass.monthlyContainerCount < 0 { return .failure(.axError) }
            let five: TokenHubWindowQuota?
            switch checkedWindow(.fiveHour, marker: pass.fiveHourMarkerSeen, value: pass.fiveHour) {
            case .success(let value): five = value
            case .failure(let failure): return .failure(failure)
            }
            let seven: TokenHubWindowQuota?
            switch checkedWindow(.sevenDay, marker: pass.sevenDayMarkerSeen, value: pass.sevenDay) {
            case .success(let value): seven = value
            case .failure(let failure): return .failure(failure)
            }
            var monthly: TokenHubMonthlyUsage?
            if pass.monthlyContainerCount == 1 {
                guard let raw = pass.monthly?.amountText, let amount = parseSingleAmount(raw) else {
                    return .failure(.malformedPresentField(.monthly))
                }
                monthly = TokenHubMonthlyUsage(usedAmount: amount.used, sourceSymbol: amount.symbol)
            } else if pass.monthly != nil {
                return .failure(.malformedPresentField(.monthly))
            }
            return .success((five, seven, monthly))
        }
        let first: ParsedPass
        switch parse(observation.first) {
        case .success(let value): first = value
        case .failure(let failure): return fail(failure)
        }
        let second: ParsedPass
        switch parse(observation.second) {
        case .success(let value): second = value
        case .failure(let failure): return fail(failure)
        }
        guard first.five == second.five, first.seven == second.seven, first.monthly == second.monthly else {
            return fail(.doubleReadMismatch)
        }
        let five = first.five, seven = first.seven, monthly = first.monthly
        guard five != nil || seven != nil || monthly != nil else { return fail(.noQuotaFields, .quotaGroupUnavailable) }
        return TokenHubQuotaResult(status: .connected,
            snapshot: TokenHubQuotaSnapshot(identity: identity, fiveHour: five, sevenDay: seven, monthly: monthly, observedAt: now),
            failure: nil)
    }

    private static func parsePercent(_ text: String) -> Decimal? {
        let pattern = #"^(?:(?:5 小时限额|7 天限额)\s+)?已使用\s*([0-9]+(?:\.[0-9]+)?)%$"#
        let regex = try? NSRegularExpression(pattern: pattern)
        guard let regex,
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(result.range(at: 1), in: text) else { return nil }
        let number = String(text[numberRange])
        return Decimal(string: number, locale: Locale(identifier: "en_US_POSIX"))
    }

    private struct ParsedAmount { let used: Decimal; let limit: Decimal; let symbol: String }
    private static func parseAmountPair(_ text: String) -> ParsedAmount? {
        let pattern = #"^\s*(\$)([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*/\s*\$(?:\s*)([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges == 4,
              let usedRange = Range(match.range(at: 2), in: text), let limitRange = Range(match.range(at: 3), in: text) else { return nil }
        guard let used = parseDecimalAmount(String(text[usedRange])), let limit = parseDecimalAmount(String(text[limitRange])) else { return nil }
        return ParsedAmount(used: used, limit: limit, symbol: "$")
    }
    private static func parseSingleAmount(_ text: String) -> ParsedAmount? {
        let pattern = #"^\s*(\$)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges == 3,
              let range = Range(match.range(at: 2), in: text), let value = parseDecimalAmount(String(text[range])) else { return nil }
        return ParsedAmount(used: value, limit: 0, symbol: "$")
    }
    private static func parseDecimalAmount(_ raw: String) -> Decimal? {
        let pieces = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { return nil }
        let integer = String(pieces[0])
        if integer.contains(",") {
            let groups = integer.split(separator: ",", omittingEmptySubsequences: false)
            guard let first = groups.first, (1...3).contains(first.count), first.allSatisfy(\.isNumber),
                  groups.dropFirst().allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isNumber) }) else { return nil }
        } else if !integer.allSatisfy(\.isNumber) { return nil }
        if pieces.count == 2, !(1...2).contains(pieces[1].count) { return nil }
        let normalized = raw.replacingOccurrences(of: ",", with: "")
        guard let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              !NSDecimalNumber(decimal: value).doubleValue.isNaN,
              value >= 0, value <= Decimal(string: "1000000000000000")! else { return nil }
        return value
    }
    private static func validReset(_ text: String) -> String? {
        let pattern = #"^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01]) ([01][0-9]|2[0-3]):[0-5][0-9]$"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let pieces = text[..<range.upperBound].split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" })
        guard pieces.count == 4, let month = Int(pieces[0]), let day = Int(pieces[1]) else { return nil }
        let maxDay: Int
        switch month { case 2: maxDay = 29; case 4, 6, 9, 11: maxDay = 30; default: maxDay = 31 }
        guard day <= maxDay else { return nil }
        return text
    }
}
