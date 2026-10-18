// Original code-native geometry. This renderer reads no images or user data.
// The reviewed PNG and native .icns are reproducible build-time assets only.
import AppKit
import Foundation

let output = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/AppIcon.png")
let dimension = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: dimension, pixelsHigh: dimension,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: dimension * 4, bitsPerPixel: 32)!
bitmap.bitmapData!.initialize(repeating: 0, count: bitmap.bytesPerRow * dimension)
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.shouldAntialias = true

// All colored pixels are clipped to this one native rounded rectangle.
let tile = NSBezierPath(roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832),
                        xRadius: 190, yRadius: 190)
tile.addClip()
let blue = NSColor(srgbRed: 0.20, green: 0.38, blue: 0.98, alpha: 1)
let violet = NSColor(srgbRed: 0.52, green: 0.27, blue: 0.95, alpha: 1)
NSGradient(starting: blue, ending: violet)!.draw(in: tile, angle: -45)

// A single opaque pulse and two token dots stay clear at small icon sizes.
NSColor.white.setStroke()
NSColor.white.setFill()
let pulse = NSBezierPath()
pulse.move(to: NSPoint(x: 320, y: 512))
pulse.curve(to: NSPoint(x: 450, y: 650), controlPoint1: NSPoint(x: 388, y: 512),
            controlPoint2: NSPoint(x: 396, y: 650))
pulse.curve(to: NSPoint(x: 562, y: 374), controlPoint1: NSPoint(x: 508, y: 650),
            controlPoint2: NSPoint(x: 504, y: 374))
pulse.curve(to: NSPoint(x: 704, y: 512), controlPoint1: NSPoint(x: 620, y: 374),
            controlPoint2: NSPoint(x: 632, y: 512))
pulse.lineWidth = 50
pulse.lineCapStyle = .round
pulse.lineJoinStyle = .round
pulse.stroke()
for centerX in [220.0, 804.0] {
    NSBezierPath(ovalIn: NSRect(x: centerX - 31, y: 481, width: 62, height: 62)).fill()
}
NSGraphicsContext.restoreGraphicsState()

// Guard the transparent margin without modifying any rendered pixels.
for y in 0..<dimension {
    for x in 0..<dimension where x < 95 || x > 929 || y < 95 || y > 929 {
        precondition(bitmap.colorAt(x: x, y: y)!.alphaComponent == 0, "Icon margin must stay transparent")
    }
}
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode original icon geometry")
}
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: output, options: .atomic)
print("Rendered original 1024px TokenStatMenu icon.")
