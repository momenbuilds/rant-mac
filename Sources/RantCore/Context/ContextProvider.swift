import Foundation

/// Gathers what Rant knows about where the user is typing.
public protocol ContextProvider: Sendable {
  /// Capture a snapshot. Must be quick — this runs on the hot path, between the
  /// hotkey and the first audio sample.
  func capture(settings: ContextSettings) async -> TranscriptionContext
}

/// Returns whatever it was constructed with. Lets pipeline tests state the context
/// as a literal instead of pretending to have a focused window.
public struct StaticContextProvider: ContextProvider {
  private let context: TranscriptionContext
  public init(_ context: TranscriptionContext) { self.context = context }
  public func capture(settings: ContextSettings) async -> TranscriptionContext { context }
}
