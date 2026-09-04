# Finishing setup

Rant is installed and configured. macOS requires three approvals that no application
can grant itself — deliberately, because an app that could grant itself Accessibility
could silently log every key you press. There is no way around this: the database is
protected by System Integrity Protection, so it is unwritable even as root, and
`tccutil` can only reset a grant, never create one. Each approval is one click, and
with a stable signing identity (below) you only give it once.

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

## Granting it once, not once per build

macOS does not bind a permission to an application's *name*. It binds it to the
application's **designated requirement** — a description of the signature. For an
ad-hoc signed build that requirement is `cdhash H"..."`, a hash of the binary, so it
is a different value after every single build. The consequence is brutal and not
obvious: every rebuild silently orphans every permission, and System Settings goes on
showing a switch that is on and points at a binary that no longer exists.

`scripts/dev-build.sh` therefore signs with a real certificate whenever the machine
has one — Developer ID, Apple Development, or Mac Developer, in that order. The
requirement then becomes:

```
identifier "dev.rant.mac.dev" and anchor apple generic and
certificate leaf[subject.CN] = "Apple Development: ..."
```

which is identical across builds, so grants survive. You can check yours:

```bash
codesign -d -r- "/Applications/Rant Dev.app" | grep designated
```

If it says `cdhash`, you are on ad-hoc signing and will be re-granting after every
build. Anything else and you grant once.

**No certificate at all?** `bash scripts/make-signing-identity.sh` creates a local
self-signed one. It is not a Developer ID and cannot be distributed — see
`docs/PACKAGING.md` — it exists purely so your machine stops asking.

## If the switch is on and Rant still says it is not

That is the stale-requirement problem above: an entry from a previous build.

```bash
tccutil reset Accessibility dev.rant.mac.dev
```

Then reopen Rant and grant it once more. With a stable signing identity it is the
last time.

## What is actually happening, if you want to check

```bash
tail -f ~/Library/Application\ Support/Rant/rant.log
```

Lifecycle only — never transcript text. `event tap installed, listening for fnGlobe`
is the line that means the dictation key is live.
