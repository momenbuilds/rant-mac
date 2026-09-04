import RantCore
import SwiftUI

/// Meetings recorded locally, with no bot joining the call.
///
/// The screen is deliberately plain about what was captured. "Me" and "Them" come
/// from which audio channel a segment arrived on, which is a fact Rant always knows —
/// as opposed to speaker names, which depend on the provider and are therefore shown
/// only when they exist.
struct NotetakerView: View {
  @EnvironmentObject private var model: AppModel
  @State private var meetings: [Meeting] = []
  @State private var selection: Int64?
  @State private var segments: [MeetingSegment] = []
  @State private var query = ""

  var body: some View {
    HSplitView {
      list.frame(minWidth: 250, idealWidth: 290)
      detail.frame(minWidth: 420)
    }
    .navigationTitle("Notetaker")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { model.startMeeting() } label: {
          Label("Start recording", systemImage: "record.circle")
        }
        .help("Records your microphone and, with Screen Recording granted, the other people on the call")
      }
      ToolbarItem {
        Menu {
          ForEach(MeetingExportFormat.allCases, id: \.self) { format in
            Button("Export as \(format.rawValue.uppercased())") { export(format) }
          }
          Divider()
          Button("Delete", role: .destructive) { deleteSelected() }
        } label: { Label("More", systemImage: "ellipsis.circle") }
        .accessibilityLabel("Meeting actions")
        .disabled(current == nil)
      }
    }
    .onAppear(perform: reload)
    .onChange(of: selection) { _, _ in loadSegments() }
  }

  private var current: Meeting? { meetings.first { $0.id == selection } }

  @ViewBuilder private var list: some View {
    if meetings.isEmpty {
      ContentUnavailableView {
        Label("No meetings yet", systemImage: "person.2.wave.2")
      } description: {
        Text("Press Start recording when a call begins. Rant captures your microphone and, if you grant Screen Recording, the other people too. Nothing joins your call and nothing is uploaded.")
      }
    } else {
      List(shown, id: \.id, selection: $selection) { meeting in
        VStack(alignment: .leading, spacing: 2) {
          Text(meeting.title ?? "Untitled meeting").fontWeight(.medium)
          HStack(spacing: 6) {
            Text(meeting.startedAt, format: .dateTime.day().month().hour().minute())
            if meeting.endedAt != nil { Text("· \(meeting.durationMilliseconds / 60_000) min") }
          }
          .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .tag(meeting.id ?? -1)
      }
      .searchable(text: $query, prompt: "Search everything that was said")
    }
  }

  /// Search hits arrive one per matching segment, so a meeting mentioned three times
  /// would otherwise appear three times in the list.
  private var shown: [Meeting] {
    guard !query.trimmingCharacters(in: .whitespaces).isEmpty, let store = model.meetings else {
      return meetings
    }
    let hits = (try? store.search(query, limit: 100)) ?? []
    var seen = Set<Int64>()
    return hits.compactMap { hit in
      guard let id = hit.meeting.id, seen.insert(id).inserted else { return nil }
      return hit.meeting
    }
  }

  @ViewBuilder private var detail: some View {
    if let meeting = current {
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
          VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title ?? "Untitled meeting").font(.title2.weight(.semibold))
            Text(meeting.startedAt, format: .dateTime.weekday().day().month().hour().minute())
              .font(.callout).foregroundStyle(.secondary)
          }

          if let summary = meeting.summary, !summary.isEmpty {
            SectionCard(title: "Summary") {
              Text(summary).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          if !meeting.actionItems.isEmpty {
            SectionCard(title: "Action items") {
              VStack(alignment: .leading, spacing: 5) {
                ForEach(meeting.actionItems, id: \.self) { item in
                  Label(item, systemImage: "square").font(.callout)
                }
              }
            }
          }
          if !meeting.decisions.isEmpty {
            SectionCard(title: "Decisions") {
              VStack(alignment: .leading, spacing: 5) {
                ForEach(meeting.decisions, id: \.self) { item in
                  Label(item, systemImage: "checkmark.diamond").font(.callout)
                }
              }
            }
          }

          SectionCard(title: "Transcript", subtitle: "\(segments.count) segments") {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
              ForEach(segments, id: \.id) { segment in
                HStack(alignment: .top, spacing: Theme.Spacing.small) {
                  Text(MeetingExport.clock(milliseconds: segment.startedMilliseconds))
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    .frame(width: 62, alignment: .leading)
                  VStack(alignment: .leading, spacing: 1) {
                    Text(label(for: segment))
                      .font(.caption.weight(.medium))
                      .foregroundStyle(segment.channel == .me ? Theme.accent : .secondary)
                    Text(segment.text).font(.callout).textSelection(.enabled)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                }
              }
            }
          }
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: 720, alignment: .leading)
      }
    } else {
      ContentUnavailableView("Select a meeting", systemImage: "person.2.wave.2")
    }
  }

  /// A diarised speaker name when the provider gave one, otherwise the channel —
  /// which Rant always knows, because it is which microphone the audio arrived on.
  private func label(for segment: MeetingSegment) -> String {
    if let speaker = segment.speaker, !speaker.isEmpty { return speaker }
    return segment.channel == .me ? "Me" : "Them"
  }

  private func reload() {
    meetings = (try? model.meetings?.recent(limit: 200, offset: 0)) ?? []
  }

  private func loadSegments() {
    guard let store = model.meetings, let id = selection else {
      segments = []
      return
    }
    segments = (try? store.segments(forMeeting: id)) ?? []
  }

  private func export(_ format: MeetingExportFormat) {
    guard let meeting = current else { return }
    let text: String
    switch format {
    case .markdown: text = MeetingExport.markdown(meeting: meeting, segments: segments)
    case .text: text = MeetingExport.plainText(meeting: meeting, segments: segments)
    case .json: text = (try? MeetingExport.json(meeting: meeting, segments: segments)) ?? ""
    case .srt: text = MeetingExport.srt(segments)
    case .vtt: text = MeetingExport.vtt(segments)
    }
    let name = (meeting.title ?? "meeting").replacingOccurrences(of: "/", with: "-")
    model.exportText(text, suggestedName: "\(name).\(format.fileExtension)")
  }

  private func deleteSelected() {
    guard let store = model.meetings, let id = selection else { return }
    try? store.delete(id: id)
    selection = nil
    reload()
  }
}
