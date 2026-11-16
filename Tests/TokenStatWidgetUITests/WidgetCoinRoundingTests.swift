import AppKit
import SwiftUI
import Vision
import XCTest
import TokenStatWidgetShared
@testable import TokenStatWidgetUI

@MainActor
final class WidgetCoinRoundingTests: XCTestCase {
    func testActualWidgetUsesPositiveHalfExpandForCoinAmounts() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = WidgetQuotaSnapshot(writtenAt: now, observedAt: now,
            validUntil: now.addingTimeInterval(120), hubSource: .direct, hubState: .ready,
            fiveHour: .init(remainingPercent: 50, resetsAt: nil, usedAmount: 1,
                            limitAmount: 12.345, sourceSymbol: "🪙"),
            sevenDay: .init(remainingPercent: 50, resetsAt: nil, usedAmount: 1,
                            limitAmount: 12.355, sourceSymbol: "🪙"),
            monthly: .init(usedAmount: 12.345, limitAmount: 100, sourceSymbol: "🪙"),
            local: nil, resetVoucherCount: nil)
        let entry = WidgetEntry(date: now, snapshot: snapshot, channelAvailable: true)
        let bounds = NSRect(x: 0, y: 0, width: 164, height: 164)
        let containerBounds = NSRect(x: 0, y: 0, width: bounds.width + 248, height: bounds.height)
        let productView = WidgetEntryView(entry: entry)
            .frame(width: bounds.width, height: bounds.height)
        let host = NSHostingView(rootView: productView)
        host.frame = bounds
        let contentView = NSView(frame: containerBounds)
        contentView.addSubview(host)
        let capabilityProbe = NSHostingView(rootView: Text("Synthetic AX capability probe"))
        capabilityProbe.frame = NSRect(x: bounds.maxX + 8, y: 0, width: 240, height: 24)
        contentView.addSubview(capabilityProbe)
        let window = NSWindow(contentRect: containerBounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        defer { window.close() }
        window.contentView = contentView
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        capabilityProbe.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(capabilityProbe.window === window, "the SwiftUI AX probe belongs to the same test window")
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 984, pixelsHigh: 984, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = bounds.size
        host.cacheDisplay(in: bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: try XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        let text = (request.results ?? []).flatMap { $0.topCandidates(10) }.map(\.string).joined(separator: "\n")
        let compact = text.replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(compact.contains("12.35"), "actual Widget shows 12.345 as 12.35: \(text)")
        XCTAssertTrue(compact.contains("12.36"), "actual Widget shows 12.355 as 12.36: \(text)")
        let accessibilityText = widgetVisibleAccessibilityStrings(in: window, hosts: [contentView, host])
        let probeText = widgetVisibleAccessibilityStrings(in: window, hosts: [capabilityProbe])
        guard !accessibilityText.isEmpty || probeText.contains(where: { $0.contains("Synthetic AX capability probe") }) else {
            throw XCTSkip("The test-owned NSWindow host (key=\(window.isKeyWindow)) exposes no plain SwiftUI AX text; coin AX was not observable")
        }
        XCTAssertTrue(accessibilityText.contains(where: { $0.contains("🪙 12.35") }),
                      "actual Widget AX label/value retains the coin prefix and separating space: \(accessibilityText)")
        XCTAssertTrue(accessibilityText.contains(where: { $0.contains("🪙 12.36") }),
                      "actual Widget AX label/value retains the coin prefix and separating space: \(accessibilityText)")
    }

    private func widgetVisibleAccessibilityStrings(in window: NSWindow, hosts: [NSView]) -> [String] {
        var queue: [(object: AnyObject, depth: Int)] = [(window, 0)]
            + hosts.map { ($0 as AnyObject, 0) }
        var visited = Set<ObjectIdentifier>()
        var strings: [String] = []
        while let next = queue.first, visited.count < 128 {
            queue.removeFirst()
            let (object, depth) = next
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if let item = object as? any NSAccessibilityProtocol {
                if let label = item.accessibilityLabel(), !label.isEmpty { strings.append(label) }
                if let value = item.accessibilityValue() as? String, !value.isEmpty { strings.append(value) }
                if let value = item.accessibilityValue() as? NSAttributedString, !value.string.isEmpty {
                    strings.append(value.string)
                }
                guard depth < 6 else { continue }
                let routes: [[Any]] = [item.accessibilityChildren() ?? [],
                                       item.accessibilityChildrenInNavigationOrder() ?? [],
                                       (item.accessibilityContents() as? [Any]) ?? []]
                for child in routes.flatMap({ Array($0.prefix(32)) }) {
                    queue.append((child as AnyObject, depth + 1))
                }
            }
            if let text = object as? any NSAccessibilityStaticText,
               let value = text.accessibilityValue(), !value.isEmpty {
                strings.append(value)
            }
            if let button = object as? any NSAccessibilityButton,
               let label = button.accessibilityLabel(), !label.isEmpty {
                strings.append(label)
            }
        }
        return strings
    }
}
