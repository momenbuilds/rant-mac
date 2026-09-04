import XCTest
@testable import RantCore

/// The trigger key is the most bug-prone surface in the product: it has to tell a
/// hold from a tap from a double-tap, and it has to do all that without ever eating
/// a keystroke that belonged to a real shortcut. These tests drive the gate the way
/// a keyboard would.
final class HotkeyStateMachineTests: XCTestCase {

  private func gate(_ mode: ActivationMode = .hybrid) -> DictationGate {
    DictationGate(mode: mode, timings: GateTimings(tapThreshold: 0.3, doubleTapWindow: 0.4))
  }

  // MARK: - Push to talk

  func testHoldStartsImmediatelyAndStopsOnRelease() {
    var g = gate(.holdOnly)
    XCTAssertEqual(g.handle(.triggerDown(otherModifiersHeld: false), at: 0), [.startRecording(.pushToTalk)])
    XCTAssertTrue(g.isRecording)
    XCTAssertEqual(g.handle(.triggerUp, at: 1.0), [.stopAndTranscribe])
    XCTAssertFalse(g.isRecording)
  }

  /// Recording begins on key *down*, not after the tap threshold has elapsed.
  /// Waiting would clip the first syllable, which is the most noticeable failure a
  /// dictation app can have.
  func testRecordingStartsBeforeTheTapThresholdElapses() {
    var g = gate(.hybrid)
    _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 0)
    XCTAssertTrue(g.isRecording, "audio must already be running well before 0.3s")
  }

  func testQuickTapInHoldOnlyModeCancelsRatherThanTranscribingSilence() {
    var g = gate(.holdOnly)
    _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 0)
    XCTAssertEqual(g.handle(.triggerUp, at: 0.05), [.cancel])
    XCTAssertEqual(g.state, .idle)
  }

  // MARK: - Toggle

  func testHybridTapBecomesAToggleAndTheNextTapStops() {
    var g = gate(.hybrid)
    _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 0)
    XCTAssertEqual(g.handle(.triggerUp, at: 0.1), [], "the recording that already started just keeps going")
    XCTAssertTrue(g.isRecording)

    // Second tap, comfortably outside the double-tap window, stops.
    _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 5.0)
    XCTAssertEqual(g.handle(.triggerUp, at: 5.08), [.stopAndTranscribe])
    XCTAssertFalse(g.isRecording)
  }

  func testToggleOnlyModeStartsOnReleaseNotOnPress() {
    var g = gate(.toggleOnly)
    XCTAssertEqual(g.handle(.triggerDown(otherModifiersHeld: false), at: 0), [])
    XCTAssertEqual(g.handle(.triggerUp, at: 0.1), [.startRecording(.toggled)])
    XCTAssertTrue(g.isRecording)
  }

  func testHoldingWhileToggleRecordingAlsoStops() {
    var g = gate(.hybrid)
    _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 0)
    _ = g.handle(.triggerUp, at: 0.1)              // now toggled-recording
    _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 5.0)
    XCTAssertEqual(g.handle(.triggerUp, at: 6.0), [.stopAndTranscribe], "a long press stops too")
  }

  // MARK: - Hands free

  func testDoubleTapPromotesToHandsFreeWithoutRestartingAudio() {
    var g = gate(.hybrid)
    _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 0)
    _ = g.handle(.triggerUp, at: 0.05)             // tap 1 -> toggled
    _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 0.15)
    let actions = g.handle(.triggerUp, at: 0.2)    // tap 2, inside the window
    XCTAssertEqual(actions, [.promoteToHandsFree],
                   "the audio from tap 1 must be kept, not restarted")
    XCTAssertEqual(g.state, .recording(.handsFree))
  }

  func testTapsOutsideTheDoubleTapWindowAreNotADoubleTap() {
    var g = gate(.hybrid)
    _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 0)
    _ = g.handle(.triggerUp, at: 0.05)
    _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 2.0)
    XCTAssertEqual(g.handle(.triggerUp, at: 2.05), [.stopAndTranscribe],
                   "a late second tap is a stop, not a hands-free promotion")
  }

  func testHandsFreeIgnoresNothingAndStopsOnExternalStop() {
    var g = gate(.hybrid)
    _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 0)
    _ = g.handle(.triggerUp, at: 0.05)
    _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 0.15)
    _ = g.handle(.triggerUp, at: 0.2)
    XCTAssertEqual(g.handle(.externalStop, at: 30), [.stopAndTranscribe])
  }

  // MARK: - Not stealing shortcuts

  /// The whole reason a lone modifier is usable as a trigger: ⌘C must still copy.
  func testTriggerPressedAsPartOfAShortcutNeverStartsDictation() {
    var g = gate(.hybrid)
    _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 0)
    // The user then presses "c" — this is ⌘C, not a dictation.
    XCTAssertEqual(g.handle(.otherKeyDown, at: 0.04), [.cancel, .passThrough])
    XCTAssertFalse(g.isRecording)
    // And the eventual release must not transcribe anything.
    XCTAssertEqual(g.handle(.triggerUp, at: 0.3), [.passThrough])
    XCTAssertEqual(g.state, .idle)
  }

  func testTriggerPressedWhileAnotherModifierIsAlreadyHeldIsAlwaysAShortcut() {
    var g = gate(.hybrid)
    XCTAssertEqual(g.handle(.triggerDown(otherModifiersHeld: true), at: 0), [.passThrough])
    XCTAssertFalse(g.isRecording)
    XCTAssertEqual(g.handle(.triggerUp, at: 0.5), [.passThrough])
  }

  /// A shortcut must not leave a stale tap timestamp that turns the user's *next*
  /// unrelated tap into a spurious double-tap.
  func testAContaminatedPressDoesNotSeedTheDoubleTapDetector() {
    var g = gate(.hybrid)
    _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 0)
    _ = g.handle(.otherKeyDown, at: 0.02)
    _ = g.handle(.triggerUp, at: 0.05)
    // A genuine tap right afterwards should start a toggle, not hands-free.
    _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 0.1)
    XCTAssertEqual(g.handle(.triggerUp, at: 0.15), [])
    XCTAssertEqual(g.state, .recording(.toggled))
  }

  // MARK: - Cancel

  func testEscapeCancelsFromEveryRecordingState() {
    for build in [
      { () -> DictationGate in                       // push-to-talk in progress
        var g = self.gate(.hybrid)
        _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 0)
        return g
      },
      { () -> DictationGate in                       // toggled
        var g = self.gate(.hybrid)
        _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 0)
        _ = g.handle(.triggerUp, at: 0.05)
        return g
      },
      { () -> DictationGate in                       // hands free
        var g = self.gate(.hybrid)
        _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 0)
        _ = g.handle(.triggerUp, at: 0.05)
        _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 0.15)
        _ = g.handle(.triggerUp, at: 0.2)
        return g
      },
    ] {
      var g = build()
      XCTAssertEqual(g.handle(.escape, at: 10), [.cancel])
      XCTAssertEqual(g.state, .idle)
    }
  }

  /// Escape between "stop speaking" and "transcript arrives" must still cancel —
  /// this is the window where a user realises they said the wrong thing.
  func testEscapeCancelsWhileTheTranscriptIsInFlight() {
    var g = gate(.holdOnly)
    _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 0)
    _ = g.handle(.triggerUp, at: 1.0)
    XCTAssertEqual(g.state, .finishing)
    XCTAssertEqual(g.handle(.escape, at: 1.1), [.cancel])
    XCTAssertEqual(g.state, .idle)
  }

  func testEscapeWhenIdlePassesThroughToTheApp() {
    var g = gate()
    XCTAssertEqual(g.handle(.escape, at: 0), [.passThrough])
  }

  // MARK: - Robustness

  func testKeyRepeatDoesNotRestartRecording() {
    var g = gate(.hybrid)
    XCTAssertEqual(g.handle(.triggerDown(otherModifiersHeld: false), at: 0), [.startRecording(.pushToTalk)])
    for i in 1...20 {
      XCTAssertEqual(g.handle(.triggerDown(otherModifiersHeld: false), at: Double(i) * 0.03), [],
                     "auto-repeat must be inert")
    }
    XCTAssertEqual(g.handle(.triggerUp, at: 1.0), [.stopAndTranscribe])
  }

  func testStrayReleaseWhileIdleIsHarmless() {
    var g = gate()
    XCTAssertEqual(g.handle(.triggerUp, at: 0), [])
    XCTAssertEqual(g.state, .idle)
  }

  func testSessionEndedReturnsToIdle() {
    var g = gate(.holdOnly)
    _ = g.handle(.triggerDown(otherModifiersHeld: false), at: 0)
    _ = g.handle(.triggerUp, at: 1)
    _ = g.handle(.sessionEnded, at: 2)
    XCTAssertEqual(g.state, .idle)
  }

  /// A long random walk should never leave the gate believing it is recording while
  /// its state says otherwise, and should never emit two starts without a stop.
  func testFuzzedEventSequencesKeepStartAndStopBalanced() {
    var rng = SystemRandomNumberGenerator()
    for mode in ActivationMode.allCases {
      var g = gate(mode)
      var recording = false
      var t = 0.0
      for _ in 0..<4000 {
        t += Double.random(in: 0.01...0.6, using: &rng)
        let event: GateEvent = [
          .triggerDown(otherModifiersHeld: Bool.random(using: &rng)),
          .triggerUp, .otherKeyDown, .escape, .externalStop, .sessionEnded,
        ].randomElement(using: &rng)!
        // `sessionEnded` is the transcript pipeline reporting that it finished on
        // its own, so it ends the recording without the gate emitting an action.
        if event == .sessionEnded { recording = false }
        for action in g.handle(event, at: t) {
          switch action {
          case .startRecording:
            XCTAssertFalse(recording, "two starts without an intervening stop in \(mode)")
            recording = true
          case .promoteToHandsFree:
            XCTAssertTrue(recording, "promoted to hands-free while nothing was recording in \(mode)")
          case .stopAndTranscribe, .cancel:
            recording = false
          case .passThrough:
            break
          }
        }
      }
    }
  }
}
