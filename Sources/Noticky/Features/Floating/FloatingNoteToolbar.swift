import AppKit
import SwiftUI

/// 浮窗顶部始终可见的标题条。空标题 + 没有 fallback 时不渲染(EmptyView),
/// 保持顶部 strip 留给 hover 工具条不挤压编辑器。`fallbackWhenEmpty` 给折叠
/// 态用 —— 没标题文字也得显示个占位符,否则折叠后是空 strip 用户看不到任何
/// 信息。文本居中、单行截断,左右各 32pt 给 × / ⋯ 按钮腾位置。
///
/// `stripHeight` 决定垂直居中的容器高度:展开态 28pt,折叠态 32pt。文本以
/// `.frame(height:, alignment: .center)` 居中,不再依赖 `.padding(.top, 8)`,
/// 这样折叠时整条 bar 内文字自然垂直居中。
struct NoteTitleBar: View {
    let text: String
    var fallbackWhenEmpty: String? = nil
    let stripHeight: CGFloat

    var body: some View {
        let display = text.isEmpty ? (fallbackWhenEmpty ?? "") : text
        let isFallback = text.isEmpty && fallbackWhenEmpty != nil

        if display.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                Text(display)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(isFallback ? 0.4 : 0.65))
                    .italic(isFallback)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: stripHeight, alignment: .center)
                Spacer(minLength: 0)
            }
            // 标题条不挡点击,不抢编辑器/按钮/双击 hit 区的事件。
            .allowsHitTesting(false)
        }
    }
}

/// 标题条上的双击命中层。catch mouseDown:clickCount==2 → 触发 onDoubleClick;
/// 单击 + 真位移 → `window.performDrag(with:)` 转交给系统拖窗 —— 这样这块区域既能
/// 双击折叠/展开,又不挡用户拖动整个浮窗。
///
/// **关键:performDrag 只能等 mouseDragged 累计位移超过阈值再调**。直接在第一次
/// mouseDown 就 performDrag,触摸板的微抖动会瞬间触发 windowDidMove,导致
/// stack/tile layout 模式的 reflow 跟双击折叠动画打架(出现折一半/卡住的视觉
/// bug)。设 4pt 阈值,小于这个就当用户没动 —— 双击间隙的颤抖不算拖。
///
/// 在 ZStack 里**必须放在 HoverToolbar 之下** —— 上层的 × / ⋯ 按钮要先吃到点击。
/// 自身限定 ~28pt 高顶部条,不会下探到编辑器区域。
struct TitleDoubleClickHit: NSViewRepresentable {
    let onDoubleClick: () -> Void

    final class HitView: NSView {
        var onDoubleClick: (() -> Void)?
        /// 当前一次 mouseDown 的原始事件,等到 mouseDragged 越过阈值时拿它当
        /// performDrag 的 anchor。判定为双击 / mouseUp 后清空。
        private var pendingDownEvent: NSEvent?
        private var downLocation: NSPoint = .zero
        private static let dragThreshold: CGFloat = 4

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                pendingDownEvent = nil
                onDoubleClick?()
                return
            }
            pendingDownEvent = event
            downLocation = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down = pendingDownEvent else { return }
            let dx = event.locationInWindow.x - downLocation.x
            let dy = event.locationInWindow.y - downLocation.y
            if dx * dx + dy * dy >= Self.dragThreshold * Self.dragThreshold {
                pendingDownEvent = nil
                // performDrag 进 modal 循环直到 mouseUp;期间 windowDidMove 正常触发,
                // 用户是真在拖,reflow 应该走。
                window?.performDrag(with: down)
            }
        }

        override func mouseUp(with event: NSEvent) {
            pendingDownEvent = nil
        }
    }

    func makeNSView(context: Context) -> HitView {
        let v = HitView()
        v.onDoubleClick = onDoubleClick
        return v
    }

    func updateNSView(_ nsView: HitView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }
}

