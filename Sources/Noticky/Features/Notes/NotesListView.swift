import SwiftUI
import CoreData

/// Popover 内容:笔记索引。
/// 交互模型:点击行 = 打开/聚焦悬浮便签窗口;+ 按钮 = 新建便签并立即弹出。
/// 不在 popover 内编辑笔记 —— 真正的编辑发生在悬浮便签窗里。
struct NotesListView: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(fetchRequest: Note.sortedFetchRequest(), animation: .default)
    private var notes: FetchedResults<Note>

    let floating: FloatingNotesRegistry
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if notes.isEmpty {
                ContentUnavailableView(
                    "No notes yet",
                    systemImage: "note.text",
                    description: Text("Click + or press ⌘⇧N anywhere")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(notes, id: \.objectID) { note in
                        NoteRow(note: note, floating: floating)
                            .contentShape(Rectangle())
                            .onTapGesture { open(note) }
                            .contextMenu {
                                Button(role: .destructive) {
                                    floating.delete(note: note)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete(perform: deleteNotes)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 320, height: 420)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Noticky").font(.headline)
            Spacer()
            Button(action: addNote) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("New sticky (⌘N)")
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func addNote() {
        let note = Note.create(in: context)
        try? context.save()
        floating.show(note: note)
        dismiss()
    }

    private func open(_ note: Note) {
        floating.show(note: note)
        dismiss()
    }

    private func deleteNotes(at offsets: IndexSet) {
        // 走 registry 入口,顺便关掉对应浮窗,避免悬空引用已删除对象。
        for i in offsets {
            floating.delete(note: notes[i])
        }
    }
}

private struct NoteRow: View {
    @ObservedObject var note: Note
    let floating: FloatingNotesRegistry

    var body: some View {
        // 删除瞬间 @ObservedObject 会先于 FetchRequest 推送一次 body 重算,
        // 此时访问已 fault 的 note 属性会触发 CoreData 的 debug breakpoint。
        // 直接返回空视图等 ForEach 把这行移走即可。
        if note.isDeleted || note.managedObjectContext == nil {
            EmptyView()
        } else {
            rowBody
        }
    }

    private var rowBody: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.displayTitle)
                    .lineLimit(1)
                    .font(.body)
                Text(note.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                floating.toggle(note: note)
            } label: {
                Image(systemName: note.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(note.isPinned ? .orange : .secondary)
            }
            .buttonStyle(.plain)
            .help(note.isPinned ? "Close sticky" : "Open as sticky")
        }
        .padding(.vertical, 4)
    }
}
