import SwiftUI
import AppKit

/// 浮窗里的 Markdown 源码编辑器。配合 MarkdownNoteEditor 的双态架构使用 ——
/// 渲染态用 Textual 显示渲染结果,点击进入编辑态再用这个 NSTextView 写源码。
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var autofocus: Bool = false
    var onExitEdit: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        // 浮窗便签的彩色底由父层 RoundedRectangle 画;scroll/textView 默认会
        // 用 controlBackgroundColor 自绘一层深色,会盖住调色板色 → 全部透明掉。
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        // 滚动条:overlay 模式悬浮在内容之上 + 自动隐藏,不滚动时不占空间。
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.allowsUndo = true
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.font = .systemFont(ofSize: 14)
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.string = text

        if autofocus {
            // makeNSView 时 view 还没进 hierarchy,window 是 nil。下个 runloop tick
            // 已经 attach 了,这时拿到 window 让它成为 first responder,光标自动出现。
            DispatchQueue.main.async { [weak tv] in
                tv?.window?.makeFirstResponder(tv)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        // 中文 IME 拼音预编辑期间(hasMarkedText 为 true),`tv.string = ...` 会
        // 把 marked text 一锅端清掉。父层 SwiftUI 任意 re-render(比如 hover 变化)
        // 都会把 updateNSView 推一遍,如果不守卫这里,marked text 每次都被清空。
        if tv.hasMarkedText() { return }
        if tv.string != text {
            let selected = tv.selectedRanges
            tv.string = text
            tv.selectedRanges = selected
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        /// 延迟 exit 用 —— 见 `textDidEndEditing` 注释。
        private var pendingExit: DispatchWorkItem?

        init(_ parent: PlainTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        /// Esc 键。NSTextView 默认把它转成 cancelOperation: 调到 delegate,这里
        /// 拦掉返回 true,触发外层切回渲染态。
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                pendingExit?.cancel()
                parent.onExitEdit?()
                return true
            }
            return false
        }

        /// 失焦切回渲染态。**两层防御中文 IME 候选窗口的短暂失焦**:
        ///
        /// 1. 拼音预编辑期间(`hasMarkedText` 为 true)直接跳过 —— textView 还在
        ///    跟 IME 协商,提前 exit 会把 NSTextView 整个销毁,marked text 和 IME
        ///    候选窗口同归于尽。
        /// 2. 其它情况延迟 150ms 再 exit —— 部分中文 IME(尤其第三方)弹候选窗时
        ///    会瞬间偷一下 key 状态,触发 textDidEndEditing 但很快 textView 又重新
        ///    获焦。`textDidBeginEditing` 里 cancel 这个 pending,真正失焦的场景
        ///    (点别的窗口/sticky/app)不会回来,150ms 后照常 exit。
        func textDidEndEditing(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if tv.hasMarkedText() { return }

            pendingExit?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.parent.onExitEdit?()
            }
            pendingExit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        func textDidBeginEditing(_ notification: Notification) {
            // textView 重新获焦,取消之前安排的延迟 exit。
            pendingExit?.cancel()
            pendingExit = nil
        }
    }
}
