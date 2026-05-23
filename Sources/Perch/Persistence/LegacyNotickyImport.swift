import AppKit
import CoreData

/// 从旧版 **Noticky** 一次性把本地数据导入 **Perch**。
///
/// Perch 用了全新的 bundle id,对 macOS 是一个**全新 app**:沙盒容器 / CloudKit
/// 容器 / 自动更新都与 Noticky 解耦,数据不会自动延续。但 Noticky **非沙盒**,
/// 它的本地库就在用户主目录(`~/Library/Application Support/Noticky/Noticky.sqlite`),
/// Perch 有完整磁盘访问读得到。这里在首次启动时:
///   1. 检测旧库(先现役的非沙盒位置,再古早沙盒容器位置);
///   2. 走 `NoteIO.importSQLite`(按 UUID 去重 + lightweight 迁移)导入到 Perch 的库;
///   3. 弹框询问用户是否删除旧库(默认保留)。
/// 只跑一次,用 UserDefaults 标记(Perch 是新 domain,默认未跑过)。
enum LegacyNotickyImport {
    /// 只导一次的标记。Perch = 新 bundle id → 全新 UserDefaults domain,默认 false。
    private static let doneKey = "Perch.didImportLegacyNoticky"

    struct Outcome {
        let notes: Int
        let groups: Int
        /// 旧库 .sqlite 路径,供「删除旧数据」用。
        let store: URL
    }

    /// 旧 Noticky 本地库的候选路径:先现役的非沙盒位置,再古早的沙盒容器位置
    /// (老用户从未升级到非沙盒版本时数据还留在容器里)。
    private static var candidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Application Support/Noticky/Noticky.sqlite"),
            home.appendingPathComponent("Library/Containers/tech.xvanturing.Noticky/Data/Library/Application Support/Noticky/Noticky.sqlite"),
        ]
    }

    /// 首启导入。已导过 / 找不到旧库 / 导入为空 → 返回 nil(并打标记不再重试)。
    /// **必须在 `restorePinnedNotes` 之前调用**:导入的 pinned 笔记随后被 restore
    /// 一起恢复成浮窗,无需额外 spawn。
    static func importIfNeeded(into context: NSManagedObjectContext) -> Outcome? {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return nil }

        let fm = FileManager.default
        guard let store = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            defaults.set(true, forKey: doneKey)   // 没有旧库可导,标记完成,别再每次启动都查
            return nil
        }

        let result = NoteIO.importSQLite(store, into: context)
        defaults.set(true, forKey: doneKey)

        guard let result, result.notes > 0 || result.groups > 0 else { return nil }
        NSLog("Perch: imported %d note(s) + %d group(s) from legacy Noticky at %@",
              result.notes, result.groups, store.path)
        return Outcome(notes: result.notes, groups: result.groups, store: store)
    }

    /// 导入完成后弹框:**保留(默认/回车,安全)** 或 删除旧数据。删除只清旧 sqlite
    /// 三件套(.sqlite/-shm/-wal),不动旧目录里的其它东西。放在窗口都起来之后再
    /// modal,避免挡住启动。
    static func promptDeleteOldData(_ outcome: Outcome) {
        let alert = NSAlert()
        alert.messageText = L.t(.legacyImportDoneTitle)
        alert.informativeText = L.t(.legacyImportDoneBody, outcome.notes, outcome.groups)
        alert.addButton(withTitle: L.t(.legacyImportKeep))    // 默认 = 保留
        alert.addButton(withTitle: L.t(.legacyImportDelete))  // 次选 = 删除
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            deleteStoreFiles(outcome.store)
        }
    }

    private static func deleteStoreFiles(_ store: URL) {
        let fm = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            let f = store.deletingLastPathComponent()
                .appendingPathComponent(store.lastPathComponent + suffix)
            if fm.fileExists(atPath: f.path) { try? fm.removeItem(at: f) }
        }
        NSLog("Perch: deleted legacy Noticky store at %@", store.path)
    }
}
