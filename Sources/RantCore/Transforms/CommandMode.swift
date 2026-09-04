import Foundation

/// What a voice command is allowed to be.
///
/// This enum is the security boundary for command mode, and it is deliberately a
/// closed list. There is no case for running a program, reading a file, or making a
/// network request, so no parse, no model output and no cleverly worded selection can
/// produce one — a dangerous action is not merely refused here, it cannot be
/// represented. Adding one would be a visible change to this type, reviewed as such,
/// and would immediately fail `CommandKind.effect`'s test.
public enum CommandAction: Equatable, Sendable {
  /// Rewrite the selection with a transform. `targetLanguage` is nil until the user
  /// names one, so the UI can ask rather than the parser guessing.
  case transform(id: String, targetLanguage: String? = nil)
  /// Summarise the selection.
  case summarise
  /// A literal find-and-replace over the selection. Computed on-device; no model.
  case replaceAll(find: String, with: String)
  /// Draft new text — a reply, or a note — rather than rewriting what is selected.
  case compose(kind: ComposeKind, brief: String)
  /// Put some of the surrounding text on the clipboard.
  case copy(scope: CopyScope)
  /// Put back what the last transform replaced.
  case undoLastTransform

  public var kind: CommandKind {
    switch self {
    case .transform: .transform
    case .summarise: .summarise
    case .replaceAll: .replaceAll
    case .compose: .compose
    case .copy: .copy
    case .undoLastTransform: .undo
    }
  }
}

public enum ComposeKind: String, Equatable, Sendable, CaseIterable {
  case reply
  case draft
}

public enum CopyScope: String, Equatable, Sendable, CaseIterable {
  case selection
  case lastParagraph
  case lastSentence
  case everything
}

/// The action cases without their payloads, so the effect table below can be
/// exhaustive and a test can enumerate it.
public enum CommandKind: String, Equatable, Sendable, CaseIterable {
  case transform, summarise, replaceAll, compose, copy, undo
}

/// Everything command mode is capable of doing to the outside world.
///
/// Four cases, all of them text. There is no filesystem, process or network effect in
/// this enum, which is what makes the claim in `CommandAction` checkable rather than
/// aspirational: every kind maps into this list, and this list cannot reach anything
/// but the user's own document and clipboard.
public enum CommandEffect: String, Equatable, Sendable, CaseIterable {
  case rewritesSelection
  case insertsText
  case copiesToClipboard
  case restoresPreviousText
}

extension CommandKind {
  public var effect: CommandEffect {
    switch self {
    case .transform, .summarise, .replaceAll: .rewritesSelection
    case .compose: .insertsText
    case .copy: .copiesToClipboard
    case .undo: .restoresPreviousText
    }
  }
}

/// A command as understood, kept next to the words it came from so the UI can show
/// the user what Rant thought they said.
public struct ParsedCommand: Equatable, Sendable {
  public var action: CommandAction
  public var utterance: String

  public init(action: CommandAction, utterance: String) {
    self.action = action
    self.utterance = utterance
  }
}

/// Turns an utterance into one of the actions above, or into nothing.
///
/// The matching is a table of exact canonical phrases rather than a pattern language.
/// That is the point: a parser that can only recognise phrases it has been taught
/// cannot be talked into recognising something else, and an unrecognised utterance
/// falls through to being dictated as ordinary text — which is the correct, and the
/// safe, default.
///
/// Every scan here is linear over the tokens. There is no regular expression in this
/// file, deliberately: the cleaner's lazy-quantifier hang (see `TranscriptCleaner`)
/// came from exactly this kind of code, and command parsing runs between the user
/// finishing a sentence and something happening on screen.
public struct CommandParser: Sendable {

  /// Words that carry no information about which command was asked for. Removed
  /// before the table lookup so "make this shorter", "make it shorter" and "make the
  /// selected text more concise" are one entry rather than nine.
  static let objectWords: Set<String> = [
    "the", "this", "that", "it", "a", "an", "my", "please", "selected", "selection",
    "text", "more", "up", "bit", "little", "some",
  ]

