import Foundation

/// `TranscriptStore` over SQLite.
public struct SQLiteTranscriptStore: TranscriptStore, Sendable {
  private let database: Database
  private let log = RantLog("History")

  public init(database: Database) {
    self.database = database
  }

  private static let columns = """
    id, created_at, raw_text, final_text, provider, language, cleanup_level, mode, style,
    app_bundle_id, app_name, browser_host, category, duration_ms, word_count,
    words_per_minute, enhanced, audio_path, content_hash, source, source_id, favourite
    """

  private func decode(_ row: Row) -> Transcript {
    Transcript(
      id: Int64(row.int(0)),
      createdAt: row.date(1),
      rawText: row.string(2),
      finalText: row.string(3),
      provider: row.string(4),
      language: row.stringOrNil(5),
      cleanupLevel: CleanupLevel(rawValue: row.string(6)) ?? .medium,
      mode: row.stringOrNil(7),
      style: row.stringOrNil(8),
      appBundleID: row.stringOrNil(9),
      appName: row.stringOrNil(10),
      browserHost: row.stringOrNil(11),
      category: UsageCategory(rawValue: row.string(12)) ?? .other,
      durationMilliseconds: row.int(13),
      wordCount: row.int(14),
      wordsPerMinute: row.intOrNil(15).map(Double.init) ?? (row.double(15) > 0 ? row.double(15) : nil),
      enhanced: row.bool(16),
      audioPath: row.stringOrNil(17),
      contentHash: row.string(18),
      source: row.string(19),
      sourceID: row.stringOrNil(20),
      favourite: row.bool(21))
  }

  /// Insert, or quietly return the existing row when the content hash matches.
  ///
  /// The existence check comes *before* the insert rather than relying on
  /// `INSERT OR IGNORE` alone, because the aggregate tables must only be touched for
  /// a row that is genuinely new. An ignored insert still looks like a success from
  /// the outside, and updating usage on the strength of that double-counts every
  /// re-imported dictation — which is exactly what a duplicate import is made of.
  /// The unique index stays as the backstop.
  @discardableResult
  public func save(_ transcript: Transcript) throws -> Transcript {
    try database.transaction {
      if let existing = try database.query(
        "SELECT \(Self.columns) FROM transcripts WHERE content_hash = ? LIMIT 1",
        [.text(transcript.contentHash)], decode
      ).first {
        return existing
      }

      try database.run(
        """
        INSERT OR IGNORE INTO transcripts
          (created_at, raw_text, final_text, provider, language, cleanup_level, mode, style,
           app_bundle_id, app_name, browser_host, category, duration_ms, word_count,
           words_per_minute, enhanced, audio_path, content_hash, source, source_id, favourite)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """,
        [
          SQLValue(transcript.createdAt), .text(transcript.rawText), .text(transcript.finalText),
          .text(transcript.provider), SQLValue(transcript.language),
          .text(transcript.cleanupLevel.rawValue), SQLValue(transcript.mode),
          SQLValue(transcript.style), SQLValue(transcript.appBundleID),
          SQLValue(transcript.appName), SQLValue(transcript.browserHost),
          .text(transcript.category.rawValue), .int(transcript.durationMilliseconds),
          .int(transcript.wordCount), SQLValue(transcript.wordsPerMinute),
          SQLValue(transcript.enhanced), SQLValue(transcript.audioPath),
          .text(transcript.contentHash), .text(transcript.source), SQLValue(transcript.sourceID),
          SQLValue(transcript.favourite),
        ])

      let stored = try database.query(
        "SELECT \(Self.columns) FROM transcripts WHERE content_hash = ? LIMIT 1",
        [.text(transcript.contentHash)], decode)
      guard let row = stored.first else { return transcript }
      try recordUsage(row)
      return row
    }
  }

  /// Keeps the pre-aggregated Insights tables current. Runs inside the caller's
  /// transaction, so a failed save never leaves inflated statistics behind.
  private func recordUsage(_ transcript: Transcript) throws {
    let day = Self.dayFormatter.string(from: transcript.createdAt)
    try database.run(
      """
      INSERT INTO usage_daily (day, words, dictations, duration_ms) VALUES (?,?,1,?)
      ON CONFLICT(day) DO UPDATE SET
        words = words + excluded.words,
        dictations = dictations + 1,
        duration_ms = duration_ms + excluded.duration_ms
      """,
      [.text(day), .int(transcript.wordCount), .int(transcript.durationMilliseconds)])
    try database.run(
      """
      INSERT INTO app_usage (day, category, words) VALUES (?,?,?)
      ON CONFLICT(day, category) DO UPDATE SET words = words + excluded.words
      """,
      [.text(day), .text(transcript.category.rawValue), .int(transcript.wordCount)])
  }

