# Rant Tasks

Statuses: `[ ]` not started · `[~]` active · `[x]` done (verified) · `[!]` blocked

Rules: no substantial work happens outside a task. Mark active before starting.
Run the task's `verify:` command before marking `[x]`, and record evidence.

---

## Phase A — Research & Foundation

- [x] RANT-001 — Repository bootstrap (git, MIT license, gitignore, doc skeleton)
  - depends:
  - acceptance: repo initialised, LICENSE + .gitignore present, docs/ scripts/ exist
  - verify: `test -f LICENSE && test -d docs && git rev-parse --git-dir`
  - notes: MIT. Working name Rant. Repo `rant-mac`.

- [x] RANT-002 — Task tracking system (TASKS.md, PROGRESS.md, DECISIONS.md, CLAUDE.md, status.sh)
  - depends: RANT-001
  - acceptance: all tracking files exist and scripts/status.sh runs
  - verify: `bash scripts/status.sh`

- [x] RANT-003 — Competitor audit
  - depends: RANT-001
  - acceptance: docs/COMPETITOR_AUDIT.md with a full capability matrix; every capability
    marked MATCH / BEAT / INTENTIONALLY_SKIP(reason)
  - verify: `bash scripts/check-audit.sh`
  - notes: Wispr Flow, VoiceInk (GPLv3 — inspect only), Blurt (MIT), Superwhisper, others.

- [x] RANT-004 — Architecture + decision records
  - depends: RANT-003
  - acceptance: docs/ARCHITECTURE.md, docs/DECISIONS.md, docs/DATA_MODEL.md,
    docs/NETWORK_BEHAVIOR.md, docs/THREAT_MODEL.md
  - verify: `ls docs/ARCHITECTURE.md docs/DECISIONS.md docs/DATA_MODEL.md docs/NETWORK_BEHAVIOR.md docs/THREAT_MODEL.md`

- [x] RANT-005 — SwiftPM package scaffolding (RantCore + tests)
  - depends: RANT-004
  - acceptance: `swift build` succeeds; `swift test` runs
  - verify: `swift build && swift test`

- [x] RANT-006 — Logging + redaction subsystem
  - depends: RANT-005
  - acceptance: os.Logger wrapper; transcript/context bodies never logged at default level
  - verify: `swift test --filter RedactionTests`

- [x] RANT-007 — Keychain secret storage
  - depends: RANT-005
  - acceptance: store/read/delete API keys in Keychain; never UserDefaults; no logging
  - verify: `swift test --filter SecretStoreTests`

- [x] RANT-008 — SQLite storage layer with versioned migrations + FTS5
  - depends: RANT-005
  - acceptance: schema v1..vN applied in order; migration tests; WAL; FTS5 search
  - verify: `swift test --filter StoreTests`

- [x] RANT-009 — Permissions manager (mic, accessibility, screen recording)
  - depends: RANT-005
  - acceptance: status query + deep links to the correct System Settings panes
  - verify: `swift test --filter PermissionsTests`

## Phase B — Killer core loop  (must work end to end)

- [x] RANT-010 — Global hotkey engine + state machine
  - depends: RANT-009
  - acceptance: push-to-talk, tap-toggle, double-tap hands-free, cancel, lone-modifier
    handling that does not break normal shortcuts
  - verify: `swift test --filter HotkeyStateMachineTests`

- [x] RANT-011 — Audio capture pipeline (AVAudioEngine, 16 kHz mono PCM, level meter)
  - depends: RANT-005
  - acceptance: capture starts <150 ms, ring buffer prevents first-syllable loss
  - verify: `swift test --filter AudioTests`

- [x] RANT-012 — AssemblyAI streaming provider (BYOK)
  - depends: RANT-007, RANT-011
  - acceptance: v3 streaming URL/auth/message construction unit-tested against fixtures;
    reconnect/backoff; cancellation; key-terms priming
  - verify: `swift test --filter AssemblyAITests`

- [x] RANT-013 — Text injection (AX-first, clipboard+Cmd-V fallback, clipboard restore)
  - depends: RANT-009
  - acceptance: secure-field refusal, spacing rules, clipboard save/restore, failure keeps
    text on clipboard and notifies
  - verify: `swift test --filter InjectionTests`

- [x] RANT-014 — Recording overlay (original design, waveform, live partials, states)
  - depends: RANT-010, RANT-011
  - acceptance: NSPanel non-activating overlay, all states, drag position, Reduce Motion
  - verify: app build + manual smoke

- [x] RANT-015 — Dictation session orchestrator (hotkey→audio→STT→enhance→inject)
  - depends: RANT-012, RANT-013, RANT-014
  - acceptance: full pipeline with mock STT in tests; latency stages recorded
  - verify: `swift test --filter SessionTests`

- [x] RANT-016 — App shell, menu bar, XcodeGen project
  - depends: RANT-014
  - acceptance: `xcodegen` regenerates project; app builds; menu bar item with actions
  - verify: `bash scripts/build-app.sh`

- [x] RANT-017 — Onboarding + Settings (permissions, mic pick, hotkey, API key, privacy)
  - depends: RANT-016, RANT-007
  - acceptance: key saved to Keychain, test-connection button, per-pane deep links
  - verify: app build + `swift test --filter OnboardingTests`

- [x] RANT-018 — Stable dev install (`/Applications/Rant Dev.app`) + scripts
  - depends: RANT-016
  - acceptance: scripts/dev-build.sh installs to a stable path with stable bundle ID
  - verify: `bash scripts/dev-build.sh`

