import Foundation
import SwiftUI

// 紧凑的半透明原生组件，使用语义化前景色和材质适配深浅外观。
enum PanelPalette {
    static let blue = Color(red: 0.24, green: 0.43, blue: 0.96)
    static let violet = Color(red: 0.55, green: 0.39, blue: 0.89)
    static let gradient = LinearGradient(colors: [blue, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
}

enum TwoDecimalPercentFormatter {
    static func string(_ value: Double) -> String {
        String(format: "%.2f%%", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func string(_ value: Decimal) -> String {
        let number = NSDecimalNumber(decimal: value).doubleValue
        return string(number)
    }
}

enum HeaderActionMetrics {
    static let actionSize: CGFloat = 30
}

/// README 与 AppIcon 使用的同一枚标记：圆角渐变、一条波形、两端各一个圆点。
struct TokenStatMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 832
            context.scaleBy(x: scale, y: scale)
            let tile = Path(roundedRect: CGRect(x: 0, y: 0, width: 832, height: 832), cornerRadius: 190)
            context.clip(to: tile)
            context.fill(tile, with: .linearGradient(
                Gradient(colors: [
                    Color(.sRGB, red: 0.20, green: 0.38, blue: 0.98),
                    Color(.sRGB, red: 0.52, green: 0.27, blue: 0.95)
                ]),
                startPoint: .zero,
                endPoint: CGPoint(x: 832, y: 832)))
            // AppIcon 坐标系原点在左下；这里换成 SwiftUI 的左上原点。
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x - 96, y: 928 - y)
            }
            var pulse = Path()
            pulse.move(to: point(320, 512))
            pulse.addCurve(to: point(450, 650), control1: point(388, 512), control2: point(396, 650))
            pulse.addCurve(to: point(562, 374), control1: point(508, 650), control2: point(504, 374))
            pulse.addCurve(to: point(704, 512), control1: point(620, 374), control2: point(632, 512))
            context.stroke(pulse, with: .color(.white),
                           style: StrokeStyle(lineWidth: 50, lineCap: .round, lineJoin: .round))
            for centerX in [CGFloat(220), 804] {
                let center = point(centerX, 481)
                let dot = Path(ellipseIn: CGRect(x: center.x - 31, y: center.y - 31, width: 62, height: 62))
                context.fill(dot, with: .color(.white))
            }
        }
        .accessibilityHidden(true)
    }
}

enum PanelMetrics {
    static let size = CGSize(width: 300, height: 420)
}

/// 顶部操作不使用强调色，使设置和退出按钮在获取键盘焦点时仍保持中性、对称。
struct NeutralHeaderActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background(Color.clear)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct PanelCardStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.07)))
    }
}
