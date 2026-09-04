import Combine
import RantCore
import SwiftUI

/// Runs a meeting: capture in, transcript out, meeting saved.
///
/// The pieces all existed and none of them were connected. `MeetingSession` is the
/// decision layer, `SystemAudioMeetingCapture` is the real ScreenCaptureKit capture,
/// `MeetingSummariser` writes the summary and `MeetingStore` persists it — and
/// `AppModel.startMeeting()` only asked for a permission and set an error string, so
/// pressing "Start recording" produced no meeting, no transcript and no row. This is
/// the effectful half the session's own documentation says lives "in whatever owns a
/// `MeetingCaptureProvider`".
///
/// Transcription is chunked rather than streamed. The capture emits audio at the
/// callback rate — tens of milliseconds — which is far too small to transcribe, so
/// both channels accumulate until there is enough to be worth a request. That also
/// means the notetaker works with any `TranscriptionProvider`, including the on-device
/// one, rather than requiring a streaming provider and a network.
@MainActor
final class MeetingController: ObservableObject {
  @Published private(set) var session = MeetingSession()
  @Published private(set) var liveTranscript = ""
  @Published private(set) var capturesSystemAudio = false
  @Published private(set) var lastError: String?
  /// Set once a meeting has been written, so the view can select it.
  @Published private(set) var savedMeetingID: Int64?

  /// Enough audio to be worth a transcription request, and short enough that the live
  /// transcript still feels live.
  private static let flushSeconds = 6

  private let store: MeetingStore
  private let microphone: MicrophoneCapture
  private let makeProvider: () -> any TranscriptionProvider
  private let makeEnhancer: () -> any EnhancementProvider
  private let allowOffDeviceSummary: () -> Bool
  private let log = RantLog("Notetaker")

  private var capture: SystemAudioMeetingCapture?
  private var pump: Task<Void, Never>?
  private var micPump: Task<Void, Never>?
  private var pending: [MeetingChannel: PendingAudio] = [:]

  /// Audio waiting to be transcribed, with the offset the first sample arrived at, so
  /// a segment can be placed on the meeting's timeline.
  private struct PendingAudio {
    var offsetMilliseconds: Int
    var pcm: Data
  }

  init(
    store: MeetingStore,
    microphone: MicrophoneCapture,
    makeProvider: @escaping () -> any TranscriptionProvider,
    makeEnhancer: @escaping () -> any EnhancementProvider,
    allowOffDeviceSummary: @escaping () -> Bool
  ) {
    self.store = store
    self.microphone = microphone
    self.makeProvider = makeProvider
    self.makeEnhancer = makeEnhancer
    self.allowOffDeviceSummary = allowOffDeviceSummary
  }

  var isRunning: Bool { session.state.isCapturing || session.state == .paused }

  // MARK: - Controls

  func start(title: String?) {
    guard session.state == .idle || session.state.isFinished else { return }
    if session.state.isFinished { session.handle(.reset) }
    session.title = title?.isEmpty == false ? title : nil
    savedMeetingID = nil
    lastError = nil
    liveTranscript = ""
    pending = [:]

    let actions = session.handle(.start(at: Date()))
    perform(actions)
  }

  func pause() { perform(session.handle(.pause(at: Date()))) }

  func resume() { perform(session.handle(.resume(at: Date()))) }

  func stop() { perform(session.handle(.stop(at: Date()))) }

  /// Throw the meeting away. Deliberately separate from `stop`: a meeting that is
  /// discarded must never reach the database, and routing both through one path is
  /// how that goes wrong.
  func cancel() {
    let capture = self.capture
    pump?.cancel()
    micPump?.cancel()
    Task { await capture?.cancel() }
    self.capture = nil
    pending = [:]
    liveTranscript = ""
    session.handle(.reset)
  }

  // MARK: - Actions

  private func perform(_ actions: [MeetingSessionAction]) {
    for action in actions {
      switch action {
      case .beginCapture: beginCapture()
      case .pauseCapture: Task { [capture] in await capture?.pause() }
      case .resumeCapture: Task { [weak self] in await self?.resumeCapture() }
      case .endCapture: endCapture()
      case .persist: persistAndSummarise()
      // Persisting already summarises: the summary is written on the same row, and
      // running it twice would ask the enhancer for the same work again.
      case .summarise: break
      case .discard: cancel()
      }
    }
    refreshLiveTranscript()
  }

