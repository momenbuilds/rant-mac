import RantCore
import SwiftUI

/// The first screen: how to use it, what it has done for you, and what you just said.
struct HomeView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var preferences: Preferences
  @EnvironmentObject private var permissions: Permissions

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.large) {
      PageTitle(title: greeting, subtitle: nil)
      hotkeyLine
      if !permissions.isReadyForDictation { permissionNotice }
      if !model.hasAPIKey && !preferences.localOnly { keyNotice }
      statStrip
      recent
    }
    .page()
  }

  private var greeting: String {
    switch Calendar.current.component(.hour, from: Date()) {
    case 5..<12: "Good morning"
    case 12..<18: "Good afternoon"
    case 18..<23: "Good evening"
    default: "Still up?"
    }
  }

  /// The instruction, drawn as the keys you actually press. Both references put this
  /// at the very top of the home screen, and it is the right call: the one thing a
  /// new user needs is which key, and the one thing an old user needs is a reminder
  /// after they change it.
  private var hotkeyLine: some View {
    HStack(spacing: 8) {
      Text("Hold").font(.system(size: 15)).foregroundStyle(Theme.inkMuted)
      KeyCap(text: preferences.triggerKey.displayName)
      Text("and talk. Let go and it lands where your cursor is.")
        .font(.system(size: 15))
        .foregroundStyle(Theme.inkMuted)
      Spacer()
    }
  }

  // MARK: - Notices

  private var permissionNotice: some View {
    Card(fill: Theme.claySoft) {
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        HStack(spacing: 7) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundStyle(Theme.clay)
            .accessibilityHidden(true)
          Text(remaining == 1 ? "One switch left" : "Rant is not ready yet")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.ink)
          Spacer()
          if remaining == 1 {
            Text("takes 3 seconds")
              .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
          }
        }

        if !permissions.microphone.isGranted {
          permissionRow(PermissionCopy.microphone, pane: .microphone) {
            Task { await permissions.requestMicrophone() }
          }
        }
        if !permissions.accessibility.isGranted {
          permissionRow(PermissionCopy.accessibility, pane: .accessibility) {
            permissions.requestAccessibility()
          }
          if permissions.looksStale { staleGrantHelp }
        }
      }
    }
  }

  /// How many of the two required permissions are still missing. Saying "one switch
  /// left" is a materially different message from "not ready yet" — the first is a
  /// task, the second is a verdict.
  private var remaining: Int {
    (permissions.microphone.isGranted ? 0 : 1) + (permissions.accessibility.isGranted ? 0 : 1)
  }

  private func permissionRow(
    _ copy: PermissionCopy, pane: Permissions.Pane, action: @escaping () -> Void
  ) -> some View {
    HStack(alignment: .top, spacing: Theme.Spacing.small) {
      VStack(alignment: .leading, spacing: 2) {
        Text(copy.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
        Text(copy.why)
          .font(.system(size: 12))
          .foregroundStyle(Theme.inkMuted)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: Theme.Spacing.small)
      VStack(alignment: .trailing, spacing: 4) {
        Button("Grant", action: action).buttonStyle(.clay)
        Button("Open Settings") { permissions.open(pane) }
          .buttonStyle(.plain)
          .font(.system(size: 11))
          .foregroundStyle(Theme.clay)
      }
    }
  }

  /// The specific failure that looks like the app is broken: the switch in System
  /// Settings is already on, but macOS recorded the grant against an earlier build.
  /// Every rebuild of an ad-hoc-signed app has a different signature, so the entry
  /// authorises a binary that no longer exists. Nothing in the app can fix it, and
  /// without saying so the user keeps toggling a switch that is already on.
  private var staleGrantHelp: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
      Divider().overlay(Theme.hairline)
      Text("Already switched on in System Settings?")
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(Theme.ink)
      Text("Then macOS is holding an out-of-date entry — this happens whenever Rant is rebuilt. Remove Rant from the Accessibility list with “–”, then add it back with “+”. Or run this once and grant it again:")
        .font(.system(size: 12))
        .foregroundStyle(Theme.inkMuted)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Text("tccutil reset Accessibility dev.rant.mac.dev")
          .font(.system(size: 11.5, design: .monospaced))
          .foregroundStyle(Theme.ink)
          .textSelection(.enabled)
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
          .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.chip)
              .strokeBorder(Theme.hairline, lineWidth: 1))
        Button("Copy") { model.copy("tccutil reset Accessibility dev.rant.mac.dev") }
          .buttonStyle(.quiet)
      }
    }
  }

  private var keyNotice: some View {
    Card {
      HStack(alignment: .top, spacing: Theme.Spacing.small) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Add your AssemblyAI key")
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
          Text("Rant uses your own key, held in your Keychain. Or switch to local only and skip this entirely.")
            .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: Theme.Spacing.small)
        PrivacyBadge(level: preferences.localOnly ? .onDevice : .network)
      }
    }
  }

  // MARK: - Statistics

  /// A single strip rather than three separate cards. It reads as one fact about you
  /// instead of three competing boxes.
  private var statStrip: some View {
    Card(padding: Theme.Spacing.large) {
      HStack(alignment: .top, spacing: Theme.Spacing.large) {
        Stat(value: totalWords.formatted(), label: "Words dictated")
        divider
        Stat(
          value: averageWPM.map { "\(Int($0))" } ?? "—", label: "Average pace",
          unit: averageWPM == nil ? nil : "wpm")
        divider
        Stat(value: model.recentTranscripts.count.formatted(), label: "Dictations")
        divider
        Stat(value: timeSaved, label: "Time saved", tint: Theme.clay)
      }
    }
  }

  private var divider: some View {
    Rectangle().fill(Theme.hairline).frame(width: 1, height: 38)
  }

  private var totalWords: Int {
    model.recentTranscripts.reduce(0) { $0 + $1.wordCount }
  }

  private var averageWPM: Double? {
    let values = model.recentTranscripts.compactMap(\.wordsPerMinute)
    return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
  }

  /// Against typing rather than against nothing: the assumption is stated so the
  /// number means something.
  private var timeSaved: String {
    let typedSeconds = Double(totalWords) / 40 * 60
    let spokenSeconds = model.recentTranscripts.reduce(0) { $0 + Double($1.durationMilliseconds) / 1000 }
    let saved = max(0, typedSeconds - spokenSeconds)
    if saved < 60 { return "0m" }
    if saved < 3_600 { return "\(Int(saved / 60))m" }
    return String(format: "%.1fh", saved / 3_600)
  }

  // MARK: - Recent

  private var recent: some View {
    Section2(
      "Recent",
      accessory: model.recentTranscripts.isEmpty
        ? nil
        : AnyView(
          Text("\(model.recentTranscripts.count) total")
            .font(.system(size: 11)).foregroundStyle(Theme.inkFaint))
    ) {
      if model.recentTranscripts.isEmpty {
        Card {
          EmptyState(
            icon: "waveform",
            title: "Nothing yet",
            message: "Hold \(preferences.triggerKey.displayName) anywhere on your Mac and start talking. What you say lands where your cursor already is.")
        }
      } else {
        TranscriptList(transcripts: Array(model.recentTranscripts.prefix(12)))
      }
    }
  }
}

