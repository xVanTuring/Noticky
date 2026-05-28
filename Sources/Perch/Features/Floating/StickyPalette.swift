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
    /// 「炫彩」—— 不是单一颜色而是彩虹角度渐变。便签背景用柔和淡彩(`backgroundFill`),
    /// 选择器色块用鲜艳版(`swatchFill`)。其余纯色 case 的 fillStyle 退化成自己的实色。
    case rainbow

    var id: Int16 { rawValue }

    /// 是否「炫彩」渐变色 —— 渲染时要走渐变分支(没有单一 nsColor)。
    var isRainbow: Bool { self == .rainbow }

    /// 6 个纯色(不含炫彩),供「随机默认色」从中挑 —— 随机不该摇到炫彩这种特殊项。
    static var solidCases: [StickyPalette] { allCases.filter { $0 != .rainbow } }

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
        return solidCases.randomElement() ?? .yellow
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
        case .rainbow: return .colorRainbow
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
        // 炫彩没有单一色,任何走 nsColor 的兜底路径给个柔和中间紫,实际渲染走渐变。
        case .rainbow: return NSColor(srgbRed: 0.90, green: 0.86, blue: 1.00, alpha: 1)
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
        case .rainbow: return NSColor(srgbRed: 0.34, green: 0.30, blue: 0.48, alpha: 1)
        }
    }

    // MARK: - 炫彩渐变 --------------------------------------------------------
    //
    // 两套彩虹色环:`vivid` 给选择器色块(高饱和,显眼);非 vivid 给便签背景
    // (低饱和淡彩,跟现有 6 个柔和色一脉相承,正文文字仍可读)。都是 dynamic
    // NSColor,深浅色各一版。SwiftUI 走 `MeshGradient`(中心放柔和中性色,避免
    // AngularGradient 的尖锐汇聚点);AppKit 小图标走 `NSGradient` 线性扫一遍。

    private static func dyn(_ l: (Double, Double, Double), _ d: (Double, Double, Double)) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? d : l
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }

    /// 炫彩色环(红→橙→黄→绿→蓝→紫)。`vivid` 鲜艳 / 否则柔和。
    static func rainbowStops(vivid: Bool) -> [NSColor] {
        if vivid {
            return [
                dyn((1.00, 0.42, 0.45), (0.86, 0.32, 0.36)),
                dyn((1.00, 0.70, 0.32), (0.85, 0.56, 0.24)),
                dyn((1.00, 0.92, 0.38), (0.82, 0.74, 0.28)),
                dyn((0.46, 0.85, 0.52), (0.34, 0.68, 0.42)),
                dyn((0.40, 0.72, 1.00), (0.30, 0.55, 0.86)),
                dyn((0.72, 0.52, 1.00), (0.56, 0.40, 0.86)),
            ]
        } else {
            return [
                dyn((1.00, 0.86, 0.87), (0.44, 0.30, 0.33)),
                dyn((1.00, 0.91, 0.80), (0.45, 0.37, 0.26)),
                dyn((1.00, 0.97, 0.82), (0.43, 0.40, 0.26)),
                dyn((0.84, 0.95, 0.84), (0.28, 0.43, 0.31)),
                dyn((0.82, 0.90, 1.00), (0.26, 0.34, 0.49)),
                dyn((0.90, 0.85, 1.00), (0.37, 0.31, 0.49)),
            ]
        }
    }

    /// SwiftUI 3x3 网格渐变。相比 `AngularGradient`,中心点用一个柔和中性色,
    /// 避免 6 色全挤到 1 像素时产生的尖锐汇聚点。周围 8 点按顺时针铺彩虹色,
    /// 顶/底缺位用相邻两色 mix 填(pink = red⊕purple, indigo = blue⊕purple),
    /// 让色环过渡均匀。
    func meshGradient(vivid: Bool) -> MeshGradient {
        let stops = Self.rainbowStops(vivid: vivid).map { Color(nsColor: $0) }
        let r = stops[0], o = stops[1], y = stops[2]
        let g = stops[3], b = stops[4], p = stops[5]
        let pink = r.mix(with: p, by: 0.5)
        let indigo = b.mix(with: p, by: 0.5)
        // 中心点: 浅色模式接近暖白,深色模式给一个中性灰紫,刚好融化掉原本的尖点。
        let centerColor = Color(nsColor: Self.dyn(
            vivid ? (0.98, 0.95, 0.97) : (1.00, 0.98, 0.98),
            vivid ? (0.46, 0.40, 0.50) : (0.38, 0.34, 0.42)
        ))
        return MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0],   [0.5, 0],   [1, 0],
                [0, 0.5], [0.5, 0.5], [1, 0.5],
                [0, 1],   [0.5, 1],   [1, 1],
            ],
            colors: [
                r,    o,           y,
                pink, centerColor, g,
                p,    indigo,      b,
            ]
        )
    }

    /// SwiftUI 便签背景填充:纯色返回实色;炫彩返回**柔和**网格渐变(正文可读)。
    var backgroundFill: AnyShapeStyle {
        isRainbow ? AnyShapeStyle(meshGradient(vivid: false)) : AnyShapeStyle(color)
    }

    /// SwiftUI 色块/选择器/细色条填充:纯色返回实色;炫彩返回**鲜艳**网格渐变。
    var swatchFill: AnyShapeStyle {
        isRainbow ? AnyShapeStyle(meshGradient(vivid: true)) : AnyShapeStyle(color)
    }

    /// AppKit:用本色填充给定 path。纯色直接 setFill;炫彩用 `NSGradient` 斜扫一遍
    /// 彩虹(小图标/小色点上线性渐变就够「彩」了)。`vivid` 选鲜艳还是柔和。
    func fill(path: NSBezierPath, vivid: Bool) {
        if isRainbow, let g = NSGradient(colors: Self.rainbowStops(vivid: vivid)) {
            g.draw(in: path, angle: 45)
        } else {
            nsColor.setFill()
            path.fill()
        }
    }
}
