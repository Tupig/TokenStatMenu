import AppKit
import SwiftUI
import Vision
import XCTest
import TokenStatWidgetShared
@testable import TokenStatWidgetUI

@MainActor
final class WidgetEntryViewTests: XCTestCase {
    func testActualWidgetRendersCurrentUnknownExpiredResetAndUnavailableStates() async throws {
        let now = Date()
        func snapshot(observed: Date, reset: Date, sevenReset: Date? = nil,
                      state: WidgetQuotaSnapshot.HubState = .ready) -> WidgetQuotaSnapshot {
            WidgetQuotaSnapshot(writtenAt: observed, observedAt: observed,
                validUntil: observed.addingTimeInterval(120), hubSource: .direct, hubState: state,
                fiveHour: .init(remainingPercent: 87.66, resetsAt: reset, limitAmount: 500, sourceSymbol: "$"),
                sevenDay: .init(remainingPercent: 43.22, resetsAt: sevenReset ?? now.addingTimeInterval(600), limitAmount: 2000, sourceSymbol: "$"),
                monthly: .init(usedAmount: 1234.56, limitAmount: nil, sourceSymbol: "$"),
                local: nil, resetVoucherCount: 3)
        }
        let current = snapshot(observed: now, reset: now.addingTimeInterval(600))
        let expired = snapshot(observed: now.addingTimeInterval(-121), reset: now.addingTimeInterval(600))
        let reset = snapshot(observed: now, reset: now.addingTimeInterval(-1))
        func assertLabels(_ text: String) {
            for label in ["5小时", "7天", "月度用量", "重置券"] { XCTAssertTrue(text.contains(label), text) }
        }
        func assertNoOldValues(_ text: String) {
            for old in ["87.66", "43.22", "1,234.56", "3张"] { XCTAssertFalse(text.contains(old), text) }
        }
        for dark in [false, true] {
            let live = try await render(.init(date: now, snapshot: current, channelAvailable: true), dark: dark)
            assertLabels(live)
            XCTAssertTrue(live.contains("87.66%"), live)
            XCTAssertTrue(live.contains("43.22%"), live)
            XCTAssertTrue(live.contains("1,234.56"), live)
            XCTAssertTrue(live.contains("3张"), live)
            let stale = try await render(.init(date: now, snapshot: expired, channelAvailable: true), dark: dark)
            XCTAssertTrue(stale.contains("未知"), stale)
            assertLabels(stale)
            assertNoOldValues(stale)
            let resetText = try await render(.init(date: now, snapshot: reset, channelAvailable: true), dark: dark)
            XCTAssertFalse(resetText.contains("87.66"), resetText)
            XCTAssertTrue(resetText.contains("43.22%"), resetText)
            XCTAssertTrue(resetText.contains("未知"), resetText)
            assertLabels(resetText)
            XCTAssertTrue(resetText.contains("1,234.56") && resetText.contains("3张"), resetText)
            let sevenExpired = snapshot(observed: now, reset: now.addingTimeInterval(600), sevenReset: now.addingTimeInterval(-1))
            let reverse = try await render(.init(date: now, snapshot: sevenExpired, channelAvailable: true), dark: dark)
            assertLabels(reverse)
            XCTAssertTrue(reverse.contains("87.66%") && reverse.contains("未知"), reverse)
            XCTAssertFalse(reverse.contains("43.22"), reverse)
            XCTAssertTrue(reverse.contains("1,234.56") && reverse.contains("3张"), reverse)
            for vouchers: Int? in [nil, 0] {
                let partial = WidgetQuotaSnapshot(writtenAt: now, observedAt: now, validUntil: now.addingTimeInterval(120),
                    hubSource: .direct, hubState: .ready, fiveHour: nil, sevenDay: current.sevenDay,
                    monthly: nil, local: nil, resetVoucherCount: vouchers)
                let text = try await render(.init(date: now, snapshot: partial, channelAvailable: true), dark: dark)
                assertLabels(text)
                XCTAssertTrue(text.contains("43.22%") && text.contains("未知"), text)
                XCTAssertFalse(text.contains("87.66") || text.contains("1,234.56") || text.contains("3张"), text)
                XCTAssertEqual(text.contains("0张"), vouchers == 0, text)
            }
            for invalid in [
                snapshot(observed: now, reset: now.addingTimeInterval(600), state: .unavailable),
                snapshot(observed: now.addingTimeInterval(60), reset: now.addingTimeInterval(600)),
            ] {
                let text = try await render(.init(date: now, snapshot: invalid, channelAvailable: true), dark: dark)
                XCTAssertTrue(text.contains("未知"), text)
                assertLabels(text)
                assertNoOldValues(text)
            }
            let empty = try await render(.init(date: now, snapshot: nil, channelAvailable: true), dark: dark)
            XCTAssertTrue(empty.contains("尚未获取数据"), empty)
            let unavailable = try await render(.init(date: now, snapshot: current, channelAvailable: false), dark: dark)
            XCTAssertTrue(unavailable.contains("共享通道不可用"), unavailable)
            assertNoOldValues(unavailable)
        }
    }

    private func render(_ entry: WidgetEntry, dark: Bool) async throws -> String {
        let bounds = NSRect(x: 0, y: 0, width: 164, height: 164)
        let view = WidgetEntryView(entry: entry)
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: bounds.width, height: bounds.height)
            .background(dark ? Color.black : Color.white)
        let host = NSHostingView(rootView: view)
        host.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 984, pixelsHigh: 984, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = bounds.size
        host.cacheDisplay(in: bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n").replacingOccurrences(of: " ", with: "")
    }
}
