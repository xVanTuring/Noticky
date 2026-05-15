import AppKit
import Carbon.HIToolbox

/// 通过合成 ⌘C 从前台 App 抓选中文本的兜底路径。AX 拿不到的 App
/// (微信、各种 Electron / 自绘 UI 应用)走这条 —— 任何能 ⌘C 的输入框都吃。
///
/// 与 `SelectionFetcher` 的差异:
/// - 不读 AX 选区属性,改用 `CGEvent.postToPid` 合成 ⌘C 让接收方自己把
///   选区写进剪贴板。但 **仍然需要辅助功能权限** —— macOS 10.14+ 起合成
///   按键统一走 TCC,没权限事件被静默丢弃(没报错、没回调、剪贴板不会变),
///   失败模式比 AX 模式更难诊断。Settings → Capture 在切到非 disabled 模式
///   时会主动 `requestTrust()` 提前申请。
/// - 会污染剪贴板 —— 我们读完之后立刻 **恢复用户原本的剪贴板内容**。
/// - 异步:⌘C 派发后接收方处理需要一两个 runloop tick,我们短轮询 `changeCount`
///   ~150ms;没动就当抓不到。
///
/// 关键时序前提同 `SelectionFetcher`:**必须在 Noticky 抢焦点之前调用**。
/// 调用方应已捕获 `frontmostApplication.processIdentifier` 传进来,而不是这里
/// 现读 —— 这函数本身会跑几十毫秒,期间 frontmost 可能已经变。
enum ClipboardFetcher {
    /// 同步抓 `pid` 进程当前选中的文本。
    /// - 保存原 pasteboard string,合成 ⌘C,等 changeCount 跳变(~150ms 超时),
    ///   读新内容,**无论成败都恢复原 pasteboard**,返回新串(没跳变 → nil)。
    /// - `pid` 必须是抢焦点前抓到的源 App pid;不是 Noticky 自己。
    static func fetch(from pid: pid_t) -> String? {
        let pasteboard = NSPasteboard.general

        // 保存原内容。只保 string —— 图片/文件类自定义类型恢复成本高,且 ⌘C
        // 出来的几乎都是文本场景。如果原本是图片,恢复后变成空 string,稍微
        // 牺牲一下边缘 case 换实现简洁。
        let savedString = pasteboard.string(forType: .string)
        let baselineCount = pasteboard.changeCount

        guard postCommandC(to: pid) else { return nil }

        // 短轮询等接收方写 pasteboard。System Settings.app 之类响应 ~10ms,
        // 慢的 App ~80ms,150ms 上限够覆盖绝大多数情况而不至于让用户感到卡。
        let deadline = Date().addingTimeInterval(0.15)
        var captured: String?
        while Date() < deadline {
            if pasteboard.changeCount != baselineCount {
                captured = pasteboard.string(forType: .string)
                break
            }
            // 0.01s = 10ms,够 runloop 跑一圈又不至于忙等。
            Thread.sleep(forTimeInterval: 0.01)
        }

        // 恢复原内容。即使 captured 是 nil 也要恢复 —— 我们可能把 changeCount
        // 推进了(实际没变文本)或者把别的类型清掉了。
        pasteboard.clearContents()
        if let savedString {
            pasteboard.setString(savedString, forType: .string)
        }

        guard let text = captured,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// 把 ⌘C 合成事件 post 到指定 pid。`postToPid` 比 `post(tap:)` 精准 ——
    /// 直接送给目标 App 的事件队列,不会被中途拦截、也不会被快速切走的窗口接收。
    private static func postCommandC(to pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let cKey = CGKeyCode(kVK_ANSI_C)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand

        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }
}
