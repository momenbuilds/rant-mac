import Foundation

/// Which side of the conversation a piece of audio came from.
///
/// This is the only speaker distinction Rant can always make. Diarisation depends on
/// the transcription provider and is wrong often enough that a notetaker cannot be
/// built on it, whereas "this arrived on the microphone" versus "this arrived on the
/// system output" is a property of the capture graph and is never ambiguous. The
/// `channel` column in `meeting_segments` stores exactly this, and everything
/// user-facing — export, summary, search — labels from it.
public enum MeetingChannel: String, Codable, Sendable, CaseIterable {
  /// The microphone: you.
  case me
  /// System audio: everyone else on the call.
  case them
}

/// How the two channels are named in transcripts and exports.
///
/// Carried as data rather than hard-coded strings, so a meeting joined to a calendar
/// event can say "Priya" instead of "Them" without the export code having to learn
/// anything about calendars.
public struct MeetingSpeakerLabels: Equatable, Sendable {
  public var me: String
  public var them: String

  public init(me: String = "Me", them: String = "Them") {
    self.me = me
    self.them = them
  }

  public static let `default` = MeetingSpeakerLabels()

  public func label(for channel: MeetingChannel) -> String {
    switch channel {
    case .me: me
    case .them: them
    }
  }
}

/// A block of audio from one channel, stamped with where it sits in the meeting.
///
/// The offset is relative to the start of the recording rather than wall-clock,
/// because pausing must not leave a hole in the timeline that the user then has to
/// reason about when reading the exported subtitles.
public struct MeetingAudioChunk: Equatable, Sendable {
  public var channel: MeetingChannel
  public var offsetMilliseconds: Int
  public var audio: AudioBuffer

  public init(channel: MeetingChannel, offsetMilliseconds: Int, audio: AudioBuffer) {
    self.channel = channel
    self.offsetMilliseconds = offsetMilliseconds
    self.audio = audio
  }
}

/// Everything a finished capture produced, kept per channel.
///
/// Two buffers rather than one mix, because a mixed recording cannot be
/// re-transcribed with the "Me"/"Them" split intact, and that split is the part of a
/// meeting transcript people actually rely on.
public struct MeetingRecording: Equatable, Sendable {
  public var me: AudioBuffer
  public var them: AudioBuffer
  /// Length of the capture, excluding paused time.
  public var durationMilliseconds: Int

  public init(me: AudioBuffer, them: AudioBuffer, durationMilliseconds: Int) {
    self.me = me
    self.them = them
    self.durationMilliseconds = durationMilliseconds
  }

  public static let empty = MeetingRecording(
    me: AudioBuffer(pcm: Data()), them: AudioBuffer(pcm: Data()), durationMilliseconds: 0)

  public var isEmpty: Bool { me.isEmpty && them.isEmpty }
}

public enum MeetingCaptureError: Error, Equatable, LocalizedError {
  case screenRecordingPermissionDenied
  case noDisplayAvailable
  case systemAudioUnavailable(String)
  case alreadyCapturing
  case notCapturing

  public var errorDescription: String? {
    switch self {
    case .screenRecordingPermissionDenied:
      "Rant needs screen recording access to hear the other side of a call. "
        + "Grant it in System Settings → Privacy & Security → Screen Recording."
    case .noDisplayAvailable:
      "No display is available to capture system audio from."
    case .systemAudioUnavailable(let detail):
      "System audio capture failed: \(detail)"
    case .alreadyCapturing:
      "A meeting is already being recorded."
    case .notCapturing:
      "No meeting is being recorded."
    }
  }
}

/// Captures both sides of a call.
///
/// Behind a protocol for the same reason the microphone is: the real implementation
/// needs screen-recording permission and a display, and neither exists on CI. It is
/// also the seam that keeps the promise on the tin — Rant records the audio the
/// machine is already playing and the microphone it is already allowed to use. No
/// bot ever joins the call, nothing is invited, and the other participants see
/// exactly the attendee list they saw before Rant was installed.
public protocol MeetingCaptureProvider: AnyObject, Sendable {
  /// False when only the microphone is available — permission refused, or a build
  /// without ScreenCaptureKit. The session still works; it records one side, and the
  /// UI has to say so rather than silently producing half a meeting.
  var capturesSystemAudio: Bool { get async }

