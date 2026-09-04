import AVFoundation
import AppKit
import ApplicationServices
import RantCore

/// The macOS permissions Rant needs, what each one is actually for, and a button
/// that opens the exact pane rather than "System Settings, somewhere".
///
/// Onboarding lives or dies on this. A permission prompt with no explanation gets
/// denied, and a denied permission with no route back is how an app ends up
/// permanently broken on someone's machine with no visible cause.
@MainActor
final class Permissions: ObservableObject {

  enum Status: Equatable {
    case granted
    case denied
    case notDetermined

    var isGranted: Bool { self == .granted }
  }

  @Published private(set) var microphone: Status = .notDetermined
  @Published private(set) var accessibility: Status = .notDetermined
  @Published private(set) var screenRecording: Status = .notDetermined

  /// Fires when a permission changes from not-granted to granted, so the app can act
  /// on it immediately rather than waiting for a relaunch.
  var onGranted: ((Status, Status, Status) -> Void)?

  private var pollTimer: Timer?

  init() { refresh() }

  /// No `deinit` cleanup: the timer holds only a weak reference to this object, so it
  /// cannot keep it alive, and a main-actor property cannot be touched from a
  /// nonisolated `deinit` under strict concurrency. `stopWatching()` is there for a
  /// caller that wants to be explicit.

  @discardableResult
  func refresh() -> Bool {
    let previousAccessibility = accessibility
    microphone = Self.microphoneStatus()
    accessibility = AXIsProcessTrusted() ? .granted : .notDetermined
    screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined

    let becameGranted = previousAccessibility != .granted && accessibility == .granted
    if becameGranted {
      onGranted?(microphone, accessibility, screenRecording)
    }
    return becameGranted
  }

  /// Watches for a permission being granted while the app is running.
  ///
  /// Granting Accessibility happens in System Settings, in another process, and macOS
  /// sends no notification about it. Checking once at launch means the user grants the
  /// permission, comes back, and the app still insists it is not ready — which reads
  /// as the app being broken rather than as the app not having looked again.
  ///
  /// So it polls. `AXIsProcessTrusted` is a cheap local call, and the poll is slow
  /// enough to be free and fast enough that returning to the window feels immediate.
  /// It also refreshes whenever the app is reactivated, which is the moment it
  /// actually matters — you grant the permission, then switch back.
  func startWatching() {
    pollTimer?.invalidate()
    let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refresh() }
    }
    RunLoop.main.add(timer, forMode: .common)
    pollTimer = timer

    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refresh() }
    }
  }

  func stopWatching() {
    pollTimer?.invalidate()
    pollTimer = nil
  }

  private static func microphoneStatus() -> Status {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: .granted
    case .denied, .restricted: .denied
    case .notDetermined: .notDetermined
    @unknown default: .notDetermined
    }
  }

  /// Asks for the microphone. The only one of the three that can be granted by a
  /// system prompt without a trip to Settings.
  func requestMicrophone() async {
    _ = await AVCaptureDevice.requestAccess(for: .audio)
    refresh()
  }

  /// Accessibility cannot be granted programmatically. This shows the system's own
  /// prompt, which at least offers a direct route to the right pane.
  func requestAccessibility() {
    // The constant is a global `var` in the C headers, which strict concurrency
    // rejects. The key it holds is stable API, so naming it directly is both safe
    // and clearer than working around the import.
    let options = ["AXTrustedCheckOptionPrompt": true]
    _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    refresh()
  }

  func requestScreenRecording() {
    CGRequestScreenCaptureAccess()
    refresh()
  }

  /// Deep links straight to the right pane. Getting these exactly right is the
  /// difference between "click here" and "hunt through Settings".
  enum Pane: String {
    case microphone = "Privacy_Microphone"
    case accessibility = "Privacy_Accessibility"
    case screenRecording = "Privacy_ScreenCapture"
    case calendar = "Privacy_Calendars"

    var url: URL {
      URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!
    }
  }

  func open(_ pane: Pane) {
    NSWorkspace.shared.open(pane.url)
  }

  /// True when we have been running long enough that a user who was going to grant
  /// Accessibility has probably tried — at which point "still not granted" is more
  /// likely a stale TCC entry than someone who has not got round to it.
  ///
  /// It is a heuristic and it only changes what advice is offered, never behaviour.
  var looksStale: Bool {
    Date().timeIntervalSince(startedAt) > 20
  }

  private let startedAt = Date()

  /// Everything dictation needs. Screen recording is deliberately excluded — it is
  /// only for the notetaker, and a user who never records meetings should never be
  /// nagged about it.
  var isReadyForDictation: Bool {
    microphone.isGranted && accessibility.isGranted
  }
}

/// What each permission is for, in the user's terms. Kept next to the code that asks
/// for them so the two cannot drift apart.
struct PermissionCopy {
  let title: String
  let why: String
  let ifDenied: String
  let required: Bool

  static let microphone = PermissionCopy(
    title: "Microphone",
    why: "So Rant can hear you while you hold your dictation key. Audio is not kept unless you turn retention on yourself.",
    ifDenied: "Without it, Rant cannot transcribe anything at all.",
    required: true)

  static let accessibility = PermissionCopy(
    title: "Accessibility",
    why: "So Rant can tell which text field you are typing in and put the text there — and so your dictation key works everywhere, not just inside Rant.",
    ifDenied: "Rant will fall back to leaving text on your clipboard, which is slower and less reliable.",
    required: true)

  static let screenRecording = PermissionCopy(
    title: "Screen Recording",
    why: "Only so the meeting notetaker can hear the other people on a call. macOS classes system audio under screen recording.",
    ifDenied: "Dictation is unaffected. The notetaker will record only your side of a call.",
    required: false)
}
