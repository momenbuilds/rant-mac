Rant — Claude Code Master Build Prompt

Working name: Rant

Tagline: talk messy. write clean.

Goal: build a production-quality, open-source, local-first macOS voice input system that matches the useful functionality of Wispr Flow and strong open-source competitors, then goes beyond them with migration, offline mode, extensibility, developer context, local MCP, and better ownership/privacy.

This is NOT a toy demo and NOT a weekend mock UI. Build and test the real native macOS app.

0. Your role

You are the autonomous founding engineer for this project.

Your job is to research, architect, implement, test, debug, package, and document the app end to end.

Do not stop after creating a plan, scaffolding files, or making a UI prototype. Continue through working functionality and tests.

Do not repeatedly ask me what to do next. Make strong engineering decisions yourself. Ask me only when you are truly blocked by something that cannot be inferred or automated, such as:

a credential that only I possess

a macOS permission dialog that I must click

an Apple Developer signing identity that does not exist

a destructive operation requiring explicit approval

If a real API key is unavailable, implement the integration behind a provider interface, write mocks/tests, and continue everything else. The app must still build.

1. Product

Build Rant, a native macOS app that lets me:

Hold or tap a global hotkey.

Speak naturally, including filler words, corrections, pauses, lists, technical jargon, code terms, and mid-sentence backtracking.

See a beautiful lightweight floating recorder / waveform / live transcript.

Release or tap the hotkey.

Get clean, context-aware text inserted at the exact cursor position in whatever app I was using.

Keep my transcript history, statistics, preferences, notes, dictionary, snippets, migrations, and optional audio LOCAL on my Mac.

Use my own AssemblyAI API key as the default cloud speech provider.

Switch to a local speech provider when I want fully offline operation.

Use optional local or BYOK LLM providers for rewriting and intelligence.

Migrate my own data from other dictation/notetaker apps into Rant.

Use meeting notetaking, selected-text transforms, command mode, scratchpad, voice assistant, contextual modes, developer-aware dictation, and local integrations from one app.

The core philosophy is:

open source

native

local-first

no required account

bring your own keys

provider-agnostic

fast enough to become muscle memory

user owns/exportable data

no telemetry by default

privacy controls visible and understandable

2. Competitive research MUST happen before implementation

Before writing product code, perform a fresh competitor audit.

Research CURRENT public documentation and open-source code. Do not assume feature lists in this prompt are complete.

At minimum inspect:

Wispr Flow

Official site/docs:

https://wisprflow.ai/

https://docs.wisprflow.ai/

Audit the current desktop product, especially:

system-wide dictation

push-to-talk

hands-free/toggle dictation

floating Flow Bar

transcript history

WPM / word count / streak insights

app usage categorization

dictionary

learned vocabulary

replacements

snippets

style personalization

auto cleanup levels

smart formatting

mid-sentence backtracking/corrections

context awareness

selected text / nearby cursor context

app and browser-site classification

IDE variable/file-name recognition

developer/AI coding workflows

transforms

polish

prompt engineer / custom transforms

diff view

scratchpad

command mode

notetaker

live meeting transcript

speaker/source labels

refined transcript

meeting summaries

calendar behavior

microphone selection/test

language switching

retry/cancel/paste-last controls

menu bar controls

onboarding/permissions

privacy/local storage controls

accessibility

import/export capabilities

any new feature you discover

Do not copy Wispr's branding, artwork, proprietary assets, or pixel-for-pixel UI.

VoiceInk

Repository:

https://github.com/Beingpax/VoiceInk

Docs:

https://tryvoiceink.com/docs/introduction

Study it for product and architecture ideas such as:

native macOS implementation

local transcription

modes

application/website triggers

context awareness

selected text

clipboard context

screen OCR

AI enhancement

assistant response mode

output routing

hotkeys

personal dictionary

history

privacy

IMPORTANT LICENSE RULE:

VoiceInk is GPLv3. Our project should be MIT licensed unless I explicitly change this decision.

Therefore:

you MAY inspect VoiceInk and learn from public behavior/architecture

you MUST NOT copy GPLv3 source code into this MIT project

do not mechanically translate GPL code

implement our own independent code from requirements and platform APIs

document this boundary in docs/COMPETITOR_AUDIT.md

AssemblyAI Blurt

Repository:

https://github.com/AssemblyAI/blurt

This is especially relevant because it is an open-source native macOS dictation app using a user-supplied AssemblyAI API key.

Study:

engine/app separation

