# Competitor audit

Researched 2026-09-04 against current public documentation and public source.

**Re-checked during the final completeness audit, same day.** That pass re-examined the
*Rant* column only — every MATCH and BEAT claim was tested against the implementation
rather than against the intent, and two were found to be false and are now marked as
such. The competitor columns were not re-researched in that pass and carry their
original date; a claim about what a competitor ships today should be re-read from their
documentation rather than trusted from this table.

| Product | Licence | What we did |
|---|---|---|
| [Wispr Flow](https://wisprflow.ai/) · [docs](https://docs.wisprflow.ai/) | Proprietary | Read public site + help centre. No assets, branding or UI copied. |
| VoiceInk | **GPLv3** | Public documentation and observed behaviour only. **No source copied or translated.** |
| [Blurt](https://github.com/AssemblyAI/blurt) | MIT | Read source. Reused *factual API contract knowledge* (AssemblyAI dictation wire format). Attribution in `THIRD_PARTY_NOTICES.md`. |
| [Superwhisper](https://superwhisper.com/) | Proprietary | Public site only. |

## Licence boundary (important)

VoiceInk is GPLv3 and Rant is MIT. These are incompatible in the copy direction.
The rule this project follows:

- We **may** observe what VoiceInk does — that a "mode" exists, that it can be
  triggered by an application or a website, that it can read the selection.
  Behaviour and ideas are not copyrightable.
- We **may not** copy, paste, adapt, or mechanically translate VoiceInk source
  code, structure-for-structure, into this repository.
- Every file in `Sources/` is written from the requirements in the product spec
  and from Apple's platform APIs.

Blurt is MIT, so reuse is legally permitted. Even so we implement our own code and
limit borrowing to *facts about AssemblyAI's HTTP contract* (endpoint, multipart
field names, JSON keys) which are not creative expression. Attribution is recorded
regardless, because that is the courteous reading of the licence.

## Capability matrix

Legend — **W** Wispr Flow · **V** VoiceInk · **B** Blurt · **S** Superwhisper.
`✓` present, `~` partial, `✗` absent, `?` not publicly documented.

### Core dictation

| Capability | W | V | B | S | Rant verdict |
|---|---|---|---|---|---|
| System-wide dictation into any app | ✓ | ✓ | ✓ | ✓ | MATCH |
| Push-to-talk (hold) | ✓ | ✓ | ✓ | ✓ | MATCH |
| Tap-to-toggle | ✓ | ✓ | ✓ | ✓ | MATCH |
| Hands-free / locked recording | ✓ | ~ | ✗ | ~ | MATCH |
| Lone-modifier trigger that preserves normal shortcuts | ✓ | ~ | ✓ | ~ | MATCH |
| Escape cancels without inserting | ✓ | ✓ | ✓ | ✓ | MATCH |
| Retry last failed transcription | ✓ | ~ | ~ | ? | MATCH |
| Paste last transcript again | ✓ | ✓ | ✓ | ✓ | MATCH |
| Floating recorder bar with waveform | ✓ | ✓ | ✓ | ✓ | MATCH |
| Live partial transcript in the overlay | ✓ | ~ | ✗ | ~ | BEAT — partials from streaming provider, shown inline |
| Draggable / hideable overlay | ✓ | ✓ | ~ | ✓ | MATCH |
| Microphone picker + live level test | ✓ | ✓ | ✓ | ✓ | MATCH |
| Language selection / auto-detect | ✓ | ✓ | ~ | ✓ | MATCH |
| Menu bar controls | ✓ | ✓ | ✓ | ✓ | MATCH |
| Sound feedback on start/stop | ✓ | ✓ | ✓ | ✓ | MATCH |

### Text quality

| Capability | W | V | B | S | Rant verdict |
|---|---|---|---|---|---|
| Filler-word removal | ✓ | ✓ | ✓ | ✓ | MATCH |
| Punctuation and capitalisation | ✓ | ✓ | ✓ | ✓ | MATCH |
| Spoken punctuation commands | ✓ | ✓ | ~ | ✓ | MATCH |
| Lists / paragraphs / new line | ✓ | ✓ | ~ | ✓ | MATCH |
| Mid-sentence self-correction ("actually, Wednesday") | ✓ | ~ | ✓ | ~ | MATCH |
| Selectable cleanup strength | ~ | ✓ | ~ | ✓ | BEAT — explicit None/Light/Medium/High, each documented and testable |
| Raw transcript retained alongside cleaned text | ✗ | ~ | ✗ | ~ | BEAT — both always stored, both visible, either can be pasted |
| Code / identifier casing preservation | ~ | ✓ | ~ | ~ | BEAT — dedicated developer context pass |

### Personalisation

| Capability | W | V | B | S | Rant verdict |
|---|---|---|---|---|---|
| Personal dictionary | ✓ | ✓ | ✓ | ✓ | MATCH |
| Spoken-form → written-form replacement | ✓ | ✓ | ~ | ✓ | MATCH |
| Automatically learned vocabulary | ✓ | ✗ | ✗ | ✗ | MATCH — opt-in, with an accept/reject review step |
| Learning from post-insert corrections | ~ | ✗ | ✗ | ✗ | BEAT — bounded observation window, user approves every rule |
| Text snippets expanded by voice | ✓ | ~ | ✓ | ~ | MATCH |
| Writing styles / tone | ✓ | ✓ | ✓ | ✓ | MATCH |
| Per-application style | ✓ | ✓ | ✗ | ✓ | MATCH |
| Per-website style | ~ | ✓ | ✗ | ~ | MATCH |
| Reusable Modes bundling provider+prompt+context+output | ✗ | ✓ | ✗ | ✓ | MATCH |
| Dictionary/snippet import & export | ~ | ~ | ✗ | ~ | BEAT — plain JSON in and out, no lock-in |

### Context

| Capability | W | V | B | S | Rant verdict |
|---|---|---|---|---|---|
| Frontmost app awareness | ✓ | ✓ | ✓ | ✓ | MATCH |
| Window title awareness | ~ | ✓ | ✓ | ✓ | MATCH |
| Browser URL / site classification | ✓ | ✓ | ✗ | ~ | MATCH |
| Focused field role/label | ~ | ~ | ✓ | ? | MATCH |
| Text before / after the cursor | ✓ | ✓ | ✓ | ~ | MATCH |
| Selected text as context | ✓ | ✓ | ~ | ✓ | MATCH |
| Clipboard as context | ✗ | ✓ | ✗ | ~ | MATCH — opt-in only |
| Screen OCR context | ✗ | ✓ | ✗ | ~ | MATCH — opt-in, never logged |
| IDE file / symbol awareness | ~ | ~ | ✗ | ✗ | BEAT — symbol harvesting + casing repair + `@file` references |
| Secure-field exclusion | ? | ? | ✓ | ? | BEAT — hard refusal, unit-tested, never overridable |
| Per-app exclusion list | ~ | ✓ | ✗ | ~ | MATCH |
| Global "context off" toggle | ✗ | ✗ | ✗ | ✗ | BEAT — one switch, plus "local context, never sent to cloud" |
| Secret redaction before any upload | ✗ | ✗ | ✗ | ✗ | BEAT — pattern-based redaction on the outbound path |

### Power features

| Capability | W | V | B | S | Rant verdict |
|---|---|---|---|---|---|
| Selected-text transforms | ✓ | ~ | ✗ | ~ | MATCH |
| Diff preview before replacing | ✓ | ✗ | ✗ | ✗ | MATCH |
| Custom transform prompts | ✓ | ✓ | ✗ | ✓ | MATCH |
| Command mode (voice instruction, not dictation) | ✓ | ✓ | ✗ | ~ | MATCH |
| Assistant / answer mode | ~ | ✓ | ✗ | ✓ | MATCH |
| Scratchpad notes | ✓ | ✗ | ✗ | ✗ | MATCH |
| Voice-to-action beyond text | ~ | ~ | ✗ | ~ | BEAT — registered capabilities with permission classes and confirmation |
| Local MCP server for coding agents | ✗ | ✗ | ✗ | ✗ | BEAT — opt-in, loopback, read-only default, audited |

### Meetings

| Capability | W | V | B | S | Rant verdict |
|---|---|---|---|---|---|
| Meeting recording without a bot joining | ✓ | ✗ | ✗ | ~ | MATCH |
| System audio capture | ✓ | ✗ | ✗ | ~ | MATCH |
| Live meeting transcript | ✓ | ✗ | ✗ | ~ | MATCH |
| Me vs others source labelling | ✓ | ✗ | ✗ | ~ | MATCH |
| Speaker diarisation | ✓ | ✗ | ✗ | ~ | MATCH — when the provider supports it |
| Summary / action items / decisions | ✓ | ✗ | ✗ | ~ | MATCH |
| Calendar awareness | ✓ | ✗ | ✗ | ✗ | MATCH — EventKit, local only, never uploaded |
| Meeting export MD/TXT/JSON/SRT/VTT | ~ | ✗ | ✗ | ~ | BEAT — five formats, no paywall |
| Local-first meeting summarisation | ✗ | ✗ | ✗ | ~ | BEAT — local model default, cloud only on explicit consent |

### Ownership, privacy, data

| Capability | W | V | B | S | Rant verdict |
|---|---|---|---|---|---|
| Transcript history | ✓ | ✓ | ✓ | ✓ | MATCH |
| Full-text history search | ✓ | ✓ | ~ | ✓ | MATCH |
| Delete a single item | ~ | ✓ | ✓ | ✓ | MATCH |
| Bulk delete / delete everything | ~ | ✓ | ~ | ✓ | BEAT — one obvious control, no support ticket |
| Word count / WPM / streak insights | ✓ | ✗ | ~ | ✗ | MATCH |
| App usage categorisation | ✓ | ✗ | ✗ | ✗ | MATCH |
| Provider latency visibility | ✗ | ~ | ✓ | ✗ | BEAT — per-stage latency in diagnostics |
| Works with no account | ✗ | ✓ | ✓ | ✓ | MATCH |
| No subscription required | ✗ | ✗ | ✓ | ✗ | MATCH |
| Open source | ✗ | ✓ (GPL) | ✓ | ✗ | MATCH — MIT |
| Bring-your-own API key | ✗ | ✓ | ✓ | ✓ | MATCH |
| Fully offline / local transcription | ✗ | ✓ | ✗ | ✓ | MATCH — `AppleSpeechProvider`, pinned on device, no key and no download. Verified with real speech via `scripts/local-speech-smoke.sh`. **This row was previously a false MATCH:** the local provider had no working backend until the completeness audit — see `docs/FINAL_AUDIT.md`. |
| Provider choice at runtime | ✗ | ✓ | ✗ | ✓ | MATCH — both engines listed from `ProviderRegistry`, and the selection is honoured. **Also previously false:** the picker offered one option and the code ignored it. |
| Audio retention policy control | ~ | ~ | ✗ | ~ | BEAT — never / 24h / 7d / 30d / forever, with a real cleanup job |
| Portable export archive | ✗ | ~ | ✗ | ~ | BEAT — versioned Rant Archive, documented, re-importable |
| Import from competitors | ✗ | ✗ | ✗ | ✗ | BEAT — Migration Center with per-source adapters, dry run, idempotent |
| No telemetry by default | ✗ | ✓ | ✓ | ~ | MATCH |
| Documented network behaviour | ✗ | ~ | ~ | ✗ | BEAT — `docs/NETWORK_BEHAVIOR.md` lists every request the app can make |
| Published threat model | ✗ | ✗ | ✗ | ✗ | BEAT — `docs/THREAT_MODEL.md` |

### Platform / distribution

| Capability | W | V | B | S | Rant verdict |
|---|---|---|---|---|---|
| Native macOS (no Electron) | ✓ | ✓ | ✓ | ✓ | MATCH |
| Windows client | ✓ | ✗ | ✗ | ✗ | INTENTIONALLY_SKIP — Rant is a macOS-first project; the engine is a portable Swift package, so a port stays possible, but shipping Windows now would halve the quality of the macOS behaviour that is the whole point. |
| iOS / Android client | ✓ | ✗ | ✗ | ✗ | INTENTIONALLY_SKIP — mobile keyboards cannot do system-wide injection the way macOS Accessibility can; a phone app would be a different product. Revisit after 1.0. |
| Team / enterprise administration | ✓ | ✗ | ✗ | ✗ | INTENTIONALLY_SKIP — Rant has no server and no account, which is the point. Fleet management implies both. |
| SOC 2 / HIPAA / ISO certification | ✓ | ✗ | ✗ | ✗ | INTENTIONALLY_SKIP — certifications attest to a vendor's server operations. Rant has no server; the equivalent assurance here is auditable source plus a published threat model. |
| Cloud sync across devices | ✓ | ✗ | ✗ | ~ | INTENTIONALLY_SKIP for 1.0 — would require either an account or a user-supplied sync backend. Rant Archive export covers device migration meanwhile. |
| Hosted account & subscription | ✓ | ~ | ✗ | ✓ | INTENTIONALLY_SKIP — deliberate anti-feature. |
| Auto-update | ✓ | ✓ | ✓ | ✓ | INTENTIONALLY_SKIP until signing identity exists — an updater that cannot verify signatures is worse than none. Tracked for post-1.0. |
| Notarised distribution | ✓ | ✓ | ✓ | ✓ | INTENTIONALLY_SKIP until a Developer ID certificate is available; ad-hoc signed local builds ship meanwhile and the gap is documented. |

## What Rant does that none of them do

1. **Migration Center** — bring history, dictionary and snippets in from Wispr Flow,
   VoiceInk, Superwhisper, Otter and generic transcript formats. Dry-run preview,
   deterministic dedupe hashes, never mutates the source.
2. **Local MCP server** — Claude Code and other agents can query your own dictation
   and meeting history, with per-collection consent and an audit log.
3. **Published threat model and network inventory** — every outbound request the app
   can make is enumerated in the repository.
4. **Symmetric data ownership** — the same archive format is used for export and
   import, so leaving Rant is a supported operation rather than an obstacle.
5. **Redaction on the outbound context path** — context that would leave the device
   is scanned for credential-shaped strings first.
