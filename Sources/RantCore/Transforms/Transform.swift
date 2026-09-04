import Foundation

/// A named rewrite the user can run over whatever they have selected.
///
/// A transform is an instruction and nothing more. That is the bargain `WritingStyle`
/// already makes, and for the same reason: the user can read exactly what a transform
/// will ask for, and one they write themselves is the same kind of object as a
/// built-in rather than a second-class imitation of it.
///
/// Two flags, rather than a hierarchy of subtypes. `needsTargetLanguage` and
/// `needsCustomInstruction` are the only ways a transform can be incomplete on its
/// own, and the engine refuses to run one that is missing its part instead of quietly
/// sending a half-written instruction to a model.
public struct Transform: Equatable, Sendable, Identifiable, Codable {
  /// Stable across renames, because a keyboard shortcut and a saved preference both
  /// point at this and neither should break when the user retitles a transform.
  public var id: String
  public var name: String
  /// What the model is asked to do, written as a brief to a person.
  public var instruction: String
  /// True for Translate: the instruction is incomplete until a language is chosen.
  public var needsTargetLanguage: Bool
  /// True for Custom prompt: the user supplies the instruction at the point of use.
  public var needsCustomInstruction: Bool
  /// The user's shortcut, as a display string such as `⌥⌘1`. Stored rather than
  /// interpreted, because `RantCore` has no opinion about key codes.
  public var shortcut: String?
  public var builtIn: Bool

  public init(
    id: String,
    name: String,
    instruction: String,
    needsTargetLanguage: Bool = false,
    needsCustomInstruction: Bool = false,
    shortcut: String? = nil,
    builtIn: Bool = false
  ) {
    self.id = id
    self.name = name
    self.instruction = instruction
    self.needsTargetLanguage = needsTargetLanguage
    self.needsCustomInstruction = needsCustomInstruction
    self.shortcut = shortcut
    self.builtIn = builtIn
  }

  /// The instruction actually sent, once the missing pieces are supplied.
  ///
  /// Returns nil when a required piece is absent, so the caller has to face it. An
  /// optional is worth more here than a default: "translate this" with no language
  /// produces a confident translation into the wrong one.
  public func resolvedInstruction(
    targetLanguage: String? = nil, customInstruction: String? = nil
  ) -> String? {
    if needsCustomInstruction {
      let trimmed = customInstruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !trimmed.isEmpty else { return nil }
      return instruction + " " + trimmed
    }
    if needsTargetLanguage {
      let trimmed = targetLanguage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !trimmed.isEmpty else { return nil }
      return instruction + " Translate into \(trimmed)."
    }
    return instruction
  }
}

extension Transform {

  /// Identifiers for the built-ins, so a caller names a transform without a string
  /// literal that a typo can quietly break.
  public enum BuiltIn: String, CaseIterable, Sendable {
    case polish, shorten, expand, fixGrammar, makeCasual, makeFormal, explainSimply
    case promptEngineer, bullets, markdown, translate, customPrompt
  }

