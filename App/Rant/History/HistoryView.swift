import RantCore
import SwiftUI

/// Everything you have dictated, searchable, with deletion one click away.
///
/// Making deletion obvious is a deliberate contrast with the alternatives: your words
/// are yours, and removing them should not require finding a setting.
struct HistoryView: View {
  @EnvironmentObject private var model: AppModel
  @State private var query = ""
  @State private var confirmingDeleteAll = false

  private var results: [Transcript] {
    query.trimmingCharacters(in: .whitespaces).isEmpty
      ? model.recentTranscripts
      : model.search(query).map(\.transcript)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.large) {
      PageTitle(
        title: "History",
        subtitle: "Everything you have said, on this Mac and nowhere else.",
        accessory: AnyView(
          Menu {
            Button("Export everything…") { model.exportArchive() }
            Divider()
            Button("Delete everything…", role: .destructive) { confirmingDeleteAll = true }
          } label: {
            Image(systemName: "ellipsis")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(Theme.inkMuted)
              .frame(width: 30, height: 26)
              .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
              .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                  .strokeBorder(Theme.hairline, lineWidth: 1))
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .accessibilityLabel("History actions")))

      searchField

      if results.isEmpty {
        Card {
          EmptyState(
            icon: query.isEmpty ? "waveform" : "magnifyingglass",
            title: query.isEmpty ? "No dictations yet" : "Nothing matches “\(query)”",
            message: query.isEmpty
              ? "Hold your dictation key anywhere and start talking."
              : "Search looks at both the cleaned text and what you actually said.")
        }
      } else {
        TranscriptList(transcripts: results)
      }
    }
    .page()
    .confirmationDialog(
      "Delete every transcript?", isPresented: $confirmingDeleteAll, titleVisibility: .visible
    ) {
      Button("Delete everything", role: .destructive) { model.deleteAllHistory() }
      Button("Keep them", role: .cancel) {}
    } message: {
      Text("This removes all \(model.recentTranscripts.count) transcripts and the statistics derived from them, from this Mac, permanently. Nothing is kept anywhere else.")
    }
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12))
        .foregroundStyle(Theme.inkFaint)
      TextField("Search everything you have dictated", text: $query)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(Theme.ink)
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 12))
            .foregroundStyle(Theme.inkFaint)
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
