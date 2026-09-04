import RantCore
import SwiftUI

/// The Rant Bar: the floating recorder.
///
/// An ambient system surface rather than a dialog. It sits over whatever you are
/// writing in, so every decision here is about earning that space — small enough to
/// ignore, legible enough to read out of the corner of your eye, and quiet unless you
/// reach for it.
///
/// Three things shape the design.
///
/// **Rant is keyboard-first.** The key you held starts and stops the recording, and
/// Escape cancels. So the bar shows no permanent buttons: a stop control sitting there
/// at all times implies the mouse is how this works, which is exactly backwards. The
/// controls exist, but they wait until the pointer arrives.
///
/// **It is one shape throughout.** Listening, working, done and failed are the same
/// capsule at different widths, not four different panels. Morphing keeps the eye in
/// one place; appearing and disappearing makes it hunt.
///
/// **The panel never resizes.** It is created once at the largest size the bar can
/// reach and the capsule changes shape inside it. Animating an `NSWindow` frame in step
/// with a SwiftUI spring judders, and it judders differently on every machine.
struct RantBar: View {
  @ObservedObject var controller: OverlayController
  /// Forces the hover treatment on for off-screen rendering.
  ///
  /// The visual QA gallery draws every state without a pointer, and the hover state is
  /// one of the states that has to be looked at. Nil in the running app, where hover
  /// means what it says.
  var forcedHover: Bool?
  /// Draw a flat approximation of the material instead of the real one.
  ///
  /// `ImageRenderer` cannot draw an `NSViewRepresentable` — it renders a "not
  /// supported" glyph — so the off-screen gallery substitutes a fill. The gallery is
  /// therefore a check on layout, spacing and colour, and the material itself has to
  /// be reviewed on screen. Nothing else differs.
  var staticSurface = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pointerInside = false

  private var hovering: Bool { (forcedHover ?? pointerInside) && layout.allowsControls }

  private var phase: RantBarPhase {
    RantBarProjection.phase(for: controller.state, handsFree: controller.handsFree)
  }

  private var layout: RantBarLayout {
    RantBarLayout.forPhase(phase, expanded: controller.showsLiveWords)
  }

  /// Twelve bars: enough to read as a waveform, few enough that each one is wide
  /// enough to see at this size.
  private var envelope: MeterEnvelope { MeterEnvelope(barCount: 12) }

  var body: some View {
    capsule
      .frame(width: layout.width, height: layout.height)
      .background(surface)
      .overlay(rim)
      .clipShape(shape)
      .compositingGroup()
      .shadow(color: .black.opacity(0.30), radius: 12, y: 4)
      .offset(y: controller.isDismissing ? 8 : 0)
      .opacity(controller.isDismissing ? 0 : 1)
      .onHover { pointerInside = $0 }
      .animation(morph, value: layout)
      .animation(morph, value: hovering)
      .animation(fade, value: controller.isDismissing)
      // One element. VoiceOver should say what is happening, not count twelve bars.
      .accessibilityElement(children: .contain)
      .accessibilityLabel(accessibilityLabel)
      // Fill whatever the panel is and stay centred in it. The panel is resized to
      // the phase, so this must not pin itself to a fixed width or the capsule would
      // sit off-centre the moment the panel changed.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var shape: some InsettableShape {
    RoundedRectangle(cornerRadius: RantBarLayout.cornerRadius, style: .continuous)
  }

  // MARK: - Surface

  /// A translucent material, with a solid scrim behind it.
  ///
  /// The material alone samples the wallpaper, so contrast depended on what the bar
  /// happened to float over — fine on a dark desktop, washed out on a light one. The
  /// scrim fixes the floor and the material supplies the depth, which is the part that
  /// makes it read as a system surface rather than as a rectangle the app drew.
  @ViewBuilder private var surface: some View {
    ZStack {
      if staticSurface {
        Rectangle().fill(Color(white: 0.16))
      } else {
      // The system's own HUD material, sampling what is behind the window. This is the
      // part that makes the bar read as a macOS surface rather than as a rectangle an
      // app drew, and `NSVisualEffectView` is the only way to get it — SwiftUI's
      // `.ultraThinMaterial` inside a borderless panel samples the panel, not the
      // desktop, so it comes out flat.
        VibrancyBackdrop()
      }
      // A dark floor under the content, so contrast never depends on the wallpaper.
      // The bar floats over arbitrary content; legibility cannot be left to chance.
      Rectangle().fill(Color.black.opacity(0.42))
    }
  }

