import XCTest

@testable import RantCore

/// Retention is tested against real files in a real temporary directory. A stubbed
/// file manager would agree with whatever the code believes, and the entire point of
/// this type is what it does when the disk disagrees.
final class RetentionTests: XCTestCase {

  private var root: URL!
  private var audio: URL!
  private var database: Database!
  private var store: SQLiteTranscriptStore!
  private var retention: AudioRetention!

  override func setUpWithError() throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("rant-retention-\(UUID().uuidString)")
    audio = root.appendingPathComponent("Audio", isDirectory: true)
    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)

    database = try Database(url: nil)
    try Migrations.migrate(database)
    store = SQLiteTranscriptStore(database: database)
    retention = AudioRetention(store: store, directory: audio)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  @discardableResult
  private func recording(_ name: String) throws -> URL {
    let url = audio.appendingPathComponent(name)
    try Data("not really audio".utf8).write(to: url)
    return url
  }

  @discardableResult
  private func dictation(_ text: String, ageInDays: Double, audioPath: String?) throws
    -> Transcript
  {
    try store.save(
      Transcript(
        createdAt: Date().addingTimeInterval(-ageInDays * 24 * 60 * 60), rawText: "raw \(text)",
        finalText: text, provider: "test", durationMilliseconds: 1_000, audioPath: audioPath))
  }

  private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  private func storedPath(_ id: Int64) throws -> String? {
    try store.transcript(id: id)?.audioPath
  }

  // MARK: - Policy

  func testTheDefaultPolicyKeepsNoAudioAtAll() {
    XCTAssertEqual(AudioRetentionPolicy.never.maximumAge, 0)
    XCTAssertEqual(AudioRetentionPolicy.oneDay.maximumAge, 24 * 60 * 60)
    XCTAssertEqual(AudioRetentionPolicy.sevenDays.maximumAge, 7 * 24 * 60 * 60)
    XCTAssertEqual(AudioRetentionPolicy.thirtyDays.maximumAge, 30 * 24 * 60 * 60)
    XCTAssertNil(AudioRetentionPolicy.forever.maximumAge)
  }

  func testEveryPolicyHasAName() {
    for policy in AudioRetentionPolicy.allCases {
      XCTAssertFalse(policy.displayName.isEmpty)
    }
  }

  // MARK: - Sweeping

  func testNeverRemovesTheRecordingAsSoonAsItSweeps() throws {
    let file = try recording("a.wav")
    let saved = try dictation("hello", ageInDays: 0.001, audioPath: file.path)

    let result = try retention.sweep(policy: .never)
    XCTAssertEqual(result.filesDeleted, 1)
    XCTAssertEqual(result.rowsCleared, 1)
    XCTAssertFalse(exists(file))
    XCTAssertNil(try storedPath(saved.id!))
  }

  func testForeverLeavesEverythingWhereItIs() throws {
    let file = try recording("a.wav")
    let saved = try dictation("hello", ageInDays: 400, audioPath: file.path)

    let result = try retention.sweep(policy: .forever)
    XCTAssertTrue(result.isEmpty)
    XCTAssertTrue(exists(file))
    XCTAssertEqual(try storedPath(saved.id!), file.path)
  }

  func testAWindowKeepsWhatIsInsideItAndRemovesWhatIsNot() throws {
    let fresh = try recording("fresh.wav")
    let stale = try recording("stale.wav")
    let keep = try dictation("recent", ageInDays: 2, audioPath: fresh.path)
    let drop = try dictation("old", ageInDays: 9, audioPath: stale.path)

    let result = try retention.sweep(policy: .sevenDays)
    XCTAssertEqual(result.filesDeleted, 1)
    XCTAssertTrue(exists(fresh))
    XCTAssertFalse(exists(stale))
    XCTAssertEqual(try storedPath(keep.id!), fresh.path)
    XCTAssertNil(try storedPath(drop.id!))
  }

  func testTheBoundaryIsRespectedForEachWindow() throws {
    for (policy, ageInDays) in [
      (AudioRetentionPolicy.oneDay, 0.5), (.sevenDays, 6), (.thirtyDays, 29),
    ] {
      let file = try recording("\(policy.rawValue).wav")
      _ = try dictation("row \(policy.rawValue)", ageInDays: ageInDays, audioPath: file.path)
      try retention.sweep(policy: policy)
      XCTAssertTrue(exists(file), "\(policy.rawValue) deleted audio that was still inside it")
    }
  }

  /// The second run must be a no-op. If it is not, either the column is not being
  /// cleared or the sweep is finding rows it already dealt with.
  func testSweepingTwiceChangesNothingTheSecondTime() throws {
    let file = try recording("a.wav")
    _ = try dictation("hello", ageInDays: 10, audioPath: file.path)

    XCTAssertEqual(try retention.sweep(policy: .sevenDays).filesDeleted, 1)
    let second = try retention.sweep(policy: .sevenDays)
    XCTAssertTrue(second.isEmpty)
    XCTAssertFalse(exists(file))
  }

  /// A user who empties the folder by hand leaves rows pointing at nothing. The sweep
  /// still has to clear them, and it must not report a failure for each one.
  func testAMissingFileIsClearedRatherThanTreatedAsAnError() throws {
    let file = try recording("gone.wav")
    let saved = try dictation("hello", ageInDays: 10, audioPath: file.path)
    try FileManager.default.removeItem(at: file)

    let result = try retention.sweep(policy: .sevenDays)
    XCTAssertEqual(result.filesMissing, 1)
    XCTAssertEqual(result.filesDeleted, 0)
    XCTAssertEqual(result.failed, 0)
    XCTAssertEqual(result.rowsCleared, 1)
    XCTAssertNil(try storedPath(saved.id!))
  }

  /// One unreachable file must not strand a month of expired recordings on disk.
  func testOneUnusableRowDoesNotAbandonTheRestOfTheSweep() throws {
    let outside = root.appendingPathComponent("not-ours.wav")
    try Data("x".utf8).write(to: outside)
    let mine = try recording("mine.wav")
    _ = try dictation("first", ageInDays: 10, audioPath: outside.path)
    _ = try dictation("second", ageInDays: 10, audioPath: mine.path)

    let result = try retention.sweep(policy: .sevenDays)
    XCTAssertEqual(result.refused, 1)
    XCTAssertEqual(result.filesDeleted, 1)
    XCTAssertFalse(exists(mine))
    XCTAssertTrue(exists(outside))
  }

  // MARK: - Safety

  func testItRefusesEveryPathOutsideTheManagedDirectory() throws {
    let siblings = [
      root.appendingPathComponent("elsewhere.wav").path,
      audio.deletingLastPathComponent().appendingPathComponent("Audio-old/x.wav").path,
      audio.appendingPathComponent("../escape.wav").path,
      "/etc/hosts",
      "",
    ]
    for path in siblings {
      XCTAssertNil(retention.managedURL(for: path), "\(path) was treated as managed")
    }
  }

  /// A neighbouring directory whose name starts with the managed one's. A string
  /// prefix check passes this and deletes somebody else's files.
  func testASiblingDirectoryWithASharedPrefixIsNotManaged() throws {
    let sibling = root.appendingPathComponent("Audio-old", isDirectory: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    let file = sibling.appendingPathComponent("keep.wav")
    try Data("x".utf8).write(to: file)
    _ = try dictation("hello", ageInDays: 10, audioPath: file.path)

    let result = try retention.sweep(policy: .never)
    XCTAssertEqual(result.refused, 1)
    XCTAssertEqual(result.filesDeleted, 0)
    XCTAssertTrue(exists(file))
  }

  /// A refused path keeps its row. Clearing it would throw away the user's only
  /// pointer to a file Rant has decided it may not touch.
  func testARefusedRowKeepsItsPath() throws {
    let outside = root.appendingPathComponent("outside.wav")
    try Data("x".utf8).write(to: outside)
    let saved = try dictation("hello", ageInDays: 10, audioPath: outside.path)

    try retention.sweep(policy: .never)
    XCTAssertEqual(try storedPath(saved.id!), outside.path)
  }

  func testASymlinkPointingOutOfTheDirectoryIsRefused() throws {
    let target = root.appendingPathComponent("secret.wav")
    try Data("x".utf8).write(to: target)
    let link = audio.appendingPathComponent("link.wav")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    _ = try dictation("hello", ageInDays: 10, audioPath: link.path)

    let result = try retention.sweep(policy: .never)
    XCTAssertEqual(result.refused, 1)
    XCTAssertTrue(exists(target), "following a symlink out of the folder deleted the target")
  }

  func testAFileInASubfolderOfTheManagedDirectoryIsStillManaged() throws {
    let nested = audio.appendingPathComponent("2024-06", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let file = nested.appendingPathComponent("a.wav")
    try Data("x".utf8).write(to: file)
    _ = try dictation("hello", ageInDays: 10, audioPath: file.path)

    XCTAssertEqual(try retention.sweep(policy: .never).filesDeleted, 1)
    XCTAssertFalse(exists(file))
  }

  func testTheManagedDirectoryItselfIsNotADeletableTarget() {
    XCTAssertNil(retention.managedURL(for: audio.path))
    XCTAssertTrue(exists(audio))
  }

  // MARK: - Deleting one dictation

  func testDeletingADictationCanTakeItsAudioWithIt() throws {
    let file = try recording("a.wav")
    let saved = try dictation("hello", ageInDays: 1, audioPath: file.path)

    XCTAssertTrue(retention.hasAudioOnDisk(saved))
    XCTAssertTrue(try retention.discardAudio(for: saved))
    XCTAssertFalse(exists(file))
    XCTAssertNil(try storedPath(saved.id!))

    try store.delete(id: saved.id!)
    XCTAssertNil(try store.transcript(id: saved.id!))
  }

  func testDiscardingAudioForADictationThatHasNoneIsHarmless() throws {
    let saved = try dictation("hello", ageInDays: 1, audioPath: nil)
    XCTAssertFalse(retention.hasAudioOnDisk(saved))
    XCTAssertFalse(try retention.discardAudio(for: saved))
  }

  func testDiscardingRefusesToDeleteAudioOutsideTheManagedDirectory() throws {
    let outside = root.appendingPathComponent("outside.wav")
    try Data("x".utf8).write(to: outside)
    let saved = try dictation("hello", ageInDays: 1, audioPath: outside.path)

    XCTAssertFalse(retention.hasAudioOnDisk(saved))
    XCTAssertFalse(try retention.discardAudio(for: saved))
    XCTAssertTrue(exists(outside))
    XCTAssertEqual(try storedPath(saved.id!), outside.path)
  }

  func testDiscardingClearsTheRowEvenWhenTheFileHasAlreadyGone() throws {
    let file = try recording("a.wav")
    let saved = try dictation("hello", ageInDays: 1, audioPath: file.path)
    try FileManager.default.removeItem(at: file)

    XCTAssertFalse(try retention.discardAudio(for: saved), "nothing was on disk to delete")
    XCTAssertNil(try storedPath(saved.id!), "the dangling path must not be left behind")
  }

  // MARK: - Nothing to do

  func testASweepOverAnEmptyHistoryDoesNothing() throws {
    XCTAssertTrue(try retention.sweep(policy: .never).isEmpty)
  }

  func testRowsWithoutAudioAreNeverTouched() throws {
    _ = try dictation("no audio here", ageInDays: 100, audioPath: nil)
    XCTAssertTrue(try retention.sweep(policy: .never).isEmpty)
  }
}
