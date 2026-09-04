import AppKit
import Combine
import RantCore
import SwiftUI

/// Drives selected-text transforms: hotkey, selection, preview, accept or reject.
///
/// `TransformEngine` had all of this — preview, diff, apply, undo, and a refusal for
/// secure fields — and the app referenced none of it. The Transforms screen listed the
/// built-ins and told the user to "press your transform key", which was not registered
/// anywhere, and described a diff that could not be shown.
///
/// The order of operations matters and is easy to get wrong: the selection has to be
/// read from the app the user was in *before* Rant's own panel takes focus, or the
/// accessibility snapshot describes Rant instead. So the context is captured the moment
/// the hotkey fires, and everything after that works from the copy.
@MainActor
final class TransformController: ObservableObject {
  enum Phase: Equatable {
    case idle
    /// Selection captured; the user is choosing what to do with it.
    case choosing(String)
    case working(String)
    case reviewing(TransformPreview)
    case failed(String)
  }

  @Published private(set) var phase: Phase = .idle
  /// The user's edit of the proposal, when they change it before applying.
  @Published var edited: String = ""

  private let engine: TransformEngine
  private let context: AccessibilityContextProvider
  private let contextSettings: () -> ContextSettings
  private let log = RantLog("Transforms")
  private var captured: TranscriptionContext?
  private var panel: NSPanel?

  init(
    engine: TransformEngine,
    context: AccessibilityContextProvider,
    contextSettings: @escaping () -> ContextSettings
  ) {
    self.engine = engine
    self.context = context
    self.contextSettings = contextSettings
  }

  var transforms: [Transform] { Transform.builtIns }

  // MARK: - Entry

  /// Called by the global hotkey.
  func begin() {
    guard phase == .idle else {
      show()
      return
    }
    Task { [weak self] in
      guard let self else { return }
      let snapshot = await context.capture(settings: contextSettings())
      // A password field is the one case where there is nothing to consider: the
      // engine refuses too, but reading the selection at all is what we avoid here.
      guard !snapshot.isSecureField else {
        self.phase = .failed("Rant does not read password fields.")
        self.show()
        return
      }
      let selection = snapshot.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let selection, !selection.isEmpty else {
        self.phase = .failed(
          "Select some text first, then press \(CarbonHotkey.Combination.optionShiftT.displayName).")
        self.show()
        return
      }
      self.captured = snapshot
      self.phase = .choosing(selection)
      self.show()
    }
  }

  func run(_ transform: Transform, targetLanguage: String? = nil, custom: String? = nil) {
    guard case .choosing(let selection) = phase else { return }
    phase = .working(transform.name)
    Task { [weak self] in
      guard let self else { return }
      do {
        let preview = try await engine.preview(
          transform,
          selection: selection,
          context: captured,
          targetLanguage: targetLanguage,
          customInstruction: custom)
        self.edited = preview.proposed
        self.phase = .reviewing(preview)
      } catch {
        self.log.warning("transform failed: \(error.localizedDescription)")
        self.phase = .failed(error.localizedDescription)
      }
    }
  }

  /// Accept the proposal — or the user's edit of it — and replace the selection.
  func accept() {
    guard case .reviewing(let preview) = phase else { return }
    let context = captured
    let edited = self.edited
    Task { [weak self] in
      guard let self else { return }
      do {
        // An edited proposal is a different proposal, so it is registered as one
        // rather than smuggled into the accepted preview. The engine only applies
        // previews it issued, which is what stops a stale one being replayed.
        let final: TransformPreview
        if edited != preview.proposed {
          final = try await engine.previewLocalEdit(
            transformID: preview.transformID,
            selection: preview.original,
            proposed: edited,
            context: context,
            target: preview.target)
        } else {
          final = preview
        }
        self.hide()
        _ = try await engine.apply(final, context: context)
        self.phase = .idle
        self.captured = nil
      } catch {
        self.phase = .failed(error.localizedDescription)
        self.show()
      }
    }
  }

  /// Reject. Nothing has been written, so this only has to forget.
  func reject() {
    phase = .idle
    captured = nil
    edited = ""
    hide()
  }

  func copyResult() {
    guard case .reviewing = phase else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(edited, forType: .string)
  }

  func undoLast() {
    Task { [weak self] in
      guard let self else { return }
      do { _ = try await engine.undoLast(context: self.captured) } catch {
        self.log.warning("nothing to undo: \(error.localizedDescription)")
      }
    }
  }

  func backToChoosing() {
    if let selection = captured?.selectedText?.trimmingCharacters(
      in: .whitespacesAndNewlines), !selection.isEmpty
    {
      phase = .choosing(selection)
    } else {
      reject()
    }
  }

  // MARK: - The panel

  /// A panel rather than a window, and non-activating, so opening it does not steal
  /// focus from the app whose text is about to be replaced.
  private func show() {
    if panel == nil {
      let hosting = NSHostingController(rootView: TransformPanel(controller: self))
      let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
        styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
        backing: .buffered, defer: false)
      panel.contentViewController = hosting
      panel.title = "Transform"
      panel.titlebarAppearsTransparent = true
      panel.isFloatingPanel = true
      panel.level = .floating
      panel.hidesOnDeactivate = false
      panel.center()
      self.panel = panel
    }
    panel?.orderFrontRegardless()
  }

  private func hide() {
    panel?.orderOut(nil)
  }
}
