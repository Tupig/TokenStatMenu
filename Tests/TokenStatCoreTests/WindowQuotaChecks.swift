import Foundation
import TokenStatCore

extension CoreChecks {
    static func windowQuotaChecks() throws {
        let config = AppConfiguration(), now = Date(timeIntervalSince1970: 1_800_000_000)
        let response = json("""
        {"data":{"five_hour":{"used_percent":25,"resets_at":1800003600},"seven_day":{"used_percent":70,"resets_at":"2027-01-17T08:00:00Z"}}}
        """)
        let report = try QuotaReport.parse(response, config: config, now: now)
        check(report.monthly == nil && report.fiveHour?.remainingPercent == 75, "5-hour quota independent of missing monthly fields")
        check(report.sevenDay?.usedPercent == 70 && report.sevenDay?.resetsAt != nil, "7-day quota and ISO reset timestamp")
        check(report.fiveHour?.isFresh(at: now.addingTimeInterval(30), refreshSeconds: 60) == true, "window fresh before reset")
        check(report.fiveHour?.isFresh(at: now.addingTimeInterval(121), refreshSeconds: 60) == false, "stale quota never drives current alerts")
        check(report.fiveHour?.isFresh(at: now.addingTimeInterval(4000), refreshSeconds: 3600) == false, "reset time expires quota even with long refresh interval")
        let codex = json("""
        {"rateLimits":{"primary":{"usedPercent":45,"windowDurationMins":10080,"resetsAt":1800007200},"secondary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":1800003600}}}
        """)
        let normalized = try QuotaReport.parse(codex, config: config, now: now)
        check(normalized.fiveHour?.usedPercent == 10 && normalized.sevenDay?.usedPercent == 45, "classify Codex windows by duration, not primary/secondary position")
        let wrappedCodex = json("""
        {"result":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300},"secondary":{"usedPercent":60,"windowDurationMins":10080}}}}
        """)
        let wrapped = try QuotaReport.parse(wrappedCodex, config: config, now: now)
        check(wrapped.fiveHour?.usedPercent == 20 && wrapped.sevenDay?.usedPercent == 60, "classify duration-based windows under the result wrapper")
        let unknown = json("{\"rateLimits\":{\"primary\":{\"usedPercent\":10,\"windowDurationMins\":null}}}")
        do { _ = try QuotaReport.parse(unknown, config: config, now: now); check(false, "unknown duration must not become 5-hour quota") } catch { check(true, "unknown duration is not guessed") }
        var ambiguousConfig = config
        ambiguousConfig.sevenDayUsedPercentPath = "data.seven_day.used_percent"
        let ambiguous = json("""
        {"data":{"seven_day":{"used_percent":65}},"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300},"secondary":{"usedPercent":30,"windowDurationMins":300}}}
        """)
        let ambiguousReport = try QuotaReport.parse(ambiguous, config: ambiguousConfig, now: now)
        check(ambiguousReport.fiveHour == nil && ambiguousReport.sevenDay?.usedPercent == 65, "duplicate 5-hour duration stays unknown without discarding configured 7-day sibling")
        let partial = try QuotaReport.parse(json("{\"data\":{\"five_hour\":{\"used_percent\":0}}}"), config: config, now: now)
        check(partial.fiveHour?.remainingPercent == 100 && partial.fiveHour?.resetsAt == nil && partial.sevenDay == nil, "zero is valid, unknown reset and missing window stay unknown")
        let full = try QuotaReport.parse(json("{\"data\":{\"five_hour\":{\"used_percent\":100,\"resets_at\":1800003600}}}"), config: config, now: now)
        check(full.fiveHour?.usedPercent == 100 && full.fiveHour?.remainingPercent == 0, "100 percent is valid and means zero remaining")
        let percentage = try QuotaReport.parse(json("{\"data\":{\"five_hour\":{\"used_percent\":0.85}}}"), config: config, now: now)
        check(percentage.fiveHour?.remainingPercent == 99.15, "percentage fields never guessed as fractional ratios")
        for value in ["true", "-1", "101"] {
            do { _ = try QuotaReport.parse(json("{\"data\":{\"five_hour\":{\"used_percent\":\(value)}}}"), config: config, now: now); check(false, "invalid percent should fail") }
            catch { check(true, "invalid percent rejected") }
        }
        let invalidStringSibling = try QuotaReport.parse(json("{\"data\":{\"five_hour\":{\"used_percent\":\"not-a-number\"},\"seven_day\":{\"used_percent\":40}}}"), config: config, now: now)
        check(invalidStringSibling.fiveHour == nil && invalidStringSibling.sevenDay?.usedPercent == 40, "invalid string percentage does not erase valid sibling window")
        do {
            _ = try QuotaReport.parse(json("{\"data\":{\"five_hour\":{\"used_percent\":\"not-a-number\"}}}"), config: config, now: now)
            check(false, "invalid percentage string alone must not create a quota report")
        } catch { check(true, "invalid percentage string rejected") }
        let invalidReset = try QuotaReport.parse(json("{\"data\":{\"five_hour\":{\"used_percent\":20,\"resets_at\":\"not-an-ISO-date\"}}}"), config: config, now: now)
        check(invalidReset.fiveHour?.usedPercent == 20 && invalidReset.fiveHour?.resetsAt == nil, "invalid reset format preserves usage with unknown reset")
        let resetNow = try QuotaReport.parse(json("{\"data\":{\"five_hour\":{\"used_percent\":20,\"resets_at\":1800000000}}}"), config: config, now: now)
        check(resetNow.fiveHour?.isFresh(at: now, refreshSeconds: 3600) == false, "reset time equal to now is expired")
        check(resetNow.fiveHour?.isFresh(at: now.addingTimeInterval(-1), refreshSeconds: 3600) == true, "window remains fresh immediately before reset time")
        let milliseconds = try QuotaReport.parse(json("{\"data\":{\"five_hour\":{\"used_percent\":10,\"resets_at\":1800003600000}}}"), config: config, now: now)
        check(milliseconds.fiveHour?.resetsAt == nil, "milliseconds must not silently become a far-future seconds timestamp")
        var customPaths = config
        customPaths.fiveHourUsedPercentPath = "payload.windows.0.used"
        customPaths.fiveHourResetPath = "payload.windows.0.reset"
        let customPathReport = try QuotaReport.parse(json("{\"payload\":{\"windows\":[{\"used\":35,\"reset\":\"2027-01-15T08:00:00Z\"}]}}"), config: customPaths, now: now)
        check(customPathReport.fiveHour?.usedPercent == 35 && customPathReport.fiveHour?.resetsAt != nil, "configured paths support nested objects and array indices")
        let month = QuotaSnapshot.currentMonth(at: now)
        let monthly = try QuotaReport.parse(json("{\"data\":{\"used_tokens\":800,\"total_tokens\":1000,\"month\":\"\(month)\"}}"), config: config, now: now)
        check(monthly.monthly?.fraction == 0.8 && monthly.fiveHour == nil && monthly.sevenDay == nil, "monthly-only APIs remain supported without manufacturing windows")
    }
}
