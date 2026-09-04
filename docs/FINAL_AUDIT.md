# Rant — Final Completeness Audit

Contract: `docs/MASTER_PROMPT.md` (recovered verbatim from the original build prompt).
`TASKS.md` is not the contract; where the two disagreed, the master prompt won.

Statuses are **PASS**, **PARTIAL**, **FAIL**, **BLOCKED_EXTERNAL** only. PASS requires
observable behaviour or an automated test that exercises the behaviour — never the mere
existence of a type. That distinction is the whole point of this document: nearly every
gap it found was a fully-implemented, fully-tested type that nothing called.

## The headline finding

`RantCore` implements very nearly the whole specification and is covered by 814 unit
tests. The **app shell reached only part of it.** Eighteen engine entry points were
implemented, tested, and referenced *nowhere* in `App/Rant`, and several screens
described behaviour that had no path from the user interface to the code that performs
it — the specific failure the master prompt forbids in §45.

The ones that mattered most:

| Was | Evidence it was broken | Now |
|---|---|---|
| **No local speech engine at all** | `WhisperBackend`'s only conformer in the repository was `FakeWhisperBackend`, in the tests. Choosing local selected a provider that could not transcribe; with Local only on, dictation was impossible. | `AppleSpeechProvider` — on device, no key, no download. `scripts/local-speech-smoke.sh` speaks a pangram and gets it back. |
| **The Engine picker changed nothing** | `makeTranscriptionProvider()` was `switch preferences.speechProvider { default: return AssemblyAIProvider(...) }`, and the picker listed one option. | Both picker and session resolve through `ProviderRegistry`. |
| **The Notetaker recorded nothing** | `startMeeting()` requested a permission, set a string, returned. No capture, no transcript, no row — and the list read from a store nothing inserted into. | `MeetingController`: capture, windowed transcription, summary, saved meeting, live transcript. |
| **Transforms was a catalogue** | The page said "press your transform key" (never registered) and promised a diff (did not exist). `TransformEngine` was unreferenced. | ⌥⇧T, selection capture, diff, accept / reject / copy / edit. |
| **Styles never reached a dictation** | `dictationSettings` never set `styleInstruction`, so it was nil on every request and `StyleResolver` was dead code. | Resolved inside the session after context; `StyleRoutingTests`. |
| **Modes were unreachable** | `ModesView` existed and was in no sidebar group. `ModeResolver` was unreferenced. | In the sidebar, editable, and it changes the pipeline; `ModeRoutingTests`. |
| **Audio retention never deleted anything** | The policy was stored and displayed; `AudioRetention` was called from nowhere. | Swept at launch and on change. |
| **The microphone setting did nothing** | `preferredDeviceID` was assigned and never read; there was no picker and no enumeration. | CoreAudio enumeration, real selection, live meter. |
| **MCP was a boolean** | `mcpEnabled` was read by nothing; the server never started. | Starts and stops, loopback only, consent per collection. |
| **Live partials did not exist** | `AppModel.partialText` was published, never set, never displayed; the session had no streaming path. | Preview under the pill; refused under Local only. |
| **Release shipped test hooks** | Four launch arguments, one of which erases every preference and one of which swaps the Keychain for an in-memory store. | `#if DEBUG`. Verified: zero occurrences in the Release binary. |

### The one that was not an app-shell gap

**`check.sh` — the definition of green — reported PASS while unit tests were failing.**

`check_tests` grepped for `", with [1-9][0-9]* failures?"`. That matches
`"Executed 800 tests, with 2 failures"`, and stops matching the moment anything is
skipped, because the summary becomes `"with 2 tests skipped and 2 failures"` and the
count no longer follows `with `. So from the first skipped test onwards, any run with
both a skip and a failure went green.

It was hiding two real failures on CI. Both were tests whose outcome depended on how
loaded the machine was — `LocalSTTTests` recording download progress through an
unawaited `Task`, and a streaming test whose 30 ms termination grace expired before a
busy runner could push the final turn. Neither is a product defect; both had been red
on CI with nobody being told.

The check now consults the exit status of `swift test`, which it never did, keeps a
summary scan as a second line of defence, and prints the failing assertions instead of
swallowing them. Verified against the exact string that fooled it:

```
$ printf 'Executed 814 tests, with 2 tests skipped and 2 failures (0 unexpected)\n' > /tmp/p
$ grep -cE ", with [1-9][0-9]* failures?" /tmp/p   # old guard
0
$ grep -cE "[1-9][0-9]* (unexpected )?failures?" /tmp/p   # new guard
1
```

This is worth its own heading because every other finding in this document was found
*by* reading the code, and this one determines whether anything else in it can be
believed. A green light that goes green when tests fail is worse than no green light.

Reproduce the shape of the original finding:

```
for t in TransformEngine CommandExecutor MCPServer LearningEngine ProviderRegistry \
         AudioRetention ModeResolver StyleResolver LocalWhisperProvider; do
  grep -rl "$t" App/Rant >/dev/null || echo "not referenced in app: $t"
done
```

