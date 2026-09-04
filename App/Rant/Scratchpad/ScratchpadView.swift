import RantCore
import SwiftUI

/// Local Markdown notes. No account, no sync, no folder someone else owns.
struct ScratchpadView: View {
  @EnvironmentObject private var model: AppModel
  @State private var notes: [Note] = []
  @State private var selection: Int64?
  @State private var query = ""
  @State private var body_ = ""
  @State private var title = ""

  private var shown: [Note] {
    guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return notes }
    guard let store = model.notes else { return notes }
    return ((try? store.search(query, limit: 100)) ?? []).map(\.note)
  }

  var body: some View {
    HSplitView {
      VStack(spacing: 0) {
        if shown.isEmpty {
          ContentUnavailableView {
            Label("No notes", systemImage: "note.text")
          } description: {
            Text(query.isEmpty ? "Dictate a thought and it lands here." : "Nothing matches.")
          }
        } else {
          List(shown, selection: $selection) { note in
            VStack(alignment: .leading, spacing: 2) {
              HStack {
                if note.pinned {
                  Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Theme.accent)
                    .accessibilityLabel("Pinned")
                }
                Text(note.title.isEmpty ? "Untitled" : note.title).fontWeight(.medium)
              }
              Text(note.body.prefix(80))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
              Text(note.updatedAt, format: .relative(presentation: .named))
                .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .tag(note.id ?? -1)
          }
        }
      }
      .frame(minWidth: 240, idealWidth: 280)
      .searchable(text: $query, prompt: "Search your notes")

      editor
        .frame(minWidth: 400)
    }
    .navigationTitle("Scratchpad")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { newNote() } label: { Label("New note", systemImage: "square.and.pencil") }
      }
      ToolbarItem {
        Menu {
          if let note = current {
            Button(note.pinned ? "Unpin" : "Pin") { togglePin(note) }
            Button("Export as Markdown…") { model.exportText(note.markdown, suggestedName: "\(note.title).md") }
            Divider()
            Button("Delete", role: .destructive) { delete(note) }
          }
        } label: { Label("More", systemImage: "ellipsis.circle") }
        .disabled(current == nil)
      }
    }
    .onAppear(perform: reload)
    .onChange(of: selection) { _, _ in loadSelection() }
  }

  private var current: Note? {
    notes.first { $0.id == selection }
  }

  @ViewBuilder private var editor: some View {
    if current != nil {
      VStack(alignment: .leading, spacing: 0) {
        TextField("Title", text: $title)
          .textFieldStyle(.plain)
          .font(.title2.weight(.semibold))
          .padding(.horizontal, Theme.Spacing.large)
          .padding(.top, Theme.Spacing.large)
          .onSubmit(saveCurrent)
        Divider().padding(.vertical, Theme.Spacing.small)
        TextEditor(text: $body_)
          .font(.body)
          .scrollContentBackground(.hidden)
          .padding(.horizontal, Theme.Spacing.large)
          .onChange(of: body_) { _, _ in saveCurrent() }
      }
    } else {
      ContentUnavailableView("Select a note", systemImage: "note.text")
    }
  }

  private func newNote() {
    guard let store = model.notes else { return }
    if let created = try? store.create(title: "New note", body: "") {
      reload()
      selection = created.id
      loadSelection()
    }
  }

  private func loadSelection() {
    guard let note = current else { return }
    title = note.title
    body_ = note.body
  }

  private func saveCurrent() {
    guard let store = model.notes, let id = selection else { return }
    try? store.update(id: id, title: title, body: body_)
    reload()
  }

  private func togglePin(_ note: Note) {
    guard let store = model.notes, let id = note.id else { return }
    try? store.setPinned(id: id, !note.pinned)
    reload()
  }

  private func delete(_ note: Note) {
    guard let store = model.notes, let id = note.id else { return }
    try? store.delete(id: id)
    selection = nil
    reload()
  }

  private func reload() {
    notes = (try? model.notes?.recent(limit: 200, offset: 0)) ?? []
  }
}
