import XCTest

@testable import RantCore

/// The recorder's behaviour, without pixels.
///
/// The Rant Bar's rules — which shape, which contents, when it may grow, how the
/// waveform moves — live in `RantBarLayout`, `RantBarProjection` and `MeterEnvelope`
/// precisely so they can be tested here. A screenshot test would assert on the one
/// thing that is allowed to change freely.
final class RantBarTests: XCTestCase {

  // MARK: - State projection

  func testEveryPipelineStateHasAPhase() {
    XCTAssertEqual(RantBarProjection.phase(for: .idle, handsFree: false), .idle)
    XCTAssertEqual(
      RantBarProjection.phase(for: .listening, handsFree: false), .listening(handsFree: false))
    XCTAssertEqual(
      RantBarProjection.phase(for: .transcribing, handsFree: false), .processing(.transcribing))
    XCTAssertEqual(
      RantBarProjection.phase(for: .enhancing, handsFree: false), .processing(.enhancing))
    XCTAssertEqual(
      RantBarProjection.phase(for: .inserting, handsFree: false), .processing(.inserting))
    XCTAssertEqual(RantBarProjection.phase(for: .success("hi"), handsFree: false), .success)
    XCTAssertEqual(RantBarProjection.phase(for: .cancelled, handsFree: false), .cancelling)
    XCTAssertEqual(
      RantBarProjection.phase(for: .failure("no", retryable: true), handsFree: false),
      .error("no", retryable: true))
  }

  /// Hands-free is a property of the recording, not of the pipeline, so it has to be
  /// carried in rather than derived — and it must not leak into any other phase.
  func testHandsFreeShowsOnlyWhileListening() {
    XCTAssertEqual(
      RantBarProjection.phase(for: .listening, handsFree: true), .listening(handsFree: true))
    XCTAssertTrue(
      RantBarLayout.forPhase(.listening(handsFree: true)).showsHandsFreeLock)
    XCTAssertFalse(
      RantBarLayout.forPhase(.listening(handsFree: false)).showsHandsFreeLock)
    XCTAssertFalse(RantBarLayout.forPhase(.processing(.transcribing)).showsHandsFreeLock)
    XCTAssertFalse(RantBarLayout.forPhase(.success).showsHandsFreeLock)
  }

  // MARK: - Shape

  func testListeningIsTheOnlyPhaseThatOffersControls() {
    XCTAssertTrue(RantBarLayout.forPhase(.listening(handsFree: false)).allowsControls)
    for phase: RantBarPhase in [
      .idle, .processing(.transcribing), .success, .cancelling,
      .error("x", retryable: true),
    ] {
      XCTAssertFalse(
        RantBarLayout.forPhase(phase).allowsControls,
        "\(phase) should not offer cancel and stop")
    }
  }

  /// Stopping should *read* as something having happened before the checkmark arrives,
  /// and finishing should read as the bar getting out of the way.
  func testTheBarNarrowsAsTheDictationProgresses() {
    let listening = RantBarLayout.forPhase(.listening(handsFree: false)).width
    let processing = RantBarLayout.forPhase(.processing(.transcribing)).width
    let success = RantBarLayout.forPhase(.success).width
    XCTAssertLessThan(processing, listening)
    XCTAssertLessThan(success, processing)
  }

  func testTheListeningBarStaysWithinItsIntendedSize() {
    let layout = RantBarLayout.forPhase(.listening(handsFree: false))
    XCTAssertGreaterThanOrEqual(layout.width, 150)
    XCTAssertLessThanOrEqual(layout.width, 170)
    XCTAssertGreaterThanOrEqual(layout.height, 42)
    XCTAssertLessThanOrEqual(layout.height, 44)
  }

  func testExpandingForALongDictationGrowsOnlyTheWidth() {
    let normal = RantBarLayout.forPhase(.listening(handsFree: false))
    let expanded = RantBarLayout.forPhase(.listening(handsFree: false), expanded: true)
    XCTAssertGreaterThan(expanded.width, normal.width)
    XCTAssertEqual(expanded.height, normal.height, "growing vertically would shove the layout")
    XCTAssertLessThanOrEqual(expanded.width, RantBarLayout.maximumWidth)
  }

  func testEachPhaseShowsExactlyOneKindOfContent() {
    let cases: [(RantBarPhase, String)] = [
      (.listening(handsFree: false), "waveform"),
      (.processing(.transcribing), "dots"),
      (.success, "check"),
      (.error("x", retryable: false), "error"),
    ]
    for (phase, expected) in cases {
      let layout = RantBarLayout.forPhase(phase)
      let shown = [
        layout.showsWaveform ? "waveform" : nil,
        layout.showsWorkingDots ? "dots" : nil,
        layout.showsCheck ? "check" : nil,
        layout.showsErrorGlyph ? "error" : nil,
      ].compactMap { $0 }
      XCTAssertEqual(shown, [expected], "\(phase) drew \(shown)")
    }
  }

  // MARK: - Errors

  /// A failure must not turn the bar into a dialog. Short reasons survive; long ones
  /// become an instruction, and the whole text is kept for the tooltip.
  func testAShortReasonIsShownAndALongOneIsReplaced() {
    let short = RantBarLayout.forPhase(.error("Nothing was recorded.", retryable: false))
    XCTAssertEqual(short.message, "Nothing was recorded.")

    let long = RantBarLayout.forPhase(
      .error(
        "Could not reach the speech provider. The request timed out after 30 seconds.",
        retryable: true))
    XCTAssertEqual(long.message, "Try again")
    XCTAssertEqual(
      long.detail,
      "Could not reach the speech provider. The request timed out after 30 seconds.",
      "the full text has to survive for the tooltip and the window a click opens")
  }