audio pipeline

AssemblyAI integration

context handling

Keychain storage

hotkey state machine

focused-app capture

paste behavior

clipboard preservation

stable /Applications development install

automated test/check scripts

XCUITest strategy

CI strategy

Blurt is MIT licensed. Reuse is legally easier than VoiceInk, but still:

prefer clean modular implementations

preserve attribution for any copied/modified MIT code

add notices where required

do not blindly fork the whole product

Other competitors

Audit current public behavior from:

Superwhisper: https://superwhisper.com/

Mumble / local dictation competitors

Relay-style voice-to-action tools

other serious macOS dictation tools you discover

Create:

docs/COMPETITOR_AUDIT.md

with a matrix:

Capability

Wispr

VoiceInk

Blurt

Superwhisper

Other

Rant plan

Every important competitor capability must end in one of:

MATCH

BEAT

INTENTIONALLY_SKIP with a written reason

No silent omissions.

3. Task tracking — SET THIS UP FIRST

Before product implementation, create persistent autonomous task tracking.

Create:

TASKS.md

PROGRESS.md

docs/DECISIONS.md

scripts/status.sh

scripts/check.sh

CLAUDE.md

TASKS.md format

Use stable task IDs and this structure:

# Rant Tasks

## P0 Core
- [ ] RANT-001 — repository/bootstrap
  - depends:
  - acceptance:
  - verify:
  - notes:

- [ ] RANT-002 — permissions/onboarding
  ...

## P1 Intelligence
...

## P2 Notetaker
...

Statuses:

[ ] not started

[~] active

[x] completed

[!] blocked

Rules:

Never perform a substantial piece of work that is not represented in TASKS.md.

Before starting a task, mark it active.

After completing it, run its verification command.

Only mark it [x] if verification passes.

Add concise evidence such as test name/build command.

If new work appears, add a task instead of silently expanding scope.

Update PROGRESS.md after every meaningful milestone.

PROGRESS.md should always tell me, at a glance:

current task

completed today

current build status

unit test status

UI test status

latest installed dev build path

blockers

next 3 tasks

Claude Code behavior

Write CLAUDE.md so future Claude Code sessions automatically obey the same workflow.

It must explicitly say:

read TASKS.md and PROGRESS.md at session start

resume the active task

update status continuously

never claim green without running the required checks

never expose API keys

never use destructive git commands without necessity

keep architecture docs synchronized with code

If Claude Code hooks are useful, create lightweight .claude/ hooks, but do not build a fragile overengineered tracker. Markdown files are the canonical source of truth.

If gh auth status succeeds, you MAY optionally mirror large milestones to GitHub Issues, but local task tracking must work without GitHub.

4. Repository and licensing

Working name: Rant

Suggested repo name:

rant-mac

License:

MIT

Create:

LICENSE

README.md

CONTRIBUTING.md

SECURITY.md

PRIVACY.md

THIRD_PARTY_NOTICES.md

No user account should be required to run the app.

No analytics SDK.

No crash-reporting SDK by default.

No secret keys committed.

5. Platform / implementation requirements

Build a REAL native macOS application.

Do NOT use:

Electron

Tauri

React Native

embedded browser UI

a localhost web app pretending to be native

Use:

Swift 6+

SwiftUI for most UI

AppKit where macOS-level control is required

AVFoundation / CoreAudio for audio

Accessibility APIs for context and text insertion

CGEventTap or an equivalent reliable native mechanism for global hotkeys

ScreenCaptureKit for optional screen/system-audio capture

Vision for local OCR where required

EventKit for optional local calendar context

Security/Keychain for secrets

SQLite for local persistent data

Swift concurrency / actors for pipelines

Target:

macOS 14.4+ where practical

Apple Silicon first-class

Intel should continue to work for cloud STT when practical

macOS 26-specific local Apple features must be feature-gated rather than making the whole app crash on older systems

Use an Xcode project that can be regenerated from a declarative source if practical (for example XcodeGen). Do not make the project file an unmaintainable hand-edited mess.

6. Architecture

Use a modular architecture with a reusable engine and a thin app shell.

Suggested structure:

