import AppKit
import SwiftUI
import CoreData

/// 浮窗布局模式。
/// - normal:用户手动摆位置,registry 不干预。
/// - stack:cascade 排列,选中谁(windowDidBecomeKey)就把那张滑到 cascade 最下方
///         (最前最完整),其它自动重排。新增/关闭也自动 reflow。
/// - tile:平铺排列,用户拖动一张到新位置释放后,按拖到的位置在队列中重新排序
///        并重新平铺。新增/关闭也自动 reflow。
enum LayoutMode: String, CaseIterable {
    case normal, stack, tile

    var label: String {
        switch self {
        case .normal: return "Free Layout"
        case .stack:  return "Stack"
        case .tile:   return "Tile"
        }
    }

    var icon: String {
        switch self {
        case .normal: return "rectangle.3.group"
        case .stack:  return "square.stack.3d.up"
        case .tile:   return "square.grid.2x2"
        }
    }
}

/// 跟踪所有当前打开的悬浮便签,保证一条笔记最多一个浮窗。
final class FloatingNotesRegistry {
    private var windows: [NSManagedObjectID: FloatingNoteWindowController] = [:]
    /// 当前显示顺序。stack 模式下:[0] = cascade 最上方(最老/最旧选中的),
    /// 末尾 = cascade 最下方(最近选中的,最完整可见)。tile 模式下用作行序优先。
    /// 新窗 spawn 时 append;关闭时 remove;stack 模式下 windowDidBecomeKey
    /// 时移到末尾;tile 模式下用户拖动后按当前 frame 位置重排序。
    private var displayOrder: [NSManagedObjectID] = []
    /// AppDelegate 在 `applicationShouldTerminate` 里设为 true。退出时系统会
    /// 关掉所有 window,触发 windowWillClose → onClose,本来会把 isPinned 清掉,
    /// 下次启动 restore 就全 false。这个 flag 让 onClose 在退出阶段跳过 isPinned 写。
    var isTerminating = false

    /// 全局置顶开关。新窗按这个值设 level,toggle 时同步刷所有已开窗。
    /// 持久化在 UserDefaults,key 见 `floatOnTopKey`。
    private static let floatOnTopKey = "Noticky.floatOnTop"
    private(set) var floatOnTop: Bool = {
        // 默认 true,跟之前一直 .floating 的行为一致;旧用户升级感知不到差异。
        // Self 在 stored property initializer 里不可用,直接写类名。
        let key = FloatingNotesRegistry.floatOnTopKey
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }()

    /// 当前布局模式,UserDefaults 持久化。
    private static let layoutModeKey = "Noticky.layoutMode"
    private(set) var layoutMode: LayoutMode = {
        let raw = UserDefaults.standard.string(forKey: FloatingNotesRegistry.layoutModeKey) ?? ""
        return LayoutMode(rawValue: raw) ?? .normal
    }()

    func setFloatOnTop(_ value: Bool) {
        guard value != floatOnTop else { return }
        floatOnTop = value
        UserDefaults.standard.set(value, forKey: Self.floatOnTopKey)
        let level: NSWindow.Level = value ? .floating : .normal
        for wc in windows.values {
            wc.setLevel(level)
        }
    }

