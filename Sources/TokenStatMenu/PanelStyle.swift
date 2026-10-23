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
        VStack(alignment: .leading, spacing: 10) {
            configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(0.07)))
    }
}

struct StatusPill: View {
    let label: String
    var color: Color = PanelPalette.blue
    var body: some View {
        Text(label).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color).padding(.horizontal, 9).padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityLabel(label)
    }
}

struct QuotaRing: View {
    let fraction: Double?
    var body: some View {
        ZStack {
            Circle().stroke(PanelPalette.blue.opacity(0.12), lineWidth: 7)
            if let fraction {
                Circle().trim(from: 0, to: min(1, max(0, fraction)))
                    .stroke(PanelPalette.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 2) {
                Text(fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                    .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(fraction == nil ? "未知" : "已使用").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 84, height: 84)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fraction.map { String(format: "配额已使用 %.1f%%", $0 * 100) } ?? "企业用量未知")
    }
}
