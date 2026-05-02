import CoreData
import AppKit

@objc(Note)
public final class Note: NSManagedObject, Identifiable {
    @NSManaged public var id: UUID
    @NSManaged public var content: String
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date
    @NSManaged public var isPinned: Bool
    @NSManaged public var colorIndex: Int16
    @NSManaged public var frameX: Double
    @NSManaged public var frameY: Double
    @NSManaged public var frameW: Double
    @NSManaged public var frameH: Double
    @NSManaged public var hasSavedFrame: Bool
    @NSManaged public var isTrashed: Bool
    @NSManaged public var trashedAt: Date?
    @NSManaged public var isCollapsed: Bool
    @NSManaged public var group: NoteGroup?
}

extension Note {
    var savedFrame: NSRect? {
        guard hasSavedFrame else { return nil }
        return NSRect(x: frameX, y: frameY, width: frameW, height: frameH)
    }

    func setSavedFrame(_ frame: NSRect) {
        frameX = Double(frame.origin.x)
        frameY = Double(frame.origin.y)
        frameW = Double(frame.size.width)
        frameH = Double(frame.size.height)
        hasSavedFrame = true
    }
}

extension Note {
    /// 默认 fetch:**只取未进回收站的笔记**。所有列表/管理/菜单都用这个。
    /// 想看回收站走 `trashedFetchRequest`。
    static func sortedFetchRequest() -> NSFetchRequest<Note> {
        let request = NSFetchRequest<Note>(entityName: "Note")
        request.predicate = NSPredicate(format: "isTrashed == %@", NSNumber(value: false))
        request.sortDescriptors = [
            NSSortDescriptor(key: "isPinned", ascending: false),
            NSSortDescriptor(key: "updatedAt", ascending: false)
        ]
        return request
    }

    /// 回收站列表用。最近丢进去的排在最前。
    static func trashedFetchRequest() -> NSFetchRequest<Note> {
        let request = NSFetchRequest<Note>(entityName: "Note")
        request.predicate = NSPredicate(format: "isTrashed == %@", NSNumber(value: true))
        request.sortDescriptors = [
            NSSortDescriptor(key: "trashedAt", ascending: false)
        ]
        return request
    }

    @discardableResult
    static func create(in context: NSManagedObjectContext, content: String = "") -> Note {
        let note = Note(context: context)
        note.id = UUID()
        note.content = content
        let now = Date()
        note.createdAt = now
        note.updatedAt = now
        note.isPinned = false
        return note
    }

    /// 第一非空行作为标题,剥掉常见 markdown 标记 —— `#` 标题、`>` 引用、列表
     /// 前缀、加粗/斜体/删除线/行内代码、链接和图片语法都还原成纯文本。便于在
    /// 标题条/菜单/管理列表里展示干净的标题。
    var displayTitle: String {
        let firstLine = content
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let raw = firstLine else { return "New note" }
        let stripped = Self.stripMarkdownMarkers(raw).trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty ? "New note" : stripped
    }

    /// 剥 markdown 用的纯文本:首行没有内容时为空。比 `displayTitle` 更干净
    /// (不返回 "New note" 这种占位符)。浮窗顶部标题条没内容就完全不显示,
    /// 用这个版本判断是否要渲染。
    var cleanTitle: String {
        let firstLine = content
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let raw = firstLine else { return "" }
        return Self.stripMarkdownMarkers(raw).trimmingCharacters(in: .whitespaces)
    }

    private static func stripMarkdownMarkers(_ input: String) -> String {
        var s = input
        // 行首结构标记:#+ heading、>+ blockquote、`-`/`*`/`+` 列表、有序列表
        // 数字、taskmark `[ ]`/`[x]`。每一类只匹配开头,顺序无所谓,匹配不到就跳过。
        s = s.replacingOccurrences(of: "^#+\\s*",      with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "^>+\\s*",      with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "^[-*+]\\s+",   with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "^\\d+\\.\\s+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "^\\[[ xX]\\]\\s*", with: "", options: .regularExpression)
        // 图片 / 链接:`![alt](url)` 和 `[text](url)` 各保留括号里的可见文本。
        // 图片必须先于链接,因为 `![...](...)` 也匹配链接 pattern。
        s = s.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\([^\\)]*\\)", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^\\)]*\\)", with: "$1", options: .regularExpression)
        // 行内强调/代码:`**bold**`、`*italic*`、`__bold__`、`_italic_`、
        // `~~strike~~`、`` `code` ``。粗体先于斜体,免得 `**` 被吃成两次 `*`。
        s = s.replacingOccurrences(of: "\\*\\*([^\\*]+)\\*\\*", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "__([^_]+)__",           with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\*([^\\*]+)\\*",       with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "_([^_]+)_",             with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "~~([^~]+)~~",           with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "`([^`]+)`",             with: "$1", options: .regularExpression)
        return s
    }
}
