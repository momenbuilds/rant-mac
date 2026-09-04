# Performance

Dictation is muscle memory or it is nothing. If the overlay appears late, or the first
syllable is missing, or the paste lands after you have already started typing again,
people stop using it — and they will not be able to tell you why.

## Targets

| Stage | Target | How it is protected |
|---|---|---|
| hotkey → overlay visible | < 100 ms | the overlay is a pre-built `NSPanel`; showing it is `orderFrontRegardless`, not a construction |
| hotkey → first audio sample kept | < 150 ms | the engine is kept warm and a 300 ms pre-roll ring buffer means the press captures the moment *before* it |
| capture end → transcript final | provider-bound | the TLS connection is opened when recording *starts*, so DNS+TCP+TLS is already paid |
| transcript final → text inserted | < 50 ms | Accessibility insertion, no keystroke synthesis, no clipboard round trip |
| Escape → recording discarded | immediate | the gate cancels the in-flight task rather than waiting for it |
| history search | instant at tens of thousands of rows | FTS5 index, not `LIKE` |

## The three design choices that exist only for latency

**The pre-roll ring buffer.** `AVAudioEngine.start()` takes tens of milliseconds to
deliver its first callback, and people begin speaking *as* they press the key. Without
a pre-roll the first syllable is simply missing. The engine runs continuously while
idle, filling a short circular buffer; pressing the key means "start keeping what you
already heard".

**Recording starts on key *down*, not after the tap threshold.** The gate cannot yet
know whether a press is a tap or a hold, and waiting to find out would clip the start
of every utterance. So it starts immediately and cancels if the press turns out to be
a shortcut. Cancelling a 200 ms recording costs nothing; losing the first word costs
the user's trust. `HotkeyStateMachineTests.testRecordingStartsBeforeTheTapThresholdElapses`
pins this.

**Connection warm-up.** `TranscriptionProvider.warmUp()` is called when recording
starts, not when it ends — an unauthenticated throwaway request that opens the pooled
TLS connection. The 4xx that comes back is discarded and it never counts as a
transcription.

## Measured

From `PerformanceTests`, on the Intel machine this was developed on — which is the
slower case, not the flattering one:

| What | Measured |
|---|---|
| arming the microphone (Rant's own overhead) | **0.01 ms** |
| everything after the transcript arrives — cleanup, vocabulary, classification, storage, insertion | **4.1 ms** |
| the same, for a 50-word dictation | **5.9 ms** |
| the same, for a 2,000-word dictation | **31.7 ms** |

The last two are the important pair. Forty times the words costs about five times the
work, not forty — the text passes are linear and the rest is fixed cost. A regression
to anything super-linear fails
`testALongDictationDoesNotSlowThePipelineDisproportionately`.

What is *not* in these numbers is the provider round trip, which is the only part
Rant does not control. The budgets above bracket it on both sides so that when
dictation feels slow, it is clear whether that is Rant or the network.

## Deliberately not on the hot path

Context capture and provider warm-up both happen **after** `audio.start()` returns,
so neither can delay the first sample. `SessionTests.testAudioStartsBeforeContextIsGatheredAndTheConnectionIsWarmed`
asserts the ordering.

## Where the milliseconds are recorded

`LatencyBreakdown` carries `captureStartMs`, `transcriptionMs`, `enhancementMs`,
`injectionMs` and `totalMs`, stored in `latency_samples`. It is surfaced only in
Settings → Diagnostics. A dictation app that reports its own latency at you is a
dictation app you notice, and the goal is not to be noticed.

## Things that must never block

- No network call on the main thread.
- No transcription work in the audio tap callback — it converts and hands off.
- No `LIKE '%…%'` scan for history search.
- **No regex with nested quantifiers on user text.** This is not hypothetical: the
  first version of the self-correction pass was a lazy regex and hung the test suite
  on a 200-word input. Both correction passes are now linear token scans. Any new text
  pass gets an adversarial-input test.

## Measuring

```bash
swift test --filter PerformanceTests
log show --predicate 'subsystem == "dev.rant.mac"' --last 1h --info | grep latency
```
