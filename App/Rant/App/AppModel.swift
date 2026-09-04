import AppKit
import Combine
import RantCore
import SwiftUI

/// The one object that owns the running system: the event tap, the dictation
/// session, the database, and the state the UI observes.
///
/// It is a coordinator, not a place for logic. Anything here that is worth a test
/// belongs in `RantCore` instead — and almost all of it already does.
@MainActor
final class AppModel: ObservableObject {
  let preferences: Preferences
  let permissions: Permissions
  let secrets: any SecretStoring

  @Published private(set) var state: DictationState = .idle
  @Published private(set) var meterHistory: [Float] = []
  @Published private(set) var partialText: String = ""
  @Published private(set) var recentTranscripts: [Transcript] = []
  @Published private(set) var lastError: String?
  @Published private(set) var engineReady = false
  /// Set when the hotkey could not be installed, so the UI can explain rather than
  /// leaving the user pressing a key that does nothing.
  @Published private(set) var hotkeyProblem: String?
  /// What the *engine* is actually listening for, as opposed to what the settings
  /// screen says. When these disagree, the key does nothing and nothing explains why.
  @Published private(set) var listeningFor: TriggerKey?

  private var database: Database?
  private(set) var store: SQLiteTranscriptStore?
  private(set) var vocabulary: VocabularyStore?
  private(set) var notes: NoteStore?
  private(set) var meetings: MeetingStore?
  private var session: DictationSession?
  private var hotkeys: HotkeyEngine?
  private let microphone = MicrophoneCapture()
  private let log = RantLog("App")
  private var meterTimer: Timer?
  private var cancellables: Set<AnyCancellable> = []

  /// Presenting the overlay is a window operation, so it is owned by the controller
  /// rather than by a SwiftUI scene — a floating recorder must not steal focus, and
  /// a normal window always would.
  let overlay = OverlayController()

  init(
    preferences: Preferences = Preferences(),
    permissions: Permissions = Permissions(),
    secrets: (any SecretStoring)? = nil
  ) {
    self.preferences = preferences
    self.permissions = permissions
    // A UI test must never touch the real Keychain. Reading it pops a system password
    // dialog, which blocks the app's own window from appearing — so the test finds no
    // window and fails for a reason that has nothing to do with what it was testing.
    self.secrets =
      secrets ?? CachingSecretStore(Self.isUITesting ? InMemorySecretStore() : KeychainSecretStore())
  }

  // MARK: - Lifecycle

  func start() {
    openDatabase()
    buildSession()
    installHotkeys()
    refreshHistory()
    startMeterUpdates()

    // The event tap cannot be installed without Accessibility, and Accessibility is
    // granted in another process with no notification. Watching for it means the
    // moment the user comes back from System Settings, the tap installs itself — no
    // relaunch, no "why is it still complaining".
    permissions.onGranted = { [weak self] _, _, _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.log.info("accessibility granted; installing the event tap")
        self.installHotkeys()
      }
    }
    permissions.startWatching()
    watchPreferences()

    // Register with macOS so Rant appears in the Accessibility list.
    //
    // An app that has never asked is not in that list at all, so a user who goes
    // looking finds nothing to switch on and has to know about the "+" button and
    // where the bundle lives. Asking once puts the row there — unchecked — which
    // turns the whole problem into one toggle. macOS shows its own dialog, which is
    // the honest place for that request to come from.
    if !permissions.accessibility.isGranted, preferences.hasCompletedOnboarding {
      permissions.requestAccessibility()
    }

