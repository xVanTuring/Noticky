import AppKit
import ApplicationServices

/// 通过 Accessibility API 抓 frontmost app 焦点元素的选中文本。
///
/// 重要前提:
/// - 用户必须在「系统设置 → 隐私与安全性 → 辅助功能」中授权 Noticky。
/// - **Noticky 必须不在 sandbox 中运行**。沙盒在 IPC 层拦截跨进程 AX 查询
///   (-25204 kAXErrorCannotComplete),即使 TCC 已授权也无效 —— 详见
///   Resources/Noticky.entitlements 注释。这是把 sandbox 关掉的核心原因。
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

    /// 引导用户授权:先把 Noticky 注册进 TCC,再深链到辅助功能面板。
    ///
    /// **关键:必须先 `AXIsProcessTrustedWithOptions(prompt:true)`**。
    /// 没这一步,App 不会出现在「系统设置 → 隐私与安全性 → 辅助功能」
    /// 列表里 —— 用户跳过去看到的是空列表,只能手动拖 .app 进去,体验很差。
    /// 调一次这个 API 就把 bundle 注册进 TCC daemon,列表里立刻有条目可勾。
    /// 已授权时 prompt 调用是 no-op,安全幂等。
    static func requestAndOpenAccessibilitySettings() {
        requestTrust()
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 读 frontmost app 焦点元素的 `kAXSelectedTextAttribute`。
    /// 没选中、没权限、或目标 app 不暴露此属性(部分 Electron/老 app)→ 返回 nil。
    ///
    /// **依赖前提:Noticky 已关闭 sandbox**。沙盒会在 IPC 层拦截所有跨进程
    /// AX 查询(返回 -25204 kAXErrorCannotComplete),即使 TCC 已授权也无效。
    /// 详见 Resources/Noticky.entitlements 注释。
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
