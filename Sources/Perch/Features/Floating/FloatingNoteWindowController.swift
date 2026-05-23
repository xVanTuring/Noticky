import AppKit
import SwiftUI
import CoreData

final class FloatingNoteWindowController: NSObject, NSWindowDelegate {
    /// 模块内可读 —— `FloatingNotesRegistry` 持久化 displayOrder 时要从打开的
    /// 窗反查对应 Note。其余外部不应改写。
    let note: Note
    private let initialLevel: NSWindow.Level
    private let initialCollectionBehavior: NSWindow.CollectionBehavior
    private let onClose: () -> Void
    private let onRequestDelete: () -> Void
    private let onRequestArchive: () -> Void
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
    /// 折叠/展开动画期间,把内容布局冻结在展开尺寸的共享状态(见 `FoldState`)。
    private let foldState = FoldState()
    /// 折叠/展开动画用的逐帧定时器。**手动 setFrame,不用 `animator()`** —— 见
    /// `toggleCollapse` 注释里的原因。
    private var foldTimer: Timer?
    private var foldFrom: NSRect = .zero
    private var foldTo: NSRect = .zero
    private var foldStartTime: CFTimeInterval = 0
    private let foldDuration: CFTimeInterval = 0.38

    /// 折叠状态下窗口高度,也是展开态顶部 strip(标题条 + hover 工具条 + 双击
    /// 命中层)的高度。两态共用同一个高度避免折叠时标题文字垂直位置发生跳变。
    /// 32pt 给 16pt 图标和 12pt 文字都留出 8/10pt 上下呼吸空间,顶部圆角不切字。
    static let collapsedHeight: CGFloat = 32

