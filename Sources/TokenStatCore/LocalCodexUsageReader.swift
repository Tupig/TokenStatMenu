import Foundation
import CoreFoundation
import Darwin

public struct LocalCodexSnapshot: Equatable {
    public let input: Int
    public let output: Int
    public let total: Int
    public let sessionCount: Int
    public let filesScanned: Int
    public let isLimited: Bool
    public let latestEventAt: Date?
    public let fiveHour: WindowQuota?
    public let sevenDay: WindowQuota?
    public let lastTurn: LocalTurnSummary?
    public init(input: Int, output: Int, total: Int, sessionCount: Int, filesScanned: Int, isLimited: Bool, latestEventAt: Date?, fiveHour: WindowQuota?, sevenDay: WindowQuota?, lastTurn: LocalTurnSummary? = nil) {
        self.input = input; self.output = output; self.total = total; self.sessionCount = sessionCount
        self.filesScanned = filesScanned; self.isLimited = isLimited; self.latestEventAt = latestEventAt
        self.fiveHour = fiveHour; self.sevenDay = sevenDay
        self.lastTurn = lastTurn
    }
}

public struct LocalTurnSummary: Equatable {
    public let outputTokens: Int
    public let durationSeconds: Double
    public let completedAt: Date
    public var outputTPS: Double { Double(outputTokens) / durationSeconds }
    public init(outputTokens: Int, durationSeconds: Double, completedAt: Date) {
        self.outputTokens = outputTokens; self.durationSeconds = durationSeconds; self.completedAt = completedAt
    }
}

/// Completion-relative, generation-aware schedule for local usage scans.
public struct LocalRefreshScheduler {
    private(set) public var generation = 0
    private var inFlight: Int?
    private var nextDue = Date.distantPast
    public init() {}
    public mutating func begin(now: Date) -> Int? {
        guard inFlight == nil, now >= nextDue else { return nil }
        inFlight = generation
        return generation
    }
    @discardableResult public mutating func complete(generation token: Int, now: Date) -> Bool {
        guard inFlight == token, generation == token else { return false }
        inFlight = nil; nextDue = now.addingTimeInterval(5)
        return true
    }
    @discardableResult public mutating func invalidate() -> Int {
        generation += 1; inFlight = nil; nextDue = .distantPast
        return generation
    }
}

/// Reads only bounded numeric usage metadata from Codex session JSONL files.
public enum LocalCodexUsageReader {
    private static let maxEntries = 5_000
    private static let maxSessions = 32
    private static let tailLimit = 256 * 1024
    private static let byteLimit = 8 * 1024 * 1024
    private static let isoFormatter = ISO8601DateFormatter()
    private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let uuidPattern = try! NSRegularExpression(pattern: "([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\\.jsonl$")

    private struct Candidate { let name: String; let uuid: String; let modified: Date }
    fileprivate struct Record { let date: Date; let input: Int; let output: Int; let total: Int; let five: WindowQuota?; let seven: WindowQuota?; let isRate: Bool }

    fileprivate struct FileSignature: Hashable {
        let device: UInt64; let inode: UInt64; let size: Int64
        let mtimeSec: Int64; let mtimeNSec: Int64; let ctimeSec: Int64; let ctimeNSec: Int64
        init(_ st: stat) {
            device = UInt64(st.st_dev); inode = UInt64(st.st_ino); size = Int64(st.st_size)
            mtimeSec = Int64(st.st_mtimespec.tv_sec); mtimeNSec = Int64(st.st_mtimespec.tv_nsec)
            ctimeSec = Int64(st.st_ctimespec.tv_sec); ctimeNSec = Int64(st.st_ctimespec.tv_nsec)
        }
    }
    fileprivate struct ParsedEvent {
        let date: Date
        let type: String
        let turnID: String?
        let duration: Double?
        let totalTokens: Int?
        let outputTokens: Int?
        let hasCumulativePayload: Bool
        let usage: Record?
        let rate: Record?
    }
    fileprivate struct CachedFileSummary {
        let token: Record?
        let rate: Record?
        let turn: LocalTurnSummary?
        let latestEventAt: Date?
        let tailLimited: Bool
    }
    public final class Cache {
        public struct Diagnostics: Equatable {
            public fileprivate(set) var bytesRead = 0
            public fileprivate(set) var parsedFiles = 0
            public fileprivate(set) var cacheHits = 0
            public fileprivate(set) var safeOpens = 0
        }
        public private(set) var diagnostics = Diagnostics()
        public var entryCount: Int { entries.count }
        fileprivate var entries: [FileSignature: CachedFileSummary] = [:]
        fileprivate var rootIdentity: FileSignature?
        fileprivate var beforePostReadValidation: (() -> Void)?
        public init() {}
        /// Internal deterministic race seam; available only to @testable checks.
        init(beforePostReadValidation: @escaping () -> Void) { self.beforePostReadValidation = beforePostReadValidation }
        fileprivate func resetDiagnostics() { diagnostics = Diagnostics() }
        fileprivate func opened() { diagnostics.safeOpens += 1 }
        fileprivate func hit() { diagnostics.cacheHits += 1 }
        fileprivate func read(_ count: Int) { diagnostics.bytesRead += count }
        fileprivate func parsed() { diagnostics.parsedFiles += 1 }
    }

