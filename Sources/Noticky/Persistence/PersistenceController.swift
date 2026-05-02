import CoreData

/// CloudKit container 标识。规则:`iCloud.<bundle-id>` 是 Apple 推荐的命名,
/// developer portal 创建 CloudKit Container 时用同名即可。改这里之前先在
/// portal 把新名字注册好,否则 NSPersistentCloudKitContainer 启动会报
/// CKErrorPartialFailure(invalid container)。
enum CloudKitConfig {
    static let containerIdentifier = "iCloud.tech.xvanturing.Noticky"
}

final class PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer
    /// 真正用上 CloudKit 的话是 true。Settings 关掉同步时退化为本地 NSPersistentContainer,
    /// 不会触发任何 CloudKit 网络/账户调用。
    let cloudKitEnabled: Bool
    /// CloudKit import 后的去重观察者。仅 cloudKitEnabled=true 时持有,负责
    /// 自动合并云上拉下来的同 UUID 重复 record。详见 CloudKitDeduplicator。
    private var deduplicator: CloudKitDeduplicator?

    init(inMemory: Bool = false) {
        let model = Self.makeModel()
        // iCloud 同步开关来自 UserDefaults。**进程启动时一次性读取**,运行中改设置
        // 不会立即生效 —— Core Data store coordinator 没有「热切换 CloudKit」API,
        // 必须重启 App。Settings UI 在用户改这个开关后弹提示请用户重启。
        let wantsSync = !inMemory && UserDefaults.standard.bool(forKey: SettingsKey.iCloudSyncEnabled)
        cloudKitEnabled = wantsSync

        if wantsSync {
            container = NSPersistentCloudKitContainer(name: "Noticky", managedObjectModel: model)
        } else {
            container = NSPersistentContainer(name: "Noticky", managedObjectModel: model)
        }

        if inMemory, let desc = container.persistentStoreDescriptions.first {
            desc.url = URL(fileURLWithPath: "/dev/null")
        }
        if let desc = container.persistentStoreDescriptions.first {
            // CloudKit 强制依赖这两项:Persistent History Tracking + Remote Change
            // Notifications。本地模式开着也无害,Manager / Floating 之间多 context
            // 合并刚好用得上。
            desc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            desc.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

            desc.shouldMigrateStoreAutomatically = true
            desc.shouldInferMappingModelAutomatically = true

            if wantsSync {
                let cloudOptions = NSPersistentCloudKitContainerOptions(
                    containerIdentifier: CloudKitConfig.containerIdentifier
                )
                desc.cloudKitContainerOptions = cloudOptions
            }

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

        // CloudKit 模式下偶尔会推下来重复 record(本地刚 create 完又收到 server 副本),
        // 把 transactionAuthor 设上有助于 history token 跟踪 + 后续做去重。
        if wantsSync, let ckContainer = container as? NSPersistentCloudKitContainer {
            container.viewContext.transactionAuthor = "viewContext"
            // 每次 import 成功后扫一遍按 UUID 合并重复。Apple 官方推荐的兜底,
            // 因为 CloudKit 没有 unique constraint,sync race / 本地 store 重建
            // 会让同 UUID 在云上有多份。
            deduplicator = CloudKitDeduplicator(container: ckContainer)
        }
    }

    /// 一次性迁移:沙盒容器里的 sqlite 三件套 → 新的 Application Support 路径。
    /// 仅当目标不存在 + 老库存在 时执行。失败/缺权限时静默跳过,Core Data
    /// 后面会照常从空目标建一个新库;数据没了,但启动不挂。
    private static func migrateFromSandboxContainerIfNeeded(target: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { return }

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
    /// CloudKit 模式下也走这个兜底:CloudKit 自身的 record schema 有版本管理,
    /// 删本地库不会丢云端数据,会重新拉。
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

        // ⚠️ CloudKit 兼容性约束:NSPersistentCloudKitContainer 要求每个属性
        // 「optional 或 有 default」。下面 id/createdAt/updatedAt 在 schema 层
        // 标 isOptional=true,实际代码路径(Note.create)总会立即赋值,所以 Swift
        // 侧 @NSManaged 仍可保持非可选。
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

        // 折叠态:浮窗双击标题缩成只剩标题条;持久化让用户重启后回到上次的状态。
        // 折叠时窗口高度强制 collapsedHeight,保留 frameW/H 当作"展开状态的几何"
        // 用于还原。
        let isCollapsed = NSAttributeDescription()
        isCollapsed.name = "isCollapsed"
        isCollapsed.attributeType = .booleanAttributeType
        isCollapsed.isOptional = false
        isCollapsed.defaultValue = false

        // NoteGroup entity --------------------------------------------------------
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

        // Relationships ----------------------------------------------------------
        // Note <-> NoteGroup,多对一。任何一方删除都 nullify(保留对方),不级联。
        // CloudKit 要求 to-many 关系必须 optional + nullify,这里两端都满足。
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
            isTrashed, trashedAt, isCollapsed,
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

#if DEBUG
extension PersistenceController {
    /// 调试用:把当前 model 推到 CloudKit 开发环境(只在你拿到真实 container ID
    /// 之后才需要,否则会报 invalid container)。在 LLDB 或临时菜单项里调:
    ///
    ///   try? PersistenceController.shared.initializeCloudKitSchema()
    ///
    /// 这个调用是同步的、可能耗时(秒级);只跑一次,跑成功后再发布。
    func initializeCloudKitSchema() throws {
        guard let container = container as? NSPersistentCloudKitContainer else {
            NSLog("Noticky: initializeCloudKitSchema skipped — not a CloudKit container")
            return
        }
        try container.initializeCloudKitSchema(options: [])
    }
}
#endif