/// 浮窗顶部 hover 工具条 + 全窗 hover 检测。`@State hovering` 在这里独立持有,
/// 状态变化不会冒泡到 FloatingNoteView,从而不让 MarkdownNoteEditor 重渲染。
///
/// 按钮一律 hover-only:鼠标进入浮窗才显示 × / 铃铛 / ⋯,移出即隐藏 ——
/// 折叠态和展开态行为一致(`isCollapsed` 仍传入,只用于 ⋯ 菜单里折叠/展开项的
/// 文案与图标)。已设提醒的铃铛例外,始终常驻当状态标记。
struct HoverToolbar: View {
    let palette: StickyPalette
    let isCollapsed: Bool
    /// 顶部 strip 高度:展开 28pt / 折叠 32pt。HStack 用它做 frame 高度 + 居中。
    let stripHeight: CGFloat
    /// 当前 note 的 reminderDate(可能 nil / 过去 / 未来)。决定铃铛是 outline
    /// 还是 fill,以及是否「无 hover 也常驻显示」(已设提醒时铃铛是状态标记)。
    let reminderDate: Date?
    let onClose: () -> Void
    let onPickColor: (StickyPalette) -> Void
    let onToggleCollapse: () -> Void
    let onDelete: () -> Void
    let onArchive: () -> Void
    let onSetReminder: (Date) -> Void
    let onClearReminder: () -> Void
    @State private var hovering = false
    @State private var showReminderPicker = false

    /// 是否有「已设」提醒(过去/未来都算 —— 用户至少要看到铃铛常驻才能知道
    /// 还有遗留提醒可以清掉)。
    private var hasReminder: Bool { reminderDate != nil }

    /// 按钮只在 hover 时显示 —— 折叠态和展开态行为一致。
    private var buttonsVisible: Bool { hovering }

    /// 颜色选择 Picker 的双向绑定:读当前 palette,写时回调 onPickColor。
    private var colorSelection: Binding<StickyPalette> {
        Binding(get: { palette }, set: { onPickColor($0) })
    }

