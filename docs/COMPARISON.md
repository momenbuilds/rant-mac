# Rant against the alternatives

The competitor audit in `docs/COMPETITOR_AUDIT.md` is the exhaustive version — 107
capability rows, every one resolved to MATCH, BEAT or INTENTIONALLY_SKIP. This is the
short version: what you actually get by choosing Rant, and what you give up.

## What you get that you cannot get elsewhere

**Your history can come with you.** The Migration Center imports from Wispr Flow,
VoiceInk, Superwhisper, Otter and seven generic transcript formats. It previews before
it writes, never touches the source, and re-running an import is a no-op. No other
product in this space will read a competitor's export.

**You can also leave.** The same archive format is used for export and import. Leaving
Rant is a supported operation with a test behind it, not an obstacle.

**Your coding agent can read your own dictation history.** The optional local MCP
server is loopback-only, read-only by default, per-collection consent, fully audited.
Claude Code can search what you have said. Nothing else does this.

**The privacy claims are checkable.** `docs/NETWORK_BEHAVIOR.md` enumerates every
request the app can make, and `scripts/check.sh` fails the build if a host appears in
the source that is not in that document. With no API key configured, Rant makes zero
network requests.

**Cleanup that works offline and costs nothing.** Three of the four cleanup levels are
deterministic Swift: punctuation, fillers, stutters, spoken commands, and
self-correction. They run in about a millisecond, behave identically with no network,
and are pinned by 29 tests.

**Both the raw and the cleaned text are kept.** Every other product shows you the
polished output and discards what you actually said. When cleanup drops a word that
mattered, Rant can still show you the original.

## What you give up

**No Windows, iOS or Android client.** Rant is macOS-first and the engine is a portable
Swift package, but shipping elsewhere now would halve the quality of the macOS
behaviour that is the entire point.

**No team administration, no SOC 2.** Both imply a server and an account. Rant has
neither, which is the design. The equivalent assurance here is auditable source and a
published threat model.

**No cloud sync.** Export an archive to move between machines.

**No notarised download yet.** Without a Developer ID certificate, builds are ad-hoc
signed and Gatekeeper will refuse them on another Mac. `docs/PACKAGING.md` says exactly
what is missing and the script uses a real identity the moment one exists.

**No auto-updater.** An updater that cannot verify signatures is a remote code
execution feature.

## The honest summary

If you want a polished product with a support team, a phone app and an invoice, buy
Wispr Flow. If you want the voice input layer you would still choose when the paid
ones were free — one you can read, change, audit, and walk away from with your data
intact — that is what this is.
