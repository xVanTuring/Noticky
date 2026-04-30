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

    private static let contentSize = NSSize(width: 560, height: 132)

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
    @FocusState private var focused: Bool
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
            TextField("Quick note…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .focused($focused)
                .onSubmit { onSubmit(text) }
                .onAppear { focused = true }
                .onExitCommand { onCancel() }
            Divider()
            HStack(spacing: 12) {
                Label("Save", systemImage: "return")
                Label("Cancel", systemImage: "escape")
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
