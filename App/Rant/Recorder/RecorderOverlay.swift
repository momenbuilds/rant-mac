import RantCore
import SwiftUI

/// The floating recorder.
///
/// Designed to be read in a glance and then ignored. It is deliberately not a copy of
/// anyone's bar: the shape is a low capsule with the meter reading outward from a
/// live dot on the left, so the eye lands on "is it listening" first and everything
/// else second. Clay for the app, red only for the microphone being live.
struct RecorderOverlay: View {
  @ObservedObject var controller: OverlayController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var geometry: MeterGeometry { MeterGeometry(barCount: 24) }

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      indicator
      content
      Spacer(minLength: 0)
      if controller.state.isBusy { cancelButton }
    }
    .padding(.horizontal, 15)
    .padding(.vertical, 12)
    .frame(width: 330, height: 72)
    .background(Theme.overlaySurface, in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.panel)
        .strokeBorder(Theme.hairlineStrong, lineWidth: 1))
    .shadow(color: .black.opacity(0.22), radius: 20, y: 7)
    .animation(Theme.animation(Theme.springy, reduceMotion: reduceMotion), value: controller.state)
    // One label for the whole thing: VoiceOver should say what is happening, not
    // enumerate two dozen waveform bars.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  // MARK: - Indicator

  private var indicator: some View {
    ZStack {
      // With Reduce Motion on, a ring stands in for the pulse rather than the signal
      // being lost entirely.
      if pulses && reduceMotion {
        Circle().strokeBorder(tint.opacity(0.45), lineWidth: 3).frame(width: 18, height: 18)
      }
      Circle()
        .fill(tint)
        .frame(width: 9, height: 9)
        .opacity(pulses && !reduceMotion ? 0.35 : 1)
        .animation(
          pulses && !reduceMotion
            ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : nil,
          value: pulses)
    }
    .frame(width: 18)
  }

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

  // MARK: - Content

  @ViewBuilder private var content: some View {
    switch controller.state {
    case .listening:
      VStack(alignment: .leading, spacing: 5) {
        waveform
        Text("Listening — release to insert")
          .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
      }
    case .transcribing:
      status("Transcribing…")
    case .enhancing:
      status("Polishing…")
    case .inserting:
      status("Inserting…")
    case .success(let text):
      VStack(alignment: .leading, spacing: 2) {
        Text("Inserted")
          .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.moss)
        Text(text)
          .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
          .lineLimit(1).truncationMode(.tail)
      }
    case .failure(let message, let retryable):
      VStack(alignment: .leading, spacing: 2) {
        Text(retryable ? "Something went wrong" : "Could not transcribe")
          .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.live)
        Text(message)
          .font(.system(size: 11)).foregroundStyle(Theme.inkMuted).lineLimit(2)
      }
    case .cancelled:
      status("Cancelled")
    case .idle:
      VStack(alignment: .leading, spacing: 5) {
        waveform.opacity(0.3)
        Text("Ready").font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
      }
    }
  }

  private func status(_ text: String) -> some View {
    Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
  }

  private var waveform: some View {
    let bars = geometry.bars(from: controller.meter)
    return HStack(alignment: .center, spacing: 2.5) {
      ForEach(Array(bars.enumerated()), id: \.offset) { _, height in
        Capsule()
          .fill(Theme.clay.opacity(0.9))
          .frame(width: 2.5, height: max(3, CGFloat(height) * 24))
      }
    }
    .frame(height: 24, alignment: .center)
    .animation(
      Theme.animation(.linear(duration: 0.06), reduceMotion: reduceMotion),
      value: controller.meter)
  }

  private var cancelButton: some View {
    Button {
      NotificationCenter.default.post(name: .rantCancelDictation, object: nil)
    } label: {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(Theme.inkMuted)
        .frame(width: 20, height: 20)
        .background(Theme.sunken, in: Circle())
        .accessibilityHidden(true)
    }
    .buttonStyle(.plain)
    .help("Cancel (Escape)")
    .accessibilityLabel("Cancel dictation")
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
}
