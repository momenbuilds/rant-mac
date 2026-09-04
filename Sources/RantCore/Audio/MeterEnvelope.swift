import Foundation

/// Turns a history of raw microphone levels into bar heights that look like a voice.
///
/// `MeterGeometry` answers "how tall is this one sample", which is a question about
/// decibels. This answers "how should the bars *move*", which is a question about
/// perception, and the two want different code.
///
/// Raw RMS per audio block is far too twitchy to draw directly: speech is not smooth
/// at that timescale, so a bar mapped straight from it flickers in a way that reads as
/// noise rather than as a voice. The fix is an envelope follower with asymmetric
/// coefficients — rise quickly, fall slowly. That asymmetry is the whole trick, and it
/// is why a level meter feels attached to the speaker: a syllable's onset should be
/// immediate, and its tail should decay rather than snap back.
///
/// Pure and deterministic, so "the waveform looks wrong" is a thing you can write a
/// test about instead of a thing you stare at.
public struct MeterEnvelope: Sendable {
  public var barCount: Int
  /// How much of the gap to the new level is closed when the signal is **rising**.
  /// High, because a delayed attack is felt as lag.
  public var attack: Float
  /// How much is closed when **falling**. Low, so a bar decays instead of snapping.
  public var release: Float
  /// Where the bars sit in silence. Not zero: a flat line reads as broken, and a
  /// microphone that is listening should look like it is listening.
  public var idleLevel: Float
  /// The quiet end of the band the bars span, in dBFS.
  ///
  /// Its own window rather than `MeterGeometry`'s −50…0. That range is right for a
  /// number but wrong for a twenty-point bar: conversational speech sits between about
  /// −40 and −15 dBFS, so mapping the whole range squeezes every syllable into the
  /// middle third and the meter looks flat no matter how loudly anybody talks. Spending
  /// the whole bar on the band speech actually occupies is what makes it move.
  public var quietDecibels: Float
  /// The loud end. Above this the bar is simply full; a shout should peg it rather
  /// than compress everything below it.
  public var loudDecibels: Float
  public var geometry: MeterGeometry

  public init(
    barCount: Int = 12,
    attack: Float = 0.55,
    release: Float = 0.16,
    idleLevel: Float = 0.10,
    quietDecibels: Float = -42,
    loudDecibels: Float = -14,
    geometry: MeterGeometry? = nil
  ) {
    self.barCount = barCount
    self.attack = attack
    self.release = release
    self.idleLevel = idleLevel
    self.quietDecibels = quietDecibels
    self.loudDecibels = loudDecibels
    self.geometry = geometry ?? MeterGeometry(barCount: barCount)
  }

  /// One sample's height, 0…1, across the speech band.
  public func height(forRMS rms: Float) -> Float {
    guard rms > 0 else { return idleLevel }
    let decibels = 20 * log10(max(rms, 1e-6))
    let span = max(1, loudDecibels - quietDecibels)
    let normalised = (decibels - quietDecibels) / span
    return min(1, max(idleLevel, normalised))
  }

  /// Bar heights, 0…1, oldest first — the same order the bars are drawn in.
  ///
  /// The envelope is run across the *window being displayed* rather than carried in
  /// mutable state between frames. That keeps this a pure function of the history it
  /// is given, which is what makes it testable, and costs nothing: the window is a
  /// dozen samples.
  public func bars(from history: [Float]) -> [Float] {
    guard barCount > 0 else { return [] }

    // A little more history than there are bars, so the follower has somewhere to
    // settle from and the leftmost bar is not simply the raw sample.
    let lead = barCount
    let window = Array(history.suffix(barCount + lead))
    guard !window.isEmpty else {
      return Array(repeating: idleLevel, count: barCount)
    }

    var followed: [Float] = []
    followed.reserveCapacity(window.count)
    var level = height(forRMS: window[0])
    for sample in window {
      let target = height(forRMS: sample)
      let coefficient = target > level ? attack : release
      level += (target - level) * coefficient
      followed.append(max(idleLevel, min(1, level)))
    }

    let visible = followed.suffix(barCount)
    if visible.count == barCount { return Array(visible) }
    // Not enough history yet: pad at the *front*, so what there is stays newest-last
    // and the bars fill in from the right as the recording starts.
    return Array(repeating: idleLevel, count: barCount - visible.count) + Array(visible)
  }
}
