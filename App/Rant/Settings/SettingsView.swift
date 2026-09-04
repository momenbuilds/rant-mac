import RantCore
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var preferences: Preferences
  @EnvironmentObject private var permissions: Permissions

  var body: some View {
    TabView {
      GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
      SpeechSettings().tabItem { Label("Speech", systemImage: "waveform") }
      IntelligenceSettings().tabItem { Label("Intelligence", systemImage: "wand.and.stars") }
      PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }
      DiagnosticsSettings().tabItem { Label("Diagnostics", systemImage: "stethoscope") }
    }
    .navigationTitle("Settings")
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
      Section("Speech engine") {
        Picker("Engine", selection: $preferences.speechProvider) {
          Text("AssemblyAI — your own key").tag("assemblyai")
        }
        HStack {
          PrivacyBadge(level: preferences.localOnly ? .onDevice : .network)
          Spacer()
        }
      }

      Section("AssemblyAI key") {
        // The key is write-only in the UI: once stored it is never displayed again,
        // because a key visible on screen is a key in a screenshot.
        if model.hasAPIKey {
          Label("A key is stored in your Keychain", systemImage: "key.fill")
            .foregroundStyle(Theme.success)
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
          Text(message).font(.caption).foregroundStyle(Theme.recording)
        }
        if let testResult {
          Text(testResult).font(.caption).foregroundStyle(.secondary)
        }
        Text("Your key is stored only in the macOS Keychain. It is never written to preferences, logs or any file, and it is never sent anywhere except AssemblyAI.")
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
          Text(problem).font(.caption).foregroundStyle(Theme.recording)
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
        .foregroundStyle(granted ? Theme.success : .secondary)
      Spacer()
      if !granted {
        Button("Open Settings") { permissions.open(pane) }.buttonStyle(.link)
      }
    }
  }
}
