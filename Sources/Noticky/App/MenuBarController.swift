import AppKit
import Combine
import CoreData

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let context: NSManagedObjectContext
    private let floating: FloatingNotesRegistry
    private let manager: ManagerWindowController
    private let settings: SettingsWindowController

    private var cancellables: Set<AnyCancellable> = []
    /// 后台检查发现的待处理更新版本号(nil = 没有)。托盘菜单据此显示入口,
    /// 图标据此点角标。订阅 `UpdaterService.shared.$availableVersion` 同步。
    private var availableUpdateVersion: String?

    init(
        context: NSManagedObjectContext,
        floating: FloatingNotesRegistry,
        manager: ManagerWindowController,
        settings: SettingsWindowController
    ) {
        self.context = context
        self.floating = floating
        self.manager = manager
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = Self.statusImage(updateBadge: false, for: button)
            button.target = self
            button.action = #selector(showMenu(_:))
            // 左右键统一一个出口,弹同一个原生 NSMenu —— 参考 Apple Stickies 的菜单样式。
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // 数字徽标随两类信号刷新:
        //  1. 笔记增删改 —— viewContext 的 objectsDidChange(新建 / trash / restore /
        //     开关浮窗都会写 isPinned/isTrashed 并 save,主线程投递)。total 和
        //     active 两种模式都靠这个,active 用 isPinned(见 MenuBarCountMode)。
        //  2. 用户在 Settings 改了显示模式 —— @AppStorage 落盘触发 didChange。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scheduleBadgeRefresh),
            name: .NSManagedObjectContextObjectsDidChange,
            object: context
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scheduleBadgeRefresh),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        refreshBadge()

        // 后台静默检查发现更新时,UpdaterService 把版本号 publish 出来。
        // 我们据此重画图标角标(托盘菜单的入口在 buildMenu 里按需读取)。
        UpdaterService.shared.$availableVersion
            .receive(on: DispatchQueue.main)
            .sink { [weak self] version in
                guard let self else { return }
                self.availableUpdateVersion = version
                self.refreshUpdateBadge()
            }
            .store(in: &cancellables)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 更新角标变化时重画状态栏图标(有待处理更新 → note.text + 橙点)。
    /// 跟 refreshBadge 的数字徽标正交:那个只动 title / imagePosition。
    private func refreshUpdateBadge() {
        guard let button = statusItem.button else { return }
        button.image = Self.statusImage(updateBadge: availableUpdateVersion != nil, for: button)
    }

    /// 托盘图标。`updateBadge == false` 时直接用模板符号(自动适配深浅菜单栏 +
    /// 点击高亮)。有待处理更新时,改用非模板合成图:符号染成 labelColor + 右上
    /// 角一个橙点 —— 模板图会把整张统一染色丢掉橙色,所以这里必须非模板。
    private static func statusImage(updateBadge: Bool, for button: NSStatusBarButton) -> NSImage? {
        guard let base = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Noticky") else {
            return nil
        }
        guard updateBadge else {
            base.isTemplate = true
            return base
        }
        base.isTemplate = true
        let appearance = button.effectiveAppearance
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                base.draw(in: rect)
                // 模板符号画出来是黑色字形,sourceAtop 把它染成当前外观的 labelColor。
                NSColor.labelColor.set()
                rect.fill(using: .sourceAtop)
                // 右上角橙点。
                let d = min(rect.width, rect.height) * 0.45
                let dot = NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 多个通知(如 showAll 一次性 spawn N 个浮窗)在同一 runloop 周期内合并成
    /// 一次 refreshBadge。`badgeRefreshScheduled` 只在主线程写,跨线程多刷一次
    /// 也只是无害的重复计数。
    private var badgeRefreshScheduled = false

    @objc private func scheduleBadgeRefresh() {
        guard !badgeRefreshScheduled else { return }
        badgeRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.badgeRefreshScheduled = false
            self.refreshBadge()
        }
    }

    /// 按当前 MenuBarCountMode 把数字写到状态栏图标右侧。`.none` 时清掉 title
    /// 并切回 imageOnly,variableLength 的 statusItem 会自动缩回只剩图标。
    private func refreshBadge() {
        guard let button = statusItem.button else { return }
        let mode = MenuBarCountMode.from(
            UserDefaults.standard.string(forKey: SettingsKey.menuBarCount) ?? ""
        )
        guard mode != .none else {
            button.title = ""
            button.imagePosition = .imageOnly
            return
        }

        let request = NSFetchRequest<Note>(entityName: "Note")
        switch mode {
        case .total:
            // 全部活跃笔记 = 未删除且未归档(归档不计入,跟它不进列表一致)。
            request.predicate = NSPredicate(
                format: "isTrashed == %@ AND isArchived == %@",
                NSNumber(value: false), NSNumber(value: false)
            )
        case .active:
            // isPinned == 浮窗打开中 / 开机自动恢复(见 CLAUDE.md & MenuBarCountMode)。
            // 归档会清 isPinned,这里再显式排除一层防御。
            request.predicate = NSPredicate(
                format: "isPinned == %@ AND isTrashed == %@ AND isArchived == %@",
                NSNumber(value: true), NSNumber(value: false), NSNumber(value: false)
            )
        case .none:
            return  // 上面已 guard,这分支只为穷尽 switch
        }
        let count = (try? context.count(for: request)) ?? 0
        // 图标在左、数字在右;前置一个空格跟图标留点缝。
        button.imagePosition = .imageLeading
        button.title = " \(count)"
    }

    @objc private func showMenu(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        // popUpContextMenu(with:event:for:) 会跟着鼠标位置弹,菜单飘到指针下面。
        // 把 menu 临时挂到 statusItem 上再 performClick,系统就会按标准位置(图标
        // 正下方,贴菜单栏)弹出。menu 是模态的,closure 同步阻塞到关闭后再解绑。
        statusItem.menu = buildMenu()
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 后台发现的待处理更新放最上面,最显眼。点了走 Sparkle 的下载/安装 UI。
        if let version = availableUpdateVersion {
            let updateItem = NSMenuItem(
                title: L.t(.menuUpdateAvailable, version),
                action: #selector(installUpdate),
                keyEquivalent: ""
            )
            updateItem.target = self
            updateItem.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(updateItem)
            menu.addItem(.separator())
        }

        let newItem = NSMenuItem(title: L.t(.menuNewNote), action: #selector(newNote), keyEquivalent: "n")
        newItem.target = self
        newItem.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        menu.addItem(newItem)

        let request = NSFetchRequest<Note>(entityName: "Note")
        // 拿全量(回收站 + 归档除外),按当前 NoteSort 设置在内存里排;pinned 永远在前。
        request.predicate = NSPredicate(
            format: "isTrashed == %@ AND isArchived == %@",
            NSNumber(value: false), NSNumber(value: false)
        )
        let allNotes = (try? context.fetch(request)) ?? []
        let sort = NoteSort.from(UserDefaults.standard.string(forKey: SettingsKey.noteSort) ?? "")
        let notes = allNotes.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            switch sort {
            case .dateEdited:  return lhs.updatedAt > rhs.updatedAt
            case .dateCreated: return lhs.createdAt > rhs.createdAt
            case .title:
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
            }
        }
        if !notes.isEmpty {
            menu.addItem(.separator())
            for note in notes {
                menu.addItem(noteMenuItem(note))
            }
        }

        menu.addItem(.separator())

        // 显示所有便签:fetch 所有未删笔记,逐条 spawn / bringToFront。
        // 库里没未删笔记时 disabled。
        let showAllStickies = NSMenuItem(
            title: L.t(.menuShowAllStickies),
            action: #selector(showAllStickiesAction),
            keyEquivalent: ""
        )
        showAllStickies.target = self
        showAllStickies.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        showAllStickies.isEnabled = !notes.isEmpty
        menu.addItem(showAllStickies)

        // 隐藏所有便签:把当前可见的浮窗 orderOut(不释放 wc、不清 isPinned)。
        // 没有可见浮窗时 disabled。
        let hideAllStickies = NSMenuItem(
            title: L.t(.menuHideAllStickies),
            action: #selector(hideAllStickiesAction),
            keyEquivalent: ""
        )
        hideAllStickies.target = self
        hideAllStickies.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
        hideAllStickies.isEnabled = floating.hasVisibleWindow
        menu.addItem(hideAllStickies)

        let showAll = NSMenuItem(
            title: L.t(.menuManageAllNotes),
            action: #selector(showManager),
            keyEquivalent: "0"
        )
        showAll.target = self
        showAll.keyEquivalentModifierMask = [.command, .shift]
        showAll.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: nil)
        menu.addItem(showAll)

        let prefs = NSMenuItem(
            title: L.t(.menuSettings),
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        prefs.target = self
        prefs.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(prefs)

        let floatToggle = NSMenuItem(
            title: L.t(.menuFloatOnTop),
            action: #selector(toggleFloatOnTop),
            keyEquivalent: ""
        )
        floatToggle.target = self
        floatToggle.state = floating.floatOnTop ? .on : .off
        floatToggle.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
        menu.addItem(floatToggle)

        // 布局模式:radio 三选一,选中谁就持续维持那个模式。stack 模式下
        // 点击哪张笔记自动滑到 cascade 最下方;tile 模式下拖动后按位置自动重排。
        let layoutItem = NSMenuItem(title: L.t(.menuLayout), action: nil, keyEquivalent: "")
        layoutItem.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
        let layoutSub = NSMenu(title: "Layout")
        for mode in LayoutMode.allCases {
            let item = NSMenuItem(
                title: mode.label,
                action: #selector(setLayoutMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.image = NSImage(systemSymbolName: mode.icon, accessibilityDescription: nil)
            item.state = (floating.layoutMode == mode) ? .on : .off
            layoutSub.addItem(item)
        }
        layoutItem.submenu = layoutSub
        menu.addItem(layoutItem)

        // 「把所有便签集中到某台显示器」:仅多屏时显示,无浮窗打开时整项 disable
        // (浮窗都没开,没东西可挪)。一次性动作,不持久化,跟便签自身的钉显示器
        // 设置正交。
        let displays = DisplayCatalog.current()
        if displays.count > 1 {
            let moveAllItem = NSMenuItem(
                title: L.t(.menuMoveAllToDisplay),
                action: nil,
                keyEquivalent: ""
            )
            moveAllItem.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
            let moveSub = NSMenu(title: "Move To Display")
            for display in displays {
                let item = NSMenuItem(
                    title: display.name,
                    action: #selector(moveAllToDisplay(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = display.uuid
                item.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
                item.isEnabled = floating.hasOpenWindows
                moveSub.addItem(item)
            }
            moveAllItem.submenu = moveSub
            moveAllItem.isEnabled = floating.hasOpenWindows
            menu.addItem(moveAllItem)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: L.t(.menuQuit),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }

    @objc private func toggleFloatOnTop() {
        floating.setFloatOnTop(!floating.floatOnTop)
    }

    @objc private func showAllStickiesAction() {
        floating.showAll(in: context)
    }

    @objc private func hideAllStickiesAction() {
        floating.hideAll()
    }

    @objc private func setLayoutMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = LayoutMode(rawValue: raw) else { return }
        floating.setLayoutMode(mode)
    }

    @objc private func moveAllToDisplay(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        floating.moveAllToDisplay(uuid: uuid)
    }

    @objc private func showManager() {
        manager.showWindow()
    }

    /// 用户点托盘里的「有可用更新」。交给 Sparkle 走 user-initiated 检查,
    /// 把后台发现的更新带 UI 重新呈现。点完 Sparkle 的 didReceiveUserAttention
    /// 会回调清掉 availableVersion,角标随之消失。
    @objc private func installUpdate() {
        UpdaterService.shared.showAvailableUpdate()
    }

    @objc private func showSettings() {
        // 我们自己的 AppKit SettingsWindowController(NSTabViewController + 动画 resize)。
        // 跟 AppDelegate 装的主菜单 ⌘, 殊途同归。
        settings.showWindow()
    }

    private func noteMenuItem(_ note: Note) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(openNote(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = note.objectID
        item.image = paletteIcon(for: StickyPalette.from(index: note.colorIndex))

        // 用 `cleanTitle`(剥过 markdown 标记的第一非空行,空内容返回 "")。
        // 一个口径同步到浮窗标题条 / 菜单 / 管理列表,不会出现菜单里还带 `#`
        // 浮窗已经剥过的不一致情况。
        let title = note.cleanTitle
        if title.isEmpty {
            // 空笔记用斜体灰色 "Empty Note",跟参考图一致。
            item.attributedTitle = NSAttributedString(
                string: L.t(.emptyNote),
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .obliqueness: 0.18
                ]
            )
        } else {
            // 截断到 50 字防止菜单过宽。
            item.title = String(title.prefix(50))
        }

        // 已 pin(浮窗打开中)的笔记打个勾,直观看到当前显示状态。
        item.state = note.isPinned ? .on : .off
        return item
    }

    private func paletteIcon(for palette: StickyPalette) -> NSImage {
        let size = NSSize(width: 16, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let body = rect.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3)
            palette.nsColor.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.18).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        // 关键:不能 isTemplate,否则系统会按 label 色调统一染色,丢掉调色板色。
        image.isTemplate = false
        return image
    }

    @objc private func newNote() {
        let note = Note.create(in: context)
        try? context.save()
        floating.show(note: note)
    }

    @objc private func openNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? NSManagedObjectID,
              let note = try? context.existingObject(with: id) as? Note else { return }
        floating.show(note: note)
    }
}
