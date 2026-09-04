# Data model

Everything Rant knows about you is in one SQLite file:

```
~/Library/Application Support/Rant/rant.sqlite
```

WAL mode, foreign keys on, schema versioned by `PRAGMA user_version`. You can open it
right now with the `sqlite3` shell and read every row. That is deliberate: a
local-first claim you cannot inspect is a marketing claim.

```bash
sqlite3 ~/Library/Application\ Support/Rant/rant.sqlite '.schema'
sqlite3 ~/Library/Application\ Support/Rant/rant.sqlite \
  'SELECT created_at, final_text FROM transcripts ORDER BY created_at DESC LIMIT 5;'
```

## Migrations

`Sources/RantCore/Storage/Migrations.swift` holds an ordered list of versioned steps,
each applied in its own transaction. Three rules:

1. **Append only.** A step that has shipped is never edited — someone's database has
   already run it. Fixing a mistake means adding a new step.
2. **Every prefix must work.** `StoreTests` applies steps 1…n for every n, and
   separately compares a stepwise upgrade against a direct one. A migration that only
   works when run after a later one cannot ship.
3. **Versions are 1…n with no gaps.** Asserted by a test.

| Version | Name | Adds |
|---|---|---|
| 1 | core dictation | `transcripts`, `latency_samples` |
| 2 | full text search | `transcripts_fts` + sync triggers |
| 3 | vocabulary | `dictionary_entries`, `snippets`, `styles`, `modes` |
| 4 | meetings | `meetings`, `meeting_segments`, `meetings_fts` |
| 5 | notes and usage | `notes`, `notes_fts`, `usage_daily`, `app_usage` |
| 6 | migration audit | `migration_runs`, `migration_items` |
| 7 | learned corrections | `learning_candidates`, `mcp_audit` |

## Tables

### `transcripts`

One completed dictation.

| Column | Why it exists |
|---|---|
| `raw_text` | what the model heard, verbatim |
| `final_text` | what was actually inserted |
| `content_hash` | SHA-256 over source + rounded timestamp + normalised text |
| `source` | `rant`, or `wispr_flow` / `voiceink` / … after an import |
| `audio_path` | null unless you turned retention on |
| `word_count`, `words_per_minute`, `duration_ms` | derived once, so Insights never recomputes |

**Both texts are always kept.** Cleanup is a lossy transform and the input is worth
having when it drops a word that mattered — see `docs/DECISIONS.md` D-004.

**`content_hash` is the deduplication key**, with a `UNIQUE` index behind it. The
timestamp is rounded to the second because exports round-trip through formats with
different precision and a millisecond of drift must not create a duplicate. This is
what makes importing the same archive twice a no-op — and the uniqueness lives in the
schema, so even a buggy migration adapter cannot create duplicates.

### `latency_samples`

Per-stage timings, keyed to a transcript with `ON DELETE CASCADE`. Separate from the
transcript because it is diagnostic noise most people never look at, and because it
should be deletable on its own.

### `transcripts_fts`, `meetings_fts`, `notes_fts`

FTS5 external-content indexes with `unicode61 remove_diacritics 2`, kept in step by
`AFTER INSERT/UPDATE/DELETE` triggers rather than by application code — so deleting a
transcript really does remove it from search, which `StoreTests` asserts.

User input never reaches FTS5 as a raw query. `SQLiteTranscriptStore.ftsQuery` reduces
it to quoted prefix terms joined with `AND`; anything non-alphanumeric is dropped
rather than escaped, because no useful search needs it and every one of them is a way
to write a query that errors.

### `usage_daily`, `app_usage`

Pre-aggregated per day (`yyyy-MM-dd`, local time) so Insights is O(days) rather than
O(transcripts). Written inside the same transaction as the transcript, and **only for
a row that was genuinely new** — `INSERT OR IGNORE` looks like success from outside,
so a duplicate import would otherwise inflate your word count.

`deleteAll()` clears these too. "Delete everything" that leaves your word count on the
Insights screen is not deleting everything.

### `dictionary_entries`, `snippets`, `styles`, `modes`

Your vocabulary. `dictionary_entries` is unique on `(spoken, kind)`, so the same word
can be both a replacement and a recognition hint — they do different jobs.
`modes.configuration` is a JSON blob because a mode's shape changes more often than
the schema should.

### `meetings`, `meeting_segments`

`channel` is `me` (microphone) or `them` (system audio) — the distinction the
notetaker can always make, as opposed to speaker diarisation, which depends on the
provider. Segments cascade on meeting deletion.

### `migration_runs`, `migration_items`

What was imported, when, from where, and what happened to each record. An import you
cannot inspect afterwards is an import you cannot trust.

### `learning_candidates`

Proposed dictionary rules observed from your corrections. Nothing here affects
transcription until you accept it.

### `mcp_audit`

One row per request served by the optional local MCP server. Off by default; when on,
you can see exactly what was asked for.

## What is *not* stored

- **Context.** App name, window title, field label, selection, clipboard and OCR text
  live in memory for the length of one dictation and are never written to disk.
- **API keys.** Keychain only.
- **Audio**, unless you turned retention on.
- **Anything on a server.** There is no server.

## Leaving

`Rant Archive` exports the whole database into documented, re-importable files:
`manifest.json`, `transcripts.jsonl`, `dictionary.json`, `snippets.json`, `notes/`,
`meetings/`. The same format is used for export and import, so leaving Rant is a
supported operation rather than an obstacle.
