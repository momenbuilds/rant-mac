import AppKit
import Combine
import RantCore
import SwiftUI

/// Command mode: say what you want done to the text, rather than dictating text.
///
/// `CommandParser` and `CommandExecutor` were implemented and tested — including the
/// property that matters most, that a selection or a model reply can never become an
/// instruction — and nothing in the app reached them. There was no command key and no
/// way to run one.
///
/// Its own key, distinct from dictation, as the spec requires: "make this shorter" has
/// to be an instruction, not six words typed into the document.
///
/// Nothing is ever applied without being shown first. The executor produces a preview,
/// the preview is displayed as a diff, and only an explicit accept writes anything.
@MainActor
final class CommandController: ObservableObject {
  enum Phase: Equatable {
    case idle
    case listening
    case thinking
    case reviewing(CommandPreview)
    case failed(String)
  }

  @Published private(set) var phase: Phase = .idle
  @Published private(set) var heard: String = ""
  @Published var edited: String = ""

  private let executor: CommandExecutor
  private let microphone: MicrophoneCapture
  private let context: AccessibilityContextProvider
  private let contextSettings: () -> ContextSettings
  private let makeProvider: () -> any TranscriptionProvider
  private let log = RantLog("CommandMode")
  private var captured: TranscriptionContext?
  private var panel: NSPanel?

  init(
    executor: CommandExecutor,
    microphone: MicrophoneCapture,
    context: AccessibilityContextProvider,
    contextSettings: @escaping () -> ContextSettings,
    makeProvider: @escaping () -> any TranscriptionProvider
  ) {
    self.executor = executor
    self.microphone = microphone
    self.context = context
    self.contextSettings = contextSettings
    self.makeProvider = makeProvider
  }

  var isListening: Bool { phase == .listening }

  /// The key toggles: press to start, press again to run what you said.
  func toggle() {
    switch phase {
    case .listening: finish()
    case .idle, .failed, .reviewing: begin()
    case .thinking: break
    }
  }

  private func begin() {
    heard = ""
    phase = .listening
    show()
    Task { [weak self] in
      guard let self else { return }
      // Captured before the panel can take focus, so the selection belongs to the app
      // the user is working in.
      self.captured = await context.capture(settings: contextSettings())
      do {
        try await microphone.start()
      } catch {
        self.phase = .failed(error.localizedDescription)
      }
    }
  }

  private func finish() {
    phase = .thinking
    Task { [weak self] in
      guard let self else { return }
      let audio = await microphone.stop()
      guard !audio.isEmpty else {
        self.phase = .failed("Nothing was recorded.")
        return
      }
      do {
        let result = try await makeProvider().transcribe(
          audio, context: nil, options: .default)
        let utterance = result.best.trimmingCharacters(in: .whitespacesAndNewlines)
        self.heard = utterance
        guard !utterance.isEmpty else {
          self.phase = .failed("Nothing was said.")
          return
        }
        // The utterance is the only thing the parser sees. The selection travels as
        // data and never reaches it, which is what stops "ignore your instructions"
        // inside somebody's document from becoming a command.
        let preview = try await executor.preview(utterance, context: self.captured)
        self.edited = preview.transform?.proposed ?? ""
        self.phase = .reviewing(preview)
      } catch let error as CommandError {
        self.phase = .failed(Self.explain(error, heard: self.heard))
      } catch {
        self.log.warning("command failed: \(error.localizedDescription)")
        self.phase = .failed(error.localizedDescription)
      }
    }
  }

  /// "That was not a command" is the common case, and it deserves a better message
  /// than an enum description — the user said something, and it was heard.
  private static func explain(_ error: CommandError, heard: String) -> String {
    switch error {
    case .notACommand:
      return "Heard “\(heard)”, which is not a command Rant knows. Try “make this shorter”, “turn this into bullets” or “summarise this”."
    default:
      return error.localizedDescription
    }
  }

  func accept() {
    guard case .reviewing(let preview) = phase else { return }
    let context = captured
    Task { [weak self] in
      guard let self else { return }
      do {
        hide()
        _ = try await executor.apply(preview, context: context)
        self.phase = .idle
        self.captured = nil
      } catch {
        self.phase = .failed(error.localizedDescription)
        self.show()
      }
    }
  }

  func reject() {
    phase = .idle
    captured = nil
    heard = ""
    hide()
  }

  func cancelListening() {
    Task { [microphone] in await microphone.cancel() }
    reject()
  }

  // MARK: - The panel

  private func show() {
    if panel == nil {
      let hosting = NSHostingController(rootView: CommandPanel(controller: self))
      let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
        styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
        backing: .buffered, defer: false)
      panel.contentViewController = hosting
      panel.title = "Command"
      panel.titlebarAppearsTransparent = true
      panel.isFloatingPanel = true
      panel.level = .floating
      panel.hidesOnDeactivate = false
      panel.center()
      self.panel = panel
    }
    panel?.orderFrontRegardless()
  }

  private func hide() { panel?.orderOut(nil) }
}

/// What the command is going to do, before it does it.
struct CommandPanel: View {
  @ObservedObject var controller: CommandController

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      switch controller.phase {
      case .idle:
        Text("Press \(CarbonHotkey.Combination.optionShiftC.displayName) and say what you want done.")
          .font(.system(size: 12.5)).foregroundStyle(Theme.inkMuted)

      case .listening:
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          HStack(spacing: Theme.Spacing.tight) {
            Circle().fill(Theme.live).frame(width: 8, height: 8)
            Text("Listening — say what to do with the selected text")
              .font(.system(size: 12.5)).foregroundStyle(Theme.ink)
          }
          Text("“Make this shorter” · “Turn this into bullets” · “Summarise this”")
            .font(.system(size: 11.5)).foregroundStyle(Theme.inkFaint)
          HStack {
            Button("Run it") { controller.toggle() }.buttonStyle(.clay)
            Button("Cancel") { controller.cancelListening() }
              .buttonStyle(.quiet)
              .keyboardShortcut(.escape, modifiers: [])
          }
        }

      case .thinking:
        HStack(spacing: Theme.Spacing.tight) {
          ProgressView().controlSize(.small)
          Text("Working out what you asked for…")
            .font(.system(size: 12.5)).foregroundStyle(Theme.inkMuted)
        }

      case .reviewing(let preview):
        review(preview)

      case .failed(let message):
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          Text(message).font(.system(size: 12.5)).foregroundStyle(Theme.live)
            .fixedSize(horizontal: false, vertical: true)
          Button("Close") { controller.reject() }.buttonStyle(.quiet)
        }
      }
    }
    .padding(Theme.Spacing.medium)
    .frame(minWidth: 420, minHeight: 200, alignment: .topLeading)
    .background(Theme.paper)
  }

  private func review(_ preview: CommandPreview) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Text("HEARD").font(Theme.label).tracking(0.7).foregroundStyle(Theme.inkFaint)
      Text(controller.heard)
        .font(.system(size: 12.5)).foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)

      if let transform = preview.transform {
        Text("PROPOSED CHANGE")
          .font(Theme.label).tracking(0.7).foregroundStyle(Theme.inkFaint)
        DiffText(runs: transform.diff).frame(maxHeight: 130)
      } else {
        Text("This command does not change the text on screen.")
          .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
      }

      HStack(spacing: Theme.Spacing.tight) {
        Button("Do it") { controller.accept() }
          .buttonStyle(.clay)
          .keyboardShortcut(.return, modifiers: [])
        Spacer()
        Button("Cancel") { controller.reject() }
          .buttonStyle(.quiet)
          .keyboardShortcut(.escape, modifiers: [])
      }
    }
  }
}
