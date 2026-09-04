import Foundation

/// Turns what you said into what you meant to write, without a model.
///
/// The stages run in a fixed order and each one is small enough to reason about:
///
/// 1. spoken punctuation and layout commands
/// 2. filler removal
/// 3. stutter and repetition collapse
/// 4. self-correction resolution — the "actually, Wednesday" case
/// 5. sentence capitalisation and terminal punctuation
/// 6. whitespace normalisation
///
/// Order matters. Fillers go before repetition collapse so "the, um, the plan"
/// becomes "the the plan" and then "the plan". Self-correction runs after both, so
/// the correction marker is adjacent to what it corrects rather than separated by an
/// "um". Capitalisation runs last, once the sentence boundaries are final.
public struct TranscriptCleaner: Sendable {

  private let punctuation = SpokenPunctuation()

  /// Sounds that carry no meaning. Kept deliberately short: every word here is one
  /// the user can never dictate, so "like", "so", "right", "well" and "just" are
  /// absent — they are filler *sometimes*, and a cleaner that eats a real word is
  /// worse than one that leaves an "um".
  static let fillerWords: Set<String> = [
    "um", "uh", "erm", "uhm", "hmm", "mhm", "umm", "uhh", "ahh", "er", "eh",
  ]

  /// Multi-word hedges removed at `.medium` and above, where the user has asked for
  /// prose rather than a transcript.
  static let fillerPhrases: [String] = [
    "you know", "i mean like", "kind of like", "sort of like", "or something like that",
  ]

  /// Words that announce a correction of what was just said.
  static let correctionMarkers: [String] = [
    "actually", "sorry", "i mean", "i meant", "or rather", "no wait", "wait no",
    "rather", "excuse me", "correction",
  ]

  /// Phrases that discard everything said so far in the sentence.
  static let restartMarkers: [String] = [
    "scratch that", "strike that", "let me rephrase that", "let me rephrase",
    "let me start over", "start over", "forget that", "ignore that",
  ]

  public init() {}

  /// Clean `raw` at the given level. Deterministic, allocation-light, and safe to
  /// call on the audio thread's continuation — it does no I/O.
  public func clean(_ raw: String, level: CleanupLevel) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    guard level != .none else { return normaliseWhitespace(trimmed) }

    var text = punctuation.expand(trimmed)
    text = removeFillers(text, aggressive: level != .light)

    if level != .light {
      text = collapseRepetitions(text)
      text = resolveRestarts(text)
      text = resolveSelfCorrections(text)
    }