  /// A hairline of light along the top edge only.
  ///
  /// A full stroked border is what made the old recorder look like a toolbar. Real
  /// macOS surfaces are lit from above, so the highlight belongs where the light would
  /// fall and nowhere else.
  private var rim: some View {
    shape
      .strokeBorder(
        LinearGradient(
          stops: [
            .init(color: .white.opacity(0.16), location: 0),
            .init(color: .white.opacity(0.03), location: 0.35),
            .init(color: .clear, location: 0.7),
          ],
          startPoint: .top, endPoint: .bottom),
        lineWidth: 0.8)
  }

  // MARK: - Contents

  @ViewBuilder private var capsule: some View {
    HStack(spacing: 8) {
      leading
      // The waveform takes the space rather than sitting in the middle of it. The old
      // recorder centred a small meter between two spacers, which is what made the
      // pill look mostly empty.
      centre.frame(maxWidth: .infinity)
      trailing
    }
    .padding(.horizontal, layout.showsCheck ? 0 : 11)
  }

  // MARK: Left

  @ViewBuilder private var leading: some View {
    if hovering {
      control(
        icon: "xmark", label: "Cancel dictation (Escape)", tint: .white.opacity(0.72)
      ) {
        NotificationCenter.default.post(name: .rantCancelDictation, object: nil)
      }
      .transition(.opacity.combined(with: .scale(scale: 0.8)))
    } else if layout.showsWaveform, phase.isListening {
      recordingDot
    } else if layout.showsErrorGlyph {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.live)
        .frame(width: 20)
    } else {
      Color.clear.frame(width: layout.showsCheck ? 0 : 4)
    }
  }

  /// The live indicator: a small coral dot with a slow halo.
  ///
  /// The halo breathes rather than the dot, so the thing your eye tracks stays a fixed
  /// size. A pulsing dot in peripheral vision is a distraction; a pulsing glow around a
  /// steady dot is a heartbeat.
  private var recordingDot: some View {
    ZStack {
      Circle()
        .fill(Theme.clay.opacity(0.28))
        .frame(width: 16, height: 16)
        .scaleEffect(breathing ? 1.0 : 0.62)
        .opacity(breathing ? 0.0 : 0.9)
        .animation(
          reduceMotion
            ? nil : .easeInOut(duration: 1.5).repeatForever(autoreverses: false),
          value: breathing)
      Circle().fill(Theme.clay).frame(width: 7, height: 7)
    }
    .frame(width: 20)
    .onAppear { breathing = true }
    .accessibilityHidden(true)
  }

  @State private var breathing = false

  // MARK: Middle

  @ViewBuilder private var centre: some View {
    if layout.showsWaveform {
      HStack(spacing: 8) {
        waveform
        if controller.showsLiveWords, !controller.partial.isEmpty {
          liveWords
        }
      }
    } else if layout.showsWorkingDots {
      WorkingDots(reduceMotion: reduceMotion)
    } else if layout.showsCheck {
      Image(systemName: "checkmark")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Theme.moss)
        .accessibilityHidden(true)
    } else if let message = layout.message {
      // Clicking opens Rant, where the full error and the transcript that survived it
      // can actually be read. The bar carries the short version; nothing is lost, it
      // is just not shown at 40 points high.
      Button {
        NotificationCenter.default.post(name: .rantOpenAfterFailure, object: nil)
      } label: {
        Text(message)
          .font(.system(size: 11.5))
          .foregroundStyle(.white.opacity(0.92))
          .lineLimit(1)
          .truncationMode(.tail)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(layout.detail ?? message)
    } else if case .cancelling = phase {
      Text("Cancelled")
        .font(.system(size: 11.5))
        .foregroundStyle(.white.opacity(0.55))
    }
  }

  private var waveform: some View {
    let bars = envelope.bars(from: controller.meter)
    return HStack(alignment: .center, spacing: 5) {
      ForEach(Array(bars.enumerated()), id: \.offset) { _, height in
        Capsule(style: .continuous)
          .fill(Theme.clay)
          .frame(width: 4, height: max(4, CGFloat(height) * 22))
      }
    }
    .frame(height: 22, alignment: .center)
    // Linear and short. A spring on a level meter overshoots, and an overshooting
    // meter is one that disagrees with the voice driving it.
    .animation(
      Theme.animation(.linear(duration: 0.07), reduceMotion: reduceMotion),
      value: controller.meter)
    .accessibilityHidden(true)
  }

  /// The newest few words, on one line, fading at the leading edge.
  ///
  /// Deliberately not a transcript view. The mask means the sentence appears to slide
  /// out of the bar rather than being truncated by it, which keeps the eye on the last
  /// few words — the only ones worth reading while still speaking.
  private var liveWords: some View {
    Text(controller.partial)
      .font(.system(size: 11))
      .foregroundStyle(.white.opacity(0.78))
      .lineLimit(1)
      .truncationMode(.head)
      .frame(maxWidth: 148, alignment: .trailing)
      .mask(
        LinearGradient(
          colors: [.clear, .black, .black],
          startPoint: .leading, endPoint: .init(x: 0.28, y: 0.5)))
      .transition(.opacity)
  }

  // MARK: Right

  @ViewBuilder private var trailing: some View {
    if hovering {
      control(icon: "stop.fill", label: "Finish and insert", tint: Theme.clay) {
        NotificationCenter.default.post(name: .rantFinishDictation, object: nil)
      }
      .transition(.opacity.combined(with: .scale(scale: 0.8)))
    } else if layout.showsHandsFreeLock {
      Image(systemName: "lock.fill")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.white.opacity(0.45))
        .frame(width: 20)
        .help("Hands-free — press your key again to finish")
        .accessibilityLabel("Hands-free recording")
    } else if case .error(_, let retryable) = phase, retryable {
      control(icon: "arrow.clockwise", label: "Try again", tint: Theme.clay) {
        NotificationCenter.default.post(name: .rantRetryDictation, object: nil)
      }
    } else {
      Color.clear.frame(width: layout.showsCheck ? 0 : 4)
    }
  }

  /// A small, quiet control. No filled circle: at this size a coloured disc is a
  /// button shouting, and these are meant to be found rather than noticed.
  private func control(
    icon: String, label: String, tint: Color, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 26, height: 26)
        .background(.white.opacity(0.12), in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
  }

  // MARK: - Motion

  /// One spring for every shape change, damped enough that nothing overshoots
  /// visibly. With Reduce Motion on, morphing is replaced by a short fade.
  private var morph: Animation? {
    reduceMotion
      ? .easeOut(duration: 0.12)
      : .spring(response: 0.34, dampingFraction: 0.86)
  }

  private var fade: Animation? {
    .easeOut(duration: reduceMotion ? 0.10 : 0.18)
  }

  private var accessibilityLabel: String {
    switch phase {
    case .idle: "Rant is ready"
    case .listening(let handsFree):
      handsFree
        ? "Rant is listening, hands-free. Press your dictation key to finish, or Escape to cancel."
        : "Rant is listening. Release your dictation key to insert, or press Escape to cancel."
    case .processing: "Working on your words"
    case .success: "Inserted"
    case .error(let message, _): "Dictation failed: \(message)"
    case .cancelling: "Dictation cancelled"
    }
  }
}

