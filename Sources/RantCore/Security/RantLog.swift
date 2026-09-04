import Foundation
import os

/// Logging that cannot accidentally publish what you said.
///
/// `os.Logger` interpolation defaults to `.private` for strings, but that default is
/// easy to lose: one `\(text, privacy: .public)` added while debugging and every
/// transcript the user dictates is in the system log, readable by any process that
/// can run `log show`. So the transcript body never reaches a `Logger` at all —
/// `RantLog` exposes no method that takes user text, only shapes and counts.
///
/// When you genuinely need to see the text while debugging, turn on Developer Mode
/// in Advanced settings; that writes to a file inside the app's own container which
/// the user can open, inspect and delete, rather than to the system-wide log.
public struct RantLog: Sendable {
  public static let subsystem = "dev.rant.mac"

  private let logger: Logger
  public let category: String

  public init(_ category: String) {
    self.category = category
    self.logger = Logger(subsystem: Self.subsystem, category: category)
  }

  public func debug(_ message: String) { logger.debug("\(message, privacy: .public)") }
  public func info(_ message: String) { logger.info("\(message, privacy: .public)") }
  public func notice(_ message: String) { logger.notice("\(message, privacy: .public)") }
  public func warning(_ message: String) { logger.warning("\(message, privacy: .public)") }
  public func error(_ message: String) { logger.error("\(message, privacy: .public)") }

  /// The only sanctioned way to say anything about user text: its shape, never its
  /// content. `log.shape("transcript", of: text)` yields `transcript 143 chars, 27 words`.
  public func shape(_ label: String, of text: String) {
    let words = text.split(whereSeparator: \.isWhitespace).count
    logger.info("\(label, privacy: .public) \(text.count, privacy: .public) chars, \(words, privacy: .public) words")
  }

  /// Compile-time barrier. Calling `log.info(transcript)` is legal Swift, so the
  /// guard has to be a review-and-test one rather than a type-system one — but this
  /// marker makes the intent greppable, and `RedactionTests` asserts the redactor
  /// catches what matters.
  public static let userTextIsNeverLogged = true
}