Rant/
  Package.swift
  Sources/
    RantCore/
      Audio/
      Hotkeys/
      STT/
      Enhancement/
      Context/
      Injection/
      Storage/
      Dictionary/
      Snippets/
      Styles/
      Transforms/
      Insights/
      Notetaker/
      Migration/
      MCP/
      Security/
  Tests/
    RantCoreTests/

  App/
    Rant/
      App/
      DesignSystem/
      Onboarding/
      Home/
      Recorder/
      Notetaker/
      Insights/
      Dictionary/
      Snippets/
      Styles/
      Transforms/
      Scratchpad/
      Migrate/
      Settings/
      MenuBar/
    RantUITests/

  docs/
  scripts/
  .github/workflows/

Use clear protocols/interfaces.

At minimum:

protocol TranscriptionProvider
protocol StreamingTranscriptionProvider
protocol EnhancementProvider
protocol ContextProvider
protocol TextInjector
protocol HotkeyProvider
protocol AudioCaptureProvider
protocol TranscriptStore
protocol MigrationAdapter
protocol MeetingCaptureProvider

Do not couple the UI directly to AssemblyAI.

Providers must be replaceable.

7. Speech-to-text providers

Default: AssemblyAI BYOK

The default cloud provider is AssemblyAI.

The user pastes their own API key during onboarding/settings.

Store it ONLY in macOS Keychain.

Never:

hardcode it

print it

write it to logs

put it in UserDefaults

put it in a crash report

commit it

Support the best current AssemblyAI path for low-latency dictation after checking current official docs.

Requirements:

streaming partial transcripts where supported

reconnect/backoff

network error state

clean cancellation

silence handling

language configuration / auto detect where supported

custom vocabulary / key terms

context priming when supported

correct audio format conversion

testable networking abstraction

Also support a non-streaming/high-quality path when useful.

Local providers

Rant must not become useless when the AssemblyAI free credit runs out.

Implement a provider architecture and at least one practical fully-local provider.

Evaluate current options and select the best path for supported macOS versions, such as:

Apple SpeechAnalyzer on macOS 26+

whisper.cpp

FluidAudio / Parakeet

another strong open model with a compatible license

Local mode requirements:

no audio leaves the Mac

models clearly show size/RAM requirements

download/progress/delete controls

graceful fallback if hardware is insufficient

no silent cloud fallback when user selected "Local only"

Provider UI:

Settings → Speech

should show:

AssemblyAI

Local

future providers

with status, latency test, privacy indicator, and model/provider configuration.

8. Core dictation experience

Implement the interaction so it feels instant.

Support:

Push-to-talk

Hold the configured key:

start recording

show overlay

release

finalize

insert

Toggle

Tap configured key:

start

tap again

stop

Hybrid single-modifier behavior

A lone modifier should be usable without breaking normal shortcuts.

Example:

right Option

right Command

Fn/Globe where technically reliable

If the modifier participates in another shortcut, normal shortcut behavior must continue.

Build and thoroughly test the state machine.

Hands-free

Double-tap configurable hotkey to start a locked recording.
Stop with:

hotkey

overlay button

Esc

Cancel

Esc cancels the active recording and inserts nothing.

Retry

Retry last failed transcription.

Paste last

Global action to paste the most recent successful transcript.

Recording overlay

Create an original design, not a Wispr clone.

Default position near bottom-center.

States:

idle/ready when configured to stay visible

listening

processing

enhancing

success

error

offline

meeting capture

Include:

live waveform / meter

partial transcript preview

active mode/style

microphone indicator

clear cancel affordance

duration for long recordings

Allow:

drag positioning

hide/show always

compact and expanded sizes

Keep animation lightweight and honor Reduce Motion.

9. Reliable cursor insertion

This is critical.

Text must land in the app that had focus when dictation started/ended.

Implement a robust injector:

Prefer direct Accessibility insertion where reliable.

Fall back to clipboard + synthesized Cmd+V.

Preserve and restore the user's existing clipboard safely.

Avoid restoring too early.

Handle applications with weird text fields.

Handle the target app/window disappearing.

If insertion fails, keep final text on clipboard and notify the user.

Correct spacing around the insertion point.

Never paste into secure/password fields automatically.

Test at minimum against:

TextEdit

Notes

Safari/Chrome text field

Slack/Discord-like input if installed

Terminal

VS Code/Cursor if installed

Xcode

Notion/browser editor if available

Create a local manual compatibility matrix in:

docs/APP_COMPATIBILITY.md

10. Context awareness

Context is one of the key quality differentiators.

Create a strict local ContextEngine.

Possible sources:

frontmost app bundle ID

app name

window title

browser URL/domain when accessible

focused field role/label

selected text

text immediately before cursor

text immediately after cursor

nearby text

clipboard, only if user enables it

