import SwiftUI
import CoreData

/// 管理窗口的 SwiftUI 根视图。两栏 NavigationSplitView:
///   sidebar  → 「All Notes」+ 各分组 + 「Ungrouped」,各自可展开/折叠的笔记列表
///   detail   → 选中笔记的渲染内容(Textual),空选中态显示提示
struct ManagerView: View {
    let floating: FloatingNotesRegistry

    @Environment(\.managedObjectContext) private var context
    @FetchRequest(fetchRequest: NoteGroup.sortedFetchRequest(), animation: .default)
    private var groups: FetchedResults<NoteGroup>
    @FetchRequest(fetchRequest: Note.sortedFetchRequest(), animation: .default)
    private var allNotes: FetchedResults<Note>

    @State private var selection: Note.ID?
    @State private var search: String = ""
    @AppStorage(SettingsKey.noteSort) private var noteSortRaw: String = NoteSort.dateEdited.rawValue
    /// 重命名分组用的状态:点 "Rename" 后存住目标 group + 当前名,alert 用 TextField
    /// 让用户改;Save 写回并清空,Cancel 直接清空。
    @State private var renamingGroup: NoteGroup?
    @State private var renameText: String = ""
    /// 新建分组用的状态:toolbar New Group 按钮把它打开,alert 让用户先输入名字
    /// 再写库 —— 不再插一条占位 "New Group" 等用户进 sidebar 右键改名。
    @State private var creatingGroup: Bool = false
    @State private var newGroupName: String = ""

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("")
        // .searchable 用系统原生 search field,自动塞到 toolbar 合适位置,
        // 样式跟 Notes/Mail 一致(灰色圆角胶囊 + 放大镜 + 占位符 + ⌘ + 取消圈)。
        .searchable(text: $search, prompt: "Search all notes")
        .alert(
            "Rename Group",
            isPresented: Binding(
                get: { renamingGroup != nil },
                set: { if !$0 { renamingGroup = nil } }
            ),
            presenting: renamingGroup
        ) { group in
            TextField("Group name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingGroup = nil }
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    group.name = trimmed
                    try? context.save()
                }
                renamingGroup = nil
            }
        } message: { _ in
            Text("Enter a new name for the group.")
        }
        .alert("New Group", isPresented: $creatingGroup) {
            TextField("Group name", text: $newGroupName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                _ = NoteGroup.create(in: context, name: trimmed)
                try? context.save()
            }
        } message: {
            Text("Enter a name for the new group.")
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: createGroup) {
                    Label("New Group", systemImage: "folder.badge.plus")
                }
                .help("New Group")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: createNote) {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .help("New Note (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    // MARK: Sidebar -------------------------------------------------------------

    private var sidebar: some View {
        List(selection: $selection) {
            // 没有任何 group 时,直接平铺所有笔记,不要画"Ungrouped"那种空头。
            if groups.isEmpty {
                ForEach(filteredAll, id: \.id) { note in
                    NoteSidebarRow(note: note)
                        .tag(note.id as Note.ID?)
                        .contextMenu { noteContextMenu(note) }
                }
            } else {
                ForEach(groups, id: \.id) { group in
                    Section {
                        ForEach(filteredNotes(in: group), id: \.id) { note in
                            NoteSidebarRow(note: note)
                                .tag(note.id as Note.ID?)
                                .contextMenu { noteContextMenu(note) }
                        }
                    } header: {
                        Text(group.name.isEmpty ? "Untitled" : group.name)
                            .contextMenu { groupContextMenu(group) }
                    }
                }
                if !ungroupedNotes.isEmpty {
                    Section("Ungrouped") {
                        ForEach(ungroupedNotes, id: \.id) { note in
                            NoteSidebarRow(note: note)
                                .tag(note.id as Note.ID?)
                                .contextMenu { noteContextMenu(note) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
    }

    // MARK: Detail --------------------------------------------------------------

    private var detail: some View {
        Group {
            if let id = selection,
               let note = allNotes.first(where: { $0.id == id && !$0.isDeleted }) {
                NoteDetailView(note: note, floating: floating)
            } else {
                ContentUnavailableView(
                    "Select a note",
                    systemImage: "note.text",
                    description: Text("Pick a note from the sidebar, or ⌘N to create one.")
                )
            }
        }
    }

    // MARK: Filtering -----------------------------------------------------------

    private var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredAll: [Note] {
        applyFilterAndSort(Array(allNotes))
    }

    private func filteredNotes(in group: NoteGroup) -> [Note] {
        applyFilterAndSort(Array(group.notes))
    }

    private var ungroupedNotes: [Note] {
        applyFilterAndSort(allNotes.filter { $0.group == nil })
    }

    /// pinned 的笔记永远排在前面;同 pinned 状态内按设置选的方式排。
    private func applyFilterAndSort(_ notes: [Note]) -> [Note] {
        let filtered = trimmedSearch.isEmpty
            ? notes
            : notes.filter { $0.content.localizedCaseInsensitiveContains(trimmedSearch) }
        let sort = NoteSort.from(noteSortRaw)
        return filtered.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            switch sort {
            case .dateEdited:  return lhs.updatedAt > rhs.updatedAt
            case .dateCreated: return lhs.createdAt > rhs.createdAt
            case .title:
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
            }
        }
    }

    // MARK: Actions -------------------------------------------------------------

    private func createNote() {
        let note = Note.create(in: context)
        try? context.save()
        selection = note.id
    }

    private func createGroup() {
        // 不再直接插占位条;弹 alert 先要用户输入名字,跟 Rename 体验一致。
        newGroupName = ""
        creatingGroup = true
    }

    @ViewBuilder
    private func noteContextMenu(_ note: Note) -> some View {
        Button("Open as Sticky") { floating.show(note: note) }
        Menu("Move to Group") {
            Button("Ungrouped") {
                note.group = nil
                try? context.save()
            }
            ForEach(groups, id: \.id) { g in
                Button(g.name.isEmpty ? "Untitled" : g.name) {
                    note.group = g
                    try? context.save()
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            if selection == note.id { selection = nil }
            floating.delete(note: note)
        }
    }

    @ViewBuilder
    private func groupContextMenu(_ group: NoteGroup) -> some View {
        Button("Rename") {
            renameText = group.name
            renamingGroup = group
        }
        Divider()
        Button("Delete Group", role: .destructive) {
            // 关系是 nullify:删 group 后,组里的 note 自动 ungrouped。
            context.delete(group)
            try? context.save()
        }
    }
}

// MARK: Sidebar row -----------------------------------------------------------

private struct NoteSidebarRow: View {
    @ObservedObject var note: Note

    var body: some View {
        if note.isDeleted || note.managedObjectContext == nil {
            EmptyView()
        } else {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(StickyPalette.from(index: note.colorIndex).color)
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                    .cornerRadius(1.5)
                let title = note.displayTitle
                let isEmpty = note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Text(isEmpty ? "Empty Note" : title)
                    .lineLimit(1)
                    .italic(isEmpty)
                    .foregroundStyle(isEmpty ? .secondary : .primary)
            }
            .frame(height: 22)
        }
    }
}

// MARK: Detail view -----------------------------------------------------------

private struct NoteDetailView: View {
    @ObservedObject var note: Note
    let floating: FloatingNotesRegistry
    @Environment(\.managedObjectContext) private var context

    var body: some View {
        if note.isDeleted || note.managedObjectContext == nil {
            EmptyView()
        } else {
            ZStack {
                StickyPalette.from(index: note.colorIndex).color
                    .ignoresSafeArea()
                // 直接复用 MarkdownNoteEditor 的双态(渲染 ↔ 编辑),管理窗口
                // 既能看也能改,跟浮窗里的体验一致。Open as Sticky 行为通过
                // sidebar 行右键菜单走,不再用大按钮占地方。
                MarkdownNoteEditor(text: Binding(
                    get: { note.content },
                    set: { newValue in
                        guard newValue != note.content else { return }
                        note.content = newValue
                        note.updatedAt = Date()
                        try? context.save()
                    }
                ))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
}
