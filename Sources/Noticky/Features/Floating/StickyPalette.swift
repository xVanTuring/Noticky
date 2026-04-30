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
