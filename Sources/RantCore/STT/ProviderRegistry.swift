import Foundation

/// Why a provider can or cannot be used right now.
public enum ProviderStatus: Equatable, Sendable {
  case ready
  case needsAPIKey
  /// The local weights have not been downloaded yet; the string is the model's name.
  case needsModelDownload(String)
  /// Perfectly configured, but it would send audio off the machine and the user has
  /// said not to. Listed rather than hidden, so the setting explains itself.
  case blockedByLocalOnly
  case unavailable(String)

  public var isReady: Bool { self == .ready }

  /// One line for the settings row.
  public var explanation: String? {
    switch self {
    case .ready: nil
    case .needsAPIKey: "Add an API key to use this."
    case .needsModelDownload(let model): "Download \(model) to use this."
    case .blockedByLocalOnly: "Turned off because Rant is set to local only."
    case .unavailable(let reason): reason
    }
  }
}

/// What the settings list shows for one provider.
public struct ProviderDescriptor: Equatable, Sendable, Identifiable {
  public let identifier: String
  public let displayName: String
  /// The privacy indicator, and the thing local-only mode keys off. One boolean
  /// rather than a policy object, because a user reading the list needs a yes or a no.
  public let sendsAudioOffDevice: Bool
  public let status: ProviderStatus
  /// Whether the user has supplied whatever this provider needs — a key, a model. A
  /// provider can be configured and still not selectable, which is exactly the
  /// local-only case.
  public let isConfigured: Bool

  public var id: String { identifier }
  public var isSelectable: Bool { status.isReady }

  /// The words next to the provider's name. Stated as where the audio goes, not as a
  /// reassuring adjective.
  public var privacyLabel: String {
    sendsAudioOffDevice ? "Audio is sent to the provider" : "Audio stays on this Mac"
  }

  public init(
    identifier: String,
    displayName: String,
    sendsAudioOffDevice: Bool,
    status: ProviderStatus,
    isConfigured: Bool
  ) {
    self.identifier = identifier
    self.displayName = displayName
    self.sendsAudioOffDevice = sendsAudioOffDevice
    self.status = status
    self.isConfigured = isConfigured
  }
}

/// The speech providers Rant knows about, what state each is in, and which one a
/// dictation should use.
///
/// The one rule worth the whole type: in local-only mode a network provider is
/// **refused**, never substituted. Silent fallback is the failure this file exists to
/// prevent — a user who turns on local-only and later finds their audio was uploaded
/// because the local model happened to be missing has been lied to, and no error
/// message afterwards repairs that.
public struct ProviderRegistry: Sendable {
  /// A provider plus how to ask whether the user has finished setting it up. The
  /// closure is evaluated on every read so that adding a key or downloading a model
  /// shows up immediately, without anything having to remember to invalidate a cache.
  public struct Entry: Sendable {
    public let provider: any TranscriptionProvider
    public let configuration: @Sendable () -> ProviderStatus

    public init(
      _ provider: any TranscriptionProvider,
      configuration: @escaping @Sendable () -> ProviderStatus
    ) {
      self.provider = provider
      self.configuration = configuration
    }

    /// A cloud provider is configured exactly when there is a key.
    public static func cloud(
      _ provider: any TranscriptionProvider, hasKey: @escaping @Sendable () -> Bool
    ) -> Entry {
      Entry(provider) { hasKey() ? .ready : .needsAPIKey }
    }

    /// A local provider is configured exactly when the weights are on disk.
    public static func local(
      _ provider: LocalWhisperProvider, isModelInstalled: @escaping @Sendable () -> Bool
    ) -> Entry {
      let name = provider.model.displayName
      return Entry(provider) { isModelInstalled() ? .ready : .needsModelDownload(name) }
    }
  }

  public let entries: [Entry]
  /// The user's promise to themselves. When set, nothing that leaves the machine runs.
  public let localOnly: Bool

  public init(entries: [Entry], localOnly: Bool = false) {
    self.entries = entries
    self.localOnly = localOnly
  }

  /// Same registry, different setting. Cheap, so a settings toggle can rebuild rather
  /// than mutate shared state.
  public func settingLocalOnly(_ value: Bool) -> ProviderRegistry {
    ProviderRegistry(entries: entries, localOnly: value)
  }

  public func descriptors() -> [ProviderDescriptor] {
    entries.map { entry in
      let configured = entry.configuration()
      let blocked = localOnly && entry.provider.sendsAudioOffDevice
      return ProviderDescriptor(
        identifier: entry.provider.identifier,
        displayName: entry.provider.displayName,
        sendsAudioOffDevice: entry.provider.sendsAudioOffDevice,
        // Local-only wins over everything: a provider with a perfectly good key is
        // still not usable, and saying so is the point.
        status: blocked ? .blockedByLocalOnly : configured,
        isConfigured: configured.isReady)
    }
  }

  public func descriptor(for identifier: String) -> ProviderDescriptor? {
    descriptors().first { $0.identifier == identifier }
  }

  /// True when there is at least one provider that can run under the current setting.
  public var hasUsableProvider: Bool {
    descriptors().contains { $0.isSelectable }
  }

  /// The provider for an explicit choice.
  ///
  /// Throws rather than returning a substitute. A caller that wanted AssemblyAI and
  /// gets an error can tell the user; a caller that wanted AssemblyAI and silently
  /// got something else cannot.
  public func provider(withIdentifier identifier: String) throws -> any TranscriptionProvider {
    guard let entry = entries.first(where: { $0.provider.identifier == identifier }) else {
      throw TranscriptionError.modelUnavailable(identifier)
    }
    if localOnly && entry.provider.sendsAudioOffDevice {
      throw TranscriptionError.localOnlyViolation(provider: entry.provider.displayName)
    }
    switch entry.configuration() {
    case .ready:
      return entry.provider
    case .needsAPIKey:
      throw TranscriptionError.apiKeyMissing
    case .needsModelDownload(let model):
      throw TranscriptionError.modelUnavailable(model)
    case .blockedByLocalOnly:
      throw TranscriptionError.localOnlyViolation(provider: entry.provider.displayName)
    case .unavailable(let reason):
      throw TranscriptionError.network(reason)
    }
  }

  /// The provider to dictate with.
  ///
  /// With a preference, that provider or an error — never a different one. Without a
  /// preference, the first ready provider in registration order, where a network
  /// provider is not even a candidate under local-only. The asymmetry is deliberate:
  /// choosing for the user is acceptable only when they have not chosen.
  public func resolve(preferred identifier: String? = nil) throws -> any TranscriptionProvider {
    if let identifier {
      return try provider(withIdentifier: identifier)
    }
    let candidates = entries.filter { !(localOnly && $0.provider.sendsAudioOffDevice) }
    if let ready = candidates.first(where: { $0.configuration().isReady }) {
      return ready.provider
    }
    // Report the most specific reason we have rather than a generic "no provider".
    if localOnly, let local = candidates.first {
      switch local.configuration() {
      case .needsModelDownload(let model): throw TranscriptionError.modelUnavailable(model)
      case .needsAPIKey: throw TranscriptionError.apiKeyMissing
      default: break
      }
    }
    if localOnly, let blocked = entries.first(where: { $0.provider.sendsAudioOffDevice }) {
      throw TranscriptionError.localOnlyViolation(provider: blocked.provider.displayName)
    }
    if let entry = entries.first, case .needsAPIKey = entry.configuration() {
      throw TranscriptionError.apiKeyMissing
    }
    throw TranscriptionError.modelUnavailable("speech provider")
  }
}