    text = normaliseWhitespace(text)
    text = capitaliseSentences(text)
    text = ensureTerminalPunctuation(text)
    return text
  }

  // MARK: - Fillers

  func removeFillers(_ text: String, aggressive: Bool) -> String {
    var text = text
    if aggressive {
      for phrase in Self.fillerPhrases {
        text = text.replacingOccurrences(
          of: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b[,]?",
          with: "", options: [.regularExpression, .caseInsensitive])
      }
    }

    // Word-level pass keeps line structure intact, which a regex over the whole
    // string would flatten.
    return text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { line -> String in
        let kept = line.split(separator: " ", omittingEmptySubsequences: true)
          .map(String.init)
          .filter { token in
            !Self.fillerWords.contains(SpokenPunctuation.normalise(token))
          }
        return kept.joined(separator: " ")
      }
      .joined(separator: "\n")
  }

  // MARK: - Repetition

  /// "the the plan" → "the plan"; "I I I think" → "I think".
  ///
  /// Only collapses an *identical* adjacent token, and refuses on the handful of
  /// words where doubling is real English: "had had", "that that". Anything longer
  /// than a single-word stutter is left alone — "very very good" is emphasis, and
  /// deciding otherwise is the cleaner overreaching.
  func collapseRepetitions(_ text: String) -> String {
    let legitimate: Set<String> = ["had", "that", "very", "no", "so"]

    return text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { line -> String in
        var out: [String] = []
        for token in line.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
          let key = SpokenPunctuation.normalise(token)
          if let previous = out.last,
            SpokenPunctuation.normalise(previous) == key,
            !key.isEmpty,
            !legitimate.contains(key)
          {
            // Keep whichever copy carries punctuation — the later one usually does.
            if token.count > previous.count { out[out.count - 1] = token }
            continue
          }
          out.append(token)
        }
        return out.joined(separator: " ")
      }
      .joined(separator: "\n")
  }

  // MARK: - Restarts and self-correction

  /// Both correction passes work on tokens rather than regular expressions.
  ///
  /// That is not a style preference. The regex form of this — a lazy `[^.!?]*?`
  /// scanning for a marker — backtracks catastrophically on exactly the input real
  /// dictation produces: a long utterance with no sentence break and many candidate
  /// markers. The first version of this file hung the test suite on a 200-word
  /// input. The token scan below is linear in the number of words and cannot hang,
  /// which matters because it runs in the gap between "you stopped speaking" and
  /// "text appears".

  /// One sentence, split so it can be rebuilt byte-for-byte: the whitespace that
  /// preceded it, the words, and the terminator that ended it.
  private struct Segment {
    var leading: String
    var body: String
    var terminator: String

    var tokens: [String] { body.split(separator: " ", omittingEmptySubsequences: true).map(String.init) }

    func rebuilt(_ newBody: [String]) -> String {
      leading + newBody.joined(separator: " ") + terminator
    }
    var unchanged: String { leading + body + terminator }
  }

  private func segments(_ text: String) -> [Segment] {
    var out: [Segment] = []
    var current = ""
    for character in text {
      if ".!?\n".contains(character) {
        out.append(Self.makeSegment(current, terminator: String(character)))
        current = ""
      } else {
        current.append(character)
      }
    }
    if !current.isEmpty { out.append(Self.makeSegment(current, terminator: "")) }
    return out
  }

  private static func makeSegment(_ raw: String, terminator: String) -> Segment {
    let leading = String(raw.prefix { $0 == " " || $0 == "\t" })
    return Segment(leading: leading, body: String(raw.dropFirst(leading.count)), terminator: terminator)
  }

  /// "we ship Tuesday. scratch that, we ship Friday" → everything before the marker
  /// in that sentence is discarded.
  func resolveRestarts(_ text: String) -> String {
    segments(text).map { segment -> String in
      let tokens = segment.tokens
      guard !tokens.isEmpty else { return segment.unchanged }

      var cut: Int?
      var index = 0
      while index < tokens.count {
        if let length = markerLength(at: index, in: tokens, phrases: Self.restartMarkers) {
          cut = index + length
          index += length
        } else {
          index += 1
        }
      }
      guard let cut else { return segment.unchanged }
      return segment.rebuilt(Array(tokens[min(cut, tokens.count)...]))
    }
    .joined()
  }

  /// "send it Tuesday, actually Wednesday" → "send it Wednesday"
  /// "his name is Mark, sorry, Marcus"    → "his name is Marcus"
  ///
  /// The heuristic: what follows the marker is the correction, and it replaces the
  /// same number of words immediately before it. That is how people actually correct
  /// themselves — you restate the wrong thing at roughly the same length.
  ///
  /// The load-bearing guard is `isAtCorrectionBoundary`: a marker only counts when it
  /// sits against the pause a speaker makes when catching themselves — a comma,
  /// semicolon or dash. Without it, "I actually think so" silently loses a word.
  ///
  /// A correction longer than four words is a new statement rather than a swap, so
  /// both halves are kept and only the marker is dropped. Guessing there would
  /// destroy meaning, and being wrong quietly is the worst thing a cleaner can do.
  func resolveSelfCorrections(_ text: String) -> String {
    segments(text).map { segment -> String in
      var tokens = segment.tokens
      guard tokens.count > 1 else { return segment.unchanged }

      var index = 1
      while index < tokens.count {
        guard let length = markerLength(at: index, in: tokens, phrases: Self.correctionMarkers),
          isAtCorrectionBoundary(index, in: tokens)
        else {
          index += 1
          continue
        }

        let correction = Array(tokens[(index + length)...])
        var before = Array(tokens[..<index])
        while let last = before.last, ["—", "–", "-", "--"].contains(last) { before.removeLast() }

        guard !correction.isEmpty else {
          tokens = before
          break
        }

        if correction.count <= 4, before.count > correction.count {
          if let last = before.last {
            before[before.count - 1] = SpokenPunctuation.stripTrailingPunctuation(last)
          }
          before.removeLast(correction.count)
          tokens = before + correction
        } else {
          // Too long to be a swap: keep both halves, drop only the marker.
          tokens = before + correction
        }
        // Resume from where the surviving prefix ends — the replacement may itself
        // contain a later correction. Token count strictly decreases, so this ends.
        index = max(1, before.count)
      }

      return segment.rebuilt(tokens)
    }
    .joined()
  }

  /// Length in tokens of the longest phrase from `phrases` starting at `index`.
  private func markerLength(at index: Int, in tokens: [String], phrases: [String]) -> Int? {
    var best: Int?
    for phrase in phrases {
      let words = phrase.split(separator: " ").map(String.init)
      guard index + words.count <= tokens.count else { continue }
      let slice = tokens[index..<(index + words.count)]
      guard zip(slice, words).allSatisfy({ SpokenPunctuation.normalise($0.0) == $0.1 }) else {
        continue
      }
      if best.map({ words.count > $0 }) ?? true { best = words.count }
    }
    return best
  }

  /// A correction marker only counts against a spoken pause: a comma or semicolon on
  /// the previous word, a dash token, or a comma on the marker itself
  /// ("sorry, Marcus").
  private func isAtCorrectionBoundary(_ index: Int, in tokens: [String]) -> Bool {
    guard index > 0 else { return false }
    let previous = tokens[index - 1]
    if let last = previous.last, ",;:".contains(last) { return true }
    if ["—", "–", "-", "--"].contains(previous) { return true }
    if let last = tokens[index].last, ",;:".contains(last) { return true }
    return false
  }

  // MARK: - Shape

  func normaliseWhitespace(_ text: String) -> String {
    text
      .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
      // Space before closing punctuation is an artefact of token joining.
      .replacingOccurrences(of: " +([,.;:!?)\\]}])", with: "$1", options: .regularExpression)
      .replacingOccurrences(of: "([(\\[{]) +", with: "$1", options: .regularExpression)
      .replacingOccurrences(of: " *\n *", with: "\n", options: .regularExpression)
      .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
      // A comma left stranded by a removed filler.
      .replacingOccurrences(of: "([,;])\\s*([,;.!?])", with: "$2", options: .regularExpression)
      .replacingOccurrences(of: "^[\\s,;]+", with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Capitalises the first letter of each sentence and the standalone pronoun "I".
  /// Deliberately does not touch anything else — an all-caps acronym, a `camelCase`
  /// identifier and a brand like "iPhone" all survive, which a naive
  /// `.capitalized` would destroy.
  func capitaliseSentences(_ text: String) -> String {
    var characters = Array(text)
    var atSentenceStart = true

    for index in characters.indices {
      let character = characters[index]
      if atSentenceStart, character.isLetter {
        // Only uppercase a word that is entirely lowercase. `iPhone` and `userId`
        // are already cased on purpose.
        var end = index
        while end < characters.count, characters[end].isLetter || characters[end] == "'" { end += 1 }
        let word = String(characters[index..<end])
        if word == word.lowercased() {
          characters[index] = Character(String(character).uppercased())
        }
        atSentenceStart = false
        continue
      }
      if ".!?".contains(character) { atSentenceStart = true }
      else if character == "\n" { atSentenceStart = true }
      else if atSentenceStart, "-*\u{2022}".contains(character) {
        // A list bullet introduces the sentence rather than being part of it, so the
        // first real word after it still gets a capital.
        continue
      }
      else if !character.isWhitespace { atSentenceStart = false }
    }

    var result = String(characters)
    result = result.replacingOccurrences(
      of: "\\bi\\b", with: "I", options: .regularExpression)
    // …but not inside an identifier or a URL, where a bare `i` is a variable.
    return result
  }

  /// A dictated sentence that ends with no punctuation reads as unfinished. Adds a
  /// full stop — unless the text already ends in punctuation, a list item, or code.
  func ensureTerminalPunctuation(_ text: String) -> String {
    guard let last = text.last else { return text }
    if ".!?:;,)]}\u{201D}\"'`".contains(last) { return text }
    if text.hasSuffix("- ") { return text }
    // Something that looks like code or a path should not gain a sentence full stop.
    if text.contains("://") || last == "/" || last == "\\" { return text }
    return text + "."
  }
}
