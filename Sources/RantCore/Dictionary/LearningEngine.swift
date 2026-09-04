import Foundation

/// How the learning feature is configured. Every default here is the cautious one:
/// the feature is off, the window is short, and a correction that looks nothing like
/// what Rant wrote is never offered as a rule.
public struct LearningSettings: Equatable, Sendable, Codable {
  /// Opt-in. While this is false the engine keeps nothing in memory and writes
  /// nothing to the database — see `noteInsertion`.
  public var enabled: Bool
  /// How long after an insertion an edit is still attributable to that insertion.
  /// Past this the user has moved on, and whatever changed is their own writing.
  public var observationWindow: TimeInterval
  /// The largest substitution that can become a dictionary rule, in words on either
  /// side. A dictionary entry is for a term the recogniser mishears, not for a
  /// sentence the user rewrote.
  public var maximumWords: Int
  /// The longest either side of the rule may be, in characters. Same reasoning as
  /// `maximumWords`, and it also bounds the edit-distance work.
  public var maximumCharacters: Int
  /// Below this a candidate is not proposed and not stored. A correction that looks
  /// nothing like what Rant wrote is a rewrite, and turning a rewrite into a
  /// permanent replacement rule would corrupt every later dictation.
  public var minimumConfidence: Double

  public init(
    enabled: Bool = false,
    observationWindow: TimeInterval = 30,
    maximumWords: Int = 3,
    maximumCharacters: Int = 64,
    minimumConfidence: Double = 0.5
  ) {
    self.enabled = enabled
    self.observationWindow = observationWindow
    self.maximumWords = maximumWords
    self.maximumCharacters = maximumCharacters
    self.minimumConfidence = minimumConfidence
  }

  /// The shipping default: off.
  public static let `default` = LearningSettings()
}

/// A dictionary rule Rant thinks it has spotted, waiting for the user to say yes.
///
/// A candidate is inert. Nothing in the dictation pipeline reads this table; the only
/// way one can affect what Rant writes is `LearningEngine.accept(id:)`, which creates
/// an ordinary `DictionaryEntry` the user can then see, edit and delete like any
/// other. That split is the point: learning that silently installs permanent rules is
/// indistinguishable, from the user's side, from an app that has started getting
/// words wrong for no reason.
public struct LearningCandidate: Equatable, Sendable, Identifiable {
  public enum Status: String, Sendable, Codable, CaseIterable {
    case pending, accepted, rejected
  }

  public var id: Int64?
  public var observedAt: Date
  /// Exactly what Rant inserted. Rant's own output, never the document around it.
  public var insertedText: String
  /// The same span after the user's edit, bounded to the region Rant wrote plus the
  /// few words the correction grew or shrank it by.
  public var correctedText: String
  /// The proposed rule: what Rant wrote…
  public var spoken: String
  /// …and what the user changed it to.
  public var written: String
  public var occurrences: Int
  public var status: Status
  public var appBundleID: String?

  public init(
    id: Int64? = nil,
    observedAt: Date,
    insertedText: String,
    correctedText: String,
    spoken: String,
    written: String,
    occurrences: Int = 1,
    status: Status = .pending,
    appBundleID: String? = nil
  ) {
    self.id = id
    self.observedAt = observedAt
    self.insertedText = insertedText
    self.correctedText = correctedText
    self.spoken = spoken
    self.written = written
    self.occurrences = occurrences
    self.status = status
    self.appBundleID = appBundleID
  }

  /// Derived rather than stored, so a change to the scoring rule applies to
  /// candidates that already exist instead of leaving stale numbers in the table.
  public var confidence: Double {
    LearningEngine.confidence(spoken: spoken, written: written, occurrences: occurrences)
  }
}

