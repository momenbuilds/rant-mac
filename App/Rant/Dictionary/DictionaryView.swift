import RantCore
import SwiftUI

/// The personal dictionary: what you say, and what Rant should write.
struct DictionaryView: View {
  @EnvironmentObject private var model: AppModel
  @State private var entries: [DictionaryEntry] = []
  @State private var query = ""
  @State private var editing: DictionaryEntry?
  @State private var showingEditor = false
  @State private var errorMessage: String?

  private var shown: [DictionaryEntry] {
    guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return entries }
    let needle = query.lowercased()
    return entries.filter {
      $0.spoken.lowercased().contains(needle) || $0.written.lowercased().contains(needle)
    }
  }

  var body: some View {
    Group {
      if entries.isEmpty {
        ContentUnavailableView {
          Label("No entries yet", systemImage: "character.book.closed")
        } description: {
          Text("Teach Rant the words it keeps getting wrong — names, brands, jargon. “super base” becomes Supabase, and it applies from the very next dictation.")
        } actions: {
          Button("Add an entry") { newEntry() }
        }
      } else {
        List {
          ForEach(shown) { entry in
            row(entry)
          }
        }
        .listStyle(.inset)
      }
    }
    .searchable(text: $query, prompt: "Search your dictionary")
    .navigationTitle("Dictionary")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { newEntry() } label: { Label("Add", systemImage: "plus") }
      }
      ToolbarItem {
        Menu {
          Button("Export as JSON…") { export() }
          Button("Import from JSON…") { importEntries() }
        } label: { Label("More", systemImage: "ellipsis.circle") }
      }
    }
    .sheet(isPresented: $showingEditor) {
      DictionaryEntryEditor(entry: editing ?? DictionaryEntry(spoken: "", written: "")) { saved in
        save(saved)
      }
    }
    .alert("Could not save", isPresented: .constant(errorMessage != nil)) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
    .onAppear(perform: reload)
  }

  private func row(_ entry: DictionaryEntry) -> some View {
    HStack(spacing: Theme.Spacing.small) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(entry.spoken).foregroundStyle(.secondary)
          Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
          Text(entry.written).fontWeight(.medium)
        }
        HStack(spacing: 6) {
          Text(entry.kind.displayName)
          if entry.caseSensitive { Text("· case sensitive") }
          if !entry.enabled { Text("· off") }
        }
        .font(.caption2).foregroundStyle(.tertiary)
      }
      Spacer()
      Toggle("", isOn: Binding(
        get: { entry.enabled },
        set: { value in
          var updated = entry
          updated.enabled = value
          try? model.vocabulary?.update(updated)
          reload()
        }))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
      Menu {
        Button("Edit") { editing = entry; showingEditor = true }
        Button("Delete", role: .destructive) {
          if let id = entry.id { try? model.vocabulary?.deleteEntry(id: id); reload() }
        }
      } label: { Image(systemName: "ellipsis.circle") }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .frame(width: 28)
    }
    .padding(.vertical, 4)
  }

  private func newEntry() {
    editing = nil
    showingEditor = true
  }

  private func save(_ entry: DictionaryEntry) {
    do {
      if entry.id == nil {
        _ = try model.vocabulary?.add(entry)
      } else {
        try model.vocabulary?.update(entry)
      }
      model.rebuildVocabulary()
      reload()
    } catch {
      errorMessage = error.localizedDescription
    }
    showingEditor = false
  }

  private func reload() {
    entries = (try? model.vocabulary?.entries()) ?? []
  }

  private func export() {
    guard let entries = try? model.vocabulary?.entries() else { return }
    model.exportJSON(entries, suggestedName: "rant-dictionary.json")
  }

  private func importEntries() {
    model.importJSON([DictionaryEntry].self) { imported in
      for var entry in imported {
        entry.id = nil
        _ = try? model.vocabulary?.addOrIgnore(entry)
      }
      model.rebuildVocabulary()
      reload()
    }
  }
}