    /// 切换布局模式,持久化并立刻生效。设到 `.normal` 不会动当前位置,只是停止
    /// 后续 auto reflow,用户从此可以自由拖。
    func setLayoutMode(_ mode: LayoutMode) {
        guard mode != layoutMode else { return }
        layoutMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.layoutModeKey)
        applyLayout()
    }

    /// 按当前模式重排所有浮窗。`.normal` 是 no-op。
    /// AppDelegate 在启动 restore 完毕也会调一次,保证启动时回到上次的模式。
    func applyLayout() {
        switch layoutMode {
        case .normal: return
        case .stack:  applyStackLayout()
        case .tile:   applyTileLayout()
        }
    }

    /// macOS 经典 cascade。**保留每张原尺寸**,各张右边对齐;每张顶部比前一张
    /// 顶部低 `stepY`,按 displayOrder 排,index 0 在 cascade 最上方,末尾(最近
    /// 选中的)在最下方完整可见。z-order 按 displayOrder 依次 orderFront,最终
    /// 末尾那张在最前。
    private func applyStackLayout() {
        guard let screen = activeScreen() else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 16
        let stepY: CGFloat = 36
        let rightX = visible.maxX - margin

        let cascadeWCs = displayOrder.compactMap { windows[$0] }
        guard !cascadeWCs.isEmpty else { return }

        let firstTopY = visible.maxY - margin
        for (i, wc) in cascadeWCs.enumerated() {
            guard let frame = wc.currentFrame else { continue }
            let topY = firstTopY - CGFloat(i) * stepY
            let origin = NSPoint(x: rightX - frame.width, y: topY - frame.height)
            wc.animateFrame(NSRect(origin: origin, size: frame.size))
        }

        // z-order 重排:依次 orderFront,最后一个(最近选中的)在最前。
        for wc in cascadeWCs {
            wc.bringToFrontWithoutActivating()
        }
    }

    /// 平铺:**保留每张当前尺寸**,只重排位置。先按 displayOrder 决定迭代顺序;
    /// 但**用户拖动一张后会先把 displayOrder 按当前可视位置重排**,然后再 tile。
    /// 这样拖到哪儿,松手 reflow 后那张就在哪个 slot,其它顺移补位。
    /// shelf packing:左→右一行,装不下换行,行高 = 该行最高的那张。
    private func applyTileLayout() {
        guard let screen = activeScreen() else { return }
        let visible = screen.visibleFrame
        guard !windows.isEmpty else { return }

        let margin: CGFloat = 16
        let padding: CGFloat = 12
        let leftEdge = visible.minX + margin
        let rightLimit = visible.maxX - margin

        var x = leftEdge
        var rowTopY = visible.maxY - margin
        var rowMaxH: CGFloat = 0
        var anyInRow = false

        let tileWCs = displayOrder.compactMap { windows[$0] }
        for wc in tileWCs {
            guard let frame = wc.currentFrame else { continue }
            let w = frame.width
            let h = frame.height

            if anyInRow, x + w > rightLimit {
                x = leftEdge
                rowTopY -= rowMaxH + padding
                rowMaxH = 0
                anyInRow = false
            }

            let origin = NSPoint(x: x, y: rowTopY - h)
            wc.animateFrame(NSRect(origin: origin, size: frame.size))

            x += w + padding
            rowMaxH = max(rowMaxH, h)
            anyInRow = true
        }
    }

    /// 找操作目标屏:有 key 浮窗就用 key 所在屏,否则鼠标所在屏,再否则 main。
    private func activeScreen() -> NSScreen? {
        if let keyScreen = NSApp.keyWindow?.screen { return keyScreen }
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) { return s }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// 当前是否有任何浮窗(供菜单 enabled 状态用)。
    var hasOpenWindows: Bool { !windows.isEmpty }

    // MARK: 模式回调 ---------------------------------------------------------

    /// 浮窗 windowDidBecomeKey 转过来。stack 模式下,把这张挪到 displayOrder 末尾
    /// (= cascade 最下方 = 最完整可见),然后重排。tile 模式不动 —— 单纯点击不算
    /// 重新排序意图。
    fileprivate func notifyWindowBecameKey(id: NSManagedObjectID) {
        guard layoutMode == .stack else { return }
        guard displayOrder.contains(id) else { return }
        displayOrder.removeAll { $0 == id }
        displayOrder.append(id)
        applyStackLayout()
    }

    /// 用户结束拖动/缩放浮窗(非 animateFrame 触发的位移)。tile 模式下按当前
    /// 可视位置重排 displayOrder,再 reflow,实现「拖到哪儿就停在哪儿」。stack
    /// 模式下不重排,直接 reflow 把它弹回 cascade 位置。
    fileprivate func notifyUserMoveEnded(id: NSManagedObjectID) {
        switch layoutMode {
        case .normal:
            return
        case .stack:
            applyStackLayout()
        case .tile:
            sortDisplayOrderByCurrentPosition()
            applyTileLayout()
        }
    }

    /// 按浮窗当前 frame 的视觉位置(reading order:上→下,左→右)重排 displayOrder。
    /// tile 模式下用户拖动后用,把拖到的位置反映到队列顺序。
    private func sortDisplayOrderByCurrentPosition() {
        let rowThreshold: CGFloat = 40   // 顶边差距 < 40pt 视为同一行
        displayOrder.sort { a, b in
            guard let fa = windows[a]?.currentFrame, let fb = windows[b]?.currentFrame else { return false }
            if abs(fa.maxY - fb.maxY) > rowThreshold {
                return fa.maxY > fb.maxY  // 顶部更高的(maxY 更大)在前
            }
            return fa.minX < fb.minX        // 同行按左边
        }
    }

    /// 打开便签;若已打开,则把窗口提到最前。返回 true 表示创建了新窗口。
    @discardableResult
    func show(note: Note) -> Bool {
        let id = note.objectID
        if let wc = windows[id] {
            wc.bringToFront()
            return false
        }
        spawn(note: note, id: id)
        return true
    }

    /// 关闭便签(若已打开),否则打开。供「pin」按钮使用。
    func toggle(note: Note) {
        let id = note.objectID
        if let wc = windows[id] {
            wc.close()
            windows[id] = nil
            displayOrder.removeAll { $0 == id }
            note.isPinned = false
            try? note.managedObjectContext?.save()
            applyLayout()
        } else {
            spawn(note: note, id: id)
        }
    }

    /// 删除便签:有浮窗先无痕关掉(不走 windowWillClose,避免对已删对象写
    /// isPinned),再从 context 删除 + 保存。列表行和浮窗 ⋯ 菜单走同一入口。
    /// 真正的 context.delete 推到下一个 runloop tick —— 浮窗 SwiftUI 的
    /// `@ObservedObject note` 在同 tick 删除会收到属性变更通知并访问已 fault
    /// 的对象,触发 CoreData EXC_BREAKPOINT 崩溃。
    func delete(note: Note) {
        let id = note.objectID
        if let wc = windows[id] {
            wc.close()
            windows[id] = nil
            displayOrder.removeAll { $0 == id }
        }
        let context = note.managedObjectContext
        DispatchQueue.main.async {
            context?.delete(note)
            try? context?.save()
        }
        applyLayout()
    }

    private func spawn(note: Note, id: NSManagedObjectID) {
        // 已开浮窗的数量决定偏移量,启动批量恢复时多个浮窗会从中心向右下错开,
        // 避免全部叠在一个点上。模 8 防止越开越远直接出屏。
        let cascade = windows.count % 8
        let wc = FloatingNoteWindowController(
            note: note,
            initialLevel: floatOnTop ? .floating : .normal,
            onClose: { [weak self] in
                guard let self else { return }
                self.windows[id] = nil
                self.displayOrder.removeAll { $0 == id }
                guard !self.isTerminating else { return }
                note.isPinned = false
                try? note.managedObjectContext?.save()
                self.applyLayout()
            },
            onRequestDelete: { [weak self] in
                self?.delete(note: note)
            },
            onBecameKey: { [weak self] in
                self?.notifyWindowBecameKey(id: id)
            },
            onUserMoveEnded: { [weak self] in
                self?.notifyUserMoveEnded(id: id)
            }
        )
        wc.show(cascadeIndex: cascade)
        windows[id] = wc
        displayOrder.append(id)
        if !note.isPinned {
            note.isPinned = true
            try? note.managedObjectContext?.save()
        }
        applyLayout()
    }
}

