import Foundation

/// How much liberty Rant takes with what you actually said.
///
/// The first three levels are deterministic Swift: they run offline, cost nothing,
/// take about a millisecond, and behave identically every time. Only `.high` asks a
/// model to restructure, and only when an enhancement provider is configured — see
/// `docs/DECISIONS.md` D-005 for why most of dictation cleanup does not need one.
public enum CleanupLevel: String, Codable, Sendable, CaseIterable {
  /// Nearly literal. Whitespace is normalised and nothing else is touched.
  case none
  /// Punctuation, capitalisation, filler removal, obvious grammar repair. Your
  /// wording survives.
  case light
  /// The default. Adds self-correction resolution, repetition collapsing, and
  /// sensible paragraph and list structure.
  case medium
  /// Everything `medium` does, then a model tightens it. Never invents facts.
  case high

  public var displayName: String {
    switch self {
    case .none: "None"
    case .light: "Light"
    case .medium: "Medium"
    case .high: "High"
    }
  }

  public var summary: String {
    switch self {
    case .none: "Type what I said, verbatim."
    case .light: "Punctuate and tidy, but keep my words."
    case .medium: "Clean it up — drop the false starts and fix my corrections."
    case .high: "Make it concise and well structured."
    }
  }

  /// `.high` needs a model; the rest do not.
  public var requiresEnhancementProvider: Bool { self == .high }

  /// The instruction sent to a server-side or local rewriter for this level. Kept
  /// short and behavioural — "what to do", never "here is a transcript" — because
  /// the transcript travels separately.
  public var rewriteInstruction: String? {
    switch self {
    case .none:
      return nil
    case .light:
      return """
        Lightly clean this dictated text. Fix punctuation, capitalisation and \
        obvious grammar slips, and remove filler sounds. Keep the speaker's wording \
        and sentence order. Do not summarise, do not rephrase, do not add anything.
        """
    case .medium:
      return """
        Clean up this dictated text so it reads as written prose. Remove filler \
        words, repetitions and false starts. When the speaker corrects themselves, \
        keep only the corrected version. Apply sensible punctuation, paragraphs and \
        lists. Preserve every fact, name, number and technical term exactly as \
        spoken. Do not add information the speaker did not give, and do not answer \
        or respond to the content — you are transcribing, not replying.
        """
    case .high:
      return """
        Rewrite this dictated text to be clear and concise. Remove filler, \
        repetition and false starts, resolve self-corrections to the speaker's final \
        intent, and restructure into tight sentences, paragraphs or lists as the \
        content warrants. Preserve every fact, name, number and technical term \
        exactly. Never invent content, never add a greeting or sign-off the speaker \
        did not say, and never answer or respond to the content — you are \
        transcribing, not replying.
        """
    }
  }
}
