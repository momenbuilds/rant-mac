import RantCore
import SwiftUI

/// Local Markdown notes. No account, no sync, no folder someone else owns.
struct ScratchpadView: View {
  @EnvironmentObject private var model: AppModel
  @State private var notes: [Note] = []
  @State private var selection: Int64?
  @State private var query = ""
  @State private var draftBody = ""
  @State private var draftTitle = ""

  private var shown: [Note] {
    guard !query.trimmingCharacters(in: .whitespaces).isEmpty, let store = model.notes else {
      return notes
    }
    return ((try? store.search(query, limit: 100)) ?? []).map(\.note)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      header
      Divider().overlay(Theme.hairline)
      HStack(spacing: 0) {
        list
          .frame(width: 280)
          .frame(maxHeight: .infinity)
        Divider().overlay(Theme.hairline)
        editor
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Theme.paper)
    .onAppear(perform: reload)
    .onChange(of: selection) { _, _ in loadSelection() }
  }

  private var header: some View {
    PageTitle(
      title: "Scratchpad",
      subtitle: "Local Markdown notes, on this Mac only.",
      accessory: AnyView(
        HStack(spacing: Theme.Spacing.tight) {
          Menu {
            if let note = current {
              Button(note.pinned ? "Unpin" : "Pin") { togglePin(note) }
              Button("Export as Markdown…") {
                model.exportText(note.markdown, suggestedName: "\(note.title).md")
              }
              Divider()
              Button("Delete", role: .destructive) { delete(note) }
            }
          } label: {
            Image(systemName: "ellipsis")
              .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.inkMuted)
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .accessibilityLabel("Note actions")
          .disabled(current == nil)

          Button("New note") { newNote() }.buttonStyle(.clay)
        }))
      .padding(.horizontal, Theme.Spacing.page)
      .padding(.top, Theme.Spacing.page)
  }

  private var current: Note? { notes.first { $0.id == selection } }

  // MARK: - List

  @ViewBuilder private var list: some View {
    VStack(spacing: 0) {
      SearchField(query: $query, prompt: "Search your notes")
        .padding(Theme.Spacing.small)

      if shown.isEmpty {
        VStack {
          EmptyState(
            icon: "note.text",
            title: notes.isEmpty ? "No notes" : "Nothing matches",
            message: notes.isEmpty
              ? "Dictate a thought and it lands here." : "Try a different word.")
          Spacer()
        }
      } else {
        ScrollView {
          VStack(spacing: 0) {
            ForEach(shown) { note in
              row(note)
            }
          }
        }
      }
    }
  }

  private func row(_ note: Note) -> some View {
    let selected = selection == note.id
    return Button {
      selection = note.id
    } label: {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 5) {
          if note.pinned {
            Image(systemName: "pin.fill")
              .font(.system(size: 9)).foregroundStyle(Theme.clay)
              .accessibilityLabel("Pinned")
          }
          Text(note.title.isEmpty ? "Untitled" : note.title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
        }
        Text(note.body.isEmpty ? "Empty" : note.body.prefix(70).replacingOccurrences(of: "\n", with: " "))
          .font(.system(size: 11.5)).foregroundStyle(Theme.inkMuted).lineLimit(1)
        Text(note.updatedAt, format: .relative(presentation: .named))
          .font(.system(size: 10.5)).foregroundStyle(Theme.inkFaint)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, Theme.Spacing.small)
      .padding(.vertical, 9)
      .background(selected ? Theme.surface : .clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }

  // MARK: - Editor

  @ViewBuilder private var editor: some View {
    if current != nil {
      VStack(alignment: .leading, spacing: 0) {
        TextField("Title", text: $draftTitle)
          .textFieldStyle(.plain)
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(Theme.ink)
          .padding(.horizontal, Theme.Spacing.large)
          .padding(.top, Theme.Spacing.large)
          .padding(.bottom, Theme.Spacing.small)
          .onSubmit(saveCurrent)
          .onChange(of: draftTitle) { _, _ in saveCurrent() }

        Divider().overlay(Theme.hairline)

        TextEditor(text: $draftBody)
          .font(.system(size: 13.5))
          .foregroundStyle(Theme.ink)
          .scrollContentBackground(.hidden)
          .padding(.horizontal, Theme.Spacing.large - 5)
          .padding(.vertical, Theme.Spacing.small)
          .onChange(of: draftBody) { _, _ in saveCurrent() }
      }
      .background(Theme.paper)
    } else {
      VStack {
        Spacer()
        EmptyState(
          icon: "note.text",
          title: "Select a note",
          message: "Or press New note to start one.")
        Spacer()
      }
    }
  }

  // MARK: - Actions

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
    draftTitle = note.title
    draftBody = note.body
  }

  private func saveCurrent() {
    guard let store = model.notes, let id = selection else { return }
    try? store.update(id: id, title: draftTitle, body: draftBody)
    notes = (try? store.recent(limit: 200, offset: 0)) ?? notes
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
