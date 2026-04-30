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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let context = PersistenceController.shared.container.viewContext

        manager = ManagerWindowController(context: context, floating: floating)
        menuBar = MenuBarController(context: context, floating: floating, manager: manager, settings: settings)
        capture = CaptureWindowController(context: context)
        installMainMenu()

        hotKey = HotKeyManager()
        hotKey.register(combo: .captureDefault) { [weak self] in
            self?.capture.toggle()
        }

        restorePinnedNotes(in: context)
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
