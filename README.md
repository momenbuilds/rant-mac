<h1>Rant</h1>

**talk messy. write clean.**

A native, local-first voice input system for macOS. Hold a key, say what you mean —
filler words, false starts, mid-sentence corrections and all — let go, and clean
text lands at your cursor in whatever app you were already using.

Your keys, your Mac, your data. MIT licensed. No account, no subscription, no
telemetry.

> **Status: pre-1.0, in active development.** See `TASKS.md` for exactly what works
> today and `PROGRESS.md` for the current build state. Nothing in this README
> describes a feature that is not tracked as a task.

## Why another dictation app

The good ones are proprietary and rent-seeking; the open ones are missing half the
product. Rant is trying to be the one you would still choose if the paid
alternatives were free:

- **Native.** Swift, SwiftUI and AppKit. Not Electron wearing a traffic-light hat.
- **Local-first.** Everything you say, everything you keep, and everything Rant
  learns lives in one folder on your Mac.
- **Bring your own key.** AssemblyAI by default. It is your account and your key,
  held in the Keychain.
- **Genuinely offline when you want it.** A local speech provider that keeps audio
  on the machine, and a "local only" mode with no silent cloud fallback.
- **Yours to leave.** Export a portable archive of everything, any time. And import
  your history *in* from Wispr Flow, VoiceInk, Superwhisper or Otter — the Migration
  Center is a first-class feature, not an afterthought.

## What it does

| | |
|---|---|
| **Dictate anywhere** | Push-to-talk, tap-to-toggle, or hands-free. Escape cancels. |
| **Clean text** | Four cleanup levels. Punctuation, filler removal, lists, and self-corrections resolved — "send it Tuesday, actually Wednesday" becomes "Send it Wednesday." |
| **Context aware** | Knows the app, the window, the site and the field you are typing in, and writes to suit. |
| **Developer aware** | Preserves `camelCase`, recognises symbols from your editor, and understands `@main.swift`. |
| **Your vocabulary** | Personal dictionary, spoken-form replacements, and voice-triggered snippets. |
| **Transforms** | Select text anywhere, press a key, polish / shorten / bullet / translate it — with a diff before it commits. |
| **Notetaker** | Records meetings locally with system audio. Live transcript, summary, action items, five export formats. No bot joins your call. |
| **History and insights** | Every dictation searchable locally. Words, WPM, streaks. Delete one item or all of them, obviously and immediately. |
| **Local MCP server** | Opt-in, loopback-only. Lets Claude Code and other agents search your own dictation history. |

## Requirements

- macOS 14.4 or later
- Apple Silicon or Intel — cloud speech works on both; local models are much faster
  on Apple Silicon
- An AssemblyAI API key for cloud speech, or a downloaded local model for offline

## Install from source

```bash
git clone https://github.com/<you>/rant-mac && cd rant-mac
bash scripts/dev-build.sh
```

That builds Rant, signs it for local use, installs it as `Rant Dev.app`, and
launches it. Onboarding walks through the permissions and explains why each one is
needed. Install to the stable path rather than running from a build directory —
macOS ties Accessibility grants to the bundle's location.

## Privacy in one paragraph

With no API key configured, Rant makes no network requests at all. With AssemblyAI
selected, your audio and a small, redacted slice of context go to AssemblyAI and
nowhere else. With the local provider selected, nothing leaves your Mac. Audio is
not retained unless you ask for it. Password fields are never read from or typed
into. Every request the app can make is enumerated in
[`docs/NETWORK_BEHAVIOR.md`](docs/NETWORK_BEHAVIOR.md); what we do and do not
defend against is in [`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md).

## Documentation

| | |
|---|---|
| [Architecture](docs/ARCHITECTURE.md) | how the engine and the shell fit together |
| [Decisions](docs/DECISIONS.md) | why it is built this way, including the trade-offs |
| [Competitor audit](docs/COMPETITOR_AUDIT.md) | what the alternatives do, and what Rant matches, beats or deliberately skips |
| [Privacy](PRIVACY.md) · [Network](docs/NETWORK_BEHAVIOR.md) · [Threats](docs/THREAT_MODEL.md) | the claims, in checkable form |
| [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) | how to help, how to report |

## Licence

MIT. See [`LICENSE`](LICENSE) and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)
— in particular the note on why no VoiceInk code is present here.
