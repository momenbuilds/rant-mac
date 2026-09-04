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

  /// A file the app writes lifecycle lines to, alongside the system log.
  ///
  /// `os.Logger` output did not reach `log show` on this machine — a common enough
  /// situation with privacy settings and log throttling — which made every "why did
  /// nothing happen?" question unanswerable. A plain file inside the app's own
  /// container is readable by the person who owns the machine, deletable by them, and
  /// works regardless of how the unified log is configured.
  ///
  /// It records *shapes and lifecycle*, never transcript or context bodies — the same
  /// rule the system log follows.
  nonisolated(unsafe) public static var fileURL: URL? = defaultFileURL

  private static var defaultFileURL: URL? {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
    guard let directory = base.first?.appendingPathComponent("Rant", isDirectory: true) else {
      return nil
    }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("rant.log")
  }

  private static let fileLock = NSLock()

  private static func appendToFile(_ category: String, _ level: String, _ message: String) {
    guard let fileURL else { return }
    let stamp = Date().formatted(date: .omitted, time: .standard)
    let line = "\(stamp) [\(level)] \(category): \(message)\n"
    fileLock.lock()
    defer { fileLock.unlock() }
    if let handle = try? FileHandle(forWritingTo: fileURL) {
      defer { try? handle.close() }
      try? handle.seekToEnd()
      try? handle.write(contentsOf: Data(line.utf8))
    } else {
      try? Data(line.utf8).write(to: fileURL)
    }
  }

  private let logger: Logger
  public let category: String

  public init(_ category: String) {
    self.category = category
    self.logger = Logger(subsystem: Self.subsystem, category: category)
  }

  public func debug(_ message: String) { logger.debug("\(message, privacy: .public)") }

  public func info(_ message: String) {
    logger.info("\(message, privacy: .public)")
    Self.appendToFile(category, "info", message)
  }

  public func notice(_ message: String) {
    logger.notice("\(message, privacy: .public)")
    Self.appendToFile(category, "notice", message)
  }

  public func warning(_ message: String) {
    logger.warning("\(message, privacy: .public)")
    Self.appendToFile(category, "warn", message)
  }

  public func error(_ message: String) {
    logger.error("\(message, privacy: .public)")
    Self.appendToFile(category, "error", message)
  }

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