/// The system HUD material, behind the window.
///
/// `.hudWindow` is the material macOS uses for its own floating overlays — the volume
/// and brightness indicators — which is exactly the family the Rant Bar belongs to.
/// `blendingMode: .behindWindow` is what makes it sample the desktop rather than the
/// panel it sits in, and is the difference between a translucent surface and a grey
/// rectangle.
///
/// One effect view, no stacking. Blur is the most expensive thing on this surface and
/// the bar is on the critical path of every dictation.
private struct VibrancyBackdrop: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .hudWindow
    view.blendingMode = .behindWindow
    view.state = .active
    // The bar is a dark surface whatever the system theme is: it floats over other
    // people's windows, and a light pill over a dark editor is a flashbang.
    view.appearance = NSAppearance(named: .darkAqua)
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension Notification.Name {
  static let rantCancelDictation = Notification.Name("rant.cancelDictation")
  static let rantToggleDictation = Notification.Name("rant.toggleDictation")
  static let rantFinishDictation = Notification.Name("rant.finishDictation")
  static let rantRetryDictation = Notification.Name("rant.retryDictation")
  /// Clicking a failed bar opens the app, where the whole error and the transcript
  /// that survived it can be read.
  static let rantOpenAfterFailure = Notification.Name("rant.openAfterFailure")
}

/// The processing animation: four bars where the waveform was, pulsing in sequence.
///
/// Not a `ProgressView`. A stock spinner in a bar this size is a foreign object, and
/// it says "some framework is busy" rather than "your words are being worked on". These
/// are the waveform's own bars, collapsed — the shape the eye was already following,
/// carried through the transition instead of replaced by one.
private struct WorkingDots: View {
  let reduceMotion: Bool
  @State private var animating = false

  private let count = 4

  var body: some View {
    HStack(spacing: 5) {
      ForEach(0..<count, id: \.self) { index in
        Capsule(style: .continuous)
          .fill(Theme.clay)
          .frame(width: 4, height: animating ? 14 : 5)
          .opacity(animating ? 1 : 0.45)
          .animation(
            reduceMotion
              ? nil
              : .easeInOut(duration: 0.52)
                .repeatForever(autoreverses: true)
                // Staggered, so the row reads as a travelling pulse rather than four
                // things blinking together.
                .delay(Double(index) * 0.11),
            value: animating)
      }
    }
    .frame(height: 20)
    .onAppear { animating = true }
    .accessibilityHidden(true)
  }
}
