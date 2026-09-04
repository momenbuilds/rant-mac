<div align="center">

<img src="docs/assets/icon.png" width="120" alt="Rant">

# Rant

**talk messy. write clean.**

A native, local-first voice input system for macOS.
Hold a key, say what you mean — filler words, false starts, mid-sentence corrections and all —
let go, and clean text lands at your cursor in whatever app you were already using.

<img src="docs/assets/recorder.gif" width="480" alt="The Rant recorder listening, transcribing and inserting">

[Install](#install) · [Why](#why-another-dictation-app) · [Privacy](#privacy-in-one-paragraph) · [Docs](#documentation)

</div>

---

> **Status: pre-1.0, but real.** 762 tests, a green `scripts/check.sh`, and it has been
> transcribing actual speech since day one. `TASKS.md` says exactly what is done;
> `PROGRESS.md` says what is not. Nothing below describes a feature that is not
> tracked as a task.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/momenbuilds/rant-mac/main/scripts/install.sh | bash
```

That clones, builds a universal binary, installs it to `/Applications`, and launches it.
It takes a couple of minutes the first time.

<details>
<summary>Or build it yourself</summary>

```bash
git clone https://github.com/momenbuilds/rant-mac && cd rant-mac
bash scripts/bootstrap.sh          # checks the toolchain
CONFIG=Release bash scripts/dev-build.sh
```

**Requirements:** macOS 14.4+, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). Apple Silicon and Intel both work — cloud speech is identical
on either, local models are much faster on Apple Silicon.
</details>

<details>
<summary>Why there is no notarised download</summary>

Rant is ad-hoc signed because there is no Apple Developer ID certificate behind it.
A downloaded ad-hoc build is refused by Gatekeeper on any Mac but the one that built
it — and telling you to right-click → Open, or to run `xattr -d com.apple.quarantine`,
is teaching a habit that will eventually get you hurt. So the install script builds
locally instead, which needs none of that.

`docs/PACKAGING.md` lists exactly what is missing and what changes the day a
certificate exists.
</details>

### First run

1. **Microphone** and **Accessibility** — Rant explains what each is for before asking,
   and every step can be skipped.
2. **A speech engine** — paste your own AssemblyAI key, or choose *Local only* and stay
   entirely offline.
3. **Hold your key and talk.**

> If Accessibility looks switched on but Rant says it is not, macOS is holding an
> entry for an older build — that happens whenever an ad-hoc-signed app is rebuilt.
> Run `tccutil reset Accessibility dev.rant.mac.dev` and grant it again. Rant detects
> this and shows you the command with a copy button.

## Why another dictation app

The good ones are proprietary and rent-seeking; the open ones are missing half the
product. Rant is trying to be the one you would still choose if the paid alternatives
were free.

| | |
|---|---|
| **Native** | Swift, SwiftUI and AppKit. Not Electron wearing a traffic-light hat. |
| **Local-first** | Everything you say, everything you keep, and everything Rant learns lives in one folder on your Mac. |
| **Bring your own key** | AssemblyAI by default, on your account, held in the Keychain. |
| **Genuinely offline** | A local speech provider, and a *local only* mode with no silent cloud fallback. |
| **Yours to leave** | Export a portable archive any time — and import your history *in* from Wispr Flow, VoiceInk, Superwhisper or Otter. |

## What it does

|  |  |
|---|---|
| **Dictate anywhere** | Push-to-talk, tap-to-toggle, or hands-free. Escape cancels. A lone modifier triggers it without stealing ⌘C. |
| **Clean text** | Four cleanup levels. The first three are deterministic Swift — instant, free, and identical offline. "Send it Tuesday, actually Wednesday" becomes "Send it Wednesday." |
| **Context aware** | Knows the app, the window, the site and the field you are typing in, and writes to suit. |
| **Developer aware** | Preserves `camelCase`, recognises symbols from your editor, understands `@main.swift`. Terminal mode does *no* cleanup, because a helpfully added full stop breaks a command. |
| **Your vocabulary** | Personal dictionary, spoken-form replacements, voice-triggered snippets — applied to the very next dictation. |
| **Transforms** | Select text anywhere, press a key, polish / shorten / bullet / translate it — with a real word-level diff before it commits. |
| **Notetaker** | Records meetings locally with system audio. Live transcript, summary, action items, five export formats. No bot joins your call. |
| **History & insights** | Every dictation searchable locally. Words, WPM, streaks. Delete one item or all of them, obviously and immediately. |
| **Local MCP server** | Opt-in, loopback-only, read-only by default. Lets Claude Code and other agents search your own dictation history. |
| **Migration Center** | Adapters for four competitors and seven generic formats. Dry-run preview, never touches the source, idempotent. |

## Privacy in one paragraph

With no API key configured, **Rant makes no network requests at all** — no analytics
SDK and no crash-reporting SDK is linked into the binary. With AssemblyAI selected,
your audio and a small, redacted slice of context go to AssemblyAI and nowhere else.
With the local provider, nothing leaves your Mac. Audio is not retained unless you ask
for it. Password fields are never read from or typed into, and there is no setting to
change that. Every request the app can make is enumerated in
[`docs/NETWORK_BEHAVIOR.md`](docs/NETWORK_BEHAVIOR.md), and `scripts/check.sh` fails the
build if a host appears in the source that is not in that document.

## Built to be checked, not trusted

```bash
bash scripts/check.sh       # the definition of green — CI runs this exact script
bash scripts/status.sh      # what is done and what is next
bash scripts/smoke-test.sh  # the manual matrix, for what cannot be honestly automated
```

762 unit tests and 9 UI tests. Warnings are treated as failures. A check that cannot
run prints `SKIP` and is reported as a skip — never counted as a pass. Global text
injection is the one thing deliberately left manual, because it needs real permissions
and real applications, and a flaky test guarding something important is worse than an
honest checklist.

Some of what those tests caught before it shipped: a regex that **hung the app** on
long dictations, spoken punctuation taking **4.1 seconds** per dictation, a streaming
session that **billed until timeout** when cancelled mid-handshake, and audio retention
deleting files in a sibling directory via a `hasPrefix` check.

## Documentation

| | |
|---|---|
| [Architecture](docs/ARCHITECTURE.md) | how the engine and the shell fit together |
| [Decisions](docs/DECISIONS.md) | why it is built this way, including the trade-offs |
| [Competitor audit](docs/COMPETITOR_AUDIT.md) | 107 capabilities, every one marked MATCH, BEAT or INTENTIONALLY_SKIP with a reason |
| [Comparison](docs/COMPARISON.md) | the short version, including what Rant gives up |
| [Privacy](PRIVACY.md) · [Network](docs/NETWORK_BEHAVIOR.md) · [Threat model](docs/THREAT_MODEL.md) | the claims, in checkable form |
| [Data model](docs/DATA_MODEL.md) | it is one SQLite file, and you can open it |
| [Performance](docs/PERFORMANCE.md) | the latency budget and the three design choices that exist only to protect it |
| [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) | how to help, how to report |

## Licence

MIT. See [`LICENSE`](LICENSE) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) —
in particular the note on why no VoiceInk code is present here, since Rant is MIT and
VoiceInk is GPLv3.
