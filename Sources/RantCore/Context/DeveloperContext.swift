import Foundation

/// The dictation repairs that only make sense in front of code.
///
/// Speech recognisers are trained on prose, so they return prose: "user ID" for
/// `userId`, "max retries" for `MAX_RETRIES`, "main dot swift" for `main.swift`. In a
/// document that is the right answer. In an editor or an AI chat about a repository it
/// is wrong every single time, and the user ends up retyping the identifier they just
/// dictated.
///
/// Three rules, in three pure functions:
///
/// 1. harvest the identifiers that are already on screen,
/// 2. repair a dictated identifier to the casing one of them uses,
/// 3. expand a spoken file reference into the `@file` form an assistant expects.
///
/// **Nothing here reads the disk.** Not the working directory, not a project file, not
/// a `.git` folder. Every symbol comes from text the caller already had — the visible
/// window, via the accessibility snapshot the user consented to. That is a deliberate
/// boundary: a dictation app that crawls your repository to improve its guesses has
/// become something the user did not install, and the guarantee is worth more than the
/// extra accuracy. It is also why these are static functions over strings: there is no
/// file handle for them to reach for.
public struct DeveloperContext: Sendable {

  public init() {}

  // MARK: - Harvesting

  /// File extensions Rant will recognise in a spoken file reference. A closed list,
  /// because the test for "is this a file name?" has to be something better than "it
  /// contains a dot" — otherwise "version one dot two" becomes a file.
  public static let fileExtensions: Set<String> = [
    "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "rs", "go", "java", "kt", "kts",
    "py", "rb", "php", "cs", "ts", "tsx", "js", "jsx", "mjs", "vue", "svelte",
    "json", "yml", "yaml", "toml", "ini", "xml", "plist", "lock",
    "md", "mdx", "txt", "csv", "sql", "sh", "zsh", "bash", "fish",
    "html", "css", "scss", "less", "gradle", "make", "dockerfile", "env",
  ]

