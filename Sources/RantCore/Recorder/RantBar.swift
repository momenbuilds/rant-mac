import Foundation

/// What the floating recorder is showing, and how big it is.
///
/// Separated from the SwiftUI view on purpose. "Which shape is the bar in, and what
/// does it contain" is a decision with real rules — a success flash has a minimum
/// duration, an error must not collapse to a checkmark, a hands-free recording looks
/// different from a held key — and rules belong somewhere a test can reach. The view
/// then has nothing left to decide; it draws what this says.
public enum RantBarPhase: Equatable, Sendable {
  /// Not on screen, or on screen only because the user asked for it to stay.
  case idle
  case listening(handsFree: Bool)
  case processing(RantBarWork)
  case success
  case error(String, retryable: Bool)
  case cancelling

  public var isListening: Bool {
    if case .listening = self { return true }
    return false
  }

  public var isProcessing: Bool {
    if case .processing = self { return true }
    return false
  }
}

/// Which part of the pipeline is running. Shown as a shape, never as a word — the bar
/// is too small for "Transcribing" to be read at a glance, and the distinction matters
/// to a developer reading a log rather than to somebody waiting two seconds.
public enum RantBarWork: Equatable, Sendable {
  case transcribing
  case enhancing
  case inserting
}

/// The geometry and content of the bar for a given phase.
///
/// Every size here is in points and every one is deliberate. The bar sits over
/// whatever the user is writing in, so it earns its space by being small: it should be
/// legible in peripheral vision and ignorable in direct vision.
public struct RantBarLayout: Equatable, Sendable {
  public var width: Double
  public var height: Double
  public var showsWaveform: Bool
  /// The collapsed processing animation — four bars pulsing where the waveform was.
  public var showsWorkingDots: Bool
  public var showsCheck: Bool
  public var showsErrorGlyph: Bool
  /// The tiny padlock, shown only when the recording is locked open.
  public var showsHandsFreeLock: Bool
  /// Whether hovering may reveal the cancel and stop controls.
  public var allowsControls: Bool
  /// The short line shown in the bar. Kept short by construction — see
  /// `shortReason(for:retryable:)`.
  public var message: String?
  /// The full text, for the tooltip and for the window a click opens. Never drawn in
  /// the bar itself.
  public var detail: String?

  public static let cornerRadius: Double = 21

  /// Reserved so the panel never has to resize while the bar is animating: the panel
  /// is sized once to the widest state plus room for the shadow, and the capsule
  /// changes shape inside it. Resizing a window in step with a spring is a way to get
  /// a bar that judders on exactly the machines you cannot reproduce it on.
  public static let maximumWidth: Double = 280
  public static let maximumHeight: Double = 44
  /// Room for the drop shadow, and for the success state's short drop as it fades.
  public static let shadowMargin: Double = 26
}

extension RantBarLayout {

  /// How long a message may be before the bar stops trying to show it.
  ///
  /// Short enough to fit at the error width without truncation. "Nothing was
  /// recorded." fits; "Could not reach the speech provider. The request timed out."
  /// does not, and showing the first half of that is worse than a clear instruction.
  static let reasonLimit = 26

  static func shortReason(for message: String, retryable: Bool) -> String {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty, trimmed.count <= reasonLimit { return trimmed }
    return retryable ? "Try again" : "That didn't work"
  }

