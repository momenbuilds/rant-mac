# Threat model

## What Rant is

A macOS application that can see every keystroke-adjacent surface on your machine:
it holds a global event tap, reads focused text fields through Accessibility, can
capture the microphone and system audio, and can synthesise keystrokes. That is an
enormous amount of trust. This document says what we do with it and what we refuse.

## Assets

| Asset | Where it lives | Worst case if it leaks |
|---|---|---|
| API keys | macOS Keychain | billing fraud on your provider account |
| Transcripts | `~/Library/Application Support/Rant/rant.sqlite` | everything you have dictated |
| Retained audio | same directory, off by default | your voice, verbatim |
| Context snapshots | memory only, never persisted | whatever was on screen |
| Meeting recordings | same directory | other people's voices, who did not install this |

## Adversaries considered

**A curious local process.** Another app on your Mac reading Rant's files. The
database sits under your user account with standard permissions; a process running
as you can read it, exactly as it could read your Notes database. Mitigation is
scope, not cryptography: audio is not retained by default, context is never
persisted, and keys are in the Keychain where an ACL applies rather than in a file.

**A network observer.** All provider traffic is TLS. Nothing is sent in the clear.
An observer learns that you use AssemblyAI and roughly when and how much you speak.

**A malicious or compromised provider.** This is the real one. If you use a cloud
speech provider, that provider hears everything you dictate. There is no way around
that other than not using one — which is why the local provider is a first-class
path and not a checkbox. "Local only" mode means a provider failure is an error,
never a silent fallback to the network.

**A malicious import file.** Migration parses formats produced by other programs.
Adapters are parsers, and parsers are attack surface: they run on untrusted input,
open files read-only, never execute anything from the source, never follow symlinks
out of the chosen directory, and are fuzzed against malformed fixtures.

**A malicious MCP client.** The optional local MCP server exposes your history to
local agents. It is off by default, binds loopback only, is read-only unless you
grant otherwise, exposes only the collections you tick, never exposes API keys, and
writes an audit line for every request.

**A prompt-injection payload in dictated or imported text.** Text that reaches an
enhancement model may contain instructions aimed at that model. Enhancement output
is only ever *text that gets inserted where you were typing*; it cannot invoke an
action. The Actions layer is driven by an explicit registry with typed inputs and a
confirmation step for anything destructive — a model cannot reach past the text
channel into the action channel.

## Explicit refusals

These are enforced in code and covered by tests:

1. Never read from or write into a secure text field (`AXSecureTextField`).
2. Never log transcript bodies, context bodies, or OCR text at default level.
3. Never write an API key anywhere except the Keychain.
4. Never send context to a remote party when "local context only" is set.
5. Never fall back to cloud when the user chose local-only.
6. Never modify, delete, or decrypt another application's data during migration.
7. Never execute a shell command or filesystem mutation from a voice command
   without an explicit, previewed confirmation.

## Out of scope

We do not defend against a compromised macOS, a kernel-level keylogger, physical
access to an unlocked machine, or a user who pastes their API key into a screenshot.
We also cannot defend you against the privacy policy of a cloud provider you choose;
we can only make choosing none of them viable.

## Reporting

See `SECURITY.md`.
