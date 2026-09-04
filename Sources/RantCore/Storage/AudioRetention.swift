import Foundation

/// How long Rant keeps the recorded audio of a dictation.
///
/// The default is `never`, and that is a stance rather than a shrug. The text is what
/// the feature is for; the audio is a recording of a room, it is the most sensitive
/// thing this app ever touches, and keeping it by default would mean every user who
/// never opened settings accumulated one. Anyone who wants playback, or wants to
/// re-run a transcription against a better model, can turn a window on knowingly.
public enum AudioRetentionPolicy: String, Codable, Sendable, CaseIterable {
  /// Discard the recording as soon as the transcript is saved.
  case never
  case oneDay
  case sevenDays
  case thirtyDays
  /// Keep until the user deletes the dictation.
  case forever

  public var displayName: String {
    switch self {
    case .never: "Don't keep audio"
    case .oneDay: "24 hours"
    case .sevenDays: "7 days"
    case .thirtyDays: "30 days"
    case .forever: "Keep until I delete it"
    }
  }

  /// How old audio may get, in seconds. Nil for `forever`, zero for `never`.
  public var maximumAge: TimeInterval? {
    switch self {
    case .never: 0
    case .oneDay: 24 * 60 * 60
    case .sevenDays: 7 * 24 * 60 * 60
    case .thirtyDays: 30 * 24 * 60 * 60
    case .forever: nil
    }
  }
}

/// What a sweep did. Every count is a separate field because "12 deleted" and
/// "12 rows cleared, 3 files already gone" are different stories, and the second one
/// is the one worth investigating.
public struct AudioSweepResult: Equatable, Sendable {
  /// Files actually removed from disk.
  public var filesDeleted = 0
  /// Rows whose `audio_path` was set back to NULL.
  public var rowsCleared = 0
  /// Rows pointing at a file that was no longer there. Not an error: the user may have
  /// emptied the folder themselves, and the row still needs clearing.
  public var filesMissing = 0
  /// Paths outside the managed directory, which are left strictly alone.
  public var refused = 0
  /// Files that exist and could not be removed — a permissions problem, usually.
  public var failed = 0

  public var isEmpty: Bool {
    filesDeleted == 0 && rowsCleared == 0 && filesMissing == 0 && refused == 0 && failed == 0
  }
}

/// Deletes retained audio once the policy says it has expired.
///
/// Three properties this has to have, in order of how badly they end if missing:
///
/// 1. **It never deletes outside its own directory.** `audio_path` is a string in a
///    database that has survived imports from other apps and hand edits in `sqlite3`.
///    A row saying `/Users/me/Documents` must be skipped, not honoured. Every path is
///    resolved and checked against the managed directory before `removeItem` is
///    called, and a path that fails the check is counted and left.
/// 2. **One bad file cannot stop the sweep.** A missing file, or one the sandbox will
///    not let go of, is recorded and the loop moves on. The alternative is that a
///    single stale row keeps a month of expired recordings on disk indefinitely,
///    which is the exact failure the retention policy exists to prevent.
/// 3. **It is idempotent.** Clearing `audio_path` is what makes the second run a
///    no-op; the file deletion and the column update are ordered so a crash between
///    them leaves a row pointing at a file that is gone, which the next sweep tidies.
public struct AudioRetention: Sendable {
  private let store: SQLiteTranscriptStore
  /// The only directory this type will ever delete from.
  public let directory: URL
  private let log = RantLog("AudioRetention")

  public init(store: SQLiteTranscriptStore, directory: URL) {
    self.store = store
    self.directory = directory.standardizedFileURL
  }

  /// Removes audio that `policy` no longer allows.
  ///
  /// `now` is a parameter so the tests can age a file by a month without waiting.
  @discardableResult
  public func sweep(policy: AudioRetentionPolicy, now: Date = Date()) throws -> AudioSweepResult {
    guard let maximumAge = policy.maximumAge else { return AudioSweepResult() }
    // `never` gives an age of zero, which makes the cutoff `now`: everything with a
    // recording is expired the moment the transcript is saved. That falls out of the
    // same comparison rather than needing a branch of its own.
    let cutoff = now.addingTimeInterval(-maximumAge)

    var result = AudioSweepResult()
    for transcript in try store.transcriptsWithAudio(olderThan: cutoff) {
      guard let id = transcript.id, let path = transcript.audioPath else { continue }
      switch discard(path: path) {
      case .deleted: result.filesDeleted += 1
      case .missing: result.filesMissing += 1
      case .refused:
        result.refused += 1
        // The row keeps its path. Clearing it would lose the user's only pointer to a
        // file Rant has decided it may not touch.
        continue
      case .failed:
        result.failed += 1
        continue
      }
      try store.clearAudioPath(id: id)
      result.rowsCleared += 1
    }

    if !result.isEmpty {
      log.info(
        "audio sweep: \(result.filesDeleted) deleted, \(result.rowsCleared) rows cleared, "
          + "\(result.filesMissing) missing, \(result.refused) refused, \(result.failed) failed")
    }
    return result
  }

  /// Deletes the audio for one dictation and clears its row.
  ///
  /// Called on its own when the user deletes a transcript, so the history view can
  /// offer to take the recording with it. Returns whether anything was on disk, which
  /// is what lets the caller decide whether the offer is worth making at all.
  @discardableResult
  public func discardAudio(for transcript: Transcript) throws -> Bool {
    guard let path = transcript.audioPath else { return false }
    let outcome = discard(path: path)
    guard outcome != .refused, outcome != .failed else { return false }
    if let id = transcript.id { try store.clearAudioPath(id: id) }
    return outcome == .deleted
  }

  /// True when this dictation still has a recording on disk, so the delete prompt can
  /// say so rather than guessing.
  public func hasAudioOnDisk(_ transcript: Transcript) -> Bool {
    guard let path = transcript.audioPath, let url = managedURL(for: path) else { return false }
    return FileManager.default.fileExists(atPath: url.path)
  }

  // MARK: - Deleting

  enum Outcome: Equatable {
    case deleted
    case missing
    case refused
    case failed
  }

  func discard(path: String) -> Outcome {
    guard let url = managedURL(for: path) else {
      log.warning("refusing to delete audio outside the managed directory")
      return .refused
    }
    guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
    do {
      try FileManager.default.removeItem(at: url)
      return .deleted
    } catch {
      log.error("could not delete an audio file: \(error.localizedDescription)")
      return .failed
    }
  }

  /// The URL to delete, or nil when the path is not one of ours.
  ///
  /// Both sides are resolved before comparing, so a symlink pointing out of the
  /// directory, a `..` segment, and `/tmp` against its real `/private/tmp` all reach
  /// the same answer. The comparison is on path *components*, not on a string prefix:
  /// `/Rant/Audio-old/x.wav` starts with `/Rant/Audio` as text, and a prefix check
  /// would happily delete it.
  func managedURL(for path: String) -> URL? {
    guard !path.isEmpty else { return nil }
    let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    let root = directory.resolvingSymlinksInPath().standardizedFileURL

    let candidateParts = candidate.pathComponents
    let rootParts = root.pathComponents
    guard candidateParts.count > rootParts.count else { return nil }
    guard Array(candidateParts.prefix(rootParts.count)) == rootParts else { return nil }
    return candidate
  }
}
