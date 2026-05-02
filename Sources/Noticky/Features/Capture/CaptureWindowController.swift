import AppKit
import SwiftUI
import CoreData

final class CaptureWindowController {
    private let context: NSManagedObjectContext
    private let floating: FloatingNotesRegistry
    private var window: NSWindow?

    init(context: NSManagedObjectContext, floating: FloatingNotesRegistry) {
        self.context = context
        self.floating = floating
    }

    func toggle(prefill: String? = nil) {
        if let w = window, w.isVisible {
            w.orderOut(nil)
            return
        }
        present(prefill: prefill ?? "")
    }

    private static let contentSize = NSSize(width: 560, height: 200)

    private func present(prefill: String) {
        let view = CaptureView(
            initialText: prefill,
            onSubmit: { [weak self] text in
                self?.save(text)
                self?.window?.orderOut(nil)
            },
            onCancel: { [weak self] in
                self?.window?.orderOut(nil)
            }
        )
        let host = NSHostingController(rootView: view)

        let w = window ?? makeWindow()
        w.contentViewController = host
        // 同 FloatingNoteWindow:contentViewController 会把 window 缩到
        // SwiftUI 固有尺寸,必须在赋值后再调一次 setContentSize 拉回。
        w.setContentSize(Self.contentSize)
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.isMovableByWindowBackground = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.hidesOnDeactivate = true
        w.isReleasedWhenClosed = false
        return w
    }

    private func save(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let note = Note.create(in: context, content: trimmed)
        try? context.save()
        // 创建后立刻弹出浮窗 —— ⌘⇧N 快速记录的语义本来就是"写完一条便签放桌面",
        // 不浮出来用户根本看不到刚记的那条。floating.show 会把 isPinned 置 true
        // 并按当前 layoutMode 自动 reflow,新笔记直接进 cascade/tile。
        floating.show(note: note)
    }
}

private struct CaptureView: View {
    @State private var text: String
    @ObservedObject private var loc = LocalizationManager.shared
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    init(
        initialText: String = "",
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._text = State(initialValue: initialText)
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            CaptureTextEditor(
                text: $text,
                onSubmit: { onSubmit(text) },
                onCancel: onCancel
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()
            HStack(spacing: 14) {
                Label(L.t(.quickSave), systemImage: "return")
                Label {
                    Text(L.t(.quickNewLine))
                } icon: {
                    HStack(spacing: 2) {
                        Image(systemName: "shift")
                        Image(systemName: "return")
                    }
                }
                Label(L.t(.quickCancel), systemImage: "escape")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
    }
}

/// Quick-capture 多行编辑器。直接 wrap NSTextView 而不是用 SwiftUI TextEditor —— 我们要
/// **自己定义 Return 行为**:Return = 保存(onSubmit),Shift+Return = 真换行,
/// SwiftUI TextField/TextEditor 都拿不到这种细分。
struct CaptureTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
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
        tv.font = .systemFont(ofSize: 17)
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.string = text

        // 占位符:NSTextView 没原生 placeholder API,自己塞一个 attributed string
        // 给 setValue。空文本时显示,有内容时自动隐藏(系统行为)。
        let placeholderAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: NSFont.systemFont(ofSize: 17)
        ]
        let placeholder = NSAttributedString(string: L.t(.quickPlaceholder), attributes: placeholderAttrs)
        tv.setValue(placeholder, forKey: "placeholderAttributedString")

        // 入场就抢焦点,跟之前 TextField .focused($focused).onAppear 等价。
        DispatchQueue.main.async { [weak tv] in
            tv?.window?.makeFirstResponder(tv)
            // 预填的话,把光标放到末尾,方便用户继续接着写。
            if !tv!.string.isEmpty {
                let end = (tv!.string as NSString).length
                tv?.setSelectedRange(NSRange(location: end, length: 0))
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.hasMarkedText() { return }
        if tv.string != text {
            let selected = tv.selectedRanges
            tv.string = text
            tv.selectedRanges = selected
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CaptureTextEditor
        init(_ parent: CaptureTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        /// NSTextView 默认按键路由:
        /// - Return → `insertNewline:`(默认插入 \n)
        /// - Shift+Return → `insertNewlineIgnoringFieldEditor:`(也插入 \n)
        /// - Esc → `cancelOperation:`
        ///
        /// 我们拦掉 `insertNewline:` 转成保存,Shift+Return 走默认路径插入真换行 ——
        /// 跟 Slack/iMessage 等"Enter 发送, Shift+Enter 换行"惯例一致。
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}
