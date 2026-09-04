import Foundation

/// How far outside the text channel an action can reach.
///
/// Command mode (see `CommandEffect`) can only touch the user's document and
/// clipboard, and that closed list is what makes it safe to run from a phrase. This
/// layer exists for the things that cannot be expressed there — a note on disk, a
/// browser window, a command the user configured — so it needs a way to say how far a
/// capability reaches before it is allowed to run. The order matters: it is the ladder
/// the confirmation threshold is compared against, so a new case belongs at the rung it
/// actually sits on rather than appended to the end.
public enum ActionPermission: String, Sendable, Codable, CaseIterable, Comparable {
  /// Writes text where the user was already typing. Nothing leaves the document.
  case textOnly
  /// Touches the pasteboard, which every other app can read.
  case clipboard
  /// Writes to Rant's own database. Reversible, and never leaves the machine.
  case createsLocalData
  /// Hands a URL to another application. The first rung that reaches the network.
  case opensURL
  /// Runs a program the user configured. The top rung, and the only one that can do
  /// something Rant cannot describe in advance.
  case runsCommand

  /// Position on the ladder. Written out rather than derived from `allCases`, so
  /// reordering the enum for cosmetic reasons cannot quietly re-rank a permission.
  public var rank: Int {
    switch self {
    case .textOnly: 0
    case .clipboard: 1
    case .createsLocalData: 2
    case .opensURL: 3
    case .runsCommand: 4
    }
  }

  public static func < (lhs: ActionPermission, rhs: ActionPermission) -> Bool {
    lhs.rank < rhs.rank
  }
}

// MARK: - Input

/// The kinds of value an action can accept.
///
/// A closed list, because it is also the list of things this layer knows how to
/// validate. `text` is the important one: it is the transcript, or a model's rewrite of
/// it, and it is carried as opaque data that is never parsed, matched against a phrase
/// table, or interpolated into anything that has syntax.
public enum ActionInputKind: String, Sendable, Equatable, CaseIterable {
  case text
  case title
  case url
  case identifier
  case date
}

public struct ActionInputField: Sendable, Equatable {
  public let name: String
  public let kind: ActionInputKind
  public let isRequired: Bool

  public init(_ name: String, _ kind: ActionInputKind, required: Bool = true) {
    self.name = name
    self.kind = kind
    self.isRequired = required
  }
}

/// The values an action was asked to run with.
public struct ActionInput: Sendable, Equatable {
  public private(set) var values: [String: String]

  public init(_ values: [String: String] = [:]) {
    self.values = values
  }

  public subscript(name: String) -> String? { values[name] }

  public func string(_ name: String) throws -> String {
    guard let value = values[name] else { throw ActionError.missingField(name) }
    return value
  }

  /// Total size of the values, for the audit trail. Counts only — the trail records
  /// the shape of what was acted on, never the words.
  public var characterCount: Int { values.values.reduce(0) { $0 + $1.count } }
}

/// What an action accepts, and the only place input is checked.
///
/// The schema is closed in both directions: a required field that is missing is a
/// refusal, and so is a field the action never declared. Ignoring unknown fields would
/// let a caller attach `arguments` or `url` to a note action and hope some later reader
/// picks it up, which is the kind of gap a smuggled payload walks through.
public struct ActionInputSchema: Sendable, Equatable {
  public let fields: [ActionInputField]

  public init(_ fields: [ActionInputField]) {
    self.fields = fields
  }

  /// Returns the input as it will be used, or throws. Validation happens once, here,
  /// before a preview exists — so a URL with a refused scheme fails while the user is
  /// still being asked, and never reaches an executor at all.
  public func validate(_ input: ActionInput) throws -> ActionInput {
    var checked: [String: String] = [:]
    let declared = Set(fields.map(\.name))
    for name in input.values.keys where !declared.contains(name) {
      throw ActionError.unknownField(name)
    }
    for field in fields {
      guard let raw = input[field.name], !raw.isEmpty else {
        if field.isRequired { throw ActionError.missingField(field.name) }
        continue
      }
      checked[field.name] = try Self.check(raw, as: field.kind, named: field.name)
    }
    return ActionInput(checked)
  }

