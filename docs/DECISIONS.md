# Decision records

Short, dated, and honest about the trade-off. Newest last.

## D-001 · MIT licence, and therefore a hard boundary against VoiceInk source
*2026-09-04*

Rant is MIT. VoiceInk, the closest open-source competitor, is GPLv3. Copying GPLv3
code into an MIT project is not permitted, and "rewriting it line by line while
looking at it" is the same act with extra steps.

**Decision.** Read VoiceInk's documentation and observe its shipped behaviour;
write every line of `Sources/` from the product requirements and Apple's APIs.
Blurt is MIT so reuse is lawful, but we still limit borrowing to factual API
contract details and record attribution.

**Cost.** Slower than forking. **Why anyway.** An MIT engine is the thing that makes
this useful to other people, and a licence violation would make the project
undistributable.

## D-002 · Native Swift, no web runtime
*2026-09-04*

The product requires a global event tap, Accessibility text insertion, a
non-activating floating panel, ScreenCaptureKit system audio, and sub-100 ms
overlay presentation. Electron can do none of the first four well and none of the
fifth at all.

**Decision.** Swift 6 + SwiftUI + AppKit. No Electron, Tauri, React Native, or
localhost web UI.

## D-003 · Two AssemblyAI paths, not one
*2026-09-04*

AssemblyAI exposes a synchronous dictation endpoint
(`POST https://dictation.assemblyai.com/transcribe`) that returns transcript *and*
LLM cleanup in a single round trip, and a streaming websocket
(`wss://streaming.assemblyai.com/v3/ws`) that returns partial turns live.

They are good at different things. The sync endpoint gives the best final text with
one request and no session management, but shows nothing until you stop speaking.
The websocket gives live partials — which is what makes the overlay feel alive and
lets you catch a misrecognition mid-sentence — but its finals are not LLM-cleaned.

**Decision.** Ship both behind `TranscriptionProvider`. Default to sync for final
quality; when streaming is enabled, run the websocket for *display only* and still
take the final text from the sync path. The user sees live text and gets the better
transcript. Streaming can also be used standalone for long utterances that exceed
the sync endpoint's 2-minute / 40 MB ceiling.

**Cost.** Audio is sent twice when both are on. Documented in
`docs/NETWORK_BEHAVIOR.md`, and it is a setting, not a default.

## D-004 · Raw and cleaned text are both first-class
*2026-09-04*

Competitors show you the polished output and discard the verbatim transcript. When
cleanup drops a word that mattered, there is no recovery.

**Decision.** Every transcript row stores `raw_text` and `final_text`. History shows
both, and either can be pasted. Cleanup is a lossy transform, so we keep the input.

## D-005 · Cleanup runs locally first, remotely only if asked
*2026-09-04*

**Decision.** The `None`/`Light`/`Medium` cleanup levels are implemented as
deterministic Swift — punctuation, capitalisation, filler removal, spoken-command
expansion, self-correction resolution. They run offline, cost nothing, and are unit
tested against a fixture corpus. Only `High`, and only when an enhancement provider
is configured, involves a model.

**Why.** Most of what dictation cleanup does is mechanical. Making the mechanical
part deterministic means it is testable, instant, free, and identical offline.

## D-006 · The hotkey gate is a pure value type
*2026-09-04*

Distinguishing hold from tap from double-tap, while not breaking ⌘C, is the single
most bug-prone part of the product, and it is untestable if it is entangled with a
`CGEventTap` and a real clock.

**Decision.** `DictationGate` is a struct: `(event, timestamp) -> [Action]`. No
timers, no I/O, injected time. The event tap is a thin adapter over it.

## D-007 · Local STT target is whisper.cpp, not SpeechAnalyzer or Parakeet
*2026-09-04*

The development machine is Intel x86_64. Apple's `SpeechAnalyzer` (macOS 26) and
Parakeet-class CoreML models depend on the Neural Engine, which Intel Macs do not
have. Selecting either as *the* local provider would mean the offline path is
untested on the machine building it.

**Decision.** `LocalWhisperProvider` (whisper.cpp, CPU, GGUF weights) is the local
provider that must work everywhere. `SpeechAnalyzer` is added behind an availability
gate as a fast path on Apple Silicon + macOS 26, and its absence is a feature flag
being off, never a crash.

## D-008 · Secure fields are a refusal, not a preference
*2026-09-04*

**Decision.** If the focused element is `AXSecureTextField`, Rant collects no
context from it and inserts nothing into it. There is no setting to turn this off.
Unit-tested, and the test is not allowed to be deleted without a decision record
superseding this one.

## D-009 · Migration never touches the source
*2026-09-04*

Reading another app's local data is legitimate when it is the user's own data and
the user pointed us at it. Circumventing a protection to get at it is not.

**Decision.** Adapters open files read-only, never write to the source directory,
never delete originals, never decrypt anything, never touch keychain items or
cookies belonging to another app, and never scan a directory the user did not
choose. Every import is preceded by a dry-run preview and produces an idempotent
result via content hashing.

## D-010 · No telemetry, and the claim is checkable
*2026-09-04*

Saying "we don't track you" is worth little in a binary. **Decision.** No analytics
or crash SDK is linked at all, and `docs/NETWORK_BEHAVIOR.md` enumerates every
outbound request the app is capable of making, so the claim can be verified against
the source and against Little Snitch.