## Matrix

| ID | Area | Requirement (master prompt §) | Implementation evidence | Test evidence | Status | Note |
|----|------|------------------------------|-------------------------|---------------|--------|------|
| A-01 | Platform | Native Swift/SwiftUI/AppKit, no Electron/web shell (§5) | 122 Swift files, zero JS/HTML | build | PASS | — |
| A-02 | Architecture | Engine/app split; RantCore imports no SwiftUI (§6) | `check.sh` layering check | check.sh | PASS | — |
| A-03 | Architecture | Provider protocols, AssemblyAI not hardwired (§6) | `AppModel.speechProviderRegistry()` | `AppleSpeechTests` | PASS | closed this pass |
| B-01 | Core loop | Push-to-talk / toggle / hands-free / cancel (§8) | `DictationGate` | `HotkeyStateMachineTests` | PASS | — |
| B-02 | Core loop | Lone-modifier trigger leaves shortcuts alone (§8) | `HotkeyEngine.isDown` | `HotkeyEngineClassificationTests` | PASS | was cancelling every recording; fixed |
| B-03 | Core loop | Overlay states, waveform, cancel affordance (§8) | `RecorderOverlay` | manual | PASS | — |
| B-04 | Injection | Accessibility-first, clipboard fallback, restore (§9) | `Sources/RantCore/Injection` | `InjectionTests` | PASS | — |
| B-05 | Core loop | Retry last failure; paste last transcript (§8) | menu bar items | manual | PASS | — |
| C-01 | STT | AssemblyAI BYOK, key in Keychain only (§7) | `AssemblyAIProvider`, `SecretStore` | `AssemblyAITests`, `SecretStoreTests` | PASS | — |
| C-02 | STT | Streaming partial transcripts, reconnect/backoff (§7) | session streaming path, `makeStreamingProvider()` | `LivePreviewTests`, `StreamingTests` | PASS | refused under local-only |
| C-03 | STT | **At least one practical fully-local provider** (§7, §9) | `AppleSpeechProvider`, `SystemOnDeviceRecogniser` | `AppleSpeechTests` + `scripts/local-speech-smoke.sh` | PASS | real speech, offline, on this machine |
| C-04 | STT | Provider picker changes the provider (§7, §45) | `makeTranscriptionProvider()` | `AppleSpeechTests` | PASS | — |
| C-05 | STT | Local model download / progress / delete / disk use (§9) | `ModelStore`, `ModelCatalog` | `LocalSTTTests` | PARTIAL | only needed for whisper.cpp now; RANT-085, stated in the README |
| C-06 | STT | Local-only refuses network, never silently falls back (§7) | `DictationSession:156` | `SessionTests` | PASS | — |
| D-01…03 | Cleanup | Four levels, self-correction, spoken punctuation (§11) | `TranscriptCleaner`, `SpokenPunctuation` | `CleanupTests` | PASS | — |
| E-01 | Context | Frontmost app, field role, selection, cursor text (§10) | `AccessibilityContextProvider` | unit | PASS | — |
| E-02 | Context | Secure fields never read (§10, §33) | `SurfaceClassifier` | `InjectionTests` | PASS | — |
| E-03 | Context | Single audited outbound boundary; redaction (§10) | `OutboundContext`, `SecretRedactor` | unit | PASS | — |
| E-04 | Context | Per-app exclusions (§10) | `ContextSettings.excludedBundleIDs` | unit | PASS | — |
| F-01 | Dictionary | CRUD, search, replacement, casing, import/export (§13) | `DictionaryView` | `DictionaryTests` | PASS | — |
| F-02 | Learning | Opt-in learn-from-corrections (§13) | `LearningObserver` | `LearningTests` | PASS | inert until accepted |
| G-01 | Snippets | CRUD + expansion inside dictation (§14) | engine + UI | `DictionaryTests` | PASS | — |
| H-01 | Styles | Custom instructions, per-category/app/site override (§15) | editable `StylesView` | `StyleRoutingTests` | PASS | — |
| I-01 | Modes | Modes control the pipeline (§16) | `DictationSettings.modeResolver` | `ModeRoutingTests` | PASS | — |
| J-01 | Transforms | Selection → transform → diff → accept/reject/edit (§17) | `TransformController`, ⌥⇧T | `TransformTests` | PASS | — |
| K-01 | Command mode | Instructions on context, with preview (§18) | `CommandController`, ⌥⇧C | `CommandModeTests` | PASS | text-only by construction |
| L-01 | Scratchpad | Notes CRUD, pin, search, export (§19) | `ScratchpadView` | `ScratchpadTests` | PASS | — |
| M-01 | History | Store all metadata fields (§20) | `Storage` | `StoreTests` | PASS | — |
| M-02 | History | **Delete ONE** transcript (§20) | `TranscriptRow` trash → `AppModel.delete(_:)` | `StoreTests` | PASS | audit first misread this as missing; the row lives in `HomeView.swift` |
| M-03 | History | Copy / paste again / retry / favourite / tags (§20) | per-row copy, show-raw, delete; menu-bar paste-last and retry | `StoreTests` | PARTIAL | favourite and per-item tags unimplemented, though the schema carries them |
| N-01 | Audio retention | Policy actually enforced (§20) | `sweepRetainedAudio()` | `RetentionTests` | PASS | — |
| O-01 | Insights | Local aggregates, no hardcoded numbers (§21) | `InsightsEngine` | `InsightsTests` | PASS | — |
| O-02 | Voice profile | Explainable local stats (§22) | Insights "Your voice" | `InsightsTests` | PASS | no personality labels |
| P-01 | Notetaker | Capture, live transcript, persistence, summary, exports (§23) | `MeetingController` | `MeetingTests`, `MeetingExportTests` | PASS | says when only the microphone is captured |
| Q-01 | Calendar | EventKit, permission, join links, denied path (§24) | `EventKitCalendar` | `MeetingTests` | PASS | read-only, never uploaded |
| R-01 | Migration | Adapters, preview, dry run, idempotent import (§25) | `MigrateView` + adapters | `MigrationTests` | PASS | — |
| R-02 | Archive | Rant Archive export/import round trip (§25) | `RantArchiveAdapter` | `ArchiveTests` | PASS | — |
| S-01 | Search | SQLite FTS5 over transcripts/notes/meetings (§26) | `Storage` FTS | `StoreTests` | PASS | — |
| S-02 | Search | Optional local semantic recall (§26) | History "Related by meaning" | `SemanticSearchTests` | PASS | `NLEmbedding`, on device |
| T-01 | MCP | Loopback-only server, off by default, enable UI (§27) | `MCPController` | `MCPTransportTests` (real sockets) | PASS | consent per collection |
| U-01 | Actions | Registered capabilities, permission class, confirmation (§28) | `ActionsController` | `ActionsTests` | PASS | `runsCommand` unavailable by design |
| V-01 | Settings | The seven sections the spec names (§29) | `SettingsPane` | `OnboardingUITests` | PASS | plus Diagnostics |
| W-01 | Onboarding | Permissions explained, key entry, never traps (§30) | `OnboardingView` | `OnboardingUITests` | PASS | — |
| X-01 | Menu bar | Full menu, no dead items (§32) | `MenuBarContent` | manual | PASS | History and Settings navigate |
| Y-01 | Privacy | No telemetry, keys in Keychain, no transcript logging (§33) | `check.sh` secret scan, `RantLog` | check.sh | PASS | — |
| Z-01 | Data model | Versioned migrations, WAL, FTS5 (§34) | `Storage` | `StoreTests` | PASS | — |
| Z-02 | Performance | Measured budgets (§35) | `PerformanceTests` | unit | PASS | — |
| Z-03 | Packaging | Debug + Release build, stable dev install (§37, §40) | `dev-build.sh`, `package.sh` | Release universal; zero test hooks in binary | PASS | — |
| Z-04 | Licence | No GPL VoiceInk source in this MIT codebase (§4) | `check.sh` licence guard | check.sh | PASS | — |
| Z-05 | Compatibility | Per-application insertion matrix (§9, §11) | `docs/APP_COMPATIBILITY.md` | — | BLOCKED_EXTERNAL | needs a human; see below |
| Z-06 | Distribution | Notarised build (§40) | `docs/PACKAGING.md` | — | BLOCKED_EXTERNAL | needs a Developer ID certificate |
| Z-07 | STT | A real AssemblyAI round trip (§8) | provider + mocks complete | `AssemblyAITests` | BLOCKED_EXTERNAL | needs a key; on-device covers dictation meanwhile |

## The three that are not PASS, and why

**C-05 and M-03 are PARTIAL, deliberately.** Neither is a false claim in the UI. The
model-download controls exist and work; what is missing underneath is the whisper.cpp
binding, and the README says so. Favourites and per-item tags have schema columns and
no interface, which is a missing feature rather than a broken one.

**Z-05 is BLOCKED_EXTERNAL and cannot be automated away.** Verifying that insertion
works in Slack, Terminal or Safari means putting text into somebody's real
applications, where the consequences are not symmetrical: a stray paste into Slack
sends a message, into Terminal runs a command. A harness willing to do that to a live
machine is worse than an honest empty column. The *mechanism* those rows depend on —
Accessibility-first insertion, clipboard fallback, clipboard save and restore, spacing,
and the secure-field refusal — is covered by `InjectionTests` on every check.

## What the audit could not verify itself

- **XCUITest on the build machine.** The runner is killed before it bootstraps
  (`Test crashed with signal kill before establishing connection`). The suite runs in
  CI instead, which is where its result is recorded.
- **A real AssemblyAI transcription.** No key on this machine. Everything around it is
  built and tested against mocks; the on-device engine means this is no longer a
  blocker for dictation working at all.