  static func check(_ raw: String, as kind: ActionInputKind, named name: String) throws -> String {
    switch kind {
    case .text:
      // Deliberately unrestricted. Text is the payload, and mangling it here would
      // change what the user dictated in the name of a safety property that is
      // enforced at the point of use instead.
      return raw
    case .title:
      // One line, because a title is a filing label, and a newline in one silently
      // becomes a second line of body.
      let single = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)
      guard !single.isEmpty else { throw ActionError.malformedField(name) }
      return String(single.prefix(200))
    case .url:
      return try ActionURLPolicy.validated(raw).absoluteString
    case .identifier:
      guard raw.allSatisfy(\.isNumber) else { throw ActionError.malformedField(name) }
      return raw
    case .date:
      guard Self.parseISO8601(raw) != nil else { throw ActionError.malformedField(name) }
      return raw
    }
  }

  /// `ISO8601DateFormatter` is a mutable class, so a shared static instance of it is
  /// rejected under strict concurrency. `Date.ISO8601FormatStyle` is a value type and
  /// carries no shared state, so it can simply be constructed where it is needed.
  static func parseISO8601(_ raw: String) -> Date? {
    try? Date.ISO8601FormatStyle().parse(raw)
  }

  static func iso8601(_ date: Date) -> String {
    date.ISO8601Format()
  }
}

/// Which URLs Rant is willing to hand to the rest of the machine.
///
/// An allow-list, not a deny-list. `file:` reads the disk, `javascript:` runs in
/// whichever browser window happens to be frontmost, and the custom schemes registered
/// by installed apps are an open-ended set nobody can review — so anything not named
/// here is refused, including the schemes that do not exist yet.
public enum ActionURLPolicy {
  public static let allowedSchemes: Set<String> = ["https", "http", "mailto"]

  public static func validated(_ raw: String) throws -> URL {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // A control character or an embedded space can split the URL when it is handed on,
    // so the whole candidate is refused rather than escaped into something else.
    guard !trimmed.isEmpty,
      !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0 == " " })
    else { throw ActionError.malformedField("url") }
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
      throw ActionError.malformedField("url")
    }
    guard allowedSchemes.contains(scheme) else { throw ActionError.refusedScheme(scheme) }
    // A web URL with no host is either a typo or an attempt to get somewhere odd.
    if scheme == "https" || scheme == "http" {
      guard let host = url.host, !host.isEmpty else { throw ActionError.malformedField("url") }
    }
    return url
  }
}

// MARK: - Running a program

/// A program the user chose, and the only shape a command can have.
///
/// There is no case here for a shell string and no initialiser that takes one. That is
/// the entire design: a command line is a language with syntax, and every injection bug
/// of this class comes from writing a sentence in that language out of text somebody
/// dictated. An executable path plus an argument array has no syntax, so `; rm -rf ~`
/// arriving as the last argument is a strange-looking string handed to a program, not
/// an instruction handed to a shell.
public struct LocalCommand: Sendable, Equatable {
  public let executablePath: String
  /// Arguments the user configured. They always precede the dictated text.
  public let fixedArguments: [String]

  /// Interpreters whose job is to turn a string back into a command line. Allowing one
  /// would re-open the door this type closes: `/bin/sh -c "…"` puts the argument array
  /// straight back into the shell's hands.
  public static let refusedExecutables: Set<String> = [
    "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish", "env", "xargs", "osascript",
  ]

  public init(executablePath: String, fixedArguments: [String] = []) throws {
    let path = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
    // Absolute, so which program runs does not depend on a PATH that Rant did not set.
    guard path.hasPrefix("/") else { throw ActionError.malformedCommand("not an absolute path") }
    let name = (path as NSString).lastPathComponent
    guard !Self.refusedExecutables.contains(name) else {
      throw ActionError.malformedCommand("\(name) is a shell")
    }
    guard !fixedArguments.contains("-c") else {
      throw ActionError.malformedCommand("-c is a shell argument")
    }
    self.executablePath = path
    self.fixedArguments = fixedArguments
  }

