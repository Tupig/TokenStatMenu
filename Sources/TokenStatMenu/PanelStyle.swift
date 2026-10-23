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
