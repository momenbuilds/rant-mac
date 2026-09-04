import Foundation
import Security

/// Where API keys live: the macOS Keychain, and nowhere else.
///
/// Not `UserDefaults` (world-readable plist in the container), not a JSON file, not
/// an environment variable, not a `@AppStorage` property that a SwiftUI preview
/// would happily dump. `SECURITY.md` lists "an API key leaving the Keychain" as a
/// vulnerability class, and this type is the only sanctioned way to touch one.
public protocol SecretStoring: Sendable {
  func read(_ key: SecretKey) throws -> String?
  func write(_ value: String, for key: SecretKey) throws
  func delete(_ key: SecretKey) throws
}

/// The secrets Rant can hold. An enum rather than free strings so the full inventory
/// of what this app stores is one screenful, auditable at a glance.
public enum SecretKey: String, CaseIterable, Sendable {
  case assemblyAI = "assemblyai.api-key"
  case openAICompatible = "openai-compatible.api-key"
  case enhancementProvider = "enhancement.api-key"

  public var displayName: String {
    switch self {
    case .assemblyAI: "AssemblyAI API key"
    case .openAICompatible: "OpenAI-compatible API key"
    case .enhancementProvider: "Enhancement provider API key"
    }
  }
}

public enum SecretStoreError: Error, Equatable, LocalizedError {
  case keychain(OSStatus)
  case malformedData

  public var errorDescription: String? {
    switch self {
    case .keychain(let status):
      let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
      return "Keychain error \(status): \(message)"
    case .malformedData:
      return "The stored value could not be read as text."
    }
  }
}

/// The real implementation, backed by a generic password item.
public struct KeychainSecretStore: SecretStoring {
  private let service: String
  private let log = RantLog("Secrets")

  public init(service: String = "dev.rant.mac") {
    self.service = service
  }

  private func baseQuery(_ key: SecretKey) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key.rawValue,
      // The key is needed whenever the user dictates, which can be immediately after
      // login and while the screen is locked by a screensaver — but it should never
      // sync to another device or survive into a restored backup on a machine the
      // user did not set up.
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      kSecAttrSynchronizable as String: false,
    ]
  }

  public func read(_ key: SecretKey) throws -> String? {
    var query = baseQuery(key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
        throw SecretStoreError.malformedData
      }
      // Note what was read, never what was read *out*.
      return string.trimmingCharacters(in: .whitespacesAndNewlines)
    case errSecItemNotFound:
      return nil
    default:
      throw SecretStoreError.keychain(status)
    }
  }

  public func write(_ value: String, for key: SecretKey) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { try delete(key); return }
    let data = Data(trimmed.utf8)

    // Update in place if it exists, so we never briefly have no key on disk.
    let updateStatus = SecItemUpdate(
      baseQuery(key) as CFDictionary,
      [kSecValueData as String: data] as CFDictionary)
    if updateStatus == errSecSuccess {
      log.info("updated \(key.rawValue)")
      return
    }
    guard updateStatus == errSecItemNotFound else { throw SecretStoreError.keychain(updateStatus) }

    var insert = baseQuery(key)
    insert[kSecValueData as String] = data
    let addStatus = SecItemAdd(insert as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw SecretStoreError.keychain(addStatus) }
    log.info("stored \(key.rawValue)")
  }

  public func delete(_ key: SecretKey) throws {
    let status = SecItemDelete(baseQuery(key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SecretStoreError.keychain(status)
    }
    log.info("deleted \(key.rawValue)")
  }
}

/// In-memory store for tests and previews. Deliberately in the shipping target so a
/// test never has to reach for the real Keychain — a test that prompts for a
/// keychain password is a test nobody runs.
public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
  private var storage: [SecretKey: String] = [:]
  private let lock = NSLock()

  public init(_ initial: [SecretKey: String] = [:]) { storage = initial }

  public func read(_ key: SecretKey) throws -> String? {
    lock.withLock { storage[key] }
  }
  public func write(_ value: String, for key: SecretKey) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    lock.withLock { trimmed.isEmpty ? (storage[key] = nil) : (storage[key] = trimmed) }
  }
  public func delete(_ key: SecretKey) throws {
    lock.withLock { storage[key] = nil }
  }
}

/// Shape validation for a pasted AssemblyAI key. Not authentication — that needs a
/// round trip — but enough to catch the overwhelmingly common mistakes (pasting a
/// whole curl command, pasting with quotes, pasting nothing) before we spend a
/// network request and show a confusing 401.
public enum APIKeyValidator {
  public enum Verdict: Equatable, Sendable {
    case looksValid
    case empty
    case tooShort
    case containsWhitespace
    case looksLikeACommand

    public var message: String? {
      switch self {
      case .looksValid: nil
      case .empty: "Paste your AssemblyAI API key."
      case .tooShort: "That looks too short to be an API key."
      case .containsWhitespace: "That contains spaces — did some extra text come along with it?"
      case .looksLikeACommand: "That looks like a whole command. Paste just the key itself."
      }
    }
  }

  public static func check(_ raw: String) -> Verdict {
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if key.isEmpty { return .empty }
    if key.lowercased().hasPrefix("curl") || key.contains("://") { return .looksLikeACommand }
    if key.contains(where: \.isWhitespace) { return .containsWhitespace }
    if key.count < 20 { return .tooShort }
    return .looksValid
  }
}