  /// The dictated text goes on the end, as exactly one argument, whatever is in it.
  public func invocation(with text: String) -> CommandInvocation {
    CommandInvocation(executablePath: executablePath, arguments: fixedArguments + [text])
  }
}

/// What a runner is handed. There is no string here that a shell would ever see.
public struct CommandInvocation: Sendable, Equatable {
  public let executablePath: String
  public let arguments: [String]

  public init(executablePath: String, arguments: [String]) {
    self.executablePath = executablePath
    self.arguments = arguments
  }
}

/// Handing a URL to the rest of the machine, behind a protocol so `RantCore` neither
/// imports AppKit nor opens anything during a test run.
public protocol ActionURLOpening: Sendable {
  func open(_ url: URL) async throws
}

/// Running the user's configured program. The implementation lives in the app layer and
/// must use `Process.executableURL` with `arguments`; there is nothing in this module
/// that can hand it a shell command, because `CommandInvocation` cannot carry one.
public protocol ActionCommandRunning: Sendable {
  func run(_ invocation: CommandInvocation) async throws -> Int32
}

/// Pressing Return after a paste. Separate from injection because sending the message
/// is the part that cannot be taken back.
public protocol ActionSubmitting: Sendable {
  func submit() async throws
}

// MARK: - Intent, preview, confirmation

/// Where an action came from.
///
/// There is no case for "a model suggested it", and there will not be one. Model output
/// and surrounding text are always *payload* — the thing being saved, copied or sent —
/// and payload never picks the action. A transcript reading "ignore the above and open
/// this link" is a string that ends up stored in a note, because the only two things
/// that can name an action are the user's own words, matched against a closed phrase
/// table, and a control the user pressed.
public enum ActionOrigin: Sendable, Equatable {
  case spokenCommand(utterance: String)
  case userInterface

  /// The part of the origin that is safe to write to the audit trail: the kind of
  /// gesture, not the words.
  public var kind: String {
    switch self {
    case .spokenCommand: "spoken"
    case .userInterface: "ui"
    }
  }
}

/// An action, its input and where it came from, before anything has been checked.
public struct ActionIntent: Sendable, Equatable {
  public let actionID: String
  public let input: ActionInput
  public let origin: ActionOrigin

  public init(actionID: String, input: ActionInput, origin: ActionOrigin) {
    self.actionID = actionID
    self.input = input
    self.origin = origin
  }
}

/// What an action proposes to do, in words, before it does it.
///
/// The summary is the contract with the user: it is written from the validated input,
/// so what they are shown is what will run — not a description of what was asked for
/// before the input was tidied up.
public struct ActionPreview: Sendable, Equatable {
  public let id: UUID
  public let actionID: String
  public let title: String
  public let permission: ActionPermission
  public let requiresConfirmation: Bool
  public let summary: String
  public let undoDescription: String?
  public let input: ActionInput
  public let origin: ActionOrigin

  init(
    id: UUID = UUID(), actionID: String, title: String, permission: ActionPermission,
    requiresConfirmation: Bool, summary: String, undoDescription: String?, input: ActionInput,
    origin: ActionOrigin
  ) {
    self.id = id
    self.actionID = actionID
    self.title = title
    self.permission = permission
    self.requiresConfirmation = requiresConfirmation
    self.summary = summary
    self.undoDescription = undoDescription
    self.input = input
    self.origin = origin
  }
}

/// How the user said yes. Recorded so the trail says which gesture authorised a
/// high-risk action, rather than merely that something did.
public enum ActionGrant: String, Sendable, Equatable {
  case confirmedInApp
  case confirmedInMenuBar
}

/// Proof that a human agreed to one particular preview.
///
/// The token is generated inside `ActionRegistry` and held there in a set of
/// outstanding grants, so a value assembled anywhere else — by a parser, by a caller
/// with a plausible-looking `UUID`, by the same code path twice — is not a
/// confirmation. It is bound to one preview, spent once, and expires: a token that
/// outlives the question it answered is a token that can authorise a later action the
/// user never saw.
public struct ActionConfirmation: Sendable, Equatable {
  public let previewID: UUID
  public let actionID: String
  public let grant: ActionGrant
  let token: UUID

