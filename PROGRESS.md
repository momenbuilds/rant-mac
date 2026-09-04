# Progress

_Last updated: 2026-09-04_

## At a glance

| | |
|---|---|
| **Current task** | RANT-023/024 — dictionary and snippets storage |
| **Build** | ✅ engine builds clean (0 warnings) · ✅ app builds (`BUILD SUCCEEDED`) |
| **Unit tests** | ✅ **156 passing**, 0 failing, 1 skipped (needs a real Accessibility grant) |
| **UI tests** | ⬜ not written yet — RANT-065 |
| **`scripts/check.sh`** | ✅ **7 passed, 0 failed, 1 skipped** |
| **Dev build installed** | `/Applications/Rant Dev.app` (bundle `dev.rant.mac.dev`) — launches, onboarding renders |
| **Blockers** | One: an AssemblyAI API key is needed to transcribe real speech. See below. |

## What works right now

The **Phase B core loop is complete and tested end to end.** With an API key pasted
in, holding the trigger key records, releasing transcribes, and clean text is
inserted at the cursor.

- **Hotkey** — push-to-talk, tap-to-toggle, double-tap hands-free, Escape to cancel,
  lone-modifier triggers that leave ⌘C alone. Driven by a pure state machine with 19
  tests including a 4,000-step fuzz across all three activation modes.
- **Audio** — `AVAudioEngine` at 16 kHz mono, with a 300 ms pre-roll ring buffer so
  the first syllable is never clipped by engine start-up.
- **Speech** — AssemblyAI dictation endpoint, key from the Keychain, connection
  pre-warmed at record start. 27 tests assert on the actual request bytes.
- **Cleanup** — four levels, deterministic and offline for the first three.
  Punctuation, fillers, stutters, spoken commands, and self-correction
  ("send it Tuesday, actually Wednesday" → "Send it Wednesday."). 29 tests.
- **Injection** — Accessibility first, clipboard + ⌘V fallback, clipboard restored
  only after the paste settles, secure fields refused outright. 22 tests.
- **History** — SQLite with versioned migrations and FTS5 search, per-item and bulk
  deletion, deduplication by content hash. 32 tests.
- **App** — onboarding, menu bar, floating non-activating overlay with live waveform,
  Home, History, and five Settings panes.

## What I need from you

**An AssemblyAI API key**, to make the first real transcription. Everything around it
is built and tested against mocks, so this is the only thing standing between the
current build and dictating for real.

1. Open **Rant Dev** (already installed and running).
2. Onboarding → **Continue** to the *Where should the listening happen?* step.
3. Paste the key into **Paste your AssemblyAI API key** → **Save to Keychain**.
   *(Or later: Settings → Speech → same field, plus a **Test connection** button.)*

The key goes straight to the macOS Keychain. It is never written to preferences,
logs, or any file, and it is never displayed again once stored.

You will also be asked for **Microphone** and **Accessibility** permissions during
onboarding — macOS requires a human click for both, and Accessibility in particular
cannot be granted programmatically.

## Completed

| Task | Evidence |
|---|---|
| RANT-001 bootstrap | repo, MIT `LICENSE`, doc skeleton |
| RANT-002 task tracking | `scripts/status.sh` runs |
| RANT-003 competitor audit | `scripts/check-audit.sh` — 107 rows, 8 explicit skips, 0 silent omissions |
| RANT-004 architecture + decisions | `docs/ARCHITECTURE.md`, `docs/DECISIONS.md` (D-001…D-010) |
| RANT-005 package scaffolding | `swift build` clean |
| RANT-006 logging + redaction | `RantLog` exposes no method taking user text |
| RANT-007 Keychain | `KeychainSecretStore`, `APIKeyValidator` |
| RANT-008 storage + migrations | `swift test --filter StoreTests` — 32 passing |
| RANT-009 permissions | `Permissions` with per-pane deep links |
| RANT-010 hotkey state machine | `swift test --filter HotkeyStateMachineTests` — 19 passing |
| RANT-011 audio capture | `MicrophoneCapture` with pre-roll; `MeterGeometry` pure |
| RANT-012 AssemblyAI provider | `swift test --filter AssemblyAITests` — 27 passing |
| RANT-013 text injection | `swift test --filter InjectionTests` — 22 passing |
| RANT-014 recorder overlay | non-activating `NSPanel`, all states, Reduce Motion |
| RANT-015 session orchestrator | `swift test --filter SessionTests` — 27 passing |
| RANT-016 app shell + XcodeGen | `BUILD SUCCEEDED` |
| RANT-017 onboarding + settings | verified on screen |
| RANT-018 stable dev install | `bash scripts/dev-build.sh` → `/Applications/Rant Dev.app` |
| RANT-019 retry / paste-last | covered in `SessionTests` |
| RANT-020 context engine | `AccessibilityContextProvider`, `SurfaceClassifier` |
| RANT-021 cleanup levels | `swift test --filter CleanupTests` — 29 passing |
| RANT-060 check.sh | 7 passed, 0 failed, 1 skipped |

## Bugs the tests caught (worth recording)

1. **Double-tap never reached hands-free.** The second tap of a pair landed in the
   `recordingKeyHeld` state, which treated every press as a stop. Also, the promotion
   was emitted as `startRecording(.handsFree)`, which would have discarded the audio
   from the first tap — now a distinct `promoteToHandsFree` action.
2. **The cleanup pipeline hung.** The self-correction pass was a lazy regex and
   backtracked catastrophically on a 200-word input — it would have frozen the app on
   a long dictation. Both correction passes are now linear token scans.
3. **Duplicate imports inflated the statistics.** `INSERT OR IGNORE` looks like
   success from the outside, so usage aggregates were updated for rows that were
   never inserted. The existence check now precedes the insert.
4. **Newline detection was unreachable.** Insertion spacing skipped whitespace before
   testing for a newline, so text dictated at the start of a new line was lowercased
   as if it continued the previous sentence.

## Next three

1. RANT-023/024 — dictionary and snippets, stored and editable
2. RANT-032/033 — Rant Archive export/import, then the Migration Center
3. RANT-031 — Insights from the aggregates already being written
