import Foundation

public typealias TokenHubNodeID = Int

public enum TokenHubAXRole: Equatable, Sendable {
    case application, window, group, staticText, progressIndicator
    case button, table, editableText, secureText, other(String)
}
public enum TokenHubGroupLabelKind: Equatable, Sendable { case description, title }

public protocol TokenHubBoundedTreeReading {
    func exactBundleTargets(bundleID: String) throws -> [TokenHubIdentity]
    func rootNode(for identity: TokenHubIdentity, timeout: TimeInterval) throws -> TokenHubNodeID
    func identity(of node: TokenHubNodeID, timeout: TimeInterval) throws -> TokenHubIdentity
    func role(of node: TokenHubNodeID, timeout: TimeInterval) throws -> TokenHubAXRole
    func groupLabel(of node: TokenHubNodeID, kind: TokenHubGroupLabelKind,
                    timeout: TimeInterval) throws -> String?
    func children(of node: TokenHubNodeID, maximum: Int, timeout: TimeInterval) throws -> TokenHubChildrenPage
    func staticText(of node: TokenHubNodeID, maximumCharacters: Int, timeout: TimeInterval) throws -> String?
    func progressLabel(of node: TokenHubNodeID, timeout: TimeInterval) throws -> String?
    func progressValue(of node: TokenHubNodeID, timeout: TimeInterval) throws -> Decimal?
}

public struct TokenHubChildrenPage: Equatable, Sendable {
    public let nodes: [TokenHubNodeID]
    public let isTruncated: Bool
    public init(nodes: [TokenHubNodeID], isTruncated: Bool) { self.nodes = nodes; self.isTruncated = isTruncated }
}

public protocol TokenHubQuotaScanning {
    func scan(now: Date, monotonicNow: () -> TimeInterval, permissionTrusted: Bool,
              refreshSeconds: TimeInterval, mode: TokenHubRunMode,
              generation: UInt64) -> TokenHubQuotaResult
}

public enum TokenHubReadEvent: Equatable, Sendable {
    case targets, root, identity(TokenHubNodeID), role(TokenHubNodeID)
    case groupDescription(TokenHubNodeID), groupTitle(TokenHubNodeID)
    case children(TokenHubNodeID), staticText(TokenHubNodeID)
    case progressLabel(TokenHubNodeID), progressValue(TokenHubNodeID)
}