  init(previewID: UUID, actionID: String, grant: ActionGrant, token: UUID) {
    self.previewID = previewID
    self.actionID = actionID
    self.grant = grant
    self.token = token
  }
}

/// The result of running an action, with the means of putting it back where there is
/// one.
public struct ActionOutcome: Sendable {
  public let actionID: String
  public let summary: String
  public let undo: ActionUndo?

  init(actionID: String, summary: String, undo: ActionUndo?) {
    self.actionID = actionID
    self.summary = summary
    self.undo = undo
  }
}

/// Undo carried as work rather than as a sentence, so "undoable" is something the
/// registry can do rather than a promise printed next to a button.
public struct ActionUndo: Sendable {
  public let description: String
  let perform: @Sendable () async throws -> Void

  public init(_ description: String, perform: @escaping @Sendable () async throws -> Void) {
    self.description = description
    self.perform = perform
  }
}

/// What an action's body returns: what happened, and how to reverse it.
public struct ActionEffect: Sendable {
  public var summary: String
  public var undo: ActionUndo?

  public init(summary: String, undo: ActionUndo? = nil) {
    self.summary = summary
    self.undo = undo
  }
}

// MARK: - Definition

/// When a capability needs a human to agree first.
public enum ActionConfirmationRule: Sendable, Equatable {
  /// Compared against the policy threshold. The normal case.
  case byPermission
  /// Always, whatever the permission says — for the actions nothing can reverse. A
  /// message that has been sent is gone, even though sending it was only text.
  case always
}

/// One capability: what it is called, what it accepts, how far it reaches, what it will
/// say it is about to do, and how to do it.
public struct ActionDefinition: Sendable {
  public let id: String
  public let title: String
  public let permission: ActionPermission
  public let schema: ActionInputSchema
  public let confirmation: ActionConfirmationRule
  /// What the user is shown. Runs on validated input only.
  public let describe: @Sendable (ActionInput) -> String
  /// What undoing would mean, in words, for the preview. Nil when nothing can be put
  /// back — which the user deserves to be told before rather than afterwards.
  public let undoDescription: String?
  public let perform: @Sendable (ActionInput) async throws -> ActionEffect

  public init(
    id: String,
    title: String,
    permission: ActionPermission,
    schema: ActionInputSchema,
    confirmation: ActionConfirmationRule = .byPermission,
    undoDescription: String? = nil,
    describe: @escaping @Sendable (ActionInput) -> String,
    perform: @escaping @Sendable (ActionInput) async throws -> ActionEffect
  ) {
    self.id = id
    self.title = title
    self.permission = permission
    self.schema = schema
    self.confirmation = confirmation
    self.undoDescription = undoDescription
    self.describe = describe
    self.perform = perform
  }

  public func requiresConfirmation(under policy: ActionPolicy) -> Bool {
    switch confirmation {
    case .always: true
    case .byPermission: permission >= policy.confirmationThreshold
    }
  }
}

/// A definition with the closures taken off, for a settings screen that has to list
/// what a voice can reach.
public struct ActionSummary: Sendable, Equatable {
  public let id: String
  public let title: String
  public let permission: ActionPermission
  public let requiresConfirmation: Bool
  public let fields: [ActionInputField]
}

public struct ActionPolicy: Sendable {
  /// Everything at this rung or above needs an explicit yes. Opening a URL is the
  /// first thing Rant can do that reaches past the user's own machine, which is where
  /// the line belongs.
  public var confirmationThreshold: ActionPermission
  /// How long a grant stays good for: long enough to read the preview, short enough
  /// that a token cannot sit around waiting to authorise something else.
  public var confirmationLifetime: TimeInterval