  private func beginCapture() {
    let capture = SystemAudioMeetingCapture(microphone: microphone)
    self.capture = capture
    pump = Task { [weak self] in
      do {
        let stream = try await capture.start()
        let hasSystemAudio = await capture.capturesSystemAudio
        await MainActor.run { self?.capturesSystemAudio = hasSystemAudio }
        for await chunk in stream {
          await self?.accept(chunk)
        }
      } catch {
        await MainActor.run { self?.fail(error) }
      }
    }
    // The capture streams system audio only; microphone audio accumulates inside the
    // capture device itself, so it has to be drained on a clock to appear live.
    micPump = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(Double(Self.flushSeconds)))
        guard let self else { return }
        await self.drainMicrophone()
      }
    }
  }

  private func resumeCapture() async {
    do {
      try await capture?.resume()
    } catch {
      await MainActor.run { self.fail(error) }
    }
  }

  private func endCapture() {
    pump?.cancel()
    micPump?.cancel()
    let capture = self.capture
    Task { [weak self] in
      _ = await capture?.stop()
      guard let self else { return }
      // Whatever was still buffered when the user pressed stop is part of the meeting.
      await self.flushAll()
      await MainActor.run { self.perform(self.session.handle(.finalised)) }
    }
  }

  private func fail(_ error: any Error) {
    lastError = error.localizedDescription
    log.error("meeting capture failed: \(error.localizedDescription)")
    perform(session.handle(.failed(error.localizedDescription)))
  }

  // MARK: - Audio in, transcript out

  private func accept(_ chunk: MeetingAudioChunk) async {
    guard session.state.isCapturing else { return }
    var bucket =
      pending[chunk.channel]
      ?? PendingAudio(offsetMilliseconds: chunk.offsetMilliseconds, pcm: Data())
    bucket.pcm.append(chunk.audio.pcm)
    pending[chunk.channel] = bucket
    if durationSeconds(bucket.pcm) >= Self.flushSeconds {
      await flush(chunk.channel)
    }
  }

  private func drainMicrophone() async {
    guard session.state.isCapturing else { return }
    let buffer = await microphone.drain()
    guard !buffer.isEmpty else { return }
    let offset = session.offsetMilliseconds(at: Date()) - buffer.durationMilliseconds
    var bucket =
      pending[.me] ?? PendingAudio(offsetMilliseconds: max(offset, 0), pcm: Data())
    bucket.pcm.append(buffer.pcm)
    pending[.me] = bucket
    if durationSeconds(bucket.pcm) >= Self.flushSeconds { await flush(.me) }
  }

  private func flushAll() async {
    for channel in pending.keys { await flush(channel) }
  }

  /// Transcribe one channel's buffered audio and hand the result to the session.
  private func flush(_ channel: MeetingChannel) async {
    guard let bucket = pending[channel], !bucket.pcm.isEmpty else { return }
    pending[channel] = nil

    let provider = makeProvider()
    do {
      let result = try await provider.transcribe(
        AudioBuffer(pcm: bucket.pcm, sampleRate: SystemAudioMeetingCapture.sampleRate),
        context: nil,
        options: .default)
      let text = result.best.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      let segment = MeetingSegment(
        startedMilliseconds: bucket.offsetMilliseconds,
        endedMilliseconds: bucket.offsetMilliseconds
          + durationSeconds(bucket.pcm) * 1000,
        channel: channel,
        text: text)
      session.handle(.heard(segment))
      refreshLiveTranscript()
    } catch is CancellationError {
      return
    } catch {
      // One failed window must not end the meeting. Say so once and keep recording —
      // losing six seconds is recoverable, losing the meeting is not.
      log.warning("a meeting window failed to transcribe: \(error.localizedDescription)")
      lastError = error.localizedDescription
    }
  }

  /// A meeting the user did not name still needs to be findable in a list.
  private static func defaultTitle(startedAt: Date) -> String {
    "Meeting · \(startedAt.formatted(date: .abbreviated, time: .shortened))"
  }

  private func durationSeconds(_ pcm: Data) -> Int {
    AudioBuffer(pcm: pcm, sampleRate: SystemAudioMeetingCapture.sampleRate)
      .durationMilliseconds / 1000
  }

  private func refreshLiveTranscript() {
    liveTranscript = session.liveTranscript()
  }

  // MARK: - Saving

  private func persistAndSummarise() {
    let segments = session.storableSegments()
    guard !segments.isEmpty else {
      // An empty meeting is not worth a row, and writing one would put a permanently
      // blank entry in the user's history for every accidental press.
      log.info("meeting produced no transcript; nothing saved")
      return
    }
    let started = session.startedAt ?? Date()
    let duration = session.durationMilliseconds
    let title = session.title
    let labels = session.labels
    let enhancer = makeEnhancer()
    let policy = MeetingSummariserPolicy(
      allowOffDeviceText: allowOffDeviceSummary())

    Task { [store, log] in
      let summary = await MeetingSummariser(enhancer: enhancer, policy: policy)
        .summarise(
          title: title, segments: segments, labels: labels,
          durationMilliseconds: duration)
      await MainActor.run {
        do {
          let meeting = Meeting(
            startedAt: started,
            endedAt: Date(),
            title: title ?? Self.defaultTitle(startedAt: started),
            appName: NSWorkspace.shared.frontmostApplication?.localizedName,
            summary: summary.overview,
            actionItems: summary.actionItems,
            decisions: summary.decisions,
            // The stored transcript is the search index's input, so it takes the
            // whole thing rather than the summariser's truncated prompt budget.
            transcript: MeetingStructure.transcript(
              segments, labels: labels, limit: .max))
          let saved = try store.save(meeting, segments: segments)
          self.savedMeetingID = saved.id
          log.info(
            "meeting saved segments=\(segments.count) words=\(self.session.wordCount)")
        } catch {
          self.lastError = "Could not save the meeting: \(error.localizedDescription)"
          log.error("could not save meeting: \(error.localizedDescription)")
        }
      }
    }
  }
}
