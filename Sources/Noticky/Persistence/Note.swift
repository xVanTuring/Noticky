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
    static func sortedFetchRequest() -> NSFetchRequest<Note> {
        let request = NSFetchRequest<Note>(entityName: "Note")
        request.sortDescriptors = [
            NSSortDescriptor(key: "isPinned", ascending: false),
            NSSortDescriptor(key: "updatedAt", ascending: false)
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

    var displayTitle: String {
        let firstLine = content
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return firstLine ?? "New note"
    }
}
