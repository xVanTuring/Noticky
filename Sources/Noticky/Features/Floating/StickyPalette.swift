import AppKit
import SwiftUI

/// 浮窗便签底色调色板。Note.colorIndex 直接存 rawValue。
/// 浅色模式用饱和度低的暖色,深色模式自动换成对应的暗色调,保证文字对比度。
enum StickyPalette: Int16, CaseIterable, Identifiable {
    case yellow = 0
    case pink
    case blue
    case green
    case purple
    case gray

    var id: Int16 { rawValue }

    static func from(index: Int16) -> StickyPalette {
        StickyPalette(rawValue: index) ?? .yellow
    }

    /// 存进 `SettingsKey.defaultColorIndex` 表示「随机默认色」的哨兵值 —— 取一个
    /// 不在 0..5(合法 rawValue)内的值。新建便签时 `resolveDefault` 看到它就每张
    /// 随机挑一个颜色。
    static let randomSentinel = -1

    /// 把 `defaultColorIndex` 解析成一个具体颜色:命中合法 rawValue(0..5)直接用;
    /// 等于随机哨兵或任何越界值,都随机挑一个 —— 所以「随机」是在**每次新建**时
    /// 现摇,而不是固定某色。
    static func resolveDefault(_ index: Int) -> StickyPalette {
        if let p = StickyPalette(rawValue: Int16(truncatingIfNeeded: index)) {
            return p
        }
        return allCases.randomElement() ?? .yellow
    }

    /// 用在 Menu / 列表里展示色名。LocKey 走 Localization.swift 集中翻译。
    var locKey: LocKey {
        switch self {
        case .yellow: return .colorYellow
        case .pink:   return .colorPink
        case .blue:   return .colorBlue
        case .green:  return .colorGreen
        case .purple: return .colorPurple
        case .gray:   return .colorGray
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? self.darkRGB : self.lightRGB
        }
    }

    private var lightRGB: NSColor {
        switch self {
        case .yellow: return NSColor(srgbRed: 1.00, green: 0.95, blue: 0.65, alpha: 1)
        case .pink:   return NSColor(srgbRed: 1.00, green: 0.84, blue: 0.88, alpha: 1)
        case .blue:   return NSColor(srgbRed: 0.78, green: 0.88, blue: 1.00, alpha: 1)
        case .green:  return NSColor(srgbRed: 0.80, green: 0.94, blue: 0.80, alpha: 1)
        case .purple: return NSColor(srgbRed: 0.90, green: 0.85, blue: 1.00, alpha: 1)
        case .gray:   return NSColor(srgbRed: 0.94, green: 0.94, blue: 0.94, alpha: 1)
        }
    }

    private var darkRGB: NSColor {
        switch self {
        case .yellow: return NSColor(srgbRed: 0.40, green: 0.36, blue: 0.20, alpha: 1)
        case .pink:   return NSColor(srgbRed: 0.45, green: 0.25, blue: 0.32, alpha: 1)
        case .blue:   return NSColor(srgbRed: 0.22, green: 0.32, blue: 0.48, alpha: 1)
        case .green:  return NSColor(srgbRed: 0.22, green: 0.40, blue: 0.28, alpha: 1)
        case .purple: return NSColor(srgbRed: 0.34, green: 0.28, blue: 0.48, alpha: 1)
        case .gray:   return NSColor(srgbRed: 0.28, green: 0.28, blue: 0.30, alpha: 1)
        }
    }
}