  /// Starts capture and returns the stream of audio blocks. The stream finishes when
  /// capture stops or is cancelled.
  func start() async throws -> AsyncStream<MeetingAudioChunk>
  /// Stops delivering audio without ending the meeting. Nothing that happens during
  /// a pause is kept — a pause the app quietly recorded through would be a betrayal.
  func pause() async
  func resume() async throws
  /// Ends capture and returns what was recorded.
  func stop() async -> MeetingRecording
  /// Ends capture and discards the audio.
  func cancel() async

  var isCapturing: Bool { get async }
  var isPaused: Bool { get async }
}

// MARK: - Pure conversion

/// Sample-rate and format conversion, kept pure so it can be tested without an audio
/// graph.
public enum MeetingAudioConversion {
  /// Converts float samples to 16-bit PCM at `targetRate`.
  ///
  /// System audio arrives at 48 kHz float and every transcription provider Rant
  /// supports wants 16 kHz 16-bit, so something has to decimate. This averages each
  /// source window instead of picking one sample in three: a box filter is a poor
  /// low-pass, but it is a great deal better than plain decimation, which folds
  /// everything above 8 kHz back into the speech band as a metallic buzz that
  /// transcription providers score badly on.
  public static func downsampleToInt16(
    _ samples: [Float], from sourceRate: Int, to targetRate: Int
  ) -> Data {
    guard sourceRate > 0, targetRate > 0, !samples.isEmpty else { return Data() }
    if sourceRate == targetRate { return int16Data(samples) }

    let outputCount = max(1, samples.count * targetRate / sourceRate)
    var data = Data()
    data.reserveCapacity(outputCount * 2)
    for index in 0..<outputCount {
      let start = index * samples.count / outputCount
      let end = min(samples.count, max(start + 1, (index + 1) * samples.count / outputCount))
      var sum: Float = 0
      for position in start..<end { sum += samples[position] }
      appendInt16(sum / Float(end - start), to: &data)
    }
    return data
  }

  /// Converts float samples in −1…1 to little-endian 16-bit PCM, clipping rather
  /// than wrapping. Wrapping turns a loud moment into white noise, which is a great
  /// deal worse than a clipped one.
  public static func int16Data(_ samples: [Float]) -> Data {
    var data = Data()
    data.reserveCapacity(samples.count * 2)
    for sample in samples { appendInt16(sample, to: &data) }
    return data
  }

  private static func appendInt16(_ sample: Float, to data: inout Data) {
    let clamped = min(1, max(-1, sample))
    let value = Int16(clamped * 32_767)
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }

  /// Milliseconds of 16-bit mono audio in `byteCount`.
  public static func milliseconds(ofInt16 byteCount: Int, sampleRate: Int) -> Int {
    guard sampleRate > 0 else { return 0 }
    return (byteCount / 2) * 1000 / sampleRate
  }
}

// MARK: - Fixture

/// Replays scripted chunks. Every notetaker test uses this, so the session, store,
/// summariser and export code runs end to end without a microphone, a display, or a
/// permission prompt.
public final class FixtureMeetingCapture: MeetingCaptureProvider, @unchecked Sendable {
  private let scripted: [MeetingAudioChunk]
  private let systemAudio: Bool
  private let lock = NSLock()
  private var capturing = false
  private var paused = false
  private var delivered: [MeetingAudioChunk] = []

  public private(set) var startCount = 0
  public private(set) var pauseCount = 0
  public private(set) var resumeCount = 0
  public private(set) var cancelCount = 0
  /// Set to make `start` fail, which is how the refused-permission path is tested.
  public var startError: Error?

  public init(chunks: [MeetingAudioChunk] = [], capturesSystemAudio: Bool = true) {
    self.scripted = chunks
    self.systemAudio = capturesSystemAudio
  }

  /// A two-sided exchange: half a second of each channel, in order.
  public static func conversation(sampleRate: Int = 16_000) -> FixtureMeetingCapture {
    let block = tonePCM(seconds: 0.5, sampleRate: sampleRate)
    let half = MeetingAudioConversion.milliseconds(ofInt16: block.count, sampleRate: sampleRate)
    return FixtureMeetingCapture(chunks: [
      MeetingAudioChunk(
        channel: .me, offsetMilliseconds: 0,
        audio: AudioBuffer(pcm: block, sampleRate: sampleRate)),
      MeetingAudioChunk(
        channel: .them, offsetMilliseconds: half,
        audio: AudioBuffer(pcm: block, sampleRate: sampleRate)),
    ])
  }

