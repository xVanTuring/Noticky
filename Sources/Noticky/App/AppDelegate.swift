import AppKit
import SwiftUI
import CoreData

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 自己写 entry point。**不用 SwiftUI `@main struct ... : App`** —— 那条路要求
    /// body 至少一个 Scene,而 `Settings { ... }` scene 会抢 ⌘, 快捷键(SwiftUI 用
    /// 私有机制绑,优先级高于我们 NSApp.mainMenu 里的菜单项,replace mainMenu 也
    /// 拦不下来)。其它 Scene(`WindowGroup`、`Window`) 又会自动开真窗口。
    /// 干脆不用 SwiftUI scene 系统,纯 AppKit 起 NSApplication。
    ///
    /// 内容仍然 SwiftUI(在 NSHostingController 里),只是窗口/菜单/快捷键归 AppKit。
    static func main() {
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        // app.delegate 是 weak,但 static main 期间 delegate 这个局部变量还在栈里,
        // app.run() 阻塞到 terminate 为止 —— 全程被 retain。
        app.run()
    }

    private var menuBar: MenuBarController!
    private var capture: CaptureWindowController!
    private var hotKey: HotKeyManager!
    private let floating = FloatingNotesRegistry()
    private var manager: ManagerWindowController!
    private let settings = SettingsWindowController()
    /// 本次启动是否已经弹过「请开启辅助功能」对话框 —— 同一进程里只引导一次,
    /// 之后没授权就静默用空 capture,避免每按一次热键骚扰一次。
    private var hasShownAccessibilityPrompt = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let context = PersistenceController.shared.container.viewContext

        // 启动头一件事:把进回收站超过 30 天的笔记真删。放在 manager/menu
        // 构造和 restorePinnedNotes 之前,这样后续视图初始化看到的就是"已清"
        // 的状态,FetchRequest 不会瞬间显示又消失。
        floating.purgeExpiredTrash(in: context)

        manager = ManagerWindowController(context: context, floating: floating)
        menuBar = MenuBarController(context: context, floating: floating, manager: manager, settings: settings)
        capture = CaptureWindowController(context: context, floating: floating)
        installMainMenu()

        hotKey = HotKeyManager()
        hotKey.register(combo: .captureDefault) { [weak self] in
            self?.handleCaptureHotKey()
        }

        restorePinnedNotes(in: context)
        // pinned 全部恢复完再 applyLayout —— 这样上次保存的布局模式(stack/tile)
        // 在启动时一气呵成,而不是一边 spawn 一边 reflow 一边再 reflow。
        floating.applyLayout()
    }

    /// 整体覆盖 SwiftUI 自动生成的 main menu。LSUIElement App 的 menu bar
    /// **不会显示**,但 NSApplication 派发 keyDown 事件时仍会走
    /// `NSMenu.performKeyEquivalent`,所以 ⌘, 这种快捷键照常生效。
    ///
    /// 这是纯标准 AppKit 路线 —— 不用 NSEvent monitor,不用任何私有 API,
    /// 也不依赖 SwiftUI `Settings { ... }` scene 的 ⌘, 绑定(那条会触发空窗,
    /// AppDelegate 拦不到)。SwiftUI 在 launch 时注入的 Settings 菜单项被这里
    /// 整个替换掉,只剩我们的 → openSettings。
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // App 菜单 ----
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Noticky",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitItem)

        // File 菜单 ----
        // 只装一项 Close (⌘W)。target=nil 走 first responder → NSWindow.performClose:。
        // 标准 NSWindow 有 .closable 时直接关;borderless 的 StickyPanel override
        // 了 performClose 让 ⌘W 也能关浮窗。
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit 菜单 ----
        // LSUIElement 隐藏 menu bar,但 NSApp.mainMenu 上的 keyEquivalent 仍参与
        // 派发。没有这一组 items,⌘V/⌘C/⌘X/⌘Z/⌘A 在 NSTextView 里全部失效 ——
        // first responder chain 只在系统知道有个对应 menu item 要触发 paste:/copy:
        // 这类 action 时才会走。target=nil 让 selector 沿 responder chain 找
        // 实现者(NSTextView 实现了 NSText 这一组方法)。
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = makeEditMenu()
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")

        // Undo / Redo:NSResponder 上的 undo:/redo: 是 first-responder action,
        // 没有 Swift @objc class 直接持有这俩 selector。用字符串 selector 是这种
        // 场景的标准做法,跟 Apple 自己 MainMenu.xib 模板里的写法一致。
        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(undoItem)
        menu.addItem(redoItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Cut",       action: #selector(NSText.cut(_:)),       keyEquivalent: "x"))
        menu.addItem(NSMenuItem(title: "Copy",      action: #selector(NSText.copy(_:)),      keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Paste",     action: #selector(NSText.paste(_:)),     keyEquivalent: "v"))

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        return menu
    }

    @objc private func openSettings() {
        settings.showWindow()
    }

    /// ⌘⇧N 主入口。根据用户在 Settings → Capture 选的模式分发抓取策略,
    /// 之后再 toggle capture 窗口预填。
    ///
    /// 关键时序:**任何抓取调用都必须在 `capture.toggle` 之前**。
    /// 一旦 capture 窗口抢焦点,`frontmostApplication` 就是 Noticky 自己,
    /// AX 读到我们自己的输入框,合成 ⌘C 也是按到 Noticky 上 —— 全错。
    /// 这函数把 frontmost app 信息(pid/bundleID)在头一两行就抓出来,
    /// 后面分支都基于这个快照,不再二次访问 NSWorkspace。
    private func handleCaptureHotKey() {
        let mode = CaptureMode.from(
            UserDefaults.standard.string(forKey: SettingsKey.captureMode) ?? ""
        )

        if mode == .disabled {
            capture.toggle()
            return
        }

        // 抢焦点前抓 frontmost。后面所有路径都用这个快照,不再访问 NSWorkspace。
        let front = NSWorkspace.shared.frontmostApplication
        let frontPID = front?.processIdentifier
        let frontBundle = front?.bundleIdentifier ?? ""

        switch mode {
        case .clipboardOnly:
            let prefill = frontPID.flatMap { ClipboardFetcher.fetch(from: $0) }
            capture.toggle(prefill: prefill)

        case .axWithWhitelist:
            let whitelist = UserDefaults.standard.string(forKey: SettingsKey.clipboardWhitelist) ?? ""
            let useClipboard = !frontBundle.isEmpty
                && ClipboardWhitelist.contains(whitelist, bundleID: frontBundle)

            if useClipboard {
                let prefill = frontPID.flatMap { ClipboardFetcher.fetch(from: $0) }
                capture.toggle(prefill: prefill)
                return
            }

            // 走 AX —— 沿用旧分支:已授权直接抓,没授权当次启动弹一次引导。
            if SelectionFetcher.isTrusted {
                let prefill = SelectionFetcher.currentSelection()
                capture.toggle(prefill: prefill)
                return
            }
            if hasShownAccessibilityPrompt {
                capture.toggle()
                return
            }
            hasShownAccessibilityPrompt = true
            promptForAccessibilityAccess()

        case .disabled:
            // 上面已 return,这分支只为穷尽 switch。
            capture.toggle()
        }
    }

    private func promptForAccessibilityAccess() {
        let alert = NSAlert()
        alert.messageText = L.t(.promptAxTitle)
        alert.informativeText = L.t(.promptAxBody)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L.t(.promptAxOpen))
        alert.addButton(withTitle: L.t(.promptAxNotNow))

        // LSUIElement 的 App 没 Dock 图标,弹 modal 前先 activate 一下,
        // alert 才会成为 key window 抢到键盘焦点。
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            SelectionFetcher.requestAndOpenAccessibilitySettings()
            // 不顺手开 capture —— 用户准备去授权,这时候弹个空输入框反而碍事。
            // 授权完成后他会再按一次 ⌘⇧N,届时已经 trusted。
        } else {
            capture.toggle()
        }
    }

    /// 启动时把上次还在浮窗状态的笔记自动恢复出来。`isPinned` 一字段同时表达
    /// 「当前是否有浮窗」和「下次启动是否自动显示」—— 用户手动 × 关掉就置 false,
    /// 从列表点开/新建就置 true。
    private func restorePinnedNotes(in context: NSManagedObjectContext) {
        let request = NSFetchRequest<Note>(entityName: "Note")
        // Swift 的 NSPredicate(format:) 不认 ObjC 字面量 YES,SQLite 里 bool 是
        // INTEGER 0/1。用 NSNumber 显式包装最稳。
        // isTrashed 过滤是防御性的:trash 流程已经把 isPinned 清成 false,
        // 但跨版本启动时旧库里可能存在 pinned + trashed 的脏数据,这里挡一下。
        request.predicate = NSPredicate(
            format: "isPinned == %@ AND isTrashed == %@",
            NSNumber(value: true), NSNumber(value: false)
        )
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        guard let pinned = try? context.fetch(request) else { return }
        for note in pinned {
            floating.show(note: note)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 退出 hook 必须比 windowWillClose 早 —— `applicationShouldTerminate` 在
    /// 系统开始关 windows 之前调,这时打 isTerminating flag,后续每个浮窗的
    /// windowWillClose → onClose 会跳过把 isPinned 清成 false 的写库逻辑,
    /// 下次启动 restorePinnedNotes 才能 fetch 到这些笔记。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        floating.isTerminating = true
        return .terminateNow
    }
}