/// .borderless 窗口默认拿不到 key/main,SwiftUI 编辑器就没法获取焦点输入。
/// 这个子类只是把两个 override 翻成 true。
final class StickyPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
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

final class FloatingNoteWindowController: NSObject, NSWindowDelegate {
    private let note: Note
    private let initialLevel: NSWindow.Level
    private let onClose: () -> Void
    private let onRequestDelete: () -> Void
    private let onBecameKey: () -> Void
    private let onUserMoveEnded: () -> Void
    private var window: NSWindow?
    /// 拖动/缩放期间会高频回调,debounce 250ms 避免每像素一次 SQL 写。
    private var pendingFrameSave: DispatchWorkItem?
    /// `animateFrame` 期间为 true,让 windowDidMove/Resize 知道这次位移是 registry
    /// 自动重排引发的,不要当成用户拖动触发模式 reflow,免得无限循环。
    private var isAnimating = false
    /// 真正的用户拖动结束信号:windowDidMove 高频回调,用 debounce 200ms 攒一次。
    private var pendingUserMove: DispatchWorkItem?

    init(
        note: Note,
        initialLevel: NSWindow.Level = .floating,
        onClose: @escaping () -> Void,
        onRequestDelete: @escaping () -> Void,
        onBecameKey: @escaping () -> Void = {},
        onUserMoveEnded: @escaping () -> Void = {}
    ) {
        self.note = note
        self.initialLevel = initialLevel
        self.onClose = onClose
        self.onRequestDelete = onRequestDelete
        self.onBecameKey = onBecameKey
        self.onUserMoveEnded = onUserMoveEnded
        super.init()
    }

