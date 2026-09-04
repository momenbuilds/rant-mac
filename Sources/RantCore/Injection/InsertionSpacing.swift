import Foundation

/// Works out how dictated text should join the text already around the cursor.
///
/// This is the small detail that separates "usable" from "infuriating". Dictate into
/// the middle of a sentence and you want a leading space; dictate at the start of an
/// empty field and you do not. Dictate after "Hello," and the next word should not be
/// capitalised; dictate after "Hello." and it should.
///
/// Pure, so every case is a one-line test rather than something you discover by
/// dictating into TextEdit forty times.
public struct InsertionSpacing: Sendable {

  public struct Plan: Equatable, Sendable {
    public var text: String
    public var addedLeadingSpace: Bool
    public var addedTrailingSpace: Bool

    public init(text: String, addedLeadingSpace: Bool = false, addedTrailingSpace: Bool = false) {
      self.text = text
      self.addedLeadingSpace = addedLeadingSpace
      self.addedTrailingSpace = addedTrailingSpace
    }
  }

  public init() {}

  /// Produce the exact string to insert at the cursor.
  ///
  /// - Parameters:
  ///   - text: the cleaned transcript.
  ///   - before: text immediately preceding the insertion point, if readable.
  ///   - after: text immediately following it, if readable.
  ///
  /// When `before` and `after` are nil — which is the common case, because plenty of
  /// apps do not expose their text through Accessibility — we insert the text
  /// unchanged. Guessing a leading space we cannot justify would put a stray space
  /// at the start of every empty field.
  public func plan(text: String, before: String?, after: String?) -> Plan {
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !body.isEmpty else { return Plan(text: "") }

    var result = body
    var addedLeading = false
    var addedTrailing = false

    if let before, let lastCharacter = before.last {
      if Self.needsSpace(after: lastCharacter) {
        result = " " + result
        addedLeading = true
      }
      // Continuing a sentence: "I said" + "hello" should not become "I said Hello".
      if Self.continuesASentence(after: before) {
        result = Self.lowercasingFirstWord(result, leadingSpace: addedLeading)
      }
    }

    if let after, let nextCharacter = after.first {
      if Self.needsSpace(before: nextCharacter) {
        result += " "
        addedTrailing = true
      }
    }

    return Plan(text: result, addedLeadingSpace: addedLeading, addedTrailingSpace: addedTrailing)
  }

  /// A space is needed after anything that is not already whitespace and not an
  /// opening bracket or an open quote.
  static func needsSpace(after character: Character) -> Bool {
    if character.isWhitespace { return false }
    if "([{\u{201C}\u{2018}\"'".contains(character) { return false }
    // A hyphen, slash or sigil mid-token means the user is building one word:
    // `well-` + `known`, `@` + `handle`. A full stop deliberately is *not* in this
    // set — "main." + "swift" would benefit, but "That was fine." + "Hello" is far
    // more common, and getting sentence spacing wrong is the more visible error.
    if "-/_@#$".contains(character) { return false }
    return true
  }

  /// A space is needed before the following text unless it starts with punctuation
  /// that should hug the inserted words, or is already whitespace.
  static func needsSpace(before character: Character) -> Bool {
    if character.isWhitespace { return false }
    if ".,;:!?)]}\u{201D}\u{2019}".contains(character) { return false }
    return true
  }

  /// True when the preceding text left a sentence open — the last non-space
  /// character is a letter, a digit, or a comma-like mark.
  static func continuesASentence(after before: String) -> Bool {
    // A trailing newline means we are starting a fresh line, so the capital stays.
    // This has to be checked before skipping whitespace, or the newline is invisible.
    if before.drop(while: { $0 == " " || $0 == "\t" }).isEmpty == false,
      let lastNonSpace = before.reversed().first(where: { $0 != " " && $0 != "\t" }),
      lastNonSpace.isNewline
    {
      return false
    }
    guard let last = before.reversed().first(where: { !$0.isWhitespace }) else { return false }
    if ".!?".contains(last) { return false }
    return last.isLetter || last.isNumber || ",;:-\u{2014}".contains(last)
  }

  /// Lowercases only the first word, and only when it looks like ordinary prose —
  /// an acronym, a proper noun with internal capitals, or a `camelCase` identifier
  /// is left exactly as it is.
  static func lowercasingFirstWord(_ text: String, leadingSpace: Bool) -> String {
    let offset = leadingSpace ? 1 : 0
    let body = String(text.dropFirst(offset))
    guard let first = body.first, first.isUppercase else { return text }

    let firstWord = body.prefix { $0.isLetter || $0 == "'" }
    // "API", "iPhone", "McDonald" and "userId" all keep their casing; only a word
    // that is capitalised-then-lowercase gets folded.
    let rest = firstWord.dropFirst()
    guard !rest.isEmpty, rest.allSatisfy({ $0.isLowercase || $0 == "'" }) else { return text }
    // A single capital letter word like "I" stays.
    guard firstWord.count > 1 else { return text }
    // A known proper noun cannot be detected here without a dictionary, so we accept
    // the occasional "…and marcus said" — it is rarer, and less jarring, than
    // "I said Hello" in the middle of a sentence.
    let prefix = leadingSpace ? " " : ""
    return prefix + first.lowercased() + String(body.dropFirst())
  }
}
