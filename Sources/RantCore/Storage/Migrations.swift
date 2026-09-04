import Foundation

/// The schema, as an ordered list of versioned steps.
///
/// Rules this file lives by:
///
/// - **Append only.** A step that has shipped is never edited, because someone's
///   database has already run it. Fixing a mistake means adding a new step.
/// - **Every prefix must work.** The test suite applies steps 1…n for every n, so a
///   migration that only works when run after a later one cannot ship.
/// - **The schema is the data-ownership guarantee.** Anyone can open `rant.sqlite`
///   in the `sqlite3` shell and read every row. That is deliberate. See
///   `docs/DATA_MODEL.md`.
public enum Migrations {

  public struct Step: Sendable {
    public let version: Int
    public let name: String
    public let sql: String
  }

  public static let all: [Step] = [
    Step(
      version: 1, name: "core dictation",
      sql: """
        CREATE TABLE transcripts (
          id                INTEGER PRIMARY KEY AUTOINCREMENT,
          created_at        REAL NOT NULL,
          -- Both texts are kept. Cleanup is a lossy transform, so we never throw the
          -- input away; see docs/DECISIONS.md D-004.
          raw_text          TEXT NOT NULL,
          final_text        TEXT NOT NULL,
          provider          TEXT NOT NULL,
          language          TEXT,
          cleanup_level     TEXT NOT NULL DEFAULT 'medium',
          mode              TEXT,
          style             TEXT,
          app_bundle_id     TEXT,
          app_name          TEXT,
          browser_host      TEXT,
          category          TEXT,
          duration_ms       INTEGER NOT NULL DEFAULT 0,
          word_count        INTEGER NOT NULL DEFAULT 0,
          words_per_minute  REAL,
          enhanced          INTEGER NOT NULL DEFAULT 0,
          audio_path        TEXT,
          -- Deterministic hash of the content, so re-importing the same export is a
          -- no-op rather than a duplicate. See MigrationAdapter.
          content_hash      TEXT NOT NULL,
          source            TEXT NOT NULL DEFAULT 'rant',
          source_id         TEXT,
          favourite         INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX idx_transcripts_created ON transcripts(created_at DESC);
        CREATE UNIQUE INDEX idx_transcripts_hash ON transcripts(content_hash);
        CREATE INDEX idx_transcripts_app ON transcripts(app_bundle_id);

        -- Per-stage latency, kept apart from the transcript because it is diagnostic
        -- noise that most users never look at and every user can delete separately.
        CREATE TABLE latency_samples (
          transcript_id     INTEGER NOT NULL REFERENCES transcripts(id) ON DELETE CASCADE,
          stage             TEXT NOT NULL,
          milliseconds      INTEGER NOT NULL
        );
        CREATE INDEX idx_latency_transcript ON latency_samples(transcript_id);
        """),

    Step(
      version: 2, name: "full text search",
      sql: """
        CREATE VIRTUAL TABLE transcripts_fts USING fts5(
          final_text, raw_text,
          content='transcripts', content_rowid='id',
          tokenize='unicode61 remove_diacritics 2'
        );
        -- Triggers keep the index honest without the application having to remember.
        CREATE TRIGGER transcripts_ai AFTER INSERT ON transcripts BEGIN
          INSERT INTO transcripts_fts(rowid, final_text, raw_text)
          VALUES (new.id, new.final_text, new.raw_text);
        END;
        CREATE TRIGGER transcripts_ad AFTER DELETE ON transcripts BEGIN
          INSERT INTO transcripts_fts(transcripts_fts, rowid, final_text, raw_text)
          VALUES ('delete', old.id, old.final_text, old.raw_text);
        END;
        CREATE TRIGGER transcripts_au AFTER UPDATE ON transcripts BEGIN
          INSERT INTO transcripts_fts(transcripts_fts, rowid, final_text, raw_text)
          VALUES ('delete', old.id, old.final_text, old.raw_text);
          INSERT INTO transcripts_fts(rowid, final_text, raw_text)
          VALUES (new.id, new.final_text, new.raw_text);
        END;
        """),

    Step(
      version: 3, name: "vocabulary",
      sql: """
        CREATE TABLE dictionary_entries (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          spoken        TEXT NOT NULL,
          written       TEXT NOT NULL,
          kind          TEXT NOT NULL DEFAULT 'replacement',
          category      TEXT,
          enabled       INTEGER NOT NULL DEFAULT 1,
          favourite     INTEGER NOT NULL DEFAULT 0,
          case_sensitive INTEGER NOT NULL DEFAULT 0,
          created_at    REAL NOT NULL,
          use_count     INTEGER NOT NULL DEFAULT 0,
          source        TEXT NOT NULL DEFAULT 'rant'
        );
        CREATE UNIQUE INDEX idx_dictionary_spoken ON dictionary_entries(spoken, kind);

        CREATE TABLE snippets (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          trigger       TEXT NOT NULL,
          expansion     TEXT NOT NULL,
          folder        TEXT,
          enabled       INTEGER NOT NULL DEFAULT 1,
          created_at    REAL NOT NULL,
          use_count     INTEGER NOT NULL DEFAULT 0,
          source        TEXT NOT NULL DEFAULT 'rant'
        );
        CREATE UNIQUE INDEX idx_snippets_trigger ON snippets(trigger);

        CREATE TABLE styles (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          name          TEXT NOT NULL UNIQUE,
          instructions  TEXT NOT NULL,
          category      TEXT,
          built_in      INTEGER NOT NULL DEFAULT 0,
          created_at    REAL NOT NULL
        );

        CREATE TABLE modes (
          id                INTEGER PRIMARY KEY AUTOINCREMENT,
          name              TEXT NOT NULL UNIQUE,
          configuration     TEXT NOT NULL,   -- JSON blob, versioned by the decoder
          built_in          INTEGER NOT NULL DEFAULT 0,
          created_at        REAL NOT NULL
        );
        """),

    Step(
      version: 4, name: "meetings",
      sql: """
        CREATE TABLE meetings (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          started_at    REAL NOT NULL,
          ended_at      REAL,
          title         TEXT,
          app_name      TEXT,
          calendar_event_id TEXT,
          summary       TEXT,
          action_items  TEXT,
          decisions     TEXT,
          audio_path    TEXT,
          content_hash  TEXT NOT NULL,
          source        TEXT NOT NULL DEFAULT 'rant'
        );
        CREATE UNIQUE INDEX idx_meetings_hash ON meetings(content_hash);
        CREATE INDEX idx_meetings_started ON meetings(started_at DESC);

        CREATE TABLE meeting_segments (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          meeting_id    INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
          started_ms    INTEGER NOT NULL,
          ended_ms      INTEGER,
          speaker       TEXT,
          -- 'me' for the microphone, 'them' for system audio. The distinction the
          -- notetaker can always make, as opposed to diarisation which it cannot.
          channel       TEXT NOT NULL DEFAULT 'me',
          text          TEXT NOT NULL
        );
        CREATE INDEX idx_segments_meeting ON meeting_segments(meeting_id, started_ms);

        CREATE VIRTUAL TABLE meetings_fts USING fts5(
          text, content='meeting_segments', content_rowid='id',
          tokenize='unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER meeting_segments_ai AFTER INSERT ON meeting_segments BEGIN
          INSERT INTO meetings_fts(rowid, text) VALUES (new.id, new.text);
        END;
        CREATE TRIGGER meeting_segments_ad AFTER DELETE ON meeting_segments BEGIN
          INSERT INTO meetings_fts(meetings_fts, rowid, text) VALUES ('delete', old.id, old.text);
        END;
        """),

    Step(
      version: 5, name: "notes and usage",
      sql: """
        CREATE TABLE notes (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          created_at    REAL NOT NULL,
          updated_at    REAL NOT NULL,
          title         TEXT NOT NULL DEFAULT '',
          body          TEXT NOT NULL DEFAULT '',
          pinned        INTEGER NOT NULL DEFAULT 0,
          tags          TEXT,
          content_hash  TEXT NOT NULL,
          source        TEXT NOT NULL DEFAULT 'rant'
        );
        CREATE UNIQUE INDEX idx_notes_hash ON notes(content_hash);

        CREATE VIRTUAL TABLE notes_fts USING fts5(
          title, body, content='notes', content_rowid='id',
          tokenize='unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER notes_ai AFTER INSERT ON notes BEGIN
          INSERT INTO notes_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
        END;
        CREATE TRIGGER notes_ad AFTER DELETE ON notes BEGIN
          INSERT INTO notes_fts(notes_fts, rowid, title, body)
          VALUES ('delete', old.id, old.title, old.body);
        END;
        CREATE TRIGGER notes_au AFTER UPDATE ON notes BEGIN
          INSERT INTO notes_fts(notes_fts, rowid, title, body)
          VALUES ('delete', old.id, old.title, old.body);
          INSERT INTO notes_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
        END;

        -- Pre-aggregated so the Insights screen never scans the whole history.
        CREATE TABLE usage_daily (
          day           TEXT PRIMARY KEY,     -- yyyy-MM-dd, local time
          words         INTEGER NOT NULL DEFAULT 0,
          dictations    INTEGER NOT NULL DEFAULT 0,
          duration_ms   INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE app_usage (
          day           TEXT NOT NULL,
          category      TEXT NOT NULL,
          words         INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (day, category)
        );
        """),

    Step(
      version: 6, name: "migration audit",
      sql: """
        -- What was imported, when, from where. An import you cannot inspect is an
        -- import you cannot trust.
        CREATE TABLE migration_runs (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          started_at    REAL NOT NULL,
          finished_at   REAL,
          source_name   TEXT NOT NULL,
          source_path   TEXT NOT NULL,
          imported      INTEGER NOT NULL DEFAULT 0,
          duplicates    INTEGER NOT NULL DEFAULT 0,
          skipped       INTEGER NOT NULL DEFAULT 0,
          failed        INTEGER NOT NULL DEFAULT 0,
          dry_run       INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE migration_items (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          run_id        INTEGER NOT NULL REFERENCES migration_runs(id) ON DELETE CASCADE,
          kind          TEXT NOT NULL,
          outcome       TEXT NOT NULL,
          detail        TEXT,
          source_ref    TEXT
        );
        CREATE INDEX idx_migration_items_run ON migration_items(run_id);
        """),

    Step(
      version: 7, name: "learned corrections",
      sql: """
        -- Proposed dictionary rules from observed corrections. Nothing here affects
        -- transcription until the user accepts it; see the opt-in learning feature.
        CREATE TABLE learning_candidates (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          observed_at   REAL NOT NULL,
          inserted_text TEXT NOT NULL,
          corrected_text TEXT NOT NULL,
          spoken        TEXT NOT NULL,
          written       TEXT NOT NULL,
          occurrences   INTEGER NOT NULL DEFAULT 1,
          status        TEXT NOT NULL DEFAULT 'pending',
          app_bundle_id TEXT
        );
        CREATE UNIQUE INDEX idx_learning_pair ON learning_candidates(spoken, written);

        -- Every request the optional local MCP server served. Off by default, but
        -- when it is on, the user can see exactly what was asked for.
        CREATE TABLE mcp_audit (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          at            REAL NOT NULL,
          tool          TEXT NOT NULL,
          arguments     TEXT,
          result_count  INTEGER NOT NULL DEFAULT 0,
          client        TEXT
        );
        """),

    Step(
      version: 8, name: "transcript tags",
      sql: """
        -- Per-dictation tags, which the specification asks for alongside favourites
        -- and which had no column. Comma-separated in one column rather than a join
        -- table: this is a personal label on a personal record, always read with the
        -- row it belongs to and never queried across, so a second table would cost a
        -- join on every history page to buy nothing.
        ALTER TABLE transcripts ADD COLUMN tags TEXT;
        """),
  ]

  public static var latestVersion: Int { all.map(\.version).max() ?? 0 }

  /// Applies every step newer than the database's current version, each in its own
  /// transaction so a failure leaves the database at the last version that worked
  /// rather than half-migrated.
  @discardableResult
  public static func migrate(_ database: Database, upTo target: Int? = nil) throws -> Int {
    let log = RantLog("Migrations")
    let ceiling = target ?? latestVersion
    var applied = database.userVersion

    for step in all.sorted(by: { $0.version < $1.version }) where step.version > applied {
      guard step.version <= ceiling else { break }
      do {
        try database.transaction {
          try database.execute(step.sql)
          try database.setUserVersion(step.version)
        }
        applied = step.version
        log.info("applied migration \(step.version) — \(step.name)")
      } catch {
        throw Database.StorageError.migrationFailed(
          version: step.version, message: error.localizedDescription)
      }
    }
    return applied
  }
}