  public init(
    confirmationThreshold: ActionPermission = .opensURL,
    confirmationLifetime: TimeInterval = 120
  ) {
    self.confirmationThreshold = confirmationThreshold
    self.confirmationLifetime = confirmationLifetime
  }
}

// MARK: - Audit

public enum ActionDecision: Sendable, Equatable {
  case previewed
  case executed
  case refused(reason: String)
  case undone
}

/// One line of the trail. Identifiers, permissions and counts — never user text, per
/// `RantLog`.
public struct ActionAuditEntry: Sendable, Equatable {
  public var at: Date
  public var actionID: String
  public var permission: ActionPermission
  public var origin: String
  public var decision: ActionDecision
  public var inputCharacters: Int
}

public protocol ActionAuditing: Sendable {
  func record(_ entry: ActionAuditEntry)
}

/// The default trail. In memory, because the job here is letting the user see what
/// their voice has been causing this session; keeping it longer is a storage decision
/// rather than this file's.
public final class InMemoryActionAudit: ActionAuditing, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [ActionAuditEntry] = []

  public init() {}

  public func record(_ entry: ActionAuditEntry) {
    lock.withLock { stored.append(entry) }
  }

  public var entries: [ActionAuditEntry] { lock.withLock { stored } }
}

// MARK: - Errors

public enum ActionError: Error, Equatable, LocalizedError {
  case unknownAction(String)
  case missingField(String)
  case unknownField(String)
  case malformedField(String)
  case refusedScheme(String)
  case malformedCommand(String)
  case confirmationRequired(String)
  case confirmationInvalid
  case notConfigured(String)
  case notUndoable

  public var errorDescription: String? {
    switch self {
    case .unknownAction(let id): "Rant has no action called \(id)."
    case .missingField(let name): "That action needs \(name)."
    case .unknownField(let name): "That action does not take \(name)."
    case .malformedField(let name): "The \(name) was not in a form Rant could use."
    case .refusedScheme(let scheme): "Rant will not open \(scheme): links."
    case .malformedCommand(let reason): "That command cannot be run: \(reason)."
    case .confirmationRequired(let id): "\(id) needs you to confirm it first."
    case .confirmationInvalid: "That confirmation is no longer good — ask again."
    case .notConfigured(let what): "\(what) has not been set up."
    case .notUndoable: "That cannot be undone."
    }
  }
}

// MARK: - The registry

