import Foundation

public enum TransformError: Error, Equatable, LocalizedError {
  case nothingSelected
  case secureField
  case missingTargetLanguage
  case missingInstruction
  case unknownTransform(String)
  case nothingToUndo
  case unknownPreview

  public var errorDescription: String? {
    switch self {
    case .nothingSelected: "Select some text first."
    case .secureField: "Rant will not read or replace text in a password field."
    case .missingTargetLanguage: "Choose a language to translate into."
    case .missingInstruction: "Type the instruction you want applied."
    case .unknownTransform(let id): "There is no transform called \(id)."
    case .nothingToUndo: "There is nothing to undo."
    case .unknownPreview: "That preview is no longer current — run the transform again."
    }
  }
}

/// A proposed rewrite that has not touched the user's document yet.
///
/// The preview is the whole point of the design. A transform replaces text the user
/// wrote, and a model that misreads an instruction can lose a paragraph; showing the
/// change first, with a diff, means the destructive step is always something the user
/// chose rather than something they discovered afterwards.
public struct TransformPreview: Equatable, Sendable, Identifiable {
  public let id: UUID
  public let transformID: String
  public let original: String
  public let proposed: String
  public let diff: [DiffRun]
  /// Where the result goes. Almost always over the selection, but a drafted reply is
  /// inserted at the caret instead — replacing the selection there would delete the
  /// message being answered.
  public let target: InjectionTarget

  public init(
    id: UUID = UUID(), transformID: String, original: String, proposed: String,
    diff: [DiffRun], target: InjectionTarget = .replaceSelection
  ) {
    self.id = id
    self.transformID = transformID
    self.original = original
    self.proposed = proposed
    self.diff = diff
    self.target = target
  }

  public var isUnchanged: Bool { TextDiff.isUnchanged(diff) }
  public var summary: (inserted: Int, deleted: Int) { TextDiff.summary(diff) }
}

/// One transform that has already replaced the user's selection, kept so it can be
/// put back.
public struct AppliedTransform: Equatable, Sendable {
  public var transformID: String
  public var original: String
  public var applied: String
  public var at: Date
}

