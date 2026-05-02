import CoreData

final class PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        let model = Self.makeModel()
        // Phase 1: 本地存储。Phase 3 切到 NSPersistentCloudKitContainer 即可,
        // 同一个 model 兼容。
        container = NSPersistentContainer(name: "Noticky", managedObjectModel: model)

        if inMemory, let desc = container.persistentStoreDescriptions.first {
            desc.url = URL(fileURLWithPath: "/dev/null")
        }
        if let desc = container.persistentStoreDescriptions.first {
            desc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            // 程序化 model 没有 .xcdatamodeld 版本号,但「加新属性 + 给默认值」这种
            // 改动 Core Data 还是会尝试 inferred mapping。开了不一定成,失败时
            // loadStores 会走删库重建路径兜底。能成的话用户笔记就保住了。
            desc.shouldMigrateStoreAutomatically = true
            desc.shouldInferMappingModelAutomatically = true

            // Sandbox 关掉之后 NSPersistentContainer 默认路径从
            //   ~/Library/Containers/<bundle>/Data/Library/Application Support/Noticky/
            // 变成
            //   ~/Library/Application Support/Noticky/
            // 老用户在沙盒容器里的 sqlite 不再可见,启动时一次性把它(以及 -shm/-wal)
            // 拷贝过来,新位置已有库则跳过。拷贝不删除老文件,留作回滚兜底。
            if !inMemory, let target = desc.url {
                Self.migrateFromSandboxContainerIfNeeded(target: target)
            }
        }

        Self.loadStores(in: container, retryOnFailure: !inMemory)
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    /// 一次性迁移:沙盒容器里的 sqlite 三件套 → 新的 Application Support 路径。
    /// 仅当目标不存在 + 老库存在 时执行。失败/缺权限时静默跳过,Core Data
    /// 后面会照常从空目标建一个新库;数据没了,但启动不挂。
    private static func migrateFromSandboxContainerIfNeeded(target: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { return }

        // 沙盒模式下 NSPersistentContainer 用的就是这个路径;关掉沙盒后系统不再
        // 把 ~/Library/... 重定向到 Containers/<bundle>/Data/...,但旧文件还在。
        let bundleID = "tech.xvanturing.Noticky"
        let home = fm.homeDirectoryForCurrentUser
        let oldDir = home
            .appendingPathComponent("Library/Containers")
            .appendingPathComponent(bundleID)
            .appendingPathComponent("Data/Library/Application Support/Noticky")
        let oldStore = oldDir.appendingPathComponent(target.lastPathComponent)
        guard fm.fileExists(atPath: oldStore.path) else { return }

        do {
            try fm.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            for suffix in ["", "-shm", "-wal"] {
                let from = oldDir.appendingPathComponent(target.lastPathComponent + suffix)
                let to = target.deletingLastPathComponent()
                    .appendingPathComponent(target.lastPathComponent + suffix)
                guard fm.fileExists(atPath: from.path) else { continue }
                if fm.fileExists(atPath: to.path) { continue }
                try fm.copyItem(at: from, to: to)
            }
            NSLog("Noticky: migrated Core Data store from sandbox container to %@", target.path)
        } catch {
            NSLog("Noticky: store migration failed: %@", "\(error)")
        }
    }

    /// 程序化 model 没有 .xcdatamodeld 版本号,schema 改动时 Core Data 推不出
    /// 迁移 mapping。Phase 1 阶段直接删旧库重建——开发测试数据不值得保留。
    private static func loadStores(in container: NSPersistentContainer, retryOnFailure: Bool) {
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        guard let error = loadError else { return }

        guard retryOnFailure,
              let desc = container.persistentStoreDescriptions.first,
              let url = desc.url else {
            fatalError("Noticky: failed to load persistent store: \(error)")
        }

        NSLog("Noticky: store load failed (%@), nuking %@ and retrying", "\(error)", url.path)
        let fm = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            let target = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + suffix)
            try? fm.removeItem(at: target)
        }

        var retryError: Error?
        container.loadPersistentStores { _, error in retryError = error }
        if let retryError {
            fatalError("Noticky: store reset still failed: \(retryError)")
        }
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let note = NSEntityDescription()
        note.name = "Note"
        note.managedObjectClassName = NSStringFromClass(Note.self)

        let id = NSAttributeDescription()
        id.name = "id"
        id.attributeType = .UUIDAttributeType
        id.isOptional = false

        let content = NSAttributeDescription()
        content.name = "content"
        content.attributeType = .stringAttributeType
        content.isOptional = false
        content.defaultValue = ""

        let createdAt = NSAttributeDescription()
        createdAt.name = "createdAt"
        createdAt.attributeType = .dateAttributeType
        createdAt.isOptional = false

        let updatedAt = NSAttributeDescription()
        updatedAt.name = "updatedAt"
        updatedAt.attributeType = .dateAttributeType
        updatedAt.isOptional = false

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

        let frameX = Self.doubleAttr("frameX")
        let frameY = Self.doubleAttr("frameY")
        let frameW = Self.doubleAttr("frameW")
        let frameH = Self.doubleAttr("frameH")

        let hasSavedFrame = NSAttributeDescription()
        hasSavedFrame.name = "hasSavedFrame"
        hasSavedFrame.attributeType = .booleanAttributeType
        hasSavedFrame.isOptional = false
        hasSavedFrame.defaultValue = false

        // 软删除:笔记进回收站置 isTrashed=true + trashedAt=now。所有"普通"
        // fetch 都加 isTrashed==false 过滤,只有 Trash 视图查 ==true。30 天后
        // 由启动时的 purge 真正 context.delete。
        let isTrashed = NSAttributeDescription()
        isTrashed.name = "isTrashed"
        isTrashed.attributeType = .booleanAttributeType
        isTrashed.isOptional = false
        isTrashed.defaultValue = false

        let trashedAt = NSAttributeDescription()
        trashedAt.name = "trashedAt"
        trashedAt.attributeType = .dateAttributeType
        trashedAt.isOptional = true

        // NoteGroup entity --------------------------------------------------------
        let groupEntity = NSEntityDescription()
        groupEntity.name = "NoteGroup"
        groupEntity.managedObjectClassName = NSStringFromClass(NoteGroup.self)

        let groupId = NSAttributeDescription()
        groupId.name = "id"
        groupId.attributeType = .UUIDAttributeType
        groupId.isOptional = false

        let groupName = NSAttributeDescription()
        groupName.name = "name"
        groupName.attributeType = .stringAttributeType
        groupName.isOptional = false
        groupName.defaultValue = ""

        let groupCreatedAt = NSAttributeDescription()
        groupCreatedAt.name = "createdAt"
        groupCreatedAt.attributeType = .dateAttributeType
        groupCreatedAt.isOptional = false

        let groupSortOrder = NSAttributeDescription()
        groupSortOrder.name = "sortOrder"
        groupSortOrder.attributeType = .integer32AttributeType
        groupSortOrder.isOptional = false
        groupSortOrder.defaultValue = Int32(0)

        // Relationships ----------------------------------------------------------
        // Note <-> NoteGroup,多对一。任何一方删除都 nullify(保留对方),不级联。
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
        groupToNotes.maxCount = 0  // unlimited
        groupToNotes.minCount = 0
        groupToNotes.isOptional = true
        groupToNotes.deleteRule = .nullifyDeleteRule

        noteToGroup.inverseRelationship = groupToNotes
        groupToNotes.inverseRelationship = noteToGroup

        note.properties = [
            id, content, createdAt, updatedAt, isPinned, colorIndex,
            frameX, frameY, frameW, frameH, hasSavedFrame,
            isTrashed, trashedAt,
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