  static func tonePCM(seconds: Double, sampleRate: Int) -> Data {
    var samples: [Float] = []
    let count = Int(Double(sampleRate) * seconds)
    samples.reserveCapacity(count)
    for index in 0..<count {
      samples.append(Float(sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate))) * 0.4)
    }
    return MeetingAudioConversion.int16Data(samples)
  }

  public var capturesSystemAudio: Bool { get async { systemAudio } }
  public var isCapturing: Bool { get async { lock.withLock { capturing } } }
  public var isPaused: Bool { get async { lock.withLock { paused } } }

  /// Emits every scripted chunk and then finishes. Finishing straight away keeps the
  /// tests free of timing: a consumer drains the whole stream with `for await` and
  /// only then asks the session to stop.
  public func start() async throws -> AsyncStream<MeetingAudioChunk> {
    if let startError { throw startError }
    let chunks = scripted
    lock.withLock {
      capturing = true
      paused = false
      startCount += 1
      delivered = chunks
    }
    return AsyncStream { continuation in
      for chunk in chunks { continuation.yield(chunk) }
      continuation.finish()
    }
  }

  public func pause() async { lock.withLock { paused = true; pauseCount += 1 } }

  public func resume() async throws {
    try lock.withLock {
      guard capturing else { throw MeetingCaptureError.notCapturing }
      paused = false
      resumeCount += 1
    }
  }

  public func stop() async -> MeetingRecording {
    lock.withLock {
      capturing = false
      paused = false
      return Self.combine(delivered)
    }
  }

  public func cancel() async {
    lock.withLock {
      capturing = false
      paused = false
      cancelCount += 1
      delivered = []
    }
  }

  static func combine(_ chunks: [MeetingAudioChunk]) -> MeetingRecording {
    var me = Data()
    var them = Data()
    var rate = 16_000
    for chunk in chunks {
      rate = chunk.audio.sampleRate
      switch chunk.channel {
      case .me: me.append(chunk.audio.pcm)
      case .them: them.append(chunk.audio.pcm)
      }
    }
    let duration = max(
      MeetingAudioConversion.milliseconds(ofInt16: me.count, sampleRate: rate),
      MeetingAudioConversion.milliseconds(ofInt16: them.count, sampleRate: rate))
    return MeetingRecording(
      me: AudioBuffer(pcm: me, sampleRate: rate),
      them: AudioBuffer(pcm: them, sampleRate: rate),
      durationMilliseconds: duration)
  }
}

// MARK: - ScreenCaptureKit

