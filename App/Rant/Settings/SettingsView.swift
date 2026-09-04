import RantCore
import SwiftUI

/// The settings panes, as one list so the picker and the content can never disagree
/// about what exists.
enum SettingsPane: String, CaseIterable, Identifiable {
  case general, speech, intelligence, privacy, notetaker, integrations, advanced,
    diagnostics

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .speech: "Speech"
    case .intelligence: "Intelligence"
    case .privacy: "Privacy"
    case .notetaker: "Notetaker"
    case .integrations: "Integrations"
    case .advanced: "Advanced"
    case .diagnostics: "Diagnostics"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .speech: "waveform"
    case .intelligence: "wand.and.stars"
    case .privacy: "hand.raised"
    case .notetaker: "person.2.wave.2"
    case .integrations: "puzzlepiece.extension"
    case .advanced: "wrench.and.screwdriver"
    case .diagnostics: "stethoscope"
    }
  }
}

struct SettingsView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var preferences: Preferences
  @EnvironmentObject private var permissions: Permissions

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pane: SettingsPane = .general
  @Namespace private var paneHighlight

  // A `TabView` here drew its own tab bar at the top of the *window*, above the page
  // title and outside the page's margins, so Settings was the one screen that did not
  // look like the rest of the app. Its tabs also surfaced as bare radio buttons with
  // no identifiers of their own. Owning the control fixes the layout and lets each
  // tab carry an identifier.
  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      PageTitle(
        title: "Settings", subtitle: "Everything Rant does, and what it does with your words.")

      picker

      // No ScrollView here: every pane is a grouped `Form`, which scrolls itself.
      // Nesting the two gives an inner scroller inside an outer one and a form that
      // will not reach its own bottom.
      Group {
        switch pane {
        case .general: GeneralSettings()
        case .speech: SpeechSettings()
        case .intelligence: IntelligenceSettings()
        case .privacy: PrivacySettings()
        case .notetaker: NotetakerSettings()
        case .integrations: IntegrationsSettings()
        case .advanced: AdvancedSettings()
        case .diagnostics: DiagnosticsSettings()
        }
      }
      .scrollContentBackground(.hidden)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .padding(.horizontal, Theme.Spacing.page)
    .padding(.top, Theme.Spacing.page)
    .padding(.bottom, Theme.Spacing.medium)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Theme.paper)
  }

  private var picker: some View {
    HStack(spacing: Theme.Spacing.hair) {
      ForEach(SettingsPane.allCases) { candidate in
        Button {
          withAnimation(Theme.animation(Theme.springy, reduceMotion: reduceMotion)) {
            pane = candidate
          }
        } label: {
          SettingsPaneLabel(
            pane: candidate, isSelected: pane == candidate, highlight: paneHighlight)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.tab.\(candidate.rawValue)")
      }
      Spacer(minLength: 0)
    }
    .padding(Theme.Spacing.hair)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        .fill(Theme.sunken))
  }
}

/// A live input level, so "is this microphone working" has an answer that does not
/// require recording something and reading it back.
struct MicrophoneMeter: View {
  let level: Float
  private let segments = 18

  var body: some View {
    HStack(spacing: 2) {
      ForEach(0..<segments, id: \.self) { index in
        // A little gamma so quiet speech still moves several segments; a linear meter
        // on RMS looks broken at conversational volume.
        let threshold = Float(index + 1) / Float(segments)
        let scaled = min(1, powf(max(level, 0), 0.5) * 1.6)
        RoundedRectangle(cornerRadius: 1, style: .continuous)
          .fill(scaled >= threshold ? Theme.clay : Theme.hairline)
          .frame(width: 3, height: index < segments - 4 ? 9 : 12)
      }
    }
    .animation(.linear(duration: 0.05), value: level)
    .accessibilityLabel("Input level")
    .accessibilityValue("\(Int(min(max(level, 0), 1) * 100)) percent")
  }
}

/// Pulled out of the picker because the whole chain inline defeated the type checker.
private struct SettingsPaneLabel: View {
  let pane: SettingsPane
  let isSelected: Bool
  let highlight: Namespace.ID

