import SwiftUI
import Textual

/// 双态 Markdown 编辑器:
/// - 渲染态:Textual 把 markdown 渲成 SwiftUI 富文本(标题/粗斜/列表/代码/图/数学公式...)
/// - 编辑态:NSTextView 显示纯 markdown 源码,正常输入,Esc 或失焦切回渲染态
///
/// 实际上「双模式 Markdown」是 iA Writer / Apple Notes / Things 的常见模式。
/// 对 sticky note 场景特别合适 —— 大部分时间是瞄一眼,要写时点进去就是普通文本。
struct MarkdownNoteEditor: View {
    @Binding var text: String
    @State private var isEditing = false

    var body: some View {
        Group {
            if isEditing {
                PlainTextEditor(
                    text: $text,
                    autofocus: true,
                    onExitEdit: { isEditing = false }
                )
            } else {
                renderedView
            }
        }
    }

    private var renderedView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Click to write")
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    StructuredText(
                        markdown: text,
                        syntaxExtensions: [.math]
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        // 整块都接受点击,空白处也能点进编辑态,而不是非要点到文字上。
        .contentShape(Rectangle())
        .onTapGesture { isEditing = true }
    }
}