    if Self.isDemoingOverlay { startOverlayDemo() }
    if let directory = Self.gifRenderDirectory { renderOverlayFrames(into: directory) }
  }

  /// Reinstalls the event tap whenever the trigger or activation mode changes.
  ///
  /// This used to be the responsibility of whichever view offered the control, and
  /// onboarding forgot: you picked Fn on the setup screen, the label updated, and the
  /// engine carried on listening for Right ⌘ — so the key you had just chosen did
  /// nothing, with the UI insisting it should. Watching the value rather than trusting
  /// every call site is the difference between a setting and a suggestion.
  private func watchPreferences() {
    preferences.$triggerKey
      .combineLatest(preferences.$activationMode)
      .dropFirst()
      .removeDuplicates { $0 == $1 }
      .receive(on: RunLoop.main)
      .sink { [weak self] trigger, mode in
        guard let self else { return }
        self.log.info("trigger is now \(trigger.rawValue) (\(mode.rawValue)); reinstalling")
        self.installHotkeys()
      }
      .store(in: &cancellables)
  }

  /// Drives the overlay through its states on a loop, with a plausible meter.
  ///
  /// It exists so the recorder can be recorded: capturing the real thing needs a
  /// microphone, an API key, granted permissions and good timing, and a demo that
  /// only works on one machine is a demo that rots. This drives the same views with
  /// the same animations — only the source of the numbers differs.
  static var isDemoingOverlay: Bool {
    UserDefaults.standard.bool(forKey: "rant-demo-overlay")
  }

  /// Where to write rendered frames of the recorder, if asked.
  static var gifRenderDirectory: String? {
    UserDefaults.standard.string(forKey: "rant-render-overlay")
  }

  /// Renders the recorder to PNG frames and exits.
  ///
  /// Screen-recording the real overlay meant recording whatever else was on the
  /// display, which is both a privacy problem and a reproducibility one — the result
  /// depended on the wallpaper and on nobody touching the machine for fifteen
  /// seconds. `ImageRenderer` draws the *same view* off-screen, so the artefact still
  /// shows exactly what ships, and the frames are identical on every run.
  private func renderOverlayFrames(into directory: String) {
    Task { @MainActor in
      try? FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true)

      let controller = OverlayController()
      var frame = 0

      @MainActor func write(_ state: DictationState, meter: [Float]) {
        controller.state = state
        controller.meter = meter
        let renderer = ImageRenderer(
          content: RecorderOverlay(controller: controller)
            .padding(14)
            .background(Theme.paper))
        renderer.scale = 2
        guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        let name = String(format: "%03d.png", frame)
        try? png.write(to: URL(fileURLWithPath: "\(directory)/\(name)"))
        frame += 1
      }

      // A speech-shaped meter: a phrase-length swell, a syllable beat and a little
      // jitter. A single sine reads as a test tone; noise reads as a broken meter.
      @Sendable func meter(at tick: Int) -> [Float] {
        (0..<40).map { index in
          let time = Double(tick - (40 - index)) / 11
          let phrase = 0.45 + 0.35 * sin(time * 0.55)
          let syllables = 0.35 + 0.65 * abs(sin(time * 4.3))
          let jitter = 0.8 + 0.2 * sin(time * 11.7)
          return Float(max(0.004, phrase * syllables * jitter * 0.13))
        }
      }

      for tick in 0..<10 { _ = tick; write(.idle, meter: []) }
      for tick in 0..<58 { write(.listening, meter: meter(at: tick)) }
      for _ in 0..<12 { write(.transcribing, meter: []) }
      for _ in 0..<6 { write(.inserting, meter: []) }
      for _ in 0..<26 {
        write(.success("So the migration lands Wednesday, and I will write the notes up after."), meter: [])
      }

      print("wrote \(frame) frames to \(directory)")
      NSApp.terminate(nil)
    }
  }

  private func startOverlayDemo() {
    Task { @MainActor in
      let phrase = "So the migration lands Wednesday, and I will write the notes up after."
      while !Task.isCancelled {
        overlay.show(state: .idle)
        try? await Task.sleep(for: .milliseconds(900))

        overlay.show(state: .listening)
        // A meter that looks like speech: a slow envelope with syllable-rate detail,
        // rather than noise, which reads as a broken meter.
        for tick in 0..<80 {
          let time = Double(tick) / 11
          // Three incommensurable rates stacked: a phrase-length swell, a
          // syllable-rate beat, and a little jitter. Speech looks like this; a single
          // sine looks like a test tone, and pure noise looks like a broken meter.
          let phrase = 0.45 + 0.35 * sin(time * 0.55)
          let syllables = 0.35 + 0.65 * abs(sin(time * 4.3))
          let jitter = 0.8 + 0.2 * sin(time * 11.7)
          let level = Float(max(0.004, phrase * syllables * jitter * 0.13))
          var history = overlay.meter
          history.append(level)
          if history.count > 40 { history.removeFirst(history.count - 40) }
          overlay.updateMeter(history)
          try? await Task.sleep(for: .milliseconds(45))
        }

        overlay.show(state: .transcribing)
        try? await Task.sleep(for: .milliseconds(700))
        overlay.show(state: .inserting)
        try? await Task.sleep(for: .milliseconds(320))
        overlay.show(state: .success(phrase))
        try? await Task.sleep(for: .milliseconds(1_700))
      }
    }
  }

  /// True when XCUITest launched us. A UI test must never read or write the
  /// developer's real dictation history, so this switches the database to memory and
  /// starts from first-run state.
  static var isUITesting: Bool {
    UserDefaults.standard.bool(forKey: "rant-ui-testing")
  }

  private func openDatabase() {
    do {
      let url: URL? = Self.isUITesting
        ? nil
        : Self.supportDirectory().appendingPathComponent("rant.sqlite")
      let database = try Database(url: url)
      try Migrations.migrate(database)
      self.database = database
      self.store = SQLiteTranscriptStore(database: database)
      self.vocabulary = VocabularyStore(database: database)
      self.notes = NoteStore(database: database)
      self.meetings = MeetingStore(database: database)
      log.info("database ready at schema \(database.userVersion)")
    } catch {
      log.error("could not open the database: \(error.localizedDescription)")
      lastError = "Rant could not open its database. \(error.localizedDescription)"
    }
  }

  static func supportDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let directory = base.appendingPathComponent("Rant", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// Rebuilds the pipeline. Called at launch and whenever a setting that changes the
  /// shape of it — the provider, the key — is edited, so a change applies to the very
  /// next dictation rather than the next launch.
  func buildSession() {
    let provider = makeTranscriptionProvider()
    // The context provider is called from the dictation actor, so it cannot reach
    // back into the main actor to read history. A snapshot taken now is both correct
    // and cheap: continuity only needs the last few utterances, and they are already
    // in hand.
    let continuity = recentTranscripts.prefix(3).map(\.finalText).reversed()
    let recent = Array(continuity)
    // The dictionary's key terms bias the recogniser toward the spellings the user
    // has already told us they want, which is far cheaper than correcting them
    // afterwards.
    let terms = (try? vocabulary?.keyTerms()) ?? []
    let context = AccessibilityContextProvider(
      recentDictations: { recent },
      keyTerms: { terms })

    session = DictationSession(
      audio: microphone,
      transcriber: provider,
      injector: AccessibilityInjector(),
      context: context,
      store: store,
      enhancer: makeEnhancementProvider(),
      vocabulary: (try? vocabulary?.makeApplier()) ?? VocabularyApplier())

    let newSession = session
    let relay = StateRelay(model: self)
    Task {
      await newSession?.observeState { state in relay.send(state) }
    }
    engineReady = true
  }

  private func makeTranscriptionProvider() -> any TranscriptionProvider {
    // Only one cloud provider exists today. The switch is here rather than inline so
    // adding the local provider is a one-line change in a place that already reads
    // like a list of choices.
    switch preferences.speechProvider {
    default:
      return AssemblyAIProvider(secrets: secrets)
    }
  }

  private func makeEnhancementProvider() -> any EnhancementProvider {
    switch preferences.enhancementProvider {
    case "ollama":
      return OllamaEnhancer(
        endpoint: URL(string: preferences.ollamaEndpoint) ?? URL(string: "http://localhost:11434")!,
        model: preferences.ollamaModel)
    default:
      return NoEnhancement()
    }
  }

  fileprivate func apply(_ state: DictationState) {
    self.state = state
    switch state {
    case .listening:
      overlay.show(state: state)
    case .idle:
      overlay.hide(unless: preferences.overlayAlwaysVisible)
    case .failure(let message, _):
      lastError = message
      overlay.show(state: state)
    case .success:
      refreshHistory()
      overlay.show(state: state)
    default:
      overlay.show(state: state)
    }
  }

  // MARK: - Hotkeys

  func installHotkeys() {
    hotkeys?.stop()
    let engine = HotkeyEngine(configuration: preferences.hotkeyConfiguration) { [weak self] command in
      Task { @MainActor [weak self] in self?.handle(command) }
    }
    if engine.start() {
      hotkeys = engine
      hotkeyProblem = nil
      listeningFor = preferences.triggerKey
      log.info("event tap installed, listening for \(preferences.triggerKey.rawValue)")
    } else {
      listeningFor = nil
      hotkeys = nil
      log.error("event tap NOT installed (trusted: \(AXIsProcessTrusted()))")
      hotkeyProblem = permissions.accessibility.isGranted
        ? "Rant could not install its keyboard listener. Try quitting and reopening Rant."
        : "Rant needs Accessibility permission before your dictation key can work anywhere."
    }
  }

  private func handle(_ command: HotkeyEngine.Command) {
    log.info("command \(String(describing: command))")
    guard let session else {
      log.error("no dictation session; the pipeline was never built")
      return
    }
    let settings = preferences.dictationSettings
    switch command {
    case .startRecording:
      // Stamped here, at the moment the key press became a decision, so the number
      // the overlay logs is the one the user actually experiences.
      overlay.commandArrivedAt = ContinuousClock.now
      Task { await session.start(settings: settings) }
    case .promoteToHandsFree:
      // The audio already running simply keeps running; only the way it ends changes.
      break
    case .stopAndTranscribe:
      Task {
        _ = await session.stopAndTranscribe(settings: settings)
        self.hotkeys?.sessionEnded()
      }
    case .cancel:
      Task {
        await session.cancel()
        self.hotkeys?.sessionEnded()
      }
    }
  }

  // MARK: - Commands the UI can issue

  func toggleDictation() {
    guard let hotkeys else { return }
    if hotkeys.isRecording {
      hotkeys.requestStop()
    } else {
      Task { await session?.start(settings: preferences.dictationSettings) }
    }
  }

  func stopDictation() { hotkeys?.requestStop() }
  func cancelDictation() { hotkeys?.requestCancel() }

  func pasteLast() {
    Task { _ = await session?.pasteLast() }
  }

  func retryLast() {
    Task { _ = await session?.retryLast(settings: preferences.dictationSettings) }
  }

  /// Rebuilds the pipeline so a dictionary or snippet edit applies to the very next
  /// dictation rather than the next launch.
  func rebuildVocabulary() {
    buildSession()
  }

  // MARK: - Notetaker

  /// Starts a meeting recording.
  ///
  /// Screen Recording is what macOS requires for system audio, so without it the
  /// notetaker records only your side of the call. That is a real limitation and the
  /// UI says so rather than failing — a one-sided transcript is still worth having.
  func startMeeting() {
    if !permissions.screenRecording.isGranted {
      permissions.requestScreenRecording()
    }
    lastError = permissions.screenRecording.isGranted
      ? nil
      : "Rant will record only your side of this call until Screen Recording is granted."
  }

  // MARK: - Import and export

  /// Writes a value out as pretty JSON through a save panel. Plain JSON, because a
  /// personal dictionary you cannot take with you is a personal dictionary you have
  /// rented.
  func exportJSON<T: Encodable>(_ value: T, suggestedName: String) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = suggestedName
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(value).write(to: url)
    } catch {
      lastError = "Could not export: \(error.localizedDescription)"
    }
  }

  /// Writes a Rant Archive — the portable copy of everything, in the same format the
  /// Migration Center reads back. Leaving Rant is a supported operation, so it gets a
  /// menu item rather than a documentation page.
  func exportArchive() {
    guard let database else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Rant Archive \(Date().formatted(.iso8601.year().month().day())).zip"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let manifest = try RantArchive(database: database).exportZip(to: url)
      lastError = nil
      log.info("exported archive with \(manifest.counts.transcripts) transcripts")
    } catch {
      lastError = "Could not export: \(error.localizedDescription)"
    }
  }

  func importJSON<T: Decodable>(_ type: T.Type, completion: (T) -> Void) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      completion(try decoder.decode(type, from: Data(contentsOf: url)))
    } catch {
      lastError = "Could not read that file: \(error.localizedDescription)"
    }
  }

  // MARK: - History

  func refreshHistory() {
    guard let store else { return }
    recentTranscripts = (try? store.recent(limit: 100, offset: 0)) ?? []
  }

  func search(_ query: String) -> [TranscriptSearchResult] {
    guard let store, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
    return (try? store.search(query, limit: 100)) ?? []
  }

  func delete(_ transcript: Transcript) {
    guard let store, let id = transcript.id else { return }
    try? store.delete(id: id)
    refreshHistory()
  }

  func deleteAllHistory() {
    try? store?.deleteAll()
    refreshHistory()
  }

  func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  // MARK: - Meter

  /// Polls the capture actor for the waveform. A timer rather than a callback because
  /// the display only needs ~30 Hz and pushing every audio buffer to the main actor
  /// would be far more traffic than the picture is worth.
  private func startMeterUpdates() {
    meterTimer?.invalidate()
    meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.state.isBusy else { return }
        let history = await self.microphone.meterHistory
        self.meterHistory = history
        self.overlay.updateMeter(history)
      }
    }
  }

  // MARK: - Diagnostics

  /// Exposed so the screens that own their own engine — Insights, Migrate — can
  /// build one against the same connection rather than opening a second.
  var databaseHandle: Database? { database }

  var databaseSizeBytes: Int { database?.pageCountBytes ?? 0 }

  /// Writes plain text out through a save panel.
  func exportText(_ text: String, suggestedName: String) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = suggestedName
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try? Data(text.utf8).write(to: url)
  }

  /// Whether a key is stored, cached after the first look.
  ///
  /// This is read by the sidebar footer, which redraws constantly — and every read of
  /// the file keychain can raise a system password prompt. Asking once and remembering
  /// the answer is the difference between one prompt and one per redraw.
  private var cachedHasAPIKey: Bool?

  var hasAPIKey: Bool {
    if let cachedHasAPIKey { return cachedHasAPIKey }
    let present = ((try? secrets.read(.assemblyAI)) ?? nil)?.isEmpty == false
    cachedHasAPIKey = present
    return present
  }

  func saveAPIKey(_ key: String) throws {
    try secrets.write(key, for: .assemblyAI)
    cachedHasAPIKey = nil
    objectWillChange.send()
    buildSession()
  }

  func testConnection() async -> Result<Void, Error> {
    do {
      try await AssemblyAIProvider(secrets: secrets).checkReachability()
      return .success(())
    } catch {
      return .failure(error)
    }
  }
}

/// Carries state changes from the dictation actor back to the main actor.
///
/// The session's observer is a `@Sendable` closure, so it cannot capture a
/// main-actor-isolated model directly. A small relay holding a weak reference keeps
/// the hop explicit and keeps the model from being retained by the session it owns —
/// which would otherwise be a cycle.
private final class StateRelay: @unchecked Sendable {
  private weak var model: AppModel?
  init(model: AppModel) { self.model = model }

  func send(_ state: DictationState) {
    Task { @MainActor in self.model?.apply(state) }
  }
}