optional visible-window OCR

optional IDE symbols/files

recent Rant dictations

local dictionary

Privacy rules:

context collection is local by default

show exactly which context types are enabled

allow per-app exclusions

NEVER collect nearby text from secure/password fields

support a global "context off" shortcut/toggle

support "local context but do not send context to cloud provider"

minimize context size

redact obvious secrets when sending context to a remote enhancer

do not log captured screen text

Browser awareness

Recognize web apps by domain when technically available, not just "Chrome".

Examples:

Gmail → Email

Slack web → Work

WhatsApp Web → Personal

Notion → Documents

Claude/ChatGPT → AI

GitHub → Developer

IDE/developer awareness

For Cursor / VS Code / Windsurf / Xcode:

capture visible/recent file names where safely accessible

learn variable/function/class names from visible editor text or accessible semantic text

improve proper casing

understand phrases like "at main dot swift" → @main.swift in supported AI chat contexts

preserve camelCase / PascalCase / snake_case symbols

developer mode should work especially well for prompts to Claude Code and Codex

Do not scan the entire disk or repository without explicit opt-in.

11. Cleanup / smart formatting / self-correction

Implement raw transcription plus configurable cleanup.

Style → Auto Cleanup

levels:

None

Nearly literal transcript.

Light

punctuation

capitalization

filler removal

obvious grammar repair

preserve wording

Medium

default

clean sentence structure

remove repetitions

understand natural self-corrections

sensible paragraph/list formatting

High

more concise

stronger restructuring

preserve meaning

never invent factual content

Support:

spoken punctuation

bullet lists

numbered lists

paragraphs

"new line"

"new paragraph"

quotes

parentheses

code-ish punctuation when developer mode applies

Backtracking

Understand patterns such as:

"send it Tuesday — actually Wednesday"

→ "Send it Wednesday."

"his name is Mark, sorry, Marcus"

→ "His name is Marcus."

Do this in the intelligence layer rather than via brittle single regex rules only.

12. Enhancement providers

Separate transcription from enhancement.

Support local-first options.

At minimum design for:

Apple on-device Foundation Models when available

Ollama / local OpenAI-compatible endpoint

optional AssemblyAI cleanup capability

optional OpenAI-compatible BYOK remote provider

API keys go to Keychain.

The app must still perform useful dictation with enhancement OFF.

Remote enhancement should be clearly labeled because transcript/context may leave the device.

13. Dictionary and learning

Create a great local personal dictionary.

Support:

word/phrase boosts

exact replacements

spoken-form → written-form

casing

acronym expansion

pronunciation note if provider supports it

categories/tags

favorites

search

import/export

Examples:

"super base" → Supabase

"ver sell" → Vercel

"cloud flare" → Cloudflare

"camel case user id" → userId depending on developer mode

Dictionary entries should affect transcription/context immediately.

Optional adaptive learning

Create an opt-in "Learn from my corrections" feature.

After Rant inserts text, for a short bounded window, it may observe edits to the SAME focused field and compare the inserted text to the corrected version.

Rules:

opt-in only

only the text Rant inserted + the changed span

never store the whole surrounding document

propose a dictionary/replacement rule

user can accept/reject

no silent permanent rule if confidence is low

This should make Rant genuinely improve over time.

14. Snippets

Create speech-triggered snippets.

Examples:

Trigger:
my meeting link

Expansion:
https://cal.com/...

Requirements:

trigger phrase

expansion

search

duplicate validation

enabled/disabled

folders/tags optional

immediate availability

import/export

snippet expansion works inside a longer dictation

clear conflict resolution with dictionary replacements

Keep all snippet data local.

15. Styles

Create app-aware writing styles.

Default categories:

Personal

Work

Email

Developer

AI Prompt

Documents

Other

Built-in styles:

Natural

Casual

Very Casual

Formal

Concise

Excited

Developer

Custom

Allow:

custom style instructions

per-category defaults

per-app override

per-site override

one-session quick override

Rant should automatically select category based on active app/domain.

16. Modes / workflows

Go beyond fixed styles with reusable Modes.

A Mode controls:

transcription provider/model

language

enhancement on/off

enhancer/model

prompt

context sources

style

output target

auto-send

shortcut

app triggers

website triggers

word trigger

custom post-processing

Starter modes:

Dictation

Clean

Email

Message

Developer

Rewrite

Assistant

Terminal

Meeting Notes

Mode switching:

manual

hotkey

app-aware automatic

domain-aware automatic

