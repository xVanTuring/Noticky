import AppKit
import SwiftUI
import CoreData

/// 跟踪所有当前打开的悬浮便签,保证一条笔记最多一个浮窗。
final class FloatingNotesRegistry {
    private var windows: [NSManagedObjectID: FloatingNoteWindowController] = [:]
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

    func setFloatOnTop(_ value: Bool) {
        guard value != floatOnTop else { return }
        floatOnTop = value
        UserDefaults.standard.set(value, forKey: Self.floatOnTopKey)
        let level: NSWindow.Level = value ? .floating : .normal
        for wc in windows.values {
            wc.setLevel(level)
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
            note.isPinned = false
            try? note.managedObjectContext?.save()
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
        }
        let context = note.managedObjectContext
        DispatchQueue.main.async {
            context?.delete(note)
            try? context?.save()
        }
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
                guard !self.isTerminating else { return }
                note.isPinned = false
                try? note.managedObjectContext?.save()
            },
            onRequestDelete: { [weak self] in
                self?.delete(note: note)
            }
        )
        wc.show(cascadeIndex: cascade)
        windows[id] = wc
        if !note.isPinned {
            note.isPinned = true
            try? note.managedObjectContext?.save()
        }
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
    private var window: NSWindow?
    /// 拖动/缩放期间会高频回调,debounce 250ms 避免每像素一次 SQL 写。
    private var pendingFrameSave: DispatchWorkItem?

    init(
        note: Note,
        initialLevel: NSWindow.Level = .floating,
        onClose: @escaping () -> Void,
        onRequestDelete: @escaping () -> Void
    ) {
        self.note = note
        self.initialLevel = initialLevel
        self.onClose = onClose
        self.onRequestDelete = onRequestDelete
        super.init()
    }

    func setLevel(_ level: NSWindow.Level) {
        window?.level = level
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

    func windowDidMove(_ notification: Notification) { scheduleFrameSave() }
    func windowDidResize(_ notification: Notification) { scheduleFrameSave() }
    // 失焦的视觉变化(毛玻璃)由 FloatingNoteView 内 SwiftUI 用
    // `@Environment(\.controlActiveState)` 自动响应,不需要在 Controller 里调 alpha。

    private func scheduleFrameSave() {
        pendingFrameSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushFrameSave() }
        pendingFrameSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: work)
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
    @State private var hovering = false
    @State private var showColorPicker = false
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

            // 顶部 hover 工具条:左 ×,右 ⋯。背景透明,贴在卡片顶部。
            // 用 .circle.fill 风格,跟参考图(经典 Stickies 红绿黄按钮)的视觉一致。
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
                            note.colorIndex = picked.rawValue
                            note.updatedAt = Date()
                            try? context.save()
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
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering = $0 }
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
