import Foundation
import RantCore
import SwiftUI

/// Everything the user can change that is not a secret.
///
/// Secrets never appear here — they live in the Keychain, reached through
/// `SecretStoring`. This type is deliberately plain `UserDefaults`-backed, because
/// its contents are exactly the sort of thing that should be readable, exportable and
/// resettable by the person who owns the machine.
@MainActor
final class Preferences: ObservableObject {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // A UI test starts from first-run state unless it explicitly asked to keep what
    // the previous launch stored — which is how the "settings persist" test works.
    if defaults.bool(forKey: "rant-ui-testing"),
      !defaults.bool(forKey: "rant-ui-testing-keep-preferences")
    {
      for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("rant.") {
        defaults.removeObject(forKey: key)
      }
    }
    // The design tour wants the main window, not onboarding. Walking a screenshot
    // harness through seven steps to reach the screens it came to photograph is
    // fragile for no benefit — onboarding has its own test.
    if defaults.bool(forKey: "rant-ui-skip-onboarding") {
      defaults.set(true, forKey: Key.hasCompletedOnboarding)
    }
    self.hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
    self.triggerKey = TriggerKey(rawValue: defaults.string(forKey: Key.triggerKey) ?? "") ?? .rightCommand
    self.activationMode = ActivationMode(rawValue: defaults.string(forKey: Key.activationMode) ?? "") ?? .hybrid
    self.cleanupLevel = CleanupLevel(rawValue: defaults.string(forKey: Key.cleanupLevel) ?? "") ?? .medium
    self.speechProvider = defaults.string(forKey: Key.speechProvider) ?? "assemblyai"
    self.localOnly = defaults.bool(forKey: Key.localOnly)
    self.preferLocalCleanup = defaults.bool(forKey: Key.preferLocalCleanup)
    self.retainAudio = defaults.bool(forKey: Key.retainAudio)
    self.audioRetentionDays = defaults.object(forKey: Key.audioRetentionDays) as? Int ?? 0
    self.microphoneUniqueID = defaults.string(forKey: Key.microphoneUniqueID)
    self.languageCode = defaults.string(forKey: Key.languageCode)
    self.playSounds = defaults.object(forKey: Key.playSounds) as? Bool ?? true
    self.overlayAlwaysVisible = defaults.bool(forKey: Key.overlayAlwaysVisible)
    self.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
    self.contextEnabled = defaults.object(forKey: Key.contextEnabled) as? Bool ?? true
    self.contextAllowCloud = defaults.object(forKey: Key.contextAllowCloud) as? Bool ?? true
    self.contextUseClipboard = defaults.bool(forKey: Key.contextUseClipboard)
    self.contextUseScreenOCR = defaults.bool(forKey: Key.contextUseScreenOCR)
    self.excludedBundleIDs = Set(
      defaults.stringArray(forKey: Key.excludedBundleIDs) ?? Array(ContextSettings.defaultExclusions))
    self.enhancementProvider = defaults.string(forKey: Key.enhancementProvider) ?? "none"
    self.ollamaEndpoint = defaults.string(forKey: Key.ollamaEndpoint) ?? "http://localhost:11434"
    self.ollamaModel = defaults.string(forKey: Key.ollamaModel) ?? "llama3.2"
    self.developerMode = defaults.bool(forKey: Key.developerMode)
    self.mcpEnabled = defaults.bool(forKey: Key.mcpEnabled)
    self.learnFromCorrections = defaults.bool(forKey: Key.learnFromCorrections)
    self.livePreview = defaults.object(forKey: Key.livePreview) as? Bool ?? true
  }

  private enum Key {
    static let hasCompletedOnboarding = "rant.onboarding.complete"
    static let triggerKey = "rant.hotkey.trigger"
    static let activationMode = "rant.hotkey.mode"
    static let cleanupLevel = "rant.text.cleanup"
    static let speechProvider = "rant.speech.provider"
    static let localOnly = "rant.privacy.localOnly"
    static let preferLocalCleanup = "rant.text.localCleanup"
    static let retainAudio = "rant.privacy.retainAudio"
    static let audioRetentionDays = "rant.privacy.audioRetentionDays"
    static let microphoneUniqueID = "rant.audio.device"
    static let languageCode = "rant.speech.language"
    static let playSounds = "rant.general.sounds"
    static let overlayAlwaysVisible = "rant.overlay.alwaysVisible"
    static let launchAtLogin = "rant.general.launchAtLogin"
    static let contextEnabled = "rant.context.enabled"
    static let contextAllowCloud = "rant.context.allowCloud"
    static let contextUseClipboard = "rant.context.clipboard"
    static let contextUseScreenOCR = "rant.context.ocr"
    static let excludedBundleIDs = "rant.context.excluded"
    static let livePreview = "rant.speech.livePreview"
    static let modeResolver = "rant.modes.resolver"
    static let mcpSettings = "rant.mcp.settings"
    static let learnFromCorrections = "rant.learning.enabled"
    static let styleResolver = "rant.styles.resolver"
    static let customStyles = "rant.styles.custom"
    static let enhancementProvider = "rant.enhance.provider"
    static let ollamaEndpoint = "rant.enhance.ollamaEndpoint"
    static let ollamaModel = "rant.enhance.ollamaModel"
    static let developerMode = "rant.advanced.developerMode"
    static let mcpEnabled = "rant.integrations.mcp"
  }

  @Published var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) } }
  @Published var triggerKey: TriggerKey { didSet { defaults.set(triggerKey.rawValue, forKey: Key.triggerKey) } }
  @Published var activationMode: ActivationMode { didSet { defaults.set(activationMode.rawValue, forKey: Key.activationMode) } }
  @Published var cleanupLevel: CleanupLevel { didSet { defaults.set(cleanupLevel.rawValue, forKey: Key.cleanupLevel) } }
  @Published var speechProvider: String { didSet { defaults.set(speechProvider, forKey: Key.speechProvider) } }
  @Published var localOnly: Bool { didSet { defaults.set(localOnly, forKey: Key.localOnly) } }
  @Published var preferLocalCleanup: Bool { didSet { defaults.set(preferLocalCleanup, forKey: Key.preferLocalCleanup) } }
  @Published var retainAudio: Bool { didSet { defaults.set(retainAudio, forKey: Key.retainAudio) } }
  @Published var audioRetentionDays: Int { didSet { defaults.set(audioRetentionDays, forKey: Key.audioRetentionDays) } }

  /// The two audio preferences as the one policy the engine sweeps against.
  ///
  /// The toggle and the day count were stored and displayed but never translated into
  /// an `AudioRetentionPolicy`, and nothing ever ran a sweep — so "keep it for 24
  /// hours" kept it forever. Deriving the policy here means the setting and the
  /// deletion can no longer disagree.
  var audioRetentionPolicy: AudioRetentionPolicy {
    guard retainAudio else { return .never }
    switch audioRetentionDays {
    case 1: return .oneDay
    case 7: return .sevenDays
    case 30: return .thirtyDays
    default: return .forever
    }
  }
  @Published var microphoneUniqueID: String? { didSet { defaults.set(microphoneUniqueID, forKey: Key.microphoneUniqueID) } }
  @Published var languageCode: String? { didSet { defaults.set(languageCode, forKey: Key.languageCode) } }
  @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Key.playSounds) } }
  @Published var overlayAlwaysVisible: Bool { didSet { defaults.set(overlayAlwaysVisible, forKey: Key.overlayAlwaysVisible) } }
  @Published var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) } }
  @Published var contextEnabled: Bool { didSet { defaults.set(contextEnabled, forKey: Key.contextEnabled) } }
  @Published var contextAllowCloud: Bool { didSet { defaults.set(contextAllowCloud, forKey: Key.contextAllowCloud) } }
  @Published var contextUseClipboard: Bool { didSet { defaults.set(contextUseClipboard, forKey: Key.contextUseClipboard) } }
  @Published var contextUseScreenOCR: Bool { didSet { defaults.set(contextUseScreenOCR, forKey: Key.contextUseScreenOCR) } }
  @Published var excludedBundleIDs: Set<String> { didSet { defaults.set(Array(excludedBundleIDs), forKey: Key.excludedBundleIDs) } }
  @Published var enhancementProvider: String { didSet { defaults.set(enhancementProvider, forKey: Key.enhancementProvider) } }
  @Published var ollamaEndpoint: String { didSet { defaults.set(ollamaEndpoint, forKey: Key.ollamaEndpoint) } }
  @Published var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: Key.ollamaModel) } }
  @Published var developerMode: Bool { didSet { defaults.set(developerMode, forKey: Key.developerMode) } }
  @Published var mcpEnabled: Bool { didSet { defaults.set(mcpEnabled, forKey: Key.mcpEnabled) } }

  /// The context configuration the engine should use, assembled from the individual
  /// switches. One place, so "what is Rant allowed to look at" has one answer.
  var contextSettings: ContextSettings {
    ContextSettings(
      enabled: contextEnabled,
      useClipboard: contextUseClipboard,
      useScreenOCR: contextUseScreenOCR,
      allowSendingToCloud: contextAllowCloud && !localOnly,
      excludedBundleIDs: excludedBundleIDs)
  }

  var dictationSettings: DictationSettings {
    DictationSettings(
      cleanupLevel: cleanupLevel,
      languageCode: languageCode,
      preferLocalCleanup: preferLocalCleanup,
      localOnly: localOnly,
      contextSettings: contextSettings,
      retainAudio: retainAudio,
      styleResolver: styleResolver,
      modeResolver: modeResolver)
  }

  /// Which mode applies where.
  ///
  /// Like the style resolver, this had no home: `ModeResolver` was implemented and
  /// tested and nothing built one, so the Modes screen described a pipeline nothing
  /// consulted.
  var modeResolver: ModeResolver {
    get {
      guard let data = defaults.data(forKey: Key.modeResolver),
        var stored = try? JSONDecoder().decode(ModeResolver.self, from: data)
      else { return ModeResolver() }
      stored.sessionOverride = nil
      return stored
    }
    set {
      guard let data = try? JSONEncoder().encode(newValue) else { return }
      defaults.set(data, forKey: Key.modeResolver)
      objectWillChange.send()
    }
  }

  /// How a writing style is chosen, persisted as JSON.
  ///
  /// The Styles screen was a browsable list of instructions that nothing consulted:
  /// `dictationSettings` never set a style, so `styleInstruction` was always nil and
  /// every dictation used the provider's default voice regardless of what the screen
  /// showed. Storing the resolver — with the per-app, per-site and per-category rules
  /// — is what makes the screen describe something real.
  var styleResolver: StyleResolver {
    get {
      guard let data = defaults.data(forKey: Key.styleResolver),
        var stored = try? JSONDecoder().decode(StyleResolver.self, from: data)
      else { return StyleResolver(available: allStyles) }
      // The built-ins can change between releases; the user's rules are what persist.
      stored.available = allStyles
      // A session override is by definition for one dictation, so it never survives
      // a relaunch even if one was somehow written.
      stored.sessionOverride = nil
      return stored
    }
    set {
      var toStore = newValue
      toStore.available = customStyles
      guard let data = try? JSONEncoder().encode(toStore) else { return }
      defaults.set(data, forKey: Key.styleResolver)
      objectWillChange.send()
    }
  }

  /// Styles the user wrote, on top of the built-ins.
  var customStyles: [WritingStyle] {
    get {
      guard let data = defaults.data(forKey: Key.customStyles),
        let styles = try? JSONDecoder().decode([WritingStyle].self, from: data)
      else { return [] }
      return styles
    }
    set {
      guard let data = try? JSONEncoder().encode(newValue) else { return }
      defaults.set(data, forKey: Key.customStyles)
      objectWillChange.send()
    }
  }

  var allStyles: [WritingStyle] { WritingStyle.builtIns + customStyles }

  /// The local MCP server's configuration.
  ///
  /// `mcpEnabled` existed as a lone boolean that nothing read. The server needs rather
  /// more than a boolean — which collections are exposed, whether write tools are
  /// allowed, where it binds — and all of it has to persist, so it is stored whole.
  var mcpSettings: MCPSettings {
    get {
      guard let data = defaults.data(forKey: Key.mcpSettings),
        let stored = try? JSONDecoder().decode(MCPSettings.self, from: data)
      else { return MCPSettings(enabled: mcpEnabled) }
      return stored
    }
    set {
      guard let data = try? JSONEncoder().encode(newValue) else { return }
      defaults.set(data, forKey: Key.mcpSettings)
      // Kept in step so the old key stays truthful for anything still reading it.
      if mcpEnabled != newValue.enabled { mcpEnabled = newValue.enabled }
      objectWillChange.send()
    }
  }

  /// Opt-in learning from corrections. Off unless the user says otherwise — the
  /// feature watches what you type after Rant inserts text, and that is not something
  /// to switch on for somebody.
  @Published var learnFromCorrections: Bool {
    didSet { defaults.set(learnFromCorrections, forKey: Key.learnFromCorrections) }
  }

  /// Show words in the recorder while you are still speaking.
  ///
  /// Costs a second connection to the speech provider for the same audio, which is
  /// why it is a switch rather than always on — and why local-only refuses it outright
  /// regardless of what this says.
  @Published var livePreview: Bool {
    didSet { defaults.set(livePreview, forKey: Key.livePreview) }
  }

  /// Put every setting back to its default.
  ///
  /// Removes the `rant.` keys and reloads, rather than assigning defaults one at a
  /// time — a list of assignments is a list somebody forgets to extend when they add a
  /// setting, and a reset that silently misses one is worse than none.
  ///
  /// Deliberately settings only. Transcripts, dictionary and snippets live in the
  /// database and are cleared from Privacy, where the warning can say what is being
  /// destroyed.
  func resetAll() {
    for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("rant.") {
      defaults.removeObject(forKey: key)
    }
    hasCompletedOnboarding = false
    triggerKey = .rightCommand
    activationMode = .hybrid
    cleanupLevel = .medium
    speechProvider = "assemblyai"
    localOnly = false
    preferLocalCleanup = false
    retainAudio = false
    audioRetentionDays = 0
    microphoneUniqueID = nil
    languageCode = nil
    playSounds = true
    overlayAlwaysVisible = false
    launchAtLogin = false
    contextEnabled = true
    contextAllowCloud = true
    contextUseClipboard = false
    contextUseScreenOCR = false
    excludedBundleIDs = ContextSettings.defaultExclusions
    enhancementProvider = "none"
    ollamaEndpoint = "http://localhost:11434"
    ollamaModel = "llama3.2"
    developerMode = false
    mcpEnabled = false
    learnFromCorrections = false
    livePreview = true
    objectWillChange.send()
  }

  var hotkeyConfiguration: HotkeyEngine.Configuration {
    HotkeyEngine.Configuration(trigger: triggerKey, mode: activationMode)
  }
}
