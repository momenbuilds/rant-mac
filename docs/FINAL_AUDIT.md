# Rant — Final Completeness Audit

Contract: `docs/MASTER_PROMPT.md` (recovered verbatim from the original build prompt).
`TASKS.md` is not the contract; where the two disagree, the master prompt wins.

Statuses are **PASS**, **PARTIAL**, **FAIL**, **BLOCKED_EXTERNAL** only. PASS requires
observable behaviour or an automated test that exercises the behaviour — never the mere
existence of a type.

## The headline finding

`RantCore` implements very nearly the whole specification and is covered by ~770 unit
tests. The **app shell exposes only part of it.** Several screens describe behaviour
that exists in the engine but has no path from the user interface to it, which is the
specific failure mode the master prompt forbids in §45: *"create a fake UI with
non-working buttons"* and *"declare TODO features done"*.

Evidence for the shape of the gap — every one of these engine entry points is fully
implemented and tested, and referenced **nowhere** in `App/Rant`:

`TransformEngine`, `CommandExecutor`, `CommandParser`, `ActionRegistry`,
`BuiltInActions`, `MCPServer`, `LearningEngine`, `SemanticIndex`, `ModelStore`,
`ModelCatalog`, `VoiceProfileBuilder`, `CalendarMatcher`, `AudioRetention`,
`AssemblyAIStreamProvider`, `ProviderRegistry`, `ModeResolver`, `StyleResolver`,
`LocalWhisperProvider`.

Verify with:

```
for t in TransformEngine CommandExecutor MCPServer LearningEngine ProviderRegistry \
         AudioRetention ModeResolver StyleResolver LocalWhisperProvider; do
  grep -rl "$t" App/Rant >/dev/null || echo "not referenced in app: $t"
done
```

## Matrix

