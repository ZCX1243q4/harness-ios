import SwiftUI
import UIKit

// MARK: - 主题选项

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, cyan, brown, gray

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blue: return "蓝"
        case .indigo: return "靛"
        case .purple: return "紫"
        case .pink: return "粉"
        case .red: return "红"
        case .orange: return "橙"
        case .yellow: return "黄"
        case .green: return "绿"
        case .mint: return "薄荷"
        case .teal: return "青"
        case .cyan: return "浅蓝"
        case .brown: return "棕"
        case .gray: return "灰"
        }
    }

    var color: Color {
        switch self {
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .mint: return .mint
        case .teal: return .teal
        case .cyan: return .cyan
        case .brown: return .brown
        case .gray: return .gray
        }
    }
}

enum BackgroundStyle: String, CaseIterable, Identifiable {
    case plain, gradient, glow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plain: return "纯色"
        case .gradient: return "渐变"
        case .glow: return "柔光"
        }
    }
}

enum BubbleStyle: String, CaseIterable, Identifiable {
    case filled, outlined

    var id: String { rawValue }

    var label: String {
        switch self {
        case .filled: return "填充"
        case .outlined: return "描边"
        }
    }
}

// MARK: - 主题键

enum Theme {
    static let appearanceKey = "harness.theme.appearance"
    static let accentKey = "harness.theme.accent"
    static let backgroundKey = "harness.theme.background"
    static let bubbleKey = "harness.theme.bubble"
    static let cornerKey = "harness.theme.corner"

    /// 圆角可选范围
    static let cornerRange: ClosedRange<Double> = 10...30
}

/// 读取当前主题的便捷外壳，视图里直接用
struct ThemeValues {
    var accent: AccentChoice
    var background: BackgroundStyle
    var bubble: BubbleStyle
    var corner: CGFloat

    var accentColor: Color { accent.color }
}

// MARK: - 背景

/// 极简背景。默认就是系统背景色，不做任何装饰。
struct AppBackground: View {
    @AppStorage(Theme.backgroundKey) private var backgroundRaw = BackgroundStyle.plain.rawValue
    @AppStorage(Theme.accentKey) private var accentRaw = AccentChoice.blue.rawValue
    @Environment(\.colorScheme) private var scheme

    private var style: BackgroundStyle { BackgroundStyle(rawValue: backgroundRaw) ?? .plain }
    private var accent: Color { (AccentChoice(rawValue: accentRaw) ?? .blue).color }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)

            switch style {
            case .plain:
                EmptyView()

            case .gradient:
                LinearGradient(
                    colors: [
                        accent.opacity(scheme == .dark ? 0.22 : 0.10),
                        Color(uiColor: .systemBackground),
                        Color(uiColor: .systemBackground)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

            case .glow:
                RadialGradient(
                    colors: [accent.opacity(scheme == .dark ? 0.20 : 0.12), .clear],
                    center: .init(x: 0.5, y: 0.02),
                    startRadius: 0,
                    endRadius: 460
                )
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - 小工具

extension View {
    /// 让列表/表单背景透出 AppBackground
    func transparentScrollBackground() -> some View {
        scrollContentBackground(.hidden)
    }
}