    func setLevel(_ level: NSWindow.Level) {
        window?.level = level
    }

    /// 给 registry 用来匹配 NSApp.keyWindow 是不是这个 controller 持有的窗。
    func matches(window other: NSWindow) -> Bool {
        window === other
    }

    /// tile 时读当前 frame 决定每张笔记占多大。
    var currentFrame: NSRect? { window?.frame }

    /// stack 时按 cascade 顺序重排 z-order 用。`orderFront(nil)` 不改 key,只调
    /// z 层 —— 多个浮窗依次调一遍后,最后一个就在最前。
    func bringToFrontWithoutActivating() {
        window?.orderFront(nil)
    }

    /// 给 stack/tile 用的批量动画 setFrame。`window.animator()` 自带平滑过渡。
    /// 期间 `isAnimating = true`,windowDidMove/Resize 跳过 onUserMoveEnded
    /// 调度,避免自动 reflow 自己触发自己。
    func animateFrame(_ frame: NSRect) {
        guard let w = window else { return }
        isAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            w.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            // 加一拍延迟,等最后一次 windowDidMove 跑完再清 flag。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self?.isAnimating = false
            }
        })
    }

    func show(cascadeIndex: Int = 0) {
        guard let context = note.managedObjectContext else { return }

        let defaultSize = NSSize(width: 280, height: 280)
        let host = NSHostingController(
            rootView: FloatingNoteView(
                note: note,
                onClose: { [weak self] in
                    // borderless 窗口没有 .closable,performClose 是 no-op,
                    // 直接 close() 才会真关 + 触发 windowWillClose 让 registry 清 isPinned。
                    self?.window?.close()
                },
                onDelete: { [weak self] in
                    self?.onRequestDelete()
                }
            )
            .environment(\.managedObjectContext, context)
        )

        // borderless 拿到大圆角:窗体本身完全透明,圆角和阴影由 SwiftUI 内部
        // RoundedRectangle 决定。`.resizable` 仍能让边缘拖动 resize。
        let w = StickyPanel(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        w.level = initialLevel
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isMovableByWindowBackground = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.contentViewController = host
        // 同样的 NSHostingController 缩窗坑:必须在 contentViewController 赋值
        // 之后再 setContentSize 一次。不要叠加 .frame() / preferredContentSize。
        w.setContentSize(defaultSize)
        w.delegate = self
        w.isReleasedWhenClosed = false

        // 优先恢复用户上次的位置/尺寸;saved frame 越界(显示器拔了)就退回 cascade。
        if let saved = note.savedFrame, Self.frameIsOnVisibleScreen(saved) {
            w.setFrame(saved, display: false)
        } else if let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            let cascade = CGFloat(cascadeIndex) * 28
            let origin = NSPoint(
                x: screenFrame.midX - defaultSize.width / 2 + cascade,
                y: screenFrame.midY - defaultSize.height / 2 - cascade
            )
            w.setFrameOrigin(origin)
        }

        w.makeKeyAndOrderFront(nil)
        NSApp.activate()

        self.window = w
    }

    /// saved frame 至少跟某个屏幕的可见区有交集才算还能用。完全在屏幕外
    /// (比如多显示器拔了一台)就放弃恢复,走 cascade 重新摆。
    private static func frameIsOnVisibleScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
    }

    func windowDidMove(_ notification: Notification) {
        scheduleFrameSave()
        scheduleUserMoveCallback()
    }
    func windowDidResize(_ notification: Notification) {
        scheduleFrameSave()
        scheduleUserMoveCallback()
    }
    /// 浮窗变成 key window —— 用户点击它/系统给它焦点。stack 模式下让 registry
    /// 把它挪到 cascade 最下方。
    func windowDidBecomeKey(_ notification: Notification) {
        onBecameKey()
    }
    // 失焦的视觉变化(毛玻璃)由 FloatingNoteView 内 SwiftUI 用
    // `@Environment(\.controlActiveState)` 自动响应,不需要在 Controller 里调 alpha。

    private func scheduleFrameSave() {
        pendingFrameSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushFrameSave() }
        pendingFrameSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
    }

    /// 用户拖动/缩放结束的 debounced 回调。`isAnimating` 期间(registry 自己在
    /// 动画 setFrame)跳过 —— 那不是用户操作。否则攒 200ms 没新位移就触发,让
    /// registry 在 tile/stack 模式下做 reflow。
    ///
    /// 触发时还会检查 `NSEvent.pressedMouseButtons` —— 用户中途停顿(看一眼/想
    /// 一下,鼠标键还按着)不算结束。直接 reflow 会把窗口从用户手底下挪走,体感
    /// 是被「抢走鼠标」。鼠标键松开后再 reflow 才顺滑。
    private func scheduleUserMoveCallback() {
        guard !isAnimating else { return }
        pendingUserMove?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 鼠标还按着 → 用户没真松手,推到下一拍再看。
            if NSEvent.pressedMouseButtons != 0 {
                self.scheduleUserMoveCallback()
                return
            }
            self.onUserMoveEnded()
        }
        pendingUserMove = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200), execute: work)
    }

    private func flushFrameSave() {
        guard let w = window, let context = note.managedObjectContext else { return }
        // note 可能已经被删,跳过避免对 fault 对象写。
        guard !note.isDeleted else { return }
        note.setSavedFrame(w.frame)
        try? context.save()
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }

    func bringToFront() {
        guard let w = window else { return }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 拖完手立刻关窗的情况下,debounced 写还在排队 → 立刻取消并同步刷一次,
        // 不然 250ms 后来时窗口和 note 状态都没了。
        pendingFrameSave?.cancel()
        if let w = notification.object as? NSWindow, !note.isDeleted {
            note.setSavedFrame(w.frame)
            try? note.managedObjectContext?.save()
        }
        window = nil
        onClose()
    }
}

