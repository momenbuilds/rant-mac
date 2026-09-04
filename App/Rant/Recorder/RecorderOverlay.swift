import RantCore
import SwiftUI

/// The floating recorder.
///
/// Designed to be read at a glance and then ignored: one row, a live waveform, a
/// word or two of status, and a way out. It deliberately does not resemble any
/// competitor's bar — the shape here is a soft capsule with the meter reading
/// outward from the centre, which reads as "listening" rather than as a progress bar.
struct RecorderOverlay: View {
  @ObservedObject var controller: OverlayController
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var geometry: MeterGeometry { MeterGeometry(barCount: 26) }

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      statusDot
      content
      Spacer(minLength: 0)
      if controller.state.isBusy { cancelButton }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(width: 320, height: 76)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.large)
        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.28), radius: 22, y: 8)
    .animation(Theme.animation(Theme.springy, reduceMotion: reduceMotion), value: controller.state)
    // One label for the whole thing: VoiceOver should say what is happening, not
    // enumerate 26 waveform bars.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  @ViewBuilder private var content: some View {
    switch controller.state {
    case .listening:
      VStack(alignment: .leading, spacing: 5) {
        waveform
        Text("Listening — release to insert")
          .font(.caption).foregroundStyle(.secondary)
      }
    case .transcribing:
      label("Transcribing…", systemImage: "waveform")
    case .enhancing:
      label("Polishing…", systemImage: "wand.and.stars")
    case .inserting:
      label("Inserting…", systemImage: "text.cursor")
    case .success(let text):
      VStack(alignment: .leading, spacing: 3) {
        Label("Inserted", systemImage: "checkmark.circle.fill")
          .font(.callout.weight(.medium))
          .foregroundStyle(Theme.success)
        Text(text)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    case .failure(let message, let retryable):
      VStack(alignment: .leading, spacing: 3) {
        Label(retryable ? "Something went wrong" : "Could not transcribe", systemImage: "exclamationmark.triangle.fill")
          .font(.callout.weight(.medium))
          .foregroundStyle(Theme.recording)
        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
    case .cancelled:
      label("Cancelled", systemImage: "xmark.circle")
    case .idle:
      VStack(alignment: .leading, spacing: 5) {
        waveform.opacity(0.35)
        Text("Ready").font(.caption).foregroundStyle(.tertiary)
      }
    }
  }

  private func label(_ text: String, systemImage: String) -> some View {
    Label(text, systemImage: systemImage)
      .font(.callout.weight(.medium))
      .foregroundStyle(.primary)
  }

  private var statusDot: some View {
    Circle()
      .fill(dotColour)
      .frame(width: 9, height: 9)
      // The recording pulse is the one piece of motion in the overlay, and it is the
      // one that carries information: it is how you know the microphone is live.
      .opacity(pulses && !reduceMotion ? 0.35 : 1)
      .animation(
        pulses && !reduceMotion
          ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true) : nil,
        value: pulses)
      // With Reduce Motion on, a ring stands in for the pulse rather than losing the
      // signal entirely.
      .overlay(
        Circle()
          .strokeBorder(dotColour.opacity(0.5), lineWidth: pulses && reduceMotion ? 3 : 0)
          .frame(width: 16, height: 16))
  }

  private var pulses: Bool {
    if case .listening = controller.state { return true }
    return false
  }

  private var dotColour: Color {
    switch controller.state {
    case .listening: Theme.recording
    case .success: Theme.success
    case .failure: Theme.recording
    case .idle, .cancelled: .secondary
    default: Theme.accent
    }
  }

  private var waveform: some View {
    let bars = geometry.bars(from: controller.meter)
    return HStack(alignment: .center, spacing: 2.5) {
      ForEach(Array(bars.enumerated()), id: \.offset) { _, height in
        Capsule()
          .fill(Theme.accent.opacity(0.85))
          .frame(width: 2.5, height: max(3, CGFloat(height) * 26))
      }
    }
    .frame(height: 26, alignment: .center)
    .animation(Theme.animation(.linear(duration: 0.06), reduceMotion: reduceMotion), value: controller.meter)
  }

  private var cancelButton: some View {
    Button {
      NotificationCenter.default.post(name: .rantCancelDictation, object: nil)
    } label: {
      Image(systemName: "xmark")
        .font(.system(size: 10, weight: .bold))
        .accessibilityHidden(true)
        .frame(width: 20, height: 20)
        .background(.quaternary, in: Circle())
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
