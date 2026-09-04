import Foundation

/// A model that rewrites text. Separate from transcription because the two are
/// genuinely different jobs, and because Rant must do useful dictation with this
/// turned off entirely.
public protocol EnhancementProvider: Sendable {
  var identifier: String { get }
  var displayName: String { get }
  /// True when using this provider sends your text to someone else's machine. Drives
  /// the label the user sees at the point of choosing it, not in a help article.
  var sendsTextOffDevice: Bool { get }

  func enhance(
    _ text: String, instruction: String, context: TranscriptionContext?
  ) async throws -> String

  func isAvailable() async -> Bool
}

/// Returns the input unchanged. The default, and what "enhancement: none" means.
public struct NoEnhancement: EnhancementProvider {
  public let identifier = "none"
  public let displayName = "None"
  public let sendsTextOffDevice = false
  public init() {}
  public func enhance(
    _ text: String, instruction: String, context: TranscriptionContext?
  ) async throws -> String { text }
  public func isAvailable() async -> Bool { true }
}

/// Applies a caller-supplied transform. Used by tests to assert the pipeline calls
/// the enhancer at the right moment with the right instruction.
public final class StubEnhancer: EnhancementProvider, @unchecked Sendable {
  public let identifier = "stub"
  public let displayName = "Stub"
  public let sendsTextOffDevice = false
  public private(set) var calls: [(text: String, instruction: String)] = []
  private let transform: @Sendable (String) -> String
  private let lock = NSLock()

  public init(_ transform: @escaping @Sendable (String) -> String = { $0.uppercased() }) {
    self.transform = transform
  }

  public func enhance(
    _ text: String, instruction: String, context: TranscriptionContext?
  ) async throws -> String {
    lock.withLock { calls.append((text, instruction)) }
    return transform(text)
  }
  public func isAvailable() async -> Bool { true }
}
