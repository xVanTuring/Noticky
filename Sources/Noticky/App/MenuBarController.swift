import AppKit
import CoreData

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let context: NSManagedObjectContext
    private let floating: FloatingNotesRegistry
    private let manager: ManagerWindowController
    private let settings: SettingsWindowController

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
            button.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Noticky")
            button.target = self
            button.action = #selector(showMenu(_:))
            // 左右键统一一个出口,弹同一个原生 NSMenu —— 参考 Apple Stickies 的菜单样式。
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
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

        let newItem = NSMenuItem(title: "New Note", action: #selector(newNote), keyEquivalent: "n")
        newItem.target = self
        newItem.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        menu.addItem(newItem)

        let request = NSFetchRequest<Note>(entityName: "Note")
        // 拿全量,按当前 NoteSort 设置在内存里排;pinned 永远在前。
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
        let showAll = NSMenuItem(
            title: "Show All Notes",
            action: #selector(showManager),
            keyEquivalent: "0"
        )
        showAll.target = self
        showAll.keyEquivalentModifierMask = [.command, .shift]
        showAll.image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: nil)
        menu.addItem(showAll)

        let prefs = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        prefs.target = self
        prefs.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(prefs)

        let floatToggle = NSMenuItem(
            title: "Float on Top",
            action: #selector(toggleFloatOnTop),
            keyEquivalent: ""
        )
        floatToggle.target = self
        floatToggle.state = floating.floatOnTop ? .on : .off
        floatToggle.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
        menu.addItem(floatToggle)

        // 窗口排布。所有打开的浮窗一键 stack(右上角叠成一摞)/ tile(网格平铺)。
        // 没开浮窗时 disable —— autoenablesItems = false,只能手动控 isEnabled。
        let stackItem = NSMenuItem(
            title: "Stack Notes",
            action: #selector(stackNotes),
            keyEquivalent: ""
        )
        stackItem.target = self
        stackItem.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
        stackItem.isEnabled = floating.hasOpenWindows
        menu.addItem(stackItem)

        let tileItem = NSMenuItem(
            title: "Tile Notes",
            action: #selector(tileNotes),
            keyEquivalent: ""
        )
        tileItem.target = self
        tileItem.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        tileItem.isEnabled = floating.hasOpenWindows
        menu.addItem(tileItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Noticky",
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

    @objc private func stackNotes() {
        floating.stackAll()
    }

    @objc private func tileNotes() {
        floating.tileAll()
    }

    @objc private func showManager() {
        manager.showWindow()
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

        let trimmed = note.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // 空笔记用斜体灰色 "Empty Note",跟参考图一致。
            item.attributedTitle = NSAttributedString(
                string: "Empty Note",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .obliqueness: 0.18
                ]
            )
        } else {
            // 取第一非空行作为标题,截断到 50 字防止菜单过宽。
            let firstLine = note.content
                .components(separatedBy: .newlines)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? trimmed
            item.title = String(firstLine.prefix(50))
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