17. Transforms

Add global selected-text transforms.

Workflow:

User selects text in ANY app.

Press transform shortcut.

Rant reads the selection via Accessibility.

Runs local/selected enhancement provider.

Shows optional diff preview.

Replaces selection in place.

Built-ins:

Polish

Shorten

Expand

Fix grammar

Make casual

Make formal

Explain simply

Prompt Engineer

Convert to bullets

Convert to Markdown

Translate

Custom Prompt

Allow custom transforms and custom shortcuts.

View Diff must show original vs result and let the user:

accept

reject

copy

edit before applying

18. Command mode

Implement voice instructions that operate on current text/context instead of simply dictating.

Examples:

"make this shorter"

"turn this into bullets"

"reply saying Thursday works"

"replace every mention of X with Y"

"summarize the selected text"

"copy the last paragraph"

"undo that transform"

Use explicit context and a constrained action model.

Safety:

text edits can be applied with preview or undo

filesystem/shell/destructive actions must NOT silently execute

if command mode eventually supports system actions, show the planned action and require confirmation for risky operations

Hotkey should be distinct from normal dictation.

19. Scratchpad

Create a local Markdown scratchpad.

Use cases:

quick thoughts

brain dumps

drafts

todo lists

dictated notes

Features:

create note

voice append

Markdown

search

pin

tags

local AI polish/summary

export

drag/drop text

no account

20. Transcript history

Every successful dictation should optionally create a local history item.

Store:

timestamp

final text

raw transcript

provider

language

mode

style

target app/domain category

duration

words

WPM

latency stages

whether enhancement ran

optional retained audio path

source/import metadata

Features:

group by date

full-text search

copy

paste again

edit

delete ONE

delete many

delete all

retry failed item

replay if audio retained

export

favorite/pin

local tags

Unlike competitors that make history deletion awkward, Rant should make ownership obvious.

Audio retention

Choices:

never store audio (default recommendation)

24 hours

7 days

30 days

forever

Deleting a transcript should also offer to delete its audio.

21. Insights

Recreate useful productivity insights locally.

Dashboard cards:

total words

average WPM

today

week

streak

longest streak

time saved estimate

Usage categories:

AI prompts

personal messages

work messages

email

documents

developer

other

Charts:

daily word count

WPM trend

app/category usage

cleanup corrections

dictionary saves

provider latency

No need to send analytics anywhere.

Use only local database aggregates.

22. Voice profile

Create a local "Voice Profile" concept based on actual user behavior.

Possible useful fields:

average speaking rate

common filler words

common vocabulary

languages

preferred cleanup level

frequently corrected terms

app-specific style patterns

Do not invent pseudo-psychological labels.

Keep it practical and explainable.

23. Meeting Notetaker

Build a serious local-first meeting recorder.

No meeting bot should need to join calls.

Capture:

microphone audio

system audio where macOS permits

meeting/app metadata

optional calendar event match

Use ScreenCaptureKit/CoreAudio as appropriate.

Features:

Start meeting manually

detect probable meeting apps if allowed

optional calendar reminders

live transcript

distinguish "Me" vs system/others when possible

speaker diarization/refinement when provider supports it

final refined transcript

summary

action items

decisions

questions

key moments

searchable transcript

playback synced to text where practical

export Markdown

export TXT

export JSON

export SRT/VTT if timestamps available

Meeting history must be local.

Enhancement/summarization should use local model by default when practical, with BYOK cloud optional.

If a provider requires uploading meeting audio, make that explicit before the first use.

24. Calendar

Prefer privacy-friendly local calendar integration first.

Use EventKit to read local macOS Calendar events after explicit permission.

Features:

upcoming meeting list

join link when available

"start notetaker" reminder

use event title/attendees as optional vocabulary context

never upload the calendar database

Optional direct cloud calendar connectors can be a later provider, not required for the core app.

25. Migration Center — major differentiator

Add a sidebar item:

Migrate

Goal:

Bring your voice history home.

Build a safe migration framework for user-owned data.

Adapters should support, where feasible:

Wispr Flow

VoiceInk

Superwhisper

Otter export

generic TXT

Markdown

JSON

CSV

SRT

VTT

folders of transcripts

Architecture:

protocol MigrationAdapter {
    var sourceName: String { get }
    func canRead(_ source: URL) async -> Bool
    func preview(_ source: URL) async throws -> MigrationPreview
    func importData(_ source: URL, options: MigrationOptions) async throws -> MigrationResult
}

