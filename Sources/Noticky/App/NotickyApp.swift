import SwiftUI

@main
struct NotickyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 只为让 SwiftUI 在主菜单注册 "Settings…" 并绑 ⌘, 快捷键。
        // ⌘, 触发时走 responder chain 上的 `showSettingsWindow:`,
        // AppDelegate 实现了这个 selector,会拦下来调我们自己的 SettingsWindowController
        // (NSTabViewController + native 动画 resize),空窗永远不会真的画出来。
        Settings { EmptyView() }
    }
}
