import AppKit
import Combine
import RantCore
import SwiftUI

/// The Actions layer, made visible and runnable.
///
/// `ActionRegistry` and `BuiltInActions` implement the whole thing — an input schema
/// per action, a permission class, a preview sentence produced without running
/// anything, a confirmation token for the consequential ones, and undo where it is
/// possible — and were constructed nowhere outside their own tests.
///
/// The point of surfacing them is the master prompt's own framing: build actions as
/// registered capabilities rather than giving a model unrestricted shell access, and
/// let a reviewer read the whole surface of "what a voice can cause" in one place. So
/// the UI lists every action with its permission and whether it will ask first, and
/// running one goes through the same preview-then-confirm path any other caller uses.
@MainActor
final class ActionsController: ObservableObject {
  @Published private(set) var catalogue: [ActionSummary] = []
  @Published private(set) var lastResult: String?
  @Published private(set) var lastError: String?
  /// An action waiting for the user to agree to it. Nothing runs while this is set.
  @Published private(set) var pending: ActionPreview?

  private let registry: ActionRegistry
  private let log = RantLog("Actions")

  init(notes: NoteStore?) {
    // No command runner and no configured local command: `runsCommand` is the only
    // rung that can do something Rant cannot describe in advance, and it stays
    // unavailable until a user configures one deliberately.
    let environment = ActionEnvironment(
      notes: notes,
      pasteboard: SystemPasteboard(),
      injector: AccessibilityInjector(),
      urlOpener: WorkspaceURLOpener())
    self.registry = ActionRegistry()
    Task { [registry] in
      await BuiltInActions.install(into: registry, environment: environment)
      let summaries = await registry.catalogue()
      await MainActor.run { self.catalogue = summaries }
    }
  }

  /// Preview, confirm if the action's permission demands it, then run.
  ///
  /// The confirmation is not a formality: `execute` refuses without a token for
  /// anything the policy says needs one, so this path cannot accidentally become the
  /// silent one.
  func run(_ summary: ActionSummary, values: [String: String]) {
    lastResult = nil
    lastError = nil
    Task { [registry, log] in
      do {
        let intent = ActionIntent(
          actionID: summary.id, input: ActionInput(values), origin: .userInterface)
        let preview = try await registry.preview(intent)
        if preview.requiresConfirmation {
          // Stop here and ask. Minting the token in the same breath as the request
          // would turn a confirmation into a formality, which is the one thing it
          // must not be — the preview sentence exists so a person can read what is
          // about to happen and say no.
          await MainActor.run { self.pending = preview }
          return
        }
        let outcome = try await registry.execute(preview, confirmation: nil)
        await MainActor.run { self.lastResult = outcome.summary }
        log.info("action \(summary.id) ran")
      } catch {
        await MainActor.run { self.lastError = error.localizedDescription }
        log.warning("action \(summary.id) refused: \(error.localizedDescription)")
      }
    }
  }

  /// The human said yes to this exact preview.
  func confirm(_ preview: ActionPreview) {
    pending = nil
    Task { [registry, log] in
      do {
        let confirmation = await registry.confirmation(
          for: preview, grantedBy: .confirmedInApp)
        let outcome = try await registry.execute(preview, confirmation: confirmation)
        await MainActor.run { self.lastResult = outcome.summary }
        log.info("action \(preview.actionID) ran after confirmation")
      } catch {
        await MainActor.run { self.lastError = error.localizedDescription }
      }
    }
  }

  func cancelPending() {
    pending = nil
    lastResult = "Cancelled."
  }
}

/// Opens a URL through `NSWorkspace`.
///
/// The registry validates the URL before this is reached — the scheme allow-list lives
/// in `ActionURLPolicy`, not here — so this stays a one-line adapter and the rule has
/// one home.
struct WorkspaceURLOpener: ActionURLOpening {
  func open(_ url: URL) async throws {
    NSWorkspace.shared.open(url)
  }
}
