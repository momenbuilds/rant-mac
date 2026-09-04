import XCTest

@testable import RantCore

/// Insights runs against a real in-memory database, and the day-boundary tests run
/// against a fixed calendar rather than the machine's own. A streak bug that only
/// appears in one time zone, on one day of the year, is not one you find by running
/// the suite in London in June.
final class InsightsTests: XCTestCase {

  private func freshDatabase() throws -> Database {
    let database = try Database(url: nil)
    try Migrations.migrate(database)
    return database
  }

  private func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
  }

  /// Writes straight into the aggregate table, which is what the engine reads. Going
  /// through the store as well would be slower and would test the store.
  private func record(
    _ database: Database, day: String, words: Int, dictations: Int = 1, durationMs: Int = 60_000
  ) throws {
    try database.run(
      "INSERT INTO usage_daily (day, words, dictations, duration_ms) VALUES (?,?,?,?)",
      [.text(day), .int(words), .int(dictations), .int(durationMs)])
  }

  private func noon(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
  }

  // MARK: - Empty history

  func testAnEmptyHistoryProducesZeroesRatherThanACrash() throws {
    let engine = InsightsEngine(database: try freshDatabase())
    let summary = try engine.summary()
    XCTAssertEqual(summary, .empty)
    XCTAssertFalse(summary.averageWordsPerMinute.isNaN)
    XCTAssertEqual(try engine.usageByCategory(), [])
    XCTAssertEqual(try engine.latencyProfiles(), [])
  }

  func testAnEmptyHistoryStillProducesAFullChartSeries() throws {
    let engine = InsightsEngine(database: try freshDatabase())
    let series = try engine.dailySeries(days: 14)
    XCTAssertEqual(series.count, 14)
    XCTAssertTrue(series.allSatisfy { $0.words == 0 && $0.wordsPerMinute == 0 })
  }

  /// A day with words but a duration of zero must not divide by it.
  func testADayWithNoRecordedDurationDoesNotDivideByZero() throws {
    let database = try freshDatabase()
    let calendar = calendar("Europe/London")
    let now = noon(calendar, 2024, 6, 10)
    let engine = InsightsEngine(database: database, calendar: calendar)
    try record(database, day: "2024-06-10", words: 50, durationMs: 0)

    let summary = try engine.summary(asOf: now)
    XCTAssertEqual(summary.averageWordsPerMinute, 0)
    XCTAssertFalse(summary.averageWordsPerMinute.isNaN)
  }

  // MARK: - Totals

  func testTotalsComeFromTheDailyAggregates() throws {
    let database = try freshDatabase()
    let calendar = calendar("Europe/London")
    let engine = InsightsEngine(database: database, calendar: calendar)
    try record(database, day: "2024-06-08", words: 100, dictations: 2, durationMs: 60_000)
    try record(database, day: "2024-06-10", words: 40, dictations: 1, durationMs: 30_000)

    let summary = try engine.summary(asOf: noon(calendar, 2024, 6, 10))
    XCTAssertEqual(summary.totalWords, 140)
    XCTAssertEqual(summary.totalDictations, 3)
    XCTAssertEqual(summary.totalSpeakingSeconds, 90)
    XCTAssertEqual(summary.wordsToday, 40)
    XCTAssertEqual(summary.dictationsToday, 1)
    XCTAssertEqual(summary.activeDays, 2)
  }

  func testThisWeekIsTheTrailingSevenDaysAndExcludesWhatCameBefore() throws {
    let database = try freshDatabase()
    let calendar = calendar("Europe/London")
    let engine = InsightsEngine(database: database, calendar: calendar)
    try record(database, day: "2024-06-10", words: 10)  // today
    try record(database, day: "2024-06-04", words: 20)  // seventh day back
    try record(database, day: "2024-06-03", words: 500)  // one day too old

    let summary = try engine.summary(asOf: noon(calendar, 2024, 6, 10))
    XCTAssertEqual(summary.wordsThisWeek, 30)
    XCTAssertEqual(summary.totalWords, 530)
  }

  func testAverageWordsPerMinuteIsWordsOverSpeakingTime() throws {
    let database = try freshDatabase()
    let calendar = calendar("Europe/London")
    let engine = InsightsEngine(database: database, calendar: calendar)
    try record(database, day: "2024-06-10", words: 300, durationMs: 120_000)

    let summary = try engine.summary(asOf: noon(calendar, 2024, 6, 10))
    XCTAssertEqual(summary.averageWordsPerMinute, 150, accuracy: 0.001)
  }

  func testTheTrendComparesTheLastSevenDaysWithTheSevenBefore() throws {
    let database = try freshDatabase()
    let calendar = calendar("Europe/London")
    let engine = InsightsEngine(database: database, calendar: calendar)
    // Recent week: 120 wpm. Week before: 100 wpm.
    try record(database, day: "2024-06-10", words: 120, durationMs: 60_000)
    try record(database, day: "2024-06-01", words: 100, durationMs: 60_000)

    let summary = try engine.summary(asOf: noon(calendar, 2024, 6, 10))
    XCTAssertEqual(summary.recentWordsPerMinute, 120, accuracy: 0.001)
    XCTAssertEqual(summary.wordsPerMinuteTrend, 20, accuracy: 0.001)
  }

  /// A first week has nothing to be a trend against, and reporting "+120 wpm" for it
  /// is a lie dressed as encouragement.
  func testTheTrendStaysAtZeroUntilBothWindowsHaveData() throws {
    let database = try freshDatabase()
    let calendar = calendar("Europe/London")
    let engine = InsightsEngine(database: database, calendar: calendar)
    try record(database, day: "2024-06-10", words: 120, durationMs: 60_000)

    let summary = try engine.summary(asOf: noon(calendar, 2024, 6, 10))
    XCTAssertEqual(summary.wordsPerMinuteTrend, 0)
  }

  // MARK: - Time saved

  func testTimeSavedUsesTheStatedTypingSpeed() {
    // 400 words at 40 wpm is ten minutes of typing; five minutes were spent speaking.
    XCTAssertEqual(InsightsEngine.timeSaved(words: 400, speakingSeconds: 300), 300, accuracy: 0.001)
    XCTAssertEqual(InsightsEngine.assumedTypingWordsPerMinute, 40)
  }

  func testTimeSavedIsNeverNegative() {
    XCTAssertEqual(InsightsEngine.timeSaved(words: 10, speakingSeconds: 600), 0)
    XCTAssertEqual(InsightsEngine.timeSaved(words: 0, speakingSeconds: 0), 0)
  }

  // MARK: - Streaks

  func testConsecutiveDaysCountAsAStreak() throws {
    let calendar = calendar("Europe/London")
    let engine = InsightsEngine(database: try freshDatabase(), calendar: calendar)
    let streaks = engine.streaks(
      in: ["2024-06-08", "2024-06-09", "2024-06-10"], asOf: noon(calendar, 2024, 6, 10))
    XCTAssertEqual(streaks.current, 3)
    XCTAssertEqual(streaks.longest, 3)
  }

  func testAStreakSurvivesAMonthBoundary() throws {
    let calendar = calendar("Europe/London")
    let engine = InsightsEngine(database: try freshDatabase(), calendar: calendar)
    let streaks = engine.streaks(
      in: ["2024-01-30", "2024-01-31", "2024-02-01", "2024-02-02"],
      asOf: noon(calendar, 2024, 2, 2))
    XCTAssertEqual(streaks.current, 4, "the 31st and the 1st are consecutive days")
  }

  func testAStreakSurvivesALeapDay() throws {
    let calendar = calendar("Europe/London")
    let engine = InsightsEngine(database: try freshDatabase(), calendar: calendar)
    let streaks = engine.streaks(
      in: ["2024-02-28", "2024-02-29", "2024-03-01"], asOf: noon(calendar, 2024, 3, 1))
    XCTAssertEqual(streaks.current, 3)
  }

  /// The clocks go forward in London at 01:00 on 31 March 2024, so that day is 23
  /// hours long. Subtracting 86,400 seconds lands on the 29th and loses the streak.
  func testAStreakSurvivesASpringForward() throws {
    let calendar = calendar("Europe/London")
    let engine = InsightsEngine(database: try freshDatabase(), calendar: calendar)
    let streaks = engine.streaks(
      in: ["2024-03-29", "2024-03-30", "2024-03-31", "2024-04-01"],
      asOf: noon(calendar, 2024, 4, 1))
    XCTAssertEqual(streaks.current, 4, "a 23-hour day is still one day")
  }

  func testAStreakSurvivesAnAutumnFallBack() throws {
    let calendar = calendar("Europe/London")
    let engine = InsightsEngine(database: try freshDatabase(), calendar: calendar)
    let streaks = engine.streaks(
      in: ["2024-10-26", "2024-10-27", "2024-10-28"], asOf: noon(calendar, 2024, 10, 28))
    XCTAssertEqual(streaks.current, 3, "a 25-hour day is still one day")
  }

  /// São Paulo used to spring forward at midnight, so 4 November 2018 had no 00:00 at
  /// all. Anchoring a day at its start there yields the wrong day.
  func testAStreakSurvivesAZoneWhereMidnightDoesNotExist() throws {
    let calendar = calendar("America/Sao_Paulo")
    let engine = InsightsEngine(database: try freshDatabase(), calendar: calendar)
    let streaks = engine.streaks(
      in: ["2018-11-03", "2018-11-04", "2018-11-05"], asOf: noon(calendar, 2018, 11, 5))
    XCTAssertEqual(streaks.current, 3)
  }

  func testAMissedDayBreaksTheStreakButNotTheRecord() throws {
    let calendar = calendar("Europe/London")
    let engine = InsightsEngine(database: try freshDatabase(), calendar: calendar)
    let streaks = engine.streaks(
      in: ["2024-06-01", "2024-06-02", "2024-06-03", "2024-06-09", "2024-06-10"],
      asOf: noon(calendar, 2024, 6, 10))
    XCTAssertEqual(streaks.current, 2)
    XCTAssertEqual(streaks.longest, 3)
  }

  /// The day is not over. A streak should not be reported as broken at 09:00 because
  /// you have not dictated yet.
  func testAStreakEndingYesterdayIsStillCurrentToday() throws {
    let calendar = calendar("Europe/London")
    let engine = InsightsEngine(database: try freshDatabase(), calendar: calendar)
    let streaks = engine.streaks(
      in: ["2024-06-08", "2024-06-09"], asOf: noon(calendar, 2024, 6, 10))
    XCTAssertEqual(streaks.current, 2)
  }

  func testAStreakThatEndedTwoDaysAgoIsNoLongerCurrent() throws {
    let calendar = calendar("Europe/London")
    let engine = InsightsEngine(database: try freshDatabase(), calendar: calendar)
    let streaks = engine.streaks(
      in: ["2024-06-07", "2024-06-08"], asOf: noon(calendar, 2024, 6, 10))
    XCTAssertEqual(streaks.current, 0)
    XCTAssertEqual(streaks.longest, 2)
  }

  func testASingleDayIsAStreakOfOne() throws {
    let calendar = calendar("Europe/London")
    let engine = InsightsEngine(database: try freshDatabase(), calendar: calendar)
    let streaks = engine.streaks(in: ["2024-06-10"], asOf: noon(calendar, 2024, 6, 10))
    XCTAssertEqual(streaks.current, 1)
    XCTAssertEqual(streaks.longest, 1)
  }

  func testDaysWithNoDictationsDoNotCountTowardsAStreak() throws {
    let database = try freshDatabase()
    let calendar = calendar("Europe/London")
    let engine = InsightsEngine(database: database, calendar: calendar)
    try record(database, day: "2024-06-09", words: 0, dictations: 0, durationMs: 0)
    try record(database, day: "2024-06-10", words: 10)

    let summary = try engine.summary(asOf: noon(calendar, 2024, 6, 10))
    XCTAssertEqual(summary.currentStreakDays, 1)
    XCTAssertEqual(summary.activeDays, 1)
  }

  // MARK: - Series

  func testTheDailySeriesIsOldestFirstAndFillsInQuietDays() throws {
    let database = try freshDatabase()
    let calendar = calendar("Europe/London")
    let engine = InsightsEngine(database: database, calendar: calendar)
    try record(database, day: "2024-06-08", words: 60, durationMs: 60_000)
    try record(database, day: "2024-06-10", words: 30, durationMs: 60_000)

    let series = try engine.dailySeries(days: 3, asOf: noon(calendar, 2024, 6, 10))
    XCTAssertEqual(series.map(\.day), ["2024-06-08", "2024-06-09", "2024-06-10"])
    XCTAssertEqual(series.map(\.words), [60, 0, 30])
    XCTAssertEqual(series[0].wordsPerMinute, 60, accuracy: 0.001)
    XCTAssertEqual(series[1].wordsPerMinute, 0)
  }

  func testTheDailySeriesCrossesAMonthBoundaryWithoutGaps() throws {
    let calendar = calendar("Europe/London")
    let engine = InsightsEngine(database: try freshDatabase(), calendar: calendar)
    let series = try engine.dailySeries(days: 3, asOf: noon(calendar, 2024, 3, 1))
    XCTAssertEqual(series.map(\.day), ["2024-02-28", "2024-02-29", "2024-03-01"])
  }

  func testTheDailySeriesCrossesADaylightSavingChangeWithoutRepeatingADay() throws {
    let calendar = calendar("Europe/London")
    let engine = InsightsEngine(database: try freshDatabase(), calendar: calendar)
    let series = try engine.dailySeries(days: 4, asOf: noon(calendar, 2024, 4, 1))
    XCTAssertEqual(series.map(\.day), ["2024-03-29", "2024-03-30", "2024-03-31", "2024-04-01"])
    XCTAssertEqual(Set(series.map(\.day)).count, 4)
  }

  // MARK: - Categories

  func testUsageByCategoryIsLargestFirstAndItsSharesSumToOne() throws {
    let database = try freshDatabase()
    let engine = InsightsEngine(database: database)
    for (day, category, words) in [
      ("2024-06-10", "developer", 60), ("2024-06-10", "email", 30), ("2024-06-09", "email", 10),
    ] {
      try database.run(
        "INSERT INTO app_usage (day, category, words) VALUES (?,?,?)",
        [.text(day), .text(category), .int(words)])
    }

    let usage = try engine.usageByCategory()
    XCTAssertEqual(usage.map(\.category), [.developer, .email])
    XCTAssertEqual(usage.map(\.words), [60, 40])
    XCTAssertEqual(usage.map(\.share).reduce(0, +), 1, accuracy: 0.0001)
  }

  /// An unrecognised category from an import falls back to `.other`, and a real
  /// `.other` row may already exist. Two rows for one category would break the shares.
  func testAnUnknownCategoryIsMergedIntoOtherRatherThanDuplicated() throws {
    let database = try freshDatabase()
    let engine = InsightsEngine(database: database)
    try database.run(
      "INSERT INTO app_usage (day, category, words) VALUES ('2024-06-10','other',10)")
    try database.run(
      "INSERT INTO app_usage (day, category, words) VALUES ('2024-06-10','from_another_app',5)")

    let usage = try engine.usageByCategory()
    XCTAssertEqual(usage.count, 1)
    XCTAssertEqual(usage[0].words, 15)
    XCTAssertEqual(usage[0].share, 1, accuracy: 0.0001)
  }

  // MARK: - Latency

  func testNearestRankPercentiles() {
    let sorted = Array(1...100)
    XCTAssertEqual(InsightsEngine.percentile(sorted, 0.5), 50)
    XCTAssertEqual(InsightsEngine.percentile(sorted, 0.9), 90)
    XCTAssertEqual(InsightsEngine.percentile(sorted, 0.99), 99)
    XCTAssertEqual(InsightsEngine.percentile([7], 0.99), 7)
    XCTAssertEqual(InsightsEngine.percentile([], 0.5), 0)
  }

  func testLatencyIsReportedPerProviderAndStage() throws {
    let database = try freshDatabase()
    let store = SQLiteTranscriptStore(database: database)
    let engine = InsightsEngine(database: database)

    func sample(_ provider: String, _ at: Double, _ stage: String, _ values: [Int]) throws {
      let saved = try store.save(
        Transcript(
          createdAt: Date(timeIntervalSince1970: at), rawText: "r", finalText: "one two",
          provider: provider, durationMilliseconds: 1_000))
      for value in values {
        try database.run(
          "INSERT INTO latency_samples (transcript_id, stage, milliseconds) VALUES (?,?,?)",
          [.int(Int(saved.id!)), .text(stage), .int(value)])
      }
    }
    try sample("whisper", 1, "transcribe", [100, 900])
    try sample("whisper", 2, "transcribe", [200])
    try sample("assemblyai", 3, "transcribe", [50])

    let profiles = try engine.latencyProfiles()
    XCTAssertEqual(profiles.count, 2)
    let whisper = try XCTUnwrap(profiles.first { $0.provider == "whisper" })
    XCTAssertEqual(whisper.stage, "transcribe")
    XCTAssertEqual(whisper.sampleCount, 3)
    XCTAssertEqual(whisper.p50, 200)
    XCTAssertEqual(whisper.p90, 900, "the tail is the part anybody notices")
    XCTAssertEqual(profiles.first { $0.provider == "assemblyai" }?.p50, 50)
  }

  // MARK: - End to end

  /// This one deliberately uses the machine's own time zone, because the store writes
  /// its day strings in local time and the engine has to read them back in the same
  /// zone. Pinning a zone here would hide a mismatch between the two.
  func testInsightsAgreeWithWhatWasActuallySaved() throws {
    let database = try freshDatabase()
    let store = SQLiteTranscriptStore(database: database)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let engine = InsightsEngine(database: database)
    let today = Date(timeIntervalSince1970: 1_718_020_800)

    _ = try store.save(
      Transcript(
        createdAt: today, rawText: "um one two three", finalText: "one two three",
        provider: "test", category: .developer, durationMilliseconds: 60_000))
    _ = try store.save(
      Transcript(
        createdAt: calendar.date(byAdding: .day, value: -1, to: today)!, rawText: "r",
        finalText: "four five", provider: "test", category: .email,
        durationMilliseconds: 60_000))

    let summary = try engine.summary(asOf: today)
    XCTAssertEqual(summary.totalWords, 5)
    XCTAssertEqual(summary.totalDictations, 2)
    XCTAssertEqual(summary.wordsToday, 3)
    XCTAssertEqual(summary.currentStreakDays, 2)
    XCTAssertEqual(try engine.usageByCategory().map(\.category), [.developer, .email])
  }

  // MARK: - Voice profile

  private func saved(
    _ database: Database, raw: String, final: String, provider: String = "test",
    language: String? = "en", level: CleanupLevel = .medium, bundle: String? = nil,
    app: String? = nil, category: UsageCategory = .other, at: Double, durationMs: Int = 60_000
  ) throws {
    _ = try SQLiteTranscriptStore(database: database).save(
      Transcript(
        createdAt: Date(timeIntervalSince1970: at), rawText: raw, finalText: final,
        provider: provider, language: language, cleanupLevel: level, appBundleID: bundle,
        appName: app, category: category, durationMilliseconds: durationMs))
  }

  func testAnEmptyHistoryGivesAnEmptyVoiceProfile() throws {
    let profile = try VoiceProfileBuilder(database: try freshDatabase()).build()
    XCTAssertEqual(profile, .empty)
    XCTAssertEqual(profile.averageWordsPerMinute, 0)
    XCTAssertEqual(profile.fillersPerHundredWords, 0)
  }

  /// Cleanup strips the fillers before anything else sees them, so a profile built
  /// from the final text would report that nobody says "um".
  func testFillersAreCountedInTheRawTranscriptNotTheCleanedOne() throws {
    let database = try freshDatabase()
    try saved(database, raw: "um so uh the plan is uh ready", final: "The plan is ready.", at: 1)
    let profile = try VoiceProfileBuilder(database: database).build()

    XCTAssertEqual(profile.fillerWords.first?.term, "uh")
    XCTAssertEqual(profile.fillerWords.first?.count, 2)
    XCTAssertTrue(profile.fillerWords.contains { $0.term == "um" })
    // Three fillers in eight spoken tokens.
    XCTAssertEqual(profile.fillersPerHundredWords, 3.0 / 8.0 * 100, accuracy: 0.001)
  }

  func testVocabularyLeavesOutTheFunctionWordsThatWouldOtherwiseWinEveryTime() throws {
    let database = try freshDatabase()
    try saved(
      database, raw: "r",
      final: "the migration is the thing and the migration matters to the migration", at: 1)
    let profile = try VoiceProfileBuilder(database: database).build()

    XCTAssertEqual(profile.vocabulary.first?.term, "migration")
    XCTAssertEqual(profile.vocabulary.first?.count, 3)
    XCTAssertFalse(profile.vocabulary.contains { $0.term == "the" })
    XCTAssertFalse(profile.vocabulary.contains { $0.term == "is" })
  }

  func testContractionsSurviveTokenisingButQuotesDoNot() {
    var counts: [String: Int] = [:]
    VoiceProfileBuilder.tallyVocabulary("‘don’t’ worry, it doesn't matter — really", into: &counts)
    XCTAssertEqual(counts["don't"], 1)
    XCTAssertEqual(counts["doesn't"], 1)
    XCTAssertEqual(counts["really"], 1)
    XCTAssertNil(counts["'don't'"])
  }

  /// The tokeniser is a character loop precisely so that a pathological input cannot
  /// backtrack. A second of budget for a megabyte is generous and still catches a
  /// return to a regular expression.
  func testTokenisingAPathologicalStringFinishesPromptly() {
    let text = String(repeating: "aaaaaaaaaa'''''   ", count: 60_000)
    let started = Date()
    var counts: [String: Int] = [:]
    VoiceProfileBuilder.tallyVocabulary(text, into: &counts)
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    XCTAssertEqual(counts["aaaaaaaaaa"], 60_000)
  }

  func testTheProfileReportsTheSpeakingRateThatWasActuallyRecorded() throws {
    let database = try freshDatabase()
    try saved(database, raw: "r", final: "one two three four", at: 1, durationMs: 60_000)
    try saved(database, raw: "r", final: "five six", at: 2, durationMs: 60_000)
    let profile = try VoiceProfileBuilder(database: database).build()

    XCTAssertEqual(profile.sampleSize, 2)
    XCTAssertEqual(profile.averageWordsPerMinute, 3, accuracy: 0.001)
    XCTAssertEqual(profile.medianWordsPerMinute, 3, accuracy: 0.001)
  }

  func testThePreferredCleanupLevelIsTheOneActuallyUsedMost() throws {
    let database = try freshDatabase()
    try saved(database, raw: "r", final: "a b", level: .light, at: 1)
    try saved(database, raw: "r", final: "c d", level: .none, at: 2)
    try saved(database, raw: "r", final: "e f", level: .none, at: 3)
    let profile = try VoiceProfileBuilder(database: database).build()
    XCTAssertEqual(profile.preferredCleanupLevel, CleanupLevel.none)
  }

  func testLanguagesAreListedByHowOftenTheyWereSeen() throws {
    let database = try freshDatabase()
    try saved(database, raw: "r", final: "a b", language: "en", at: 1)
    try saved(database, raw: "r", final: "c d", language: "de", at: 2)
    try saved(database, raw: "r", final: "e f", language: "de", at: 3)
    let profile = try VoiceProfileBuilder(database: database).build()
    XCTAssertEqual(profile.languages.map(\.term), ["de", "en"])
    XCTAssertEqual(profile.languages.first?.count, 2)
  }

  func testPerAppStyleSeparatesShortMessagesFromLongDocuments() throws {
    let database = try freshDatabase()
    try saved(
      database, raw: "r", final: "ok", bundle: "com.tinyspeck.slack", app: "Slack",
      category: .work, at: 1)
    try saved(
      database, raw: "r", final: "sounds good", bundle: "com.tinyspeck.slack", app: "Slack",
      category: .work, at: 2)
    try saved(
      database, raw: "r",
      final: String(repeating: "word ", count: 200), bundle: "com.apple.Pages", app: "Pages",
      category: .documents, at: 3)

    let styles = try VoiceProfileBuilder(database: database).build().appStyles
    XCTAssertEqual(styles.map(\.appName), ["Slack", "Pages"])
    XCTAssertEqual(styles[0].dictations, 2)
    XCTAssertEqual(styles[0].averageWords, 1.5, accuracy: 0.001)
    XCTAssertEqual(styles[0].dominantCategory, .work)
    XCTAssertEqual(styles[1].averageWords, 200, accuracy: 0.001)
    XCTAssertEqual(styles[1].dominantCategory, .documents)
  }

  func testFrequentlyCorrectedTermsComeFromWhatTheUserActuallyFixed() throws {
    let database = try freshDatabase()
    try saved(database, raw: "r", final: "a b", at: 1)
    for (spoken, written, occurrences) in [
      ("cube control", "kubectl", 9), ("post grease", "Postgres", 3), ("noise", "noise", 4),
    ] {
      try database.run(
        """
        INSERT INTO learning_candidates
          (observed_at, inserted_text, corrected_text, spoken, written, occurrences, status)
        VALUES (?,?,?,?,?,?,?)
        """,
        [
          SQLValue(Date()), .text(""), .text(""), .text(spoken), .text(written),
          .int(occurrences), .text(written == "noise" ? "rejected" : "pending"),
        ])
    }

    let corrections = try VoiceProfileBuilder(database: database).build().correctedTerms
    XCTAssertEqual(corrections.map(\.corrected), ["kubectl", "Postgres"])
    XCTAssertEqual(corrections.first?.occurrences, 9)
  }

  /// The profile describes how you dictate now, so it reads a bounded window rather
  /// than the whole history.
  func testTheProfileOnlyReadsTheRequestedWindowOfHistory() throws {
    let database = try freshDatabase()
    for index in 0..<5 {
      try saved(database, raw: "r", final: "row \(index)", at: Double(index))
    }
    let profile = try VoiceProfileBuilder(database: database).build(sampleSize: 2)
    XCTAssertEqual(profile.sampleSize, 2)
    XCTAssertEqual(profile.vocabulary.first?.term, "row")
    XCTAssertEqual(profile.vocabulary.first?.count, 2)
  }
}
