import RantCore
import SwiftUI

/// The first screen: what Rant has done for you, and whether it is ready.
struct HomeView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var preferences: Preferences
  @EnvironmentObject private var permissions: Permissions

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.large) {
        header
        if !permissions.isReadyForDictation { permissionNotice }
        if !model.hasAPIKey && !preferences.localOnly { keyNotice }
        statistics
        recent
      }
      .padding(Theme.Spacing.large)
      .frame(maxWidth: 820, alignment: .leading)
    }
    .frame(maxWidth: .infinity)
    .navigationTitle("Home")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(greeting).font(.largeTitle.weight(.semibold))
      Text("Hold \(preferences.triggerKey.displayName) and talk. Let go and it lands where your cursor is.")
        .font(.body)
        .foregroundStyle(.secondary)
    }
  }

  private var greeting: String {
    switch Calendar.current.component(.hour, from: Date()) {
    case 5..<12: "Good morning"
    case 12..<18: "Good afternoon"
    case 18..<23: "Good evening"
    default: "Still up?"
    }
  }

  private var permissionNotice: some View {
    SectionCard(
      title: "Rant is not ready yet",
      subtitle: "Two permissions stand between you and dictating anywhere."
    ) {
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        if !permissions.microphone.isGranted {
          permissionRow(PermissionCopy.microphone, pane: .microphone) {
            Task { await permissions.requestMicrophone() }
          }
        }
        if !permissions.accessibility.isGranted {
          permissionRow(PermissionCopy.accessibility, pane: .accessibility) {
            permissions.requestAccessibility()
          }
        }
      }
    }
  }

  private func permissionRow(
    _ copy: PermissionCopy, pane: Permissions.Pane, action: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .top, spacing: Theme.Spacing.small) {
      Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.accent)
      VStack(alignment: .leading, spacing: 2) {
        Text(copy.title).font(.callout.weight(.medium))
        Text(copy.why).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      VStack(spacing: 4) {
        Button("Grant", action: action)
        Button("Open Settings") { permissions.open(pane) }
          .buttonStyle(.link).font(.caption)
      }
    }
  }

  private var keyNotice: some View {
    SectionCard(
      title: "Add your AssemblyAI key",
      subtitle: "Rant uses your own key, held in your Keychain. Or switch to local only and skip this entirely."
    ) {
      Text("Settings → Speech is where it goes.")
        .font(.callout).foregroundStyle(.secondary)
    }
  }

  private var statistics: some View {
    let total = model.recentTranscripts.reduce(0) { $0 + $1.wordCount }
    let averageWPM = model.recentTranscripts.compactMap(\.wordsPerMinute).average
    return HStack(spacing: Theme.Spacing.medium) {
      statCard("Words dictated", value: total.formatted(), systemImage: "text.word.spacing")
      statCard(
        "Average pace",
        value: averageWPM.map { "\(Int($0)) wpm" } ?? "—",
        systemImage: "speedometer")
      statCard(
        "Dictations", value: model.recentTranscripts.count.formatted(), systemImage: "waveform")
    }
  }

  private func statCard(_ title: String, value: String, systemImage: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: systemImage)
        .font(.caption).foregroundStyle(.secondary)
      Text(value).font(.title2.weight(.semibold)).monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .card()
  }

  private var recent: some View {
    SectionCard(title: "Recent", subtitle: model.recentTranscripts.isEmpty ? "Nothing yet — try holding your dictation key." : nil) {
      VStack(spacing: 0) {
        ForEach(model.recentTranscripts.prefix(8)) { transcript in
          TranscriptRow(transcript: transcript)
          if transcript.id != model.recentTranscripts.prefix(8).last?.id { Divider() }
        }
      }
    }
  }
}

struct TranscriptRow: View {
  let transcript: Transcript
  @EnvironmentObject private var model: AppModel
  @State private var showingRaw = false

  var body: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.small) {
      VStack(alignment: .leading, spacing: 4) {
        Text(showingRaw ? transcript.rawText : transcript.finalText)
          .font(.callout)
          .textSelection(.enabled)
        HStack(spacing: 8) {
          Text(transcript.createdAt, format: .relative(presentation: .named))
          if let app = transcript.appName { Text("· \(app)") }
          Text("· \(transcript.wordCount) words")
          if let wpm = transcript.wordsPerMinute { Text("· \(Int(wpm)) wpm") }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
      }
      Spacer()
      Menu {
        Button("Copy") { model.copy(showingRaw ? transcript.rawText : transcript.finalText) }
        // Both texts are always kept, so you can always get back to what you said
        // when cleanup dropped something that mattered.
        Toggle("Show what I actually said", isOn: $showingRaw)
        Divider()
        Button("Delete", role: .destructive) { model.delete(transcript) }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .frame(width: 28)
    }
    .padding(.vertical, 8)
  }
}

extension Collection where Element == Double {
  var average: Double? { isEmpty ? nil : reduce(0, +) / Double(count) }
}