private struct FloatingNoteView: View {
    @ObservedObject var note: Note
    @Environment(\.managedObjectContext) private var context
    /// 当前窗口是否处于 key 状态:.key = 活跃,其它都按非活跃处理(渲染毛玻璃)。
    /// SwiftUI 自动跟踪这个 env value,key 状态变化会触发 body 重渲染,
    /// 拿到自由的「失焦动画」,不用手动监听 NSWindow 通知。
    @Environment(\.controlActiveState) private var controlActiveState
    /// 用户在设置面板里可关掉这个效果;@AppStorage 跨视图自动同步。
    @AppStorage(SettingsKey.fadeWhenInactive) private var fadeWhenInactive: Bool = true
    let onClose: () -> Void
    let onDelete: () -> Void

    private var palette: StickyPalette {
        guard !note.isDeleted, note.managedObjectContext != nil else { return .yellow }
        return StickyPalette.from(index: note.colorIndex)
    }

    /// 设置开了 fade,且当前窗确实失焦了,才进入毛玻璃态。
    /// fade 关掉时永远渲染实色,跟"经典"sticky 一致。
    private var isInactive: Bool {
        fadeWhenInactive && controlActiveState != .key
    }

    var body: some View {
        // 删除流程里浮窗已 orderOut 但 SwiftUI 视图树尚未释放;@ObservedObject
        // 会在 context.delete 那一刻被通知去重渲染。提前 guard 就不会访问已 fault
        // 的 note 属性 → 跳过 CoreData 的 debug breakpoint。
        if note.isDeleted || note.managedObjectContext == nil {
            EmptyView()
        } else {
            mainBody
        }
    }