Rules

Migration must NEVER:

bypass authentication

decrypt protected competitor data

steal tokens/cookies

modify competitor files

delete originals

silently scan unrelated user directories

It MAY:

import official exports

import a user-selected file/folder

inspect documented/readable local app storage after explicit user approval

copy readable user-owned local records into Rant

parse formats we can lawfully and safely understand

If a competitor's format is undocumented/brittle:

make the adapter versioned

show a warning

do a dry-run

never mutate source data

Migration UX

Step 1:
Choose source.

Step 2:
Choose export/file/folder or approve detected local path.

Step 3:
Preview:

transcripts found

meetings found

dictionary entries

snippets

styles

date range

estimated size

unsupported records

Step 4:
Import.

Step 5:
Show report:

imported

duplicates skipped

malformed skipped

unsupported

errors with file references

Use deterministic duplicate hashes so imports are idempotent.

Preserve source metadata:

source = wispr_flow

etc.

Rant export

Also create OUR own portable archive format from day one.

Rant Archive

A versioned folder/zip containing:

manifest.json

transcripts.jsonl

meetings/

dictionary.json

snippets.json

styles.json

scratchpad/

optional audio/

Users must always be able to leave Rant.

26. Local search and semantic recall

Full-text search using SQLite FTS5.

Optional advanced local semantic search:

local embeddings only by default

search transcript/meeting/scratchpad history

"what did I say about Candle last week?"

"find the dictation where I mentioned the API migration"

This is a differentiator, but do not block core launch on embeddings.

27. Local MCP server

Add an OPTIONAL local-only MCP server bundled with the app.

Purpose:

Allow Claude Code, Codex, Cursor, and other local MCP clients to query user-approved Rant data.

Tools could include:

rant_search_transcripts

rant_get_transcript

rant_search_meetings

rant_get_meeting

rant_search_notes

rant_get_stats

rant_get_current_context

rant_start_dictation

rant_stop_dictation

Privacy:

disabled by default

loopback/local process only

explicit enable UI

read-only by default

user can choose which collections are exposed

never expose API keys

audit local MCP requests in a local log

Do this after core dictation is stable.

28. Voice-to-action / "more than Flow"

Add a carefully constrained Actions layer after the text product is stable.

Examples:

create a local scratchpad note

copy result

paste and send

open a URL

create a local reminder via a supported macOS mechanism

send final text into a custom local command with confirmation

Build actions as registered capabilities rather than giving an LLM unrestricted shell access.

Every action must have:

identifier

input schema

permission class

preview text

execution result

undo information if possible

High-risk actions require confirmation.

29. Settings

Settings sections:

General

launch at login

menu bar behavior

overlay visibility

sounds

hotkeys

language

Speech

AssemblyAI key/status

speech provider

local models

microphone

streaming

language

Intelligence

cleanup level

enhancement provider

local/cloud privacy state

context settings

Privacy

no telemetry statement

local storage

cloud context toggles

audio retention

per-app exclusions

clear local data

export archive

Notetaker

system audio

summaries

calendar

retention

Integrations

MCP

custom commands

URL scheme

optional providers

Advanced

developer mode

logs

diagnostics

reset

experimental features

30. Onboarding

Make first-run setup excellent.

Flow:

Welcome to Rant

"Your voice, your Mac, your data."

Microphone permission

Accessibility permission

Optional Screen Recording permission

Select microphone + live meter

Choose activation key

Choose speech engine:

AssemblyAI BYOK

Local

If AssemblyAI:

API key field

test button

save to Keychain

Privacy choices

One live dictation test

Done

The onboarding must explain WHY every macOS permission exists.

If a permission is denied, show a precise button to open the correct System Settings pane.

Never trap the user in a broken onboarding state.

31. Main app design

Build an original premium native design.

Do NOT clone Wispr Flow pixel-for-pixel.

Suggested sidebar:

Home

Notetaker

Insights

Dictionary

Snippets

Styles

Modes

Transforms

Scratchpad

Migrate

Settings

Home should feel immediately useful.

Show:

greeting

total words

WPM

streak

current voice profile summary

recent transcript history

search

quick start control

privacy/provider status

Use restrained macOS-native visuals.

No giant gradient AI slop.

No unnecessary illustration-heavy landing page.

Use typography, spacing, subtle materials, and small delightful motion.

Support:

light

dark

system

keyboard navigation

VoiceOver

reduced motion

dynamic text where appropriate

32. Menu bar

