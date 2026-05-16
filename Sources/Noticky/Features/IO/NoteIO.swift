import Foundation
import AppKit
import CoreData

/// 便签导入 / 导出 / 整库备份的逻辑核心。每个 entry point 都是「拿一个
/// `NSManagedObjectContext` + 一个 user-presented panel」的形式,UI 层(File menu /
/// Manager context menu)只负责弹 panel 和把结果传过来。
///
/// **格式选择:**
/// - 单条导出:`.md` 文件,内容直接写 note.content。Markdown 跟我们 Textual 渲染
///   一致,任意编辑器都能开。
/// - 多条导出:一个文件夹,里面每条便签一个 `.md`,文件名用 displayTitle(经过
///   Markdown 标记剥离 + 文件名安全字符 sanitize)。
/// - 整库 backup:单个 `.noticky-backup.json` 文件。包含全部 notes + groups
///   元数据。**不**走 zip(Apple 没好的公开 zip API + 当前没附件,zip 暂无意义)。
///   等加图片附件后再换 zip 容器。
///
/// **Restore 去重:** 按 UUID。已有相同 id 的 note/group 跳过(import 不覆盖)。
/// CloudKit 模式下,即使没跳过,CloudKitDeduplicator 也会兜底合并。
enum NoteIO {

    // MARK: - 单条 / 多条 export ----------------------------------------------

    /// 单条便签导出成 .md 文件。返回写入的 URL,失败 nil。
    @discardableResult
    static func exportNote(_ note: Note, to url: URL) -> URL? {
        do {
            try note.content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            NSLog("Noticky: exportNote failed: %@", "\(error)")
            return nil
        }
    }

