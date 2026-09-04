# Architecture

Rant is two pieces: **RantCore**, a dependency-free Swift package holding all the
logic, and **Rant**, a thin SwiftUI/AppKit shell that owns windows, permissions and
system integration. Everything interesting is testable without launching an app.

```
                 ┌────────────────────────────────────────────┐
   keyboard ───► │ HotkeyEngine  (CGEventTap → DictationGate)  │
                 └───────────────┬────────────────────────────┘
                                 │ .start / .stop / .cancel
                 ┌───────────────▼────────────────────────────┐
   microphone ─► │ AudioCapture (AVAudioEngine → 16k mono S16) │
                 └───────────────┬────────────────────────────┘
                                 │ PCM + level
   frontmost app ─► ContextEngine┤
                                 │ TranscriptionContext
                 ┌───────────────▼────────────────────────────┐
                 │ TranscriptionProvider                      │
                 │   AssemblyAISyncProvider  (dictation POST) │
                 │   AssemblyAIStreamProvider(v3 websocket)   │
                 │   LocalWhisperProvider    (offline)        │
                 └───────────────┬────────────────────────────┘
                                 │ raw + cleaned text
                 ┌───────────────▼────────────────────────────┐
                 │ TextPipeline                               │
                 │   dictionary → snippets → cleanup → style  │
                 │   → EnhancementProvider (optional)         │
                 └───────────────┬────────────────────────────┘
                                 │ final text
                 ┌───────────────▼────────────────────────────┐
                 │ TextInjector (AX first, ⌘V fallback)       │
                 └───────────────┬────────────────────────────┘
                                 │
                       TranscriptStore (SQLite + FTS5)
```

## Why this shape

**The engine has no UI imports.** `RantCore` links Foundation and the system
frameworks it genuinely needs. It never imports SwiftUI. That is what makes the
hotkey state machine, the cleanup rules, the injector's spacing logic and the
migration adapters unit-testable on a machine with no display and no microphone.

**Everything crossing a boundary is a protocol.** The nine seams the product spec
names are the nine places we swap in a fake during tests:

| Protocol | Production | In tests |
|---|---|---|
| `TranscriptionProvider` | AssemblyAI sync / local whisper | `FakeTranscriber` returning fixtures |
| `StreamingTranscriptionProvider` | AssemblyAI v3 websocket | scripted partial/final sequence |
| `EnhancementProvider` | Apple FM, Ollama, OpenAI-compatible | deterministic echo |
| `ContextProvider` | Accessibility + window list | literal `TranscriptionContext` |
| `TextInjector` | AX value set, else synthesised ⌘V | recording spy |
| `HotkeyProvider` | `CGEventTap` | direct event injection into the gate |
| `AudioCaptureProvider` | `AVAudioEngine` | PCM from a fixture WAV |
| `TranscriptStore` | SQLite | in-memory SQLite (same code path) |
| `MigrationAdapter` | one per source format | fixture directories in `Tests/Fixtures` |

**The pure core is separated from the effectful shell.** `DictationGate` is a value
type: events in, actions out, no timers, no globals, no I/O. `HotkeyEngine` is the
thin effectful wrapper that owns the event tap and the clock. The tricky logic —
distinguishing a hold from a tap from a double-tap, deciding whether a modifier is
part of a combination — lives in the value type where a test can drive a thousand
event sequences in a millisecond.

## Concurrency

Swift 6 strict concurrency, complete checking. `DictationSession` is an `actor`;
it owns the transition between capture, transcription and injection so two hotkey
presses cannot interleave. Injection and Accessibility calls hop to the main actor
because AppKit requires it. Networking is structured `async` with explicit
cancellation — pressing Escape cancels the in-flight task rather than orphaning it.

## Latency budget

Measured per stage and surfaced only in developer diagnostics:

| Stage | Target |
|---|---|
| hotkey → overlay visible | < 100 ms |
| hotkey → first audio sample captured | < 150 ms |
| capture end → transcript final | provider-bound; connection pre-warmed at record start |
| transcript final → text inserted | < 50 ms |

Two design choices exist purely to protect this. First, the audio engine keeps a
short pre-roll ring buffer so the first syllable is never clipped by engine start
latency. Second, the transcriber opens its HTTPS connection when recording *starts*,
not when it ends, so DNS/TCP/TLS is already paid for by the time there is audio to
send.

## Storage

One SQLite database at `~/Library/Application Support/Rant/rant.sqlite`, WAL mode,
schema versioned by a monotonic `user_version`. Migrations are an ordered array of
(version, SQL) pairs applied in a transaction; the test suite applies every prefix of
that array to catch a migration that only works from empty. Search is FTS5 over
transcripts, meetings and notes.

## The app shell

`App/Rant` owns: the menu bar item, the non-activating overlay panel, the main
window with its sidebar, onboarding, settings, and the TCC permission prompts. It
holds no logic that could live in the engine. If a piece of behaviour is worth a
test, it belongs in `RantCore`.
