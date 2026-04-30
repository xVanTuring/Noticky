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

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        settings.showWindow()
    }

    /// ⌘⇧N 主入口。已授权 → 抓 selection 预填;未授权 → 当次启动里弹一次
    /// NSAlert 引导用户开权限,之后(以及他选择「不开」时)用空 capture 继续。
    ///
    /// 关键时序:`SelectionFetcher.currentSelection()` 必须在 `capture.toggle`
    /// **之前** 调 —— 一旦 capture 窗口抢焦点,frontmostApplication 就成了
    /// Noticky 自己。NSAlert 路径同理:先弹 alert 再开 capture,这次按键不读
    /// selection 也无所谓(用户还没授权)。
    private func handleCaptureHotKey() {
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
    }

    private func promptForAccessibilityAccess() {
        let alert = NSAlert()
        alert.messageText = "开启辅助功能以自动填入选中文本"
        alert.informativeText = """
            Noticky 需要「辅助功能」权限才能在你按下 ⌘⇧N 时,读取当前 App 里选中的文字并自动填入。

            打开「系统设置 → 隐私与安全性 → 辅助功能」,把 Noticky 勾上即可。授权后再按 ⌘⇧N 就能用了。
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "暂不开启")

        // LSUIElement 的 App 没 Dock 图标,弹 modal 前先 activate 一下,
        // alert 才会成为 key window 抢到键盘焦点。
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            SelectionFetcher.openAccessibilitySettings()
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
        // Swift 的 NSPredicate(format:) 不认 ObjC 字面量 YES,SQLite 里 isPinned 是
        // INTEGER 0/1。用 NSNumber 显式包装最稳。
        request.predicate = NSPredicate(format: "isPinned == %@", NSNumber(value: true))
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
