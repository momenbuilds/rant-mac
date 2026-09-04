import Foundation

/// What a whisper.cpp run gives back.
public struct WhisperTranscript: Equatable, Sendable {
  /// Verbatim text, exactly as the model decoded it.
  public var text: String
  /// The language whisper detected, when it was asked to detect one.
  public var language: String?

  public init(text: String, language: String? = nil) {
    self.text = text
    self.language = language
  }
}

/// The seam between Rant and whisper.cpp.
///
/// The C library and the GGUF weights are the two things that cannot live in a unit
/// test: one is a binary dependency, the other is hundreds of megabytes we are not
/// going to download in CI. Everything that can be wrong *in Swift* — the model being
/// absent, the sample rate being wrong, silence coming back as `[BLANK_AUDIO]`,
/// cancellation — sits on this side of the seam, where a fake backend exercises it.
///
/// Samples arrive as 32-bit float mono at 16 kHz because that is what `whisper_full`
/// takes; converting *before* the boundary keeps the C shim to little more than a
/// pointer and a length.
public protocol WhisperBackend: Sendable {
  /// Loads the weights, or does nothing if the same file is already loaded. Called on
  /// warm-up as well as on the hot path, so it must be cheap to repeat.
  func prepare(modelAt url: URL) async throws

  func transcribe(samples: [Float], languageCode: String?) async throws -> WhisperTranscript
}

/// Speech-to-text that never leaves the machine: whisper.cpp on the CPU.
///
/// This is the provider that has to work on every Mac Rant runs on, which is why it
/// is CPU whisper.cpp rather than `SpeechAnalyzer` or a Parakeet CoreML model — both
/// of those want a Neural Engine, and the machine this was built on is Intel. See
/// `docs/DECISIONS.md` D-007. A faster Apple-Silicon path can be added beside this
/// one; it can never replace it.
///
/// The provider holds no transport of any kind. That is deliberate: "local mode makes
/// no network request" is a claim best kept by having nothing here that *could* make
/// one, rather than by a flag somebody has to remember to check. When the model is
/// missing it throws `modelUnavailable` — it never reaches for the cloud, because a
/// user who chose local would rather see an error than discover their audio was
/// uploaded.
public struct LocalWhisperProvider: TranscriptionProvider {
  public let identifier = "local-whisper"
  public var displayName: String { "Local — \(model.displayName)" }
  public let sendsAudioOffDevice = false
  /// No limit. Nothing is being uploaded and nobody is billing per second; a long
  /// recording just takes longer to decode.
  public let maximumUtteranceSeconds: Int? = nil

  /// whisper.cpp is trained on 16 kHz mono audio and resamples internally if you let
  /// it; we do it ourselves so the conversion is visible and tested.
  public static let requiredSampleRate = 16_000

  public let model: WhisperModel
  private let backend: any WhisperBackend
  /// Where the weights are, or nil when they have not been downloaded. A closure
  /// rather than a stored path so that deleting the model in Settings takes effect on
  /// the very next dictation, the same way a changed API key does.
  private let modelLocator: @Sendable () -> URL?
  private let log = RantLog("LocalSTT")

  public init(
    model: WhisperModel,
    backend: any WhisperBackend,
    modelLocator: @escaping @Sendable () -> URL?
  ) {
    self.model = model
    self.backend = backend
    self.modelLocator = modelLocator
  }