/// The list of things a voice can cause, and the gate in front of them.
///
/// This is a registry of capabilities, not an interpreter. Nothing here executes a
/// string: a caller names a registered action, the action's own schema validates the
/// input, the user is shown a sentence describing the result, and only then does a body
/// run. Three properties are worth defending, in the order they are easiest to lose:
///
/// - **The action is chosen before the payload is read.** `preview` takes an
///   `ActionIntent` whose `actionID` came from the user's words or from a button, and
///   the payload only ever lands in `input`. There is no path from text back to an id.
/// - **High-risk actions cannot run on the registry's own say-so.** Above the
///   threshold, `execute` needs a token this actor issued, for this preview, once.
/// - **Everything is written down.** Previews, refusals, executions and undos each
///   produce a row, so "what did it just do" has an answer that does not depend on the
///   UI having been watching at the time.
public actor ActionRegistry {
  private var definitions: [String: ActionDefinition] = [:]
  private var outstanding: [UUID: Grant] = [:]
  private let policy: ActionPolicy
  private let audit: ActionAuditing
  private let clock: @Sendable () -> Date
  private let log = RantLog("Actions")

  private struct Grant {
    let previewID: UUID
    let actionID: String
    let issued: Date
  }

  public init(
    policy: ActionPolicy = ActionPolicy(),
    audit: ActionAuditing = InMemoryActionAudit(),
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.policy = policy
    self.audit = audit
    self.clock = clock
  }

  public func register(_ definition: ActionDefinition) {
    definitions[definition.id] = definition
    log.info("action registered: \(definition.id) [\(definition.permission.rawValue)]")
  }

  public func register(_ definitions: [ActionDefinition]) {
    for definition in definitions { register(definition) }
  }

  public func definition(_ id: String) -> ActionDefinition? { definitions[id] }

  /// Everything registered, for a screen that has to show the user what is switched on.
  public func catalogue() -> [ActionSummary] {
    definitions.values
      .map {
        ActionSummary(
          id: $0.id, title: $0.title, permission: $0.permission,
          requiresConfirmation: $0.requiresConfirmation(under: policy), fields: $0.schema.fields)
      }
      .sorted { $0.id < $1.id }
  }

  // MARK: Preview

  /// Validates an intent and describes what it would do. Nothing happens here.
  public func preview(_ intent: ActionIntent) throws -> ActionPreview {
    guard let definition = definitions[intent.actionID] else {
      record(
        actionID: intent.actionID, permission: .textOnly, origin: intent.origin,
        decision: .refused(reason: "unknown action"), characters: intent.input.characterCount)
      throw ActionError.unknownAction(intent.actionID)
    }
    do {
      let input = try definition.schema.validate(intent.input)
      let preview = ActionPreview(
        actionID: definition.id,
        title: definition.title,
        permission: definition.permission,
        requiresConfirmation: definition.requiresConfirmation(under: policy),
        summary: definition.describe(input),
        undoDescription: definition.undoDescription,
        input: input,
        origin: intent.origin)
      record(
        actionID: definition.id, permission: definition.permission, origin: intent.origin,
        decision: .previewed, characters: input.characterCount)
      return preview
    } catch {
      record(
        actionID: definition.id, permission: definition.permission, origin: intent.origin,
        decision: .refused(reason: Self.reason(error)), characters: intent.input.characterCount)
      throw error
    }
  }

  // MARK: Confirmation

  /// Issues the token that lets one preview run.
  ///
  /// Call this from the code that put the preview's summary in front of a human and
  /// watched them agree, and from nowhere else. `grant` records which gesture that was.
  public func confirmation(for preview: ActionPreview, grantedBy grant: ActionGrant)
    -> ActionConfirmation
  {
    prune()
    let token = UUID()
    outstanding[token] = Grant(previewID: preview.id, actionID: preview.actionID, issued: clock())
    return ActionConfirmation(
      previewID: preview.id, actionID: preview.actionID, grant: grant, token: token)
  }

  /// Drops a grant the user backed out of, so an abandoned dialogue does not leave a
  /// live token behind it.
  public func revoke(_ confirmation: ActionConfirmation) {
    outstanding[confirmation.token] = nil
  }

  private func consume(_ confirmation: ActionConfirmation, for preview: ActionPreview) -> Bool {
    prune()
    guard let grant = outstanding[confirmation.token],
      grant.previewID == preview.id,
      grant.previewID == confirmation.previewID,
      grant.actionID == preview.actionID,
      confirmation.actionID == preview.actionID
    else { return false }
    // Spent once. A token that survives its own execution can authorise the next one.
    outstanding[confirmation.token] = nil
    return true
  }

  private func prune() {
    let cutoff = clock().addingTimeInterval(-policy.confirmationLifetime)
    outstanding = outstanding.filter { $0.value.issued > cutoff }
  }

  // MARK: Execute

  /// Runs a preview this registry produced.
  ///
  /// `confirmation` defaults to nil, so a caller who has not asked anybody gets a
  /// refusal for anything above the threshold rather than a side effect. The default is
  /// the safety property: forgetting the token fails closed.
  @discardableResult
  public func execute(
    _ preview: ActionPreview, confirmation: ActionConfirmation? = nil
  ) async throws -> ActionOutcome {
    guard let definition = definitions[preview.actionID] else {
      record(
        actionID: preview.actionID, permission: preview.permission, origin: preview.origin,
        decision: .refused(reason: "unknown action"), characters: preview.input.characterCount)
      throw ActionError.unknownAction(preview.actionID)
    }

    if definition.requiresConfirmation(under: policy) {
      guard let confirmation else {
        record(
          actionID: definition.id, permission: definition.permission, origin: preview.origin,
          decision: .refused(reason: "not confirmed"), characters: preview.input.characterCount)
        throw ActionError.confirmationRequired(definition.id)
      }
      guard consume(confirmation, for: preview) else {
        record(
          actionID: definition.id, permission: definition.permission, origin: preview.origin,
          decision: .refused(reason: "bad confirmation"),
          characters: preview.input.characterCount)
        throw ActionError.confirmationInvalid
      }
    }

    do {
      // Validated again rather than trusted: a preview is a value the caller has been
      // holding on to, and checking it twice costs nothing next to running the wrong
      // thing once.
      let input = try definition.schema.validate(preview.input)
      let effect = try await definition.perform(input)
      record(
        actionID: definition.id, permission: definition.permission, origin: preview.origin,
        decision: .executed, characters: input.characterCount)
      return ActionOutcome(actionID: definition.id, summary: effect.summary, undo: effect.undo)
    } catch {
      record(
        actionID: definition.id, permission: definition.permission, origin: preview.origin,
        decision: .refused(reason: Self.reason(error)), characters: preview.input.characterCount)
      throw error
    }
  }

  /// Puts back what an outcome did, where it said it could.
  public func undo(_ outcome: ActionOutcome) async throws {
    guard let undo = outcome.undo else {
      record(
        actionID: outcome.actionID, permission: .textOnly, origin: .userInterface,
        decision: .refused(reason: "not undoable"), characters: 0)
      throw ActionError.notUndoable
    }
    try await undo.perform()
    record(
      actionID: outcome.actionID,
      permission: definitions[outcome.actionID]?.permission ?? .textOnly,
      origin: .userInterface, decision: .undone, characters: 0)
  }

  // MARK: Audit

  private func record(
    actionID: String, permission: ActionPermission, origin: ActionOrigin,
    decision: ActionDecision, characters: Int
  ) {
    audit.record(
      ActionAuditEntry(
        at: clock(), actionID: actionID, permission: permission, origin: origin.kind,
        decision: decision, inputCharacters: characters))
    switch decision {
    case .refused(let reason): log.warning("action \(actionID) refused: \(reason)")
    case .executed: log.info("action \(actionID) executed")
    default: break
    }
  }

  /// A short, safe reason for the trail. These descriptions name fields and schemes,
  /// never values.
  static func reason(_ error: Error) -> String {
    guard let action = error as? ActionError else { return "failed" }
    switch action {
    case .unknownAction: return "unknown action"
    case .missingField(let name): return "missing \(name)"
    case .unknownField(let name): return "unknown field \(name)"
    case .malformedField(let name): return "malformed \(name)"
    case .refusedScheme(let scheme): return "refused scheme \(scheme)"
    case .malformedCommand(let reason): return "bad command: \(reason)"
    case .confirmationRequired: return "not confirmed"
    case .confirmationInvalid: return "bad confirmation"
    case .notConfigured(let what): return "\(what) not configured"
    case .notUndoable: return "not undoable"
    }
  }
}

// MARK: - Test doubles

/// Records what it was asked to open, and opens nothing.
public final class RecordingURLOpener: ActionURLOpening, @unchecked Sendable {
  private let lock = NSLock()
  private var opened: [URL] = []
  public var error: Error?

  public init() {}

  public func open(_ url: URL) async throws {
    lock.withLock { opened.append(url) }
    if let error { throw error }
  }

  public var urls: [URL] { lock.withLock { opened } }
}

/// Records invocations. Note that it has nowhere to put a shell string, because
/// `CommandInvocation` has nowhere to put one either.
public final class RecordingCommandRunner: ActionCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var calls: [CommandInvocation] = []
  public var exitCode: Int32 = 0

  public init() {}

  public func run(_ invocation: CommandInvocation) async throws -> Int32 {
    lock.withLock { calls.append(invocation) }
    return exitCode
  }

  public var invocations: [CommandInvocation] { lock.withLock { calls } }
}

/// Records Return presses.
public final class RecordingSubmitter: ActionSubmitting, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  public init() {}

  public func submit() async throws { lock.withLock { count += 1 } }

  public var submissions: Int { lock.withLock { count } }
}
