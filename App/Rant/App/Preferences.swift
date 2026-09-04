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
      retainAudio: retainAudio)
  }

  var hotkeyConfiguration: HotkeyEngine.Configuration {
    HotkeyEngine.Configuration(trigger: triggerKey, mode: activationMode)
  }
}
