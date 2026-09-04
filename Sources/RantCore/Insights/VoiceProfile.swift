import Foundation

/// A term and how often it was observed.
public struct TermCount: Equatable, Sendable {
  public var term: String
  public var count: Int
}

/// A pair the user kept fixing by hand: what went in, what they changed it to.
public struct CorrectedTerm: Equatable, Sendable {
  public var heard: String
  public var corrected: String
  public var occurrences: Int
}

/// How dictation into one application actually looks.
public struct AppStyle: Equatable, Sendable {
  public var bundleID: String?
  public var appName: String
  public var dictations: Int
  /// Mean words per dictation. The difference between a chat window and a document
  /// shows up here more clearly than anywhere else.
  public var averageWords: Double
  public var averageWordsPerMinute: Double
  public var dominantCategory: UsageCategory
  public var dominantCleanupLevel: CleanupLevel
}

/// A factual description of how someone dictates.
///
/// Every field is a count or a mean over rows the user can open in `sqlite3` and check
/// for themselves. There are deliberately no personality labels, no "communication
/// style", no archetypes: those are unfalsifiable, they cannot be traced to a row, and
/// a user who disagrees with one has no way to argue. A profile that says "your median
/// rate is 138 wpm across 412 dictations" can be wrong in a way you can point at,
/// which is the only kind of claim worth showing.
///
/// `sampleSize` is on the value for the same reason: a profile built from nine
/// dictations should be read as nine dictations, and the screen cannot say so unless
/// the number travels with the data.
public struct VoiceProfile: Equatable, Sendable {
  /// Number of dictations the profile was computed from.
  public var sampleSize: Int
  public var earliest: Date?
  public var latest: Date?
  /// Mean speaking rate over the sample, weighted by duration rather than by
  /// dictation, so one three-word aside does not count as much as a five-minute note.
  public var averageWordsPerMinute: Double
  /// The middle rate. Reported alongside the mean because a handful of very short
  /// recordings drags a mean around and this does not move.
  public var medianWordsPerMinute: Double
  /// Filler sounds counted in the *raw* transcript, since cleanup removes them before
  /// anything else sees them.
  public var fillerWords: [TermCount]
  /// Fillers per hundred words spoken — comparable between a light week and a heavy
  /// one, which a raw count is not.
  public var fillersPerHundredWords: Double
  /// The words used most, excluding the common English function words that would
  /// otherwise be the whole list.
  public var vocabulary: [TermCount]
  /// Language codes seen on the transcripts, most frequent first.
  public var languages: [TermCount]
  /// The cleanup level actually used most, which is not always the one in settings.
  public var preferredCleanupLevel: CleanupLevel
  public var correctedTerms: [CorrectedTerm]
  public var appStyles: [AppStyle]

  public static let empty = VoiceProfile(
    sampleSize: 0, earliest: nil, latest: nil, averageWordsPerMinute: 0,
    medianWordsPerMinute: 0, fillerWords: [], fillersPerHundredWords: 0, vocabulary: [],
    languages: [], preferredCleanupLevel: .medium, correctedTerms: [], appStyles: [])
}

/// Builds a `VoiceProfile` from the history.
///
/// Unlike `InsightsEngine`, this one has to read transcript text — there is no
/// aggregate table for "which words do you say". So it reads a bounded window of the
/// most recent dictations instead of the lot: the profile is meant to describe how you
/// dictate *now*, and the vocabulary of two years ago is both less useful and more
/// expensive to fetch. The window is the argument, so the caller can widen it.
public struct VoiceProfileBuilder: Sendable {
  private let database: Database
  private let log = RantLog("VoiceProfile")

  /// How many recent dictations to read. A thousand rows of text is a few megabytes at
  /// worst and one query; the whole history is unbounded.
  public static let defaultSampleSize = 1_000

  /// Words too common to say anything about a person. Kept short and closed rather
  /// than clever: this list only exists to stop "the" topping every profile, and a
  /// longer one starts deleting terms that are genuinely characteristic.
  static let stopWords: Set<String> = [
    "the", "a", "an", "and", "or", "but", "if", "then", "than", "that", "this", "these",
    "those", "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did",
    "have", "has", "had", "i", "you", "he", "she", "it", "we", "they", "me", "him", "her",
    "us", "them", "my", "your", "his", "its", "our", "their", "of", "to", "in", "on", "at",
    "for", "with", "from", "by", "as", "into", "about", "over", "not", "no", "yes", "so",
    "just", "will", "would", "can", "could", "should", "there", "here", "what", "which",
    "who", "when", "where", "how", "all", "any", "some", "one", "up", "out", "very",
  ]