public struct TokenHubQuotaScanner {
    public init() {}
    public func scan(using reader: any TokenHubBoundedTreeReading, now: Date,
                     monotonicNow: () -> TimeInterval, permissionTrusted: Bool,
                     refreshSeconds: TimeInterval, mode: TokenHubRunMode, generation: UInt64) -> TokenHubQuotaResult {
        var events: [TokenHubReadEvent] = []
        var visits = 0, maxDepth = 0, maxChildren = 0, longest = 0, textCount = 0
        var slowest: TimeInterval = 0
        let started = monotonicNow()
        func failure(_ value: TokenHubQuotaFailure, status: TokenHubQuotaStatus = .accessFailed) -> TokenHubQuotaResult {
            TokenHubQuotaResult(status: status, snapshot: nil, failure: value)
        }
        if mode != .localCodex { return TokenHubQuotaResult(status: .disabled, snapshot: nil, failure: nil) }
        guard permissionTrusted else { return failure(.permissionMissing, status: .permissionRequired) }
        func elapsed() -> TimeInterval { max(0, monotonicNow() - started) }
        func budgetCheck() throws {
            if elapsed() > 3 { throw ScanIssue.failure(.timeBudgetExceeded) }
        }
        func message<T>(_ node: TokenHubNodeID?, event: TokenHubReadEvent,
                        enforceSingleMessageLimit: Bool = true, _ body: () throws -> T) throws -> T {
            try budgetCheck()
            let t0 = monotonicNow()
            do {
                let result = try body()
                let duration = max(0, monotonicNow() - t0)
                if enforceSingleMessageLimit {
                    slowest = max(slowest, duration)
                    if duration > 0.15 { throw ScanIssue.failure(.elementTimeout) }
                }
                try budgetCheck()
                return result
            } catch let issue as ScanIssue { throw issue }
            catch { throw ScanIssue.failure(.axError) }
        }
        do {
            events.append(.targets)
            let targets = try reader.exactBundleTargets(bundleID: TokenHubTarget.bundleID)
            guard targets.count == 1 else {
                if targets.isEmpty { throw ScanIssue.failure(.noTarget) }
                throw ScanIssue.failure(.multipleTargets)
            }
            let selected = targets[0]
            guard selected.bundleID == TokenHubTarget.bundleID, selected.pid > 0,
                  selected.executablePath.hasPrefix("/"),
                  selected.executablePath == URL(fileURLWithPath: selected.executablePath).standardizedFileURL.path else {
                throw ScanIssue.failure(.identityChanged)
            }
            let before = selected
            events.append(.root)
            let root = try reader.rootNode(for: selected, timeout: 0.15)
            var nodeParent: [TokenHubNodeID: TokenHubNodeID] = [:]
            var found: [TokenHubNodeID] = []
            var foundDepth: [TokenHubNodeID: Int] = [:]
            var visitedOnPath = Set<TokenHubNodeID>()

            func visit(_ node: TokenHubNodeID, depth: Int) throws -> TokenHubAXRole {
                try budgetCheck()
                guard depth <= 16 else { throw ScanIssue.failure(.depthBudgetExceeded) }
                visits += 1
                if visits > 512 { throw ScanIssue.failure(.nodeBudgetExceeded) }
                maxDepth = max(maxDepth, depth)
                events.append(.identity(node))
                let identity = try message(node, event: .identity(node)) { try reader.identity(of: node, timeout: 0.15) }
                guard identity == selected else {
                    throw ScanIssue.failure(node == root ? .identityChanged : .elementPIDMismatch)
                }
                events.append(.role(node))
                let role = try message(node, event: .role(node)) { try reader.role(of: node, timeout: 0.15) }
                return role
            }
            func label(_ node: TokenHubNodeID, kind: TokenHubGroupLabelKind) throws -> String? {
                let event: TokenHubReadEvent = kind == .description ? .groupDescription(node) : .groupTitle(node)
                events.append(event)
                let value = try message(node, event: event) { try reader.groupLabel(of: node, kind: kind, timeout: 0.15) }
                try countText(value)
                return value
            }
            func countText(_ value: String?) throws {
                guard let value else { return }
                let count = value.count
                longest = max(longest, count)
                guard count <= 256 else { throw ScanIssue.failure(.textBudgetExceeded) }
                textCount += count
                guard textCount <= 8192 else { throw ScanIssue.failure(.textBudgetExceeded) }
            }
            func children(_ node: TokenHubNodeID) throws -> [TokenHubNodeID] {
                events.append(.children(node))
                // The native children operation performs separate bounded count and copy AX messages;
                // each receives a 0.15s timeout, while this wrapper enforces the shared 3s scan limit.
                let page = try message(node, event: .children(node), enforceSingleMessageLimit: false) {
                    try reader.children(of: node, maximum: 64, timeout: 0.15)
                }
                guard page.nodes.count <= 64 else { throw ScanIssue.failure(.childBudgetExceeded) }
                guard !page.isTruncated else { throw ScanIssue.failure(.childBudgetExceeded) }
                maxChildren = max(maxChildren, page.nodes.count)
                return page.nodes
            }
            func discover(_ node: TokenHubNodeID, depth: Int) throws {
                guard !visitedOnPath.contains(node) else { throw ScanIssue.failure(.axError) }
                visitedOnPath.insert(node); defer { visitedOnPath.remove(node) }
                let role = try visit(node, depth: depth)
                if role == .button || role == .table || role == .editableText || role == .secureText { return }
                if role == .group {
                    let description = try label(node, kind: .description)
                    let title = try label(node, kind: .title)
                    if description == "用量和限额" || title == "用量和限额" {
                        found.append(node); foundDepth[node] = depth
                    }
                }
                guard role == .application || role == .window || role == .group || role == .other("AXWebArea") || role == .other("AXScrollArea") else { return }
                for child in try children(node) { nodeParent[child] = node; try discover(child, depth: depth + 1) }
            }
            try discover(root, depth: 0)
            guard found.count == 1 else {
                if found.isEmpty { throw ScanIssue.failure(.quotaGroupMissing) }
                throw ScanIssue.failure(.duplicateQuotaGroup)
            }
            let quotaGroup = found[0]
            func readPass() throws -> TokenHubQuotaPass {
                var records: [(role: TokenHubAXRole, text: String?, progressLabel: String?, progress: Decimal?, node: Int)] = []
                var duplicateQuotaMarkers = 0
                var monthlyGroups = [TokenHubNodeID]()
                var inside = Set<TokenHubNodeID>()
                func read(_ node: TokenHubNodeID, depth: Int, isRoot: Bool = false) throws {
                    guard !inside.contains(node) else { throw ScanIssue.failure(.axError) }
                    inside.insert(node); defer { inside.remove(node) }
                    let role = try visit(node, depth: depth)
                    if role == .button || role == .table || role == .editableText || role == .secureText { return }
                    if role == .group && node != quotaGroup {
                        let d = try label(node, kind: .description)
                        let t = try label(node, kind: .title)
                        if d == "用量和限额" || t == "用量和限额" { duplicateQuotaMarkers += 1 }
                        if d == "月度用量" || t == "月度用量" { monthlyGroups.append(node) }
                    }
                    if role == .staticText {
                        events.append(.staticText(node))
                        let value = try message(node, event: .staticText(node)) { try reader.staticText(of: node, maximumCharacters: 256, timeout: 0.15) }
                        try countText(value)
                        records.append((role, value, nil, nil, node))
                    } else if role == .progressIndicator {
                        events.append(.progressLabel(node))
                        let progressLabel = try message(node, event: .progressLabel(node)) { try reader.progressLabel(of: node, timeout: 0.15) }
                        try countText(progressLabel)
                        let value: Decimal?
                        if progressLabel == "5 小时限额已用比例" || progressLabel == "7 天限额已用比例" {
                            events.append(.progressValue(node))
                            value = try message(node, event: .progressValue(node)) { try reader.progressValue(of: node, timeout: 0.15) }
                        } else { value = nil }
                        records.append((role, nil, progressLabel, value, node))
                    }
                    guard role == .application || role == .window || role == .group || role == .other("AXWebArea") || role == .other("AXScrollArea") else { return }
                    let childNodes = try children(node)
                    if depth == 16, !childNodes.isEmpty { throw ScanIssue.failure(.depthBudgetExceeded) }
                    for child in childNodes { nodeParent[child] = node; try read(child, depth: depth + 1) }
                }
                try read(quotaGroup, depth: foundDepth[quotaGroup] ?? 0, isRoot: true)
                if duplicateQuotaMarkers > 0 { throw ScanIssue.failure(.duplicateQuotaGroup) }
                let quotaGroups = found.count
                guard monthlyGroups.count <= 1 else { throw ScanIssue.failure(.duplicateMonthlyContainer) }
                var fiveMarkers = 0, sevenMarkers = 0
                var fiveProgressMarkers = 0, sevenProgressMarkers = 0
                var five: TokenHubWindowObservation?, seven: TokenHubWindowObservation?
                var monthly: TokenHubMonthlyObservation?
                func isWithinMonthly(_ node: Int) -> Bool {
                    var cursor: Int? = node
                    while let current = cursor {
                        if monthlyGroups.contains(current) { return true }
                        cursor = nodeParent[current]
                    }
                    return false
                }
                let titles = records.indices.filter { index in
                    guard records[index].role == .staticText, let text = records[index].text else { return false }
                    return text.hasPrefix("5 小时限额") || text.hasPrefix("7 天限额")
                }
                for (position, titleIndex) in titles.enumerated() {
                    let title = records[titleIndex].text!
                    let kind: TokenHubWindowKind = title.hasPrefix("5 小时限额") ? .fiveHour : .sevenDay
                    if kind == .fiveHour { fiveMarkers += 1 } else { sevenMarkers += 1 }
                    let nextWindow = titles.dropFirst(position + 1).first ?? records.count
                    let nextMonthly = records.indices.first { index in index > titleIndex && isWithinMonthly(records[index].node) } ?? records.count
                    let boundary = min(nextWindow, nextMonthly)
                    let range = (titleIndex + 1)..<boundary
                    let expectedProgress = kind == .fiveHour ? "5 小时限额已用比例" : "7 天限额已用比例"
                    let allAmountRows = range.filter { i in records[i].role == .staticText && records[i].text?.hasPrefix("$") == true }
                    let amounts = range.filter { i in
                        records[i].role == .staticText && records[i].text?.hasPrefix("$") == true && records[i].text?.contains("/") == true
                    }
                    let progress = range.filter { i in records[i].role == .progressIndicator && records[i].progressLabel == expectedProgress }
                    let resetLabels = range.filter { i in records[i].role == .staticText && records[i].text == "重置" }
                    let resetValues = range.filter { i in
                        guard records[i].role == .staticText, let value = records[i].text else { return false }
                        return value.range(of: #"^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01]) ([01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil
                    }
                    let unexpected = range.contains { i in
                        let record = records[i]
                        if record.role == .staticText, let text = record.text {
                            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
                            return !text.hasPrefix("$") && text != "额度" && text != "重置" && text != "时间" &&
                                text.range(of: #"^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01]) ([01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) == nil
                        }
                        if record.role == .progressIndicator { return record.progressLabel != expectedProgress && record.progressLabel != "重置进度" }
                        return false
                    }
                    if kind == .fiveHour { fiveProgressMarkers += progress.count } else { sevenProgressMarkers += progress.count }
                    // Require one ordered amount -> matching progress -> reset label -> reset value chain.
                    let validChains = amounts.filter { amount in
                        guard amounts.count == 1, progress.count == 1,
                              resetLabels.count == 1, resetValues.count == 1,
                              let p = progress.first, let r = resetLabels.first,
                              let v = resetValues.first else { return false }
                        return amount < p && p < r && r < v
                    }
                    if allAmountRows.count != amounts.count || amounts.count > 1 || progress.count > 1 || resetLabels.count > 1 || resetValues.count > 1 || validChains.count > 1 || unexpected {
                        throw ScanIssue.failure(.malformedPresentField(kind == .fiveHour ? .fiveHour : .sevenDay))
                    }
                    let amountIndex = validChains.first
                    let progressIndex = amountIndex.flatMap { a in progress.first(where: { $0 > a }) }
                    let resetIndex = progressIndex.flatMap { p in resetLabels.first(where: { $0 > p }) }
                    let resetValueIndex = resetIndex.flatMap { r in resetValues.first(where: { $0 > r }) }
                    let observation = TokenHubWindowObservation(titleSeen: true, usedPercentText: title,
                        amountText: amountIndex.flatMap { records[$0].text },
                        progressLabel: progressIndex.flatMap { records[$0].progressLabel },
                        progressValue: progressIndex.flatMap { records[$0].progress },
                        resetLabelSeen: resetIndex != nil, resetText: resetValueIndex.flatMap { records[$0].text })
                    if kind == .fiveHour { five = observation } else { seven = observation }
                }
                fiveProgressMarkers = records.filter { $0.role == .progressIndicator && $0.progressLabel == "5 小时限额已用比例" }.count
                sevenProgressMarkers = records.filter { $0.role == .progressIndicator && $0.progressLabel == "7 天限额已用比例" }.count
                if fiveMarkers > 1 || fiveProgressMarkers > 1 { throw ScanIssue.failure(.duplicateWindow(.fiveHour)) }
                if sevenMarkers > 1 || sevenProgressMarkers > 1 { throw ScanIssue.failure(.duplicateWindow(.sevenDay)) }
                if !monthlyGroups.isEmpty {
                    // Only extract amount text whose node is directly or indirectly under the unique monthly group.
                    let values = records.enumerated().compactMap { index, record -> String? in
                        guard record.role == .staticText, isWithinMonthly(record.node),
                              let text = record.text, text.hasPrefix("$") else { return nil }
                        return text
                    }
                    if values.count > 1 { throw ScanIssue.failure(.malformedPresentField(.monthly)) }
                    if let first = values.first { monthly = TokenHubMonthlyObservation(amountText: first) }
                }
                return TokenHubQuotaPass(rootIdentity: selected, quotaGroupCount: quotaGroups,
                    fiveHourMarkerSeen: fiveMarkers > 0 || fiveProgressMarkers > 0, fiveHour: five,
                    sevenDayMarkerSeen: sevenMarkers > 0 || sevenProgressMarkers > 0, sevenDay: seven,
                    monthlyContainerCount: monthlyGroups.count, monthly: monthly)
            }
            let first = try readPass()
            let second = try readPass()
            visits += 1
            if visits > 512 { throw ScanIssue.failure(.nodeBudgetExceeded) }
            events.append(.identity(root))
            let after = try message(root, event: .identity(root)) { try reader.identity(of: root, timeout: 0.15) }
            guard after == selected else { throw ScanIssue.failure(.identityChanged) }
            let observation = TokenHubQuotaObservation(permissionTrusted: true, targets: targets, before: before,
                after: after, first: first, second: second,
                traversal: TokenHubTraversalSummary(nodeVisits: visits, maximumDepth: maxDepth,
                    maximumChildrenForAnyNode: maxChildren, longestStringCharacters: longest,
                    textCharacters: textCount, elapsed: elapsed(), slowestElementMessage: slowest),
                accessTrace: events)
            return TokenHubQuotaParser.parse(observation, now: now, refreshSeconds: refreshSeconds)
        } catch let issue as ScanIssue {
            return failure(issue.failure, status: status(for: issue.failure))
        } catch {
            return failure(.axError)
        }
    }
}

private struct ScanIssue: Error { let failure: TokenHubQuotaFailure; static func failure(_ f: TokenHubQuotaFailure) -> Self { Self(failure: f) } }
private func status(for failure: TokenHubQuotaFailure) -> TokenHubQuotaStatus {
    switch failure {
    case .permissionMissing: .permissionRequired
    case .noTarget: .targetNotRunning
    case .multipleTargets: .ambiguousTarget
    case .quotaGroupMissing, .noQuotaFields: .quotaGroupUnavailable
    case .malformedPresentField, .duplicateQuotaGroup, .duplicateWindow, .duplicateMonthlyContainer, .doubleReadMismatch: .unsupportedLayout
    default: .accessFailed
    }
}
