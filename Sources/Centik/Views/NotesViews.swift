import SwiftUI

struct NotesTab: View {
    @ObservedObject private var notes = NotesService.shared
    @ObservedObject private var model = IslandModel.shared
    @Environment(\.islandAccent) private var accent
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionLabel(title: String(localized: "Notlar"), symbol: "checklist")
                if notes.openCount > 0 { Chip(text: String(localized: "\(notes.openCount) açık"), tint: accent) }
                let done = notes.notes.count - notes.openCount
                if done > 0 { Chip(text: String(localized: "\(done) bitti"), symbol: "checkmark", tint: .green) }
                Spacer()
                if done > 0 {
                    Button { withAnimation(Motion.content) { notes.clearDone() } } label: { Label("Bitenleri sil", systemImage: "trash") }
                        .buttonStyle(.pill(.red))
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").font(.system(size: 15)).foregroundStyle(accent)
                TextField("Not ya da yapılacak yaz, Enter ile ekle", text: $notes.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($typing)
                    .onSubmit { withAnimation(Motion.content) { notes.addDraft() } }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(CardSurface(tint: typing ? accent : nil, radius: 10))
            .onTapGesture { typing = true }

            if notes.notes.isEmpty {
                EmptyState(symbol: "checklist", title: String(localized: "Henüz not yok"),
                           subtitle: String(localized: "Aklına geleni hızla yaz; işaretleyince yapıldı olur."), tint: accent)
            } else if notes.notes.count <= 3 {
                rows
            } else {
                ScrollView(showsIndicators: false) { rows }
            }
        }
        // While typing, leaving the island with the pointer doesn't close it.
        .onChange(of: typing) { _, on in model.keepOpen = on }
        .onDisappear { model.keepOpen = false }
    }

    private var rows: some View {
        LazyVStack(spacing: 4) {
            ForEach(notes.notes) { NoteRow(note: $0) }
        }
    }
}

struct NoteRow: View {
    var note: QuickNote
    @Environment(\.islandAccent) private var accent
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            Button { withAnimation(Motion.content) { NotesService.shared.toggle(note) } } label: {
                Image(systemName: note.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(note.done ? .green : .white.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressScaleStyle())
            Text(note.text)
                .font(.system(size: 11.5, weight: .medium))
                .strikethrough(note.done, color: .white.opacity(0.5))
                .foregroundStyle(note.done ? .white.opacity(0.45) : .white)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text(ClipAge.text(note.date)).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.subtleText)
            Button { withAnimation(Motion.content) { NotesService.shared.remove(note) } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                    .frame(width: 20, height: 20).background(Circle().fill(.white.opacity(0.1)))
            }
            .buttonStyle(PressScaleStyle())
            .opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 9)
        .frame(minHeight: 34)
        .background(CardSurface(radius: 10).opacity(hover ? 1 : 0.6))
        .onHover { hover = $0 }
        .contextMenu {
            Button("Kopyala") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(note.text, forType: .string)
            }
            Button(note.done ? "Yapılmadı olarak işaretle" : "Yapıldı olarak işaretle") { NotesService.shared.toggle(note) }
            Divider()
            Button("Sil") { NotesService.shared.remove(note) }
        }
    }
}
