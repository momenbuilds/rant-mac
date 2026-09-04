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

/// Owns the Rant Bar's window.
///
/// This is an `NSPanel`, not a SwiftUI `Window`, and the reasons are all
/// non-negotiable behaviours: it must appear above full-screen apps, it must never
/// take focus (taking focus would move the cursor away from the field the user is
/// dictating into, which defeats the entire product), and it must be draggable
/// anywhere on screen including over another app's menu bar.
///
/// The controller owns *timing* — how long a success flash lasts, the floor under the
/// processing animation, when a long recording may expand — and the view owns
/// appearance. Both read the same `RantBarProjection` constants, so the numbers exist
/// once and are testable.
@MainActor
final class OverlayController: ObservableObject {
  private let log = RantLog("Overlay")
  @Published var state: DictationState = .idle
  @Published var meter: [Float] = []
  /// Interim text from a streaming provider. Empty when there is no live preview,
  /// which is the normal case for the on-device engine.
  @Published var partial: String = ""
  /// True while the recording is locked open, so the bar can show a padlock.
  @Published var handsFree = false
  /// True once a recording has run long enough — and the setting allows — for the bar
  /// to grow and show the newest words.
  @Published private(set) var showsLiveWords = false
  /// Drives the short drop-and-fade on the way out. Separate from `state` because the
  /// bar leaves the screen after the pipeline has already finished.
  @Published private(set) var isDismissing = false

  /// When the bar may show live words. Set from `Preferences`.
  var liveWordsPreference: LiveWordsPreference = .longDictations

  private var panel: NSPanel?
  private var hideWorkItem: DispatchWorkItem?
  private var pendingWork: [DispatchWorkItem] = []
  private var recordingStartedAt: Date?
  private var processingStartedAt: Date?
  /// A plain backdrop shown only in demo mode, so a recording of the overlay is a
  /// recording of the overlay rather than of whatever happened to be on the desktop.
  private var backdrop: NSWindow?

  /// Where the user dragged the bar, as a fraction of the screen's visible width and a
  /// distance up from its bottom edge.
  ///
  /// Relative rather than absolute so it survives moving between displays of different
  /// sizes — an absolute point remembered on a 6K display puts the bar off-screen on a
  /// laptop, which is how a "remembered position" becomes a bar you cannot find.
  private var savedPlacement: (fractionX: Double, offsetY: Double)? {
    get {
      guard let stored = UserDefaults.standard.dictionary(forKey: Self.placementKey),
        let x = stored["fx"] as? Double, let y = stored["dy"] as? Double
      else { return nil }
      return (x, y)
    }
    set {
      guard let newValue else {
        UserDefaults.standard.removeObject(forKey: Self.placementKey)
        return
      }
      UserDefaults.standard.set(
        ["fx": newValue.fractionX, "dy": newValue.offsetY], forKey: Self.placementKey)
    }
  }

  private static let placementKey = "rant.overlay.placement"

  /// Force the expanded state on, for the off-screen state gallery.
  ///
  /// `showsLiveWords` is normally derived from elapsed recording time, which an
  /// off-screen render has none of.
  func forceLiveWordsForRendering() {
    showsLiveWords = true
  }

  /// Put the bar back at the bottom centre. Exposed for Settings.
  func resetPosition() {
    savedPlacement = nil
    if let panel, panel.isVisible { position(panel) }
  }

  /// When the command that led to this presentation arrived, so the overlay can
  /// report how long it took to appear. The budget is 100 ms in
  /// `docs/PERFORMANCE.md`, and a budget nobody measures is a wish.
  var commandArrivedAt: ContinuousClock.Instant?

  // MARK: - Presenting

  func show(state new: DictationState) {
    cancelPendingWork()
    isDismissing = false

    switch new {
    case .listening:
      recordingStartedAt = recordingStartedAt ?? Date()
      processingStartedAt = nil
      apply(new)

    case .transcribing, .enhancing, .inserting:
      if processingStartedAt == nil { processingStartedAt = Date() }
      recordingStartedAt = nil
      showsLiveWords = false
      apply(new)

    case .success:
      // Hold the processing animation to its floor before flashing the checkmark. A
      // transcription that returns in 40 ms would otherwise show one frame of dots,
      // which reads as a glitch rather than as speed. The *text* is never delayed —
      // it has already been inserted by the time this runs.
      after(remainingProcessingTime) { [weak self] in
        guard let self else { return }
        self.apply(new)
        self.after(RantBarProjection.successDuration) { self.dismiss() }
      }

    case .failure:
      apply(new)
      after(RantBarProjection.errorDuration) { [weak self] in self?.dismiss() }

    case .cancelled:
      apply(new)
      after(RantBarProjection.cancelDuration) { [weak self] in self?.dismiss() }

    case .idle:
      apply(new)
    }
  }

  /// Put the state on screen, sizing the panel to it first.
  private func apply(_ new: DictationState) {
    state = new
    if AppModel.wantsDemoBackdrop { showBackdrop() }

    let panel = panel ?? makePanel()
    self.panel = panel
    resize(panel, for: new, animated: panel.isVisible)

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
  }

  private var remainingProcessingTime: Double {
    guard let processingStartedAt else { return 0 }
    let shown = Date().timeIntervalSince(processingStartedAt)
    return max(0, RantBarProjection.minimumProcessingDuration - shown)
  }

  func hide(unless alwaysVisible: Bool) {
    cancelPendingWork()
    recordingStartedAt = nil
    processingStartedAt = nil
    showsLiveWords = false
    handsFree = false
    guard !alwaysVisible else {
      isDismissing = false
      apply(.idle)
      return
    }
    dismiss()
  }

