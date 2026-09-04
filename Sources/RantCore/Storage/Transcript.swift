import CryptoKit
import Foundation

/// How Rant classifies the surface you were dictating into. Drives style selection
/// and the Insights breakdown.
public enum UsageCategory: String, Codable, Sendable, CaseIterable {
  case aiPrompt, personal, work, email, documents, developer, other

  public var displayName: String {
    switch self {
    case .aiPrompt: "AI prompts"
    case .personal: "Personal messages"
    case .work: "Work messages"
    case .email: "Email"
    case .documents: "Documents"
    case .developer: "Developer"
    case .other: "Other"
    }
  }
}

/// One completed dictation.
public struct Transcript: Equatable, Sendable, Identifiable {
  public var id: Int64?
  public var createdAt: Date
  /// What the model heard. Never rewritten — cleanup is lossy and this is the input.
  public var rawText: String
  /// What was actually inserted.
  public var finalText: String
  public var provider: String
  public var language: String?
  public var cleanupLevel: CleanupLevel
  public var mode: String?
  public var style: String?
  public var appBundleID: String?
  public var appName: String?
  public var browserHost: String?
  public var category: UsageCategory
  public var durationMilliseconds: Int
  public var wordCount: Int
  public var wordsPerMinute: Double?
  public var enhanced: Bool
  public var audioPath: String?
  /// Deterministic over the content, so importing the same export twice is a no-op.
  public var contentHash: String
  /// Where this row came from: `rant`, or `wispr_flow`, `voiceink`, … after an import.
  public var source: String
  public var sourceID: String?
  public var favourite: Bool
  /// The user's own labels for this dictation. Personal, local, never sent anywhere.
  public var tags: [String]

  public init(
    id: Int64? = nil,
    createdAt: Date = Date(),
    rawText: String,
    finalText: String,
    provider: String,
    language: String? = nil,
    cleanupLevel: CleanupLevel = .medium,
    mode: String? = nil,
    style: String? = nil,
    appBundleID: String? = nil,
    appName: String? = nil,
    browserHost: String? = nil,
    category: UsageCategory = .other,
    durationMilliseconds: Int = 0,
    wordCount: Int? = nil,
    wordsPerMinute: Double? = nil,
    enhanced: Bool = false,
    audioPath: String? = nil,
    contentHash: String? = nil,
    source: String = "rant",
    sourceID: String? = nil,
    favourite: Bool = false,
    tags: [String] = []
  ) {
    self.tags = tags
    self.id = id
    self.createdAt = createdAt
    self.rawText = rawText
    self.finalText = finalText
    self.provider = provider
    self.language = language
    self.cleanupLevel = cleanupLevel
    self.mode = mode
    self.style = style
    self.appBundleID = appBundleID
    self.appName = appName
    self.browserHost = browserHost
    self.category = category
    self.durationMilliseconds = durationMilliseconds
    let words = wordCount ?? Transcript.countWords(finalText)
    self.wordCount = words
    self.wordsPerMinute =
      wordsPerMinute ?? Transcript.wordsPerMinute(words: words, milliseconds: durationMilliseconds)
    self.enhanced = enhanced
    self.audioPath = audioPath
    self.contentHash =
      contentHash ?? Transcript.hash(text: finalText, createdAt: createdAt, source: source)
    self.source = source
    self.sourceID = sourceID
    self.favourite = favourite
  }

  public static func countWords(_ text: String) -> Int {
    text.split(whereSeparator: { $0.isWhitespace }).count
  }

  public static func wordsPerMinute(words: Int, milliseconds: Int) -> Double? {
    guard milliseconds > 500, words > 0 else { return nil }
    return Double(words) / (Double(milliseconds) / 60_000)
  }

  /// Identity for deduplication.
  ///
  /// Text plus timestamp plus source, rather than text alone: dictating "yes" twice
  /// in a day is two real events, but importing the same export twice is one. The
  /// timestamp is rounded to the second because exports round-trip through formats
  /// with different precision, and a millisecond of drift should not create a
  /// duplicate.
  public static func hash(text: String, createdAt: Date, source: String) -> String {
    let normalised = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .lowercased()
    let seconds = Int(createdAt.timeIntervalSince1970.rounded())
    let digest = SHA256.hash(data: Data("\(source)|\(seconds)|\(normalised)".utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

/// A search hit, with the snippet FTS produced.
public struct TranscriptSearchResult: Equatable, Sendable {
  public var transcript: Transcript
  public var snippet: String
}

/// Reading and writing dictation history.
public protocol TranscriptStore: Sendable {
  @discardableResult func save(_ transcript: Transcript) throws -> Transcript
  func recent(limit: Int, offset: Int) throws -> [Transcript]
  func transcript(id: Int64) throws -> Transcript?
  func search(_ query: String, limit: Int) throws -> [TranscriptSearchResult]
  func delete(id: Int64) throws
  func delete(ids: [Int64]) throws
  func deleteAll() throws
  func count() throws -> Int
  func setFavourite(id: Int64, _ value: Bool) throws
  func update(id: Int64, finalText: String) throws
}