// MARK: - The transcript list

/// Transcripts grouped by day, with the time in a left gutter.
///
/// Both references land on this shape and it is worth taking: the timestamp column
/// gives the eye a rail to scan, and the date heading turns a wall of rows into
/// something you can navigate by memory — "that was Tuesday".
struct TranscriptList: View {
  let transcripts: [Transcript]
  @EnvironmentObject private var model: AppModel

  private var grouped: [(day: Date, items: [Transcript])] {
    let calendar = Calendar.current
    let buckets = Dictionary(grouping: transcripts) { calendar.startOfDay(for: $0.createdAt) }
    return buckets.keys.sorted(by: >).map { ($0, buckets[$0]!.sorted { $0.createdAt > $1.createdAt }) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      ForEach(grouped, id: \.day) { group in
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
          Text(Self.dayLabel(group.day).uppercased())
            .font(Theme.label)
            .tracking(0.7)
            .foregroundStyle(Theme.inkFaint)

          Card(padding: 0) {
            VStack(spacing: 0) {
              ForEach(Array(group.items.enumerated()), id: \.element.id) { index, transcript in
                TranscriptRow(transcript: transcript)
                if index < group.items.count - 1 {
                  Divider().overlay(Theme.hairline).padding(.leading, 82)
                }
              }
            }
          }
        }
      }
    }
  }

  static func dayLabel(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    let formatter = DateFormatter()
    formatter.dateFormat = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
      ? "EEEE d MMMM" : "d MMMM yyyy"
    return formatter.string(from: date)
  }
}

/// One dictation. The row actions appear on hover, which keeps a long list quiet.
struct TranscriptRow: View {
  let transcript: Transcript
  @EnvironmentObject private var model: AppModel
  @State private var showingRaw = false
  @State private var hovering = false
  @State private var copied = false

  var body: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.small) {
      Text(transcript.createdAt, format: .dateTime.hour().minute())
        .font(.system(size: 11.5).monospacedDigit())
        .foregroundStyle(Theme.inkFaint)
        .frame(width: 58, alignment: .leading)
        .padding(.top, 2)

      VStack(alignment: .leading, spacing: 5) {
        Text(showingRaw ? transcript.rawText : transcript.finalText)
          .font(.system(size: 13.5))
          .foregroundStyle(Theme.ink)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 6) {
          if showingRaw {
            Chip(text: "What you said", tint: Theme.clay, fill: Theme.claySoft)
          }
          if let app = transcript.appName {
            Text(app)
          }
          Text("\(transcript.wordCount) words")
          if let wpm = transcript.wordsPerMinute {
            Text("\(Int(wpm)) wpm")
          }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.inkFaint)
      }

      Spacer(minLength: Theme.Spacing.small)

      HStack(spacing: 2) {
        if hovering || copied {
          action(copied ? "checkmark" : "doc.on.doc", "Copy") {
            model.copy(showingRaw ? transcript.rawText : transcript.finalText)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
          }
          // Both texts are always kept, so you can always get back to what you said
          // when cleanup dropped something that mattered.
          action(
            showingRaw ? "sparkles" : "text.quote",
            showingRaw ? "Show the cleaned version" : "Show what you actually said"
          ) {
            showingRaw.toggle()
          }
          action("trash", "Delete") { model.delete(transcript) }
        }
      }
      .frame(width: 84, alignment: .trailing)
      .animation(Theme.gentle, value: hovering)
    }
    .padding(.horizontal, Theme.Spacing.medium)
    .padding(.vertical, Theme.Spacing.small)
    .background(hovering ? Theme.sunken.opacity(0.5) : .clear)
    .onHover { hovering = $0 }
  }

  private func action(_ icon: String, _ label: String, _ perform: @escaping () -> Void)
    -> some View
  {
    Button(action: perform) {
      Image(systemName: icon)
        .font(.system(size: 11))
        .foregroundStyle(Theme.inkMuted)
        .frame(width: 24, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
  }
}