  /// The way out: a short drop and fade, then the window goes away.
  private func dismiss() {
    guard let panel, panel.isVisible else {
      state = .idle
      return
    }
    isDismissing = true
    after(0.20) { [weak self] in
      guard let self, let panel = self.panel else { return }
      self.rememberPlacement(of: panel)
      panel.orderOut(nil)
      self.isDismissing = false
      self.state = .idle
      self.handsFree = false
      self.showsLiveWords = false
    }
  }

  // MARK: - Live data

  /// Called about thirty times a second while a dictation is running.
  ///
  /// The expansion decision lives here rather than on its own timer: this already
  /// ticks at exactly the moments it could change, and a second timer for a boolean
  /// would be a timer running during every recording for no reason.
  func updateMeter(_ history: [Float]) {
    meter = history
    guard let started = recordingStartedAt else { return }
    let wanted = RantBarProjection.showsLiveWords(
      liveWordsPreference,
      elapsed: Date().timeIntervalSince(started),
      hasWords: !partial.isEmpty)
    if wanted != showsLiveWords { showsLiveWords = wanted }
  }

  func updatePartial(_ text: String) {
    partial = text
  }

  // MARK: - Window

  private func cancelPendingWork() {
    hideWorkItem?.cancel()
    hideWorkItem = nil
    for item in pendingWork { item.cancel() }
    pendingWork.removeAll()
  }

  private func after(_ delay: Double, _ body: @escaping () -> Void) {
    guard delay > 0 else { return body() }
    let work = DispatchWorkItem(block: body)
    pendingWork.append(work)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  /// Size the window to the phase, keeping the capsule centred inside it.
  ///
  /// Growing happens first so the capsule has room to animate into; shrinking waits
  /// until the morph has settled, or the window would clip the shape mid-flight. The
  /// panel is only ever a little larger than the bar, which matters because a floating
  /// window swallows clicks over its whole frame — a permanently oversized one would
  /// put a dead zone around a bar the user has asked to keep on screen.
  private func resize(_ panel: NSPanel, for new: DictationState, animated: Bool) {
    let phase = RantBarProjection.phase(for: new, handsFree: handsFree)
    let layout = RantBarLayout.forPhase(phase, expanded: showsLiveWords)
    let margin = RantBarLayout.shadowMargin
    let target = NSSize(
      width: layout.width + margin * 2,
      height: RantBarLayout.maximumHeight + margin * 2)

    guard animated else { return setSize(panel, target) }
    if target.width >= panel.frame.width {
      setSize(panel, target)
    } else {
      after(0.36) { [weak self] in
        guard let self, let panel = self.panel, panel.isVisible else { return }
        self.setSize(panel, target)
      }
    }
  }

  /// Resize about the horizontal centre, so a morph does not appear to slide.
  private func setSize(_ panel: NSPanel, _ size: NSSize) {
    let frame = panel.frame
    guard abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 else {
      return
    }
    let origin = CGPoint(
      x: frame.midX - size.width / 2,
      y: frame.midY - size.height / 2)
    panel.setFrame(NSRect(origin: origin, size: size), display: true)
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
    let margin = RantBarLayout.shadowMargin
    let panel = NonActivatingPanel(
      contentRect: NSRect(
        x: 0, y: 0,
        width: 160 + margin * 2,
        height: RantBarLayout.maximumHeight + margin * 2),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    // SwiftUI draws the shadow, so that it follows the capsule as it morphs rather
    // than the window's square frame.
    panel.hasShadow = false
    panel.isMovableByWindowBackground = true
    // Hover reveals the controls, which needs mouse-moved events in a window that
    // never becomes key.
    panel.acceptsMouseMovedEvents = true
    // Above everything, including other apps' full-screen windows.
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .none
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.contentView = NSHostingView(rootView: RantBar(controller: self))
    return panel
  }

  // MARK: - Placement

  /// The display the user is actually working on.
  ///
  /// The pointer is the most reliable signal available: the key window belongs to
  /// another application, and Rant's own windows say nothing about where the user is
  /// looking. Falls back to the main display when the pointer is somewhere unhelpful.
  private var activeScreen: NSScreen? {
    let pointer = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
  }

  private func position(_ panel: NSPanel) {
    guard let screen = activeScreen else { return }
    let visible = screen.visibleFrame

    if let placement = savedPlacement {
      let x = visible.minX + visible.width * placement.fractionX - panel.frame.width / 2
      let y = visible.minY + placement.offsetY
      panel.setFrameOrigin(
        CGPoint(
          x: min(max(x, visible.minX), visible.maxX - panel.frame.width),
          y: min(max(y, visible.minY), visible.maxY - panel.frame.height)))
      return
    }

    // Bottom centre of the active display, clear of the Dock.
    panel.setFrameOrigin(
      CGPoint(
        x: visible.midX - panel.frame.width / 2,
        y: visible.minY + 84))
  }

  private func rememberPlacement(of panel: NSPanel) {
    guard let screen = activeScreen else { return }
    let visible = screen.visibleFrame
    guard visible.width > 0 else { return }
    savedPlacement = (
      fractionX: (panel.frame.midX - visible.minX) / visible.width,
      offsetY: panel.frame.minY - visible.minY
    )
  }
}

/// A panel that refuses to become key, so dictating never steals focus from the app
/// you are dictating into.
private final class NonActivatingPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