  static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
  }()

  public func recent(limit: Int = 50, offset: Int = 0) throws -> [Transcript] {
    try database.query(
      "SELECT \(Self.columns) FROM transcripts ORDER BY created_at DESC LIMIT ? OFFSET ?",
      [.int(limit), .int(offset)], decode)
  }

  public func transcript(id: Int64) throws -> Transcript? {
    try database.query(
      "SELECT \(Self.columns) FROM transcripts WHERE id = ?", [.int(Int(id))], decode).first
  }

  /// Full-text search over both the cleaned and the raw text.
  ///
  /// The query is turned into a prefix match per term rather than passed through, so
  /// a user typing an apostrophe or a stray quote gets results instead of an FTS
  /// syntax error.
  public func search(_ query: String, limit: Int = 50) throws -> [TranscriptSearchResult] {
    let expression = Self.ftsQuery(query)
    guard !expression.isEmpty else { return [] }
    return try database.query(
      """
      SELECT \(Self.columns.split(separator: ",").map { "t.\($0.trimmingCharacters(in: .whitespaces))" }.joined(separator: ", ")),
             snippet(transcripts_fts, 0, '⟦', '⟧', '…', 12)
      FROM transcripts_fts
      JOIN transcripts t ON t.id = transcripts_fts.rowid
      WHERE transcripts_fts MATCH ?
      ORDER BY rank
      LIMIT ?
      """,
      [.text(expression), .int(limit)]
    ) { row in
      TranscriptSearchResult(transcript: decode(row), snippet: row.string(22))
    }
  }

  /// Escapes user input into an FTS5 expression: each term becomes a quoted prefix
  /// match, joined with AND. Anything that is not alphanumeric is dropped rather than
  /// escaped, because there is no useful search that needs it and every one of them
  /// is a way to write a query that errors.
  static func ftsQuery(_ raw: String) -> String {
    raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map { "\"\($0)\"*" }
      .joined(separator: " AND ")
  }

  public func delete(id: Int64) throws {
    try database.run("DELETE FROM transcripts WHERE id = ?", [.int(Int(id))])
  }

  public func delete(ids: [Int64]) throws {
    guard !ids.isEmpty else { return }
    try database.transaction {
      for id in ids {
        try database.run("DELETE FROM transcripts WHERE id = ?", [.int(Int(id))])
      }
    }
  }

  /// Everything, including the derived statistics. "Delete all" that leaves your word
  /// count sitting there is not delete all.
  public func deleteAll() throws {
    try database.transaction {
      try database.execute("DELETE FROM transcripts;")
      try database.execute("DELETE FROM usage_daily;")
      try database.execute("DELETE FROM app_usage;")
    }
  }

  public func count() throws -> Int {
    try database.query("SELECT COUNT(*) FROM transcripts") { $0.int(0) }.first ?? 0
  }

  public func setFavourite(id: Int64, _ value: Bool) throws {
    try database.run(
      "UPDATE transcripts SET favourite = ? WHERE id = ?", [SQLValue(value), .int(Int(id))])
  }

  public func update(id: Int64, finalText: String) throws {
    try database.run(
      "UPDATE transcripts SET final_text = ?, word_count = ? WHERE id = ?",
      [.text(finalText), .int(Transcript.countWords(finalText)), .int(Int(id))])
  }

  /// Rows whose retained audio is older than the policy allows.
  public func transcriptsWithAudio(olderThan cutoff: Date) throws -> [Transcript] {
    try database.query(
      "SELECT \(Self.columns) FROM transcripts WHERE audio_path IS NOT NULL AND created_at < ?",
      [SQLValue(cutoff)], decode)
  }

  public func clearAudioPath(id: Int64) throws {
    try database.run("UPDATE transcripts SET audio_path = NULL WHERE id = ?", [.int(Int(id))])
  }
}
