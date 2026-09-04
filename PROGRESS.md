# Progress

_Last updated: 2026-09-04 — Final Completeness Audit_

## Current work

The Final Completeness Audit is finished. Rant was re-audited against
`docs/MASTER_PROMPT.md` rather than against `TASKS.md`, and what the audit found has
been fixed. The requirement matrix, with evidence per item, is `docs/FINAL_AUDIT.md`.

Work is on `worktree-final-audit`, open as PR #1.

## At a glance

| | |
|---|---|
| **`scripts/check.sh`** (CI, run 33906055652) | ✅ **8 passed, 0 failed, 1 skipped** |
| **Unit tests** | ✅ **814 passing**, 0 failing, 2 skipped (both opt-in) |
| **UI tests (XCUITest)** | ✅ **9 passing**, 0 failing |
| **Engine build** | ✅ clean — warnings treated as failures |
| **App build** | ✅ Debug and Release; Release universal (x86_64 arm64), zero test hooks in the binary |
| **Installed dev app** | `/Applications/Rant Dev.app`, signed with a real Apple Development certificate so TCC grants survive rebuilds |
| **Local speech** | ✅ verified with real audio on this machine |

## The finding that matters most

**`check.sh` reported PASS while unit tests were failing.** Its failure grep stopped
matching the moment any test was skipped, so from the first skipped test onwards a run
with both a skip and a failure went green. It was concealing two genuinely red tests on
CI. Repaired, and verified against the exact string that fooled it — see
`docs/FINAL_AUDIT.md`. Everything else in this file depends on that check being honest,
which is why it is first.

## What else the audit found

`RantCore` implements very nearly the whole specification and is well covered. The
**app shell reached only part of it**: eighteen implemented, tested engine entry points
were referenced nowhere in `App/Rant`, and several screens described behaviour with no
path from the interface to the code performing it.

| Was | Now |
|---|---|
| No local engine at all — `WhisperBackend`'s only conformer was a test fake, so "Local only" could not dictate | `AppleSpeechProvider`, on device, no key, no download. Real speech verified on this machine |
| Engine picker had one option and the selection was ignored | Picker and session both resolve through `ProviderRegistry` |
| Notetaker recorded nothing — `startMeeting()` asked for a permission and returned | `MeetingController` records, transcribes, summarises, saves; live transcript |
| Transforms was a list of prompts with an unregistered hotkey and no diff | ⌥⇧T, selection, diff, accept / reject / copy / edit |
| Styles never reached a dictation | Resolved in the session after context; `StyleRoutingTests` |
| Modes were in no sidebar group; the resolver was unused | In the sidebar, editable, changes the pipeline; `ModeRoutingTests` |
| Audio retention displayed and never enforced | Swept at launch and on change |
| Microphone preference assigned and never read | CoreAudio enumeration, real selection, live meter |
| MCP was a boolean nothing read | Starts and stops, loopback only, consent per collection |
| Command mode had no key | ⌥⇧C, preview before anything is written |
| Live partials did not exist | Preview under the pill; refused under Local only |
| Actions were constructed only in tests | Listed with permissions in Integrations; confirmation is a real stop |
| Calendar had a fixture conformer only | `EventKitCalendar`, read-only |
| Correction learning and the voice profile computed and never shown | Both wired; learning opt-in |
| Release shipped four test hooks, one erasing every preference | `#if DEBUG`; verified absent from the Release binary |

## Known failures

None. `check.sh` is green for every runnable check, and the check is now trustworthy.

Two flaky tests were fixed rather than retried: both had made their outcome a property
of how loaded the machine was, and both are now deterministic.

## Honest skips

- **Global text injection** — cannot be honestly automated. Manual matrix in
  `docs/SMOKE_TEST.md`. The mechanism it depends on is covered by `InjectionTests`.
- **XCUITest locally** — opt-in, and the runner cannot bootstrap on this machine
  (`Test crashed with signal kill before establishing connection`). It runs in CI,
  where all nine pass.
- **`scripts/local-speech-smoke.sh`** — opt-in: it needs the Speech Recognition grant,
  and a permission prompt would hang a CI runner.

## External blockers

- **A real AssemblyAI transcription** — no key on this machine. Everything around it is
  built and tested against mocks. Settings → Speech → paste the key → Test connection.
  No longer blocks dictation: the on-device engine needs no key.
- **Per-application insertion matrix** — needs a person. Verifying it means pasting
  into real applications, where a stray paste into Slack sends a message and into
  Terminal runs a command.
- **Notarisation** — needs a Developer ID certificate. See `docs/PACKAGING.md`.

## Next

1. Merge PR #1.
2. Walk `docs/SMOKE_TEST.md` to fill in the compatibility matrix.
3. RANT-085 — whisper.cpp behind `WhisperBackend`, for a specific chosen model.
4. Per-item favourites and tags in history (schema already carries the columns).
