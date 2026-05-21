import CoreData
import CoreSpotlight
import UniformTypeIdentifiers

/// 把 Note 喂给系统 Spotlight 索引。继承 `NSCoreDataCoreSpotlightDelegate`:
/// Core Data 用 persistent history(本项目已开,CloudKit 强制依赖)自动驱动
/// 增量索引 —— 本地 create/update/delete、以及 CloudKit 拉下来的远端改动都会
/// 自动反映到 Spotlight,**无需手写任何同步代码**。
///
/// 只索引**活跃笔记**(未归档、未回收站、且内容非空)。归档/回收站/空白
/// 笔记 `attributeSet(for:)` 返回 nil → 不索引;若一条已索引的笔记之后被归档、
/// 进回收站或清空内容,下一次 history pass 重新求值得到 nil,父类会自动把它
/// 从索引里删掉。
///
/// 为什么不索引归档笔记:打开一条笔记走 `FloatingNotesRegistry.show` → `spawn`,
/// 后者无条件置 `isPinned = true`(= 开机自动恢复)。给归档笔记开浮窗会造出
/// `pinned + archived` 的脏态。索引范围与 `Note.sortedFetchRequest` 保持一致,
/// 保证 Spotlight 里能点开的都是能正常 show 的活跃笔记。
///
/// `CSSearchableItem.uniqueIdentifier` 由父类设为 objectID 的 URI;续传(点击
/// Spotlight 结果)时 `AppDelegate` 用 `managedObjectID(forURIRepresentation:)`
/// 还原成 Note。
final class NoteSpotlightDelegate: NSCoreDataCoreSpotlightDelegate {
    override func domainIdentifier() -> String {
        "tech.xvanturing.Noticky.notes"
    }

    override func indexName() -> String? {
        "noticky-notes-index"
    }

    override func attributeSet(for object: NSManagedObject) -> CSSearchableItemAttributeSet? {
        guard let note = object as? Note else { return nil }
        // 范围与 sortedFetchRequest 一致:只活跃笔记。
        guard !note.isTrashed, !note.isArchived else { return nil }
        // 空白笔记不进索引 —— displayTitle 会退化成占位符 "New note",纯噪音。
        let body = note.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }

        let attr = CSSearchableItemAttributeSet(contentType: .text)
        attr.title = note.displayTitle
        attr.contentDescription = note.content
        attr.contentCreationDate = note.createdAt
        attr.contentModificationDate = note.updatedAt
        return attr
    }
}