    var body: some View {
        ZStack(alignment: .top) {
            // 全窗 hover 检测层:用 NSTrackingArea 自己的 NSView,不挡点击
            // (`hitTest` 返回 nil),整窗都能感知 mouseEntered/Exited。
            // SwiftUI `.onHover` 只能配合 hit-test 区域,要么挡点击要么覆盖不全 ——
            // 这层 NSView 走 AppKit 原生路线两全。
            HoverTracker(hovering: $hovering)
                .allowsHitTesting(false)

            HStack(spacing: 6) {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.hierarchical)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(NonDraggable())
                .opacity(buttonsVisible ? 1 : 0)

                Spacer()

                // 铃铛:hover 时和「已设提醒」时都显示。fill 图标 + 强调色 = 设了。
                // outline + 默认色 = 没设(只在 hover 期间出现)。
                // 圆形底:hasReminder 时铃铛常驻顶部,长标题截尾会撞到这里 ——
                // 给个半透明 + 毛玻璃的圆底把标题文本盖住,避免视觉重叠。
                // .ultraThinMaterial 在 palette 色底上自然糊一层,既能遮字
                // 又不会像实色圆点那么突兀。
                Button {
                    showReminderPicker.toggle()
                } label: {
                    Image(systemName: hasReminder ? "bell.fill" : "bell")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(hasReminder ? Color.accentColor : Color.primary.opacity(0.65))
                        .contentShape(Rectangle())
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .background(NonDraggable())
                .opacity(buttonsVisible || hasReminder ? 1 : 0)
                .popover(isPresented: $showReminderPicker, arrowEdge: .top) {
                    ReminderPicker(
                        currentReminder: reminderDate,
                        onSet: { date in
                            showReminderPicker = false
                            onSetReminder(date)
                        },
                        onClear: {
                            showReminderPicker = false
                            onClearReminder()
                        },
                        onCancel: {
                            showReminderPicker = false
                        }
                    )
                }

                // 动作菜单改用原生 Menu(NSMenu),不再用 popover。NSMenu 在自己的
                // 事件追踪循环里开关,选中项后菜单同步消失、动作立刻执行 —— 不像
                // NSPopover 那样有一段独立子窗口的 dismiss 动画,会和折叠时改父窗 frame
                // 打架(内容先掉窗底再瞬移回顶)。换 NSMenu 后折叠不再需要任何延迟兜底。
                Menu {
                    Picker(selection: colorSelection) {
                        ForEach(StickyPalette.allCases) { p in
                            Image(systemName: "circle.fill")
                                .tint(p.color)
                                .tag(p)
                        }
                    } label: {
                        Text(L.t(.noteColor))
                    }
                    .pickerStyle(.palette)

                    Divider()

                    Button(action: onToggleCollapse) {
                        Label(
                            isCollapsed ? L.t(.floatExpand) : L.t(.floatCollapse),
                            systemImage: isCollapsed ? "chevron.down" : "chevron.up"
                        )
                    }
                    Button(action: onArchive) {
                        Label(L.t(.floatArchive), systemImage: "archivebox")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label(L.t(.floatDelete), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.hierarchical)
                        .contentShape(Rectangle())
                }
                // .button menu style + .plain button style 让触发器渲染成纯图标,
                // 跟 × / 铃铛(都是 .buttonStyle(.plain))一致,不带 bezel/高亮。
                // .borderlessButton 会自己画一层底,显得比其它按钮突兀。
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .background(NonDraggable())
                .opacity(buttonsVisible ? 1 : 0)
            }
            .padding(.horizontal, 8)
            // 用固定 stripHeight + center 对齐替换原先的 `.padding(.top, 6)` ——
            // 折叠态 32pt 下按钮自然垂直居中(原方案 6pt top padding 留出底部空白)。
            // 外层 ZStack(alignment: .top) 负责把整个 HStack 锚到窗顶。
            .frame(height: stripHeight, alignment: .center)
            .foregroundStyle(.primary.opacity(0.65))
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// 配合 `isMovableByWindowBackground = true` 使用:NSHostingView 不知道 SwiftUI
/// Button 区域是控件,默认整窗都允许背景拖动,Button 的 mouseDown 被吞掉
/// 当成拖窗事件 → 点了没反应。把这个表示为 .background 垫在按钮下,系统
/// 看到 mouseDownCanMoveWindow = false 就会把事件正常下发。
private struct NonDraggable: NSViewRepresentable {
    final class View: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
    func makeNSView(context: Context) -> NSView { View() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 全窗 hover 检测的隐形 NSView。NSTrackingArea 走 AppKit 原生 mouse enter/exit,
/// `hitTest` 返回 nil 让点击穿透到下面的 SwiftUI 编辑器。`@Binding hovering` 把
/// AppKit 端的 enter/exit 事件转成 SwiftUI state(只反映在 HoverToolbar 内部)。
private struct HoverTracker: NSViewRepresentable {
    @Binding var hovering: Bool

    final class TrackerView: NSView {
        var onHoverChange: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for ta in trackingAreas { removeTrackingArea(ta) }
            // .inVisibleRect:tracking area 跟着 view 可见区域走,不需要手动维护 rect。
            // .activeInActiveApp:只在 App 活跃时跟踪,失活了不发杂事件。
            let ta = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(ta)
        }

        override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
        override func mouseExited(with event: NSEvent)  { onHoverChange?(false) }

        // 不挡点击 —— 编辑器在我们下面,要能拿到 mouseDown。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> TrackerView {
        let v = TrackerView()
        v.onHoverChange = { newValue in
            // tracking 回调可能在非 main 走;SwiftUI state 必须 main 设。
            DispatchQueue.main.async { hovering = newValue }
        }
        return v
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {
        // 闭包持有的是 binding 的当前 setter,binding 每次重建都更新一下避免持引用旧版。
        nsView.onHoverChange = { newValue in
            DispatchQueue.main.async { hovering = newValue }
        }
    }
}
