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
    /// 回收站项数。展示在 sidebar 底部的徽章,数据源跟 TrashDetailView 共享
    /// 同一个 store —— 同一个 viewContext 改动后两边都会自动刷新。
    @FetchRequest(fetchRequest: Note.trashedFetchRequest(), animation: .default)
    private var trashedNotes: FetchedResults<Note>

    /// **多选**:`List(selection:)` 给 `Binding<Set<Hashable>>` 时,系统自动支持
    /// Cmd-click(切换单条入/出选区)和 Shift-click(范围选)—— 跟 Finder/Notes
    /// 一致,不需要自己拦事件。空集合表示没选;单选时取唯一元素显示详情。
    @State private var selection: Set<Note.ID> = []
    /// 进 Trash 视图。Trash 不在 List selection 里(不跟 note 混选),用一个独立
    /// state 切。点击其它任何 note 会把这个清回 false(由 onChange 处理)。
    @State private var viewingTrash: Bool = false
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
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("")
        // .searchable 用系统原生 search field,自动塞到 toolbar 合适位置,
        // 样式跟 Notes/Mail 一致(灰色圆角胶囊 + 放大镜 + 占位符 + ⌘ + 取消圈)。
        .searchable(text: $search, prompt: L.t(.managerSearch))
        .alert(
            L.t(.managerRenameAlertTitle),
            isPresented: Binding(
                get: { renamingGroup != nil },
                set: { if !$0 { renamingGroup = nil } }
            ),
            presenting: renamingGroup
        ) { group in
            TextField(L.t(.managerGroupNamePlaceholder), text: $renameText)
            Button(L.t(.cancel), role: .cancel) { renamingGroup = nil }
            Button(L.t(.save)) {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    group.name = trimmed
                    try? context.save()
                }
                renamingGroup = nil
            }
        } message: { _ in
            Text(L.t(.managerRenameMessage))
        }
        .alert(L.t(.managerNewGroupAlertTitle), isPresented: $creatingGroup) {
            TextField(L.t(.managerGroupNamePlaceholder), text: $newGroupName)
            Button(L.t(.cancel), role: .cancel) {}
            Button(L.t(.managerCreate)) {
                let trimmed = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                _ = NoteGroup.create(in: context, name: trimmed)
                try? context.save()
            }
        } message: {
            Text(L.t(.managerNewGroupMessage))
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: createGroup) {
                    Label(L.t(.managerNewGroup), systemImage: "folder.badge.plus")
                }
                .help(L.t(.managerNewGroup))
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: createNote) {
                    Label(L.t(.managerNewNote), systemImage: "square.and.pencil")
                }
                .help(L.t(.managerNewNote) + " (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    // MARK: Sidebar -------------------------------------------------------------

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                // 没有任何 group 时,直接平铺所有笔记,不要画"Ungrouped"那种空头。
                if groups.isEmpty {
                    ForEach(filteredAll, id: \.id) { note in
                        NoteSidebarRow(note: note)
                            .tag(note.id)
                            .contextMenu { noteContextMenu(note) }
                    }
                } else {
                    ForEach(groups, id: \.id) { group in
                        Section {
                            ForEach(filteredNotes(in: group), id: \.id) { note in
                                NoteSidebarRow(note: note)
                                    .tag(note.id)
                                    .contextMenu { noteContextMenu(note) }
                            }
                        } header: {
                            Text(group.name.isEmpty ? L.t(.untitled) : group.name)
                                .contextMenu { groupContextMenu(group) }
                        }
                    }
                    if !ungroupedNotes.isEmpty {
                        Section(L.t(.managerUngrouped)) {
                            ForEach(ungroupedNotes, id: \.id) { note in
                                NoteSidebarRow(note: note)
                                    .tag(note.id)
                                    .contextMenu { noteContextMenu(note) }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // 选中任何 note 时立刻退出 Trash 视图。这是单向耦合 —— 选 Trash 时
            // 我们手动清掉 selection;选 note 时这里把 viewingTrash 关掉。
            .onChange(of: selection) { _, new in
                if !new.isEmpty { viewingTrash = false }
            }

            Divider()
            TrashSidebarRow(
                count: trashedNotes.count,
                active: viewingTrash,
                onTap: {
                    viewingTrash = true
                    selection = []
                }
            )
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
    }

    // MARK: Detail --------------------------------------------------------------

    private var detail: some View {
        Group {
            if viewingTrash {
                TrashDetailView(floating: floating)
            } else if selection.count == 1,
               let id = selection.first,
               let note = allNotes.first(where: { $0.id == id && !$0.isDeleted }) {
                NoteDetailView(note: note, floating: floating)
            } else if selection.count > 1 {
                ContentUnavailableView(
                    L.t(.managerMultiSelected, selection.count),
                    systemImage: "square.stack",
                    description: Text(L.t(.managerMultiSelectedDesc))
                )
            } else {
                ContentUnavailableView(
                    L.t(.managerSelectNote),
                    systemImage: "note.text",
                    description: Text(L.t(.managerSelectNoteDesc))
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
        selection = [note.id]
    }

    private func createGroup() {
        // 不再直接插占位条;弹 alert 先要用户输入名字,跟 Rename 体验一致。
        newGroupName = ""
        creatingGroup = true
    }

    /// 右键命中**选中**项里的某个 → 作用于整组当前选中(Finder/Notes 标准行为);
    /// 命中**未选**的项 → 只作用于这一条。返回数组保证至少一项。
    private func contextTargets(for note: Note) -> [Note] {
        if selection.contains(note.id), selection.count > 1 {
            return allNotes.filter { selection.contains($0.id) }
        }
        return [note]
    }

    @ViewBuilder
    private func noteContextMenu(_ note: Note) -> some View {
        let targets = contextTargets(for: note)
        let multi = targets.count > 1

        // Open as Sticky 只对单条有意义;批量同时弹一堆浮窗会糊屏。
        if !multi {
            Button(L.t(.managerOpenAsSticky)) { floating.show(note: note) }
        }

        Menu(multi ? L.t(.managerMoveNotesToGroup, targets.count) : L.t(.managerMoveToGroup)) {
            Button(L.t(.managerUngrouped)) {
                for n in targets { n.group = nil }
                try? context.save()
            }
            ForEach(groups, id: \.id) { g in
                Button(g.name.isEmpty ? L.t(.untitled) : g.name) {
                    for n in targets { n.group = g }
                    try? context.save()
                }
            }
        }
        Divider()
        Button(multi ? L.t(.managerDeleteCount, targets.count) : L.t(.managerDeleteNote), role: .destructive) {
            for n in targets {
                selection.remove(n.id)
                floating.delete(note: n)
            }
        }
    }

    @ViewBuilder
    private func groupContextMenu(_ group: NoteGroup) -> some View {
        Button(L.t(.managerRename)) {
            renameText = group.name
            renamingGroup = group
        }
        Divider()
        Button(L.t(.managerDeleteGroup), role: .destructive) {
            // 关系是 nullify:删 group 后,组里的 note 自动 ungrouped。
            context.delete(group)
            try? context.save()
        }
    }
}

// MARK: Sidebar row -----------------------------------------------------------

private struct NoteSidebarRow: View {
    @ObservedObject var note: Note
    @ObservedObject private var loc = LocalizationManager.shared

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
                Text(isEmpty ? L.t(.emptyNote) : title)
                    .lineLimit(1)
                    .italic(isEmpty)
                    .foregroundStyle(isEmpty ? .secondary : .primary)
            }
            .frame(height: 22)
        }
    }
}

// MARK: Detail view -----------------------------------------------------------

// MARK: Trash sidebar row -----------------------------------------------------

/// Sidebar 底部的 Trash 入口。手动绘制成"高亮态/默认态"两种,不进 List
/// selection 队列,这样不和 note 多选混在一起。徽章显示 trash 笔记数量。
private struct TrashSidebarRow: View {
    let count: Int
    let active: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                    .frame(width: 16)
                Text(L.t(.trashTitle))
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Color.secondary.opacity(0.18))
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? Color.accentColor.opacity(0.18) : .clear)
                    .padding(.horizontal, 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }
}

// MARK: Trash detail ---------------------------------------------------------

/// 回收站列表 + Empty Trash 按钮。每行显示标题 + trashedAt 相对时间,行尾
/// Restore / Delete Permanently。点 Empty Trash 弹一个 alert 二次确认 ——
/// 整体真删,这步不能误触。
private struct TrashDetailView: View {
    let floating: FloatingNotesRegistry
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(fetchRequest: Note.trashedFetchRequest(), animation: .default)
    private var trashed: FetchedResults<Note>
    @State private var confirmingEmpty = false
    @State private var confirmingDelete: Note?
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if trashed.isEmpty {
                ContentUnavailableView(
                    L.t(.trashEmpty),
                    systemImage: "trash",
                    description: Text(L.t(.trashEmptyDesc))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(trashed, id: \.id) { note in
                        TrashRow(
                            note: note,
                            onRestore: { floating.restore(note: note) },
                            onDelete: { confirmingDelete = note }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .alert(
            L.t(.trashEmptyAlert),
            isPresented: $confirmingEmpty
        ) {
            Button(L.t(.trashEmptyButton), role: .destructive) {
                floating.emptyTrash(in: context)
            }
            Button(L.t(.cancel), role: .cancel) {}
        } message: {
            Text(L.t(.trashEmptyAlertMsg))
        }
        .alert(
            L.t(.trashDeleteAlert),
            isPresented: Binding(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } }
            ),
            presenting: confirmingDelete
        ) { note in
            Button(L.t(.delete), role: .destructive) {
                floating.deletePermanently(note: note)
                confirmingDelete = nil
            }
            Button(L.t(.cancel), role: .cancel) { confirmingDelete = nil }
        } message: { _ in
            Text(L.t(.trashDeleteAlertMsg))
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "trash")
            Text(L.t(.trashTitle))
                .font(.title3.weight(.semibold))
            Text("(\(trashed.count))")
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                confirmingEmpty = true
            } label: {
                Label(L.t(.trashEmptyButton), systemImage: "trash.slash")
            }
            .disabled(trashed.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct TrashRow: View {
    @ObservedObject var note: Note
    @ObservedObject private var loc = LocalizationManager.shared
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        if note.isDeleted || note.managedObjectContext == nil {
            EmptyView()
        } else {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(StickyPalette.from(index: note.colorIndex).color)
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                    .cornerRadius(1.5)

                VStack(alignment: .leading, spacing: 2) {
                    let isEmpty = note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Text(isEmpty ? L.t(.emptyNote) : note.displayTitle)
                        .lineLimit(1)
                        .italic(isEmpty)
                        .foregroundStyle(isEmpty ? .secondary : .primary)
                    Text(trashedAtLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(L.t(.restore), action: onRestore)
                    .buttonStyle(.bordered)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .help(L.t(.trashDeletePermanentlyHelp))
            }
            .padding(.vertical, 4)
        }
    }

    /// "丢进回收站 X 之前"。30 天后启动时自动清,所以最大也就是 30 多天。
    private var trashedAtLabel: String {
        guard let when = note.trashedAt else { return L.t(.trashTitle) }
        let formatter = RelativeDateTimeFormatter()
        // RelativeDateTimeFormatter 跟 LocalizationManager 选的语言对齐 ——
        // .system 退回 Locale.current,显式选英/中则强制用对应 locale。
        switch LocalizationManager.shared.effective {
        case .english: formatter.locale = Locale(identifier: "en")
        case .chinese: formatter.locale = Locale(identifier: "zh-Hans")
        case .system:  break
        }
        formatter.unitsStyle = .full
        return L.t(.trashedRelative, formatter.localizedString(for: when, relativeTo: Date()) as NSString)
    }
}

// MARK: Note detail ----------------------------------------------------------

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
