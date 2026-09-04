# Progress

_Last updated: 2026-09-04 — during the Final Completeness Audit_

## Current work

The Final Completeness Audit: re-auditing the product against
`docs/MASTER_PROMPT.md` rather than against `TASKS.md`, and closing what it finds.
See `docs/FINAL_AUDIT.md` for the requirement matrix and the evidence per item.

Remaining: command mode, a selectable streaming provider, the Actions layer, an
app-compatibility pass against real applications, and a Release build.

## At a glance

| | |
|---|---|
| **Unit tests** | ✅ **810 passing**, 0 failing, 2 skipped (both opt-in, see below) |
| **`scripts/check.sh`** | ✅ **7 passed, 0 failed, 2 skipped** |
| **Engine build** | ✅ clean — warnings treated as failures |
| **App build (Debug)** | ✅ |
| **Installed dev app** | `/Applications/Rant Dev.app`, signed with a real Apple Development certificate so TCC grants survive rebuilds |
| **Local speech** | ✅ verified with real audio on this machine |
| **Branch** | `worktree-final-audit` |

## What the audit found

`RantCore` implements very nearly the whole specification and is well covered by
tests. The **app shell reached only part of it.** Eighteen fully-implemented engine
entry points were referenced nowhere in `App/Rant`, and several screens described
behaviour that had no path from the interface to the code that performs it — the
specific failure the master prompt forbids in §45.

Fixed, each with the evidence that moved it:

| Was | Now |
|---|---|
| No local engine at all. `WhisperBackend`'s only conformer in the repository was a test fake, so "Local only" could not dictate. | `AppleSpeechProvider`, on-device, no key, no download. Verified with real speech: `The quick brown fox jumps over the lazy dog` |
| Engine picker had one option and `makeTranscriptionProvider()` ignored the selection entirely | Both the picker and the session resolve through `ProviderRegistry` |
| Notetaker: `startMeeting()` asked for a permission and returned. No capture, no transcript, no saved meeting. | `MeetingController` records, transcribes in windows, summarises and saves |
| Transforms: a list of prompts, a hotkey that was never registered, a diff that did not exist | Hotkey, selection capture, diff, accept / reject / copy / edit |
| Styles never reached a dictation — `styleInstruction` was always nil | Resolved inside the session, after context; `StyleRoutingTests` |
| Modes: `ModesView` was in no sidebar group; `ModeResolver` unused | In the sidebar, editable, and it changes the pipeline; `ModeRoutingTests` |
| Audio retention displayed and stored, never enforced | Swept at launch and on change |
| Microphone preference assigned and never read; no picker | CoreAudio enumeration, real device selection, live meter |
| MCP: a boolean nothing read | Server starts and stops, loopback only, per-collection consent |
| Calendar: a fixture conformer and nothing else | `EventKitCalendar` |
| Settings had five of the seven sections the spec names | Notetaker, Integrations and Advanced added |
| Correction learning and the voice profile computed and never shown | Both wired; learning stays opt-in |

## Known failures

None outstanding. `check.sh` is green for every runnable check.

One observation worth recording rather than burying: a single run of the full suite
reported one failure, immediately after a `check.sh` run had left the machine loaded.
Nine subsequent runs — three of the whole suite, six of the timing-sensitive suites
(`MCPTransportTests`, `PerformanceTests`, `MeetingTests`) — were clean, and the failing
test could not be identified from the surviving output. It is noted here because an
intermittent failure nobody wrote down is an intermittent failure nobody fixes.

## Honest skips

- **XCUITest suite** — opt-in (`RUN_UI_TESTS=1`). It drives the real cursor and takes
  the machine over for two minutes, so it runs in CI rather than on every local check.
- **Global text injection** — cannot be honestly automated. Manual matrix in
  `docs/SMOKE_TEST.md`.
- **`scripts/local-speech-smoke.sh`** — opt-in, because it needs the Speech
  Recognition grant and a permission prompt would hang a CI runner.

## External blockers

- **AssemblyAI key.** Everything around it is built and tested against mocks. To use
  the cloud engine: Rant → Settings → Speech → paste the key → Test connection. Not a
  blocker for dictation any more: the on-device engine needs no key.
- **Notarisation.** The build is signed with an Apple Development certificate, which
  is right for this machine and not enough for distribution to others. See
  `docs/PACKAGING.md`.

## Next

1. Command mode on its own key, operating on context rather than dictating.
2. Streaming provider selectable for live partials.
3. Actions layer with confirmation for anything consequential.
4. App compatibility pass against the applications actually installed here.
