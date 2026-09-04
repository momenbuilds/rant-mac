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
    VStack(alignment: .leading, spacing: Theme.Spacing.large) {
      PageTitle(
        title: "Dictionary",
        subtitle: "Teach Rant the words it keeps getting wrong.",
        accessory: AnyView(
          HStack(spacing: Theme.Spacing.tight) {
            Menu {
              Button("Export as JSON…") { export() }
              Button("Import from JSON…") { importEntries() }
            } label: {
              Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.inkMuted)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Dictionary actions")

            Button("Add entry") { newEntry() }
              .buttonStyle(.clay)
              .accessibilityIdentifier("dictionary.addToolbar")
          }))

      if let learning = model.learning, !learning.candidates.isEmpty {
        SuggestedRules(learning: learning) { reload() }
      }

      if !entries.isEmpty { SearchField(query: $query, prompt: "Search your dictionary") }

      if shown.isEmpty {
        Card {
          EmptyState(
            icon: "character.book.closed",
            title: entries.isEmpty ? "No entries yet" : "Nothing matches “\(query)”",
            message: entries.isEmpty
              ? "Names, brands, jargon — anything Rant mishears. “super base” becomes Supabase, and it applies from the very next dictation."
              : "Try a different word.",
            actionTitle: entries.isEmpty ? "Add an entry" : nil,
            action: entries.isEmpty ? { newEntry() } : nil,
            actionIdentifier: "dictionary.add")
        }
      } else {
        Card(padding: 0) {
          VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
              row(entry)
              if index < shown.count - 1 {
                Divider().overlay(Theme.hairline).padding(.leading, Theme.Spacing.medium)
              }
            }
          }
        }
      }
    }
    .page()
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
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Text(entry.spoken).font(.system(size: 13)).foregroundStyle(Theme.inkMuted)
          Image(systemName: "arrow.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.inkFaint)
            .accessibilityHidden(true)
          Text(entry.written).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
        }
        HStack(spacing: 6) {
          Text(entry.kind.displayName)
          if entry.caseSensitive { Text("· case sensitive") }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.inkFaint)
      }
      Spacer(minLength: Theme.Spacing.small)

      Toggle(
        "", isOn: Binding(
          get: { entry.enabled },
          set: { value in
            var updated = entry
            updated.enabled = value
            try? model.vocabulary?.update(updated)
            model.rebuildVocabulary()
            reload()
          })
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.mini)
      .accessibilityLabel("Enabled")

      Menu {
        Button("Edit") { editing = entry; showingEditor = true }
        Button("Delete", role: .destructive) {
          if let id = entry.id {
            try? model.vocabulary?.deleteEntry(id: id)
            model.rebuildVocabulary()
            reload()
          }
        }
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Theme.inkFaint)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .frame(width: 22)
      .accessibilityLabel("Actions for this entry")
    }
    .padding(.horizontal, Theme.Spacing.medium)
    .padding(.vertical, Theme.Spacing.small)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(entry.spoken) becomes \(entry.written)")
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

/// The search field, styled once and reused, because `.searchable` needs a navigation
/// container this app deliberately does not have.
struct SearchField: View {
  @Binding var query: String
  let prompt: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12)).foregroundStyle(Theme.inkFaint)
        .accessibilityHidden(true)
      TextField(prompt, text: $query)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(Theme.ink)
      if !query.isEmpty {
        Button { query = "" } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 12)).foregroundStyle(Theme.inkFaint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.control)
        .strokeBorder(Theme.hairline, lineWidth: 1))
  }
}

