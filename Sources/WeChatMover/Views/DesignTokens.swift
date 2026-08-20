import SwiftUI
import AppKit

/// 设计规范第 4 节：颜色 / 字体 / 间距 / 圆角集中管理，全部动态适配深浅色。
enum DesignTokens {
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 12
        static let control: CGFloat = 8
        static let pill: CGFloat = 999
    }

    enum Colors {
        static let background = Color(nsColor: .windowBackgroundColor)
        static let surface = Color(nsColor: .controlBackgroundColor)
        static let surfaceSubtle = Color(nsColor: .quaternaryLabelColor).opacity(0.2)
        static let separator = Color(nsColor: .separatorColor)
        /// 主题色：跟随当前档案（微信绿 / 企业微信蓝），由 Theme.accent 提供。
        /// 注意：Color.accentColor 环境解析对 .tint() 不可靠（实测仍解析为系统蓝），
        /// 故显式走 Theme 全局；Theme 在 switchProfile 中先于 profile 赋值，时序安全。
        static var accent: Color { Theme.accent }
        static let warning = Color.orange
        static let danger = Color.red
        static let info = Color.blue
    }

    /// 状态色调 → 颜色（不单独依赖颜色表达状态，配合 SF Symbol + 文案使用）。
    static func toneColor(_ tone: StatusTone) -> Color {
        switch tone {
        case .neutral: return .secondary
        case .info: return Colors.info
        case .success: return Colors.accent
        case .warning: return Colors.warning
        case .danger: return Colors.danger
        }
    }

    /// 卡片容器修饰：surface 底 + 1px separator 描边 + 12 圆角，无阴影。
    struct Card: ViewModifier {
        func body(content: Content) -> some View {
            content
                .padding(Spacing.md)
                .background(Colors.surface, in: RoundedRectangle(cornerRadius: Radius.card))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card)
                        .stroke(Colors.separator, lineWidth: 1)
                )
        }
    }
}

extension View {
    func cardStyle() -> some View { modifier(DesignTokens.Card()) }
}

extension Color {
    /// 深浅色双值动态颜色。
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
