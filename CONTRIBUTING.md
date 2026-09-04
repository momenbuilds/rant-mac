# Contributing to Rant

## The short version

```bash
git clone https://github.com/<you>/rant-mac && cd rant-mac
bash scripts/bootstrap.sh     # checks the toolchain
bash scripts/check.sh         # this is what "green" means
bash scripts/dev-build.sh     # builds and installs "Rant Dev.app", then launches it
```

`scripts/check.sh` is the definition of done. CI runs the same script. If a check
cannot run in your environment it prints `SKIP` — a skip is reported as a skip and
never counted as a pass.

The XCUITest suite is **opt-in**, because it drives the real cursor and takes the
machine over for a couple of minutes:

```bash
bash scripts/ui-test.sh              # just the UI tests
RUN_UI_TESTS=1 bash scripts/check.sh # everything, including them
```

## Ground rules

**Licence.** Rant is MIT. By contributing you agree your contribution is MIT.
Do not paste code from a GPL-licensed project — VoiceInk in particular. Reading
another project to understand *what* it does is fine; copying *how* it does it is
not. See `docs/DECISIONS.md` D-001.

**Logic goes in `RantCore`.** If it is worth a test, it does not belong in a
SwiftUI view. `RantCore` never imports SwiftUI.

**Every behaviour change needs a test.** Not "we added tests"; the specific
behaviour you changed, asserted. The seams are already there — nine protocols with
fakes in `Tests/RantCoreTests/Support`.

**Never weaken a refusal.** The ten guarantees in `SECURITY.md` are enforced by
tests. If you have a reason one should change, write a decision record in
`docs/DECISIONS.md` first and link it from the PR.

**No secrets.** Not in a test fixture, not in a comment, not in a commit that gets
amended later. CI checks for key-shaped strings.

**No new runtime dependencies** without a decision record. Rant currently links
nothing but Apple frameworks, and that is a feature.

## Working on a task

Work is tracked in `TASKS.md` with stable `RANT-NNN` ids.

- Mark the task `[~]` when you start.
- Run the task's `verify:` command before marking it `[x]`.
- Record the evidence in `PROGRESS.md`.
- New work gets a new task rather than growing an existing one.

`bash scripts/status.sh` prints where things stand.

## Permissions, and why they keep disappearing

If Accessibility seems to switch itself off after every build, you are on ad-hoc
signing. macOS binds a grant to the signature, and an ad-hoc signature is a hash of
the binary — so every build orphans it. `scripts/dev-build.sh` uses a real
certificate when the machine has one; `scripts/make-signing-identity.sh` makes a local
one when it does not. `docs/SETUP.md` has the detail.

## Testing things that touch the OS

Global hotkeys, Accessibility and text injection are keyed by macOS to the app
bundle's path and identity, so testing from a DerivedData build will make you think
permissions are broken when they are not. Always test those from the stable install:

```bash
bash scripts/dev-build.sh
```

Things that genuinely cannot be automated — does text land correctly in Xcode's
editor, in a terminal, in a browser contenteditable — live in `docs/SMOKE_TEST.md`
as a manual matrix. Please update `docs/APP_COMPATIBILITY.md` when you find an app
that misbehaves, including *how* it misbehaves.

## Commit style

Present tense, imperative, and say why in the body if the what is not obvious.
Reference the task id: `RANT-013: restore clipboard after the paste settles`.