  /// The layout for a phase.
  ///
  /// `expanded` is the long-dictation state: the bar grows to show the newest few
  /// words. It is a parameter rather than a phase because it is orthogonal — a
  /// recording is expanded or not regardless of whether it is hands-free.
  public static func forPhase(_ phase: RantBarPhase, expanded: Bool = false) -> RantBarLayout {
    switch phase {
    case .idle:
      return RantBarLayout(
        width: 132, height: 40, showsWaveform: true, showsWorkingDots: false,
        showsCheck: false, showsErrorGlyph: false, showsHandsFreeLock: false,
        allowsControls: false, message: nil, detail: nil)

    case .listening(let handsFree):
      return RantBarLayout(
        width: expanded ? 264 : 160,
        height: 44,
        showsWaveform: true, showsWorkingDots: false, showsCheck: false,
        showsErrorGlyph: false, showsHandsFreeLock: handsFree,
        allowsControls: true, message: nil, detail: nil)

    case .processing:
      // Narrower than listening, so stopping *reads* as something having happened
      // even before the checkmark.
      return RantBarLayout(
        width: 98, height: 38, showsWaveform: false, showsWorkingDots: true,
        showsCheck: false, showsErrorGlyph: false, showsHandsFreeLock: false,
        allowsControls: false, message: nil, detail: nil)

    case .success:
      return RantBarLayout(
        width: 58, height: 36, showsWaveform: false, showsWorkingDots: false,
        showsCheck: true, showsErrorGlyph: false, showsHandsFreeLock: false,
        allowsControls: false, message: nil, detail: nil)

    case .error(let message, let retryable):
      // A failure must not turn a 44-point bar into a dialog box. The bar carries a
      // short reason; the full text lives in the tooltip and in the window a click
      // opens — a provider's sentence does not fit here, and half of it truncated
      // mid-word tells the user less than a plain instruction would.
      return RantBarLayout(
        width: 178, height: 40, showsWaveform: false, showsWorkingDots: false,
        showsCheck: false, showsErrorGlyph: true, showsHandsFreeLock: false,
        allowsControls: false,
        message: shortReason(for: message, retryable: retryable),
        detail: message)

    case .cancelling:
      return RantBarLayout(
        width: 96, height: 36, showsWaveform: false, showsWorkingDots: false,
        showsCheck: false, showsErrorGlyph: false, showsHandsFreeLock: false,
        allowsControls: false, message: nil, detail: nil)
    }
  }
}

/// How the bar is driven by the dictation pipeline.
///
/// One place that turns a `DictationState` into a phase, so the view never switches on
/// pipeline states and the mapping can be tested on its own.
public enum RantBarProjection {

  /// How long the success flash stays up. Long enough to register as confirmation,
  /// short enough that nobody waits for it.
  public static let successDuration: Double = 0.28
  /// The floor on the processing animation. Without it a fast transcription produces a
  /// single frame of dots, which reads as a glitch rather than as speed. It is a floor
  /// on the *animation*, never a delay on the text.
  public static let minimumProcessingDuration: Double = 0.15
  /// How long an error stays before it gets out of the way on its own.
  public static let errorDuration: Double = 4.0
  /// The cancel collapse. Short: cancelling should feel like the bar was never there.
  public static let cancelDuration: Double = 0.16
  /// How long a recording has to run before the bar is allowed to grow and show words.
  public static let expansionThreshold: Double = 4.5

  public static func phase(for state: DictationState, handsFree: Bool) -> RantBarPhase {
    switch state {
    case .idle: .idle
    case .listening: .listening(handsFree: handsFree)
    case .transcribing: .processing(.transcribing)
    case .enhancing: .processing(.enhancing)
    case .inserting: .processing(.inserting)
    case .success: .success
    case .failure(let message, let retryable): .error(message, retryable: retryable)
    case .cancelled: .cancelling
    }
  }

  /// Whether the bar should be showing live words right now.
  ///
  /// The setting decides *whether*, the elapsed time decides *when*. Both have to
  /// agree, which is why this is one function rather than two conditions in a view.
  public static func showsLiveWords(
    _ preference: LiveWordsPreference, elapsed: Double, hasWords: Bool
  ) -> Bool {
    guard hasWords else { return false }
    switch preference {
    case .never: return false
    case .always: return true
    case .longDictations: return elapsed >= expansionThreshold
    }
  }
}

/// When the recorder may grow to show what is being said.
public enum LiveWordsPreference: String, CaseIterable, Sendable, Codable {
  case never
  case longDictations
  case always

  public var displayName: String {
    switch self {
    case .never: "Off"
    case .longDictations: "Long dictations only"
    case .always: "Always"
    }
  }
}
