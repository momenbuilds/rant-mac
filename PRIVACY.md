# Privacy

Rant is local-first. This page is the short version; `docs/NETWORK_BEHAVIOR.md` is
the exhaustive one and `docs/THREAT_MODEL.md` is the honest one.

- **No account.** There is nothing to sign up for. There is no Rant server.
- **No telemetry.** No analytics SDK and no crash-reporting SDK is linked into the
  binary. With no API key configured, Rant makes zero network requests.
- **Your keys stay in the Keychain.** Never in preferences, never in logs, never in
  a file, never in a commit.
- **Your data stays in one folder.** `~/Library/Application Support/Rant/`. Delete
  that folder and Rant knows nothing about you.
- **Audio is not retained by default.** If you turn retention on you choose 24 hours,
  7 days, 30 days or forever, and a cleanup job actually enforces it.
- **Cloud is a choice.** Pick the local speech provider and nothing you say leaves
  the machine. Pick "local only" and there is no silent fallback.
- **Context is minimised.** Rant can read the app you are in, the window title, the
  site, the field you are typing into and the text around your cursor — but only the
  sources you switch on, only locally, and only a small subset is ever allowed onto
  the network. Credential-shaped strings are redacted before anything is sent.
- **Password fields are off limits.** Rant will not read from or type into a secure
  text field, and there is no setting to change that.
- **You can leave.** Export a Rant Archive at any time: your transcripts, meetings,
  dictionary, snippets, styles and notes in documented, re-importable formats.

## What each macOS permission is for

| Permission | Why | If you deny it |
|---|---|---|
| Microphone | to hear you | dictation cannot work |
| Accessibility | to know which field you are typing in and to insert text there | Rant falls back to the clipboard, less reliably |
| Screen Recording | only for meeting system-audio capture and optional OCR context | dictation is unaffected; the notetaker cannot hear other people |
| Calendar | only to show upcoming meetings and offer to start the notetaker | the notetaker still works, started manually |

Rant asks for each one at the moment it first needs it, explains why in the same
breath, and never asks again if you say no.
