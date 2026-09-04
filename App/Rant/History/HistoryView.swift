import RantCore
import SwiftUI

/// Local transcript history, with search and per-item deletion that is exactly one
/// click away.
///
/// Making deletion obvious is a deliberate contrast with the competitors: your words
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
    VStack(spacing: 0) {
      if results.isEmpty {
        ContentUnavailableView(
          query.isEmpty ? "No dictations yet" : "Nothing matches “\(query)”",
          systemImage: query.isEmpty ? "waveform" : "magnifyingglass",
          description: Text(query.isEmpty
            ? "Hold your dictation key anywhere and start talking."
            : "Search looks at both the cleaned text and what you actually said."))
      } else {
        List {
          ForEach(results) { transcript in
            TranscriptRow(transcript: transcript)
          }
        }
        .listStyle(.inset)
      }
    }
    .searchable(text: $query, prompt: "Search everything you have dictated")
    .navigationTitle("History")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Button("Delete everything…", role: .destructive) { confirmingDeleteAll = true }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
    .confirmationDialog(
      "Delete every transcript?",
      isPresented: $confirmingDeleteAll, titleVisibility: .visible
    ) {
      Button("Delete everything", role: .destructive) { model.deleteAllHistory() }
      Button("Keep them", role: .cancel) {}
    } message: {
      Text("This removes all \(model.recentTranscripts.count) transcripts and the statistics derived from them, from this Mac, permanently. Nothing is kept anywhere else.")
    }
  }
}
