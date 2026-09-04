# Progress

_Last updated: 2026-09-04_

## At a glance

| | |
|---|---|
| **Tasks** | **54 of 54 complete** |
| **Engine build** | ✅ clean — zero warnings, warnings treated as failures |
| **Unit tests** | ✅ **765 passing**, 0 failing, 1 skipped |
| **UI tests** | ✅ 9 passing — **opt-in**, they take over the cursor (`bash scripts/ui-test.sh`) |
| **`scripts/check.sh`** | ✅ **8 passed, 0 failed, 2 skipped** (both skips are honest, see below) |
| **Published** | https://github.com/momenbuilds/rant-mac |
| **Real dictation** | ✅ confirmed end to end |

## Measured, not claimed

From `PerformanceTests`, on the Intel machine this was built on — the slower case:

| | |
|---|---|
| arming the microphone (Rant's own overhead) | **0.01 ms** |
| everything after the transcript arrives | **4.1 ms** |
| a 50-word dictation, post-provider | **5.9 ms** |
| a 2,000-word dictation, post-provider | **31.7 ms** |

Forty times the words costs five times the work, not forty. The provider round trip is
the only part Rant does not control, and the budgets bracket it on both sides so a slow
dictation can be attributed correctly.

## What is built

Dictation (push-to-talk, toggle, hands-free, lone-modifier triggers that leave ⌘C
alone), four cleanup levels with the first three deterministic and offline,
Accessibility-first insertion with a clipboard fallback, three speech providers
(AssemblyAI sync, AssemblyAI streaming, local whisper.cpp), a context engine with a
single audited outbound boundary, dictionary and snippets, styles and modes, local
history with FTS search, Insights, Rant Archive export/import, a Migration Center with
eleven adapters, the meeting Notetaker, selected-text transforms with a real
word-level diff, a constrained command mode, an Actions layer with permission classes
and confirmation tokens, opt-in adaptive learning, local semantic search, and a
loopback-only MCP server with a working socket and stdio transport.

## Bugs the tests caught

Every one would have shipped. The full list is in the git history; the ones worth
knowing about:

1. A lazy regex in the self-correction pass **hung the app** on long dictations.
2. Spoken-punctuation expansion took **4.1 seconds** per dictation — sixty string
   allocations per word, on the critical path.
3. A streaming session cancelled during the websocket handshake **never terminated**,
   billing until AssemblyAI timed it out.
4. Audio retention used `hasPrefix` for path containment, so a sibling directory
   sharing a prefix **had its files deleted**.
5. Reading the Keychain from the sidebar footer meant a read on every redraw — and on
   the file keychain each read can raise a password dialog that is modal to the app,
   so it appeared *before* the window and blocked it entirely.
6. Styles and Modes were `Identifiable` on a database row id that is nil for every
   built-in, so SwiftUI drew the first style ten times.
7. Streak calculation broke on DST days; `words_per_minute` truncated 4.5 to 4.0 on
   every read; half the Actions vocabulary was unreachable; adaptive learning never
   learned the useful case.

## The two honest skips

- **Global text injection** is not automated and will not be. It needs real
  permissions and real applications; a flaky test guarding something that important is
  worse than the manual matrix in `docs/SMOKE_TEST.md`.
- **The XCUITest suite is opt-in.** It drives the real cursor and makes the machine
  unusable for two minutes, so it does not run on every check. CI runs it with
  `RUN_UI_TESTS=1`.

## Honest gaps

- **No Developer ID certificate**, so builds are ad-hoc signed and Gatekeeper refuses
  them on another Mac. That is why `install.sh` builds from source instead of shipping
  a binary. `docs/PACKAGING.md` says exactly what changes when a certificate exists.
- **No auto-updater.** One that cannot verify signatures is a remote code execution
  feature.
- **The whisper.cpp backend is a protocol without its C binding.** Everything around
  it is built and tested, and the provider throws `modelUnavailable` rather than
  silently reaching for the network.
- **The VoiceOver walkthrough has not been done by a person.** The static pass fixed
  what a static pass can find.