struct DictionaryEntryEditor: View {
  @State var entry: DictionaryEntry
  let onSave: (DictionaryEntry) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      Text(entry.id == nil ? "New entry" : "Edit entry")
        .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)

      VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
        field("When I say", text: $entry.spoken, identifier: "dictionary.spoken")
        field("Write", text: $entry.written, identifier: "dictionary.written")
        Text("Matched as whole words, so an entry for “sell” will never corrupt the middle of “reseller”.")
          .font(.system(size: 11.5)).foregroundStyle(Theme.inkMuted)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
        Picker("Kind", selection: $entry.kind) {
          ForEach(DictionaryEntry.Kind.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Text(entry.kind == .boost
          ? "A key term nudges the recogniser toward this spelling without rewriting anything."
          : "A replacement rewrites the text after transcription, so it always wins over the model.")
          .font(.system(size: 11.5)).foregroundStyle(Theme.inkMuted)
          .fixedSize(horizontal: false, vertical: true)
        Toggle("Match capitals exactly", isOn: $entry.caseSensitive).font(.system(size: 13))
        Toggle("Enabled", isOn: $entry.enabled).font(.system(size: 13))
      }

      HStack {
        Button("Cancel") { dismiss() }.buttonStyle(.quiet)
        Spacer()
        Button("Save") { onSave(entry) }
          .buttonStyle(.clay)
          .accessibilityIdentifier("dictionary.save")
          .disabled(entry.spoken.trimmingCharacters(in: .whitespaces).isEmpty
            || entry.written.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(Theme.Spacing.large)
    .frame(width: 440)
    .background(Theme.paper)
  }

  private func field(_ label: String, text: Binding<String>, identifier: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label.uppercased()).font(Theme.label).tracking(0.7).foregroundStyle(Theme.inkFaint)
      TextField("", text: text)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(
          RoundedRectangle(cornerRadius: Theme.Radius.control)
            .strokeBorder(Theme.hairline, lineWidth: 1))
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
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
    VStack(alignment: .leading, spacing: Theme.Spacing.large) {
      PageTitle(
        title: "Snippets",
        subtitle: "Say a short phrase, get a long one.",
        accessory: AnyView(
          Button("Add snippet") { editing = nil; showingEditor = true }
            .buttonStyle(.clay)
            .accessibilityIdentifier("snippets.addToolbar")))

      if snippets.isEmpty {
        Card {
          EmptyState(
            icon: "text.append",
            title: "No snippets yet",
            message: "“my meeting link” becomes your booking URL — and it works in the middle of a longer sentence, not just on its own.",
            actionTitle: "Add a snippet",
            action: { editing = nil; showingEditor = true },
            actionIdentifier: "snippets.add")
        }
      } else {
        Card(padding: 0) {
          VStack(spacing: 0) {
            ForEach(Array(snippets.enumerated()), id: \.element.id) { index, snippet in
              HStack(alignment: .top, spacing: Theme.Spacing.small) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(snippet.trigger)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                  Text(snippet.expansion)
                    .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
                    .lineLimit(2)
                }
                Spacer(minLength: Theme.Spacing.small)
                Menu {
                  Button("Edit") { editing = snippet; showingEditor = true }
                  Button("Delete", role: .destructive) {
                    if let id = snippet.id {
                      try? model.vocabulary?.deleteSnippet(id: id)
                      model.rebuildVocabulary()
                      reload()
                    }
                  }
                } label: {
                  Image(systemName: "ellipsis")
                    .font(.system(size: 12)).foregroundStyle(Theme.inkFaint)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
                .accessibilityLabel("Actions for this snippet")
              }
              .padding(.horizontal, Theme.Spacing.medium)
              .padding(.vertical, Theme.Spacing.small)
              if index < snippets.count - 1 {
                Divider().overlay(Theme.hairline).padding(.leading, Theme.Spacing.medium)
              }
            }
          }
        }
      }
    }
    .page()
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
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      Text(snippet.id == nil ? "New snippet" : "Edit snippet")
        .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)

      VStack(alignment: .leading, spacing: 4) {
        Text("WHEN I SAY").font(Theme.label).tracking(0.7).foregroundStyle(Theme.inkFaint)
        TextField("", text: $snippet.trigger)
          .textFieldStyle(.plain)
          .font(.system(size: 13))
          .padding(.horizontal, 10).padding(.vertical, 7)
          .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
          .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
              .strokeBorder(Theme.hairline, lineWidth: 1))
          .accessibilityIdentifier("snippets.trigger")
          .accessibilityLabel("When I say")
        Text("A short, distinctive phrase you would not say by accident.")
          .font(.system(size: 11.5)).foregroundStyle(Theme.inkMuted)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("EXPAND TO").font(Theme.label).tracking(0.7).foregroundStyle(Theme.inkFaint)
        TextEditor(text: $snippet.expansion)
          .font(.system(size: 13, design: .monospaced))
          .scrollContentBackground(.hidden)
          .padding(6)
          .frame(minHeight: 110)
          .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
          .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control)
              .strokeBorder(Theme.hairline, lineWidth: 1))
          .accessibilityIdentifier("snippets.expansion")
          .accessibilityLabel("Expand to")
      }

      Toggle("Enabled", isOn: $snippet.enabled).font(.system(size: 13))

      HStack {
        Button("Cancel") { dismiss() }.buttonStyle(.quiet)
        Spacer()
        Button("Save") { onSave(snippet) }
          .buttonStyle(.clay)
          .accessibilityIdentifier("snippets.save")
          .disabled(snippet.trigger.trimmingCharacters(in: .whitespaces).isEmpty
            || snippet.expansion.isEmpty)
      }
    }
    .padding(Theme.Spacing.large)
    .frame(width: 460)
    .background(Theme.paper)
  }
}

/// Rules Rant noticed you making, waiting for a yes or a no.
///
/// Nothing here is in effect. A candidate is inert until it is accepted — the dictation
/// pipeline never reads this table — which is what makes it safe to propose something
/// on a guess. The user's answer is what creates a dictionary entry.
struct SuggestedRules: View {
  @ObservedObject var learning: LearningObserver
  var onAccepted: () -> Void

  var body: some View {
    Section2(
      "Noticed from your corrections",
      subtitle: "Nothing changes until you accept it."
    ) {
      Card(padding: 0) {
        VStack(spacing: 0) {
          ForEach(Array(learning.candidates.enumerated()), id: \.element.id) {
            index, candidate in
            HStack(spacing: Theme.Spacing.small) {
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                  Text(candidate.spoken)
                    .font(.system(size: 13)).foregroundStyle(Theme.inkMuted)
                  Image(systemName: "arrow.right")
                    .font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
                    .accessibilityHidden(true)
                  Text(candidate.written)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                }
                Text(
                  candidate.occurrences > 1
                    ? "You corrected this \(candidate.occurrences) times"
                    : "You corrected this once")
                  .font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
              }
              Spacer(minLength: Theme.Spacing.small)
              Button("Add") {
                learning.accept(candidate)
                onAccepted()
              }
              .buttonStyle(.quiet)
              Button("No") { learning.reject(candidate) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.inkFaint)
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)

            if index < learning.candidates.count - 1 {
              Divider().overlay(Theme.hairline).padding(.leading, Theme.Spacing.medium)
            }
          }
        }
      }
    }
  }
}