| ID | Area | Requirement (master prompt §) | Implementation evidence | Test evidence | Status | Gap |
|----|------|------------------------------|-------------------------|---------------|--------|-----|
| A-01 | Platform | Native Swift/SwiftUI/AppKit, no Electron/Tauri/web shell (§5) | `Package.swift`, `project.yml`, 115 Swift files, zero JS/HTML | build | PASS | — |
| A-02 | Architecture | Engine/app split; RantCore imports no SwiftUI (§6) | `scripts/check.sh` "engine/app layering" | check.sh | PASS | — |
| A-03 | Architecture | Provider protocols, AssemblyAI not hardwired (§6) | `TranscriptionProvider`, `EnhancementProvider`, … | unit | PARTIAL | app bypasses `ProviderRegistry`; `makeTranscriptionProvider()` returns AssemblyAI unconditionally |
| B-01 | Core loop | Push-to-talk / toggle / hands-free / cancel (§8) | `DictationGate`, `HotkeyEngine` | `HotkeyStateMachineTests` | PASS | — |
| B-02 | Core loop | Lone-modifier trigger leaves shortcuts alone (§8) | `HotkeyEngine.isDown` classification | `HotkeyEngineClassificationTests` | PASS | fixed this session; was cancelling every recording |
| B-03 | Core loop | Overlay states, waveform, cancel affordance (§8) | `RecorderOverlay`, `OverlayController` | manual | PASS | — |
| B-04 | Injection | Accessibility-first, clipboard fallback, restore (§9) | `Sources/RantCore/Injection` | `InjectionTests` | PASS | — |
| B-05 | Core loop | Retry last failure; paste last transcript (§8) | `AppModel`, menu bar | manual | PARTIAL | verify both are reachable |
| C-01 | STT | AssemblyAI BYOK, key in Keychain only (§7) | `AssemblyAIProvider`, `SecretStore` | `AssemblyAITests`, `SecretStoreTests` | PASS | — |
| C-02 | STT | Streaming partial transcripts, reconnect/backoff (§7) | `AssemblyAIStreamProvider`, `ReconnectPolicy` | `StreamingTests` | FAIL | never constructed by the app; no way to select it |
| C-03 | STT | **At least one practical fully-local provider** (§7, §9) | `LocalWhisperProvider` + `WhisperBackend` protocol | `LocalSTTTests` (against `FakeWhisperBackend`) | FAIL | **no production `WhisperBackend` exists.** Only conformer in the repo is a test fake. Local mode cannot transcribe |
| C-04 | STT | Provider picker changes the provider (§7, §45) | `SettingsView` Engine picker | — | FAIL | `makeTranscriptionProvider()` is `switch { default: AssemblyAIProvider }` — the picker changes nothing |
| C-05 | STT | Local model download / progress / delete / disk use (§9) | `ModelStore`, `ModelCatalog`, `URLSessionModelDownloader` | `LocalSTTTests` | FAIL | no UI anywhere |
| C-06 | STT | Local-only refuses network provider, never silently falls back (§7) | `DictationSession.swift:156` throws `localOnlyViolation` | `SessionTests` | PASS | correct — but with C-03 unfixed it means local-only cannot dictate at all |
| D-01 | Cleanup | Four levels, deterministic offline (§11) | `TranscriptCleaner` | `CleanupTests` | PASS | — |
| D-02 | Cleanup | Self-correction / backtracking (§11) | `TranscriptCleaner` linear scans | `CleanupTests` | PASS | — |
| D-03 | Cleanup | Spoken punctuation (§11) | `SpokenPunctuation` | `CleanupTests` | PASS | — |
| E-01 | Context | Frontmost app, field role, selection, before/after cursor (§10) | `AccessibilityContextProvider` | unit | PASS | — |
| E-02 | Context | Secure fields never read (§10, §33) | `SurfaceClassifier` | `InjectionTests` | PASS | — |
| E-03 | Context | Single audited outbound boundary; redaction (§10) | `OutboundContext`, `SecretRedactor` | unit | PASS | — |
| E-04 | Context | Per-app exclusions (§10) | `ContextSettings` | unit | PARTIAL | confirm the UI writes it |
| F-01 | Dictionary | CRUD, search, replacement, casing, import/export (§13) | `DictionaryView` (437 lines) | `DictionaryTests` | PASS | — |
| F-02 | Learning | Opt-in learn-from-corrections (§13) | `LearningEngine` | `LearningTests` | FAIL | not referenced by the app; no opt-in UI |
| G-01 | Snippets | CRUD + expansion inside dictation (§14) | engine + UI | `DictionaryTests` | PASS | — |
| H-01 | Styles | Custom instructions, per-category/app/site override (§15) | `WritingStyle`, `StyleResolver` | `StyleTests` | FAIL | `StylesView` is a read-only list — zero controls |
| I-01 | Modes | Modes control provider/language/cleanup/context/style/triggers (§16) | `Mode`, `ModeResolver` | `StyleTests` | FAIL | no sidebar item, no UI, resolver unused |
| J-01 | Transforms | Select text anywhere → transform → diff → accept/reject/edit (§17) | `TransformEngine`, `TextDiff`, `TransformCatalogue` | `TransformTests` | FAIL | `TransformsView` is a catalogue listing. No hotkey, no diff UI, no invocation. The page's own copy describes behaviour that does not exist |
| K-01 | Command mode | Voice instructions operating on context, with preview (§18) | `CommandParser`, `CommandExecutor` | `CommandModeTests` | FAIL | unwired; no hotkey |
| L-01 | Scratchpad | Notes CRUD, pin, search, export, persistence (§19) | `ScratchpadView` | `ScratchpadTests` | PASS | — |
| M-01 | History | Store all metadata fields (§20) | `Storage` | `StoreTests` | PASS | — |
| M-02 | History | **Delete ONE** transcript (§20) | `AppModel.delete(_:)` exists at line 559 | `StoreTests` | FAIL | nothing in `HistoryView` calls it; only "delete everything" |
| M-03 | History | Copy / paste again / retry / favourite / tags per item (§20) | partial | — | PARTIAL | audit each |
| N-01 | Audio retention | never / 24h / 7d / 30d / forever actually enforced (§20) | `AudioRetention` sweeper | `RetentionTests` | FAIL | sweeper never runs in the app |
| O-01 | Insights | Local aggregates, no hardcoded numbers (§21) | `InsightsEngine` | `InsightsTests` | PASS | — |
| O-02 | Voice profile | Explainable local stats (§22) | `VoiceProfileBuilder` | `InsightsTests` | FAIL | not referenced by the app |
| P-01 | Notetaker | Capture, live transcript, persistence, summary, exports (§23) | `NotetakerView`, `MeetingSession`, `MeetingSummariser` | `MeetingTests`, `MeetingExportTests` | PARTIAL | page calls the store; confirm capture + summary reachable |
| Q-01 | Calendar | EventKit, permission, join links, denied path (§24) | `CalendarMatcher`, `CalendarProviding` | `MeetingTests` | FAIL | not referenced by the app |
| R-01 | Migration | Adapters, preview, dry run, idempotent import, report (§25) | `MigrateView` + adapters | `MigrationTests` | PASS | — |
| R-02 | Archive | Rant Archive export/import round trip (§25) | `RantArchiveAdapter` | `ArchiveTests` | PASS | — |
| S-01 | Search | SQLite FTS5 over transcripts/notes/meetings (§26) | `Storage` FTS | `StoreTests` | PASS | — |
| S-02 | Search | Optional local semantic recall (§26) | `SemanticIndex` | `SemanticSearchTests` | FAIL | unwired; spec allows it to be optional, but it is built and hidden |
| T-01 | MCP | Local-only MCP server, disabled by default, enable UI (§27) | `MCPServer`, `MCPSettings` | `MCPTests`, `MCPTransportTests` | FAIL | no enable UI; server never started |
| U-01 | Actions | Registered capabilities, permission class, confirmation (§28) | `ActionRegistry`, `BuiltInActions` | `ActionsTests` | FAIL | unwired |
| V-01 | Settings | Sections General/Speech/Intelligence/Privacy/**Notetaker**/**Integrations**/**Advanced** (§29) | `SettingsView` | UI tests | PARTIAL | only General/Speech/Intelligence/Privacy/Diagnostics exist |
| W-01 | Onboarding | Permissions explained, key entry, never traps the user (§30) | `OnboardingView` (491 lines) | `OnboardingUITests` | PASS | — |
| X-01 | Menu bar | Full menu, no dead items (§32) | `MenuBarContent` | manual | PARTIAL | audit every item |
| Y-01 | Privacy | No telemetry, keys in Keychain, no transcript logging (§33) | `check.sh` secret scan, `RantLog` redaction | check.sh | PASS | — |
| Z-01 | Data model | Versioned migrations, WAL, FTS5 (§34) | `Storage` | `StoreTests` | PASS | — |
| Z-02 | Performance | Measured budgets (§35) | `PerformanceTests` | unit | PASS | — |
| Z-03 | Packaging | Debug + Release build, dev install at stable path (§37, §40) | `scripts/dev-build.sh`, `scripts/package.sh` | manual | PARTIAL | Release build unverified this session |
| Z-04 | Licence | No GPL VoiceInk source in this MIT codebase (§4) | `check.sh` licence guard greps GPL headers | check.sh | PASS | — |

## Working list

Everything marked FAIL or PARTIAL above is tracked in `TASKS.md` under
**Final Completeness Audit** and is being fixed in that order. This document is updated
as each one lands, with the evidence that moved it.
