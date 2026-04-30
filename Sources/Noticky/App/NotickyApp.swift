import SwiftUI

@main
struct NotickyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // SwiftUI 原生 Settings scene:自动绑 ⌘,,自动给窗口注入 toolbar 风格的
        // tab bar,切 tab 时窗口高度由系统平滑动画(macOS 14+)。
        // 各 tab 用 .frame(width:height:) 指定固定尺寸,SwiftUI 会按这个推算
        // contentSize 并驱动 window resize。
        Settings {
            SettingsView()
        }
    }
}
