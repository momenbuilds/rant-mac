import Foundation

/// Microphone capture, behind a protocol so the pipeline can be tested with a WAV
/// fixture instead of a microphone — which matters because CI has no microphone and
/// because a test that depends on ambient noise is not a test.
public protocol AudioCaptureProvider: Sendable, AnyObject {
  /// Begins capture. Throws if the device is unavailable or permission is missing.
  func start() async throws
  /// Stops capture and returns everything recorded since `start`.
  func stop() async -> AudioBuffer
  /// Stops and discards. Used by cancel, where keeping the audio would be wrong.
  func cancel() async
  var isRecording: Bool { get async }
  /// Normalised 0…1 input level, for the waveform. Polled by the overlay.
  var level: Float { get async }

  /// Take everything captured so far and keep recording.
  ///
  /// For the live preview and the notetaker, both of which need audio while it is
  /// still being spoken rather than at the end. Returning and clearing in one step is
  /// what keeps that safe: two callers cannot receive the same samples, so nothing is
  /// transcribed twice.
  ///
  /// Defaulted to returning nothing, because a capture that cannot deliver audio
  /// incrementally is a perfectly good capture — the caller falls back to waiting for
  /// `stop()`.
  func drain() async -> AudioBuffer
}

extension AudioCaptureProvider {
  public func drain() async -> AudioBuffer { AudioBuffer(pcm: Data()) }
}

public enum AudioCaptureError: Error, Equatable, LocalizedError {
  case microphonePermissionDenied
  case noInputDevice
  case engineFailed(String)

  public var errorDescription: String? {
    switch self {
    case .microphonePermissionDenied:
      "Rant needs microphone access. Grant it in System Settings → Privacy & Security → Microphone."
    case .noInputDevice:
      "No microphone is available."
    case .engineFailed(let detail):
      "The audio engine failed: \(detail)"
    }
  }
}

/// Converts a normalised RMS level into the bar heights the overlay draws.
///
/// Pure, because "the waveform looks wrong" is otherwise a thing you debug by
/// staring at it. Speech RMS lives in a narrow band near the bottom of the range, so
/// a linear meter barely moves; the curve below spreads that band across the full
/// height without letting a loud noise peg every bar.
public struct MeterGeometry: Sendable {
  public var barCount: Int
  public var minimumHeight: Float
  /// Level below which we treat the input as silence.
  public var noiseFloor: Float

  public init(barCount: Int = 28, minimumHeight: Float = 0.08, noiseFloor: Float = 0.004) {
    self.barCount = barCount
    self.minimumHeight = minimumHeight
    self.noiseFloor = noiseFloor
  }

  /// Maps raw RMS to a 0…1 display height.
  public func height(forRMS rms: Float) -> Float {
    guard rms > noiseFloor else { return minimumHeight }
    // Decibels, mapped from a −50…0 dB window onto 0…1. Speech sits around −30 dB,
    // which lands in the middle of the bar rather than invisibly near the floor.
    let decibels = 20 * log10(max(rms, 1e-6))
    let normalised = (decibels + 50) / 50
    return min(1, max(minimumHeight, normalised))
  }

  /// Heights for the whole bar array given a history of recent levels, newest last.
  /// Older samples scroll leftwards; missing history reads as silence rather than as
  /// a jump.
  public func bars(from history: [Float]) -> [Float] {
    let window = history.suffix(barCount)
    let padding = Array(repeating: minimumHeight, count: max(0, barCount - window.count))
    return padding + window.map(height(forRMS:))
  }
}

/// Root-mean-square of a block of 16-bit samples.
public enum AudioMath {
  public static func rms(ofInt16 samples: Data) -> Float {
    guard samples.count >= 2 else { return 0 }
    return samples.withUnsafeBytes { raw -> Float in
      let buffer = raw.bindMemory(to: Int16.self)
      guard !buffer.isEmpty else { return 0 }
      var sum: Double = 0
      for sample in buffer {
        let value = Double(sample) / 32_768
        sum += value * value
      }
      return Float((sum / Double(buffer.count)).squareRoot())
    }
  }

  /// True when a recording is silent enough that transcribing it would waste a
  /// request and return an empty string. Checked before we spend a round trip.
  public static func isEffectivelySilent(_ buffer: AudioBuffer, threshold: Float = 0.005) -> Bool {
    buffer.isEmpty || rms(ofInt16: buffer.pcm) < threshold
  }
}

/// Replays a fixed buffer. The pipeline tests use this so they exercise the real
/// orchestration with deterministic audio.
public final class FixtureAudioCapture: AudioCaptureProvider, @unchecked Sendable {
  private let buffer: AudioBuffer
  private var recording = false
  private let lock = NSLock()
  public private(set) var startCount = 0
  public private(set) var cancelCount = 0
  public var startError: Error?

  public init(_ buffer: AudioBuffer) { self.buffer = buffer }

  /// A second of a 440 Hz tone — audible, non-silent, and deterministic.
  public static func tone(seconds: Double = 1, sampleRate: Int = 16_000) -> FixtureAudioCapture {
    var data = Data()
    let count = Int(Double(sampleRate) * seconds)
    data.reserveCapacity(count * 2)
    for index in 0..<count {
      let value = sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate))
      let sample = Int16(value * 12_000)
      withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
    }
    return FixtureAudioCapture(AudioBuffer(pcm: data, sampleRate: sampleRate))
  }

  public static func silence(seconds: Double = 1, sampleRate: Int = 16_000) -> FixtureAudioCapture {
    FixtureAudioCapture(
      AudioBuffer(pcm: Data(count: Int(Double(sampleRate) * seconds) * 2), sampleRate: sampleRate))
  }

  public func start() async throws {
    if let startError { throw startError }
    lock.withLock { recording = true; startCount += 1 }
  }

  public func stop() async -> AudioBuffer {
    lock.withLock { recording = false }
    return buffer
  }

  public func cancel() async {
    lock.withLock { recording = false; cancelCount += 1 }
  }

  public var isRecording: Bool { get async { lock.withLock { recording } } }
  public var level: Float { get async { 0.3 } }
}