    /// 多条便签导出到一个文件夹。返回成功写入的 URL 列表。
    /// 文件名冲突时附加 `-1` `-2` …。
    @discardableResult
    static func exportNotes(_ notes: [Note], toFolder folder: URL) -> [URL] {
        var written: [URL] = []
        for note in notes {
            let baseName = sanitizedFilename(note.displayTitle)
            var url = folder.appendingPathComponent(baseName).appendingPathExtension("md")
            var n = 1
            while FileManager.default.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent("\(baseName)-\(n)").appendingPathExtension("md")
                n += 1
            }
            if let written_ = exportNote(note, to: url) { written.append(written_) }
        }
        return written
    }

    // MARK: - Import 单 / 多文件 ----------------------------------------------

    /// 把多个 .md / .txt 文件作为新便签导入,每文件一条。返回成功导入的条数。
    /// **不**触碰 group —— 导入的笔记进 Ungrouped,用户后续手动分组。
    @discardableResult
    static func importFiles(_ urls: [URL], into context: NSManagedObjectContext) -> Int {
        var count = 0
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            _ = Note.create(in: context, content: text)
            count += 1
        }
        if count > 0 { try? context.save() }
        return count
    }

    // MARK: - 整库 backup / restore ------------------------------------------

    /// Backup 文件的顶层结构。version 用于将来格式演进。
    private struct Backup: Codable {
        let version: Int
        let exportedAt: Date
        let groups: [GroupRow]
        let notes: [NoteRow]
    }

    private struct GroupRow: Codable {
        let id: UUID
        let name: String
        let createdAt: Date
        let sortOrder: Int32
    }

    private struct NoteRow: Codable {
        let id: UUID
        let content: String
        let createdAt: Date
        let updatedAt: Date
        let isPinned: Bool
        let colorIndex: Int16
        let isTrashed: Bool
        let trashedAt: Date?
        // V3 起的归档状态。optional 让旧 backup(没有这两个 key)仍能解码 ——
        // 解出来 nil 即 false / 未归档。
        let isArchived: Bool?
        let archivedAt: Date?
        let groupId: UUID?
        // 不持久化 frame / isCollapsed —— 这些是 UI 本地状态,不该跨设备 migrate。
    }

    /// 把整库写成 JSON 到 `url`。回收站里的笔记也包含进去(用户可能想留作存档),
    /// restore 时会保留 isTrashed=true 状态。
    @discardableResult
    static func backupAll(in context: NSManagedObjectContext, to url: URL) -> Bool {
        let groupReq = NoteGroup.sortedFetchRequest()
        let groups = (try? context.fetch(groupReq)) ?? []

        // 注意不能用 Note.sortedFetchRequest()(它默认过滤 trashed),要全部。
        let noteReq = NSFetchRequest<Note>(entityName: "Note")
        noteReq.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
        let notes = (try? context.fetch(noteReq)) ?? []

        let backup = Backup(
            version: 1,
            exportedAt: Date(),
            groups: groups.map { g in
                GroupRow(id: g.id, name: g.name, createdAt: g.createdAt, sortOrder: g.sortOrder)
            },
            notes: notes.map { n in
                NoteRow(
                    id: n.id, content: n.content,
                    createdAt: n.createdAt, updatedAt: n.updatedAt,
                    isPinned: n.isPinned, colorIndex: n.colorIndex,
                    isTrashed: n.isTrashed, trashedAt: n.trashedAt,
                    isArchived: n.isArchived, archivedAt: n.archivedAt,
                    groupId: n.group?.id
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(backup)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("Noticky: backup failed: %@", "\(error)")
            return false
        }
    }

    /// 从 backup JSON 恢复。**已存在相同 UUID 的不导入**,避免覆盖用户当前数据。
    /// 返回 (importedNotes, importedGroups)。
    @discardableResult
    static func restoreFrom(_ url: URL, into context: NSManagedObjectContext) -> (notes: Int, groups: Int) {
        guard let data = try? Data(contentsOf: url) else { return (0, 0) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(Backup.self, from: data) else {
            NSLog("Noticky: restore parse failed for %@", url.path)
            return (0, 0)
        }

        // 先建 group。建好的存 [UUID: NoteGroup] 用来给 note.group 接回去。
        var groupMap: [UUID: NoteGroup] = [:]
        var importedGroups = 0
        for row in backup.groups {
            if let existing = fetchGroup(id: row.id, in: context) {
                groupMap[row.id] = existing
                continue
            }
            let g = NoteGroup(context: context)
            g.id = row.id
            g.name = row.name
            g.createdAt = row.createdAt
            g.sortOrder = row.sortOrder
            groupMap[row.id] = g
            importedGroups += 1
        }

        var importedNotes = 0
        for row in backup.notes {
            if fetchNote(id: row.id, in: context) != nil { continue }
            let n = Note(context: context)
            n.id = row.id
            n.content = row.content
            n.createdAt = row.createdAt
            n.updatedAt = row.updatedAt
            n.isPinned = row.isPinned
            n.colorIndex = row.colorIndex
            n.isTrashed = row.isTrashed
            n.trashedAt = row.trashedAt
            n.isArchived = row.isArchived ?? false
            n.archivedAt = row.archivedAt
            n.hasSavedFrame = false
            n.isCollapsed = false
            if let gid = row.groupId, let g = groupMap[gid] {
                n.group = g
            } else if let gid = row.groupId {
                // 备份里 note.groupId 指了一个 group 但 backup.groups 里没列出
                // (理论上不该出现,容错跳过分组)。
                _ = gid
            }
            importedNotes += 1
        }

        if importedNotes > 0 || importedGroups > 0 {
            try? context.save()
        }
        return (importedNotes, importedGroups)
    }

    // MARK: - Helpers ---------------------------------------------------------

    private static func fetchNote(id: UUID, in context: NSManagedObjectContext) -> Note? {
        let req = NSFetchRequest<Note>(entityName: "Note")
        req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        req.fetchLimit = 1
        return (try? context.fetch(req))?.first
    }

    private static func fetchGroup(id: UUID, in context: NSManagedObjectContext) -> NoteGroup? {
        let req = NSFetchRequest<NoteGroup>(entityName: "NoteGroup")
        req.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        req.fetchLimit = 1
        return (try? context.fetch(req))?.first
    }

    /// 把 displayTitle 化简成文件系统安全的 basename。剥掉 / : 等控制字符,空字符串
    /// 兜底成 "Untitled"。max 80 字符,免得 Finder 那头看着累。
    private static func sanitizedFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = raw.components(separatedBy: invalid).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let s = cleaned.isEmpty ? "Untitled" : cleaned
        return String(s.prefix(80))
    }
}

// MARK: - 用户面板 (NSOpenPanel / NSSavePanel) -----------------------------------

/// 包装常用的文件 panel 调用,UI 调用方一行解决。所有 panel 都同步阻塞,跑在
/// 主线程没问题(用户在等结果)。
enum NoteIOPanels {

    /// 选若干 .md / .txt 文件来 import。返回 URLs;用户取消返回空数组。
    static func chooseFilesToImport() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// 单条 export 的 save panel。建议名 = note.displayTitle.md。
    static func chooseExportSingleNote(suggestedTitle: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.text]
        panel.nameFieldStringValue = suggestedTitle + ".md"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 多条 export 的目录选择器。返回选中的目录 URL。
    static func chooseExportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Backup save panel。建议名 `Noticky-backup-YYYYMMDD.json`。
    static func chooseBackupDestination() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        panel.nameFieldStringValue = "Noticky-backup-\(formatter.string(from: Date())).json"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Restore open panel。
    static func chooseBackupToRestore() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