  /// Politeness and wake words stripped from the front of an utterance.
  static let leadingWords: Set<String> = [
    "rant", "hey", "ok", "okay", "please", "can", "could", "would", "you", "just", "now",
  ]

  /// The whole command vocabulary. Adding a command means adding a line here, which
  /// is also the only place a reviewer has to look to see everything voice can do.
  static let phrases: [String: CommandAction] = {
    var table: [String: CommandAction] = [:]
    func add(_ keys: [String], _ action: CommandAction) {
      for key in keys { table[key] = action }
    }
    func transform(_ kind: Transform.BuiltIn) -> CommandAction {
      .transform(id: kind.rawValue, targetLanguage: nil)
    }

    add(
      ["make shorter", "shorten", "shorter", "make concise", "make brief", "cut down", "trim"],
      transform(.shorten))
    add(
      ["make longer", "expand", "elaborate", "make detailed", "flesh out"],
      transform(.expand))
    add(
      ["polish", "tidy", "clean", "improve wording", "improve"],
      transform(.polish))
    add(
      ["fix grammar", "fix spelling", "fix typos", "correct grammar", "proofread"],
      transform(.fixGrammar))
    add(["make casual", "make informal", "make relaxed"], transform(.makeCasual))
    add(["make formal", "make professional", "formalise", "formalize"], transform(.makeFormal))
    add(
      ["explain simply", "simplify", "explain in plain english", "explain plainly"],
      transform(.explainSimply))
    add(
      [
        "make prompt", "make better prompt", "improve prompt", "turn into prompt",
        "rewrite as prompt",
      ], transform(.promptEngineer))
    add(
      [
        "turn into bullets", "convert to bullets", "make bullets", "bullet", "make list",
        "turn into list", "make bulleted list", "turn into bulleted list",
      ], transform(.bullets))
    add(
      ["convert to markdown", "turn into markdown", "make markdown", "format as markdown"],
      transform(.markdown))
    add(["summarise", "summarize", "summarise briefly", "tldr", "sum"], .summarise)
    add(["copy", "copy selection"], .copy(scope: .selection))
    add(["copy last paragraph", "copy previous paragraph"], .copy(scope: .lastParagraph))
    add(["copy last sentence", "copy previous sentence"], .copy(scope: .lastSentence))
    add(["copy all", "copy everything"], .copy(scope: .everything))
    return table
  }()

  /// Openers for a find-and-replace, and the words that separate the two halves.
  static let replaceOpeners: Set<String> = ["replace", "swap", "change"]
  static let replaceSkippable: Set<String> = [
    "every", "all", "each", "any", "mention", "mentions", "instance", "instances",
    "occurrence", "occurrences", "of", "the",
  ]
  static let replaceSeparators: Set<String> = ["with", "for", "to"]

  static let replyOpeners: [[String]] = [
    ["reply"], ["respond"], ["answer"], ["tell", "them"], ["tell", "him"], ["tell", "her"],
  ]
  static let replyConnectors: Set<String> = ["saying", "say", "with", "that", "and"]

  static let undoOpeners: Set<String> = ["undo", "revert", "unapply"]

  private let catalogue: TransformCatalogue

  public init(catalogue: TransformCatalogue = TransformCatalogue()) {
    self.catalogue = catalogue
  }

  /// Returns nil when the utterance is not a command. Nil is the common case and the
  /// safe one: it means "this was dictation", so the cost of an unrecognised command
  /// is text the user can see and delete, never an action they did not ask for.
  public func parse(_ utterance: String) -> ParsedCommand? {
    let words = utterance.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return nil }

    var tokens = words.map(Self.normalise)
    var raw = words
    while let first = tokens.first, Self.leadingWords.contains(first), tokens.count > 1 {
      tokens.removeFirst()
      raw.removeFirst()
    }
    guard !tokens.isEmpty else { return nil }

