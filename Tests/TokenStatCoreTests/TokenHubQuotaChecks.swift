import Foundation
import TokenStatCore

// W1 synthetic-only C13 checks. These compile against the frozen BP08 interface after
// delivery adds the public fixture initializers recorded in this file; no AX permission or
// native reader is used by parser cases.
extension CoreChecks {
    static let hubIdentity = TokenHubIdentity(pid: 421, bundleID: TokenHubTarget.bundleID,
                                               executablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture")

    static func hubWindow(_ kind: TokenHubWindowKind = .fiveHour,
                          titleSeen: Bool = true,
                          percentText: String? = "已使用 37.5%",
                          amount: String? = "$3.75 / $10.00",
                          progressLabel: String? = nil,
                          includeExpectedProgressLabel: Bool = true,
                          progress: Decimal? = Decimal(string: "37.5"),
                          resetSeen: Bool = true,
                          reset: String? = "02-29 23:59") -> TokenHubWindowObservation {
        TokenHubWindowObservation(titleSeen: titleSeen,
            usedPercentText: percentText,
            amountText: amount,
            progressLabel: progressLabel ?? (includeExpectedProgressLabel
                ? (kind == .fiveHour ? "5 小时限额已用比例" : "7 天限额已用比例") : nil),
            progressValue: progress,
            resetLabelSeen: resetSeen,
            resetText: reset)
    }

    static func hubPass(five: TokenHubWindowObservation? = nil,
                        fiveMarker: Bool = false,
                        seven: TokenHubWindowObservation? = nil,
                        sevenMarker: Bool = false,
                        monthlyCount: Int = 0,
                        monthly: TokenHubMonthlyObservation? = nil,
                        groupCount: Int = 1,
                        identity: TokenHubIdentity = hubIdentity) -> TokenHubQuotaPass {
        TokenHubQuotaPass(rootIdentity: identity, quotaGroupCount: groupCount,
            fiveHourMarkerSeen: fiveMarker, fiveHour: five,
            sevenDayMarkerSeen: sevenMarker, sevenDay: seven,
            monthlyContainerCount: monthlyCount, monthly: monthly)
    }

    static func hubSummary(visits: Int = 150, depth: Int = 8, children: Int = 12,
                           longest: Int = 100, text: Int = 600, elapsed: TimeInterval = 0.2,
                           slowest: TimeInterval = 0.01) -> TokenHubTraversalSummary {
        TokenHubTraversalSummary(nodeVisits: visits, maximumDepth: depth,
            maximumChildrenForAnyNode: children, longestStringCharacters: longest,
            textCharacters: text, elapsed: elapsed, slowestElementMessage: slowest)
    }

    static func hubObservation(first: TokenHubQuotaPass? = nil,
                               second: TokenHubQuotaPass? = nil,
                               summary: TokenHubTraversalSummary = hubSummary(),
                               trusted: Bool = true,
                               targets: [TokenHubIdentity] = [hubIdentity],
                               before: TokenHubIdentity? = hubIdentity,
                               after: TokenHubIdentity? = hubIdentity,
                               trace: [TokenHubReadEvent] = []) -> TokenHubQuotaObservation {
        TokenHubQuotaObservation(permissionTrusted: trusted, targets: targets,
            before: before, after: after,
            first: first ?? hubPass(five: hubWindow(), fiveMarker: true),
            second: second ?? hubPass(five: hubWindow(), fiveMarker: true),
            traversal: summary, accessTrace: trace)
    }

    static func hubParse(_ observation: TokenHubQuotaObservation,
                         now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> TokenHubQuotaResult {
        TokenHubQuotaParser.parse(observation, now: now, refreshSeconds: 60)
    }

    static func hubChecks() throws {
        let valid = hubParse(hubObservation())
        check(valid.status == .connected && valid.snapshot != nil, "synthetic valid Hub snapshot accepted")
        check(valid.snapshot?.fiveHour?.usedAmount == Decimal(string: "3.75") &&
              valid.snapshot?.fiveHour?.limitAmount == Decimal(10), "amounts parsed as Decimal")
        check(valid.snapshot?.fiveHour?.sourceSymbol == "$" &&
              valid.snapshot?.fiveHour?.usedPercent == Decimal(string: "37.5") &&
              valid.snapshot?.fiveHour?.remainingPercent == Decimal(string: "62.5"),
              "currency symbol retained and validated progress derives interface remaining")
        check(valid.snapshot?.fiveHour?.resetDisplay == "02-29 23:59",
              "leap-day reset text preserved without year inference")

        let seven = hubWindow(.sevenDay, percentText: "已使用 37.5%", amount: "$3.75 / $10.00")
        let both = hubParse(hubObservation(first: hubPass(five: hubWindow(), fiveMarker: true,
                                                           seven: seven, sevenMarker: true),
                                          second: hubPass(five: hubWindow(), fiveMarker: true,
                                                           seven: seven, sevenMarker: true)))
        check(both.status == .connected && both.snapshot?.fiveHour != nil && both.snapshot?.sevenDay != nil,
              "5h and 7d are independently represented in one atomic snapshot")

        let monthOnly = TokenHubMonthlyObservation(amountText: "$4.25")
        let monthly = hubParse(hubObservation(first: hubPass(monthlyCount: 1, monthly: monthOnly),
                                              second: hubPass(monthlyCount: 1, monthly: monthOnly)))
        check(monthly.status == .connected && monthly.snapshot?.monthly?.usedAmount == Decimal(string: "4.25"),
              "monthly used amount accepted")
        check(monthly.snapshot?.monthly != nil, "monthly model contains only used amount; no fabricated limit")

        let missingSeven = hubParse(hubObservation(first: hubPass(five: hubWindow(), fiveMarker: true),
                                                   second: hubPass(five: hubWindow(), fiveMarker: true)))
        check(missingSeven.status == .connected && missingSeven.snapshot?.sevenDay == nil,
              "wholly absent 7d group accepted as unknown")
        let brokenPartner = hubPass(five: hubWindow(amount: nil), fiveMarker: true)
        let malformed = hubParse(hubObservation(first: brokenPartner, second: brokenPartner))
        check(malformed.snapshot == nil && malformed.failure == .malformedPresentField(.fiveHour),
              "present 5h marker with missing amount rejects whole refresh")
        let validSeven = hubWindow(.sevenDay)
        let progressOnlyFive = hubPass(fiveMarker: true, seven: validSeven, sevenMarker: true)
        let progressOnlyResult = hubParse(hubObservation(first: progressOnlyFive, second: progressOnlyFive))
        check(progressOnlyResult.snapshot == nil &&
              progressOnlyResult.failure == .malformedPresentField(.fiveHour),
              "5h progress-only marker with valid 7d sibling rejects whole snapshot")
        let missingFiveReset = hubPass(five: hubWindow(reset: nil), fiveMarker: true,
                                       seven: validSeven, sevenMarker: true)
        let missingFiveResetResult = hubParse(hubObservation(first: missingFiveReset,
                                                              second: missingFiveReset))
        check(missingFiveResetResult.snapshot == nil &&
              missingFiveResetResult.failure == .malformedPresentField(.fiveHour),
              "missing 5h reset cannot borrow valid 7d reset")
        let brokenMonthly = hubParse(hubObservation(first: hubPass(monthlyCount: 1),
                                                    second: hubPass(monthlyCount: 1)))
        check(brokenMonthly.snapshot == nil && brokenMonthly.failure == .malformedPresentField(.monthly),
              "present monthly container without amount rejects whole refresh")
        let partialPartnerCases = [
            hubWindow(titleSeen: false), hubWindow(percentText: nil),
            hubWindow(includeExpectedProgressLabel: false), hubWindow(progress: nil),
            hubWindow(resetSeen: false), hubWindow(reset: nil), hubWindow(amount: nil)
        ]
        for partial in partialPartnerCases {
            let pass = hubPass(five: partial, fiveMarker: true)
            check(hubParse(hubObservation(first: pass, second: pass)).snapshot == nil,
                  "each missing required 5h partner rejects a marked-present window")
        }
        let malformedWithValidSibling = hubPass(five: hubWindow(amount: "$NaN / $10"), fiveMarker: true,
                                                seven: seven, sevenMarker: true)
        let siblingRejected = hubParse(hubObservation(first: malformedWithValidSibling,
                                                      second: malformedWithValidSibling))
        check(siblingRejected.snapshot == nil,
              "malformed 5h rejects entire refresh despite valid 7d sibling")
        let duplicateGroupPass = hubPass(five: hubWindow(), fiveMarker: true, groupCount: 2)
        check(hubParse(hubObservation(first: duplicateGroupPass, second: duplicateGroupPass)).snapshot == nil,
              "duplicate quota container rejects whole read")
        let duplicateMonthPass = hubPass(five: hubWindow(), fiveMarker: true,
                                         monthlyCount: 2, monthly: monthOnly)
        check(hubParse(hubObservation(first: duplicateMonthPass, second: duplicateMonthPass)).snapshot == nil,
              "duplicate monthly container rejects whole read")
        let noFieldsPass = hubPass()
        let noFields = hubParse(hubObservation(first: noFieldsPass, second: noFieldsPass))
        check(noFields.snapshot == nil && noFields.failure == .noQuotaFields,
              "all wholly absent quota fields report unavailable")

        let invalidWindows: [(TokenHubWindowObservation, String)] = [
            (hubWindow(amount: "$-1 / $10"), "negative amount"),
            (hubWindow(amount: "$1.001 / $10"), "too many decimal places"),
            (hubWindow(amount: "$1,00 / $10"), "invalid grouping"),
            (hubWindow(amount: "¥1.00 / $10.00"), "unsupported or mixed currency symbol"),
            (hubWindow(amount: "$1e999 / $10"), "exponent amount format"),
            (hubWindow(amount: "$1 / $0"), "zero limit"),
            (hubWindow(amount: "$11 / $10"), "used above limit"),
            (hubWindow(percentText: "已使用 101%"), "text percentage out of range"),
            (hubWindow(progress: Decimal(1000)), "progress out of range"),
            (hubWindow(percentText: "已使用 40%", progress: Decimal(37)), "text and progress disagree"),
            (hubWindow(reset: "02-30 23:59"), "invalid reset date"),
            (hubWindow(reset: "2026-02-29T23:59Z"), "reset is not source short text"),
            (hubWindow(progressLabel: "wrong label"), "unexpected progress label")
        ]
        for (window, label) in invalidWindows {
            let pass = hubPass(five: window, fiveMarker: true)
            let result = hubParse(hubObservation(first: pass, second: pass))
            check(result.snapshot == nil && result.failure == .malformedPresentField(.fiveHour),
                  "malformed present field rejects entire snapshot: \(label)")
        }

        let maxAmount = hubWindow(amount: "$999,999,999,999,999.99 / $1,000,000,000,000,000.00")
        let maxPass = hubPass(five: maxAmount, fiveMarker: true)
        check(hubParse(hubObservation(first: maxPass, second: maxPass)).status == .connected,
              "maximum supported Decimal amount and valid grouping accepted")
        let overMax = hubWindow(amount: "$1,000,000,000,000,000.01 / $1,000,000,000,000,000.02")
        let overPass = hubPass(five: overMax, fiveMarker: true)
        check(hubParse(hubObservation(first: overPass, second: overPass)).snapshot == nil,
              "amount beyond maximum rejected")

        let changed = hubPass(five: hubWindow(percentText: "已使用 38%", progress: Decimal(38)), fiveMarker: true)
        let mismatch = hubParse(hubObservation(first: hubPass(five: hubWindow(), fiveMarker: true), second: changed))
        check(mismatch.snapshot == nil && mismatch.failure == .doubleReadMismatch,
              "two complete passes must normalize identically")

        let firstEquivalent = hubPass(five: hubWindow(percentText: "已使用 37.5%",
            amount: "$1.00 / $10.00", progress: Decimal(string: "37.5")), fiveMarker: true)
        let secondEquivalent = hubPass(five: hubWindow(percentText: "已使用 37.50%",
            amount: "$1 / $10", progress: Decimal(string: "37.50")), fiveMarker: true)
        let normalizedEqual = hubParse(hubObservation(first: firstEquivalent, second: secondEquivalent))
        check(normalizedEqual.status == .connected &&
              normalizedEqual.snapshot?.fiveHour?.usedAmount == Decimal(1) &&
              normalizedEqual.snapshot?.fiveHour?.limitAmount == Decimal(10) &&
              normalizedEqual.snapshot?.fiveHour?.usedPercent == Decimal(string: "37.5"),
              "two valid passes with equivalent Decimal values and presentation precision normalize equally")

        let actuallyChanged = hubPass(five: hubWindow(percentText: "已使用 37.5%",
            amount: "$1.01 / $10.00", progress: Decimal(string: "37.5")), fiveMarker: true)
        let changedAmount = hubParse(hubObservation(first: firstEquivalent, second: actuallyChanged))
        check(changedAmount.snapshot == nil && changedAmount.failure == .doubleReadMismatch,
              "two valid passes with a materially changed amount are rejected")
        let invalidSecond = hubPass(five: hubWindow(percentText: "已使用 37.5%",
            amount: "$1.000 / $10.00", progress: Decimal(string: "37.5")), fiveMarker: true)
        let invalidNormalized = hubParse(hubObservation(first: firstEquivalent, second: invalidSecond))
        check(invalidNormalized.snapshot == nil,
              "an invalid second pass cannot normalize equal to a valid first pass")

        let wrong = TokenHubIdentity(pid: 422, bundleID: TokenHubTarget.bundleID,
                                     executablePath: hubIdentity.executablePath)
        let wrongPass = hubPass(five: hubWindow(), fiveMarker: true, identity: wrong)
        let identityResult = hubParse(hubObservation(first: wrongPass, second: wrongPass))
        check(identityResult.snapshot == nil, "root identity mismatch rejects snapshot")
        let revoked = hubParse(hubObservation(trusted: false))
        check(revoked.snapshot == nil && revoked.failure == .permissionMissing,
              "pure observation with denied trust has no snapshot")
        let multiple = hubParse(hubObservation(targets: [hubIdentity, wrong]))
        check(multiple.snapshot == nil && multiple.failure == .multipleTargets,
              "multiple matching process candidates fail closed")
        let otherBundle = TokenHubIdentity(pid: 421, bundleID: "untrusted.fixture.app",
                                           executablePath: hubIdentity.executablePath)
        let noTarget = hubParse(hubObservation(targets: [otherBundle]))
        check(noTarget.snapshot == nil && noTarget.failure == .noTarget,
              "wrong bundle is not treated as an eligible target")
        let otherPath = TokenHubIdentity(pid: 421, bundleID: TokenHubTarget.bundleID,
                                         executablePath: "/tmp/replaced/Hub")
        let replacedPath = hubParse(hubObservation(after: otherPath))
        check(replacedPath.snapshot == nil && replacedPath.failure == .identityChanged,
              "normalized executable path change invalidates read")
        let edgeTolerance = hubWindow(percentText: "已使用 37.6%", progress: Decimal(string: "37.5"))
        let edgePass = hubPass(five: edgeTolerance, fiveMarker: true)
        check(hubParse(hubObservation(first: edgePass, second: edgePass)).status == .connected,
              "text/progress percentage difference exactly 0.1 is accepted")
        let beyondTolerance = hubWindow(percentText: "已使用 37.7%", progress: Decimal(string: "37.5"))
        let beyondPass = hubPass(five: beyondTolerance, fiveMarker: true)
        check(hubParse(hubObservation(first: beyondPass, second: beyondPass)).snapshot == nil,
              "text/progress percentage difference above 0.1 is rejected")

        let exactBounds: [(TokenHubTraversalSummary, String)] = [
            (hubSummary(visits: 512), "512 cumulative visits"),
            (hubSummary(depth: 16), "depth 16"),
            (hubSummary(children: 64), "64 children"),
            (hubSummary(longest: 256), "256 character string"),
            (hubSummary(text: 8192), "8192 aggregate characters"),
            (hubSummary(elapsed: 3.0), "3 seconds total"),
            (hubSummary(slowest: 0.15), "0.15 seconds element message")
        ]
        for (summary, label) in exactBounds {
            check(hubParse(hubObservation(summary: summary)).status == .connected,
                  "exact R15 budget boundary accepted: \(label)")
        }
        let exceededBounds: [(TokenHubTraversalSummary, String, TokenHubQuotaFailure)] = [
            (hubSummary(visits: 513), "513 cumulative visits", .nodeBudgetExceeded),
            (hubSummary(depth: 17), "depth 17", .depthBudgetExceeded),
            (hubSummary(children: 65), "65 children", .childBudgetExceeded),
            (hubSummary(longest: 257), "257 character string", .textBudgetExceeded),
            (hubSummary(text: 8193), "8193 aggregate characters", .textBudgetExceeded),
            (hubSummary(elapsed: 3.001), "over 3 seconds total", .timeBudgetExceeded),
            (hubSummary(slowest: 0.151), "over 0.15 seconds element message", .elementTimeout)
        ]
        for (summary, label, failure) in exceededBounds {
            let result = hubParse(hubObservation(summary: summary))
            check(result.snapshot == nil && result.failure == failure,
                  "over-budget input fails entire refresh: \(label)")
        }

        let forbiddenTrace: [TokenHubReadEvent] = [
            .targets, .root, .identity(1), .role(1), .groupDescription(2), .groupTitle(2),
            .children(2), .staticText(3), .progressLabel(4), .progressValue(4)
        ]
        let allowedTrace = hubParse(hubObservation(trace: forbiddenTrace))
        check(allowedTrace.status == .connected, "synthetic allowlisted read trace accepted")
        // The event enum intentionally has no arbitrary-attribute, window-title, URL,
        // input/secure-value, action, or global traversal case; compiler-enforced surface.
    }
}

// Recording synthetic tree used by scanner-path checks. Node ids and values are invented;
// the reader cannot access ApplicationServices or the desktop session.
private struct HubFixtureNode {
    var role: TokenHubAXRole
    var identity: TokenHubIdentity
    var label: String?
    var children: [Int] = []
    var text: String?
    var progressLabel: String?
    var progress: Decimal?
    var truncated = false
    var failsChildren = false
}

private final class HubRecordingReader: TokenHubBoundedTreeReading {
    var nodes: [Int: HubFixtureNode]
    var events: [TokenHubReadEvent] = []
    var valueReadsBeforeQuotaGroup = false
    var quotaGroupWasIdentified = false
    var messageDuration: TimeInterval = 0
    private(set) var readTextCharacterCount = 0
    private var paddingPass = 0
    private var paddingValues: [Int: (String, String)] = [:]
    let selected = CoreChecks.hubIdentity
    let targetList: [TokenHubIdentity]

    init(nodes: [Int: HubFixtureNode], targets: [TokenHubIdentity]? = nil) {
        self.nodes = nodes
        targetList = targets ?? [CoreChecks.hubIdentity]
    }
    private func enforce(_ timeout: TimeInterval) throws {
        if messageDuration > timeout { throw NSError(domain: "HubFixtureTimeout", code: 124) }
    }
    func exactBundleTargets(bundleID: String) throws -> [TokenHubIdentity] {
        events.append(.targets)
        return targetList.filter { $0.bundleID == bundleID }
    }
    func rootNode(for identity: TokenHubIdentity, timeout: TimeInterval) throws -> Int {
        try enforce(timeout)
        events.append(.root); return 1
    }
    func identity(of node: Int, timeout: TimeInterval) throws -> TokenHubIdentity {
        try enforce(timeout)
        events.append(.identity(node)); return nodes[node]?.identity ?? selected
    }
    func role(of node: Int, timeout: TimeInterval) throws -> TokenHubAXRole {
        try enforce(timeout)
        events.append(.role(node)); return nodes[node]?.role ?? .other("missing")
    }
    func groupLabel(of node: Int, kind: TokenHubGroupLabelKind, timeout: TimeInterval) throws -> String? {
        try enforce(timeout)
        events.append(kind == .description ? .groupDescription(node) : .groupTitle(node))
        let value = nodes[node]?.label
        readTextCharacterCount += value?.count ?? 0
        if value == "用量和限额" { quotaGroupWasIdentified = true }
        return value
    }
    func children(of node: Int, maximum: Int, timeout: TimeInterval) throws -> TokenHubChildrenPage {
        try enforce(timeout)
        events.append(.children(node))
        guard let value = nodes[node] else { throw NSError(domain: "HubFixture", code: 1) }
        if value.failsChildren { throw NSError(domain: "HubFixture", code: 2) }
        return TokenHubChildrenPage(nodes: Array(value.children.prefix(maximum)),
                                    isTruncated: value.truncated || value.children.count > maximum)
    }
    func staticText(of node: Int, maximumCharacters: Int, timeout: TimeInterval) throws -> String? {
        try enforce(timeout)
        events.append(.staticText(node))
        if !quotaGroupWasIdentified { valueReadsBeforeQuotaGroup = true }
        if node == 3 { paddingPass += 1 }
        let value: String?
        if let pair = paddingValues[node] { value = paddingPass <= 1 ? pair.0 : pair.1 }
        else { value = nodes[node]?.text }
        readTextCharacterCount += value?.count ?? 0
        return value
    }
    func progressLabel(of node: Int, timeout: TimeInterval) throws -> String? {
        try enforce(timeout)
        events.append(.progressLabel(node)); let value = nodes[node]?.progressLabel
        readTextCharacterCount += value?.count ?? 0; return value
    }
    func progressValue(of node: Int, timeout: TimeInterval) throws -> Decimal? {
        try enforce(timeout)
        events.append(.progressValue(node)); return nodes[node]?.progress
    }

    static func valid() -> HubRecordingReader {
        let id = CoreChecks.hubIdentity
        var tree: [Int: HubFixtureNode] = [:]
        tree[1] = HubFixtureNode(role: .application, identity: id, children: [20, 90, 91])
        tree[20] = HubFixtureNode(role: .other("AXScrollArea"), identity: id, children: [21])
        tree[21] = HubFixtureNode(role: .other("AXWebArea"), identity: id, children: [2])
        tree[2] = HubFixtureNode(role: .group, identity: id, label: "用量和限额",
                                 children: [3, 4, 5, 6, 7, 8, 9, 10])
        tree[3] = HubFixtureNode(role: .staticText, identity: id, text: "5 小时限额 已使用 37.5%")
        tree[4] = HubFixtureNode(role: .staticText, identity: id, text: "$3.75 / $10.00")
        tree[5] = HubFixtureNode(role: .staticText, identity: id, text: "额度")
        tree[6] = HubFixtureNode(role: .progressIndicator, identity: id,
                                 progressLabel: "5 小时限额已用比例", progress: Decimal(string: "37.5"))
        tree[7] = HubFixtureNode(role: .staticText, identity: id, text: "重置")
        tree[8] = HubFixtureNode(role: .staticText, identity: id, text: "02-29 23:59")
        tree[9] = HubFixtureNode(role: .staticText, identity: id, text: "时间")
        tree[10] = HubFixtureNode(role: .progressIndicator, identity: id,
                                 progressLabel: "重置进度", progress: Decimal(99))
        tree[90] = HubFixtureNode(role: .staticText, identity: id, text: "outside quota poison")
        tree[91] = HubFixtureNode(role: .button, identity: id, children: [92])
        tree[92] = HubFixtureNode(role: .secureText, identity: id, text: "must-never-be-read")
        return HubRecordingReader(nodes: tree)
    }

    func addUnrelatedGroups(_ childCounts: [Int]) {
        var root = nodes[1]!
        var nextID = 1_000
        for count in childCounts {
            let groupID = nextID; nextID += 1
            var children: [Int] = []
            for _ in 0..<count {
                let childID = nextID; nextID += 1; children.append(childID)
                nodes[childID] = HubFixtureNode(role: .button, identity: selected)
            }
            nodes[groupID] = HubFixtureNode(role: .group, identity: selected, children: children)
            root.children.append(groupID)
        }
        nodes[1] = root
    }

    func addGroupChain(toDepth targetDepth: Int) {
        var root = nodes[1]!
        let firstID = 3_000
        root.children.append(firstID)
        nodes[1] = root
        var current = firstID
        for depth in 1...targetDepth {
            let child = depth == targetDepth ? nil : current + 1
            nodes[current] = HubFixtureNode(role: .group, identity: selected,
                children: child.map { [$0] } ?? [])
            if let child { current = child }
        }
    }

    func addLabelGroup(length: Int) {
        var root = nodes[1]!
        let groupID = 4_000
        root.children.append(groupID)
        nodes[1] = root
        nodes[groupID] = HubFixtureNode(role: .group, identity: selected,
            label: String(repeating: "x", count: length))
    }

    func addQuotaPadding(firstPassCharacters: Int, secondPassCharacters: Int) {
        var group = nodes[2]!
        var nextID = 6_000
        func chunks(_ count: Int) -> [String] {
            var remainder = count, result: [String] = []
            while remainder > 0 {
                let size = min(256, remainder)
                result.append(String(repeating: " ", count: size)); remainder -= size
            }
            return result
        }
        let first = chunks(firstPassCharacters), second = chunks(secondPassCharacters)
        for index in 0..<max(first.count, second.count) {
            let id = nextID; nextID += 1; group.children.append(id)
            nodes[id] = HubFixtureNode(role: .staticText, identity: selected)
            paddingValues[id] = (index < first.count ? first[index] : "",
                                 index < second.count ? second[index] : "")
        }
        nodes[2] = group
    }

    func addMonthlyGroup(amounts: [String]) {
        var quotaGroup = nodes[2]!
        let groupID = 7_000
        var children: [Int] = []
        for (index, amount) in amounts.enumerated() {
            let nodeID = 7_001 + index; children.append(nodeID)
            nodes[nodeID] = HubFixtureNode(role: .staticText, identity: selected, text: amount)
        }
        nodes[groupID] = HubFixtureNode(role: .group, identity: selected,
            label: "月度用量", children: children)
        quotaGroup.children.append(groupID); nodes[2] = quotaGroup
    }

    func addSevenDayWindow(reset: String? = "03-01 01:00") {
        var quotaGroup = nodes[2]!
        let values: [(Int, HubFixtureNode)] = [
            (110, HubFixtureNode(role: .staticText, identity: selected, text: "7 天限额 已使用 40%")),
            (111, HubFixtureNode(role: .staticText, identity: selected, text: "$4.00 / $10.00")),
            (112, HubFixtureNode(role: .staticText, identity: selected, text: "额度")),
            (113, HubFixtureNode(role: .progressIndicator, identity: selected,
                progressLabel: "7 天限额已用比例", progress: Decimal(40))),
            (114, HubFixtureNode(role: .staticText, identity: selected, text: "重置")),
            (115, HubFixtureNode(role: .staticText, identity: selected, text: reset)),
            (116, HubFixtureNode(role: .staticText, identity: selected, text: "时间"))
        ]
        for (id, node) in values { nodes[id] = node; quotaGroup.children.append(id) }
        nodes[2] = quotaGroup
    }
}

extension CoreChecks {
    static func hubScannerChecks() throws {
        let reader = HubRecordingReader.valid()
        let result = TokenHubQuotaScanner().scan(using: reader, now: Date(timeIntervalSince1970: 1_800_000_000),
            monotonicNow: { 10 }, permissionTrusted: true, refreshSeconds: 60,
            mode: .localCodex, generation: 1)
        check(result.status == .connected && result.snapshot != nil, "bounded synthetic tree scan succeeds")
        check(!reader.valueReadsBeforeQuotaGroup, "scanner does not read leaf content before unique container discovery")
        check(!reader.events.contains(.staticText(90)), "scanner never reads unrelated text outside quota group")
        check(!reader.events.contains(.staticText(92)), "scanner never descends into button/secure-field subtree")
        check(!reader.events.contains(.progressValue(10)), "reset-progress value is never treated as quota")
        check(reader.events.contains(.children(20)) && reader.events.contains(.children(21)),
              "scanner safely traverses AXScrollArea and AXWebArea ancestors")
        check(reader.events.filter { if case .staticText = $0 { return true }; return false }.count == 12,
              "two passes read six supported static-text fields, including the decorative quota label")
        check(reader.events.filter { if case .progressValue = $0 { return true }; return false }.count == 2,
              "two passes read the approved progress value only")
        let deniedReader = HubRecordingReader.valid()
        let denied = TokenHubQuotaScanner().scan(using: deniedReader, now: Date(timeIntervalSince1970: 1_800_000_000),
            monotonicNow: { 10 }, permissionTrusted: false, refreshSeconds: 60,
            mode: .localCodex, generation: 2)
        check(denied.snapshot == nil && denied.failure == .permissionMissing,
              "scanner accepts injected trust boolean without requesting OS permission")
        check(deniedReader.events.isEmpty, "denied trust performs no target/tree operations")
        let proxyReader = HubRecordingReader.valid()
        let proxy = TokenHubQuotaScanner().scan(using: proxyReader, now: Date(timeIntervalSince1970: 1_800_000_000),
            monotonicNow: { 10 }, permissionTrusted: true, refreshSeconds: 60,
            mode: .proxy, generation: 3)
        check(proxy.snapshot == nil, "proxy mode never selects the AX source")
        check(proxyReader.events.isEmpty, "proxy mode performs no AX target/tree operations")

        let wrongBundle = TokenHubIdentity(pid: 421, bundleID: "other.fixture.bundle",
                                           executablePath: CoreChecks.hubIdentity.executablePath)
        let noTargetReader = HubRecordingReader(nodes: HubRecordingReader.valid().nodes, targets: [wrongBundle])
        let noTarget = TokenHubQuotaScanner().scan(using: noTargetReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 4)
        check(noTarget.failure == .noTarget && noTargetReader.events == [.targets],
              "wrong-bundle target fails before reading an AX root")

        let changedReader = HubRecordingReader.valid()
        var wrongNode = changedReader.nodes[4]!
        wrongNode.identity = TokenHubIdentity(pid: 999, bundleID: CoreChecks.hubIdentity.bundleID,
                                               executablePath: CoreChecks.hubIdentity.executablePath)
        changedReader.nodes[4] = wrongNode
        let changedResult = TokenHubQuotaScanner().scan(using: changedReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 5)
        check(changedResult.failure == .elementPIDMismatch && changedResult.snapshot == nil,
              "every visited node is checked against selected PID")

        let truncatedReader = HubRecordingReader.valid()
        var truncatedRoot = truncatedReader.nodes[1]!; truncatedRoot.truncated = true
        truncatedReader.nodes[1] = truncatedRoot
        check(TokenHubQuotaScanner().scan(using: truncatedReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 6).snapshot == nil,
            "truncated children page rejects whole refresh")

        let errorReader = HubRecordingReader.valid()
        var errorRoot = errorReader.nodes[1]!; errorRoot.failsChildren = true
        errorReader.nodes[1] = errorRoot
        check(TokenHubQuotaScanner().scan(using: errorReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 7).snapshot == nil,
            "children API error rejects whole refresh")
        let timeoutReader = HubRecordingReader.valid(); timeoutReader.messageDuration = 0.151
        let timeoutResult = TokenHubQuotaScanner().scan(using: timeoutReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8)
        check(timeoutResult.snapshot == nil, "element message exceeding 0.15s fails closed")
        let exactMessageReader = HubRecordingReader.valid(); exactMessageReader.messageDuration = 0.15
        check(TokenHubQuotaScanner().scan(using: exactMessageReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8).status == .connected,
            "scanner permits an element message exactly at 0.15 seconds")

        let exactChildrenReader = HubRecordingReader.valid()
        var rootAtChildLimit = exactChildrenReader.nodes[1]!
        rootAtChildLimit.children = [2]
        for id in 5_000..<5_063 {
            rootAtChildLimit.children.append(id)
            exactChildrenReader.nodes[id] = HubFixtureNode(role: .group,
                identity: CoreChecks.hubIdentity)
        }
        exactChildrenReader.nodes[1] = rootAtChildLimit
        check(TokenHubQuotaScanner().scan(using: exactChildrenReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8).status == .connected,
            "scanner accepts exactly 64 children for one node")
        let overChildrenReader = HubRecordingReader.valid()
        var rootOverChildLimit = overChildrenReader.nodes[1]!
        for id in 5_000..<5_062 {
            rootOverChildLimit.children.append(id)
            overChildrenReader.nodes[id] = HubFixtureNode(role: .group,
                identity: CoreChecks.hubIdentity)
        }
        overChildrenReader.nodes[1] = rootOverChildLimit
        let overChildren = TokenHubQuotaScanner().scan(using: overChildrenReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8)
        check(overChildren.snapshot == nil, "scanner fails closed when root has 65 children")

        let depth16Reader = HubRecordingReader.valid(); depth16Reader.addGroupChain(toDepth: 16)
        check(TokenHubQuotaScanner().scan(using: depth16Reader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8).status == .connected,
            "scanner accepts traversal reaching exact depth 16")
        let depth17Reader = HubRecordingReader.valid(); depth17Reader.addGroupChain(toDepth: 17)
        let depth17 = TokenHubQuotaScanner().scan(using: depth17Reader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8)
        check(depth17.snapshot == nil, "scanner rejects traversal beyond depth 16")

        let label256Reader = HubRecordingReader.valid(); label256Reader.addLabelGroup(length: 256)
        check(TokenHubQuotaScanner().scan(using: label256Reader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8).status == .connected,
            "scanner accepts a 256-character non-quota container label")
        let label257Reader = HubRecordingReader.valid(); label257Reader.addLabelGroup(length: 257)
        check(TokenHubQuotaScanner().scan(using: label257Reader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8).snapshot == nil,
            "scanner rejects a 257-character string")

        let charCalibrationReader = HubRecordingReader.valid()
        _ = TokenHubQuotaScanner().scan(using: charCalibrationReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8)
        let baseAggregateCharacters = charCalibrationReader.readTextCharacterCount
        let charsToAdd = 8192 - baseAggregateCharacters
        let exactTextReader = HubRecordingReader.valid()
        exactTextReader.addQuotaPadding(firstPassCharacters: charsToAdd / 2,
                                        secondPassCharacters: charsToAdd - charsToAdd / 2)
        let exactText = TokenHubQuotaScanner().scan(using: exactTextReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8)
        check(exactText.status == .connected && exactTextReader.readTextCharacterCount == 8192,
              "scanner accepts exactly 8192 aggregate characters across discovery and both reads")
        let overTextReader = HubRecordingReader.valid()
        overTextReader.addQuotaPadding(firstPassCharacters: charsToAdd / 2,
                                       secondPassCharacters: charsToAdd - charsToAdd / 2 + 1)
        let overText = TokenHubQuotaScanner().scan(using: overTextReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8)
        check(overText.snapshot == nil && overText.failure == .textBudgetExceeded &&
              overTextReader.readTextCharacterCount <= 8193,
              "scanner fails closed at the 8193rd aggregate character")

        let duplicateReader = HubRecordingReader.valid()
        var duplicateRoot = duplicateReader.nodes[1]!
        let duplicate = duplicateReader.nodes[2]!; duplicateReader.nodes[93] = duplicate
        duplicateRoot.children.append(93); duplicateReader.nodes[1] = duplicateRoot
        let duplicateResult = TokenHubQuotaScanner().scan(using: duplicateReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 8)
        check(duplicateResult.failure == .duplicateQuotaGroup && duplicateReader.events.filter {
            if case .staticText = $0 { return true }; if case .progressValue = $0 { return true }; return false
        }.isEmpty, "duplicate quota containers discovered before any leaf value read")

        let duplicateWindowReader = HubRecordingReader.valid()
        var duplicateWindowGroup = duplicateWindowReader.nodes[2]!
        duplicateWindowGroup.children.append(94)
        duplicateWindowReader.nodes[2] = duplicateWindowGroup
        duplicateWindowReader.nodes[94] = HubFixtureNode(role: .staticText,
            identity: CoreChecks.hubIdentity, text: "5 小时限额 已使用 37.5%")
        let duplicateWindow = TokenHubQuotaScanner().scan(using: duplicateWindowReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 9)
        check(duplicateWindow.failure == .duplicateWindow(.fiveHour) && duplicateWindow.snapshot == nil,
              "duplicate window marker rejects scanner result")

        let duplicateAmountReader = HubRecordingReader.valid()
        var amountGroup = duplicateAmountReader.nodes[2]!
        amountGroup.children.append(95)
        duplicateAmountReader.nodes[2] = amountGroup
        duplicateAmountReader.nodes[95] = HubFixtureNode(role: .staticText,
            identity: CoreChecks.hubIdentity, text: "$3.75 / $10.00")
        let duplicateAmount = TokenHubQuotaScanner().scan(using: duplicateAmountReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 9)
        check(duplicateAmount.snapshot == nil &&
              duplicateAmount.failure == .malformedPresentField(.fiveHour),
              "duplicate 5h amount rows reject whole scanner result")

        let bothWindowsReader = HubRecordingReader.valid(); bothWindowsReader.addSevenDayWindow()
        let bothWindows = TokenHubQuotaScanner().scan(using: bothWindowsReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 9)
        check(bothWindows.status == .connected && bothWindows.snapshot?.fiveHour != nil &&
              bothWindows.snapshot?.sevenDay != nil,
              "scanner accepts valid 5h and 7d sibling windows atomically")

        for brokenReset in [nil, "02-30 23:59"] {
            let resetReader = HubRecordingReader.valid()
            resetReader.addSevenDayWindow()
            var missingOrMalformed = resetReader.nodes[8]!
            missingOrMalformed.text = brokenReset
            resetReader.nodes[8] = missingOrMalformed
            let resetResult = TokenHubQuotaScanner().scan(using: resetReader,
                now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
                permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 9)
            check(resetResult.snapshot == nil &&
                  resetResult.failure == .malformedPresentField(.fiveHour),
                  "5h reset missing or malformed cannot borrow valid 7d reset")
        }

        let validMonthlyReader = HubRecordingReader.valid(); validMonthlyReader.addMonthlyGroup(amounts: ["$4.25"])
        let validMonthlyScan = TokenHubQuotaScanner().scan(using: validMonthlyReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 9)
        check(validMonthlyScan.status == .connected && validMonthlyScan.snapshot?.monthly?.usedAmount == Decimal(string: "4.25"),
              "scanner accepts monthly used-only amount in its unique container")
        let duplicateMonthlyReader = HubRecordingReader.valid()
        duplicateMonthlyReader.addMonthlyGroup(amounts: ["$4.25", "$7.00"])
        let duplicateMonthlyScan = TokenHubQuotaScanner().scan(using: duplicateMonthlyReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 9)
        check(duplicateMonthlyScan.snapshot == nil &&
              duplicateMonthlyScan.failure == .malformedPresentField(.monthly),
              "multiple monthly amount rows reject the entire scanner result")

        let replacedRootReader = HubRecordingReader.valid()
        var replacedRoot = replacedRootReader.nodes[1]!
        replacedRoot.identity = TokenHubIdentity(pid: 421, bundleID: CoreChecks.hubIdentity.bundleID,
            executablePath: "/Applications/Replaced.app/Contents/MacOS/Hub")
        replacedRootReader.nodes[1] = replacedRoot
        let replacedRootResult = TokenHubQuotaScanner().scan(using: replacedRootReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 9)
        check(replacedRootResult.failure == .identityChanged && replacedRootResult.snapshot == nil,
              "target replacement during scan rejects result")

        // Calibrate filler groups from the baseline trace, then exercise the *scanner's*
        // shared node-visit budget across discovery and both reads (including revisits).
        let baselineReader = HubRecordingReader.valid()
        _ = TokenHubQuotaScanner().scan(using: baselineReader,
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
            permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 9)
        let baselineVisits = baselineReader.events.reduce(0) { total, event in
            if case .identity = event { return total + 1 }; return total
        }
        func padding(for target: Int) -> [Int]? {
            let delta = target - baselineVisits
            guard delta >= 1 else { return nil }
            let groupCount = min(8, delta)
            let childCount = delta - groupCount
            guard childCount <= groupCount * 64 else { return nil }
            var remainder = childCount
            return (0..<groupCount).map { _ in
                let value = min(64, remainder); remainder -= value; return value
            }
        }
        if let exactPadding = padding(for: 512) {
            let exactReader = HubRecordingReader.valid(); exactReader.addUnrelatedGroups(exactPadding)
            let exactResult = TokenHubQuotaScanner().scan(using: exactReader,
                now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
                permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 10)
            check(exactResult.status == .connected, "scanner permits exactly 512 cumulative node visits")
        } else { check(false, "fixture can construct exact 512 cumulative visits") }
        if let overPadding = padding(for: 513) {
            let overReader = HubRecordingReader.valid(); overReader.addUnrelatedGroups(overPadding)
            let overResult = TokenHubQuotaScanner().scan(using: overReader,
                now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: { 10 },
                permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 11)
            check(overResult.failure == .nodeBudgetExceeded && overResult.snapshot == nil,
                  "scanner rejects the 513th cumulative visit")
        } else { check(false, "fixture can construct 513 cumulative visits") }

        var calibrationClockCalls = 0
        _ = TokenHubQuotaScanner().scan(using: HubRecordingReader.valid(),
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: {
                calibrationClockCalls += 1; return 10
            }, permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 12)
        let clockIntervals = max(1, calibrationClockCalls - 1)
        var exactClockCalls = 0
        let exactTime = TokenHubQuotaScanner().scan(using: HubRecordingReader.valid(),
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: {
                exactClockCalls += 1
                return 10 + 3 * Double(exactClockCalls - 1) / Double(clockIntervals)
            }, permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 12)
        check(exactTime.status == .connected, "scanner permits exactly 3 seconds shared elapsed time")

        var overClockCalls = 0
        let overTime = TokenHubQuotaScanner().scan(using: HubRecordingReader.valid(),
            now: Date(timeIntervalSince1970: 1_800_000_000), monotonicNow: {
                overClockCalls += 1
                return 10 + 3.001 * Double(overClockCalls - 1) / Double(clockIntervals)
            }, permissionTrusted: true, refreshSeconds: 60, mode: .localCodex, generation: 12)
        check(overTime.failure == .timeBudgetExceeded && overTime.snapshot == nil,
              "scanner uses injected monotonic clock and rejects over 3 seconds")
    }
}
