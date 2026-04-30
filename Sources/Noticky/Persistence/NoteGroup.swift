import CoreData

/// 笔记分组。Note 和 NoteGroup 是多对一关系 —— 一个 Note 最多属于一个 Group;
/// note.group == nil 表示未分组,在管理窗口里显示在 "Ungrouped" 区段。
@objc(NoteGroup)
public final class NoteGroup: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var createdAt: Date
    @NSManaged public var sortOrder: Int32
    @NSManaged public var notes: Set<Note>
}

extension NoteGroup {
    static func sortedFetchRequest() -> NSFetchRequest<NoteGroup> {
        let request = NSFetchRequest<NoteGroup>(entityName: "NoteGroup")
        request.sortDescriptors = [
            NSSortDescriptor(key: "sortOrder", ascending: true),
            NSSortDescriptor(key: "createdAt", ascending: true)
        ]
        return request
    }

    @discardableResult
    static func create(in context: NSManagedObjectContext, name: String) -> NoteGroup {
        let group = NoteGroup(context: context)
        group.id = UUID()
        group.name = name
        group.createdAt = Date()
        // 新分组排到最后:取当前最大 sortOrder + 1。
        let maxOrder = (try? context.fetch(sortedFetchRequest()).map(\.sortOrder).max()) ?? 0
        group.sortOrder = maxOrder + 1
        return group
    }

    var notesSortedByPin: [Note] {
        notes.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }
}