Menu bar app is essential.

Menu:

Start/Stop Dictation

Paste Last Transcript

Start Notetaker

Current Mode

Microphone

Language

Open Rant

History

Settings

Quit

Optional left-click quick dictate behavior.

33. Privacy/security requirements

Treat privacy as architecture, not marketing.

Rules:

No telemetry by default.

No account required.

API keys in Keychain.

No secrets in logs.

Do not log transcript/context bodies in normal logs.

Local DB only unless user explicitly enables cloud functionality.

Audio not retained by default.

Secure text fields excluded.

Clear visible indicator whenever mic/system audio capture is active.

Network requests should be inspectable/documented.

Build docs/NETWORK_BEHAVIOR.md.

Build docs/DATA_MODEL.md.

Build docs/THREAT_MODEL.md.

Add a local diagnostics view showing:

active provider

network mode

permissions

database size

audio retained size

model disk usage

34. Data model

Use versioned database migrations.

Suggested entities:

transcripts

transcript_segments

meetings

meeting_segments

dictionary_entries

snippets

styles

modes

notes

usage_daily

app_usage

migration_runs

migration_items

provider_metrics

Use SQLite WAL.

Use FTS5 for transcript/note/meeting search.

Never rely on an unversioned schema.

Migration tests are mandatory.

35. Performance targets

Measure these.

Targets:

overlay visible < 100 ms after hotkey where hardware permits

audio capture starts < 150 ms

no dropped first syllable

UI stays 60fps during normal dictation

no blocking network work on main thread

idle app memory should remain reasonable for a native menu bar app

local history search should feel instant for tens of thousands of transcripts

paste should happen as soon as final text is available

clipboard restoration must be reliable

cancellation should feel immediate

Track latency stages:

hotkey → capture

capture end → STT final

STT final → enhancement final

enhancement → inserted

Show this only in developer diagnostics, not as noisy normal UX.

36. Testing — do not fake this

The app is not done because it compiles.

Create serious automated testing.

Unit tests

At minimum:

hotkey state machine

push-to-talk

tap toggle

double-tap hands-free

cancel

retry

transcription state transitions

provider fallback

AssemblyAI request construction

context minimization

secure-field exclusion

dictionary replacements

snippet triggers

cleanup modes

style selection

app/domain classification

text spacing

clipboard save/restore

injector fallback

history CRUD

FTS search

stats/WPM

database migrations

migration dry-run

duplicate migration idempotency

Rant Archive import/export

audio retention cleanup

meeting state machine

Use mocks/protocol seams so tests do not require a real paid API.

Integration tests

Create a mock STT server/provider.

Test:

mic sample → provider → transcript → enhancement → injection seam

network failure

malformed response

timeout

cancellation mid-request

stream reconnect

empty/no-speech recording

UI tests

Use XCUITest.

At minimum:

onboarding UI

permissions explanatory state

home window opens

sidebar navigation

add dictionary entry

add snippet

change style

create scratchpad note

migration preview with fixture

settings persistence

Global OS injection is hard to fully automate. Build a targeted integration/manual harness for it rather than pretending a brittle test is reliable.

Manual smoke tests

Create:

scripts/smoke-test.sh

and:

docs/SMOKE_TEST.md

The manual matrix should include actual dictation into:

TextEdit

Safari/Chrome

Terminal

Xcode

Cursor/VS Code

Notes

37. Stable development installation

macOS privacy/TCC behavior can be unreliable if the app bundle path/identity changes constantly.

Build a stable dev install flow.

Create:

scripts/dev-build.sh

It should:

build

sign appropriately for local development when possible

install to a stable path such as:

/Applications/Rant Dev.app

or fallback to:

~/Applications/Rant Dev.app

preserve a stable bundle ID

launch the installed copy

Document how to reset permissions if needed.

Do not test Accessibility/global injection exclusively from random DerivedData bundle paths.

38. Health check

scripts/check.sh becomes the definition of green.

It should eventually run, as applicable:

formatting

lint

Swift unit tests

warnings-as-errors build

database migration tests

relevant integration tests

Xcode project drift check if generated

app build

UI tests where environment supports them

CI should call the same script where practical.

A skipped check must be reported as skipped, not silently treated as a pass.

39. CI

Create GitHub Actions for:

build

unit tests

lint/format

security/static analysis where practical

Do not expose real AssemblyAI keys to pull requests.

All normal tests must use mocks/fixtures.

