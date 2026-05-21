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
        case .normal: return L.t(.layoutFree)
        case .stack:  return L.t(.layoutStack)
        case .tile:   return L.t(.layoutTile)
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
    /// 单实例引用。所有权在 AppDelegate 的 `private let floating`(全程存活),
    /// 这里 weak —— 不延长生命周期。给没有注入路径的地方(Settings →
    /// 「清空全部内容」)拿到 registry 去同步关浮窗用。
    static weak var shared: FloatingNotesRegistry?

    init() { FloatingNotesRegistry.shared = self }

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

    /// menubar 入口:把所有当前打开的浮窗都移到给定 UUID 的显示器。屏不存在
    /// 直接 no-op。一次性动作 —— 不持久化,关掉浮窗再开仍按 savedFrame 摆。
    /// `floatOnTop=on` 时浮窗跨 Space,但跨屏要主动 setFrame。
    ///
    /// 尊重当前 layout 模式:
    /// - stack / tile:直接在目标屏上重新摆 layout(原模式的视觉规则保留)。
    /// - normal:每窗按其相对源屏 visibleFrame 的偏移映射到目标屏,避免全部
    ///   挤到同一点;源屏推不出来就退化为目标屏居中。
    func moveAllToDisplay(uuid: String) {
        guard let target = DisplayCatalog.screen(forUUID: uuid) else { return }
        switch layoutMode {
        case .stack, .tile:
            applyLayout(onScreen: target)
        case .normal:
            for wc in windows.values {
                translateToScreen(wc, target: target)
            }
        }
    }

    /// normal 模式下的"搬家":保留每窗在源屏 visibleFrame 内的相对位置,等比
    /// 映射到目标屏。源屏识别失败 → 居中兜底。**保留尺寸**,目标屏装不下时
    /// 钳到可见区。
    private func translateToScreen(_ wc: FloatingNoteWindowController, target: NSScreen) {
        guard let frame = wc.currentFrame else { return }
        let source = Self.dominantScreen(for: frame)
        let tv = target.visibleFrame
        // 没源屏 / 源屏就是目标屏 → 不动。后者重要:用户已经在目标屏的窗别瞎搬。
        guard let source, source !== target else { return }
        let sv = source.visibleFrame

        let relX = (frame.minX - sv.minX) / max(sv.width, 1)
        let relY = (frame.minY - sv.minY) / max(sv.height, 1)
        var newOrigin = NSPoint(
            x: tv.minX + relX * tv.width,
            y: tv.minY + relY * tv.height
        )
        // 钳到目标屏可见区:窗顶不能跑到屏外,左边不能贴出屏。
        let maxX = tv.maxX - min(frame.width, tv.width)
        let maxY = tv.maxY - min(frame.height, tv.height)
        newOrigin.x = min(max(newOrigin.x, tv.minX), maxX)
        newOrigin.y = min(max(newOrigin.y, tv.minY), maxY)
        wc.animateFrame(NSRect(origin: newOrigin, size: frame.size))
    }

    /// NSRect 交集面积,用来挑"窗主要落在哪块屏"。
    private static func intersectionArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let r = a.intersection(b)
        return max(0, r.width) * max(0, r.height)
    }

    func setFloatOnTop(_ value: Bool) {
        guard value != floatOnTop else { return }
        floatOnTop = value
        UserDefaults.standard.set(value, forKey: Self.floatOnTopKey)
        let level: NSWindow.Level = value ? .floating : .normal
        let behavior = Self.collectionBehavior(floatOnTop: value)
        for wc in windows.values {
            wc.setLevel(level)
            wc.setCollectionBehavior(behavior)
        }
    }

    /// 浮窗的 collectionBehavior 跟随 `floatOnTop`:
    /// - on:`[.canJoinAllSpaces, .fullScreenAuxiliary]` —— 跨所有 Space 显示,
    ///   并在其它 App 的全屏空间里也浮在上面。
    /// - off:`[]`(默认)—— 留在创建时所在的 Space,其它 App 进入全屏时
    ///   不会跑到全屏内容上面。
    /// 单独动 `window.level` 不够 —— `.fullScreenAuxiliary` 会让任何 level 的
    /// 窗都浮到全屏 Space 上,所以关置顶必须同时摘掉 collectionBehavior。
    static func collectionBehavior(floatOnTop: Bool) -> NSWindow.CollectionBehavior {
        floatOnTop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
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
    /// `onScreen` 显式给定时(menubar「移到屏 X」),layout 锚到这块屏;
    /// 否则按 activeScreen() 推断(key 窗 → 鼠标 → main)。
    func applyLayout(onScreen: NSScreen? = nil) {
        switch layoutMode {
        case .normal: return
        case .stack:  applyStackLayout(onScreen: onScreen)
        case .tile:   applyTileLayout(onScreen: onScreen)
        }
    }

    /// macOS 经典 cascade。**保留每张原尺寸**,各张右边对齐;每张顶部比前一张
    /// 顶部低 `stepY`,按 displayOrder 排,index 0 在 cascade 最上方,末尾(最近
    /// 选中的)在最下方完整可见。z-order 按 displayOrder 依次 orderFront,最终
    /// 末尾那张在最前。
    private func applyStackLayout(onScreen: NSScreen? = nil) {
        guard let screen = onScreen ?? activeScreen() else { return }
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
    private func applyTileLayout(onScreen: NSScreen? = nil) {
        guard let screen = onScreen ?? activeScreen() else { return }
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

    /// 找操作目标屏:**已经有浮窗的话,锁定在"最老浮窗所在屏"** —— 用户用
    /// menubar "Move All to Display X" 之后,最老那张也在 X,后续 spawn (New Note)
    /// 触发的 applyLayout 会继续锚在 X,不会因为鼠标当时在 Y 屏菜单上又把所有窗
    /// 拉到 Y。没浮窗时退化回旧 heuristic:key → 鼠标 → main。
    private func activeScreen() -> NSScreen? {
        if let oldestID = displayOrder.first,
           let wc = windows[oldestID],
           let frame = wc.currentFrame,
           let screen = Self.dominantScreen(for: frame) {
            return screen
        }
        if let keyScreen = NSApp.keyWindow?.screen { return keyScreen }
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) { return s }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// 给定一个 NSWindow 的 frame,推断它主要落在哪块屏(取交集面积最大的那块)。
    /// 跨屏窗用面积选主屏,避免归错。
    private static func dominantScreen(for frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            intersectionArea(a.frame, frame) < intersectionArea(b.frame, frame)
        }
    }

    /// 当前是否有任何浮窗(供菜单 enabled 状态用)。
    var hasOpenWindows: Bool { !windows.isEmpty }

    /// 至少有一个窗口当前可见(供菜单标签从 Hide ↔ Show 切换用)。
    var hasVisibleWindow: Bool {
        windows.values.contains { $0.isWindowVisible }
    }

    /// 把所有当前 spawn 的浮窗 orderOut。**不走 close()** —— 不释放 wc、不触发
    /// windowWillClose、不清 isPinned,只是视觉上藏起来。再调 showAll() 一键现身。
    func hideAll() {
        for wc in windows.values {
            wc.setHidden(true)
        }
    }

    /// 显示**所有未删除的笔记**为浮窗 —— 不管之前 pinned 与否、是否已被关闭过。
    /// 已 spawn 的会被 bringToFront(把 hidden 的也带回来);没 spawn 的 spawn。
    /// menubar "Show All Stickies" 的入口,语义是"把库里所有便签都显示出来"。
    func showAll(in context: NSManagedObjectContext) {
        let request = NSFetchRequest<Note>(entityName: "Note")
        // 不显示归档笔记 —— "显示所有便签" 只针对活跃笔记。
        request.predicate = NSPredicate(
            format: "isTrashed == %@ AND isArchived == %@",
            NSNumber(value: false), NSNumber(value: false)
        )
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        guard let notes = try? context.fetch(request) else { return }
        for note in notes {
            // show() 内部:已 spawn 则 bringToFront(makeKeyAndOrderFront 把 hidden
            // 的也变可见);新的走 spawn,会自动设 isPinned = true 进入 displayOrder。
            show(note: note)
        }
    }

    // MARK: 模式回调 ---------------------------------------------------------

    /// 浮窗 windowDidBecomeKey 转过来。stack 模式下,把这张挪到 displayOrder 末尾
    /// (= cascade 最下方 = 最完整可见),然后重排。tile 模式不动 —— 单纯点击不算
    /// 重新排序意图。
    fileprivate func notifyWindowBecameKey(id: NSManagedObjectID) {
        guard layoutMode == .stack else { return }
        guard displayOrder.contains(id) else { return }
        displayOrder.removeAll { $0 == id }
        displayOrder.append(id)
        // 用户在哪屏点的窗,cascade 就锚到哪屏 —— 不让 activeScreen 的 oldest 偏好
        // 把刚拖到新屏的窗弹回去。
        applyStackLayout(onScreen: screenForWindow(id: id))
    }

    /// 用户结束拖动/缩放浮窗(非 animateFrame 触发的位移)。tile 模式下按当前
    /// 可视位置重排 displayOrder,再 reflow,实现「拖到哪儿就停在哪儿」。stack
    /// 模式下不重排,直接 reflow 把它弹回 cascade 位置。
    ///
    /// **关键**:layout 锚到"被拖窗当前所在屏",而不是 activeScreen 默认的
    /// "最老窗所在屏" —— 用户拖到新屏就是想让整组跟过去,锁回去等于撤销操作。
    fileprivate func notifyUserMoveEnded(id: NSManagedObjectID) {
        let draggedScreen = screenForWindow(id: id)
        switch layoutMode {
        case .normal:
            return
        case .stack:
            applyStackLayout(onScreen: draggedScreen)
        case .tile:
            sortDisplayOrderByCurrentPosition()
            applyTileLayout(onScreen: draggedScreen)
        }
    }

    /// 给定 objectID 查浮窗当前所在屏。窗已关 / 算不出来都返回 nil,layout
    /// 会回退到 activeScreen 默认逻辑。
    private func screenForWindow(id: NSManagedObjectID) -> NSScreen? {
        guard let frame = windows[id]?.currentFrame else { return nil }
        return Self.dominantScreen(for: frame)
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

    /// 软删除:把笔记打进回收站。有浮窗先无痕关掉,清 isPinned(回收站里的
    /// 笔记不再算"开机自动恢复"对象),写 isTrashed = true + trashedAt = now。
    /// 真正的 context.delete 由 Trash 视图的"彻底删除/清空"或启动时的 30 天
    /// 过期 purge 完成。
    ///
    /// 入口跟之前 hard-delete 完全一致(列表右键、浮窗 ⋯ 菜单、⌘D),所以
    /// 调用方代码没改,只是行为变成"进回收站"。
    func delete(note: Note) {
        let id = note.objectID
        if let wc = windows[id] {
            wc.close()
            windows[id] = nil
            displayOrder.removeAll { $0 == id }
        }
        let context = note.managedObjectContext
        // 进回收站时撤掉提醒。reminderDate 字段保留,用户从回收站恢复时 UI
        // 仍能显示原本设的时间;若那时已过则按"过期"处理。
        ReminderScheduler.shared.cancel(noteID: note.id)
        // 同样推到下一个 runloop tick —— 跟 hard-delete 一样,@ObservedObject
        // 在同 tick 内 mutate isTrashed 也会触发 SwiftUI 重渲染访问 fault 对象;
        // 推一拍让 orderOut 先生效,SwiftUI 树释放后再写库。
        DispatchQueue.main.async {
            note.isPinned = false
            note.isTrashed = true
            note.trashedAt = Date()
            // 回收站优先级高于归档:把归档笔记移入回收站时清掉归档态,
            // 保证三态(活跃 / 归档 / 回收站)始终互斥。
            note.isArchived = false
            note.archivedAt = nil
            try? context?.save()
        }
        applyLayout()
    }

    /// 把回收站里的笔记还原回正常列表。不重新打开浮窗 —— 用户想看就自己点 Open。
    func restore(note: Note) {
        DispatchQueue.main.async {
            note.isTrashed = false
            note.trashedAt = nil
            try? note.managedObjectContext?.save()
        }
    }

    /// 归档:把笔记移出活跃列表但保留(不删除、永不过期自动清)。有浮窗先
    /// 无痕关掉,清 isPinned(归档的不再算开机自动恢复),撤掉提醒(跟进
    /// 回收站一致 —— 收起来就别再弹;reminderDate 字段保留,取消归档后 UI
    /// 仍能看到原设时间)。写 isArchived = true + archivedAt = now。
    /// 入口:浮窗 ⋯ 菜单、Manager 侧边栏右键。
    func archive(note: Note) {
        let id = note.objectID
        if let wc = windows[id] {
            wc.close()
            windows[id] = nil
            displayOrder.removeAll { $0 == id }
        }
        let context = note.managedObjectContext
        ReminderScheduler.shared.cancel(noteID: note.id)
        // 推到下一个 runloop tick —— 跟 delete 同理:@ObservedObject 在同
        // tick 内 mutate isArchived 也会触发 SwiftUI 重渲染访问 fault 对象;
        // 推一拍让 orderOut 先生效,SwiftUI 树释放后再写库。
        DispatchQueue.main.async {
            note.isPinned = false
            note.isArchived = true
            note.archivedAt = Date()
            try? context?.save()
        }
        applyLayout()
    }

    /// 取消归档:回到活跃列表。不重新打开浮窗 —— 用户想看自己点 Open
    /// (跟从回收站 restore 行为一致)。
    func unarchive(note: Note) {
        DispatchQueue.main.async {
            note.isArchived = false
            note.archivedAt = nil
            try? note.managedObjectContext?.save()
        }
    }

    /// 真删一条:回收站里的"彻底删除"按钮走这条。直接 context.delete + save。
    /// 浮窗已经在 trash 时关掉了,这里不需要再处理。
    func deletePermanently(note: Note) {
        let context = note.managedObjectContext
        ReminderScheduler.shared.cancel(noteID: note.id)
        DispatchQueue.main.async {
            context?.delete(note)
            try? context?.save()
        }
    }

    /// 清空回收站:fetch 所有 isTrashed == true 的笔记,逐条 delete + save 一次。
    /// 用 batch delete 也行,但要手动 merge changes 进 viewContext —— 量级小,
    /// 走 context.delete 简单稳妥。
    ///
    /// `main.async` 推一拍是为了让 alert 收起动画与删除分到不同 runloop tick,
    /// 与 trash/restore/deletePermanently 保持一致。**真正防 SIGTRAP 的是
    /// TrashDetailView 把 ForEach 的 id 改成 `\.objectID`** —— 删 N 条 + save 同
    /// tick 时,SwiftUI 的 List diff 会用旧列表里每个 Note 的 id keypath,
    /// `\.id` 读非可选 UUID 在已 fault 的对象上会 bridging 崩溃,`objectID`
    /// 是 NSManagedObject 自身的 Swift 属性所以一直可读。
    func emptyTrash(in context: NSManagedObjectContext) {
        let request = Note.trashedFetchRequest()
        guard let trashed = try? context.fetch(request) else { return }
        // delete(note:) 在进回收站时已经 cancel 过了,但用户跨设备同步 / 旧库
        // 残留的提醒可能还挂着,这里再扫一遍兜底。
        for note in trashed {
            ReminderScheduler.shared.cancel(noteID: note.id)
        }
        DispatchQueue.main.async {
            for note in trashed {
                context.delete(note)
            }
            try? context.save()
        }
    }

    /// 清空全部内容:删掉**所有** Note(活跃 / 归档 / 回收站全包含)+ 所有
    /// NoteGroup。设置 / 偏好(UserDefaults)一概不动。**不可撤销** —— 调用方
    /// 负责弹强确认(Settings → General 的「清空全部内容」)。
    ///
    /// 防 SIGTRAP 套路同 `emptyTrash` / `delete`:先**同步**关掉所有浮窗(其
    /// SwiftUI `@ObservedObject` 视图树随窗口释放),再把 `context.delete` 推到
    /// 下一个 runloop tick —— 不在 SwiftUI 还持有 note 的同一 tick 里 fault
    /// 已删对象。windows / displayOrder 这里就清空,关窗触发的 onClose 写
    /// isPinned 无所谓(对象马上整体删掉)。
    /// 返回这次清掉的 (便签数, 分组数) —— 同步 fetch 出来,删除本身异步。
    @discardableResult
    func clearAll(in context: NSManagedObjectContext) -> (notes: Int, groups: Int) {
        for wc in windows.values { wc.close() }
        windows.removeAll()
        displayOrder.removeAll()

        // note 不带任何 predicate —— 三态(活跃 / 归档 / 回收站)全要。
        let notes = (try? context.fetch(NSFetchRequest<Note>(entityName: "Note"))) ?? []
        let groups = (try? context.fetch(NSFetchRequest<NoteGroup>(entityName: "NoteGroup"))) ?? []
        for note in notes { ReminderScheduler.shared.cancel(noteID: note.id) }

        DispatchQueue.main.async {
            for note in notes { context.delete(note) }
            for group in groups { context.delete(group) }
            try? context.save()
        }
        return (notes.count, groups.count)
    }

    /// 当前库里 (便签数, 分组数);便签含三态全部。给「清空全部内容」确认弹窗
    /// 显示规模用。
    func contentCounts(in context: NSManagedObjectContext) -> (notes: Int, groups: Int) {
        let n = (try? context.count(for: NSFetchRequest<Note>(entityName: "Note"))) ?? 0
        let g = (try? context.count(for: NSFetchRequest<NoteGroup>(entityName: "NoteGroup"))) ?? 0
        return (n, g)
    }

    /// 启动时调一次:把超过保留天数的 trashed 笔记真删。默认 30 天(对齐
    /// 系统 Notes/Mail),用户可以在 Settings → General 改(7-365 范围)。
    /// trashedAt 为 nil 的(理论上不该出现,旧库迁移残留)跳过,等下次 trash
    /// 行为重写时再处理。
    func purgeExpiredTrash(in context: NSManagedObjectContext) {
        let request = Note.trashedFetchRequest()
        let days = TrashRetention.current
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        // 在 fetch 阶段就过滤掉 trashedAt 不达标的,免得 fetch 全量再扫一遍。
        request.predicate = NSPredicate(
            format: "isTrashed == %@ AND trashedAt != nil AND trashedAt < %@",
            NSNumber(value: true), cutoff as NSDate
        )
        guard let expired = try? context.fetch(request), !expired.isEmpty else { return }
        for note in expired {
            ReminderScheduler.shared.cancel(noteID: note.id)
            context.delete(note)
        }
        try? context.save()
        NSLog("Noticky: purged %d expired trash note(s)", expired.count)
    }

    private func spawn(note: Note, id: NSManagedObjectID) {
        // 已开浮窗的数量决定偏移量,启动批量恢复时多个浮窗会从中心向右下错开,
        // 避免全部叠在一个点上。模 8 防止越开越远直接出屏。
        let cascade = windows.count % 8
        let wc = FloatingNoteWindowController(
            note: note,
            initialLevel: floatOnTop ? .floating : .normal,
            initialCollectionBehavior: Self.collectionBehavior(floatOnTop: floatOnTop),
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
            onRequestArchive: { [weak self] in
                self?.archive(note: note)
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
/// 这个子类还托管浮窗级别的快捷键(⌘D 删除当前便签)。
final class StickyPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// ⌘D 命中时回调,由 controller 注入,转发给 registry.delete(note:)。
    var onDeleteShortcut: (() -> Void)?

    /// `performKeyEquivalent` 在响应链之前先到 window —— 比 NSTextView 的 keyDown
    /// 早,即使编辑器是 first responder 也能拦住 ⌘D / ⌘W。NSApp.mainMenu 仍然
    /// 优先,所以 ⌘, / ⌘Q 这类有 main menu item 实现的不会被这里吞。
    ///
    /// **⌘W 必须自己拦,不能交给 main menu**:NSWindow 默认的
    /// `validateUserInterfaceItem(performClose:)` 检查 `.closable` styleMask,
    /// borderless 窗永远返回 false → main menu 的 Close 在我们是 key window
    /// 时被自动 disabled → ⌘W 在 mainMenu.performKeyEquivalent 这层就被吃掉,
    /// 根本派发不到 NSWindow.performClose。这里直接调 close() 走 windowWillClose
    /// → onClose 路径(等同 × 按钮)。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers {
            case "d":
                onDeleteShortcut?()
                return true
            case "w":
                close()
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// 兜底:如果未来某个 menu / 程序化路径调到 performClose(:),也走 close()。
    /// 默认实现对 borderless 是 no-op + beep。
    override func performClose(_ sender: Any?) {
        close()
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

final class FloatingNoteWindowController: NSObject, NSWindowDelegate {
    private let note: Note
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

        // 没 savedFrame 时用 Settings → Notes 选的"默认尺寸"。已 saved 的便签不动,
        // 用户既然手动 resize 过就尊重那个尺寸。
        let defaultSizePref = DefaultNoteSize.from(
            UserDefaults.standard.string(forKey: SettingsKey.defaultNoteSize) ?? ""
        )
        let defaultSize = defaultSizePref.size
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
                },
                onArchive: { [weak self] in
                    self?.onRequestArchive()
                },
                onToggleCollapse: { [weak self] in
                    self?.toggleCollapse()
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

    /// 双击标题 / ⋯ 菜单:折叠 ↔ 展开。**瞬间生效,无动画**(顶边锚定,top edge 不变)。
    ///
    /// 这里曾尝试做平滑折叠动画,反复失败 —— 根因是 `NSWindow` frame 动画(WindowServer
    /// 服务端时间轴)与 `NSHostingView` 内容(客户端 CA 时间轴)无法同步,内容要么挤压、
    /// 要么滑动后瞬移、要么不被窗口裁剪而「完全没有变化」。完整归档见
    /// `docs/collapse-animation-attempts.md`。最终决定移除动画,直接 `setFrame`。
    private func toggleCollapse() {
        guard let w = window else { return }
        let nowCollapsed = !note.isCollapsed
        note.isCollapsed = nowCollapsed
        try? note.managedObjectContext?.save()

        let current = w.frame
        let topY = current.maxY
        let target: NSRect
        if nowCollapsed {
            // 折叠:高度→ collapsedHeight,顶部锚不变。
            target = NSRect(
                x: current.minX,
                y: topY - Self.collapsedHeight,
                width: current.width,
                height: Self.collapsedHeight
            )
            w.styleMask.remove(.resizable)
        } else {
            // 展开:回到上次的展开高度。savedFrame 在折叠期间的 flushFrameSave
            // 里只更新 X 和补偿后的 Y,W/H 保留的是展开时的,直接读出来用。
            let expandedH = (note.savedFrame?.height).map { max($0, 80) } ?? 280
            let expandedW = note.savedFrame?.width ?? current.width
            target = NSRect(
                x: current.minX,
                y: topY - expandedH,
                width: expandedW,
                height: expandedH
            )
            w.styleMask.insert(.resizable)
        }
        w.setFrame(target, display: true)
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

private struct FloatingNoteView: View {
    @ObservedObject var note: Note
    @Environment(\.managedObjectContext) private var context
    /// 当前窗口是否处于 key 状态:.key = 活跃,其它都按非活跃处理(渲染毛玻璃)。
    /// SwiftUI 自动跟踪这个 env value,key 状态变化会触发 body 重渲染,
    /// 拿到自由的「失焦动画」,不用手动监听 NSWindow 通知。
    @Environment(\.controlActiveState) private var controlActiveState
    /// 用户在设置面板里可关掉这个效果;@AppStorage 跨视图自动同步。
    @AppStorage(SettingsKey.fadeWhenInactive) private var fadeWhenInactive: Bool = true
    /// 双击标题切换折叠的总开关。默认 false —— 用户在 Settings 里自己开。
    /// 关掉时整个 hit overlay 不渲染,标题区的点击 fall-through 到下面的窗口
    /// 背景拖动逻辑(isMovableByWindowBackground = true),双击没有任何效果。
    @AppStorage(SettingsKey.doubleClickTitleToCollapse) private var doubleClickToCollapseEnabled: Bool = false
    @ObservedObject private var loc = LocalizationManager.shared
    let onClose: () -> Void
    let onDelete: () -> Void
    let onArchive: () -> Void
    let onToggleCollapse: () -> Void

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
        // 顶部 strip 高度:折叠 / 展开两态都用 collapsedHeight(32pt)。
        // 这样折叠时标题文字垂直位置不跳;同时编辑器顶部 spacer 也用这个值,
        // 跟标题条对齐。
        let stripHeight = FloatingNoteWindowController.collapsedHeight

        return ZStack(alignment: .top) {
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

            // 折叠态隐藏编辑器 —— 整个 NSTextView/SwiftUI 子树移除,光标失焦无副作用。
            // 用户双击展开后再重建。
            if !note.isCollapsed {
                VStack(spacing: 0) {
                    Spacer().frame(height: FloatingNoteWindowController.collapsedHeight)
                    MarkdownNoteEditor(
                        text: Binding(
                            get: { note.content },
                            set: { newValue in
                                guard newValue != note.content else { return }
                                note.content = newValue
                                note.updatedAt = Date()
                                try? context.save()
                            }
                        ),
                        documentId: note.id.uuidString
                    )
                    .padding(.horizontal, 6)
                    .padding(.bottom, 10)
                }
            }

            // 顶部标题条:始终可见,跟着 note.content 自动派生(`cleanTitle` 剥过
            // markdown 标记,`# 标题`、`**bold**`、列表前缀等都还原成纯文本)。
            // 跟 hover toolbar 在同一个顶部 strip,左右 padding 让出 ×/⋯ 按钮的位置,
            // hover 时三者并存不打架。展开态空内容直接不显示;折叠态用 "Empty Note"
            // 占位,免得用户折叠后只剩一条空 bar 不知道是啥。
            NoteTitleBar(
                text: note.cleanTitle,
                fallbackWhenEmpty: note.isCollapsed ? L.t(.emptyNote) : nil,
                stripHeight: stripHeight
            )

            // 双击命中层。**位于 HoverToolbar 之下** —— × / ⋯ 按钮要先吃到点击。
            // 高度 = stripHeight:展开态 28pt 不挡编辑器 mouseDown,折叠态 32pt 整条
            // bar 都能双击展开。设置关掉时整个 overlay 不存在,系统的
            // isMovableByWindowBackground 接管点击 = 跟未引入此功能时一样。
            if doubleClickToCollapseEnabled {
                VStack {
                    TitleDoubleClickHit(onDoubleClick: onToggleCollapse)
                        .frame(height: stripHeight)
                    Spacer(minLength: 0)
                }
            }

            // 顶部 hover 工具条独立成一个 struct,**自己拥有 hovering @State** ——
            // hover 状态切换只让这个子 struct 重渲染,不会沿父链冒泡触发整个
            // FloatingNoteView 重渲染。否则任何鼠标进出窗都会让 MarkdownNoteEditor
            // 的 NSTextView updateNSView 被调,扰动中文 IME 的 marked text(拼音)。
            HoverToolbar(
                palette: palette,
                isCollapsed: note.isCollapsed,
                stripHeight: stripHeight,
                reminderDate: note.reminderDate,
                onClose: onClose,
                onPickColor: { picked in
                    note.colorIndex = picked.rawValue
                    note.updatedAt = Date()
                    try? context.save()
                },
                onToggleCollapse: onToggleCollapse,
                onDelete: onDelete,
                onArchive: onArchive,
                onSetReminder: { date in setReminder(date) },
                onClearReminder: { clearReminder() }
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 设/改提醒:先 async 申请权限,授权后写库 + 调度 UN。被拒弹引导对话框。
    /// 早于当前时间的 date 也兜一层 alert(理论上 DatePicker 限制了,保险起见)。
    private func setReminder(_ date: Date) {
        guard date > Date() else {
            showAlert(title: L.t(.reminderInvalidTimeTitle), body: L.t(.reminderInvalidTimeBody))
            return
        }
        Task {
            let granted = await ReminderScheduler.shared.requestAuthorizationIfNeeded()
            await MainActor.run {
                guard !note.isDeleted, note.managedObjectContext != nil else { return }
                if !granted {
                    showPermissionDeniedAlert()
                    return
                }
                note.reminderDate = date
                try? context.save()
                ReminderScheduler.shared.schedule(
                    noteID: note.id,
                    title: note.cleanTitle.isEmpty ? L.t(.appName) : note.cleanTitle,
                    body: previewBody(note.content),
                    fireAt: date
                )
            }
        }
    }

    private func clearReminder() {
        ReminderScheduler.shared.cancel(noteID: note.id)
        note.reminderDate = nil
        try? context.save()
    }

    /// 通知 body 取笔记前 N 字符,去掉首行(已经是 title)。空内容用占位符。
    private func previewBody(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        // 跳过首行(给 title 用了),取剩下的拼成一段,截到 200 字符以内,
        // 系统通知本身也会再截一次。
        let body = lines.dropFirst().joined(separator: " ")
        if body.isEmpty { return "" }
        return String(body.prefix(200))
    }

    private func showPermissionDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = L.t(.reminderPermissionDeniedTitle)
        alert.informativeText = L.t(.reminderPermissionDeniedBody)
        alert.addButton(withTitle: L.t(.permissionOpenSettings))
        alert.addButton(withTitle: L.t(.cancel))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            ReminderScheduler.openNotificationSettings()
        }
    }

    private func showAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: L.t(.ok))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// 浮窗顶部始终可见的标题条。空标题 + 没有 fallback 时不渲染(EmptyView),
/// 保持顶部 strip 留给 hover 工具条不挤压编辑器。`fallbackWhenEmpty` 给折叠
/// 态用 —— 没标题文字也得显示个占位符,否则折叠后是空 strip 用户看不到任何
/// 信息。文本居中、单行截断,左右各 32pt 给 × / ⋯ 按钮腾位置。
///
/// `stripHeight` 决定垂直居中的容器高度:展开态 28pt,折叠态 32pt。文本以
/// `.frame(height:, alignment: .center)` 居中,不再依赖 `.padding(.top, 8)`,
/// 这样折叠时整条 bar 内文字自然垂直居中。
private struct NoteTitleBar: View {
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
private struct TitleDoubleClickHit: NSViewRepresentable {
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
private struct HoverToolbar: View {
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

/// 铃铛 popover 内容:DatePicker + Set / Clear / Cancel。`currentReminder` 决定
/// 默认显示时间(已设过用上次的,没设过用 1 小时后),以及是否显示 Clear 按钮。
private struct ReminderPicker: View {
    let currentReminder: Date?
    let onSet: (Date) -> Void
    let onClear: () -> Void
    let onCancel: () -> Void
    @State private var date: Date

    init(
        currentReminder: Date?,
        onSet: @escaping (Date) -> Void,
        onClear: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.currentReminder = currentReminder
        self.onSet = onSet
        self.onClear = onClear
        self.onCancel = onCancel
        // 默认值:有现成值且在未来 → 用它;否则 1 小时后整点附近。
        // DatePicker 的 `in: Date()...` 范围会拒绝过去时间,所以这里
        // 必须 max(suggested, now + 60s) 确保初值合法。
        let suggested = currentReminder ?? Date().addingTimeInterval(3600)
        let floor = Date().addingTimeInterval(60)
        _date = State(initialValue: max(suggested, floor))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L.t(.reminderSetTitle))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            DatePicker(
                "",
                selection: $date,
                in: Date()...,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .labelsHidden()

            HStack(spacing: 8) {
                if currentReminder != nil {
                    Button(role: .destructive) {
                        onClear()
                    } label: {
                        Text(L.t(.reminderClear))
                    }
                }
                Spacer()
                Button(L.t(.cancel)) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L.t(.reminderSet)) { onSet(date) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 280)
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