  public init(database: Database) {
    self.database = database
  }

  public func build(sampleSize: Int = defaultSampleSize) throws -> VoiceProfile {
    let rows = try database.query(
      """
      SELECT raw_text, final_text, word_count, duration_ms, words_per_minute, language,
             cleanup_level, app_bundle_id, app_name, category, created_at
      FROM transcripts
      ORDER BY created_at DESC
      LIMIT ?
      """,
      [.int(max(sampleSize, 0))]
    ) { row in
      Sample(
        rawText: row.string(0), finalText: row.string(1), wordCount: row.int(2),
        durationMilliseconds: row.int(3), wordsPerMinute: row.double(4),
        language: row.stringOrNil(5),
        cleanupLevel: CleanupLevel(rawValue: row.string(6)) ?? .medium,
        bundleID: row.stringOrNil(7), appName: row.stringOrNil(8),
        category: UsageCategory(rawValue: row.string(9)) ?? .other, createdAt: row.date(10))
    }

    guard !rows.isEmpty else { return .empty }

    let words = rows.reduce(0) { $0 + $1.wordCount }
    let milliseconds = rows.reduce(0) { $0 + $1.durationMilliseconds }
    let rates = rows.compactMap { $0.wordsPerMinute > 0 ? $0.wordsPerMinute : nil }.sorted()

    var fillers: [String: Int] = [:]
    var vocabulary: [String: Int] = [:]
    var spokenWords = 0
    for sample in rows {
      spokenWords += Self.tally(sample.rawText, into: &fillers, keeping: TranscriptCleaner.fillerWords)
      Self.tallyVocabulary(sample.finalText, into: &vocabulary)
    }
    let fillerCount = fillers.values.reduce(0, +)

    return VoiceProfile(
      sampleSize: rows.count,
      earliest: rows.map(\.createdAt).min(),
      latest: rows.map(\.createdAt).max(),
      averageWordsPerMinute: milliseconds > 0 && words > 0
        ? Double(words) / (Double(milliseconds) / 60_000) : 0,
      medianWordsPerMinute: Self.median(rates),
      fillerWords: Self.top(fillers, limit: 8),
      fillersPerHundredWords: spokenWords > 0
        ? Double(fillerCount) / Double(spokenWords) * 100 : 0,
      vocabulary: Self.top(vocabulary, limit: 20),
      languages: Self.top(
        rows.reduce(into: [String: Int]()) { counts, sample in
          if let language = sample.language, !language.isEmpty {
            counts[language, default: 0] += 1
          }
        }, limit: 8),
      preferredCleanupLevel: Self.dominant(rows.map(\.cleanupLevel)) ?? .medium,
      correctedTerms: try correctedTerms(),
      appStyles: Self.appStyles(rows))
  }

  /// Corrections the user made by hand, from the learning candidates table.
  ///
  /// Read even when learning is switched off, because the value here is descriptive:
  /// "you fix Kubernetes to kubectl nine times out of ten" is worth seeing whether or
  /// not you ever want a rule created from it. Rejected candidates are excluded — the
  /// user has already said that pair is not a correction.
  func correctedTerms(limit: Int = 10) throws -> [CorrectedTerm] {
    try database.query(
      """
      SELECT spoken, written, occurrences FROM learning_candidates
      WHERE status <> 'rejected'
      ORDER BY occurrences DESC, observed_at DESC
      LIMIT ?
      """,
      [.int(limit)]
    ) { CorrectedTerm(heard: $0.string(0), corrected: $0.string(1), occurrences: $0.int(2)) }
  }

  // MARK: - Aggregation

  struct Sample: Sendable {
    var rawText: String
    var finalText: String
    var wordCount: Int
    var durationMilliseconds: Int
    var wordsPerMinute: Double
    var language: String?
    var cleanupLevel: CleanupLevel
    var bundleID: String?
    var appName: String?
    var category: UsageCategory
    var createdAt: Date
  }

