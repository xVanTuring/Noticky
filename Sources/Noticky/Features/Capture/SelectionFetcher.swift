import AppKit
import ApplicationServices

/// 通过 Accessibility API 抓 frontmost app 焦点元素的选中文本。
///
/// 重要前提:
/// - 用户必须在「系统设置 → 隐私与安全性 → 辅助功能」中授权 Noticky。
///   Sandbox 不阻止 AX,但 TCC 仍要求显式授权。
/// - 必须在自家窗口抢焦点 *之前* 读 —— 一旦 Noticky 成为 frontmost,
///   `frontmostApplication` 就是 Noticky 自己,读到的就是 capture 输入框。
///   所以 AppDelegate 那边要先 fetch 再 toggle。
enum SelectionFetcher {
    /// 当前是否已被授予 AX 权限。
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 提示用户授权(系统弹一次原生对话框,之后由用户去系统设置里勾)。
    /// 对已授权的进程是 no-op。
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let opts = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// 读 frontmost app 焦点元素的 `kAXSelectedTextAttribute`。
    /// 没选中、没权限、或目标 app 不暴露此属性(部分 Electron/老 app)→ 返回 nil。
    static func currentSelection() -> String? {
        guard isTrusted else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axApp,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focused = focusedRef else { return nil }
        // CFTypeRef → AXUIElement。AX 只在运行时检查,这里强转是惯例。
        let element = focused as! AXUIElement

        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedRef
        ) == .success else { return nil }

        guard let text = selectedRef as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }
}
