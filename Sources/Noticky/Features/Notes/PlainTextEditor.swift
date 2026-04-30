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
        if tv.string != text {
            let selected = tv.selectedRanges
            tv.string = text
            tv.selectedRanges = selected
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        init(_ parent: PlainTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        /// Esc 键。NSTextView 默认把它转成 cancelOperation: 调到 delegate,这里
        /// 拦掉返回 true,触发外层切回渲染态。
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onExitEdit?()
                return true
            }
            return false
        }

        /// 失焦也切回渲染态(点别处、切到别的 sticky、切到别的 App 等)。
        /// App 切走也会触发,接受这个小代价 —— 用户回来再点一次就进编辑。
        func textDidEndEditing(_ notification: Notification) {
            parent.onExitEdit?()
        }
    }
}