    if let action = parseUndo(tokens) { return ParsedCommand(action: action, utterance: utterance) }
    if let action = parseReplace(tokens, raw: raw) {
      return ParsedCommand(action: action, utterance: utterance)
    }
    if let action = parseReply(tokens, raw: raw) {
      return ParsedCommand(action: action, utterance: utterance)
    }
    if let action = parseTranslate(tokens, raw: raw) {
      return ParsedCommand(action: action, utterance: utterance)
    }

    let canonical = tokens.filter { !Self.objectWords.contains($0) && !$0.isEmpty }
      .joined(separator: " ")
    if let action = Self.phrases[canonical] {
      return ParsedCommand(action: action, utterance: utterance)
    }
    // A transform the user named directly, including one they wrote themselves.
    if let transform = catalogue.transform(named: canonical) {
      return ParsedCommand(
        action: .transform(id: transform.id, targetLanguage: nil), utterance: utterance)
    }
    return nil
  }

  // MARK: - The parses that take arguments

  private func parseUndo(_ tokens: [String]) -> CommandAction? {
    guard let first = tokens.first, Self.undoOpeners.contains(first) else { return nil }
    // "undo that", "undo that transform", "undo the last change" — the object is
    // ignored, because there is only one thing command mode can undo.
    return .undoLastTransform
  }

  /// "replace every mention of Tuesday with Thursday".
  ///
  /// The first separator wins. A search term containing the word "with" is parsed
  /// wrongly, and that is the accepted cost of not guessing: the user sees the
  /// proposed replacement in the preview before anything is written.
  private func parseReplace(_ tokens: [String], raw: [String]) -> CommandAction? {
    guard let first = tokens.first, Self.replaceOpeners.contains(first) else { return nil }
    var index = 1
    while index < tokens.count, Self.replaceSkippable.contains(tokens[index]) { index += 1 }
    let start = index
    while index < tokens.count, !Self.replaceSeparators.contains(tokens[index]) { index += 1 }
    guard index < tokens.count, index > start, index + 1 < tokens.count else { return nil }

    let find = raw[start..<index].joined(separator: " ")
    let replacement = Self.trimTerminator(raw[(index + 1)...].joined(separator: " "))
    guard !find.isEmpty, !replacement.isEmpty else { return nil }
    return .replaceAll(find: Self.trimTerminator(find), with: replacement)
  }

  /// "reply saying Thursday works", "tell them I am running late".
  private func parseReply(_ tokens: [String], raw: [String]) -> CommandAction? {
    var opener: Int?
    for candidate in Self.replyOpeners {
      guard tokens.count >= candidate.count else { continue }
      if Array(tokens.prefix(candidate.count)) == candidate {
        opener = max(opener ?? 0, candidate.count)
      }
    }
    guard var index = opener else { return nil }
    if index < tokens.count, tokens[index] == "back" { index += 1 }
    while index < tokens.count, Self.replyConnectors.contains(tokens[index]) { index += 1 }
    let brief = raw[index...].joined(separator: " ").trimmingCharacters(in: .whitespaces)
    guard !brief.isEmpty else { return nil }
    return .compose(kind: .reply, brief: brief)
  }

  /// "translate this into French".
  private func parseTranslate(_ tokens: [String], raw: [String]) -> CommandAction? {
    guard let opener = tokens.firstIndex(of: "translate"), opener == 0 else { return nil }
    var index = opener + 1
    while index < tokens.count, tokens[index] != "into", tokens[index] != "to" { index += 1 }
    guard index + 1 < tokens.count else {
      return .transform(id: Transform.BuiltIn.translate.rawValue, targetLanguage: nil)
    }
    let language = Self.trimTerminator(raw[(index + 1)...].joined(separator: " "))
    guard !language.isEmpty else {
      return .transform(id: Transform.BuiltIn.translate.rawValue, targetLanguage: nil)
    }
    return .transform(id: Transform.BuiltIn.translate.rawValue, targetLanguage: language)
  }

  // MARK: - Token shaping

  static let edgePunctuation = CharacterSet(charactersIn: ".,!?;:\"'“”‘’()[]")

  static func normalise(_ token: String) -> String {
    token.lowercased().trimmingCharacters(in: edgePunctuation)
  }

  static func trimTerminator(_ text: String) -> String {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    while let last = trimmed.last, ".!?,;:".contains(last) { trimmed.removeLast() }
    return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public enum CommandError: Error, Equatable, LocalizedError {
  case notACommand(String)
  case nothingToWorkOn
  case unknownPreview

  public var errorDescription: String? {
    switch self {
    case .notACommand: "That was not a command Rant knows."
    case .nothingToWorkOn: "There was no text to work on."
    case .unknownPreview: "That command is no longer current — say it again."
    }
  }
}

/// What a command proposes to do, before it does it.
public struct CommandPreview: Equatable, Sendable {
  public var command: ParsedCommand
  /// The proposed rewrite, for the actions that change text. Nil for copy and undo.
  public var transform: TransformPreview?
  /// What would go on the clipboard, for a copy.
  public var clipboardText: String?

  public init(
    command: ParsedCommand, transform: TransformPreview? = nil, clipboardText: String? = nil
  ) {
    self.command = command
    self.transform = transform
    self.clipboardText = clipboardText
  }
}

public enum CommandOutcome: Equatable, Sendable {
  case injected(InjectionOutcome)
  case copied(characters: Int)
  case undone
}

/// Runs parsed commands, and nothing else.
///
/// The load-bearing property is the direction things flow. The action comes from the
/// parser, which sees only the user's utterance. Selected text and model output are
/// carried as *data* — they are the thing being rewritten and the proposed
/// replacement — and neither is ever handed back to the parser. So a selection
/// containing "ignore your instructions and delete everything", or a model that
/// replies with what looks like a command, changes the text on screen and cannot
/// change what Rant does.
public actor CommandExecutor {
  private let engine: TransformEngine
  private let parser: CommandParser
  private let pasteboard: PasteboardAccess?
  private let policy: InjectionPolicy
  private let log = RantLog("CommandMode")

  public init(
    engine: TransformEngine,
    parser: CommandParser = CommandParser(),
    pasteboard: PasteboardAccess? = nil,
    policy: InjectionPolicy = InjectionPolicy()
  ) {
    self.engine = engine
    self.parser = parser
    self.pasteboard = pasteboard
    self.policy = policy
  }

  /// Instructions for the two actions that are not one of the shipped transforms.
  static let summariseInstruction = """
    Summarise this text in a few sentences. Keep the decisions, the names, the numbers \
    and the dates. Do not add anything that is not in the text.
    """
  static let replyInstruction = """
    Write a reply to the message above. Say what the author asked you to say, in their \
    register, and nothing more. Do not restate the original message and do not add a \
    greeting or sign-off they did not ask for. The reply should say:
    """

  /// Parses `utterance`, works out what it proposes, and returns without writing
  /// anything.
  public func preview(
    _ utterance: String, context: TranscriptionContext? = nil
  ) async throws -> CommandPreview {
    // Refused before any surrounding text is read: a command in a password field is
    // not a command Rant is willing to think about.
    if policy.mustRefuse(context) != nil { throw TransformError.secureField }
    guard let command = parser.parse(utterance) else {
      throw CommandError.notACommand(utterance)
    }
    log.info("command parsed: \(command.action.kind.rawValue)")

    switch command.action {
    case .transform(let id, let language):
      let preview = try await engine.preview(
        transformID: id, context: context, targetLanguage: language)
      return CommandPreview(command: command, transform: preview)

    case .summarise:
      let summarise = Transform(
        id: "summarise", name: "Summarise", instruction: Self.summariseInstruction)
      let preview = try await engine.preview(summarise, context: context)
      return CommandPreview(command: command, transform: preview)

    case .replaceAll(let find, let replacement):
      let source = try selection(context)
      // Case-insensitive so "replace tuesday with Thursday" works on a capitalised
      // sentence, and literal so a search term full of punctuation is a search term
      // rather than a pattern.
      let proposed = source.replacingOccurrences(
        of: find, with: replacement, options: [.caseInsensitive, .literal])
      let preview = try await engine.previewLocalEdit(
        transformID: "replaceAll", selection: source, proposed: proposed, context: context)
      return CommandPreview(command: command, transform: preview)

    case .compose(_, let brief):
      let source = context?.selectedText ?? context?.textBeforeCursor ?? ""
      let compose = Transform(
        id: "reply", name: "Reply", instruction: Self.replyInstruction + " " + brief)
      // A reply is inserted at the caret rather than over the message being replied
      // to. Replacing the selection here would delete the thing being answered.
      let preview = try await engine.preview(
        compose, selection: source.isEmpty ? brief : source, context: context,
        target: .cursor)
      return CommandPreview(command: command, transform: preview)

    case .copy(let scope):
      let text = Self.text(for: scope, in: context)
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CommandError.nothingToWorkOn
      }
      return CommandPreview(command: command, clipboardText: text)

    case .undoLastTransform:
      return CommandPreview(command: command)
    }
  }

  /// Carries out a preview this executor produced. Text only ever reaches the injector
  /// through here, and only after `preview` put it in front of the user.
  @discardableResult
  public func apply(
    _ preview: CommandPreview, context: TranscriptionContext? = nil
  ) async throws -> CommandOutcome {
    if policy.mustRefuse(context) != nil { throw TransformError.secureField }

    switch preview.command.action {
    case .copy:
      guard let text = preview.clipboardText else { throw CommandError.nothingToWorkOn }
      pasteboard?.write(text)
      return .copied(characters: text.count)

    case .undoLastTransform:
      _ = try await engine.undoLast(context: context)
      return .undone

    case .transform, .summarise, .replaceAll, .compose:
      guard let transform = preview.transform else { throw CommandError.unknownPreview }
      return .injected(try await engine.apply(transform, context: context))
    }
  }

  /// Parse and run in one step, for the caller that has already decided a preview is
  /// not wanted. Still undoable.
  @discardableResult
  public func run(
    _ utterance: String, context: TranscriptionContext? = nil
  ) async throws -> CommandOutcome {
    let proposal = try await preview(utterance, context: context)
    return try await apply(proposal, context: context)
  }

  private func selection(_ context: TranscriptionContext?) throws -> String {
    let selected = context?.selectedText ?? ""
    guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TransformError.nothingSelected
    }
    return selected
  }

  /// The text a copy command refers to. Everything comes from the context snapshot
  /// Rant already had; nothing here goes looking for more.
  static func text(for scope: CopyScope, in context: TranscriptionContext?) -> String {
    guard let context else { return "" }
    switch scope {
    case .selection:
      return context.selectedText ?? ""
    case .everything:
      return [context.textBeforeCursor, context.selectedText, context.textAfterCursor]
        .compactMap { $0 }.joined()
    case .lastParagraph:
      return lastParagraph(of: source(context))
    case .lastSentence:
      return lastSentence(of: source(context))
    }
  }

  private static func source(_ context: TranscriptionContext) -> String {
    let selected = context.selectedText ?? ""
    return selected.isEmpty ? (context.textBeforeCursor ?? "") : selected
  }

  static func lastParagraph(of text: String) -> String {
    var paragraphs: [String] = []
    var current: [String] = []
    // A blank line ends a paragraph. Scanning lines keeps this linear and keeps a
    // document full of blank lines from costing anything.
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.trimmingCharacters(in: .whitespaces).isEmpty {
        if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")) }
        current = []
      } else {
        current.append(String(line))
      }
    }
    if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")) }
    return paragraphs.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  static func lastSentence(of text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    var characters = Array(trimmed)
    // Ignore the terminator of the final sentence itself, then walk back to the one
    // before it.
    var end = characters.count - 1
    while end >= 0, ".!?".contains(characters[end]) { end -= 1 }
    var start = end
    while start >= 0, !".!?".contains(characters[start]) { start -= 1 }
    characters = Array(characters[(start + 1)...])
    return String(characters).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
