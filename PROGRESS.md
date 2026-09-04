# Progress

_Last updated: 2026-09-04_

## At a glance

| | |
|---|---|
| **Tasks** | **54 of 54 complete** |
| **Engine build** | ✅ clean — zero warnings, warnings are treated as failures |
| **Unit tests** | ✅ **753 passing**, 0 failing, 1 skipped |
| **UI tests** | ✅ **9 passing** (onboarding, navigation, CRUD, settings persistence) |
| **`scripts/check.sh`** | ✅ **8 passed, 0 failed, 1 skipped** |
| **Packaging** | ✅ `dist/Rant-0.1.0.dmg` + `.zip`, checksums, DMG verified |
| **Real dictation** | ✅ **confirmed working end to end** |

## The core loop works for real

Not "the tests pass". A live build, with a real AssemblyAI key in the Keychain, has
transcribed real speech and written it to history:

> "How are you doing?" — 4 words, 96 wpm, dictated into Terminal

Accessibility had not been granted on that run, so injection correctly took the
clipboard fallback and said so — the designed behaviour.

**To get direct insertion** (no clipboard round trip), grant Accessibility to
`Rant Dev.app`. Home has a Grant button.

## What is built

**Dictation** — push-to-talk, tap-to-toggle, double-tap hands-free, Escape to cancel,
lone-modifier triggers that leave ⌘C alone. A 300 ms pre-roll ring buffer so the first
syllable is never clipped; the TLS connection is opened when recording *starts*.

**Text** — four cleanup levels, the first three deterministic and offline. Spoken
punctuation, filler removal, stutter collapse, self-correction
("send it Tuesday, actually Wednesday" → "Send it Wednesday.").

**Insertion** — Accessibility first, clipboard + ⌘V fallback, clipboard restored only
after the paste settles, secure fields refused outright with no override.

**Speech** — AssemblyAI dictation endpoint, AssemblyAI v3 streaming, and a local
whisper.cpp provider with an honest model catalogue (size, RAM, and separate Apple
Silicon / Intel speed estimates).

**Context** — app, window, site, focused field, text around the cursor, selection,
developer symbols. One function decides what may leave the machine; credential-shaped
text is redacted before it does.

**Vocabulary, styles, modes** — dictionary and snippets applied to the very next
dictation; styles and modes resolving site → app → category → default. Terminal mode
does no cleanup at all, because a "helpfully" added full stop breaks a shell command.

**Ownership** — local history with FTS search, per-item and bulk deletion, Insights
from pre-aggregated tables, Rant Archive export/import, and a Migration Center with
adapters for Wispr Flow, VoiceInk, Superwhisper, Otter and seven generic formats.

**Notetaker** — meeting capture with system audio, Me/Them labelling, summaries with a
deterministic fallback, five export formats, read-only EventKit calendar.

**Power** — selected-text transforms with a real word-level diff, constrained command
mode, developer context, scratchpad, an Actions layer with permission classes and
confirmation tokens, opt-in adaptive learning, local semantic search, and a
loopback-only MCP server with a real socket listener and stdio transport.

## Bugs the tests caught

Every one would have shipped:

1. **The cleanup pipeline hung.** The self-correction pass was a lazy regex and
   backtracked catastrophically on a 200-word input. Both passes are now linear token
   scans.
2. **Spoken-punctuation expansion took 4.1 seconds** on a long dictation — sixty
   string allocations per word, on the critical path. A first-word index fixed it; the
   whole suite halved as a side effect.
3. **A streaming session cancelled during the websocket handshake never terminated**,
   billing until AssemblyAI timed it out. Audio captured during the handshake was also
   dropped.
4. **An oversized MCP message produced no error reply**, because cancelling the socket
   straight after send discards queued data.
5. **`FileHandle.read(upToCount:)` never returned for pipe data**, so the MCP stdio
   transport read nothing at all.
6. **Double-tap never reached hands-free**, and the promotion discarded the first
   tap's audio.
7. **Duplicate imports inflated the statistics** — `INSERT OR IGNORE` looks like
   success from outside.
8. **Audio retention used `hasPrefix` for path containment**, so a sibling directory
   sharing a prefix had its files deleted.
9. **Streak calculation broke on DST days.**
10. **`words_per_minute` truncated 4.5 to 4.0 on every read.**
11. **Half the Actions vocabulary was unreachable** — the phrase table was keyed on raw
    text while lookups were canonicalised.
12. **Adaptive learning never learned the useful case**: a correction that shortens the
    text shifts every following word, and anchor voting picked the wrong offset.
13. **Insertion spacing lowercased text at the start of a new line.**
14. **An MCP meeting search returned one copy per matching segment.**
15. **JSON `true` decoded as the integer 1** through `NSNumber`.

## Honest gaps

- **Global text injection is not automated, and will not be.** It needs real
  permissions and real applications, so it is a manual matrix in
  `docs/SMOKE_TEST.md`. `check.sh` reports it as a skip, never as a pass.
- **The VoiceOver and keyboard-only walkthroughs have not been done by a person.** The
  static accessibility pass fixed what a static pass can find; whether the
  announcements are comprehensible needs someone with VoiceOver on.
- **No Developer ID certificate**, so builds are ad-hoc signed and Gatekeeper will
  refuse them on another Mac. `docs/PACKAGING.md` says exactly what is missing, and
  `scripts/package.sh` uses a real identity the moment one exists.
- **No auto-updater.** An updater that cannot verify signatures is a remote code
  execution feature.
- **The local whisper.cpp backend is a protocol with no binding yet.** Everything
  around it is built and tested; wiring the C library is the remaining step, and the
  provider throws `modelUnavailable` rather than silently reaching for the network.

## Verifying any of this yourself

```bash
bash scripts/check.sh          # the definition of green
bash scripts/status.sh         # task state
bash scripts/dev-build.sh      # build, install, launch
bash scripts/smoke-test.sh     # the manual matrix
bash scripts/package.sh        # .dmg and .zip in dist/
```
