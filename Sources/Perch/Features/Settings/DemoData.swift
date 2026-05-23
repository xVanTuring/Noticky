#if DEBUG
import CoreData
import Foundation

/// **仅 DEBUG** 的演示数据填充。Settings → General → Data 里那个 "Fill Demo
/// Data" 按钮调它,一键造一批覆盖各种状态的便签 + 分组,方便手测列表 / 排序 /
/// 分组 / 归档 / 回收站 / 调色板 / Markdown 渲染,而不用手敲。
///
/// Release 构建里整个文件 `#if DEBUG` 编掉 —— 终端用户没有也不该有这个入口。
/// 内容**全英文**(按需求),且每次调用都新建(按下多次会累积,dev 自己清楚;
/// 想回到干净态用同一区块的「清空全部内容」)。
enum DemoData {

    /// 造演示数据并 save。返回 (新建便签数, 新建分组数)。
    @discardableResult
    static func fill(into context: NSManagedObjectContext) -> (notes: Int, groups: Int) {
        let now = Date()
        // createdAt/updatedAt 往回铺开,排序 / 相对时间显示才有层次。
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

        // 确定性计数 —— 不用 context.insertedObjects(会把无关的 pending insert
        // 也算进来)。
        var noteCount = 0
        var groupCount = 0

        func makeGroup(_ name: String, order: Int32, createdAgo: Double) -> NoteGroup {
            let g = NoteGroup(context: context)
            g.id = UUID()
            g.name = name
            g.createdAt = ago(createdAgo)
            g.sortOrder = order
            groupCount += 1
            return g
        }

        @discardableResult
        func makeNote(
            _ content: String,
            color: Int16 = 0,
            createdAgo: Double,
            updatedAgo: Double? = nil,
            group: NoteGroup? = nil,
            archived: Bool = false,
            trashed: Bool = false
        ) -> Note {
            let n = Note(context: context)
            n.id = UUID()
            n.content = content
            n.createdAt = ago(createdAgo)
            n.updatedAt = ago(updatedAgo ?? createdAgo)
            // **必须 false**:isPinned 在本项目里 = 「浮窗已打开 / 开机自动恢复」
            //(见 CLAUDE.md),不是普通的「用户收藏」。造数据时设 true 却没真的
            // spawn 浮窗,会让 menubar 的 active 徽标算进这些「幽灵 pinned」,
            // 数字比实际可见浮窗多 —— 想测 pinned 就开机后手动打开浮窗。
            n.isPinned = false
            n.colorIndex = color
            n.hasSavedFrame = false
            n.isCollapsed = false
            n.isArchived = archived
            n.archivedAt = archived ? ago(updatedAgo ?? createdAgo) : nil
            n.isTrashed = trashed
            n.trashedAt = trashed ? ago(updatedAgo ?? createdAgo) : nil
            n.group = group
            noteCount += 1
            return n
        }

        let work = makeGroup("Work", order: 0, createdAgo: 240)
        let personal = makeGroup("Personal", order: 1, createdAgo: 200)
        let ideas = makeGroup("Ideas", order: 2, createdAgo: 160)

        // --- Work -------------------------------------------------------------
        makeNote("""
        # Sprint planning

        - [x] Carry over open bugs
        - [ ] Estimate the export epic
        - [ ] Book the demo room

        Owner: **me** — review by Friday.
        """, color: 2, createdAgo: 30, updatedAgo: 1, group: work)

        makeNote("""
        Standup notes

        Yesterday: finished the SQLite import path.
        Today: wire the Settings data section.
        Blockers: none.
        """, color: 0, createdAgo: 26, updatedAgo: 4, group: work)

        makeNote("""
        1:1 agenda
        - Roadmap for Q3
        - Headcount
        - On-call rotation
        """, color: 5, createdAgo: 72, updatedAgo: 50, group: work)

        // --- Personal ---------------------------------------------------------
        makeNote("""
        Groceries

        - Coffee beans
        - Olive oil
        - Oranges
        - Sparkling water
        """, color: 3, createdAgo: 18, updatedAgo: 2, group: personal)

        makeNote("Call the dentist to reschedule next week's appointment.",
                 color: 1, createdAgo: 90, updatedAgo: 90, group: personal)

        // --- Ideas ------------------------------------------------------------
        makeNote("""
        # App ideas

        A few things worth prototyping:

        1. Markdown export with front-matter
        2. Quick capture from the share sheet
        3. Per-note reminders with snooze

        See the [design doc](https://example.com/doc) for context.

        ```swift
        let answer = 41 + 1
        print("the answer is \\(answer)")
        ```
        """, color: 4, createdAgo: 120, updatedAgo: 6, group: ideas)

        makeNote("> The best way to predict the future is to invent it.\n\n— Alan Kay",
                 color: 4, createdAgo: 130, updatedAgo: 130, group: ideas)

        // --- Ungrouped --------------------------------------------------------
        makeNote("Quick scratch note — paste things here, sort later.",
                 color: 0, createdAgo: 5, updatedAgo: 0.5)

        makeNote("   ", color: 5, createdAgo: 3, updatedAgo: 3) // empty-ish: tests "Empty Note"

        // --- Archived ---------------------------------------------------------
        makeNote("""
        Old project retro (archived)

        What went well, what didn't. Kept for reference, off the main list.
        """, color: 3, createdAgo: 600, updatedAgo: 500, group: work, archived: true)

        makeNote("Conference talk outline — done and archived.",
                 color: 2, createdAgo: 540, updatedAgo: 520, archived: true)

        // --- Trash ------------------------------------------------------------
        makeNote("Draft email I decided not to send.",
                 color: 1, createdAgo: 48, updatedAgo: 12, trashed: true)

        makeNote("Duplicate note — moved to Trash.",
                 color: 0, createdAgo: 60, updatedAgo: 20, group: personal, trashed: true)

        try? context.save()
        return (noteCount, groupCount)
    }
}
#endif
