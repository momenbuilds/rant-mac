import Foundation

/// Turns spoken punctuation and layout commands into the characters they name.
///
/// The hard part is not the substitution, it is knowing when the speaker meant the
/// mark and when they meant the word. "Add a period to the end" must not become
/// "Add a . to the end", and "the comma separated list" must stay prose. The rule
/// used here: a punctuation word counts as a command only when it is *not* preceded
/// by an article or preposition that makes it a noun. That single check removes
/// almost all the false positives, and the remaining ones are in the test file so
/// the tradeoff is visible rather than folklore.
public struct SpokenPunctuation: Sendable {

  /// Words that turn the following punctuation word back into a noun.
  /// "a period", "the comma", "with a dash", "no colon".
  private static let nounMarkers: Set<String> = [
    "a", "an", "the", "this", "that", "these", "those", "any", "no", "another",
    "one", "two", "three", "some", "each", "every", "its", "his", "her", "their",
    "my", "your", "our", "double", "triple",
  ]

  /// Longest-first so "question mark" wins over "mark", and "new paragraph" over "new".
  private static let replacements: [(phrase: String, output: Output)] = {
    let table: [(String, Output)] = [
      // Layout
      ("new paragraph", .paragraph),
      ("next paragraph", .paragraph),
      ("new line", .newline),
      ("next line", .newline),
      ("line break", .newline),
      // Terminators
      ("question mark", .glued("?")),
      ("exclamation mark", .glued("!")),
      ("exclamation point", .glued("!")),
      ("full stop", .glued(".")),
      ("period", .glued(".")),
      ("comma", .glued(",")),
      ("semicolon", .glued(";")),
      ("semi colon", .glued(";")),
      ("colon", .glued(":")),
      ("ellipsis", .glued("…")),
      ("dot dot dot", .glued("…")),
      // Dashes
      ("em dash", .spaced("—")),
      ("en dash", .spaced("–")),
      ("hyphen", .tight("-")),
      ("dash", .spaced("—")),
      // Brackets and quotes
      ("open paren", .opening("(")),
      ("open parenthesis", .opening("(")),
      ("close paren", .glued(")")),
      ("close parenthesis", .glued(")")),
      ("open bracket", .opening("[")),
      ("close bracket", .glued("]")),
      ("open brace", .opening("{")),
      ("close brace", .glued("}")),
      ("open quote", .opening("\u{201C}")),
      ("close quote", .glued("\u{201D}")),
      ("open quotes", .opening("\u{201C}")),
      ("close quotes", .glued("\u{201D}")),
      // Symbols that are genuinely useful when dictating into a terminal or an editor
      ("at sign", .tight("@")),
      ("hash tag", .tight("#")),
      ("hash sign", .tight("#")),
      ("percent sign", .glued("%")),
      ("dollar sign", .tight("$")),
      ("ampersand", .word("&")),
      ("asterisk", .tight("*")),
      ("underscore", .tight("_")),
      ("forward slash", .tight("/")),
      ("back slash", .tight("\\")),
      ("backslash", .tight("\\")),
      ("plus sign", .word("+")),
      ("equals sign", .word("=")),
      ("greater than sign", .word(">")),
      ("less than sign", .word("<")),
      // Lists
      ("bullet point", .bullet),
      ("next bullet", .bullet),
      ("new bullet", .bullet),
    ]
    return table.sorted { $0.0.split(separator: " ").count > $1.0.split(separator: " ").count }
  }()

  /// How a replacement joins its neighbours.
  enum Output: Equatable {
    /// Attaches to the previous word with no space: `hello,`
    case glued(String)
    /// Space on both sides: `a — b`
    case spaced(String)
    /// No space on either side: `user_id`
    case tight(String)
    /// Space before, none after: `(hello`
    case opening(String)
    /// Behaves like an ordinary word.
    case word(String)
    case newline
    case paragraph
    case bullet
  }

  public init() {}

  /// Expand spoken punctuation in `text`.
  ///
  /// Works on a token list rather than by regex substitution because the decision is
  /// contextual — the previous token is what tells you whether "period" is a mark or
  /// a noun — and because gluing punctuation to the preceding word is a join
  /// operation, not a replacement.
  public func expand(_ text: String) -> String {
    var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard !tokens.isEmpty else { return text }

    var out: [String] = []
    out.reserveCapacity(tokens.count)
    var index = 0

    while index < tokens.count {
      var matched = false

      for (phrase, output) in Self.replacements {
        let words = phrase.split(separator: " ").map(String.init)
        guard index + words.count <= tokens.count else { continue }
        let slice = tokens[index..<(index + words.count)]
        guard zip(slice, words).allSatisfy({ Self.normalise($0.0) == $0.1 }) else { continue }

        // "a period" is a noun phrase, not an instruction.
        if let previous = out.last, Self.nounMarkers.contains(Self.normalise(previous)) {
          continue
        }
        // Trailing punctuation on the spoken word means the provider already
        // punctuated it — "period." is the provider's guess, still a command.
        emit(output, into: &out)
        index += words.count
        matched = true
        break
      }

      if !matched {
        out.append(tokens[index])
        index += 1
      }
    }

    tokens = out
    return tokens.joined(separator: " ")
      // Collapse the marker spacing introduced above.
      .replacingOccurrences(of: " \u{0}GLUE\u{0} ", with: "")
      .replacingOccurrences(of: "\u{0}GLUE\u{0}", with: "")
  }

  /// Emits one replacement, joining it to what came before according to its kind.
  private func emit(_ output: Output, into out: inout [String]) {
    switch output {
    case .glued(let mark):
      if var last = out.popLast() {
        last = Self.stripTrailingPunctuation(last)
        out.append(last + mark)
      } else {
        out.append(mark)
      }
    case .tight(let mark):
      if let last = out.popLast() {
        out.append(last + mark + "\u{0}GLUE\u{0}")
      } else {
        out.append(mark + "\u{0}GLUE\u{0}")
      }
    case .opening(let mark):
      out.append(mark + "\u{0}GLUE\u{0}")
    case .spaced(let mark), .word(let mark):
      out.append(mark)
    case .newline:
      if var last = out.popLast() {
        last = Self.stripTrailingPunctuation(last)
        out.append(last + "\n")
      } else {
        out.append("\n")
      }
    case .paragraph:
      if var last = out.popLast() {
        last = Self.stripTrailingPunctuation(last)
        out.append(last + "\n\n")
      } else {
        out.append("\n\n")
      }
    case .bullet:
      if var last = out.popLast() {
        last = Self.stripTrailingPunctuation(last)
        out.append(last + "\n- ")
      } else {
        out.append("- ")
      }
    }
  }

  /// Lowercased, stripped of the punctuation a speech provider may have already
  /// attached, so "Period." and "period" are the same token.
  static func normalise(_ token: String) -> String {
    token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\u{201C}\u{201D}\"'"))
  }

  /// The provider often writes "Tuesday, comma" — the comma it guessed is redundant
  /// once we honour the spoken one.
  static func stripTrailingPunctuation(_ token: String) -> String {
    var value = token
    while let last = value.last, ",;:".contains(last) { value.removeLast() }
    return value
  }
}
