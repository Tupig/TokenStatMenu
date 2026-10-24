import AppKit
import SwiftUI
import Vision
import XCTest
import TokenStatWidgetShared
@testable import TokenStatWidgetUI

@MainActor
final class WidgetEntryViewTests: XCTestCase {
    func testActualWidgetRendersCurrentUnknownExpiredResetAndUnavailableStates() async throws {
        // 产品取 max(entry.date, Date.now)；提前一小时的条目时间让本组
        // 慢速图像识别期间仍按同一逻辑时钟验证，不修改产品时钟策略。
        let now = Date().addingTimeInterval(3600)
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
        func assertLabels(_ result: RenderResult) {
            for label in ["5小时", "7天", "月度用量", "重置券"] {
                XCTAssertTrue(result.labels.contains(label), "top-1: \(result.text)\n候选: \(result.labels)")
            }
        }
        func assertNoOldValues(_ result: RenderResult) {
            let text = result.text
            for old in ["87.66", "43.22", "1,234.56", "3张"] { XCTAssertFalse(text.contains(old), text) }
        }
        for dark in [false, true] {
            let live = try await render(.init(date: now, snapshot: current, channelAvailable: true), dark: dark)
            assertLabels(live)
            XCTAssertTrue(live.text.contains("87.66%"), live.text)
            XCTAssertTrue(live.text.contains("43.22%"), live.text)
            XCTAssertTrue(live.text.contains("1,234.56"), live.text)
            XCTAssertTrue(live.text.contains("3张"), live.text)
            let stale = try await render(.init(date: now, snapshot: expired, channelAvailable: true), dark: dark)
            XCTAssertTrue(stale.labels.contains("未知"), stale.text)
            assertLabels(stale)
            assertNoOldValues(stale)
            let resetText = try await render(.init(date: now, snapshot: reset, channelAvailable: true), dark: dark)
            XCTAssertFalse(resetText.text.contains("87.66"), resetText.text)
            XCTAssertTrue(resetText.text.contains("43.22%"), resetText.text)
            XCTAssertTrue(resetText.labels.contains("未知"), resetText.text)
            assertLabels(resetText)
            XCTAssertTrue(resetText.text.contains("1,234.56") && resetText.text.contains("3张"), resetText.text)
            let sevenExpired = snapshot(observed: now, reset: now.addingTimeInterval(600), sevenReset: now.addingTimeInterval(-1))
            let reverse = try await render(.init(date: now, snapshot: sevenExpired, channelAvailable: true), dark: dark)
            assertLabels(reverse)
            XCTAssertTrue(reverse.text.contains("87.66%") && reverse.labels.contains("未知"), reverse.text)
            XCTAssertFalse(reverse.text.contains("43.22"), reverse.text)
            XCTAssertTrue(reverse.text.contains("1,234.56") && reverse.text.contains("3张"), reverse.text)
            for vouchers: Int? in [nil, 0] {
                let partial = WidgetQuotaSnapshot(writtenAt: now, observedAt: now, validUntil: now.addingTimeInterval(120),
                    hubSource: .direct, hubState: .ready, fiveHour: nil, sevenDay: current.sevenDay,
                    monthly: nil, local: nil, resetVoucherCount: vouchers)
                let text = try await render(.init(date: now, snapshot: partial, channelAvailable: true), dark: dark)
                assertLabels(text)
                XCTAssertTrue(text.text.contains("43.22%") && text.labels.contains("未知"), text.text)
                XCTAssertFalse(text.text.contains("87.66") || text.text.contains("1,234.56") || text.text.contains("3张"), text.text)
                XCTAssertEqual(text.text.contains("0张"), vouchers == 0, text.text)
            }
            for invalid in [
                snapshot(observed: now, reset: now.addingTimeInterval(600), state: .unavailable),
                snapshot(observed: now.addingTimeInterval(60), reset: now.addingTimeInterval(600)),
            ] {
                let text = try await render(.init(date: now, snapshot: invalid, channelAvailable: true), dark: dark)
                XCTAssertTrue(text.labels.contains("未知"), text.text)
                assertLabels(text)
                assertNoOldValues(text)
            }
            let empty = try await render(.init(date: now, snapshot: nil, channelAvailable: true), dark: dark)
            XCTAssertTrue(empty.labels.contains("尚未获取数据"), empty.text)
            let unavailable = try await render(.init(date: now, snapshot: current, channelAvailable: false), dark: dark)
            XCTAssertTrue(unavailable.labels.contains("共享通道不可用"), unavailable.text)
            assertNoOldValues(unavailable)
        }
    }

    private struct RenderResult {
        let text: String
        let labels: String
    }

    private func render(_ entry: WidgetEntry, dark: Bool) async throws -> RenderResult {
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
        let image = try XCTUnwrap(bitmap.cgImage)
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = request.results ?? []
        let text = observations.compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n").replacingOccurrences(of: " ", with: "")
        // 数值与旧值泄露仍核对关闭纠正的整图 top-1。中文标签另核对
        // 原始候选和启用系统纠正的真实行区域；不注入预期词，不能据此
        // 宣称每个中文字形正确，也不代替原生辅助功能检查。
        var labels = observations.flatMap { $0.topCandidates(10) }.map(\.string)
        for observation in observations {
            let recognized = observation.topCandidates(1).first?.string ?? ""
            guard recognized.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) else { continue }
            let box = observation.boundingBox
            let region = CGRect(x: box.minX * CGFloat(image.width) - 12,
                y: (1 - box.maxY) * CGFloat(image.height) - 12,
                width: box.width * CGFloat(image.width) + 24,
                height: box.height * CGFloat(image.height) + 24)
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
            guard let crop = image.cropping(to: region) else { continue }
            // 不同 macOS Vision 对 6× 小字的字形分割不同。用原始行和
            // 降采样行各取系统识别结果，不注入预期词，也不替换错字。
            for scale: CGFloat in [1, 0.5] {
                let context = try XCTUnwrap(CGContext(data: nil,
                    width: max(1, Int(CGFloat(crop.width) * scale)),
                    height: max(1, Int(CGFloat(crop.height) * scale)),
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.interpolationQuality = .high
                context.draw(crop, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
                let lineImage = try XCTUnwrap(context.makeImage())
                let lineRequest = VNRecognizeTextRequest()
                lineRequest.recognitionLevel = .accurate
                lineRequest.recognitionLanguages = ["zh-Hans", "en-US"]
                lineRequest.usesLanguageCorrection = true
                try VNImageRequestHandler(cgImage: lineImage, options: [:]).perform([lineRequest])
                labels += (lineRequest.results ?? []).flatMap { $0.topCandidates(10) }.map(\.string)
            }
        }
        return RenderResult(text: text, labels: labels.joined(separator: "\n").replacingOccurrences(of: " ", with: ""))
    }
}
