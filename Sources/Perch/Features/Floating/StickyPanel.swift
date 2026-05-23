import AppKit

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