- [x] RANT-019 — Error handling: retry, paste-last, offline state, cancel
  - depends: RANT-015
  - acceptance: failed transcription recoverable; last transcript re-pasteable
  - verify: `swift test --filter RecoveryTests`

## Phase C — Intelligence

- [x] RANT-020 — Context engine (app/window/URL/field/selection/before-after text)
  - verify: `swift test --filter ContextTests`
- [x] RANT-021 — Cleanup levels (None/Light/Medium/High) + spoken punctuation + backtracking
  - verify: `swift test --filter CleanupTests`
- [x] RANT-022 — Enhancement providers (Apple FM, Ollama/OpenAI-compatible, none)
  - verify: `swift test --filter EnhancementTests`
- [x] RANT-023 — Personal dictionary (boosts, replacements, casing, import/export)
  - verify: `swift test --filter DictionaryTests`
- [x] RANT-024 — Snippets (voice triggers, expansion inside longer dictation)
  - verify: `swift test --filter SnippetTests`
- [x] RANT-025 — Styles + app/domain category classification
  - verify: `swift test --filter StyleTests`
- [x] RANT-026 — Modes (provider/prompt/context/output/triggers)
  - verify: `swift test --filter ModeTests`
- [ ] RANT-027 — Adaptive learning from corrections (opt-in)
  - verify: `swift test --filter LearningTests`

## Phase D — Ownership

- [x] RANT-030 — Transcript history + FTS search + per-item deletion
  - verify: `swift test --filter HistoryTests`
- [x] RANT-031 — Insights (words, WPM, streak, categories, latency)
  - verify: `swift test --filter InsightsTests`
- [x] RANT-032 — Rant Archive export/import (portable, versioned)
  - verify: `swift test --filter ArchiveTests`
- [x] RANT-033 — Migration Center + adapters (Wispr, VoiceInk, Superwhisper, Otter, TXT/MD/JSON/CSV/SRT/VTT)
  - verify: `swift test --filter MigrationTests`
- [x] RANT-034 — Audio retention policy + cleanup job
  - verify: `swift test --filter RetentionTests`

## Phase E — Power

- [x] RANT-040 — Selected-text transforms + diff preview
  - verify: `swift test --filter TransformTests`
- [x] RANT-041 — Command mode (constrained action model, preview/undo)
  - verify: `swift test --filter CommandModeTests`
- [x] RANT-042 — Developer context (IDE symbols, casing, @file references)
  - verify: `swift test --filter DeveloperContextTests`
- [x] RANT-043 — Scratchpad (local Markdown notes, voice append)
  - verify: `swift test --filter ScratchpadTests`
- [x] RANT-044 — Local MCP server (opt-in, loopback, read-only default, audit log)
  - verify: `swift test --filter MCPTests`
- [ ] RANT-069 — MCP loopback socket listener + stdio wiring in the app shell
  - depends: RANT-044
  - acceptance: the validated `MCPBindAddress` seam is actually bound; `claude mcp add` can reach it
  - verify: `swift test --filter MCPTransportTests`
  - notes: RANT-044 shipped the protocol and a line transport only. The listener is
    deliberately separate so the protocol could be tested without sockets.

- [~] RANT-045 — Actions layer (registered capabilities, permission classes, confirmation)
  - verify: `swift test --filter ActionsTests`
- [ ] RANT-046 — Local semantic search (embeddings, opt-in)
  - verify: `swift test --filter SemanticSearchTests`

## Phase F — Notetaker

- [x] RANT-050 — Meeting capture (mic + system audio via ScreenCaptureKit)
  - verify: `swift test --filter MeetingCaptureTests`
- [x] RANT-051 — Live meeting transcript + source labels + meeting state machine
  - verify: `swift test --filter MeetingTests`
- [x] RANT-052 — Summaries, action items, decisions, key moments
  - verify: `swift test --filter SummaryTests`
- [x] RANT-053 — Meeting exports (MD/TXT/JSON/SRT/VTT)
  - verify: `swift test --filter MeetingExportTests`
- [x] RANT-054 — Calendar (EventKit, local only, join links)
  - verify: `swift test --filter CalendarTests`

## Phase G — Hardening

- [x] RANT-060 — scripts/check.sh as the definition of green
  - verify: `bash scripts/check.sh`
- [x] RANT-061 — CI workflow (build, unit tests, lint)
  - verify: workflow file present + `swift build` locally
- [x] RANT-062 — Local STT provider (whisper.cpp; Intel-safe) behind provider protocol
  - verify: `swift test --filter LocalSTTTests`
- [x] RANT-063 — Privacy/diagnostics view + docs (PRIVACY, NETWORK_BEHAVIOR, THREAT_MODEL)
  - verify: `ls PRIVACY.md docs/NETWORK_BEHAVIOR.md docs/THREAT_MODEL.md`
- [x] RANT-064 — App compatibility matrix + smoke test harness
  - verify: `ls docs/APP_COMPATIBILITY.md docs/SMOKE_TEST.md scripts/smoke-test.sh`
- [x] RANT-065 — XCUITest suite (onboarding, navigation, CRUD flows)
  - verify: `bash scripts/ui-test.sh`
- [ ] RANT-066 — Packaging (.dmg / zip, ad-hoc signing, notarization docs)
  - verify: `bash scripts/package.sh`
- [ ] RANT-067 — Accessibility + VoiceOver + Reduce Motion audit
  - verify: manual matrix in docs/ACCESSIBILITY.md
- [x] RANT-068 — Performance instrumentation vs targets in docs/PERFORMANCE.md
  - verify: `swift test --filter PerformanceTests`
