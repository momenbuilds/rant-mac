import RantCore
import SwiftUI

/// The floating recorder.
///
/// A compact pill rather than a panel: cancel on the left, the meter in the middle,
/// confirm on the right. It sits over whatever you are writing in, so it has to be
/// small enough to ignore and legible enough to read in the corner of your eye — and
/// the two things you might want mid-dictation, *stop* and *throw it away*, should be
/// one click each rather than hidden behind a keyboard shortcut you have to remember.
///
/// The surface is a solid colour, not a material. A material samples what is behind
/// it, so contrast depended on the wallpaper it happened to sit over — readable on a
/// dark desktop, washed out on a light one. This is the one surface in the app that
/// floats over arbitrary content, so it is the one that cannot be translucent.
struct RecorderOverlay: View {
  @ObservedObject var controller: OverlayController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The pill's own metrics. Kept here rather than in the theme because nothing else
  /// in the app is this shape.
  private enum Pill {
    static let height: CGFloat = 34
    static let control: CGFloat = 22
    static let barCount = 16
  }

  private var geometry: MeterGeometry { MeterGeometry(barCount: Pill.barCount) }

  var body: some View {
    HStack(spacing: 6) {
      leading
      centre
      trailing
    }
    .padding(.horizontal, 6)
    .frame(height: Pill.height)
    .background(Theme.overlaySurface, in: Capsule())
    .overlay(Capsule().strokeBorder(Theme.hairlineStrong, lineWidth: 1))
    .shadow(color: .black.opacity(0.24), radius: 11, y: 3)
    .animation(Theme.animation(Theme.springy, reduceMotion: reduceMotion), value: controller.state)
    // One label for the whole thing: VoiceOver should say what is happening, not
    // enumerate twenty-two waveform bars.
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabel)
  }

  // MARK: - Left

  @ViewBuilder private var leading: some View {
    if controller.state.isBusy {
      circleButton(
        icon: "xmark", label: "Cancel dictation", tint: Theme.inkMuted, fill: Theme.sunken
      ) {
        NotificationCenter.default.post(name: .rantCancelDictation, object: nil)
      }
    } else {
      statusDot
        .frame(width: Pill.control, height: Pill.control)
    }
  }

  private var statusDot: some View {
    ZStack {
      if pulses && reduceMotion {
        // With Reduce Motion on, a ring stands in for the pulse rather than the
        // signal being lost entirely.
        Circle().strokeBorder(tint.opacity(0.45), lineWidth: 2).frame(width: 13, height: 13)
      }
      Circle()
        .fill(tint)
        .frame(width: 7, height: 7)
        .opacity(pulses && !reduceMotion ? 0.35 : 1)
        .animation(
          pulses && !reduceMotion
            ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : nil,
          value: pulses)
    }
  }

  // MARK: - Middle

  @ViewBuilder private var centre: some View {
    switch controller.state {
    case .listening:
      waveform.frame(width: 86)
    case .transcribing, .enhancing, .inserting:
      HStack(spacing: 7) {
        ProgressView().controlSize(.small).scaleEffect(0.7)
        Text(busyLabel)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(Theme.ink)
      }
      .frame(width: 96)
    case .success(let text):
      Text(text)
        .font(.system(size: 11))
        .foregroundStyle(Theme.inkMuted)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(width: 132, alignment: .leading)
    case .failure(let message, _):
      Text(message)
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.live)
        .lineLimit(2)
        .frame(width: 150, alignment: .leading)
    case .cancelled:
      Text("Cancelled")
        .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
        .frame(width: 96, alignment: .leading)
    case .idle:
      waveform.frame(width: 86).opacity(0.28)
    }
  }

  private var busyLabel: String {
    switch controller.state {
    case .transcribing: "Transcribing"
    case .enhancing: "Polishing"
    case .inserting: "Inserting"
    default: ""
    }
  }

  private var waveform: some View {
    let bars = geometry.bars(from: controller.meter)
    return HStack(alignment: .center, spacing: 2) {
      ForEach(Array(bars.enumerated()), id: \.offset) { _, height in
        Capsule()
          .fill(Theme.clay)
          .frame(width: 2, height: max(2.5, CGFloat(height) * 15))
      }
    }
    .frame(height: 15)
    .animation(
      Theme.animation(.linear(duration: 0.06), reduceMotion: reduceMotion),
      value: controller.meter)
  }

  // MARK: - Right

  @ViewBuilder private var trailing: some View {
    switch controller.state {
    case .listening:
      // Finish now. The key does this too, but a button means you can stop without
      // remembering which key you chose.
      circleButton(
        icon: "checkmark", label: "Finish and insert", tint: .white, fill: Theme.clay
      ) {
        NotificationCenter.default.post(name: .rantFinishDictation, object: nil)
      }
    case .success:
      Image(systemName: "checkmark")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(Theme.moss)
        .frame(width: Pill.control, height: Pill.control)
        .accessibilityHidden(true)
    case .failure(_, let retryable):
      if retryable {
        circleButton(
          icon: "arrow.clockwise", label: "Try again", tint: .white, fill: Theme.clay
        ) {
          NotificationCenter.default.post(name: .rantRetryDictation, object: nil)
        }
      } else {
        Color.clear.frame(width: 4, height: Pill.control)
      }
    default:
      Color.clear.frame(width: 4, height: Pill.control)
    }
  }

  private func circleButton(
    icon: String, label: String, tint: Color, fill: Color, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(tint)
        .frame(width: Pill.control, height: Pill.control)
        .background(fill, in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
  }

  // MARK: - Shared

  private var pulses: Bool {
    if case .listening = controller.state { return true }
    return false
  }

  private var tint: Color {
    switch controller.state {
    case .listening, .failure: Theme.live
    case .success: Theme.moss
    case .idle, .cancelled: Theme.inkFaint
    default: Theme.clay
    }
  }

  private var accessibilityLabel: String {
    switch controller.state {
    case .idle: "Rant is ready"
    case .listening: "Rant is listening. Release your dictation key to insert, or press Escape to cancel."
    case .transcribing: "Transcribing"
    case .enhancing: "Polishing the text"
    case .inserting: "Inserting text"
    case .success(let text): "Inserted: \(text)"
    case .failure(let message, _): "Dictation failed: \(message)"
    case .cancelled: "Dictation cancelled"
    }
  }
}

extension Notification.Name {
  static let rantCancelDictation = Notification.Name("rant.cancelDictation")
  static let rantToggleDictation = Notification.Name("rant.toggleDictation")
  static let rantFinishDictation = Notification.Name("rant.finishDictation")
  static let rantRetryDictation = Notification.Name("rant.retryDictation")
}