    private var mainBody: some View {
        ZStack(alignment: .top) {
            // 卡片本体:活跃时实色填充,失焦时切到 .regularMaterial(NSVisualEffectView)
            // 毛玻璃 + 调色板色当 tint(opacity 0.45 让材质透出来)。
            // 窗体本身透明,系统阴影自动跟圆角形状走。
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(palette.color)
                    .opacity(isInactive ? 0.45 : 1.0)
            }
            .animation(.easeInOut(duration: 0.18), value: isInactive)

            VStack(spacing: 0) {
                Spacer().frame(height: 28)
                MarkdownNoteEditor(text: Binding(
                    get: { note.content },
                    set: { newValue in
                        guard newValue != note.content else { return }
                        note.content = newValue
                        note.updatedAt = Date()
                        try? context.save()
                    }
                ))
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }

            // 顶部标题条:始终可见,跟着 note.content 自动派生(`cleanTitle` 剥过
            // markdown 标记,`# 标题`、`**bold**`、列表前缀等都还原成纯文本)。
            // 跟 hover toolbar 在同一个顶部 strip,左右 padding 让出 ×/⋯ 按钮的位置,
            // hover 时三者并存不打架。空内容时 cleanTitle 为空字符串,Text 不显示。
            NoteTitleBar(text: note.cleanTitle)

            // 顶部 hover 工具条独立成一个 struct,**自己拥有 hovering @State** ——
            // hover 状态切换只让这个子 struct 重渲染,不会沿父链冒泡触发整个
            // FloatingNoteView 重渲染。否则任何鼠标进出窗都会让 MarkdownNoteEditor
            // 的 NSTextView updateNSView 被调,扰动中文 IME 的 marked text(拼音)。
            HoverToolbar(
                palette: palette,
                onClose: onClose,
                onPickColor: { picked in
                    note.colorIndex = picked.rawValue
                    note.updatedAt = Date()
                    try? context.save()
                },
                onDelete: onDelete
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// 浮窗顶部始终可见的标题条。空标题时不渲染任何东西(EmptyView),保持顶部
/// 28pt 留给 hover 工具条不挤压编辑器。文本居中、单行截断,左右各 32pt 给
/// `×` / `⋯` 按钮腾位置。
private struct NoteTitleBar: View {
    let text: String

    var body: some View {
        if text.isEmpty {
            EmptyView()
        } else {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.65))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 8)
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity)
                // 标题条不挡点击,不抢编辑器/按钮的事件。
                .allowsHitTesting(false)
        }
    }
}

/// 浮窗顶部 hover 工具条 + 全窗 hover 检测。`@State hovering` 在这里独立持有,
/// 状态变化不会冒泡到 FloatingNoteView,从而不让 MarkdownNoteEditor 重渲染。
private struct HoverToolbar: View {
    let palette: StickyPalette
    let onClose: () -> Void
    let onPickColor: (StickyPalette) -> Void
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var showColorPicker = false

    var body: some View {
        ZStack(alignment: .top) {
            // 全窗 hover 检测层:用 NSTrackingArea 自己的 NSView,不挡点击
            // (`hitTest` 返回 nil),整窗都能感知 mouseEntered/Exited。
            // SwiftUI `.onHover` 只能配合 hit-test 区域,要么挡点击要么覆盖不全 ——
            // 这层 NSView 走 AppKit 原生路线两全。
            HoverTracker(hovering: $hovering)
                .allowsHitTesting(false)

            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.hierarchical)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(NonDraggable())

                Spacer()

                Button {
                    showColorPicker.toggle()
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.hierarchical)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(NonDraggable())
                .popover(isPresented: $showColorPicker, arrowEdge: .top) {
                    NoteActionsBubble(
                        selected: palette,
                        onPickColor: { picked in
                            onPickColor(picked)
                            showColorPicker = false
                        },
                        onDelete: {
                            showColorPicker = false
                            onDelete()
                        }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .foregroundStyle(.primary.opacity(0.65))
            .opacity(hovering ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
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

private struct NoteActionsBubble: View {
    let selected: StickyPalette
    let onPickColor: (StickyPalette) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                ForEach(StickyPalette.allCases) { palette in
                    Button {
                        onPickColor(palette)
                    } label: {
                        Circle()
                            .fill(palette.color)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .stroke(palette == selected ? Color.accentColor : Color.black.opacity(0.15),
                                            lineWidth: palette == selected ? 2 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text("Delete note")
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
        .padding(10)
        .frame(minWidth: 180)
    }
}