  static func appStyles(_ rows: [Sample], limit: Int = 8) -> [AppStyle] {
    var grouped: [String: [Sample]] = [:]
    for sample in rows {
      // Bundle id first: an app can be renamed, and two apps can share a display name.
      let key = sample.bundleID ?? sample.appName ?? ""
      guard !key.isEmpty else { continue }
      grouped[key, default: []].append(sample)
    }

    var styles: [AppStyle] = []
    for (key, samples) in grouped {
      let words: Int = samples.reduce(0) { $0 + $1.wordCount }
      let milliseconds: Int = samples.reduce(0) { $0 + $1.durationMilliseconds }
      let minutes: Double = Double(milliseconds) / 60_000
      let rate: Double = (minutes > 0 && words > 0) ? Double(words) / minutes : 0
      styles.append(
        AppStyle(
          bundleID: samples.first?.bundleID,
          appName: samples.compactMap(\.appName).first ?? key,
          dictations: samples.count,
          averageWords: Double(words) / Double(samples.count),
          averageWordsPerMinute: rate,
          dominantCategory: dominant(samples.map(\.category)) ?? .other,
          dominantCleanupLevel: dominant(samples.map(\.cleanupLevel)) ?? .medium))
    }

    styles.sort {
      $0.dictations == $1.dictations
        ? $0.appName < $1.appName : $0.dictations > $1.dictations
    }
    return Array(styles.prefix(limit))
  }

  /// Counts tokens of `text` that appear in `keeping`, and returns the total number of
  /// tokens seen so a rate can be computed from the same pass.
  ///
  /// A linear scan rather than a regular expression. Tokenising with a pattern is the
  /// obvious move and it is how this codebase already earned one catastrophic
  /// backtracking hang; a character loop cannot backtrack at all, and on a megabyte of
  /// transcript it is also faster.
  @discardableResult
  static func tally(_ text: String, into counts: inout [String: Int], keeping: Set<String>)
    -> Int
  {
    var total = 0
    forEachToken(text) { token in
      total += 1
      if keeping.contains(token) { counts[token, default: 0] += 1 }
    }
    return total
  }

  static func tallyVocabulary(_ text: String, into counts: inout [String: Int]) {
    forEachToken(text) { token in
      // Single letters are almost always list markers or the remains of an
      // abbreviation, and two-letter words are function words we do not want either.
      guard token.count > 2, !stopWords.contains(token) else { return }
      counts[token, default: 0] += 1
    }
  }

  /// Lower-cased word tokens. Letters and digits build a token; an apostrophe is kept
  /// only between them, so "don't" survives whole while a quoted 'word' does not gain
  /// one. Everything else ends the token.
  static func forEachToken(_ text: String, _ body: (String) -> Void) {
    var token = ""
    var pendingApostrophe = false
    for character in text.lowercased() {
      if character.isLetter || character.isNumber {
        if pendingApostrophe, !token.isEmpty { token.append("'") }
        pendingApostrophe = false
        token.append(character)
      } else if character == "'" || character == "\u{2019}" {
        pendingApostrophe = !token.isEmpty
      } else {
        pendingApostrophe = false
        if !token.isEmpty {
          body(token)
          token.removeAll(keepingCapacity: true)
        }
      }
    }
    if !token.isEmpty { body(token) }
  }

  static func top(_ counts: [String: Int], limit: Int) -> [TermCount] {
    var terms: [TermCount] = []
    terms.reserveCapacity(counts.count)
    for (term, count) in counts { terms.append(TermCount(term: term, count: count)) }
    // Ties broken alphabetically so the list does not reshuffle between two runs over
    // identical data, which looks like a bug to anyone watching the screen.
    terms.sort { $0.count == $1.count ? $0.term < $1.term : $0.count > $1.count }
    return Array(terms.prefix(limit))
  }

  /// The most frequent value, with ties going to whichever appeared first.
  ///
  /// `Dictionary.max(by:)` would be shorter and would return a different answer on
  /// each run when two values tie, because dictionary order is not stable. A profile
  /// that changes its mind about your preferred cleanup level between two refreshes
  /// reads as a bug.
  static func dominant<T: Hashable>(_ values: [T]) -> T? {
    var counts: [T: Int] = [:]
    var best: T?
    var bestCount = 0
    for value in values {
      let count = (counts[value] ?? 0) + 1
      counts[value] = count
      if count > bestCount {
        bestCount = count
        best = value
      }
    }
    return best
  }

  static func median(_ sorted: [Double]) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
  }
}
