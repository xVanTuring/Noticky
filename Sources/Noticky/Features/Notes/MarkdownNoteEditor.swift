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
    @State private var isEditing: Bool

    /// 初始模式按 Settings → Notes 的 "Open notes in edit mode" 决定。
    /// 之后切换是 view 自身 @State(每次 init 一个新 editor 都按当前 setting 起步)。
    init(text: Binding<String>) {
        self._text = text
        let startInEdit = UserDefaults.standard.bool(forKey: SettingsKey.startInEditMode)
        self._isEditing = State(initialValue: startInEdit)
    }

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
        // 整块都接受双击,空白处也能点进编辑态。改成双击是因为单击太容易误触
        // (拖窗、调色板、× 关闭附近),特别是 hover 工具条出现时。双击是 macOS
        // Notes/Stickies 进编辑态的常见交互。
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { isEditing = true }
    }
}