  var body: some View {
    Label(pane.title, systemImage: pane.symbol)
      .labelStyle(.titleAndIcon)
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(isSelected ? Theme.clay : Theme.inkMuted)
      .padding(.horizontal, Theme.Spacing.small)
      .padding(.vertical, Theme.Spacing.tight)
      .background(selectionBackground)
      .contentShape(Rectangle())
  }

  @ViewBuilder private var selectionBackground: some View {
    if isSelected {
      RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
        .fill(Theme.surface)
        .matchedGeometryEffect(id: "settings.pane", in: highlight)
    }
  }
}

struct GeneralSettings: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var preferences: Preferences

  var body: some View {
    Form {
      Section("Dictation key") {
        Picker("Trigger", selection: $preferences.triggerKey) {
          ForEach(TriggerKey.allCases, id: \.self) { key in
            Text(key.displayName).tag(key)
          }
        }
        Picker("Behaviour", selection: $preferences.activationMode) {
          ForEach(ActivationMode.allCases, id: \.self) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        Text("A lone modifier types nothing on its own, so Rant can use it without taking a shortcut away from you. Press it with another key and it behaves exactly as it always did.")
          .font(.caption).foregroundStyle(.secondary)
        Text("Double-tap to keep recording hands-free. Escape always cancels without inserting anything.")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("Interface") {
        Toggle("Keep the recorder visible when idle", isOn: $preferences.overlayAlwaysVisible)
        Toggle("Play a sound when recording starts and stops", isOn: $preferences.playSounds)
      }
    }
    .formStyle(.grouped)
    .onChange(of: preferences.triggerKey) { _, _ in model.installHotkeys() }
    .onChange(of: preferences.activationMode) { _, _ in model.installHotkeys() }
  }
}

struct SpeechSettings: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var preferences: Preferences
  @State private var apiKey = ""
  @State private var testResult: String?
  @State private var testing = false

  var body: some View {
    Form {
      // Built from the same registry the dictation session resolves against, so the
      // list cannot drift from what actually runs. It previously offered exactly one
      // engine while the code ignored the selection entirely.
      Section("Speech engine") {
        Picker("Engine", selection: $preferences.speechProvider) {
          ForEach(model.speechProviderRegistry().descriptors()) { descriptor in
            Text(descriptor.displayName).tag(descriptor.identifier)
          }
        }
        ForEach(model.speechProviderRegistry().descriptors()) { descriptor in
          if descriptor.identifier == preferences.speechProvider {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.tight) {
              PrivacyBadge(level: descriptor.sendsAudioOffDevice ? .network : .onDevice)
              Text(descriptor.privacyLabel)
                .font(.caption).foregroundStyle(.secondary)
              Spacer()
            }
            // Says why an engine cannot be used, instead of letting the user find out
            // at the first dictation.
            if let explanation = descriptor.status.explanation {
              Text(explanation).font(.caption).foregroundStyle(Theme.live)
            }
          }
        }
        Text("The on-device engine uses the speech model already on your Mac. It needs no key and no download, and Rant refuses to run it over the network — if your Mac cannot recognise your language offline, you get an error rather than an upload.")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("AssemblyAI key") {
        // The key is write-only in the UI: once stored it is never displayed again,
        // because a key visible on screen is a key in a screenshot.
        if model.hasAPIKey {
          Label("A key is stored in your Keychain", systemImage: "key.fill")
            .foregroundStyle(Theme.moss)
        }
        SecureField("Paste your API key", text: $apiKey)
          .textFieldStyle(.roundedBorder)
        HStack {
          Button("Save to Keychain") { save() }
            .disabled(APIKeyValidator.check(apiKey) != .looksValid)
          Button(testing ? "Testing…" : "Test connection") { test() }
            .disabled(testing || !model.hasAPIKey)
          Spacer()
        }
        if let message = APIKeyValidator.check(apiKey).message, !apiKey.isEmpty {
          Text(message).font(.caption).foregroundStyle(Theme.live)
        }
        if let testResult {
          Text(testResult).font(.caption).foregroundStyle(.secondary)
        }
        Text("Your key is stored only in the macOS Keychain. It is never written to preferences, logs or any file, and it is never sent anywhere except AssemblyAI.")
          .font(.caption).foregroundStyle(.secondary)
      }

      // The device preference existed and was never handed to the capture, and there
      // was nowhere to set it. Both halves are here now: the list, and a meter that
      // proves the chosen microphone is the one being heard.
      Section("Live preview") {
        Toggle("Show words while I am still speaking", isOn: $preferences.livePreview)
          .onChange(of: preferences.livePreview) { _, _ in model.buildSession() }
        Text("Streams the audio to AssemblyAI a second time so the recorder can show interim text. The on-device engine does not stream, and Local only refuses it outright — the preview is not worth opening a connection you asked Rant not to open.")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("Microphone") {
        Picker("Input", selection: Binding(
          get: { preferences.microphoneUniqueID ?? "" },
          set: { preferences.microphoneUniqueID = $0.isEmpty ? nil : $0 })
        ) {
          Text("System default").tag("")
          ForEach(model.availableMicrophones) { device in
            Text(device.name).tag(device.uniqueID)
          }
        }
        LabeledContent("Level") {
          MicrophoneMeter(level: model.meterLevel)
        }
        Text("The meter moves when Rant can hear you. If it stays flat, macOS has not granted the microphone, or the wrong input is selected.")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("Language") {
        Picker("Language", selection: Binding(
          get: { preferences.languageCode ?? "auto" },
          set: { preferences.languageCode = $0 == "auto" ? nil : $0 })
        ) {
          Text("Detect automatically").tag("auto")
          Text("English").tag("en")
          Text("Spanish").tag("es")
          Text("French").tag("fr")
          Text("German").tag("de")
          Text("Portuguese").tag("pt")
          Text("Italian").tag("it")
          Text("Dutch").tag("nl")
          Text("Japanese").tag("ja")
          Text("Hindi").tag("hi")
        }
      }
    }
    .formStyle(.grouped)
    // Only while this pane is on screen: keeping the engine warm for a meter nobody
    // is looking at would hold the microphone open for no reason.
    .onAppear { model.beginLevelMonitoring() }
    .onDisappear { model.endLevelMonitoring() }
  }

  private func save() {
    do {
      try model.saveAPIKey(apiKey)
      apiKey = ""
      testResult = "Saved."
    } catch {
      testResult = error.localizedDescription
    }
  }

  private func test() {
    testing = true
    testResult = nil
    Task {
      let result = await model.testConnection()
      testing = false
      switch result {
      case .success: testResult = "Connected. Your key works."
      case .failure(let error): testResult = error.localizedDescription
      }
    }
  }
}

struct IntelligenceSettings: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var preferences: Preferences

  var body: some View {
    Form {
      Section("Cleanup") {
        Picker("How much cleanup", selection: $preferences.cleanupLevel) {
          ForEach(CleanupLevel.allCases, id: \.self) { level in
            Text(level.displayName).tag(level)
          }
        }
        .accessibilityIdentifier("settings.cleanupLevel")
        Text(preferences.cleanupLevel.summary).font(.caption).foregroundStyle(.secondary)
        Toggle("Do cleanup on this Mac rather than at the provider", isOn: $preferences.preferLocalCleanup)
        Text("Rant's None, Light and Medium cleanup are plain code running on your machine — instant, free, and identical offline. Only High asks a model.")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("Enhancement") {
        Picker("Provider", selection: $preferences.enhancementProvider) {
          Text("None").tag("none")
          Text("Local model via Ollama").tag("ollama")
        }
        if preferences.enhancementProvider == "ollama" {
          TextField("Endpoint", text: $preferences.ollamaEndpoint)
          TextField("Model", text: $preferences.ollamaModel)
          PrivacyBadge(level: preferences.ollamaEndpoint.contains("localhost") ? .onDevice : .network)
        }
      }
    }
    .formStyle(.grouped)
    .onChange(of: preferences.enhancementProvider) { _, _ in model.buildSession() }
  }
}

struct PrivacySettings: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var preferences: Preferences
  @State private var confirmingWipe = false

  var body: some View {
    Form {
      Section("The short version") {
        Label("No account, no telemetry, no analytics SDK", systemImage: "checkmark.shield")
        Label("Your key lives in the Keychain and nowhere else", systemImage: "key")
        Label("Rant never reads from or types into a password field", systemImage: "lock")
        Text("With no API key configured, Rant makes no network requests at all. Every request it can make is listed in docs/NETWORK_BEHAVIOR.md in the repository.")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("Context") {
        Toggle("Let Rant see what I'm working on", isOn: $preferences.contextEnabled)
        Toggle("Allow a little of it to be sent to my speech provider", isOn: $preferences.contextAllowCloud)
          .disabled(!preferences.contextEnabled || preferences.localOnly)
        Text("Only two things can ever be sent: your recent dictations, and the text just before your cursor. The app you are in, the window title, the site, your selection, your clipboard and anything read from the screen stay on this Mac. Credential-shaped text is removed before anything is sent.")
          .font(.caption).foregroundStyle(.secondary)
        Toggle("Use my clipboard as context", isOn: $preferences.contextUseClipboard)
          .disabled(!preferences.contextEnabled)
        Toggle("Read the visible window with OCR", isOn: $preferences.contextUseScreenOCR)
          .disabled(!preferences.contextEnabled)
      }

      Section("Network") {
        Toggle("Local only — never send audio or text anywhere", isOn: $preferences.localOnly)
          .accessibilityIdentifier("settings.localOnly")
        Text("With this on, a provider that needs the network is refused outright rather than quietly falling back. You will get an error, not a surprise.")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("Audio") {
        Toggle("Keep the recorded audio", isOn: $preferences.retainAudio)
        if preferences.retainAudio {
          Picker("Keep it for", selection: $preferences.audioRetentionDays) {
            Text("24 hours").tag(1)
            Text("7 days").tag(7)
            Text("30 days").tag(30)
            Text("Forever").tag(0)
          }
        }
        Text("Off by default. Rant transcribes from memory and throws the audio away.")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("Your data") {
        LabeledContent("Everything Rant knows is in") {
          Text("~/Library/Application Support/Rant").font(.caption).textSelection(.enabled)
        }
        Button("Reveal in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([AppModel.supportDirectory()])
        }
        Button("Delete all local data…", role: .destructive) { confirmingWipe = true }
      }
    }
    .formStyle(.grouped)
    .onChange(of: preferences.localOnly) { _, _ in model.buildSession() }
    .confirmationDialog(
      "Delete everything Rant has stored?", isPresented: $confirmingWipe, titleVisibility: .visible
    ) {
      Button("Delete it all", role: .destructive) { model.deleteAllHistory() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Transcripts, statistics and any retained audio, gone from this Mac. Your API key stays in the Keychain until you remove it there.")
    }
  }
}

/// Notetaker settings — capture, summaries, calendar, retention.
struct NotetakerSettings: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var preferences: Preferences
  @EnvironmentObject private var permissions: Permissions
  @State private var calendarGranted = false

  var body: some View {
    Form {
      Section("Capture") {
        LabeledContent("System audio") {
          HStack(spacing: Theme.Spacing.tight) {
            Text(permissions.screenRecording.isGranted ? "Granted" : "Not granted")
              .foregroundStyle(
                permissions.screenRecording.isGranted ? Theme.moss : Theme.clay)
            if !permissions.screenRecording.isGranted {
              Button("Grant…") { permissions.requestScreenRecording() }
                .buttonStyle(.quiet)
            }
          }
        }
        Text("Without it Rant records only your microphone, so a meeting has your half and not theirs. macOS puts system-audio capture behind Screen Recording; Rant asks for the smallest frame the API accepts and never reads one.")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("Summaries") {
        LabeledContent(
          "Summariser",
          value: preferences.enhancementProvider == "none"
            ? "Built in (no model)" : preferences.enhancementProvider)
        Text(
          preferences.localOnly
            ? "Local only is on, so meeting transcripts are never sent to a model that leaves this Mac. Summaries come from the built-in structural extraction."
            : "A remote enhancer sees the meeting transcript. Turn on Local only in Privacy to keep summarising entirely on this Mac."
        )
        .font(.caption).foregroundStyle(.secondary)
      }

      Section("Calendar") {
        LabeledContent("Upcoming events") {
          HStack(spacing: Theme.Spacing.tight) {
            Text(calendarGranted ? "Granted" : "Not granted")
              .foregroundStyle(calendarGranted ? Theme.moss : Theme.inkMuted)
            if !calendarGranted {
              Button("Grant…") {
                Task {
                  await model.requestCalendarAccess()
                  calendarGranted = await model.hasCalendarAccess
                }
              }
              .buttonStyle(.quiet)
            }
          }
        }
        if !model.upcomingEvents.isEmpty {
          ForEach(model.upcomingEvents, id: \.id) { event in
            LabeledContent(event.title) {
              Text(event.startDate, format: .dateTime.hour().minute())
                .foregroundStyle(.secondary)
            }
          }
        }
        Text("Used only to name a meeting and show its join link. Your calendar is never uploaded.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .task {
      calendarGranted = await model.hasCalendarAccess
      if calendarGranted { await model.refreshUpcomingEvents() }
    }
  }
}

/// Integrations — the local MCP server, and the shortcuts other tools can use.
struct IntegrationsSettings: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var preferences: Preferences

  var body: some View {
    Form {
      Section("Local MCP server") {
        Toggle(
          "Let local MCP clients read my Rant data",
          isOn: Binding(
            get: { preferences.mcpSettings.enabled },
            set: { on in
              var settings = preferences.mcpSettings
              settings.enabled = on
              preferences.mcpSettings = settings
              model.applyMCPSettings()
            }))
          .accessibilityIdentifier("settings.mcpEnabled")

        if preferences.mcpSettings.enabled {
          LabeledContent("Address") {
            Text("\(preferences.mcpSettings.host):\(model.mcpController?.boundPort ?? preferences.mcpSettings.port)")
              .monospaced()
          }
          LabeledContent("Status") {
            Text(model.mcpController?.isRunning == true ? "Listening" : "Not running")
              .foregroundStyle(
                model.mcpController?.isRunning == true ? Theme.moss : Theme.clay)
          }
          if let error = model.mcpController?.lastError {
            Text(error).font(.caption).foregroundStyle(Theme.live)
          }

          // Empty is a working configuration: the server answers tools/list and
          // refuses every tool. Exposure is opt-in per collection.
          ForEach(MCPCollection.selectable, id: \.self) { collection in
            Toggle(
              collection.displayName,
              isOn: Binding(
                get: { preferences.mcpSettings.collections.contains(collection) },
                set: { on in
                  var settings = preferences.mcpSettings
                  if on {
                    settings.collections.insert(collection)
                  } else {
                    settings.collections.remove(collection)
                  }
                  preferences.mcpSettings = settings
                  model.applyMCPSettings()
                }))
          }

          Toggle(
            "Allow tools that start and stop dictation",
            isOn: Binding(
              get: { preferences.mcpSettings.allowWrite },
              set: { on in
                var settings = preferences.mcpSettings
                settings.allowWrite = on
                preferences.mcpSettings = settings
                model.applyMCPSettings()
              }))
        }

        Text("Off by default. The server binds to loopback only — a non-loopback address is refused before a socket is created — and it never exposes your API keys. Every request is written to a local audit log.")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("Keyboard") {
        LabeledContent(
          "Transform selection",
          value: CarbonHotkey.Combination.optionShiftT.displayName)
        LabeledContent(
          "Command mode",
          value: CarbonHotkey.Combination.optionShiftC.displayName)
        LabeledContent("Dictate without Accessibility", value: model.fallbackShortcut ?? "—")
        Text("Command mode is a separate key on purpose: “make this shorter” has to be an instruction, not six words typed into your document.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

/// Advanced — developer mode, logs, and the reset switches.
struct AdvancedSettings: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var preferences: Preferences
  @State private var confirmingReset = false

  var body: some View {
    Form {
      Section("Developer") {
        Toggle("Developer mode", isOn: $preferences.developerMode)
        Text("Keeps technical casing — userId, ContentView.swift, async throws — instead of prose-formatting them.")
          .font(.caption).foregroundStyle(.secondary)

        Toggle("Learn from my corrections", isOn: $preferences.learnFromCorrections)
          .onChange(of: preferences.learnFromCorrections) { _, on in
            model.makeLearningIfNeeded()?.update(enabled: on)
          }
        Text("After Rant inserts text, it briefly watches the same field for edits and proposes a dictionary rule. Only the text Rant inserted and the part you changed are compared — never the rest of the document — and nothing is saved without you accepting it.")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("Logs") {
        LabeledContent("Log file", value: RantLog.fileURL?.path ?? "Not writing to disk")
        HStack {
          Button("Show in Finder") {
            guard let url = RantLog.fileURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
          }
          .buttonStyle(.quiet)
          .disabled(RantLog.fileURL == nil)
          Spacer()
        }
        Text("Transcripts and context are never written to the log at any level. It records what happened, not what you said.")
          .font(.caption).foregroundStyle(.secondary)
      }

      Section("Reset") {
        Button("Run onboarding again") { preferences.hasCompletedOnboarding = false }
          .buttonStyle(.quiet)
        Button("Reset every setting…", role: .destructive) { confirmingReset = true }
          .buttonStyle(.quiet)
        Text("Resetting settings does not delete your transcripts. Use Privacy → Clear local data for that.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .confirmationDialog(
      "Reset every setting?", isPresented: $confirmingReset, titleVisibility: .visible
    ) {
      Button("Reset", role: .destructive) { preferences.resetAll() }
      Button("Keep them", role: .cancel) {}
    } message: {
      Text("Your dictation key, engine choice, styles and privacy switches go back to their defaults. Your transcripts, dictionary and snippets are untouched.")
    }
  }
}

struct DiagnosticsSettings: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var permissions: Permissions

  var body: some View {
    Form {
      Section("Permissions") {
        row("Microphone", granted: permissions.microphone.isGranted, pane: .microphone)
        row("Accessibility", granted: permissions.accessibility.isGranted, pane: .accessibility)
        row("Screen Recording", granted: permissions.screenRecording.isGranted, pane: .screenRecording)
      }
      Section("State") {
        LabeledContent("Speech provider", value: model.preferences.speechProvider)
        LabeledContent("API key stored", value: model.hasAPIKey ? "Yes" : "No")
        LabeledContent("Network mode", value: model.preferences.localOnly ? "Local only" : "Provider allowed")
        LabeledContent("Database size", value: ByteCountFormatter.string(
          fromByteCount: Int64(model.databaseSizeBytes), countStyle: .file))
        LabeledContent("Transcripts stored", value: model.recentTranscripts.count.formatted())
        LabeledContent("Schema version", value: "\(Migrations.latestVersion)")
      }
      Section("Keyboard") {
        LabeledContent("Event tap", value: model.hotkeyProblem == nil ? "Installed" : "Not installed")
        if let problem = model.hotkeyProblem {
          Text(problem).font(.caption).foregroundStyle(Theme.live)
        }
        Button("Reinstall keyboard listener") { model.installHotkeys() }
      }
    }
    .formStyle(.grouped)
    .onAppear { permissions.refresh() }
  }

  private func row(_ title: String, granted: Bool, pane: Permissions.Pane) -> some View {
    HStack {
      Label(title, systemImage: granted ? "checkmark.circle.fill" : "xmark.circle")
        .foregroundStyle(granted ? Theme.moss : .secondary)
      Spacer()
      if !granted {
        Button("Open Settings") { permissions.open(pane) }.buttonStyle(.link)
      }
    }
  }
}