A separate opt-in secret-backed end-to-end AssemblyAI test may exist later, but it is not required for PR correctness.

40. Build artifacts

For local personal use, produce:

runnable .app

Debug dev app

Release app

.dmg or zip installer

If a Developer ID certificate is not available:

still make a functional local/ad-hoc signed build

document what is missing for public distribution

do not block product development on notarization

If signing credentials are available later, add:

Developer ID signing

notarization

stapling

release automation

41. Versioning / updates

Use semantic versioning.

Start at:

0.1.0

Milestone suggestions:

0.1 core dictation

0.2 history/dictionary/snippets/styles

0.3 transforms/context/developer mode

0.4 migration

0.5 notetaker

0.6 command/actions/MCP

0.9 hardening

1.0 stable

Automatic updater can be added later with a suitable open-source mechanism.

42. Initial milestone order

Do not try to implement 50 features simultaneously.

Use this dependency order while keeping the full backlog tracked.

Phase A — research + foundation

competitor audit

architecture

task tracking

project scaffolding

local DB

logs

Keychain

permissions

Phase B — killer core loop

hotkey

mic

AssemblyAI

overlay

final text

reliable injection

error handling

dev install

tests

At the end of Phase B I must be able to use Rant instead of basic dictation.

Phase C — intelligence

context

cleanup

local enhancer

dictionary

snippets

styles

modes

Phase D — ownership

history

search

insights

export

migration center

Phase E — power

transforms

command mode

developer mode

scratchpad

MCP

Phase F — notetaker

system audio

live meeting transcript

summaries

calendar

exports

Phase G — hardening

accessibility

privacy audit

performance

migration fuzz fixtures

app compatibility

packaging

docs

release

Do not call the product "done" before the killer core loop works end-to-end.

43. Acceptance criteria for core replacement

Core dictation is only accepted when all of these are true:

I can install Rant Dev.app.

Onboarding clearly requests required permissions.

I can enter an AssemblyAI key and it is stored in Keychain.

I can configure a global hotkey.

Holding the hotkey starts recording.

Overlay appears instantly.

Waveform responds.

Releasing stops.

Speech is transcribed.

Cleaned text is inserted into TextEdit.

Same works in a browser text field.

Same works in Terminal.

Existing clipboard survives.

Escape cancels.

Network failure does not lose recorded state silently.

Last transcript can be pasted again.

Transcript can be found in local history.

No transcript/audio is sent anywhere except the selected provider(s).

Unit tests pass.

scripts/check.sh is green for implemented checks.

44. Acceptance criteria for "better than competitors"

The full product should ultimately provide:

everything useful from modern system-wide AI dictation

a local/offline path

no mandatory subscription/account

open source

provider choice

local transparent history

per-item deletion

portable export

safe competitor migration

app/site-aware styles/modes

selected-text transforms

developer context

meeting notetaker

scratchpad

command mode

MCP

explainable privacy

easy data ownership

excellent test coverage

The goal is not "a Wispr clone."

The goal is:

the voice input layer I would choose even if the paid competitors were free.

45. Things you must NOT do

Do not:

create a fake UI with non-working buttons

hardcode demo transcripts

declare TODO features "done"

stop because one feature is complicated

ask me to manually create every file

use Electron

require an account

add analytics

copy Wispr assets

copy GPL VoiceInk code into our MIT codebase

expose keys

read passwords

scan unrelated files

bypass competitor protections during migration

silently execute dangerous voice commands

commit generated secrets

mark skipped tests as passed

say "production ready" without evidence

46. How to work right now

Start immediately.

Your FIRST actions should be:

Inspect the current directory and existing repo state.

Check installed tools:

Xcode

Swift

Homebrew

git

gh

Create TASKS.md, PROGRESS.md, and CLAUDE.md.

Perform current competitor research.

Create docs/COMPETITOR_AUDIT.md.

Create docs/ARCHITECTURE.md.

Create docs/DECISIONS.md.

Scaffold the native project.

Implement the Phase B core loop.

Build it.

Test it.

Install the stable dev app.

Fix failures.

Update task tracking.

Continue to the next phase.

Do not return to me with only a plan.

Return only after you have made concrete implementation progress, and report:

what now works

exact tasks completed

exact files created/changed

tests run

build result

path to the installed app

what permission/credential you need from me, if any

next tasks already tracked

If the AssemblyAI API key is needed for the first real transcription test, build the complete key-entry UI and mocked test path first. Then tell me exactly where to paste my key in the app.

Now begin.