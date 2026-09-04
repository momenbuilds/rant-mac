import Combine
import RantCore
import SwiftUI

/// Watches the field Rant just wrote into, briefly, and proposes dictionary rules.
///
/// `LearningEngine` implements the whole judgement — is this edit inside the text Rant
/// inserted, is it small enough to be a term rather than a rewrite, is the confidence
/// high enough to be worth asking about — and had no caller. The two hooks it needs are
/// an insertion and a later look at the same field, and nothing in the app provided
/// either, so no candidate was ever produced.
///
/// The bounds are the point, and they are all the engine's:
///
/// - **Opt-in.** While the setting is off, `noteInsertion` keeps nothing, so this
///   observer never starts a watch in the first place.
/// - **One field.** The engine compares field identity and abandons the observation if
///   focus moved. This never reads a field Rant did not just write into.
/// - **Bounded in time.** Watching stops at the engine's window. After that whatever
///   is on screen is the user's own writing.
/// - **Never a secure field.** Refused on both sides.
@MainActor
final class LearningObserver: ObservableObject {
  @Published private(set) var candidates: [LearningCandidate] = []

  private let engine: LearningEngine
  private let context: AccessibilityContextProvider
  private let contextSettings: () -> ContextSettings
  private let log = RantLog("Learning")
  private var watch: Task<Void, Never>?

  /// How often the field is re-read while a watch is running. Slow on purpose: this
  /// is a background convenience, and polling an accessibility tree hard would be felt.
  private static let pollInterval: Duration = .seconds(3)

  init(
    engine: LearningEngine,
    context: AccessibilityContextProvider,
    contextSettings: @escaping () -> ContextSettings
  ) {
    self.engine = engine
    self.context = context
    self.contextSettings = contextSettings
    refresh()
  }

  func update(enabled: Bool) {
    Task { [engine] in await engine.update(settings: LearningSettings(enabled: enabled)) }
    if !enabled { watch?.cancel() }
  }

  /// Called after Rant has put text at the cursor.
  ///
  /// Takes its own snapshot rather than being handed one: focus is still on the field
  /// that was just written into, and this is where the engine's idea of "the same
  /// field" is established, so it has to describe the target app and not Rant.
  func noteInsertion(_ text: String) {
    Task { [weak self] in
      guard let self else { return }
      let snapshot = await context.capture(settings: contextSettings())
      guard !snapshot.isSecureField else { return }
      await engine.noteInsertion(text, context: snapshot, at: Date())
      startWatch()
    }
  }

  private func startWatch() {
    watch?.cancel()
    watch = Task { [weak self] in
      guard let self else { return }
      let deadline = Date().addingTimeInterval(LearningSettings.default.observationWindow)
      while !Task.isCancelled, Date() < deadline {
        try? await Task.sleep(for: Self.pollInterval)
        guard !Task.isCancelled else { return }
        await self.sample()
      }
    }
  }

  private func sample() async {
    let snapshot = await context.capture(settings: contextSettings())
    guard !snapshot.isSecureField else { return }
    // The engine wants what the field says now. Before plus after the cursor is the
    // whole of it as far as the accessibility snapshot is concerned.
    let text = (snapshot.textBeforeCursor ?? "") + (snapshot.textAfterCursor ?? "")
    guard !text.isEmpty else { return }
    do {
      if let candidate = try await engine.observeEdit(
        fieldText: text, context: snapshot, at: Date())
      {
        log.info("proposed a dictionary rule from a correction")
        _ = candidate
        refresh()
        watch?.cancel()
      }
    } catch {
      log.warning("could not compare a correction: \(error.localizedDescription)")
    }
  }

  // MARK: - The queue the user answers

  func refresh() {
    Task { [weak self] in
      guard let self else { return }
      let found = (try? await engine.candidates(limit: 50)) ?? []
      self.candidates = found
    }
  }

  func accept(_ candidate: LearningCandidate) {
    guard let id = candidate.id else { return }
    Task { [weak self] in
      guard let self else { return }
      _ = try? await engine.accept(id: id)
      self.refresh()
    }
  }

  func reject(_ candidate: LearningCandidate) {
    guard let id = candidate.id else { return }
    Task { [weak self] in
      guard let self else { return }
      try? await engine.reject(id: id)
      self.refresh()
    }
  }
}
