import CoreData

/// V2 = V1 + `reminderDate: Date?`(笔记提醒时间)。
///
/// 改动来源:浮窗顶栏铃铛按钮调度本地 UNUserNotification。reminderDate
/// 单纯是「用户上次在 UI 上选的时间」的持久化记忆,UNUserNotificationCenter
/// 自己持有 pending request 队列并在系统重启后保留,不依赖这个字段重建
/// 调度。但保留它意味着用户切换设备(CloudKit)/重装 App 后,设过的提醒能
/// 在 UI 上体现出来,且新设备可以选择「重新调度还在未来的提醒」。
///
/// lightweight migration:加 optional 字段,旧 sqlite 一字段补 NULL 即可。
/// 测试入口:Settings → iCloud Sync → "Run migration self-test"。
enum SchemaV2 {
    static let identifier = "v2"

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

        // V2 新增:一次性提醒时间。nil = 没设提醒。
        // optional + 无 default,旧库迁移时既有 row 一律 NULL,等同「没提醒」。
        let reminderDate = NSAttributeDescription()
        reminderDate.name = "reminderDate"
        reminderDate.attributeType = .dateAttributeType
        reminderDate.isOptional = true

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