/// Runs transforms over the selection, and owns the two promises that make that safe:
/// nothing is written without a preview the engine itself produced, and everything
/// written can be undone.
///
/// An actor rather than a struct because the undo stack and the set of live previews
/// are mutable state that a hotkey, a menu and a voice command can all reach at once.
/// The alternative — a lock around a shared store — is the same thing written less
/// clearly.
public actor TransformEngine {
  private let enhancer: EnhancementProvider
  private let injector: TextInjector
  private let policy: InjectionPolicy
  private let log = RantLog("Transforms")

  public private(set) var catalogue: TransformCatalogue
  private var live: [UUID: TransformPreview] = [:]
  private var undoStack: [AppliedTransform] = []

  /// How many previews are remembered. A preview holds a copy of the user's text, so
  /// the set is bounded on purpose rather than growing for the life of the process.
  private let livePreviewLimit = 16
  private var liveOrder: [UUID] = []

  public init(
    enhancer: EnhancementProvider,
    injector: TextInjector,
    catalogue: TransformCatalogue = TransformCatalogue(),
    policy: InjectionPolicy = InjectionPolicy()
  ) {
    self.enhancer = enhancer
    self.injector = injector
    self.catalogue = catalogue
    self.policy = policy
  }

  public func setCatalogue(_ catalogue: TransformCatalogue) {
    self.catalogue = catalogue
  }

  public var undoDepth: Int { undoStack.count }

  // MARK: - Producing a preview

  /// Runs `transform` over the selection and returns the proposal. Writes nothing.
  ///
  /// `selection` is taken from the argument when given and from the context otherwise,
  /// so a caller that has already read the selection does not have to pretend to be an
  /// accessibility snapshot to use this.
  @discardableResult
  public func preview(
    _ transform: Transform,
    selection: String? = nil,
    context: TranscriptionContext? = nil,
    targetLanguage: String? = nil,
    customInstruction: String? = nil,
    target: InjectionTarget = .replaceSelection
  ) async throws -> TransformPreview {
    // Checked before the selection is read, not after: in a password field there is
    // nothing Rant is willing to have in memory in the first place.
    if let refusal = policy.mustRefuse(context) {
      log.warning("refusing transform: \(refusal)")
      throw TransformError.secureField
    }

    let original = (selection ?? context?.selectedText ?? "")
    guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TransformError.nothingSelected
    }

    guard
      let instruction = transform.resolvedInstruction(
        targetLanguage: targetLanguage, customInstruction: customInstruction)
    else {
      throw transform.needsTargetLanguage
        ? TransformError.missingTargetLanguage : TransformError.missingInstruction
    }

    let proposed = try await enhancer.enhance(original, instruction: instruction, context: context)
    let preview = TransformPreview(
      transformID: transform.id, original: original, proposed: proposed,
      diff: TextDiff.diff(original: original, result: proposed), target: target)

    remember(preview)
    log.shape("transform \(transform.id) proposed", of: proposed)
    return preview
  }

  /// Convenience for a caller naming a transform by id.
  @discardableResult
  public func preview(
    transformID: String,
    selection: String? = nil,
    context: TranscriptionContext? = nil,
    targetLanguage: String? = nil,
    customInstruction: String? = nil
  ) async throws -> TransformPreview {
    guard let transform = catalogue.transform(id: transformID) else {
      throw TransformError.unknownTransform(transformID)
    }
    return try await preview(
      transform, selection: selection, context: context, targetLanguage: targetLanguage,
      customInstruction: customInstruction)
  }

  /// Registers an edit Rant computed itself — a find-and-replace, say — so it goes
  /// through the same preview-then-apply path as a model rewrite.
  ///
  /// No model is involved, and no instruction is sent anywhere. It exists so that
  /// "only text that came from a preview can be injected" stays true for local edits
  /// too, rather than local edits having a private route to the injector.
  @discardableResult
  public func previewLocalEdit(
    transformID: String,
    selection: String,
    proposed: String,
    context: TranscriptionContext? = nil,
    target: InjectionTarget = .replaceSelection
  ) throws -> TransformPreview {
    if policy.mustRefuse(context) != nil { throw TransformError.secureField }
    guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TransformError.nothingSelected
    }
    let preview = TransformPreview(
      transformID: transformID, original: selection, proposed: proposed,
      diff: TextDiff.diff(original: selection, result: proposed), target: target)
    remember(preview)
    return preview
  }

  // MARK: - Applying

  /// Replaces the selection with a preview this engine produced.
  ///
  /// A preview it does not recognise is refused. That is what stops any other path in
  /// the app — a parsed command, a model's reply, a plugin — from reaching the
  /// injector with text of its own: the only way to write into the user's document is
  /// to have gone through `preview` first.
  @discardableResult
  public func apply(
    _ preview: TransformPreview, context: TranscriptionContext? = nil
  ) async throws -> InjectionOutcome {
    if let refusal = policy.mustRefuse(context) {
      log.warning("refusing to apply transform: \(refusal)")
      throw TransformError.secureField
    }
    guard live[preview.id] == preview else { throw TransformError.unknownPreview }

    let outcome = try await injector.inject(
      InjectionRequest(text: preview.proposed, target: preview.target, context: context))

    undoStack.append(
      AppliedTransform(
        transformID: preview.transformID, original: preview.original,
        applied: preview.proposed, at: Date()))
    forget(preview.id)
    return outcome
  }

  /// Preview and apply in one step, for the shortcut the user has already confirmed
  /// they want to run without a confirmation. Still undoable — the promise is
  /// "preview *or* undo", never neither.
  @discardableResult
  public func run(
    _ transform: Transform,
    selection: String? = nil,
    context: TranscriptionContext? = nil,
    targetLanguage: String? = nil,
    customInstruction: String? = nil
  ) async throws -> (preview: TransformPreview, outcome: InjectionOutcome) {
    let proposal = try await preview(
      transform, selection: selection, context: context, targetLanguage: targetLanguage,
      customInstruction: customInstruction)
    let outcome = try await apply(proposal, context: context)
    return (proposal, outcome)
  }

  // MARK: - Undo

  /// Puts the original text back, by writing it over the selection the same way the
  /// transform was written. Rant cannot reach into another app's undo stack, so undo
  /// is an ordinary replacement — which also means it is itself visible and reversible.
  @discardableResult
  public func undoLast(context: TranscriptionContext? = nil) async throws -> InjectionOutcome {
    if policy.mustRefuse(context) != nil { throw TransformError.secureField }
    guard let last = undoStack.popLast() else { throw TransformError.nothingToUndo }
    return try await injector.inject(
      InjectionRequest(text: last.original, target: .replaceSelection, context: context))
  }

  public func lastApplied() -> AppliedTransform? { undoStack.last }

  public func clearUndoHistory() {
    undoStack.removeAll()
  }

  // MARK: - Live previews

  private func remember(_ preview: TransformPreview) {
    live[preview.id] = preview
    liveOrder.append(preview.id)
    while liveOrder.count > livePreviewLimit {
      let oldest = liveOrder.removeFirst()
      live[oldest] = nil
    }
  }

  private func forget(_ id: UUID) {
    live[id] = nil
    liveOrder.removeAll { $0 == id }
  }
}