  /// Convenience for the app: weights live in the model directory under the model's
  /// own file name, and existence on disk is what "installed" means.
  public init(model: WhisperModel, backend: any WhisperBackend, directory: URL) {
    let fileName = model.fileName
    self.init(model: model, backend: backend) {
      let url = directory.appendingPathComponent(fileName)
      return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
  }

  // MARK: - Transcribe

  public func transcribe(
    _ audio: AudioBuffer,
    context: TranscriptionContext?,
    options: TranscriptionOptions
  ) async throws -> TranscriptionResult {
    guard !audio.isEmpty else { throw TranscriptionError.audioEmpty }
    guard let modelURL = modelLocator() else {
      // Not a degraded mode, not a reason to fall back: a hard stop.
      throw TranscriptionError.modelUnavailable(model.displayName)
    }

    let samples = Self.sixteenKilohertzMonoSamples(from: audio)
    guard !samples.isEmpty else { throw TranscriptionError.audioEmpty }

    let started = ContinuousClock.now
    do {
      try await backend.prepare(modelAt: modelURL)
      let decoded = try await backend.transcribe(
        samples: samples, languageCode: options.languageCode)
      let latency = Int((ContinuousClock.now - started) / .milliseconds(1))
      let text = Self.strippingNonSpeechAnnotations(decoded.text)
      log.info("local transcription audioMs=\(audio.durationMilliseconds) latencyMs=\(latency)")

      return TranscriptionResult(
        raw: text,
        // whisper does not rewrite. Leaving this nil is what tells the caller to run
        // its own `TranscriptCleaner`, which is the whole point of local mode.
        cleaned: nil,
        provider: identifier,
        language: decoded.language ?? options.languageCode,
        latencyMilliseconds: latency)
    } catch is CancellationError {
      throw TranscriptionError.cancelled
    }
  }

  /// Loads the weights while the user is still speaking. A cold load of a medium
  /// model is seconds of mmap and page-in; paying it here rather than after the key
  /// is released is the difference between "instant" and "did it hang?".
  public func warmUp() async {
    guard let url = modelLocator() else { return }
    do {
      try await backend.prepare(modelAt: url)
    } catch {
      // Nothing to tell the user yet — the real attempt will report properly.
      log.debug("warm-up load failed; the next dictation will retry")
    }
  }

  /// The local equivalent of "test connection": is the model actually there, and does
  /// it load? Reaches no network, which is the point.
  public func checkReachability() async throws {
    guard let url = modelLocator() else {
      throw TranscriptionError.modelUnavailable(model.displayName)
    }
    try await backend.prepare(modelAt: url)
  }

  // MARK: - Audio format

  /// Converts an `AudioBuffer` to the float mono 16 kHz whisper.cpp expects.
  ///
  /// Capture is already 16 kHz mono in the normal case, so this is usually a straight
  /// widening. It copes with other rates anyway because the alternative — handing
  /// 48 kHz samples to a model that assumes 16 kHz — is not an error, it is a
  /// transcript of chipmunks, and that is far harder to diagnose than a throw.
  static func sixteenKilohertzMonoSamples(from audio: AudioBuffer) -> [Float] {
    let samples = floatSamples(from: audio.pcm)
    guard audio.sampleRate > 0, audio.sampleRate != requiredSampleRate else { return samples }
    return resample(samples, from: audio.sampleRate, to: requiredSampleRate)
  }

  /// Little-endian signed 16-bit to normalised float. A trailing odd byte is dropped
  /// rather than read past — a truncated final frame is worth zero samples, not a
  /// crash.
  static func floatSamples(from pcm: Data) -> [Float] {
    let count = pcm.count / 2
    guard count > 0 else { return [] }
    var out = [Float](repeating: 0, count: count)
    pcm.withUnsafeBytes { raw in
      for index in 0..<count {
        let low = UInt16(raw[index * 2])
        let high = UInt16(raw[index * 2 + 1])
        let value = Int16(bitPattern: low | (high << 8))
        out[index] = Float(value) / 32_768
      }
    }
    return out
  }

  /// Linear interpolation. Not the finest resampler ever written, but speech arriving
  /// at 44.1 or 48 kHz is a band-limited signal being decimated, and whisper is
  /// markedly more tolerant of interpolation artefacts than of the wrong rate.
  static func resample(_ samples: [Float], from source: Int, to target: Int) -> [Float] {
    guard source > 0, target > 0, source != target, samples.count > 1 else { return samples }
    let ratio = Double(source) / Double(target)
    let outputCount = Int(Double(samples.count) / ratio)
    guard outputCount > 0 else { return [] }

    var out = [Float](repeating: 0, count: outputCount)
    for index in 0..<outputCount {
      let position = Double(index) * ratio
      let left = Int(position)
      let right = min(left + 1, samples.count - 1)
      let fraction = Float(position - Double(left))
      out[index] = samples[left] + (samples[right] - samples[left]) * fraction
    }
    return out
  }

  // MARK: - Output tidying

  /// Removes whisper's non-speech annotations — `[BLANK_AUDIO]`, `(MUSIC)`,
  /// `[ Silence ]` — which are commentary about the audio rather than words anybody
  /// said, and which look like a bug when they land in the user's text field.
  ///
  /// A hand-written scanner rather than a regular expression, on purpose: a pattern
  /// with nested quantifiers over input of unbounded length has already cost this
  /// project a hang, and bracket matching is the classic way to write one by accident.
  static func strippingNonSpeechAnnotations(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    var buffer = ""
    var closing: Character?

    for character in text {
      if let expected = closing {
        if character == expected {
          // Keep it when it reads like speech: real words in brackets do happen.
          if !isNonSpeechAnnotation(buffer) {
            out.append(expected == "]" ? "[" : "(")
            out.append(buffer)
            out.append(expected)
          }
          buffer = ""
          closing = nil
        } else {
          buffer.append(character)
        }
        continue
      }
      switch character {
      case "[": closing = "]"
      case "(": closing = ")"
      default: out.append(character)
      }
    }
    // An unterminated bracket means the decode was cut off mid-annotation. Keep the
    // tail rather than silently swallowing words.
    if closing != nil { out.append(buffer) }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Annotations are shouted — `BLANK_AUDIO`, `MUSIC` — or they are one of a small
  /// known set of lowercase ones. Anything else in brackets is treated as speech,
  /// because deleting words the user said is worse than leaving an odd `(sic)` in.
  private static func isNonSpeechAnnotation(_ body: String) -> Bool {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    if trimmed.contains(where: \.isLowercase) {
      let words = trimmed.split(whereSeparator: \.isWhitespace)
      return words.count == 1 && knownAnnotations.contains(trimmed.lowercased())
    }
    return true
  }

  private static let knownAnnotations: Set<String> = [
    "silence", "music", "inaudible", "laughter", "applause", "noise",
  ]
}
