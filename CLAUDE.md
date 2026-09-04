# CLAUDE.md — working agreement for Rant

Rant is a native, local-first macOS voice input system. MIT licensed.
Working name **Rant** · tagline *talk messy. write clean.*

## Start of every session

1. Read `TASKS.md` and `PROGRESS.md`.
2. Resume the task marked `[~]`. If none is active, pick the first `[ ]` whose
   dependencies are satisfied and mark it `[~]`.
3. Run `bash scripts/status.sh` to confirm where things stand.

## Non-negotiable rules

- **No work outside a task.** If new work appears, add a task with a stable
  `RANT-NNN` id rather than silently expanding scope.
- **Never mark a task `[x]` without running its `verify:` command** and recording
  the evidence (test name, build command, output line) in `PROGRESS.md`.
- **A skipped check is reported as skipped**, never as a pass. `scripts/check.sh`
  prints `SKIP` lines and they must survive into the summary.
- **Never claim "production ready"** without linking the evidence.
- **Secrets**: API keys live in the macOS Keychain only. Never in `UserDefaults`,
  never in logs, never in a source file, never in a commit, never in a crash report.
- **Never log transcript or context bodies** at default log level. Use the
  redaction helpers in `RantCore/Security`.
- **Licence boundary**: VoiceInk is GPLv3. You may read it to understand product
  behaviour and platform technique. You must not copy or mechanically translate
  its source into this MIT codebase. Blurt is MIT — attribution required for any
  reused code, recorded in `THIRD_PARTY_NOTICES.md`.
- **No Electron / Tauri / React Native / embedded web UI.** Swift + SwiftUI +
  AppKit only.
- **No analytics, no crash SDK, no account.**
- **No destructive git** (`push --force`, `reset --hard` on shared state,
  branch deletion) without explicit need and a stated reason.
- Keep `docs/ARCHITECTURE.md` and `docs/DATA_MODEL.md` in sync with the code.

## Layout

- `Sources/RantCore/…` — the reusable engine. No SwiftUI. Testable.
- `App/Rant/…` — the thin app shell. SwiftUI + AppKit.
- `Tests/RantCoreTests/…` — unit and integration tests against protocol seams.
- `docs/…` — audit, architecture, decisions, privacy, threat model, compatibility.
- `scripts/…` — `status.sh`, `check.sh`, `dev-build.sh`, `smoke-test.sh`.

## Definition of green

`bash scripts/check.sh` — formatting, build with warnings surfaced, unit tests,
migration tests, integration tests, app build. CI runs the same script.

## Development install

Always test global hotkeys / Accessibility / injection from the **stable install
path**, not a DerivedData bundle — macOS TCC grants are keyed to bundle path and
identity, and a moving path silently loses permissions.

```
bash scripts/dev-build.sh     # builds, signs ad-hoc, installs "Rant Dev.app", launches it
```