struct DictionaryEntryEditor: View {
  @State var entry: DictionaryEntry
  let onSave: (DictionaryEntry) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Form {
      Section {
        TextField("When I say", text: $entry.spoken)
        TextField("Write", text: $entry.written)
      } footer: {
        Text("Matched as whole words, so an entry for “sell” will never corrupt the middle of “reseller”.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section {
        Picker("Kind", selection: $entry.kind) {
          ForEach(DictionaryEntry.Kind.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        Toggle("Match capitals exactly", isOn: $entry.caseSensitive)
        Toggle("Enabled", isOn: $entry.enabled)
      } footer: {
        Text(entry.kind == .boost
          ? "A key term nudges the recogniser toward this spelling without rewriting anything."
          : "A replacement rewrites the text after transcription, so it always wins over the model.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .safeAreaInset(edge: .bottom) {
      HStack {
        Button("Cancel") { dismiss() }
        Spacer()
        Button("Save") { onSave(entry) }
          .buttonStyle(.borderedProminent)
          .disabled(entry.spoken.trimmingCharacters(in: .whitespaces).isEmpty
            || entry.written.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      .padding()
      .background(.bar)
    }
  }
}

/// Speech-triggered snippets.
struct SnippetsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var snippets: [Snippet] = []
  @State private var editing: Snippet?
  @State private var showingEditor = false
  @State private var errorMessage: String?

  var body: some View {
    Group {
      if snippets.isEmpty {
        ContentUnavailableView {
          Label("No snippets yet", systemImage: "text.badge.plus")
        } description: {
          Text("Say a short phrase, get a long one. “my meeting link” becomes your booking URL — and it works in the middle of a longer sentence.")
        } actions: {
          Button("Add a snippet") { editing = nil; showingEditor = true }
        }
      } else {
        List {
          ForEach(snippets) { snippet in
            VStack(alignment: .leading, spacing: 3) {
              Text(snippet.trigger).fontWeight(.medium)
              Text(snippet.expansion)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(.vertical, 3)
            .contextMenu {
              Button("Edit") { editing = snippet; showingEditor = true }
              Button("Delete", role: .destructive) {
                if let id = snippet.id { try? model.vocabulary?.deleteSnippet(id: id); reload() }
              }
            }
          }
        }
        .listStyle(.inset)
      }
    }
    .navigationTitle("Snippets")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { editing = nil; showingEditor = true } label: { Label("Add", systemImage: "plus") }
      }
    }
    .sheet(isPresented: $showingEditor) {
      SnippetEditor(snippet: editing ?? Snippet(trigger: "", expansion: "")) { saved in
        do {
          if saved.id == nil { _ = try model.vocabulary?.add(saved) }
          else { try model.vocabulary?.update(saved) }
          model.rebuildVocabulary()
          reload()
        } catch {
          errorMessage = error.localizedDescription
        }
        showingEditor = false
      }
    }
    .alert("Could not save", isPresented: .constant(errorMessage != nil)) {
      Button("OK") { errorMessage = nil }
    } message: { Text(errorMessage ?? "") }
    .onAppear(perform: reload)
  }

  private func reload() {
    snippets = (try? model.vocabulary?.snippets()) ?? []
  }
}

struct SnippetEditor: View {
  @State var snippet: Snippet
  let onSave: (Snippet) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Form {
      Section {
        TextField("When I say", text: $snippet.trigger)
      } footer: {
        Text("A short, distinctive phrase you would not say by accident.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Expand to") {
        TextEditor(text: $snippet.expansion)
          .font(.body.monospaced())
          .frame(minHeight: 120)
      }
      Toggle("Enabled", isOn: $snippet.enabled)
    }
    .formStyle(.grouped)
    .frame(width: 480)
    .safeAreaInset(edge: .bottom) {
      HStack {
        Button("Cancel") { dismiss() }
        Spacer()
        Button("Save") { onSave(snippet) }
          .buttonStyle(.borderedProminent)
          .disabled(snippet.trigger.trimmingCharacters(in: .whitespaces).isEmpty
            || snippet.expansion.isEmpty)
      }
      .padding()
      .background(.bar)
    }
  }
}