/// Watches for the user correcting Rant by hand, and turns a correction into a
/// *proposed* dictionary rule.
///
/// The feature exists because the commonest complaint about dictation is a name it
/// will never spell right, and the fix — adding a dictionary entry — is something
/// almost nobody does. Noticing the correction the user has already made by hand is
/// the cheapest way to offer it.
///
/// It is also the feature with the most obvious ways to go wrong, so the design is
/// built around four limits rather than around accuracy:
///
/// - It is **off** until the user turns it on. Disabled, `noteInsertion` retains
///   nothing, so there is no buffer of recent dictations to leak.
/// - It only ever keeps **what Rant inserted** and the span that changed. The engine
///   is handed the focused field's text to locate the insertion in, but what it
///   persists is bounded to Rant's own output plus the correction — never the
///   surrounding document, which in a mail client is somebody's private
///   correspondence.
/// - The window is bounded in **time and scope**. An edit in another app, in another
///   field, or a minute later is not evidence about the insertion.
/// - The result is a **proposal**, never a rule. See `LearningCandidate`.
///
/// The engine reads no clock and owns no timer: every entry point takes the time it
/// happened at, which is what lets the tests drive the window exactly rather than
/// sleeping through it.
public actor LearningEngine {
  private let database: Database
  private let log = RantLog("Learning")
  public private(set) var settings: LearningSettings

  /// What Rant last inserted, and where. In memory only, replaced by the next
  /// insertion, and dropped the moment the window closes.
  private var pending: Observation?

  /// Which field an insertion went into. App plus role plus label, because the
  /// accessibility API gives us no stable identity for "the same text field" and this
  /// triple is the closest honest approximation. Getting it wrong costs a missed
  /// candidate, which is the harmless direction.
  struct FieldIdentity: Equatable, Sendable {
    var appBundleID: String?
    var fieldRole: String?
    var fieldLabel: String?

    init(_ context: TranscriptionContext) {
      appBundleID = context.appBundleID
      fieldRole = context.fieldRole
      fieldLabel = context.fieldLabel
    }
  }

  struct Observation: Equatable, Sendable {
    var insertedText: String
    var field: FieldIdentity
    var at: Date
  }

  public init(database: Database, settings: LearningSettings = .default) {
    self.database = database
    self.settings = settings
  }

  public func update(settings: LearningSettings) {
    self.settings = settings
    // Turning the feature off drops anything already in flight, so the toggle takes
    // effect on the insertion that is on screen now rather than on the next one.
    if !settings.enabled { pending = nil }
  }

  /// True when an insertion is still inside its window. Exposed so the UI can say
  /// "watching for corrections" honestly, and so the tests can assert that a disabled
  /// engine retained nothing at all.
  public var isObserving: Bool { pending != nil }

  // MARK: - Observing

  /// Records that Rant has just inserted `text` into the focused field.
  ///
  /// Called from the injection path. When the feature is off, or the field is a
  /// secure one, this does nothing rather than recording and filtering later — the
  /// cheapest way to be sure a password field never reaches the diff is for its text
  /// never to be held in the first place.
  public func noteInsertion(_ text: String, context: TranscriptionContext, at now: Date) {
    guard settings.enabled else { return }
    guard !context.isSecureField else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    pending = Observation(insertedText: trimmed, field: FieldIdentity(context), at: now)
  }

  /// Offers the current contents of the focused field as a possible correction.
  ///
  /// Returns a candidate when the edit turned out to be a word-level substitution
  /// inside the text Rant wrote, and nil for everything else — which is most edits. A
  /// pair the user has already rejected returns nil too: they have answered that
  /// question, and asking again is nagging.
  @discardableResult
  public func observeEdit(
    fieldText: String, context: TranscriptionContext, at now: Date
  ) throws -> LearningCandidate? {
    guard settings.enabled else { return nil }
    guard !context.isSecureField else { return nil }
    guard let observation = pending else { return nil }

    // Time. Past the window, the field belongs to the user again.
    guard now >= observation.at,
      now.timeIntervalSince(observation.at) <= settings.observationWindow
    else {
      pending = nil
      return nil
    }
    // Scope. A different app or a different field is a different piece of writing.
    guard FieldIdentity(context) == observation.field else { return nil }

    let insertedWords = TextDiff.words(observation.insertedText)
    let fieldWords = TextDiff.words(fieldText)
    guard
      let found = Self.substitution(
        inserted: insertedWords, field: fieldWords, maximumWords: settings.maximumWords)
    else { return nil }

    let spoken = found.spoken.joined(separator: " ")
    let written = found.written.joined(separator: " ")
    guard Self.isPlausibleRule(spoken: spoken, written: written, settings: settings) else {
      return nil
    }

    // Only the region Rant wrote, as the user now has it. The document around it is
    // never joined back up and never stored.
    let correctedText = fieldWords[found.region].joined(separator: " ")

    // A single sighting of a wildly different phrase is not evidence. Score it before
    // anything is written, so a low-confidence pair leaves no trace either.
    let existing = try candidate(spoken: spoken, written: written)
    if existing == nil,
      Self.confidence(spoken: spoken, written: written, occurrences: 1)
        < settings.minimumConfidence
    {
      return nil
    }

    pending = nil
    guard
      let stored = try record(
        insertedText: observation.insertedText, correctedText: correctedText,
        spoken: spoken, written: written, at: now, appBundleID: context.appBundleID)
    else { return nil }

    log.info("learning candidate \(stored.status.rawValue), seen \(stored.occurrences) times")
    return stored.status == .pending ? stored : nil
  }

  // MARK: - Locating the correction

  /// Finds the word-level substitution between what Rant inserted and what the field
  /// now holds, along with the region of the field the insertion occupies.
  ///
  /// The field may be an entire document, so the insertion is located first and only
  /// that region is compared. Locating is done by anchor voting: every inserted word
  /// that is not repeated all over the field proposes an offset, and the offsets with
  /// the most votes are tried in turn. That costs one linear pass over the field,
  /// which matters because this runs while the user is typing — a scan comparing every
  /// position against every position would turn a long email into a visible stall.
  ///
  /// Several offsets are tried rather than only the winner, because the correction
  /// itself skews the vote: shortening "super base" to "Supabase" shifts every word
  /// after it by one, so the words *following* the change vote for an offset one
  /// earlier than the true start, and they can outvote the words before it. Taking
  /// that offset would drag a word of the surrounding document into the region and the
  /// correction would be thrown away as a rewrite — which is how this was found.
  ///
  /// The comparison itself is `TextDiff`, so a substitution surrounded by unchanged
  /// words is found without this file re-implementing a diff. The run pattern is then
  /// required to be exactly one deletion beside one insertion: two separate changes
  /// mean the user is rewriting rather than correcting a term, and a lone insertion or
  /// deletion is not a replacement rule at all.
  static func substitution(
    inserted: [String], field: [String], maximumWords: Int
  ) -> (spoken: [String], written: [String], region: Range<Int>)? {
    guard !inserted.isEmpty, !field.isEmpty else { return nil }
    var tried: Set<Int> = []
    for offset in alignmentOffsets(inserted: inserted, field: field) {
      let start = max(0, offset)
      guard tried.insert(start).inserted else { continue }
      if let found = substitution(
        inserted: inserted, field: field, startingAt: start, maximumWords: maximumWords)
      {
        return found
      }
    }
    return nil
  }

  /// One attempt, at a known start. Kept separate so trying a second offset costs a
  /// second bounded scan rather than a second pass over the field.
  static func substitution(
    inserted: [String], field: [String], startingAt start: Int, maximumWords: Int
  ) -> (spoken: [String], written: [String], region: Range<Int>)? {
    guard start < field.count else { return nil }

    // The corrected region can differ in length from the insertion only by the size of
    // the substitution, so the end is searched in a window of that size rather than
    // over the whole field. The end preserving the longest common suffix is the one
    // that leaves the change in the middle, where it belongs.
    let expectedEnd = start + inserted.count
    let lowest = max(start, expectedEnd - maximumWords)
    let highest = min(field.count, expectedEnd + maximumWords)
    guard lowest <= highest else { return nil }

    var bestEnd = lowest
    var bestSuffix = -1
    for end in lowest...highest {
      var matched = 0
      while matched < inserted.count, end - 1 - matched >= start,
        inserted[inserted.count - 1 - matched] == field[end - 1 - matched]
      {
        matched += 1
      }
      if matched > bestSuffix {
        bestSuffix = matched
        bestEnd = end
      }
    }

    let region = start..<bestEnd
    guard !region.isEmpty else { return nil }

    let runs = TextDiff.diff(original: inserted, result: Array(field[region]))
    var removed: (index: Int, words: [String])?
    var added: (index: Int, words: [String])?
    for (index, run) in runs.enumerated() {
      switch run.operation {
      case .equal:
        continue
      case .delete:
        guard removed == nil else { return nil }
        removed = (index, run.words)
      case .insert:
        guard added == nil else { return nil }
        added = (index, run.words)
      }
    }
    guard let removed, let added else { return nil }
    guard abs(removed.index - added.index) == 1 else { return nil }
    guard removed.words.count <= maximumWords, added.words.count <= maximumWords else {
      return nil
    }
    return (removed.words, added.words, region)
  }

  /// Words occurring more often than this in the field are ignored as anchors: they
  /// are filler, they vote for every offset equally, and letting them in is both
  /// slower and less accurate.
  static let maximumAnchorOccurrences = 4

  /// How many offsets are worth trying. Small on purpose: each one costs another
  /// bounded scan and another diff, and past the first few the votes are noise.
  static let maximumOffsetCandidates = 4

  /// Where the insertion might start in the field, best-supported first.
  static func alignmentOffsets(inserted: [String], field: [String]) -> [Int] {
    var positions: [String: [Int]] = [:]
    positions.reserveCapacity(field.count)
    for (index, word) in field.enumerated() {
      positions[word, default: []].append(index)
    }

    var votes: [Int: Int] = [:]
    for (index, word) in inserted.enumerated() {
      guard let found = positions[word], found.count <= maximumAnchorOccurrences else { continue }
      for position in found { votes[position - index, default: 0] += 1 }
    }

    // Most votes wins; the earliest offset breaks a tie, so the answer does not depend
    // on the order a dictionary happens to iterate in.
    return votes.sorted {
      $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
    }
    .prefix(maximumOffsetCandidates).map(\.key)
  }

  // MARK: - Scoring

  /// Whether the pair could sensibly be a dictionary entry at all.
  static func isPlausibleRule(
    spoken: String, written: String, settings: LearningSettings
  ) -> Bool {
    guard !spoken.isEmpty, !written.isEmpty, spoken != written else { return false }
    guard spoken.count <= settings.maximumCharacters,
      written.count <= settings.maximumCharacters
    else { return false }
    // A rule made only of punctuation would fire on every sentence.
    guard spoken.contains(where: { $0.isLetter || $0.isNumber }),
      written.contains(where: { $0.isLetter || $0.isNumber })
    else { return false }
    return true
  }

  /// How much the pair looks like a mishearing rather than a rewrite, nudged upward by
  /// having been seen before.
  ///
  /// Similarity carries most of the weight because it is the signal that separates the
  /// two cases: "super base" against "Supabase" is one term heard wrongly, while
  /// "Thursday" against "the following Tuesday" is the user changing their mind, and
  /// installing that as a replacement rule would rewrite every future Thursday. The
  /// weighting is set so that the default floor of 0.5 needs the two forms to be at
  /// least half the same characters — near enough that the user could plausibly have
  /// said one and had it written as the other.
  public static func confidence(spoken: String, written: String, occurrences: Int) -> Double {
    let base = 0.2 + 0.6 * similarity(spoken, written)
    return min(1.0, base + 0.15 * Double(max(0, occurrences - 1)))
  }

  /// Normalised edit distance, case-insensitively, over two strings already capped at
  /// a few dozen characters — so the quadratic table is a few thousand cells rather
  /// than a reason to reach for something cleverer.
  static func similarity(_ first: String, _ second: String) -> Double {
    let a = Array(first.lowercased())
    let b = Array(second.lowercased())
    let longest = max(a.count, b.count)
    guard longest > 0 else { return 1 }
    if a.isEmpty { return 0 }
    if b.isEmpty { return 0 }

    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
      current[0] = i
      for j in 1...b.count {
        let cost = a[i - 1] == b[j - 1] ? 0 : 1
        current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
      }
      swap(&previous, &current)
    }
    return max(0, 1 - Double(previous[b.count]) / Double(longest))
  }

  // MARK: - Storage

  private static let columns = """
    id, observed_at, inserted_text, corrected_text, spoken, written, occurrences, status,
    app_bundle_id
    """

  private static func decode(_ row: Row) -> LearningCandidate {
    LearningCandidate(
      id: Int64(row.int(0)), observedAt: row.date(1), insertedText: row.string(2),
      correctedText: row.string(3), spoken: row.string(4), written: row.string(5),
      occurrences: row.int(6),
      status: LearningCandidate.Status(rawValue: row.string(7)) ?? .pending,
      appBundleID: row.stringOrNil(8))
  }

  /// Upserts on the (spoken, written) pair, so mishearing the same term a second time
  /// strengthens the existing proposal instead of filling the list with copies.
  private func record(
    insertedText: String, correctedText: String, spoken: String, written: String,
    at now: Date, appBundleID: String?
  ) throws -> LearningCandidate? {
    try database.run(
      """
      INSERT INTO learning_candidates
        (observed_at, inserted_text, corrected_text, spoken, written, occurrences, status,
         app_bundle_id)
      VALUES (?,?,?,?,?,1,'pending',?)
      ON CONFLICT(spoken, written) DO UPDATE SET
        occurrences = occurrences + 1,
        observed_at = excluded.observed_at,
        inserted_text = excluded.inserted_text,
        corrected_text = excluded.corrected_text
      """,
      [
        SQLValue(now), .text(insertedText), .text(correctedText), .text(spoken), .text(written),
        SQLValue(appBundleID),
      ])
    return try candidate(spoken: spoken, written: written)
  }

  func candidate(spoken: String, written: String) throws -> LearningCandidate? {
    try database.query(
      "SELECT \(Self.columns) FROM learning_candidates WHERE spoken = ? AND written = ?",
      [.text(spoken), .text(written)], Self.decode
    ).first
  }

  /// The proposals worth showing, strongest first. The confidence floor is applied
  /// here as well as at the point of writing, so raising it hides candidates that were
  /// stored under a laxer setting rather than requiring a migration.
  public func candidates(
    status: LearningCandidate.Status = .pending, limit: Int = 50
  ) throws -> [LearningCandidate] {
    let floor = settings.minimumConfidence
    return try database.query(
      """
      SELECT \(Self.columns) FROM learning_candidates
      WHERE status = ? ORDER BY occurrences DESC, observed_at DESC LIMIT ?
      """,
      [.text(status.rawValue), .int(limit)], Self.decode
    ).filter { $0.status != .pending || $0.confidence >= floor }
  }

  public func candidate(id: Int64) throws -> LearningCandidate? {
    try database.query(
      "SELECT \(Self.columns) FROM learning_candidates WHERE id = ?", [.int(Int(id))], Self.decode
    ).first
  }

  /// Turns a proposal into an ordinary dictionary entry. The one place where anything
  /// learned starts affecting what Rant writes, and it is only ever reached from a
  /// button the user pressed.
  @discardableResult
  public func accept(id: Int64) throws -> DictionaryEntry? {
    guard let candidate = try candidate(id: id) else { return nil }
    let entry = DictionaryEntry(
      spoken: candidate.spoken, written: candidate.written, kind: .replacement,
      category: "Learned", source: "learned")
    let added = try VocabularyStore(database: database).addOrIgnore(entry)
    try setStatus(.accepted, id: id)
    return added ? entry : nil
  }

  /// Declines a proposal permanently. Later sightings still count towards its
  /// occurrences — useful if the user changes their mind — but it is never proposed
  /// again.
  public func reject(id: Int64) throws {
    try setStatus(.rejected, id: id)
  }

  private func setStatus(_ status: LearningCandidate.Status, id: Int64) throws {
    try database.run(
      "UPDATE learning_candidates SET status = ? WHERE id = ?",
      [.text(status.rawValue), .int(Int(id))])
  }

  public func count() throws -> Int {
    try database.query("SELECT COUNT(*) FROM learning_candidates") { $0.int(0) }.first ?? 0
  }

  /// Forgets everything learned. The feature is only defensible if undoing it is this
  /// easy.
  public func deleteAll() throws {
    pending = nil
    try database.execute("DELETE FROM learning_candidates;")
  }
}
