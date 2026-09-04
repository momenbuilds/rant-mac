#if canImport(AVFoundation)
@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// The real microphone, via `AVAudioEngine`, delivering 16 kHz mono 16-bit PCM —
/// the format every provider we support wants.
///
/// Two details here exist purely to protect the feel of the product.
///
/// **The pre-roll ring buffer.** `AVAudioEngine.start()` takes tens of milliseconds
/// to deliver its first callback, and people begin speaking as they press the key,
/// not after. Without a pre-roll the first syllable is simply missing — the single
/// most noticeable failure a dictation app can have. So the engine is kept running
/// between dictations when the user allows it, continuously filling a short circular
/// buffer, and pressing the key means "start keeping what you already heard".
///
/// **The tap converts once.** Conversion happens in the tap callback rather than in a
/// pass at the end, so stopping is instant instead of proportional to how long you
/// spoke.
public actor MicrophoneCapture: AudioCaptureProvider {
  public static let sampleRate = 16_000

  private let engine = AVAudioEngine()
  private var converter: AVAudioConverter?
  private var captured = Data()
  private var recording = false
  private var engineRunning = false
  private let log = RantLog("Audio")

  /// Rolling window kept while idle so a press captures the moment before it.
  private var preRoll = Data()
  private let preRollBytes: Int
  /// Recent RMS values for the waveform.
  private var levelHistory: [Float] = []
  private var currentLevel: Float = 0

  /// Device unique ID to record from, or nil for the system default.
  private var preferredDeviceID: String?

  public init(preRollMilliseconds: Int = 300) {
    // 16-bit mono: two bytes per sample.
    self.preRollBytes = Self.sampleRate / 1000 * preRollMilliseconds * 2
  }

  /// Choose which microphone to record from.
  ///
  /// Restarts the engine when the choice actually changes: the input device is a
  /// property of the running input unit, so setting it on a live engine is what makes
  /// the next dictation use the new microphone instead of the next launch. This used
  /// to store the value and never read it, which made the setting decoration.
  public func setPreferredDevice(_ uniqueID: String?) {
    guard uniqueID != preferredDeviceID else { return }
    preferredDeviceID = uniqueID
    guard engineRunning else { return }
    shutDown()
    try? prepare()
  }

  /// Point the engine's input unit at the chosen device before the format is read.
  ///
  /// Order matters: `inputFormat(forBus:)` reports the format of whatever device is
  /// currently selected, so the converter must be built *after* this, or Rant converts
  /// from the old microphone's format and gets noise.
  private func applyPreferredDevice() {
    guard let audioUnit = engine.inputNode.audioUnit else { return }
    guard
      var device = preferredDeviceID.flatMap(AudioDevices.deviceID(forUniqueID:))
        ?? AudioDevices.defaultInputDeviceID()
    else { return }
    let status = AudioUnitSetProperty(
      audioUnit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &device,
      UInt32(MemoryLayout<AudioDeviceID>.size))
    if status != noErr {
      // Not fatal: the system default still records. Say so rather than pretending
      // the chosen microphone is in use.
      log.warning("could not select the chosen microphone (status \(status)); using the default")
    }
  }

  // MARK: - Lifecycle

  /// Starts the engine without arming a recording, so the first press does not pay
  /// engine start-up latency. Safe to call repeatedly.
  public func prepare() throws {
    guard !engineRunning else { return }
    let input = engine.inputNode
    applyPreferredDevice()
    let inputFormat = input.inputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0 else { throw AudioCaptureError.noInputDevice }

    guard
      let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: Double(Self.sampleRate), channels: 1,
        interleaved: true),
      let converter = AVAudioConverter(from: inputFormat, to: target)
    else {
      throw AudioCaptureError.engineFailed("cannot convert \(inputFormat) to 16 kHz mono")
    }
    self.converter = converter

    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
      guard let self else { return }
      // The tap runs on a real-time thread; hop into the actor rather than touching
      // its state from here.
      let converted = Self.convert(buffer, using: converter, to: target)
      Task { await self.append(converted) }
    }

    engine.prepare()
    do {
      try engine.start()
      engineRunning = true
      log.info("audio engine started at \(Int(inputFormat.sampleRate))Hz")
    } catch {
      throw AudioCaptureError.engineFailed(error.localizedDescription)
    }
  }

  public func start() async throws {
    try prepare()
    // Seed the recording with what the microphone already heard, so a syllable
    // spoken as the key went down is not lost.
    captured = preRoll
    preRoll = Data()
    recording = true
  }

  public func stop() async -> AudioBuffer {
    recording = false
    let data = captured
    captured = Data()
    return AudioBuffer(pcm: data, sampleRate: Self.sampleRate)
  }

  public func cancel() async {
    recording = false
    captured = Data()
  }

  /// Take everything captured so far and keep recording.
  ///
  /// A dictation reads its audio once, at the end. A meeting cannot wait an hour to
  /// show a word, so the notetaker drains the buffer every few seconds and transcribes
  /// as it goes. Returning and clearing in one step is what keeps that safe: two
  /// callers cannot both receive the same samples, so nothing is transcribed twice.
  public func drain() -> AudioBuffer {
    let data = captured
    captured = Data()
    return AudioBuffer(pcm: data, sampleRate: Self.sampleRate)
  }

  /// Fully stops the engine. Called when the app goes idle for a long time, or when
  /// the user turns off the "keep the microphone warm" setting.
  public func shutDown() {
    guard engineRunning else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    engineRunning = false
    preRoll = Data()
  }

  public var isRecording: Bool { recording }
  public var level: Float { currentLevel }
  public var meterHistory: [Float] { levelHistory }

  // MARK: - Sample handling

  private func append(_ data: Data) {
    guard !data.isEmpty else { return }
    currentLevel = AudioMath.rms(ofInt16: data)
    levelHistory.append(currentLevel)
    if levelHistory.count > 240 { levelHistory.removeFirst(levelHistory.count - 240) }

    if recording {
      captured.append(data)
    } else {
      preRoll.append(data)
      if preRoll.count > preRollBytes {
        preRoll.removeFirst(preRoll.count - preRollBytes)
      }
    }
  }

  private nonisolated static func convert(
    _ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat
  ) -> Data {
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1_024)
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
      return Data()
    }

    // `convert` calls the block synchronously, but the block is typed as escaping,
    // so a captured `var` reads as a concurrency hazard. A reference box states the
    // single-owner intent instead of suppressing the diagnostic.
    final class Once: @unchecked Sendable { var used = false }
    let once = Once()
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if once.used {
        status.pointee = .noDataNow
        return nil
      }
      once.used = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, let channel = output.int16ChannelData else { return Data() }
    return Data(bytes: channel[0], count: Int(output.frameLength) * 2)
  }
}
#endif
