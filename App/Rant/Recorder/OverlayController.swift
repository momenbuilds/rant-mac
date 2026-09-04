import AppKit
import RantCore
import SwiftUI

extension Duration {
  /// Whole milliseconds, for a log line.
  var milliseconds: Int {
    let (seconds, attoseconds) = components
    return Int(seconds) * 1_000 + Int(attoseconds / 1_000_000_000_000_000)
  }
}

/// Owns the floating recorder window.
///
/// This is an `NSPanel`, not a SwiftUI `Window`, and the reasons are all
/// non-negotiable behaviours: it must appear above full-screen apps, it must never
/// take focus (taking focus would move the cursor away from the field the user is
/// dictating into, which defeats the entire product), and it must be draggable
/// anywhere on screen including over another app's menu bar.
@MainActor
final class OverlayController: ObservableObject {
  private let log = RantLog("Overlay")
  @Published var state: DictationState = .idle
  @Published var meter: [Float] = []

  private var panel: NSPanel?
  private var hideWorkItem: DispatchWorkItem?
  /// A plain backdrop shown only in demo mode, so a recording of the overlay is a
  /// recording of the overlay rather than of whatever happened to be on the desktop.
  private var backdrop: NSWindow?

  /// Remembered between launches so the overlay comes back where you put it.
  private var savedOrigin: CGPoint? {
    get {
      guard let dictionary = UserDefaults.standard.dictionary(forKey: "rant.overlay.origin"),
        let x = dictionary["x"] as? Double, let y = dictionary["y"] as? Double
      else { return nil }
      return CGPoint(x: x, y: y)
    }
    set {
      guard let newValue else { return }
      UserDefaults.standard.set(["x": newValue.x, "y": newValue.y], forKey: "rant.overlay.origin")
    }
  }

  /// When the command that led to this presentation arrived, so the overlay can
  /// report how long it took to appear. The budget is 100 ms in
  /// `docs/PERFORMANCE.md`, and a budget nobody measures is a wish.
  var commandArrivedAt: ContinuousClock.Instant?

  func show(state: DictationState) {
    self.state = state
    hideWorkItem?.cancel()
    if AppModel.isDemoingOverlay { showBackdrop() }

    let panel = panel ?? makePanel()
    self.panel = panel
    if !panel.isVisible {
      position(panel)
      if let commandArrivedAt {
        let elapsed = ContinuousClock.now - commandArrivedAt
        log.info("overlay visible \(elapsed.milliseconds)ms after the key")
        self.commandArrivedAt = nil
      }
      // `orderFrontRegardless` rather than `makeKeyAndOrderFront`: the panel must
      // become visible without ever becoming key, or the app the user is dictating
      // into loses focus and the text has nowhere to go.
      panel.orderFrontRegardless()
    }

    // Terminal states linger just long enough to be read, then get out of the way.
    switch state {
    case .success, .cancelled:
      scheduleHide(after: 1.1)
    case .failure:
      scheduleHide(after: 4.0)
    default:
      break
    }
  }

  func hide(unless alwaysVisible: Bool) {
    guard !alwaysVisible else {
      state = .idle
      return
    }
    scheduleHide(after: 0.2)
  }

  func updateMeter(_ history: [Float]) {
    meter = history
  }

  private func scheduleHide(after delay: TimeInterval) {
    hideWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, let panel = self.panel else { return }
      self.savedOrigin = panel.frame.origin
      panel.orderOut(nil)
      self.state = .idle
    }
    hideWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  /// A full-screen sheet of the app's own paper colour, one level below the overlay.
  private func showBackdrop() {
    guard backdrop == nil, let screen = NSScreen.main else { return }
    let window = NSWindow(
      contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isOpaque = true
    window.appearance = NSApp.effectiveAppearance
    window.backgroundColor = NSColor(Theme.paper)
    window.level = .init(Int(CGWindowLevelForKey(.statusWindow)) - 1)
    window.collectionBehavior = [.canJoinAllSpaces, .stationary]
    window.ignoresMouseEvents = true
    window.orderFrontRegardless()
    backdrop = window
  }

  private func makePanel() -> NSPanel {
    let panel = NonActivatingPanel(
      contentRect: NSRect(x: 0, y: 0, width: 330, height: 72),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovableByWindowBackground = true
    // Above everything, including other apps' full-screen windows.
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .utilityWindow
    panel.appearance = NSApp.effectiveAppearance
    panel.contentView = NSHostingView(rootView: RecorderOverlay(controller: self))
    return panel
  }

  private func position(_ panel: NSPanel) {
    guard let screen = NSScreen.main else { return }
    if let saved = savedOrigin, screen.frame.contains(CGPoint(x: saved.x + 10, y: saved.y + 10)) {
      panel.setFrameOrigin(saved)
      return
    }
    // Bottom centre, clear of the Dock.
    let frame = screen.visibleFrame
    let origin = CGPoint(
      x: frame.midX - panel.frame.width / 2,
      y: frame.minY + 96)
    panel.setFrameOrigin(origin)
  }
}

/// A panel that refuses to become key, so dictating never steals focus from the app
/// you are dictating into.
private final class NonActivatingPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
