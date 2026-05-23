import SwiftUI
import CoreData

struct NoteEditorView: View {
    @ObservedObject var note: Note
    @Environment(\.managedObjectContext) private var context

    var body: some View {
        PlainTextEditor(text: Binding(
            get: { note.content },
            set: { newValue in
                guard newValue != note.content else { return }
                note.content = newValue
                note.updatedAt = Date()
                try? context.save()
            }
        ))
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }
}