#if canImport(ScreenCaptureKit)
  @preconcurrency import CoreMedia
  @preconcurrency import ScreenCaptureKit

  /// The real thing: the microphone through the existing `AudioCaptureProvider`, and
  /// everyone else through ScreenCaptureKit's audio tap.
  ///
  /// ScreenCaptureKit is the only supported way to hear system output on a modern Mac
  /// without installing a system-level audio driver, which Rant will not do — a
  /// driver sitting in the audio path of every app on the machine is far too much to
  /// ask of a dictation tool. The cost is that system audio needs Screen Recording
  /// permission, which sounds alarming for an app that records no video. So the
  /// capture asks for the smallest frame the API accepts, never reads one, and falls
  /// back to microphone-only when permission is refused rather than failing the
  /// meeting outright: half a transcript beats none, as long as the UI says which
  /// half is missing.
  public actor SystemAudioMeetingCapture: MeetingCaptureProvider {
    public static let sampleRate = 16_000

    private let microphone: AudioCaptureProvider
    private let log = RantLog("Notetaker")

    private var stream: SCStream?
    private var output: SystemAudioOutput?
    private var continuation: AsyncStream<MeetingAudioChunk>.Continuation?
    private var startedAt: Date?
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: Date?
    private var capturing = false
    private var paused = false
    private var systemAudioActive = false
    private var themPCM = Data()

    public init(microphone: AudioCaptureProvider) {
      self.microphone = microphone
    }

    public var capturesSystemAudio: Bool { systemAudioActive }
    public var isCapturing: Bool { capturing }
    public var isPaused: Bool { paused }

    public func start() async throws -> AsyncStream<MeetingAudioChunk> {
      guard !capturing else { throw MeetingCaptureError.alreadyCapturing }
      startedAt = Date()
      pausedTotal = 0
      pausedAt = nil
      themPCM = Data()
      capturing = true
      paused = false

      try await microphone.start()

      let (stream, continuation) = AsyncStream<MeetingAudioChunk>.makeStream()
      self.continuation = continuation

      // System audio is best-effort on purpose. A refused permission has to leave a
      // working microphone-only recording rather than an error sheet mid-call.
      do {
        try await attachSystemAudio()
        systemAudioActive = true
      } catch {
        systemAudioActive = false
        log.warning("system audio unavailable, recording the microphone only")
      }
      return stream
    }

    /// Builds and starts the ScreenCaptureKit stream. Separated from `start` so the
    /// permission failure has exactly one place to be handled.
    private func attachSystemAudio() async throws {
      let content: SCShareableContent
      do {
        content = try await SCShareableContent.excludingDesktopWindows(
          false, onScreenWindowsOnly: true)
      } catch {
        // The API reports a refused Screen Recording grant as a generic failure, so
        // this is the honest reading of it for the user.
        throw MeetingCaptureError.screenRecordingPermissionDenied
      }
      guard let display = content.displays.first else {
        throw MeetingCaptureError.noDisplayAvailable
      }

      let configuration = SCStreamConfiguration()
      configuration.capturesAudio = true
      configuration.excludesCurrentProcessAudio = true
      configuration.sampleRate = 48_000
      configuration.channelCount = 1
      // The smallest frame the API accepts. We never read one; asking for a
      // full-resolution frame would burn power on pixels nobody looks at.
      configuration.width = 2
      configuration.height = 2
      configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

      let filter = SCContentFilter(display: display, excludingWindows: [])
      let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
      let output = SystemAudioOutput { [weak self] samples, rate in
        guard let self else { return }
        Task { await self.appendSystemAudio(samples, sampleRate: rate) }
      }
      try stream.addStreamOutput(
        output, type: .audio,
        sampleHandlerQueue: DispatchQueue(label: "dev.rant.notetaker.audio"))
      try await stream.startCapture()
      self.stream = stream
      self.output = output
    }

    private func appendSystemAudio(_ samples: [Float], sampleRate: Int) {
      guard capturing, !paused else { return }
      let pcm = MeetingAudioConversion.downsampleToInt16(
        samples, from: sampleRate, to: Self.sampleRate)
      guard !pcm.isEmpty else { return }
      let offset = MeetingAudioConversion.milliseconds(
        ofInt16: themPCM.count, sampleRate: Self.sampleRate)
      themPCM.append(pcm)
      continuation?.yield(
        MeetingAudioChunk(
          channel: .them, offsetMilliseconds: offset,
          audio: AudioBuffer(pcm: pcm, sampleRate: Self.sampleRate)))
    }

    public func pause() async {
      guard capturing, !paused else { return }
      paused = true
      pausedAt = Date()
      await microphone.cancel()
    }

    public func resume() async throws {
      guard capturing, paused else { return }
      if let pausedAt { pausedTotal += Date().timeIntervalSince(pausedAt) }
      pausedAt = nil
      paused = false
      try await microphone.start()
    }

    public func stop() async -> MeetingRecording {
      let mine = await microphone.stop()
      let elapsed = startedAt.map { Date().timeIntervalSince($0) - pausedTotal } ?? 0
      let recording = MeetingRecording(
        me: mine,
        them: AudioBuffer(pcm: themPCM, sampleRate: Self.sampleRate),
        durationMilliseconds: max(0, Int(elapsed * 1000)))
      await teardown()
      return recording
    }

    public func cancel() async {
      await microphone.cancel()
      themPCM = Data()
      await teardown()
    }

    private func teardown() async {
      capturing = false
      paused = false
      systemAudioActive = false
      continuation?.finish()
      continuation = nil
      if let stream { try? await stream.stopCapture() }
      stream = nil
      output = nil
    }
  }

  /// Bridges ScreenCaptureKit's delegate callback into a closure.
  ///
  /// `SCStreamOutput` has to be an `NSObject`, which cannot be an actor, so the
  /// format conversion happens here on the sample-handler queue and only plain
  /// samples cross into the actor.
  final class SystemAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let handler: @Sendable ([Float], Int) -> Void

    init(handler: @escaping @Sendable ([Float], Int) -> Void) {
      self.handler = handler
    }

    func stream(
      _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
      of type: SCStreamOutputType
    ) {
      guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
      guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
      else { return }
      var samples: [Float] = []
      _ = try? sampleBuffer.withAudioBufferList { list, _ in
        // Non-interleaved float from ScreenCaptureKit: the first buffer is the only
        // channel we asked for.
        guard let first = list.first, let pointer = first.mData else { return }
        let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let typed = pointer.bindMemory(to: Float.self, capacity: count)
        samples = Array(UnsafeBufferPointer(start: typed, count: count))
      }
      guard !samples.isEmpty else { return }
      handler(samples, Int(asbd.mSampleRate))
    }
  }
#endif
