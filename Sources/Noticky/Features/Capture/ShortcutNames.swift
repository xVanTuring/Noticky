import KeyboardShortcuts

/// 所有"用户可自定义"的全局快捷键集中在这里。命名后由
/// `KeyboardShortcuts.Recorder` 在 Settings 里编辑、`KeyboardShortcuts.onKeyDown`
/// 在 AppDelegate 里订阅。库自己负责持久化(UserDefaults)和系统级注册。
///
/// **不归这里管**:menu / window 派发的快捷键 —— ⌘N、⌘W、⌘Q、⌘,、⌘⇧0、⌘D
/// 等。它们走 NSMenuItem.keyEquivalent 或 StickyPanel.performKeyEquivalent,
/// 不是全局热键,无需进 KeyboardShortcuts 的体系。
extension KeyboardShortcuts.Name {
    /// 默认 ⌘⇧N。第一次启动时新用户保留旧体验;改过的用户库自动从 UserDefaults
    /// 读他们存的那一份,默认值不生效。
    static let quickCapture = Self(
        "quickCapture",
        default: .init(.n, modifiers: [.command, .shift])
    )
}
