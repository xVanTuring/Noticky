import AppKit
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
    /// 系统 Spotlight 索引导出器。**必须 retain**,否则 Core Data 停止往
    /// Spotlight 推增量。inMemory(测试)场景不建。详见 NoteSpotlightDelegate。
    private var spotlightDelegate: NoteSpotlightDelegate?

    init(inMemory: Bool = false) {
        let model = CoreDataSchema.currentModel()
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

            // Lightweight migration: 加字段、删字段、字段重命名(配 renaming
            // identifier)、加 entity、加 relationship —— 99% 的 schema 改动
            // Core Data 自己能推出 mapping。复杂改动(拆 entity、字段值转换)
            // 才需要写 NSEntityMigrationPolicy + NSMappingModel,届时把这两个
            // 改成 false 并手动 migrate。
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

        Self.loadStores(in: container, allowFailureUI: !inMemory)
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

        // Spotlight 索引。store load 之后构造(需要 coordinator),retain delegate
        // 并 startSpotlightIndexing() 注册 exporter —— 之后 Core Data 用 persistent
        // history 自动增量索引活跃笔记。本地 / CloudKit 模式都开;inMemory 跳过。
        if !inMemory, let description = container.persistentStoreDescriptions.first {
            let delegate = NoteSpotlightDelegate(
                forStoreWith: description,
                coordinator: container.persistentStoreCoordinator
            )
            delegate.startSpotlightIndexing()
            spotlightDelegate = delegate
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

    /// 加载 store。失败时:
    ///   1. 把 sqlite/shm/wal 备份到 ~/Desktop/Noticky-Recovery-{ts}/(best-effort)
    ///   2. 弹 NSAlert,告知用户 + 提供"打开备份目录"按钮
    ///   3. terminate App
    ///
    /// **不再静默删库重建。** 老逻辑会让用户在升级失败时悄悄丢全部便签;
    /// CloudKit 模式下尤其危险——本地 only 改动(还没同步上去的)直接没了。
    /// 现在的策略是宁可启动失败,也要保住数据。
    private static func loadStores(in container: NSPersistentContainer, allowFailureUI: Bool) {
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        guard let error = loadError else { return }

        let storeURL = container.persistentStoreDescriptions.first?.url
        NSLog("Noticky: store load failed: %@", "\(error)")

        guard allowFailureUI else {
            // inMemory / 测试场景,直接抛
            fatalError("Noticky: failed to load persistent store: \(error)")
        }

        let backup = storeURL.flatMap { backupStore(at: $0) }
        let storeVersion = storeURL.flatMap { CoreDataSchema.storeVersionIdentifiers(at: $0) }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Noticky 启动失败"
        alert.informativeText = composeFailureMessage(
            error: error,
            storeURL: storeURL,
            storeVersionIdentifiers: storeVersion,
            backupURL: backup
        )
        if backup != nil {
            alert.addButton(withTitle: "在 Finder 中显示备份")
        }
        alert.addButton(withTitle: "退出")

        // LSUIElement App 没 Dock 图标,弹 modal 前 activate 一下保证抢到焦点。
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if backup != nil, response == .alertFirstButtonReturn, let backup {
            NSWorkspace.shared.activateFileViewerSelecting([backup])
        }
        NSApp.terminate(nil)
        // terminate 是异步的,run loop 还会再转一会儿。block 在这里不让后续
        // 代码继续执行(否则会用一个没 load 的 container 去做事,各种崩)。
        RunLoop.current.run()
        fatalError("unreachable")
    }

    /// 把 sqlite 三件套(.sqlite/.sqlite-shm/.sqlite-wal)拷贝到 ~/Desktop。
    /// 失败时返回 nil —— 备份是 best-effort,主流程继续走 alert + quit。
    /// 返回备份目录的 URL(让 alert 可以弹 Finder 定位)。
    private static func backupStore(at storeURL: URL) -> URL? {
        let fm = FileManager.default
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let desktop = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let backupDir = desktop.appendingPathComponent("Noticky-Recovery-\(timestamp)")

        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            for suffix in ["", "-shm", "-wal"] {
                let from = storeURL.deletingLastPathComponent()
                    .appendingPathComponent(storeURL.lastPathComponent + suffix)
                guard fm.fileExists(atPath: from.path) else { continue }
                let to = backupDir.appendingPathComponent(from.lastPathComponent)
                try fm.copyItem(at: from, to: to)
            }
            NSLog("Noticky: backed up sqlite to %@", backupDir.path)
            return backupDir
        } catch {
            NSLog("Noticky: store backup failed: %@", "\(error)")
            return nil
        }
    }

    private static func composeFailureMessage(
        error: Error,
        storeURL: URL?,
        storeVersionIdentifiers: Set<String>?,
        backupURL: URL?
    ) -> String {
        var lines: [String] = []
        lines.append("无法加载本地数据。")
        lines.append("")
        lines.append("错误:\(error.localizedDescription)")
        if let identifiers = storeVersionIdentifiers, !identifiers.isEmpty {
            lines.append("本地库版本:\(identifiers.sorted().joined(separator: ", "))")
        }
        lines.append("当前 App schema:\(SchemaVersion.current.rawValue)")
        if let backupURL {
            lines.append("")
            lines.append("已自动备份原始数据到桌面:")
            lines.append(backupURL.lastPathComponent)
        } else {
            lines.append("")
            lines.append("⚠️ 数据备份失败,请在退出前手动复制:")
            if let storeURL { lines.append(storeURL.deletingLastPathComponent().path) }
        }
        lines.append("")
        lines.append("请把备份发给开发者排查后再继续使用。")
        return lines.joined(separator: "\n")
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