  func testANonRetryableFailureDoesNotInviteARetry() {
    let layout = RantBarLayout.forPhase(
      .error("That API key was rejected by the provider, check it.", retryable: false))
    XCTAssertEqual(layout.message, "That didn't work")
  }

  func testAnErrorNeverCollapsesToACheckmark() {
    let layout = RantBarLayout.forPhase(.error("x", retryable: true))
    XCTAssertFalse(layout.showsCheck)
    XCTAssertTrue(layout.showsErrorGlyph)
  }

  // MARK: - Live words

  func testLiveWordsFollowTheSettingAndTheClock() {
    // Off means off, however long the recording runs.
    XCTAssertFalse(RantBarProjection.showsLiveWords(.never, elapsed: 60, hasWords: true))
    // Always means as soon as there is something to show.
    XCTAssertTrue(RantBarProjection.showsLiveWords(.always, elapsed: 0.2, hasWords: true))
    // The default waits, so a short phrase does not expand and collapse before anyone
    // has read it.
    XCTAssertFalse(
      RantBarProjection.showsLiveWords(.longDictations, elapsed: 2, hasWords: true))
    XCTAssertTrue(
      RantBarProjection.showsLiveWords(.longDictations, elapsed: 6, hasWords: true))
  }

  func testTheBarNeverExpandsWithNothingToShow() {
    for preference in LiveWordsPreference.allCases {
      XCTAssertFalse(
        RantBarProjection.showsLiveWords(preference, elapsed: 30, hasWords: false),
        "\(preference) expanded with no words")
    }
  }

  // MARK: - Timings

  func testTheTimingsAreWhatTheDesignAsksFor() {
    XCTAssertGreaterThanOrEqual(RantBarProjection.successDuration, 0.20)
    XCTAssertLessThanOrEqual(RantBarProjection.successDuration, 0.30)
    XCTAssertLessThanOrEqual(RantBarProjection.cancelDuration, 0.18)
    // A floor on the animation, not a delay on the product.
    XCTAssertLessThanOrEqual(RantBarProjection.minimumProcessingDuration, 0.16)
  }

  // MARK: - The waveform

  func testSilenceLeavesTheBarsAliveRatherThanFlat() {
    let envelope = MeterEnvelope()
    let bars = envelope.bars(from: Array(repeating: 0, count: 40))
    XCTAssertEqual(bars.count, 12)
    for height in bars {
      XCTAssertGreaterThan(height, 0, "a flat line reads as a broken microphone")
      XCTAssertLessThan(height, 0.2, "silence should not look like speech")
    }
  }

  func testNoHistoryAtAllStillProducesAFullSetOfBars() {
    XCTAssertEqual(MeterEnvelope().bars(from: []).count, 12)
  }

  /// The point of the envelope: speech has to use most of the bar's height, or the
  /// meter looks the same whether you whisper or shout.
  func testSpeechUsesMostOfTheAvailableHeight() {
    let envelope = MeterEnvelope()
    // A swell through the band real speech occupies, −42 dBFS up to about −14, spread
    // across exactly the window the bars can see. The envelope only ever looks at the
    // last `barCount * 2` samples, so a sweep spread wider than that would be tested
    // on its tail alone — which is a statement about the test, not about the meter.
    let visible = envelope.barCount * 2
    let speech: [Float] = (0..<visible).map { index in
      let decibels = -42 + Float(index) * (28 / Float(visible - 1))
      return pow(10, decibels / 20)
    }
    let bars = envelope.bars(from: speech)
    let quietest = bars.min() ?? 0
    let loudest = bars.max() ?? 0
    XCTAssertGreaterThan(
      loudest - quietest, 0.35,
      "the bars barely moved across the whole speech band: \(bars)")
    XCTAssertGreaterThan(loudest, 0.7, "a loud passage should nearly fill the bar")
  }

  /// Faster attack than release is the whole trick: a syllable's onset is immediate
  /// and its tail decays, which is what makes the meter feel attached to the voice.
  func testTheEnvelopeRisesFasterThanItFalls() {
    let envelope = MeterEnvelope()
    let loud = pow(Float(10), -16 / 20)
    let quiet = pow(Float(10), -44 / 20)

    // Silence, then a sudden loud sample: the last bar should already be well up.
    let onset = Array(repeating: quiet, count: 39) + [loud]
    let afterOnset = envelope.bars(from: onset).last ?? 0

    // Loud, then a sudden drop: the last bar should still be well above the floor.
    let release = Array(repeating: loud, count: 39) + [quiet]
    let afterRelease = envelope.bars(from: release).last ?? 0

    XCTAssertGreaterThan(afterOnset, 0.3, "the attack lagged behind the voice")
    XCTAssertGreaterThan(
      afterRelease, 0.5, "the release snapped back instead of decaying")
  }

  func testBarCountIsHonoured() {
    for count in [4, 10, 12, 14] {
      XCTAssertEqual(MeterEnvelope(barCount: count).bars(from: [0.01, 0.02]).count, count)
    }
  }
}
