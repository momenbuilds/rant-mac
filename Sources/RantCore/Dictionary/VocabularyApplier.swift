import Foundation

/// Applies the user's dictionary replacements and snippet expansions to finished text.
///
/// Runs *last*, after the model and after cleanup, so the user's own vocabulary
/// always wins. If you have told Rant that "super base" means Supabase, no amount of
/// model confidence should override that.
public struct VocabularyApplier: Sendable {
  /// Spoken form → written form. Matched on word boundaries, longest first, so
  /// "cloud flare workers" beats "cloud flare".
  public var replacements: [(spoken: String, written: String, caseSensitive: Bool)]
  /// Trigger phrase → expansion.
  public var snippets: [(trigger: String, expansion: String)]

  public init(
    replacements: [(spoken: String, written: String, caseSensitive: Bool)] = [],
    snippets: [(trigger: String, expansion: String)] = []
  ) {
    self.replacements = replacements
    self.snippets = snippets
  }

  public func apply(to text: String) -> String {
    var result = text
    // Snippets first: an expansion may itself contain terms the dictionary should
    // then correct.
    for (trigger, expansion) in snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) {
      result = Self.replaceWholePhrase(trigger, with: expansion, in: result, caseSensitive: false)
    }
    for entry in replacements.sorted(by: { $0.spoken.count > $1.spoken.count }) {
      result = Self.replaceWholePhrase(
        entry.spoken, with: entry.written, in: result, caseSensitive: entry.caseSensitive)
    }
    return result
  }

  /// Replaces `phrase` only where it stands as whole words — so a dictionary entry
  /// for "ver sell" cannot corrupt the middle of "conversell".
  static func replaceWholePhrase(
    _ phrase: String, with replacement: String, in text: String, caseSensitive: Bool
  ) -> String {
    let trimmed = phrase.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return text }
    let escaped = NSRegularExpression.escapedPattern(for: trimmed)
    // Word boundaries only work next to word characters; a phrase that starts or ends
    // with punctuation needs the looser guard.
    let leading = trimmed.first?.isLetter == true || trimmed.first?.isNumber == true ? "\\b" : ""
    let trailing = trimmed.last?.isLetter == true || trimmed.last?.isNumber == true ? "\\b" : ""
    var options: NSString.CompareOptions = [.regularExpression]
    if !caseSensitive { options.insert(.caseInsensitive) }
    return text.replacingOccurrences(
      of: leading + escaped + trailing,
      with: NSRegularExpression.escapedTemplate(for: replacement),
      options: options)
  }
}