    public static func defaultSessionsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let configured = environment["CODEX_HOME"], configured.hasPrefix("/") {
            return URL(fileURLWithPath: configured).appendingPathComponent("sessions")
        }
        return home.appendingPathComponent(".codex").appendingPathComponent("sessions")
    }

    public static func scan(directory: URL, now: Date = Date()) throws -> LocalCodexSnapshot { try scan(directory: directory, now: now, cache: nil) }
    public static func scan(directory: URL, now: Date = Date(), cache: Cache?) throws -> LocalCodexSnapshot {
        cache?.resetDiagnostics()
        let empty = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0, filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil)
        var st = stat()
        guard lstat(directory.path, &st) == 0 else { cache?.entries.removeAll(); cache?.rootIdentity = nil; return empty }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { cache?.entries.removeAll(); cache?.rootIdentity = nil; return empty }
        let rootFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { cache?.entries.removeAll(); cache?.rootIdentity = nil; return empty }
        defer { close(rootFD) }
        var opened = stat()
        guard fstat(rootFD, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFDIR else { cache?.entries.removeAll(); cache?.rootIdentity = nil; return empty }
        let rootIdentity = FileSignature(opened)
        if cache?.rootIdentity != rootIdentity { cache?.entries.removeAll(); cache?.rootIdentity = rootIdentity }
        var candidates: [Candidate] = [], entries = 0, limited = false
        var directories = [""]
        while let relative = directories.first, entries < maxEntries {
            directories.removeFirst()
            let dfd = relative.isEmpty ? dup(rootFD) : openDirectoryRelative(rootFD, relative)
            guard dfd >= 0, let listing = fdopendir(dfd) else { if dfd >= 0 { close(dfd) }; continue }
            while entries < maxEntries, let item = readdir(listing) {
                let leaf = withUnsafePointer(to: &item.pointee.d_name) { ptr -> String in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                }
                if leaf == "." || leaf == ".." { continue }
                entries += 1
                let name = relative.isEmpty ? leaf : relative + "/" + leaf
                var fst = stat()
                guard fstatat(dfd, leaf, &fst, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                if (fst.st_mode & S_IFMT) == S_IFDIR { directories.append(name); continue }
                guard (fst.st_mode & S_IFMT) == S_IFREG else { continue }
                let ns = name as NSString, range = NSRange(location: 0, length: ns.length)
                guard let match = uuidPattern.firstMatch(in: name, range: range), let r = Range(match.range(at: 1), in: name) else { continue }
                candidates.append(Candidate(name: name, uuid: String(name[r]).lowercased(), modified: Date(timeIntervalSince1970: Double(fst.st_mtimespec.tv_sec))))
                if entries >= maxEntries { break }
            }
            closedir(listing)
        }
        if entries >= maxEntries { limited = true }
        var newestByUUID: [String: Candidate] = [:]
        for candidate in candidates where newestByUUID[candidate.uuid].map({ $0.modified < candidate.modified }) ?? true { newestByUUID[candidate.uuid] = candidate }
        candidates = Array(newestByUUID.values)
        candidates.sort { $0.modified == $1.modified ? $0.uuid < $1.uuid : $0.modified > $1.modified }
        if candidates.count > maxSessions { candidates = Array(candidates.prefix(maxSessions)); limited = true }
        var usedBytes = 0, filesScanned = 0, input = 0, output = 0, total = 0, sessionCount = 0
        var latestEvent: Date?, latestRate: Record?
        var latestTurn: LocalTurnSummary?
        var liveSignatures = Set<FileSignature>()
        for candidate in candidates {
            guard usedBytes < byteLimit else { limited = true; break }
            let fd = openRelative(rootFD, candidate.name)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            cache?.opened()
            var fst = stat()
            guard fstat(fd, &fst) == 0, (fst.st_mode & S_IFMT) == S_IFREG, fst.st_size >= 0 else { continue }
            let contained = isContained(fd: fd, rootFD: rootFD)
            guard contained else { continue }
            let signature = FileSignature(fst)
            liveSignatures.insert(signature)
            var summary = cache?.entries[signature]
            if summary != nil { cache?.hit() }
            else {
            let remaining = byteLimit - usedBytes
            let amount = min(Int(fst.st_size), tailLimit, remaining)
            if amount <= 0 { limited = true; continue }
            var data = Data(count: amount)
            let offset = max(0, fst.st_size - off_t(amount))
            let readCount = data.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return pread(fd, base, amount, offset)
            }
            guard readCount > 0 else { continue }
            data.count = readCount
            cache?.read(readCount)
            usedBytes += readCount
            if fst.st_size > off_t(amount) { limited = true }
            var lines = data.split(separator: 10, omittingEmptySubsequences: false)
            if offset > 0, !data.isEmpty { lines.removeFirst() }
            if data.last != 10 { lines.removeLast() }
            var parsed: [ParsedEvent] = []
            var hasInvalidLifecycleTimestamp = false
            for line in lines where !line.isEmpty {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)), let root = object as? [String: Any],
                      root["type"] as? String == "event_msg", let payload = root["payload"] as? [String: Any] else { continue }
                let payloadType = payload["type"] as? String
                guard let date = parseDate(root["timestamp"]) else {
                    if ["task_started", "task_complete", "turn_aborted", "token_count"].contains(payloadType ?? "") {
                        hasInvalidLifecycleTimestamp = true
                    }
                    continue
                }
                var tokenRecord: Record?, rateRecord: Record?, cumulativeTotal: Int?, cumulativeOutput: Int?
                let usageInfo = payload["info"] as? [String: Any]
                let cumulativePayload = usageInfo?["total_token_usage"] as? [String: Any]
                let hasCumulativePayload = usageInfo?.keys.contains("total_token_usage") == true
                if payloadType == "token_count", let usage = cumulativePayload,
                   let i = integer(usage["input_tokens"]), let o = integer(usage["output_tokens"]), let t = integer(usage["total_tokens"]) {
                    tokenRecord = Record(date: date, input: i, output: o, total: t, five: nil, seven: nil, isRate: false)
                    cumulativeTotal = t; cumulativeOutput = o
                }
                if payloadType == "token_count" {
                    let limits = payload["rate_limits"] as? [String: Any]
                    let windows = [limits?["primary"], limits?["secondary"]]
                    let fiveCandidates = windows.compactMap { window($0, minutes: 300, now: now, at: date) }
                    let sevenCandidates = windows.compactMap { window($0, minutes: 10080, now: now, at: date) }
                    let record = Record(date: date, input: 0, output: 0, total: 0,
                        five: fiveCandidates.count == 1 ? fiveCandidates[0] : nil,
                        seven: sevenCandidates.count == 1 ? sevenCandidates[0] : nil, isRate: true)
                    rateRecord = record
                }
                let duration: Double?
                if payload.keys.contains("duration_ms") {
                    if let value = payload["duration_ms"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, value.doubleValue >= 0 { duration = value.doubleValue }
                    else { duration = .nan }
                } else { duration = nil }
                parsed.append(ParsedEvent(date: date, type: payloadType ?? "", turnID: payload["turn_id"] as? String,
                    duration: duration, totalTokens: cumulativeTotal, outputTokens: cumulativeOutput,
                    hasCumulativePayload: hasCumulativePayload, usage: tokenRecord, rate: rateRecord))
            }
            cache?.parsed()
            cache?.beforePostReadValidation?()
            var after = stat()
            guard fstat(fd, &after) == 0, FileSignature(after) == signature else {
                cache?.entries.removeValue(forKey: signature)
                continue
            }
            let token = parsed.compactMap(\.usage).filter { !$0.isRate }.last
            let rate = parsed.compactMap(\.rate).reduce(nil as Record?) { latest, record in
                latest == nil || latest!.date <= record.date ? record : latest
            }
            let turnSummaries = hasInvalidLifecycleTimestamp ? [] : completedTurns(in: parsed)
            let hasFutureTurn = turnSummaries.contains { $0.completedAt > now }
            let tailLimited = fst.st_size > off_t(amount)
            let fileSummary = CachedFileSummary(token: token, rate: rate,
                turn: turnSummaries.filter { $0.completedAt <= now }.max(by: { $0.completedAt < $1.completedAt }),
                latestEventAt: token?.date, tailLimited: tailLimited)
            summary = fileSummary
            if let cache {
                if hasFutureTurn { cache.entries.removeValue(forKey: signature) }
                else { cache.entries[signature] = fileSummary }
                if cache.entries.count > maxSessions {
                    let excess = cache.entries.count - maxSessions
                    for key in cache.entries.keys.prefix(excess) { cache.entries.removeValue(forKey: key) }
                }
            }
            }
            guard let summary else { continue }
            filesScanned += 1
            if summary.tailLimited { limited = true }
            if let rate = summary.rate, latestRate == nil || latestRate!.date <= rate.date { latestRate = rate }
            if let record = summary.token {
                let (ni, oi) = input.addingReportingOverflow(record.input), (no, oo) = output.addingReportingOverflow(record.output), (nt, ot) = total.addingReportingOverflow(record.total)
                guard !oi, !oo, !ot else { throw StatError.message("本地用量汇总超出可表示范围") }
                input = ni; output = no; total = nt; sessionCount += 1
                if latestEvent == nil || latestEvent! < record.date { latestEvent = record.date }
            }
            if let turn = summary.turn, turn.completedAt <= now,
               latestTurn == nil || latestTurn!.completedAt < turn.completedAt { latestTurn = turn }
        }
        if let cache { cache.entries = cache.entries.filter { liveSignatures.contains($0.key) } }
        return LocalCodexSnapshot(input: input, output: output, total: total, sessionCount: sessionCount, filesScanned: filesScanned, isLimited: limited, latestEventAt: latestEvent,
            fiveHour: latestRate?.five, sevenDay: latestRate?.seven, lastTurn: latestTurn)
    }

    private static func completedTurns(in events: [ParsedEvent]) -> [LocalTurnSummary] {
        var result: [LocalTurnSummary] = []
        for (startIndex, start) in events.enumerated() where start.type == "task_started" {
            guard let id = start.turnID, !id.isEmpty else { continue }
            var activeIDs: [String] = []
            for event in events[..<startIndex] {
                if event.type == "task_started", let activeID = event.turnID { activeIDs.append(activeID) }
                if event.type == "task_complete", let completedID = event.turnID,
                   let index = activeIDs.lastIndex(of: completedID) { activeIDs.remove(at: index) }
                if event.type == "turn_aborted" {
                    if let abortedID = event.turnID, let index = activeIDs.lastIndex(of: abortedID) { activeIDs.remove(at: index) }
                    else if event.turnID == nil { activeIDs.removeAll() }
                }
            }
            guard activeIDs.isEmpty else { continue }
            let completes = events.enumerated().filter { $0.element.type == "task_complete" && $0.element.turnID == id && $0.offset > startIndex }
            guard let (endIndex, complete) = completes.first else { continue }
            // Reused identifiers and overlapping turns make token attribution ambiguous.
            guard !events.enumerated().contains(where: { $0.offset > startIndex && $0.offset < endIndex && $0.element.type == "task_started" }) else { continue }
            guard !events.enumerated().contains(where: { $0.offset > startIndex && $0.offset < endIndex && $0.element.type == "task_complete" && $0.element.turnID != id }) else { continue }
            guard !events[startIndex..<endIndex].contains(where: { $0.type == "turn_aborted" && ($0.turnID == nil || $0.turnID == id) }) else { continue }
            let intervalDates = events[startIndex...endIndex].map(\.date)
            guard zip(intervalDates, intervalDates.dropFirst()).allSatisfy({ $0 <= $1 }) else { continue }
            let earlierStarts = events[..<startIndex].filter { $0.type == "task_started" && $0.turnID == id }
            guard earlierStarts.isEmpty else { continue }
            guard !events.enumerated().contains(where: { $0.offset > endIndex && $0.element.type == "task_started" && $0.element.turnID == id }) else { continue }
            var durationMS: Double?
            if let duration = complete.duration { durationMS = duration }
            else { durationMS = complete.date.timeIntervalSince(start.date) * 1000 }
            guard let durationMS, durationMS.isFinite, durationMS >= 100 else { continue }
            let baselineEvents = events[..<startIndex].filter {
                $0.type == "token_count" && $0.hasCumulativePayload
            }
            guard let baseline = baselineEvents.last, baseline.date <= start.date, let baselineTotal = baseline.totalTokens,
                  let baselineOutput = baseline.outputTokens else { continue }
            let inTurn = events[(startIndex + 1)..<endIndex].filter { $0.type == "token_count" && $0.hasCumulativePayload }
            guard !inTurn.isEmpty, inTurn.allSatisfy({ $0.totalTokens != nil && $0.outputTokens != nil }) else { continue }
            let totals = inTurn.compactMap(\.totalTokens), outputs = inTurn.compactMap(\.outputTokens)
            guard let lastTotal = totals.last, lastTotal >= baselineTotal, totals.first! >= baselineTotal,
                  let lastOutput = outputs.last, lastOutput >= baselineOutput, outputs.first! >= baselineOutput,
                  zip(totals, totals.dropFirst()).allSatisfy({ $0 <= $1 }),
                  zip(outputs, outputs.dropFirst()).allSatisfy({ $0 <= $1 }) else { continue }
            let duration = complete.duration ?? complete.date.timeIntervalSince(start.date) * 1000
            guard duration.isFinite, duration >= 100 else { continue }
            let summary = LocalTurnSummary(outputTokens: lastOutput - baselineOutput,
                durationSeconds: duration / 1000, completedAt: complete.date)
            result.append(summary)
        }
        return result
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        guard n.doubleValue.isFinite, n.doubleValue >= 0 else { return nil }
        var decimal = n.decimalValue
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 0, .plain)
        guard rounded == decimal else { return nil }
        let text = NSDecimalNumber(decimal: rounded).stringValue
        guard let exact = Int(text), exact >= 0 else { return nil }
        return exact
    }
    private static func openRelative(_ rootFD: Int32, _ path: String) -> Int32 {
        let parts = path.split(separator: "/").map(String.init)
        guard let leaf = parts.last else { return -1 }
        var current = dup(rootFD)
        guard current >= 0 else { return -1 }
        for component in parts.dropLast() {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(current)
            guard next >= 0 else { return -1 }
            current = next
        }
        let result = openat(current, leaf, O_RDONLY | O_NOFOLLOW)
        close(current)
        return result
    }
    private static func openDirectoryRelative(_ rootFD: Int32, _ path: String) -> Int32 {
        let parts = path.split(separator: "/").map(String.init)
        var current = dup(rootFD)
        guard current >= 0 else { return -1 }
        for component in parts {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(current)
            guard next >= 0 else { return -1 }
            current = next
        }
        return current
    }
    private static func isContained(fd: Int32, rootFD: Int32) -> Bool {
        func path(_ descriptor: Int32) -> String? {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
            let raw = String(cString: buffer)
            return raw.withCString { pointer in
                guard let resolved = realpath(pointer, nil) else { return nil }
                defer { free(resolved) }
                return String(cString: resolved)
            }
        }
        guard let root = path(rootFD), let file = path(fd) else { return false }
        return file.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
    private static func parseDate(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        return isoFormatter.date(from: s) ?? fractionalISOFormatter.date(from: s)
    }
    private static func window(_ value: Any?, minutes: Int, now: Date, at date: Date) -> WindowQuota? {
        guard let v = value as? [String: Any], let raw = v["used_percent"] as? NSNumber,
              CFGetTypeID(raw) != CFBooleanGetTypeID(), raw.doubleValue.isFinite, (0...100).contains(raw.doubleValue),
              let duration = integer(v["window_minutes"]), duration == minutes else { return nil }
        var reset: Date?
        if let n = v["resets_at"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
           n.doubleValue.isFinite, n.doubleValue > 0, n.doubleValue < 100_000_000_000 {
            reset = Date(timeIntervalSince1970: n.doubleValue)
        }
        return WindowQuota(minutes: minutes, usedPercent: raw.doubleValue, resetsAt: reset, fetchedAt: date)
    }
}
