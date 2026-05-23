import CoreData

/// V4 = V3 + `displayOrder: Int32`(default 0).
///
/// 改动来源:悬浮窗的显示顺序(stack 的层叠次序 / tile 的排列次序)此前只活在
/// `FloatingNotesRegistry.displayOrder` 内存数组里,从不落库 —— 重启后只能按
/// `updatedAt` 倒序重建,导致用户精心摆好的 stack/tile 排序在重启(以及任何
/// 改了 updatedAt 的编辑)后被打乱。V4 把这个序号持久化到每条 Note 上,启动
/// restore 按它排序,顺序跨重启稳定保持。
///
/// lightweight migration:`displayOrder` 是带 default(0)的非可选 int32,
/// 旧 sqlite 既有 row 自动补 0 —— 等同「未排序」,启动 restore 用
/// `[displayOrder ASC, updatedAt DESC]` 排序,全 0 时退化为旧的 updatedAt 倒序
/// 行为,首启动观感不变。属于最常见的「加字段」升级,
/// `shouldInferMappingModelAutomatically` 直接搞定。
/// 测试入口:Settings → iCloud Sync → "Run migration self-test"。
enum SchemaV4 {
    static let identifier = "v4"

    static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        model.versionIdentifiers = [identifier]

        // Note entity ------------------------------------------------------------
        let note = NSEntityDescription()
        note.name = "Note"
        note.managedObjectClassName = NSStringFromClass(Note.self)

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = true

        let content = NSAttributeDescription()
        content.name = "content"
        content.attributeType = .stringAttributeType
        content.isOptional = false
        content.defaultValue = ""

        let createdAt = NSAttributeDescription()
        createdAt.name = "createdAt"
        createdAt.attributeType = .dateAttributeType
        createdAt.isOptional = true

        let updatedAt = NSAttributeDescription()
        updatedAt.name = "updatedAt"
        updatedAt.attributeType = .dateAttributeType
        updatedAt.isOptional = true

        let isPinned = NSAttributeDescription()
        isPinned.name = "isPinned"
        isPinned.attributeType = .booleanAttributeType
        isPinned.isOptional = false
        isPinned.defaultValue = false

        let colorIndex = NSAttributeDescription()
        colorIndex.name = "colorIndex"
        colorIndex.attributeType = .integer16AttributeType
        colorIndex.isOptional = false
        colorIndex.defaultValue = 0

        let frameX = doubleAttr("frameX")
        let frameY = doubleAttr("frameY")
        let frameW = doubleAttr("frameW")
        let frameH = doubleAttr("frameH")

        let hasSavedFrame = NSAttributeDescription()
        hasSavedFrame.name = "hasSavedFrame"
        hasSavedFrame.attributeType = .booleanAttributeType
        hasSavedFrame.isOptional = false
        hasSavedFrame.defaultValue = false

        let isTrashed = NSAttributeDescription()
        isTrashed.name = "isTrashed"
        isTrashed.attributeType = .booleanAttributeType
        isTrashed.isOptional = false
        isTrashed.defaultValue = false

        let trashedAt = NSAttributeDescription()
        trashedAt.name = "trashedAt"
        trashedAt.attributeType = .dateAttributeType
        trashedAt.isOptional = true

        let isCollapsed = NSAttributeDescription()
        isCollapsed.name = "isCollapsed"
        isCollapsed.attributeType = .booleanAttributeType
        isCollapsed.isOptional = false
        isCollapsed.defaultValue = false

        let reminderDate = NSAttributeDescription()
        reminderDate.name = "reminderDate"
        reminderDate.attributeType = .dateAttributeType
        reminderDate.isOptional = true

        let isArchived = NSAttributeDescription()
        isArchived.name = "isArchived"
        isArchived.attributeType = .booleanAttributeType
        isArchived.isOptional = false
        isArchived.defaultValue = false

        let archivedAt = NSAttributeDescription()
        archivedAt.name = "archivedAt"
        archivedAt.attributeType = .dateAttributeType
        archivedAt.isOptional = true

        // V4 新增:悬浮窗显示序号。非可选 + default 0,旧库迁移既有 row 一律
        // 0(等同「未排序」)。启动 restore 按 [displayOrder ASC, updatedAt DESC]
        // 排,全 0 时退化为旧的 updatedAt 倒序。
        let displayOrder = NSAttributeDescription()
        displayOrder.name = "displayOrder"
        displayOrder.attributeType = .integer32AttributeType
        displayOrder.isOptional = false
        displayOrder.defaultValue = Int32(0)

        // NoteGroup entity ------------------------------------------------------
        let groupEntity = NSEntityDescription()
        groupEntity.name = "NoteGroup"
        groupEntity.managedObjectClassName = NSStringFromClass(NoteGroup.self)

        let groupId = NSAttributeDescription()
        groupId.name = "id"
        groupId.attributeType = .UUIDAttributeType
        groupId.isOptional = true

        let groupName = NSAttributeDescription()
        groupName.name = "name"
        groupName.attributeType = .stringAttributeType
        groupName.isOptional = false
        groupName.defaultValue = ""

        let groupCreatedAt = NSAttributeDescription()
        groupCreatedAt.name = "createdAt"
        groupCreatedAt.attributeType = .dateAttributeType
        groupCreatedAt.isOptional = true

        let groupSortOrder = NSAttributeDescription()
        groupSortOrder.name = "sortOrder"
        groupSortOrder.attributeType = .integer32AttributeType
        groupSortOrder.isOptional = false
        groupSortOrder.defaultValue = Int32(0)

        // Relationships ---------------------------------------------------------
        let noteToGroup = NSRelationshipDescription()
        noteToGroup.name = "group"
        noteToGroup.destinationEntity = groupEntity
        noteToGroup.maxCount = 1
        noteToGroup.minCount = 0
        noteToGroup.isOptional = true
        noteToGroup.deleteRule = .nullifyDeleteRule

        let groupToNotes = NSRelationshipDescription()
        groupToNotes.name = "notes"
        groupToNotes.destinationEntity = note
        groupToNotes.maxCount = 0
        groupToNotes.minCount = 0
        groupToNotes.isOptional = true
        groupToNotes.deleteRule = .nullifyDeleteRule

        noteToGroup.inverseRelationship = groupToNotes
        groupToNotes.inverseRelationship = noteToGroup

        note.properties = [
            id, content, createdAt, updatedAt, isPinned, colorIndex,
            frameX, frameY, frameW, frameH, hasSavedFrame,
            isTrashed, trashedAt, isCollapsed, reminderDate,
            isArchived, archivedAt, displayOrder,
            noteToGroup
        ]
        groupEntity.properties = [groupId, groupName, groupCreatedAt, groupSortOrder, groupToNotes]
        model.entities = [note, groupEntity]
        return model
    }

    private static func doubleAttr(_ name: String) -> NSAttributeDescription {
        let attr = NSAttributeDescription()
        attr.name = name
        attr.attributeType = .doubleAttributeType
        attr.isOptional = false
        attr.defaultValue = 0.0
        return attr
    }
}
