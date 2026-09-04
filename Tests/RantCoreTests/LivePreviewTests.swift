import XCTest

@testable import RantCore

/// The live preview, and the thing it must not break.
///
/// Streaming works by draining the capture while the user is still speaking. That is
/// also the way to lose their dictation: every sample handed to the stream has been
/// taken out of what `stop()` will return, so unless those samples are put back the
/// final transcription sees only the last fraction of a second. These tests exist for
/// that failure more than for the feature.
final class LivePreviewTests: XCTestCase {

  /// A capture that can be drained, so the streaming path can be exercised at all.
  private actor DrainableCapture: AudioCaptureProvider {
    private var pending: [Data]
    private var stopped = Data()
    private(set) var drains = 0

    init(chunks: [Data], remainder: Data) {
      self.pending = chunks
      self.stopped = remainder
    }

    func start() async throws {}
    func cancel() async {}
    var isRecording: Bool { true }
    var level: Float { 0 }

    func drain() async -> AudioBuffer {
      drains += 1
      guard !pending.isEmpty else { return AudioBuffer(pcm: Data()) }
      return AudioBuffer(pcm: pending.removeFirst(), sampleRate: 16_000)
    }

    func stop() async -> AudioBuffer {
      AudioBuffer(pcm: stopped, sampleRate: 16_000)
    }
  }

  /// A streaming provider that records what it was sent and emits scripted partials.
  private final class ScriptedStreamer: StreamingTranscriptionProvider, @unchecked Sendable {
    let identifier = "scripted-stream"
    private let partials: [String]
    private let lock = NSLock()
    private(set) var sent = Data()
    private(set) var finishes = 0
    private var opened = false
    var isOpen: Bool { lock.withLock { opened } }

    init(partials: [String]) { self.partials = partials }

    func stream(
      context: TranscriptionContext?, options: TranscriptionOptions
    ) async throws -> TranscriptionStream {
      lock.withLock { opened = true }
      let (stream, continuation) = AsyncThrowingStream<TranscriptionPartial, Error>
        .makeStream()
      for text in partials {
        continuation.yield(TranscriptionPartial(text: text, isFinal: false))
      }
      continuation.finish()
      return TranscriptionStream(
        partials: stream,
        send: { [weak self] data in self?.lock.withLock { self?.sent.append(data) } },
        finish: { [weak self] in self?.lock.withLock { self?.finishes += 1 } })
    }
  }

  private func session(
    capture: DrainableCapture, streamer: ScriptedStreamer?,
    transcriber: ScriptedTranscriber
  ) -> DictationSession {
    DictationSession(
      audio: capture,
      transcriber: transcriber,
      injector: RecordingInjector(),
      context: StaticContextProvider(.empty),
      store: nil, enhancer: nil, vocabulary: VocabularyApplier(),
      streamer: streamer,
      now: { Date(timeIntervalSince1970: 1_700_000_000) })
  }

  /// The load-bearing one. Everything drained for the stream has to come back.
  func testAudioSentToTheStreamStillReachesTheFinalTranscription() async throws {
    let chunks = [Data(repeating: 1, count: 320), Data(repeating: 2, count: 320)]
    let remainder = Data(repeating: 3, count: 160)
    let capture = DrainableCapture(chunks: chunks, remainder: remainder)
    let transcriber = ScriptedTranscriber(raw: "hello")
    let streamer = ScriptedStreamer(partials: ["hel", "hello"])
    let session = session(capture: capture, streamer: streamer, transcriber: transcriber)

    await session.start()
    // Wait for the pump to have actually taken the chunks rather than sleeping for a
    // duration that happens to be long enough on one machine. A fixed sleep is a test
    // that passes locally and fails on a loaded CI runner.
    try await waitUntil { await capture.drains >= chunks.count }
    _ = await session.stopAndTranscribe()

    let seen = try XCTUnwrap(transcriber.receivedAudio.first)
    let expected = chunks.reduce(Data(), +) + remainder
    XCTAssertEqual(
      seen.pcm.count, expected.count,
      "audio handed to the live preview was dropped from the recording")
  }

  func testPartialsReachTheObserver() async throws {
    let capture = DrainableCapture(chunks: [], remainder: Data(repeating: 1, count: 320))
    let streamer = ScriptedStreamer(partials: ["so", "so we", "so we ship"])
    let session = session(
      capture: capture, streamer: streamer,
      transcriber: ScriptedTranscriber(raw: "so we ship"))

    let seen = Recorder()
    await session.observePartials { text in seen.add(text) }
    await session.start()
    try await waitUntil { seen.values.contains("so we ship") }
    _ = await session.stopAndTranscribe()

    XCTAssertTrue(
      seen.values.contains("so we ship"), "expected the last partial, saw \(seen.values)")
  }

  /// Cancelling must end the session politely — a provider billing by the second
  /// keeps billing until its own timeout otherwise.
  func testCancellingTerminatesTheStream() async throws {
    let capture = DrainableCapture(chunks: [], remainder: Data())
    let streamer = ScriptedStreamer(partials: [])
    let session = session(
      capture: capture, streamer: streamer, transcriber: ScriptedTranscriber(raw: ""))

    await session.start()
    // The stream has to be open before cancelling proves anything about closing it.
    try await waitUntil { streamer.isOpen }
    await session.cancel()
    XCTAssertEqual(streamer.finishes, 1)
  }

  /// No streamer is the normal case — the on-device engine does not stream — and it
  /// has to leave the ordinary path untouched.
  func testWithoutAStreamerTheRecordingIsWhateverStopReturns() async throws {
    let remainder = Data(repeating: 9, count: 640)
    let capture = DrainableCapture(chunks: [], remainder: remainder)
    let transcriber = ScriptedTranscriber(raw: "hello")
    let session = session(capture: capture, streamer: nil, transcriber: transcriber)

    await session.start()
    _ = await session.stopAndTranscribe()

    let seen = try XCTUnwrap(transcriber.receivedAudio.first)
    XCTAssertEqual(seen.pcm.count, remainder.count)
    let drains = await capture.drains
    XCTAssertEqual(drains, 0, "nothing should drain the capture when nothing streams")
  }

  /// Poll until a condition holds, or fail the test.
  ///
  /// Everything here depends on a background pump having run, and how long that takes
  /// is a property of the machine rather than of the code under test.
  private func waitUntil(
    timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("condition never became true within \(timeout)", file: file, line: line)
  }

  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ value: String) { lock.withLock { storage.append(value) } }
    var values: [String] { lock.withLock { storage } }
  }
}
