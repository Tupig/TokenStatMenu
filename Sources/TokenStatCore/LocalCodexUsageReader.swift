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
    public init(input: Int, output: Int, total: Int, sessionCount: Int, filesScanned: Int, isLimited: Bool, latestEventAt: Date?, fiveHour: WindowQuota?, sevenDay: WindowQuota?) {
        self.input = input; self.output = output; self.total = total; self.sessionCount = sessionCount
        self.filesScanned = filesScanned; self.isLimited = isLimited; self.latestEventAt = latestEventAt
        self.fiveHour = fiveHour; self.sevenDay = sevenDay
    }
}

/// Reads only bounded numeric usage metadata from Codex session JSONL files.
public enum LocalCodexUsageReader {
    private static let maxEntries = 5_000
    private static let maxSessions = 32
    private static let tailLimit = 256 * 1024
    private static let byteLimit = 8 * 1024 * 1024
    private static let uuidPattern = try! NSRegularExpression(pattern: "([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\\.jsonl$")

    private struct Candidate { let name: String; let uuid: String; let modified: Date }
    private struct Record { let date: Date; let input: Int; let output: Int; let total: Int; let five: WindowQuota?; let seven: WindowQuota?; let isRate: Bool }

    public static func defaultSessionsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let configured = environment["CODEX_HOME"], configured.hasPrefix("/") {
            return URL(fileURLWithPath: configured).appendingPathComponent("sessions")
        }
        return home.appendingPathComponent(".codex").appendingPathComponent("sessions")
    }

    public static func scan(directory: URL, now: Date = Date()) throws -> LocalCodexSnapshot {
        let empty = LocalCodexSnapshot(input: 0, output: 0, total: 0, sessionCount: 0, filesScanned: 0, isLimited: false, latestEventAt: nil, fiveHour: nil, sevenDay: nil)
        var st = stat()
        guard lstat(directory.path, &st) == 0 else { if errno == ENOENT { return empty }; return empty }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return empty }
        let rootFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { return empty }
        defer { close(rootFD) }
        var opened = stat()
        guard fstat(rootFD, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFDIR else { return empty }
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
        for candidate in candidates {
            guard usedBytes < byteLimit else { limited = true; break }
            let fd = openRelative(rootFD, candidate.name)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var fst = stat()
            guard fstat(fd, &fst) == 0, (fst.st_mode & S_IFMT) == S_IFREG, fst.st_size >= 0 else { continue }
            let contained = isContained(fd: fd, rootFD: rootFD)
            guard contained else { continue }
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
            usedBytes += readCount; filesScanned += 1
            if fst.st_size > off_t(amount) { limited = true }
            var lines = data.split(separator: 10, omittingEmptySubsequences: false)
            if offset > 0, !data.isEmpty { lines.removeFirst() }
            if data.last != 10 { lines.removeLast() }
            var lastToken: Record?
            for line in lines where !line.isEmpty {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)), let root = object as? [String: Any],
                      root["type"] as? String == "event_msg", let payload = root["payload"] as? [String: Any] else { continue }
                guard let date = parseDate(root["timestamp"]) else { continue }
                let payloadType = payload["type"] as? String
                if payloadType == "token_count", let info = payload["info"] as? [String: Any],
                   let usage = info["total_token_usage"] as? [String: Any],
                   let i = integer(usage["input_tokens"]), let o = integer(usage["output_tokens"]), let t = integer(usage["total_tokens"]) {
                    lastToken = Record(date: date, input: i, output: o, total: t, five: nil, seven: nil, isRate: false)
                }
                if payloadType == "token_count" {
                    let limits = payload["rate_limits"] as? [String: Any]
                    let windows = [limits?["primary"], limits?["secondary"]]
                    let fiveCandidates = windows.compactMap { window($0, minutes: 300, now: now, at: date) }
                    let sevenCandidates = windows.compactMap { window($0, minutes: 10080, now: now, at: date) }
                    let record = Record(date: date, input: 0, output: 0, total: 0,
                        five: fiveCandidates.count == 1 ? fiveCandidates[0] : nil,
                        seven: sevenCandidates.count == 1 ? sevenCandidates[0] : nil, isRate: true)
                    if latestRate == nil || latestRate!.date <= date { latestRate = record }
                }
            }
            if let record = lastToken {
                let (ni, oi) = input.addingReportingOverflow(record.input), (no, oo) = output.addingReportingOverflow(record.output), (nt, ot) = total.addingReportingOverflow(record.total)
                guard !oi, !oo, !ot else { throw StatError.message("本地用量汇总超出可表示范围") }
                input = ni; output = no; total = nt; sessionCount += 1
                if latestEvent == nil || latestEvent! < record.date { latestEvent = record.date }
            }
        }
        return LocalCodexSnapshot(input: input, output: output, total: total, sessionCount: sessionCount, filesScanned: filesScanned, isLimited: limited, latestEventAt: latestEvent,
            fiveHour: latestRate?.five, sevenDay: latestRate?.seven)
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
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: s) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: s)
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
