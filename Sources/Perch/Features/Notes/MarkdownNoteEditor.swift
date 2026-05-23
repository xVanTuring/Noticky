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
    /// engine WYSIWYG 需要稳定 per-note 标识隔离 undo / pending replacement
    /// (多浮窗同开时);旧双态实现用不到,给个默认值兼容。
    var documentId: String
    @State private var isEditing: Bool
    /// 实验性 WYSIWYG 引擎开关。开 → 单一实时编辑面(MarkdownEngineNoteEditor);
    /// 关 → 旧的 Textual「渲染态 ↔ 源码态」双态。@AppStorage 带默认值自初始化,
    /// 不需要在 init 里设;改设置 → body 重算 → 整个子树切换。
    @AppStorage(SettingsKey.experimentalMarkdownEngine) private var experimentalEngine: Bool = false

    /// 初始模式按 Settings → Notes 的 "Open notes in edit mode" 决定。
    /// 之后切换是 view 自身 @State(每次 init 一个新 editor 都按当前 setting 起步)。
    init(text: Binding<String>, documentId: String = "default") {
        self._text = text
        self.documentId = documentId
        let startInEdit = UserDefaults.standard.bool(forKey: SettingsKey.startInEditMode)
        self._isEditing = State(initialValue: startInEdit)
    }

    var body: some View {
        if experimentalEngine {
            MarkdownEngineNoteEditor(text: $text, documentId: documentId)
        } else {
            legacyBody
        }
    }

    /// 旧实现:渲染态用 Textual,双击进 PlainTextEditor 源码态,Esc/失焦切回。
    private var legacyBody: some View {
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