  /// The identifiers visible in a window, newest-first in reading order, deduplicated.
  ///
  /// The filter is conservative on purpose. Only a token that is *shaped* like an
  /// identifier gets in — a case boundary, an underscore, or a known file extension —
  /// because the cost of a wrong entry is not a missed repair but a corrupted word:
  /// admit the plain English "text" and every "text" the user dictates afterwards
  /// risks being rewritten.
  public static func identifiers(in text: String, limit: Int = 400) -> [String] {
    var seen: Set<String> = []
    var found: [String] = []

    for token in tokenise(text) {
      guard looksLikeIdentifier(token) else { continue }
      let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "._"))
      guard trimmed.count >= 2, trimmed.count <= 64 else { continue }
      guard !seen.contains(token) else { continue }
      seen.insert(token)
      found.append(token)
      if found.count >= limit { break }
    }
    return found
  }

  /// True when a token is shaped like something a programmer wrote rather than
  /// something a person said.
  public static func looksLikeIdentifier(_ token: String) -> Bool {
    guard let first = token.first, first.isLetter || first == "_" else { return false }
    if token.contains("_") { return true }
    if let dot = token.lastIndex(of: "."), dot != token.startIndex {
      let ext = String(token[token.index(after: dot)...]).lowercased()
      if fileExtensions.contains(ext) { return true }
    }
    // A lowercase letter followed by an uppercase one: camelCase, or PascalCase after
    // its first character. A word that is merely capitalised does not qualify.
    var previousWasLower = false
    for character in token {
      if character.isUppercase, previousWasLower { return true }
      previousWasLower = character.isLowercase
    }
    return false
  }

  /// Splits on everything that cannot appear inside an identifier. Linear, and it
  /// keeps dots so file names survive as one token.
  static func tokenise(_ text: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    for character in text {
      if character.isLetter || character.isNumber || character == "_" || character == "." {
        current.append(character)
      } else if !current.isEmpty {
        tokens.append(current)
        current = ""
      }
    }
    if !current.isEmpty { tokens.append(current) }
    return tokens
  }

  // MARK: - Casing repair

  /// Rewrites dictated words into the identifiers the surrounding code actually uses.
  ///
  /// Matching is by *shape-free key*: lowercase letters and digits only, so `userId`,
  /// `user_id`, `USER_ID` and the spoken "user id" all reduce to `userid` and find
  /// each other. Up to four spoken words are considered, longest match first, so
  /// "max retry count" reaches `MAX_RETRY_COUNT` rather than stopping at `max`.
  ///
  /// A replacement only happens when the symbol table offers an identifier-shaped
  /// candidate. Without that guard the function would happily capitalise ordinary
  /// prose the moment a type shared its name with an English word.
  public func repairIdentifiers(in text: String, symbols: [String]) -> String {
    let table = Self.symbolTable(symbols)
    guard !table.isEmpty else { return text }

    return text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in Self.repairLine(String(line), table: table) }
      .joined(separator: "\n")
  }

  /// Longest spoken phrase considered as one identifier. Four covers
  /// `MAX_RETRY_COUNT_LIMIT`; beyond that the risk of swallowing a real sentence
  /// outweighs the repair.
  static let maximumSpokenWords = 4

  static func symbolTable(_ symbols: [String]) -> [String: String] {
    var table: [String: String] = [:]
    for symbol in symbols where looksLikeIdentifier(symbol) {
      let key = normaliseKey(symbol)
      guard !key.isEmpty else { continue }
      // First one wins: the earliest symbol in the snapshot is the one nearest the
      // caret, and re-deciding on every later duplicate makes the result depend on
      // how much of the window happened to be visible.
      if table[key] == nil { table[key] = symbol }
    }
    return table
  }

  /// Lowercase letters and digits only. Separators and case are exactly what is in
  /// dispute, so they cannot be part of the key.
  static func normaliseKey(_ text: String) -> String {
    var key = ""
    for character in text.lowercased() where character.isLetter || character.isNumber {
      key.append(character)
    }
    return key
  }

  private static func repairLine(_ line: String, table: [String: String]) -> String {
    let words = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    var output: [String] = []
    var index = 0

    while index < words.count {
      var matched = false
      let longest = min(maximumSpokenWords, words.count - index)
      // Longest first, so a phrase wins over its own first word.
      for length in stride(from: longest, through: 1, by: -1) {
        let span = words[index..<(index + length)]
        guard let last = span.last else { continue }
        let trailing = trailingPunctuation(last)
        let key = normaliseKey(span.joined())
        guard !key.isEmpty, let symbol = table[key] else { continue }
        // A single word that already is the symbol needs no help, and rewriting it
        // would churn the text for nothing.
        if length == 1, span.first == symbol + trailing { break }
        output.append(symbol + trailing)
        index += length
        matched = true
        break
      }
      if !matched {
        output.append(words[index])
        index += 1
      }
    }
    return output.joined(separator: " ")
  }

  static func trailingPunctuation(_ word: String) -> String {
    var suffix = ""
    for character in word.reversed() {
      guard ".,!?;:)\"'".contains(character) else { break }
      suffix.insert(character, at: suffix.startIndex)
    }
    // A file name ends in a dot-extension, not in a full stop; treat a trailing dot as
    // punctuation only when something else follows it in the same word.
    return suffix
  }

  // MARK: - Spoken file references

  static let separatorWords: [String: String] = [
    "slash": "/", "dash": "-", "hyphen": "-", "underscore": "_", "dot": ".",
  ]

  /// Turns "at main dot swift" into "@main.swift".
  ///
  /// Only for chats with an AI assistant: `@` is how those tools are told to look at a
  /// file, and the same words dictated into an email are just words. The caller passes
  /// the surface rather than this function guessing.
  ///
  /// The scan is linear and bounded — a reference is at most a handful of tokens — and
  /// it commits only when the piece after the dot is a known file extension. "Meet me
  /// at four dot thirty" is left exactly as it is.
  public func expandFileReferences(in text: String, isAIAssistant: Bool, symbols: [String] = [])
    -> String
  {
    guard isAIAssistant else { return text }
    let table = Self.symbolTable(symbols)

    return text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in Self.expandLine(String(line), table: table) }
      .joined(separator: "\n")
  }

  /// How far past "at" the scan will look for the dot. Enough for
  /// "at sources slash rant core slash main dot swift"; short enough that a sentence
  /// containing "at" never costs anything.
  static let referenceWindow = 8

  private static func expandLine(_ line: String, table: [String: String]) -> String {
    let words = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    var output: [String] = []
    var index = 0

    while index < words.count {
      guard words[index].lowercased() == "at", index + 1 < words.count else {
        output.append(words[index])
        index += 1
        continue
      }

      if let (reference, consumed) = reference(from: words, after: index, table: table) {
        output.append("@" + reference)
        index += consumed
      } else {
        output.append(words[index])
        index += 1
      }
    }
    return output.joined(separator: " ")
  }

  /// Returns the assembled reference and how many words it consumed, including the
  /// "at" itself.
  private static func reference(
    from words: [String], after atIndex: Int, table: [String: String]
  ) -> (String, Int)? {
    let start = atIndex + 1

    // Already spelled out as one token: "at main.swift".
    let firstWord = words[start]
    let cleaned = firstWord.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
    if let dot = cleaned.lastIndex(of: "."), dot != cleaned.startIndex,
      fileExtensions.contains(String(cleaned[cleaned.index(after: dot)...]).lowercased())
    {
      return (cleaned, 2)
    }

    // Spoken out: words and separator words, ending in "dot <extension>".
    var dotIndex: Int?
    var scan = start
    let ceiling = min(words.count, start + referenceWindow)
    while scan < ceiling {
      if words[scan].lowercased() == "dot" {
        dotIndex = scan
        break
      }
      scan += 1
    }
    guard let dot = dotIndex, dot > start, dot + 1 < words.count else { return nil }
    let ext = words[dot + 1].trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")).lowercased()
    guard fileExtensions.contains(ext) else { return nil }

    // Everything between "at" and "dot" is the name, split on the separators that were
    // spoken aloud.
    var segments: [[String]] = [[]]
    var separators: [String] = []
    for word in words[start..<dot] {
      if let separator = separatorWords[word.lowercased()], separator != "." {
        separators.append(separator)
        segments.append([])
      } else {
        segments[segments.count - 1].append(word)
      }
    }
    guard segments.allSatisfy({ !$0.isEmpty }) else { return nil }

    var resolved: [String] = []
    for segment in segments {
      if segment.count == 1 {
        resolved.append(segment[0])
      } else if let symbol = table[normaliseKey(segment.joined())] {
        // "content view dot swift" only becomes "ContentView.swift" when something on
        // screen says that is the name. Joining the words ourselves would invent one.
        resolved.append(symbol)
      } else {
        return nil
      }
    }

    var name = resolved[0]
    for (offset, separator) in separators.enumerated() {
      name += separator + resolved[offset + 1]
    }
    return (name + "." + ext, dot + 2 - atIndex)
  }

  // MARK: - Putting it together

  /// The whole developer pass, applied only where it belongs.
  ///
  /// Casing repair runs in editors and terminals; file references expand in AI chats.
  /// Everywhere else the text is returned untouched, which is why this takes the
  /// classified surface rather than sniffing the bundle identifier itself.
  public func apply(
    to text: String, context: TranscriptionContext, surface: SurfaceClassifier.Surface
  ) -> String {
    guard surface.isDeveloperContext || surface.isAIAssistant else { return text }
    guard !context.isSecureField else { return text }

    var result = text
    if surface.isDeveloperContext || surface.isAIAssistant {
      result = repairIdentifiers(in: result, symbols: context.developerSymbols)
    }
    if surface.isAIAssistant {
      result = expandFileReferences(
        in: result, isAIAssistant: true, symbols: context.developerSymbols)
    }
    return result
  }
}
