import Foundation

struct QuickNote: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var done = false
    var date = Date()
}

/// Quick notes and to-dos, saved to Application Support/Centik/notes.json.
final class NotesService: ObservableObject {
    static let shared = NotesService()

    @Published private(set) var notes: [QuickNote] = []
    /// Text being typed; kept here so it survives the island closing.
    @Published var draft = ""

    private var file: URL { AgentService.shared.directory.appendingPathComponent("notes.json") }

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([QuickNote].self, from: data) {
            notes = saved
        }
    }

    var openCount: Int { notes.filter { !$0.done }.count }

    func addDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        notes.insert(QuickNote(text: text), at: 0)
        draft = ""
        save()
    }

    func toggle(_ note: QuickNote) {
        guard let i = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[i].done.toggle()
        // Finished items sink below open ones.
        notes.sort { ($0.done ? 1 : 0, $1.date) < ($1.done ? 1 : 0, $0.date) }
        save()
    }

    func remove(_ note: QuickNote) {
        notes.removeAll { $0.id == note.id }
        save()
    }

    func clearDone() {
        notes.removeAll(where: \.done)
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: AgentService.shared.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(notes) { try? data.write(to: file, options: .atomic) }
    }
}

#if DEBUG
extension NotesService {
    func loadPreview(_ preview: [QuickNote]) { notes = preview }
}
#endif
