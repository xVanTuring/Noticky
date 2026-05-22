import CoreData
import CoreSpotlight
import UniformTypeIdentifiers

/// 把活跃笔记同步进系统 Spotlight 索引(`CSSearchableIndex`),手动掌控。
///
/// **为什么不用 `NSCoreDataCoreSpotlightDelegate`**:本项目是 programmatic Core
/// Data model(没有 .xcdatamodeld),它那套"在模型编辑器里勾选 entity 为可索引"
/// 的标记机制在纯代码模型下不可靠 —— 实测存量笔记不会被回填进索引(只有新
/// 改动才偶尔触发,而且依赖 persistent history 是否还留着对应事务)。改成自己
/// 来:启动时全量索引所有活跃笔记,之后监听存盘 / CloudKit 远端变更做增量
/// reconcile。完全确定、可验证(`indexSearchableItems` 的 completion 直接报成败)。
///
/// 索引范围与 `Note.sortedFetchRequest` 一致:只活跃笔记(未归档、未回收站、
/// 内容非空)。`uniqueIdentifier` 用 `Note.id`(UUID)字符串 —— 跨 store 重建
/// 稳定,且续传时 `AppDelegate` 直接按 UUID fetch(复用提醒点击那条路径)。
final class SpotlightIndexer {
    static let domainIdentifier = "tech.xvanturing.Noticky.notes"

    private let container: NSPersistentContainer
    private let index = CSSearchableIndex.default()
    /// 上一轮 reconcile 后留在索引里的 UUID 集。下一轮用它减去"当前应在索引里
    /// 的",得出需要删除的(被删/进回收站/归档/清空的)条目。
    private var indexedIDs: Set<String> = []
    private var debounce: DispatchWorkItem?

    init(container: NSPersistentContainer) {
        self.container = container

        // 启动先清掉本 domain 的残留(上次进程留下、这次启动前已删除的条目),
        // 再做一次全量 —— 保证每次启动后索引与库严格一致,不积累幽灵条目。
        index.deleteSearchableItems(withDomainIdentifiers: [Self.domainIdentifier]) { [weak self] _ in
            DispatchQueue.main.async { self?.reconcile() }
        }

        let nc = NotificationCenter.default
        // 本地编辑/新建/进回收站/归档都走 viewContext 存盘 → didSave。
        nc.addObserver(self, selector: #selector(dataChanged),
                       name: .NSManagedObjectContextDidSave, object: nil)
        // CloudKit 拉下来的远端改动:合并进 viewContext 后这里也补一刀 reconcile。
        nc.addObserver(self, selector: #selector(dataChanged),
                       name: .NSPersistentStoreRemoteChange,
                       object: container.persistentStoreCoordinator)
    }

    @objc private func dataChanged() { scheduleReconcile(delay: 1.5) }

    /// 防抖:连续打字会触发一连串 didSave,合并成一次 reconcile。
    private func scheduleReconcile(delay: TimeInterval) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcile() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 全量对账:索引所有活跃笔记(upsert),删掉已不该在索引里的。
    /// 笔记量级很小(几十~几百),每次全量重建足够便宜,换来逻辑零状态漂移。
    private func reconcile() {
        let ctx = container.viewContext
        ctx.perform {
            let request = NSFetchRequest<Note>(entityName: "Note")
            request.predicate = NSPredicate(
                format: "isTrashed == %@ AND isArchived == %@",
                NSNumber(value: false), NSNumber(value: false)
            )
            let notes = (try? ctx.fetch(request)) ?? []

            var items: [CSSearchableItem] = []
            var desired: Set<String> = []
            for note in notes {
                // 空白笔记不进索引 —— displayTitle 会退化成 "New note",纯噪音。
                guard !note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                let id = note.id.uuidString
                desired.insert(id)

                let attr = CSSearchableItemAttributeSet(contentType: .text)
                attr.title = note.displayTitle
                attr.contentDescription = note.content
                attr.contentCreationDate = note.createdAt
                attr.contentModificationDate = note.updatedAt
                items.append(CSSearchableItem(
                    uniqueIdentifier: id,
                    domainIdentifier: Self.domainIdentifier,
                    attributeSet: attr
                ))
            }

            let stale = Array(self.indexedIDs.subtracting(desired))
            if !items.isEmpty {
                self.index.indexSearchableItems(items) { err in
                    #if DEBUG
                    NSLog("Noticky Spotlight: indexed %d notes, err=%@",
                          items.count, String(describing: err))
                    #endif
                }
            }
            if !stale.isEmpty {
                self.index.deleteSearchableItems(withIdentifiers: stale)
            }
            self.indexedIDs = desired
        }
    }
}