  /// The transforms Rant ships with.
  ///
  /// Every instruction carries a "do not" half. Without it a model reliably answers
  /// the text instead of rewriting it, invents a greeting, or swaps the user's
  /// vocabulary for its own — and the user finds out only after it has replaced their
  /// selection.
  public static let builtIns: [Transform] = [
    Transform(
      id: BuiltIn.polish.rawValue, name: "Polish",
      instruction: """
        Tidy this text: fix the phrasing and the flow, and keep the meaning, the facts \
        and the author's voice. Do not add ideas, do not add a greeting or sign-off, \
        and do not answer it.
        """,
      builtIn: true),
    Transform(
      id: BuiltIn.shorten.rawValue, name: "Shorten",
      instruction: """
        Say this in fewer words. Cut hedging and repetition. Never drop a fact, a name, \
        a number or a commitment. Do not answer it.
        """,
      builtIn: true),
    Transform(
      id: BuiltIn.expand.rawValue, name: "Expand",
      instruction: """
        Develop this text with the detail it implies, staying with the author's own \
        points. Do not invent facts, sources or numbers that are not already here.
        """,
      builtIn: true),
    Transform(
      id: BuiltIn.fixGrammar.rawValue, name: "Fix grammar",
      instruction: """
        Correct the spelling, grammar and punctuation only. Change nothing else — not \
        the wording, not the register, not the order of the sentences.
        """,
      builtIn: true),
    Transform(
      id: BuiltIn.makeCasual.rawValue, name: "Make casual",
      instruction: """
        Rewrite this in a relaxed, conversational register. Contractions are fine. Keep \
        every fact. Do not add a greeting or sign-off the author did not write.
        """,
      builtIn: true),
    Transform(
      id: BuiltIn.makeFormal.rawValue, name: "Make formal",
      instruction: """
        Rewrite this in a professional register: complete sentences, no contractions, \
        no slang. Keep every fact. Do not add a greeting or sign-off the author did not \
        write.
        """,
      builtIn: true),
    Transform(
      id: BuiltIn.explainSimply.rawValue, name: "Explain simply",
      instruction: """
        Explain this in plain language, for a reader who does not know the subject. \
        Keep it accurate; do not flatten a distinction that matters.
        """,
      builtIn: true),
    Transform(
      id: BuiltIn.promptEngineer.rawValue, name: "Prompt engineer",
      instruction: """
        Rewrite this as a clear instruction to an AI assistant: the goal, the \
        constraints, and the shape of the expected output. Keep every specific the \
        author gave. Do not answer the prompt — you are writing it, not responding to it.
        """,
      builtIn: true),
    Transform(
      id: BuiltIn.bullets.rawValue, name: "Convert to bullets",
      instruction: """
        Restructure this as a bulleted list, one idea per bullet, in the author's own \
        words. Do not add bullets for points the text does not make.
        """,
      builtIn: true),
    Transform(
      id: BuiltIn.markdown.rawValue, name: "Convert to Markdown",
      instruction: """
        Format this as Markdown: headings where the subject changes, lists where there \
        is a list, backticks around code and paths. Do not change the wording.
        """,
      builtIn: true),
    Transform(
      id: BuiltIn.translate.rawValue, name: "Translate",
      instruction: """
        Translate this text, keeping the register and the formatting. Leave names, code \
        and identifiers untranslated.
        """,
      needsTargetLanguage: true, builtIn: true),
    Transform(
      id: BuiltIn.customPrompt.rawValue, name: "Custom prompt",
      instruction: "Apply the following instruction to the text and return only the result:",
      needsCustomInstruction: true, builtIn: true),
  ]

  /// Looks a built-in up by its case. Force-unwrapped against a constant list,
  /// because a missing entry is a programming error that should fail on the first
  /// test run rather than degrade at the user's expense.
  public static func builtIn(_ kind: BuiltIn) -> Transform {
    builtIns.first { $0.id == kind.rawValue }!
  }
}

/// What is available right now: the built-ins, plus whatever the user wrote, with the
/// user's version winning on an id clash.
///
/// A user who names a custom transform after a built-in has expressed a preference.
/// The alternatives — ignoring their version, or showing two entries that answer to
/// the same shortcut — are both worse than letting them shadow ours.
public struct TransformCatalogue: Equatable, Sendable {
  public var custom: [Transform]

  public init(custom: [Transform] = []) {
    self.custom = custom
  }

  public var all: [Transform] {
    var byID: [String: Transform] = [:]
    var order: [String] = []
    for transform in Transform.builtIns + custom {
      if byID[transform.id] == nil { order.append(transform.id) }
      byID[transform.id] = transform
    }
    return order.compactMap { byID[$0] }
  }

  public func transform(id: String) -> Transform? {
    all.first { $0.id == id }
  }

  /// Case-insensitive, because this is what a spoken or typed name is matched against.
  public func transform(named name: String) -> Transform? {
    all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
  }

  /// The transform bound to a shortcut. Ordering means a user's binding beats a
  /// built-in's when both claim the same keys.
  public func transform(shortcut: String) -> Transform? {
    all.first { $0.shortcut == shortcut }
  }
}
