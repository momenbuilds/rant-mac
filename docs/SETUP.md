# Finishing setup

Rant is installed and configured. macOS requires three approvals that no application
can grant itself — deliberately, because an app that could grant itself Accessibility
could silently log every key you press. Each is one click.

## 1 · Accessibility

**System Settings → Privacy & Security → Accessibility → switch on "Rant Dev".**

Rant registers itself in that list on launch, so there is a row waiting rather than a
`+` button to hunt for. This is what lets Rant see which text field you are in, put
text there, and notice your dictation key anywhere on the system.

Rant polls for it, so the moment you flip the switch the keyboard listener installs.
No relaunch.

## 2 · Microphone

Rant asks the first time you dictate. Click **Allow**.

## 3 · The Keychain prompt

You will see *"Rant Dev wants to use your confidential information stored in
dev.rant.mac"*. Click **Always Allow**.

This happens because the app is ad-hoc signed — the old file keychain binds an item to
one exact binary, and every rebuild produces a different one. On that first successful
read, Rant moves your key to the **data-protection keychain**, which has no per-binary
list. You will not be asked again.

## Then

Hold **Fn / 🌐** and talk. Let go and the text lands where your cursor already was.

- **Escape** cancels without inserting anything.
- **Double-tap** to keep recording hands-free.
- The trigger key is in Settings → General if you want something else.

## If the switch is on and Rant still says it is not

That means macOS is holding an entry for an older build. It happens whenever an
ad-hoc-signed app is rebuilt, because the grant is bound to the signature rather than
to the app's name.

```bash
tccutil reset Accessibility dev.rant.mac.dev
```

Then reopen Rant and grant it again. `scripts/dev-build.sh` now does this for you
after every build, so the app is never left showing a switch that points at a binary
which no longer exists.

## What is actually happening, if you want to check

```bash
tail -f ~/Library/Application\ Support/Rant/rant.log
```

Lifecycle only — never transcript text. `event tap installed, listening for fnGlobe`
is the line that means the dictation key is live.
