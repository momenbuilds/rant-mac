# Manual smoke test

Some things cannot be honestly automated. Whether text lands correctly in Xcode's
editor, whether your clipboard survives a paste into Slack, whether the overlay
appears above a full-screen window — these need a person, a real microphone, and real
applications.

This is that checklist. Run it before a release, and after any change to the injector,
the event tap, or the overlay.

```bash
bash scripts/smoke-test.sh      # walks through it and records results
```

## Before you start

- [ ] `bash scripts/check.sh` is green
- [ ] `bash scripts/dev-build.sh` installed a fresh build to `/Applications/Rant Dev.app`
- [ ] Microphone and Accessibility are granted **to that bundle**
- [ ] An AssemblyAI key is saved, or the local model is downloaded

## 1. Permissions and onboarding

- [ ] A first run (`defaults delete dev.rant.mac.dev`) shows onboarding
- [ ] Each permission step explains *why* before asking
- [ ] Denying a permission still lets you continue — you are never trapped
- [ ] "Open System Settings" lands on the correct pane, not the top level
- [ ] After granting, the step updates without a restart

## 2. The core loop

In **TextEdit**:

- [ ] Hold the trigger key — the overlay appears in well under a second
- [ ] The waveform responds to your voice
- [ ] Release — text is inserted at the cursor
- [ ] The text is cleaned: no "um", sentences capitalised, a full stop at the end
- [ ] Say "send it Tuesday, actually Wednesday" → "Send it Wednesday."
- [ ] Dictate into the middle of an existing sentence — spacing and casing are right
- [ ] Dictate at the start of an empty document — no leading space

## 3. Activation modes

- [ ] Hold and release = push-to-talk
- [ ] Quick tap starts a toggle; a second tap stops it
- [ ] Double-tap = hands-free; it keeps recording after you let go
- [ ] Escape during recording cancels and inserts nothing
- [ ] Escape *after* release but before the text arrives also cancels
- [ ] **⌘C still copies.** ⌘V, ⌘Tab, ⌘Q all behave normally
- [ ] Holding the trigger and pressing another key does not start a dictation

## 4. Insertion targets

For each: dictate a sentence, confirm it lands, confirm your clipboard survives.
Record results in `docs/APP_COMPATIBILITY.md`.

- [ ] TextEdit
- [ ] Notes
- [ ] Safari — a plain input
- [ ] Safari or Chrome — a rich editor (Gmail compose)
- [ ] Terminal — confirm **no trailing full stop** on a command
- [ ] Xcode — confirm `camelCase` identifiers survive
- [ ] VS Code or Cursor
- [ ] Slack or Discord — confirm it does not send the message on paste

## 5. Clipboard contract

- [ ] Copy something distinctive, dictate into an Electron app, press ⌘V — you get
      your original clipboard back, not the transcript
- [ ] Copy something *during* a dictation — your newer copy wins, Rant does not
      clobber it

## 6. Failure and recovery

- [ ] Turn off Wi-Fi, dictate → a clear error, offered as retryable
- [ ] Turn Wi-Fi back on, press Retry → the *same* recording transcribes, you did not
      have to say it again
- [ ] Enter a wrong API key → "that key was rejected", **not** offered as retryable
- [ ] Quit the target app mid-dictation → the text ends up on your clipboard with an
      explanation, not lost
- [ ] Record silence → nothing is inserted and no request is spent

## 7. Privacy

- [ ] With no API key configured, Little Snitch (or `nettop`) shows **no** outbound
      traffic from Rant
- [ ] Turn on "Local only" and select a cloud provider → refused with an explanation,
      no audio captured
- [ ] Focus a password field and try to dictate → refused
- [ ] `log show --predicate 'subsystem == "dev.rant.mac"' --last 10m` shows **no**
      transcript text
- [ ] Settings → Privacy → "Delete all local data" empties history *and* Insights

## 8. Overlay

- [ ] Appears above a full-screen app
- [ ] Does **not** steal focus — the text field you were in keeps its caret
- [ ] Draggable, and remembers where you put it across a relaunch
- [ ] With System Settings → Accessibility → Reduce Motion on: the pulse is replaced
      by a static ring, nothing animates

## 9. Menu bar

- [ ] Start/Stop works from the menu
- [ ] Paste Last Transcript re-inserts the previous text
- [ ] Cleanup level changes from the menu apply to the next dictation
- [ ] Quit actually quits

## Recording results

Note the build (`git rev-parse --short HEAD`), macOS version, and machine
architecture. An issue that only reproduces on Intel or only on Apple Silicon is worth
knowing about.
