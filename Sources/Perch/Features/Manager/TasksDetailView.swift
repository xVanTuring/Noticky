import SwiftUI
import CoreData

/// 管理窗口里「全部任务」视图的数据聚合。把所有活跃笔记里的 markdown 任务行
/// (`- [ ]` / `- [x]`)按笔记分组、按缩进建父子树,再筛成「未完成」清单 ——
/// **未完成本身,或子树里还有未完成的**都保留。后一种情况下那个已完成的父
/// 任务作为上下文表头出现(展示但不可勾,见 `TaskRow`)。
///
/// 任务不是独立实体,完全从 `Note.content` 派生(见 `Note.parsedTasks`),所以
/// 这里每次随 `@FetchRequest` 重算即可,无需 schema / 缓存。回写走
/// `Note.toggledTaskContent`,改的是源笔记的 content,浮窗/详情同一 viewContext
/// 自动联动刷新。
enum TaskAggregator {
    /// 展平后的一行待办,`depth` 是树层级(0=顶层),用于视觉缩进 —— 跟用户写
    /// 2 还是 4 个空格无关,始终按层级对齐。
    struct RowItem: Identifiable {
        let task: Note.ParsedTask
        let depth: Int
        /// 同一笔记内 lineIndex 唯一,够做 ForEach 身份。
        var id: Int { task.lineIndex }
    }

    /// 一条笔记 + 它筛选后的待办行。`note` 留引用是为了回写与点击跳转。
    struct Group: Identifiable {
        let note: Note
        let rows: [RowItem]
        var id: NSManagedObjectID { note.objectID }
        /// 真正未完成(可勾)的条数,不含被保留的已完成父行。
        var openCount: Int { rows.reduce(0) { $0 + ($1.task.isDone ? 0 : 1) } }
    }

    /// 建分组。无任务、或筛完没有任何未完成项的笔记被跳过。
    static func build<S: Sequence>(from notes: S) -> [Group] where S.Element == Note {
        var result: [Group] = []
        for note in notes where !note.isDeleted && note.managedObjectContext != nil {
            let tasks = note.parsedTasks
            guard !tasks.isEmpty else { continue }
            var roots = buildTree(tasks)
            roots = roots.compactMap(prune)
            guard !roots.isEmpty else { continue }
            var rows: [RowItem] = []
            flatten(roots, depth: 0, into: &rows)
            result.append(Group(note: note, rows: rows))
        }
        return result
    }

    /// sidebar 徽章用的未完成总数。比 `build` 轻 —— 不建树,直接数未勾选行
    /// (剪枝从不丢弃未完成项,所以两者口径一致)。
    static func openTaskCount<S: Sequence>(from notes: S) -> Int where S.Element == Note {
        var n = 0
        for note in notes where !note.isDeleted && note.managedObjectContext != nil {
            for t in note.parsedTasks where !t.isDone { n += 1 }
        }
        return n
    }

    // MARK: tree

    private final class Node {
        let task: Note.ParsedTask
        var children: [Node] = []
        init(_ task: Note.ParsedTask) { self.task = task }
    }

    /// 平铺任务按缩进建树:缩进更深的挂到前面最近的浅缩进项下。
    private static func buildTree(_ tasks: [Note.ParsedTask]) -> [Node] {
        var roots: [Node] = []
        var stack: [Node] = []
        for task in tasks {
            let node = Node(task)
            while let top = stack.last, top.task.indent >= task.indent { stack.removeLast() }
            if let parent = stack.last { parent.children.append(node) }
            else { roots.append(node) }
            stack.append(node)
        }
        return roots
    }

    /// 原地剪枝:保留「未完成 **或** 还有保留下来的后代」的节点。已完成且子树
    /// 全清空的节点被丢弃。返回 nil = 整棵子树都该丢。
    private static func prune(_ node: Node) -> Node? {
        node.children = node.children.compactMap(prune)
        return (!node.task.isDone || !node.children.isEmpty) ? node : nil
    }

    private static func flatten(_ nodes: [Node], depth: Int, into rows: inout [RowItem]) {
        for node in nodes {
            rows.append(RowItem(task: node.task, depth: depth))
            flatten(node.children, depth: depth + 1, into: &rows)
        }
    }
}

// MARK: - View

/// 「全部任务」详情页。仿 Archive/Trash 详情的版式:顶部标题条 + 分组列表。
/// 每个分组头是来源笔记(点一下跳到那条笔记),组内是未完成待办,勾选直接
/// 回写源笔记。
struct TasksDetailView: View {
    /// 点分组头跳到对应笔记 —— 由 ManagerView 把 selection 设过去。
    let onSelectNote: (Note) -> Void
    @Environment(\.managedObjectContext) private var context
    // 跟 ManagerView 共用 store:回写 save 后这里和侧边栏徽章一起刷新。
    @FetchRequest(fetchRequest: Note.sortedFetchRequest(), animation: .default)
    private var notes: FetchedResults<Note>
    @ObservedObject private var loc = LocalizationManager.shared

    var body: some View {
        let groups = TaskAggregator.build(from: notes)
        let total = groups.reduce(0) { $0 + $1.openCount }
        VStack(spacing: 0) {
            header(total: total)
            Divider()
            if groups.isEmpty {
                ContentUnavailableView(
                    L.t(.tasksEmpty),
                    systemImage: "checklist",
                    description: Text(L.t(.tasksEmptyDesc))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.rows) { row in
                                TaskRow(item: row) { toggle(group.note, row.task) }
                            }
                        } header: {
                            groupHeader(group.note)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func header(total: Int) -> some View {
        HStack {
            Image(systemName: "checklist")
            Text(L.t(.tasksTitle))
                .font(.title3.weight(.semibold))
            Text("(\(total))")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func groupHeader(_ note: Note) -> some View {
        Button {
            onSelectNote(note)
        } label: {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(StickyPalette.from(index: note.colorIndex).swatchFill)
                    .frame(width: 3, height: 12)
                    .cornerRadius(1.5)
                let isEmpty = note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Text(isEmpty ? L.t(.emptyNote) : note.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L.t(.managerOpenAsSticky))
    }

    /// 勾选回写:翻转源笔记里那一行的勾选记号,bump updatedAt 后 save。定位失败
    /// (笔记已被别处改得对不上)就静默不动 —— `toggledTaskContent` 返回 nil。
    private func toggle(_ note: Note, _ task: Note.ParsedTask) {
        guard !note.isDeleted, note.managedObjectContext != nil else { return }
        guard let newContent = Note.toggledTaskContent(
            note.content,
            lineIndex: task.lineIndex,
            expectedRaw: task.rawLine,
            setDone: !task.isDone
        ) else { return }
        note.content = newContent
        note.updatedAt = Date()
        try? context.save()
    }
}

/// 单行待办。未完成 → 空心圈按钮,点一下回写勾上;已完成(只会是被保留的
/// 父任务上下文行)→ 灰色实心勾、删除线、不可点。缩进按 `depth` 层级。
private struct TaskRow: View {
    let item: TaskAggregator.RowItem
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if item.task.isDone {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Text(label)
                    .foregroundStyle(.secondary)
                    .strikethrough(true, color: .secondary)
                    .lineLimit(2)
            } else {
                Button(action: onToggle) {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L.t(.tasksTitle))
                Text(label)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(item.depth) * 16)
        .padding(.vertical, 1)
    }

    /// 空标签(光秃秃的 `- [ ]`)给个占位符,免得整行没东西点不准。
    private var label: String {
        item.task.label.isEmpty ? "—" : item.task.label
    }
}