    init(
        note: Note,
        initialLevel: NSWindow.Level = .floating,
        initialCollectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary],
        onClose: @escaping () -> Void,
        onRequestDelete: @escaping () -> Void,
        onRequestArchive: @escaping () -> Void = {},
        onBecameKey: @escaping () -> Void = {},
        onUserMoveEnded: @escaping () -> Void = {}
    ) {
        self.note = note
        self.initialLevel = initialLevel
        self.initialCollectionBehavior = initialCollectionBehavior
        self.onClose = onClose
        self.onRequestDelete = onRequestDelete
        self.onRequestArchive = onRequestArchive
        self.onBecameKey = onBecameKey
        self.onUserMoveEnded = onUserMoveEnded
        super.init()
    }

    func setLevel(_ level: NSWindow.Level) {
        window?.level = level
    }

    func setCollectionBehavior(_ behavior: NSWindow.CollectionBehavior) {
        window?.collectionBehavior = behavior
    }

    /// 给 registry 用来匹配 NSApp.keyWindow 是不是这个 controller 持有的窗。
    func matches(window other: NSWindow) -> Bool {
        window === other
    }

    /// tile 时读当前 frame 决定每张笔记占多大。
    var currentFrame: NSRect? { window?.frame }

    /// 当前「逻辑尺寸」(展开态的 W/H):展开时就是窗口 frame 尺寸;折叠时窗口
    /// 高度被锁在 collapsedHeight,改读存档的展开 W/H(没存过则 nil)。给快捷键
    /// 循环尺寸判断当前落在哪个预设用。
    var currentExpandedSize: NSSize? {
        guard let w = window else { return nil }
        if note.isCollapsed {
            return note.hasSavedFrame ? NSSize(width: note.frameW, height: note.frameH) : nil
        }
        return w.frame.size
    }

    /// stack 时按 cascade 顺序重排 z-order 用。`orderFront(nil)` 不改 key,只调
    /// z 层 —— 多个浮窗依次调一遍后,最后一个就在最前。
    ///
    /// **必须跳过 hidden 窗** —— 否则 hideAll 走到一半时,被 hide 掉的窗会让
    /// 系统把 key 转给下一个可见窗,触发 windowDidBecomeKey → notifyWindowBecameKey
    /// → applyStackLayout,这里再 orderFront 所有 displayOrder 里的窗 → 刚 hide
    /// 掉的瞬间又被显示回来。要点很多次菜单才能全 hide 就是这个原因。
    func bringToFrontWithoutActivating() {
        guard let w = window, w.isVisible else { return }
        w.orderFront(nil)
    }

    /// 把窗口移到指定显示器:保留尺寸,落在该屏 visibleFrame 居中。带动画。
    /// 用于"切换显示器"操作 + 屏拓扑变化时把钉住的窗拉回来。
    func moveToScreen(_ screen: NSScreen) {
        guard let w = window else { return }
        let visible = screen.visibleFrame
        // 钉过来的目标尺寸:沿用当前窗口 frame 的尺寸,不动用户的 resize 结果。
        let size = w.frame.size
        // 钳到目标屏可见区内,避免万一窗本身就比屏大时还往外飞。
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        let origin = NSPoint(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2
        )
        animateFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)))
    }

    /// 给 stack/tile 用的批量动画 setFrame。`window.animator()` 自带平滑过渡。
    /// 期间 `isAnimating = true`,windowDidMove/Resize 跳过 onUserMoveEnded
    /// 调度,避免自动 reflow 自己触发自己。
    ///
    /// `completion` 在动画结束、`isAnimating` 清零之后再跑 —— 调用方(如尺寸预设
    /// resize)可以在这里安全触发 reflow:此时 `currentFrame` 已是最终尺寸,reflow
    /// 读到的是切换后的大小,不会拿到动画中途的帧。
    func animateFrame(_ frame: NSRect, completion: (() -> Void)? = nil) {
        guard let w = window else { completion?(); return }
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
                completion?()
            }
        })
    }

    func show(cascadeIndex: Int = 0) {
        guard let context = note.managedObjectContext else { return }

        // 没 savedFrame 时用 Settings → Notes 选的"默认尺寸"。已 saved 的便签不动,
        // 用户既然手动 resize 过就尊重那个尺寸。
        let defaultSizePref = DefaultNoteSize.from(
            UserDefaults.standard.string(forKey: SettingsKey.defaultNoteSize) ?? ""
        )
        let defaultSize = defaultSizePref.size
        let host = NSHostingController(
            rootView: FloatingNoteView(
                note: note,
                foldState: foldState,
                onClose: { [weak self] in
                    // borderless 窗口没有 .closable,performClose 是 no-op,
                    // 直接 close() 才会真关 + 触发 windowWillClose 让 registry 清 isPinned。
                    self?.window?.close()
                },
                onDelete: { [weak self] in
                    self?.onRequestDelete()
                },
                onArchive: { [weak self] in
                    self?.onRequestArchive()
                },
                onToggleCollapse: { [weak self] in
                    self?.toggleCollapse()
                },
                onPickSize: { [weak self] size in
                    self?.applyPresetSize(size)
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
        w.onDeleteShortcut = { [weak self] in self?.onRequestDelete() }
        w.level = initialLevel
        w.collectionBehavior = initialCollectionBehavior
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

        // 折叠态:压成 collapsedHeight,锚顶部 —— savedFrame 表示的是"展开尺寸",
        // 折叠时 top edge 保持在 savedFrame.maxY,这样展开时位置不会跳。同时
        // 摘掉 .resizable,折叠态拖边缘改高度没意义反而会乱状态。
        if note.isCollapsed {
            applyCollapsedFrame(to: w)
            w.styleMask.remove(.resizable)
        }

        w.makeKeyAndOrderFront(nil)
        NSApp.activate()

        self.window = w
    }

    /// 把窗口压到 collapsedHeight,顶部锚在当前 frame 的 maxY。**调用方负责管 styleMask**
    /// (折叠时 caller 该 remove(.resizable),展开时 insert 回去)。
    private func applyCollapsedFrame(to w: NSWindow) {
        let current = w.frame
        let topY = current.maxY
        var f = current
        f.size.height = Self.collapsedHeight
        f.origin.y = topY - Self.collapsedHeight
        w.setFrame(f, display: true)
    }

    /// ⋯ 菜单的尺寸预设:把窗口尺寸切到选中的预设。**左上角锚定**(minX 不动、
    /// 顶边 maxY 不动),宽高往右下长/缩 —— 跟用户从右下角拖 resize 的直觉一致。
    ///
    /// 折叠态特殊处理:高度被锁在 collapsedHeight,所以只动画**宽度**,并把预设的
    /// W/H 写进存档(`frameW/frameH` 存的就是「展开尺寸」),下次展开时用新尺寸。
    /// 展开态直接动画到预设全尺寸并存档。两条路径都走 `animateFrame`(它在动画期间
    /// 置 isAnimating,windowDidResize 不会把这次程序化 resize 误当用户拖动去 reflow)。
    func applyPresetSize(_ size: NSSize) {
        guard let w = window, let context = note.managedObjectContext else { return }
        guard !isAnimating else { return }
        let current = w.frame
        let topY = current.maxY

        if note.isCollapsed {
            // 存档展开尺寸 = 新预设;可见高度保持折叠,只动画宽度(左上角锚定)。
            note.frameX = Double(current.minX)
            note.frameY = Double(topY) - size.height
            note.frameW = Double(size.width)
            note.frameH = Double(size.height)
            note.hasSavedFrame = true
            try? context.save()
            let target = NSRect(x: current.minX, y: topY - Self.collapsedHeight,
                                width: size.width, height: Self.collapsedHeight)
            animateFrame(target) { [weak self] in self?.onUserMoveEnded() }
        } else {
            let target = NSRect(x: current.minX, y: topY - size.height,
                                width: size.width, height: size.height)
            // animateFrame 不写库;立刻存一次目标尺寸(debounced save 之后会再确认一次)。
            note.setSavedFrame(target)
            try? context.save()
            // 动画到位后触发 reflow —— tile/stack 模式下其它窗按新尺寸重新对齐。
            // normal 模式 onUserMoveEnded 是 no-op。
            animateFrame(target) { [weak self] in self?.onUserMoveEnded() }
        }
    }

    /// 双击标题 / ⋯ 菜单:折叠 ↔ 展开。带平滑动画,顶边锚定(top edge 不动)。
    ///
    /// **关键:用逐帧定时器手动 `setFrame`,绝不用 `window.animator().setFrame`。**
    /// animator 的窗口动画跑在 WindowServer(服务端),它把内容当成一张缓存位图去
    /// 缩放/流式播放,SwiftUI 的 CALayer(圆角裁剪、标题位置)不会逐帧重绘 →
    /// 表现为「圆角变直角 + 标题往上飘」(正是 docs/collapse-animation-attempts.md
    /// 里的撕裂)。改成自己用 Timer 在主线程逐帧 `setFrame(_:display:true)`(瞬时,
    /// 非动画):窗口尺寸和 SwiftUI 内容在同一拍更新,圆角/裁剪每帧重绘、严丝合缝。
    ///
    /// 内容这边由 `FoldState` 在动画期间冻结在展开高度(编辑器固定布局、绝不压缩),
    /// 只随窗口缩放被 host bounds 的 clipShape 裁剪 —— 折叠 = 从底部裁掉,展开 =
    /// 自上而下显出;卡片背景与圆角始终跟随 host bounds,故全程圆角 + 阴影正确。
    private func toggleCollapse() {
        guard let w = window else { return }
        // 动画进行中忽略重复触发,避免 frame 半路被打断错位。
        guard !isAnimating else { return }
        let nowCollapsed = !note.isCollapsed

        let current = w.frame
        let topY = current.maxY

        let expandedHeight: CGFloat
        let target: NSRect
        if nowCollapsed {
            // 折叠:高度 → collapsedHeight,顶部锚不变。内容冻结在当前展开高度。
            expandedHeight = current.height
            target = NSRect(x: current.minX, y: topY - Self.collapsedHeight,
                            width: current.width, height: Self.collapsedHeight)
        } else {
            // 展开:回到上次展开高度。foldState 里内容也按这个高度布局,窗口长大时
            // 自上而下显出。savedFrame 在折叠期间只更新位置、保留展开 W/H,直接读。
            let h = (note.savedFrame?.height).map { max($0, 80) } ?? 280
            let wdt = note.savedFrame?.width ?? current.width
            expandedHeight = h
            target = NSRect(x: current.minX, y: topY - h, width: wdt, height: h)
        }

        note.isCollapsed = nowCollapsed
        try? note.managedObjectContext?.save()

        // 进入折叠布局:编辑器冻结在展开高度;卡片高度从当前帧开始逐帧驱动。
        foldState.expandedHeight = expandedHeight
        foldState.currentHeight = current.height
        foldState.animating = true

        // 折叠态不可拖边 resize;展开态恢复。
        if nowCollapsed { w.styleMask.remove(.resizable) } else { w.styleMask.insert(.resizable) }

        isAnimating = true
        pendingFrameSave?.cancel()

        startFoldAnimation(from: current, to: target)
    }

    /// 逐帧驱动折叠/展开:Timer 按 wall-clock 进度算 easeInOut,每拍**瞬时**
    /// `setFrame`。加进 `.common` mode,保证菜单/拖动 tracking loop 期间也跑。
    private func startFoldAnimation(from: NSRect, to: NSRect) {
        foldTimer?.invalidate()
        foldFrom = from
        foldTo = to
        foldStartTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] t in
            guard let self, let w = self.window else { t.invalidate(); return }
            let raw = min(1.0, (CACurrentMediaTime() - self.foldStartTime) / self.foldDuration)
            let p = Self.easeInOut(CGFloat(raw))
            let f = NSRect(
                x: self.foldFrom.minX + (self.foldTo.minX - self.foldFrom.minX) * p,
                y: self.foldFrom.minY + (self.foldTo.minY - self.foldFrom.minY) * p,
                width: self.foldFrom.width + (self.foldTo.width - self.foldFrom.width) * p,
                height: self.foldFrom.height + (self.foldTo.height - self.foldFrom.height) * p
            )
            // 先驱动 SwiftUI 卡片高度(强制本帧重绘),再把窗口设到同尺寸 —— 两者
            // 同一拍更新,内容与窗口严丝合缝。
            self.foldState.currentHeight = f.height
            w.setFrame(f, display: true)
            if raw >= 1.0 {
                t.invalidate()
                self.foldTimer = nil
                self.finishFold()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        foldTimer = timer
    }

    private func finishFold() {
        foldState.animating = false
        // 动画收尾写回正确 saved frame(折叠时只更新位置、保留展开 W/H)。
        flushFrameSave()
        // 加一拍再清 isAnimating,等最后一次 windowDidResize 跑完。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.isAnimating = false
        }
    }

    private static func easeInOut(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
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

        if note.isCollapsed {
            // 折叠期间用户只能拖位置(高度被锁)。savedFrame 里的 W/H 保留为
            // "展开尺寸",别覆盖 —— 展开时还要靠它还原。位置:把 saved 的顶部
            // 边对齐到当前 frame 的顶部,这样下次展开时窗口 top 还是用户拖到的
            // 那个位置,不会跳。
            let savedH = note.frameH
            let topY = w.frame.maxY
            note.frameX = Double(w.frame.minX)
            note.frameY = Double(topY) - savedH
            note.hasSavedFrame = true
        } else {
            note.setSavedFrame(w.frame)
        }
        try? context.save()
    }

    func close() {
        foldTimer?.invalidate()
        foldTimer = nil
        window?.orderOut(nil)
        window = nil
    }

    /// 是否当前可见(orderFront 之后 = true,orderOut 之后 = false)。
    /// 跟 close() 不同 —— 这里 window 还活着,只是不显示。
    var isWindowVisible: Bool { window?.isVisible ?? false }

    /// 隐藏 / 重新显示。orderOut 不会触发 windowWillClose,所以 isPinned / saved
    /// frame 都保持原样;调用方下次 setHidden(false) 即可恢复。
    func setHidden(_ hidden: Bool) {
        guard let w = window else { return }
        if hidden {
            w.orderOut(nil)
        } else {
            w.orderFront(nil)
        }
    }

    func bringToFront() {
        guard let w = window else { return }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // 折叠动画还在跑就关窗:停掉定时器,免得它对已关窗 setFrame。
        foldTimer?.invalidate()
        foldTimer = nil
        // 拖完手立刻关窗的情况下,debounced 写还在排队 → 立刻取消并同步刷一次,
        // 不然 250ms 后来时窗口和 note 状态都没了。
        pendingFrameSave?.cancel()
        if let w = notification.object as? NSWindow, !note.isDeleted {
            // 同 flushFrameSave:折叠时只更新位置,保留展开 W/H。
            if note.isCollapsed {
                let savedH = note.frameH
                let topY = w.frame.maxY
                note.frameX = Double(w.frame.minX)
                note.frameY = Double(topY) - savedH
                note.hasSavedFrame = true
            } else {
                note.setSavedFrame(w.frame)
            }
            try? note.managedObjectContext?.save()
        }
        window = nil
        onClose()
    }
}

/// 折叠/展开动画期间,把内容布局「冻结」在展开尺寸的共享状态。
/// controller 持有并驱动,`FloatingNoteView` 观察。
/// - `animating == true`:内容按 `expandedHeight` 固定高度顶端对齐渲染,由窗口
///   当前尺寸裁剪。窗口 frame 动画是唯一驱动,SwiftUI 只跟随 host bounds 重裁、
///   不跑自己的动画,所以不会出现 docs/collapse-animation-attempts.md 里那种
///   「窗口 / 内容两条时间轴撕裂」。
/// - `animating == false`:内容正常填满 host(展开态可被用户拖动 resize;折叠态
///   就是 32pt 的标题条)。
final class FoldState: ObservableObject {
    @Published var animating = false
    /// 编辑器在动画期间冻结的高度(= 展开高度),保证文字不被压缩。
    @Published var expandedHeight: CGFloat = 280
    /// 动画当前帧的卡片高度。**逐帧显式改它**来强制 SwiftUI 重绘 —— 只改窗口
    /// frame / host bounds 不足以让 SwiftUI 每帧重画(它会合并/延后布局,表现为
    /// 「等一下然后瞬变」)。卡片背景 + 圆角裁剪绑这个值,故每帧都重画、平滑。
    @Published var currentHeight: CGFloat = 280
}
