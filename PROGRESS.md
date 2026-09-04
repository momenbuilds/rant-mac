# Progress

_Last updated: 2026-09-04_

## At a glance

| | |
|---|---|
| **Build** | ✅ engine builds clean (0 warnings) · ✅ app builds · ✅ UI test target builds |
| **Unit tests** | ✅ **641 passing**, 0 failing, 1 skipped |
| **UI tests** | ✅ **9 passing** (onboarding, navigation, CRUD, settings persistence) |
| **`scripts/check.sh`** | ✅ **8 passed, 0 failed, 1 skipped** |
| **Dev build** | `/Applications/Rant Dev.app` (`dev.rant.mac.dev`) |
| **Real dictation** | ✅ **confirmed working end to end** — see below |
| **Tasks** | 47 of 54 complete |

## The core loop works for real

This is not "the tests pass". A live build, with a real AssemblyAI key in the
Keychain, has transcribed real speech and written it to history:

> "How are you doing?" — 4 words, 96 wpm, dictated into Terminal

Accessibility had not been granted on that run, so injection correctly took the
clipboard fallback path and said so, which is exactly the designed behaviour.

**To get direct insertion** (no clipboard round trip), grant Accessibility to
`Rant Dev.app` — Home shows a Grant button, or System Settings → Privacy & Security
→ Accessibility.

## What works

**Dictation** — push-to-talk, tap-to-toggle, double-tap hands-free, Escape to cancel,
lone-modifier triggers that leave ⌘C alone. Pre-roll ring buffer so the first
syllable is never clipped. Connection pre-warmed at record start.

**Text** — four cleanup levels, the first three deterministic and offline. Spoken
punctuation, filler removal, stutter collapse, and self-correction
("send it Tuesday, actually Wednesday" → "Send it Wednesday.").

**Insertion** — Accessibility first, clipboard + ⌘V fallback, clipboard restored only
after the paste settles, secure fields refused outright.

**Speech providers** — AssemblyAI dictation endpoint, AssemblyAI v3 streaming, and a
local whisper.cpp provider with an honest model catalogue (size, RAM, and separate
Apple Silicon / Intel speed estimates).

**Context** — app, window, site, focused field, text around the cursor, selection,
developer symbols. One function decides what may leave the machine, and credential-
shaped text is redacted first.

**Vocabulary** — dictionary and snippets, editable in the app, applied to the very
next dictation.

**Styles and modes** — resolve site → app → category → default, with Terminal mode
doing no cleanup at all because a "helpfully" added full stop breaks a shell command.

**Ownership** — local history with FTS search, per-item and bulk deletion, Insights
from pre-aggregated tables, Rant Archive export/import, and a Migration Center with
adapters for Wispr Flow, VoiceInk, Superwhisper, Otter and seven generic formats.

**Notetaker** — meeting capture with system audio, Me/Them labelling, summaries with
a deterministic fallback, and five export formats.

**Power** — selected-text transforms with a real word-level diff, a constrained
command mode, developer context, scratchpad, and an opt-in local MCP server.

## Bugs the tests caught

Every one of these would have shipped:

1. **The cleanup pipeline hung.** The self-correction pass was a lazy regex and
   backtracked catastrophically on a 200-word input — a long dictation would have
   frozen the app. Both correction passes are now linear token scans.
2. **A streaming session cancelled during the websocket handshake never sent its
   terminate message**, so the session billed until AssemblyAI timed it out — on
   exactly the short takes people do most. Audio captured during the handshake was
   also silently dropped.
3. **Double-tap never reached hands-free**, and the promotion was emitted as a fresh
   `startRecording`, which would have discarded the first tap's audio.
4. **Duplicate imports inflated the statistics.** `INSERT OR IGNORE` looks like
   success from outside, so usage aggregates were updated for rows never inserted.
5. **Audio retention used `hasPrefix` for path containment**, so a sibling directory
   sharing a prefix was treated as managed and its files deleted.
6. **Streak calculation broke on DST days** because it did day arithmetic in seconds.
7. **`words_per_minute` was read through an integer accessor**, truncating 4.5 wpm to
   4.0 on every read. The stored value was always correct.
8. **Insertion spacing skipped whitespace before testing for a newline**, so text
   dictated at the start of a line was lowercased as if it continued the last sentence.
9. **An MCP meeting search returned one copy of a meeting per matching segment.**
10. **JSON `true` decoded as the integer 1** through `NSNumber`.

## Honest gaps

- **Global text injection is not automated**, and will not be. It needs real
  permissions and real applications, so it is a manual matrix in
  `docs/SMOKE_TEST.md`. `check.sh` reports it as a skip, never as a pass.
- **No Developer ID certificate**, so builds are ad-hoc signed and will be refused by
  Gatekeeper on another Mac. `docs/PACKAGING.md` says exactly what is missing.
- **No auto-updater.** An updater that cannot verify signatures is worse than none.
- The MCP loopback listener and the Actions layer are in progress.

## Next

See `TASKS.md`. Remaining: adaptive learning, semantic search, the Actions layer, the
MCP socket listener, packaging, and the accessibility audit.
