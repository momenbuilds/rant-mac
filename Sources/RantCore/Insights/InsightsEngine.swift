import Foundation

/// Everything the Insights screen shows, computed in one pass.
///
/// One value rather than a dozen accessors, because the screen renders a single
/// consistent picture: reading the totals and the streak from two separate queries
/// taken a second apart is how a "0 words today" ends up sitting next to a 12-day
/// streak.
public struct InsightsSummary: Equatable, Sendable {
  public var totalWords: Int
  public var totalDictations: Int
  /// Time spent actually speaking, summed from the recorded durations.
  public var totalSpeakingSeconds: Double
  public var wordsToday: Int
  public var dictationsToday: Int
  public var wordsThisWeek: Int
  public var dictationsThisWeek: Int
  /// Words per minute over the whole history. Zero when nothing has been dictated.
  public var averageWordsPerMinute: Double
  /// Words per minute over the trailing window used for the trend.
  public var recentWordsPerMinute: Double
  /// Recent rate minus the window before it. Positive means speeding up. Zero when
  /// there is not enough history on both sides to compare.
  public var wordsPerMinuteTrend: Double
  public var currentStreakDays: Int
  public var longestStreakDays: Int
  /// Days on which at least one dictation was saved.
  public var activeDays: Int
  /// Speaking time subtracted from the time the same words would have taken to type.
  /// Never negative — see `InsightsEngine.assumedTypingWordsPerMinute`.
  public var timeSavedSeconds: Double

  public static let empty = InsightsSummary(
    totalWords: 0, totalDictations: 0, totalSpeakingSeconds: 0, wordsToday: 0,
    dictationsToday: 0, wordsThisWeek: 0, dictationsThisWeek: 0, averageWordsPerMinute: 0,
    recentWordsPerMinute: 0, wordsPerMinuteTrend: 0, currentStreakDays: 0,
    longestStreakDays: 0, activeDays: 0, timeSavedSeconds: 0)
}

/// One day of a chart series. Days with no dictation are present with zeroes rather
/// than absent, so a chart shows the gap in the habit instead of quietly closing it up.
public struct DailyUsage: Equatable, Sendable {
  public var day: String
  public var date: Date
  public var words: Int
  public var dictations: Int
  public var durationMilliseconds: Int

  /// Zero for a day with no speech rather than nil: an axis has to plot something,
  /// and every other zero day is already drawn at the baseline.
  public var wordsPerMinute: Double {
    guard durationMilliseconds > 0, words > 0 else { return 0 }
    return Double(words) / (Double(durationMilliseconds) / 60_000)
  }
}

/// Words dictated into one kind of surface, with its share of the total.
public struct CategoryUsage: Equatable, Sendable {
  public var category: UsageCategory
  public var words: Int
  /// 0…1. Zero when nothing has been dictated, never NaN.
  public var share: Double
}

/// Latency percentiles for one provider and one pipeline stage.
public struct LatencyProfile: Equatable, Sendable {
  public var provider: String
  public var stage: String
  public var sampleCount: Int
  public var p50: Int
  public var p90: Int
  public var p99: Int
}

/// Reads the Insights numbers out of the pre-aggregated tables.
///
/// The point of this type is what it does *not* do: it never scans `transcripts`. The
/// totals, the series, the streak and the category split all come from `usage_daily`
/// and `app_usage`, which `SQLiteTranscriptStore` maintains on every save. Two years
/// of daily dictation is roughly 700 rows to read rather than forty thousand, so the
/// screen stays instant however long the history grows — and it never touches the
/// text, which is the other half of why this is cheap.
///
/// `latencyProfiles` is the exception. There is no aggregate table for it because the
/// samples are diagnostic, bounded by how much you dictate, and most users never look.
public struct InsightsEngine: Sendable {
  private let database: Database
  private let calendar: Calendar
  private let log = RantLog("Insights")

  /// Words per minute assumed for typing, used only for the time-saved estimate.
  ///
  /// 40 wpm is the middle of the measured range for people typing prose they are
  /// composing as they go, which is the thing dictation actually replaces. Copy-typing
  /// from a script is much faster and would flatter the figure; hunt-and-peck is much
  /// slower and would inflate it. Deliberately conservative: a saving that overstates
  /// itself is a number nobody believes twice.
  public static let assumedTypingWordsPerMinute = 40.0

  /// Length of the trailing window for "this week" and for each half of the trend.
  public static let trendWindowDays = 7

  /// `calendar` decides where a day begins, and it has to agree with the one
  /// `SQLiteTranscriptStore` writes with — Gregorian, in the machine's own time zone.
  /// Tests pass a fixed zone so the streak rules can be checked over a real DST jump.
  public init(database: Database, calendar: Calendar? = nil) {
    self.database = database
    if let calendar {
      self.calendar = calendar
    } else {
      var gregorian = Calendar(identifier: .gregorian)
      gregorian.timeZone = .current
      self.calendar = gregorian
    }
  }

  // MARK: - Summary

  public func summary(asOf now: Date = Date()) throws -> InsightsSummary {
    let today = dayString(now)
    let weekStart = dayString(shiftDays(-(Self.trendWindowDays - 1), from: now))
    let previousStart = dayString(shiftDays(-(Self.trendWindowDays * 2 - 1), from: now))
    let previousEnd = dayString(shiftDays(-Self.trendWindowDays, from: now))

    let all = try totals(where: "1 = 1", [])
    let todayTotals = try totals(where: "day = ?", [.text(today)])
    let week = try totals(where: "day >= ? AND day <= ?", [.text(weekStart), .text(today)])
    let previous = try totals(
      where: "day >= ? AND day <= ?", [.text(previousStart), .text(previousEnd)])

    let recentRate = rate(words: week.words, milliseconds: week.milliseconds)
    let previousRate = rate(words: previous.words, milliseconds: previous.milliseconds)
    // A trend measured against an empty half is not a trend, it is a first data point.
    let trend = (recentRate > 0 && previousRate > 0) ? recentRate - previousRate : 0

    let days = try activeDays()
    let (current, longest) = streaks(in: days, asOf: now)

    return InsightsSummary(
      totalWords: all.words,
      totalDictations: all.dictations,
      totalSpeakingSeconds: Double(all.milliseconds) / 1000,
      wordsToday: todayTotals.words,
      dictationsToday: todayTotals.dictations,
      wordsThisWeek: week.words,
      dictationsThisWeek: week.dictations,
      averageWordsPerMinute: rate(words: all.words, milliseconds: all.milliseconds),
      recentWordsPerMinute: recentRate,
      wordsPerMinuteTrend: trend,
      currentStreakDays: current,
      longestStreakDays: longest,
      activeDays: days.count,
      timeSavedSeconds: Self.timeSaved(
        words: all.words, speakingSeconds: Double(all.milliseconds) / 1000))
  }

  /// Typing time for the same words, less the time spent speaking them.
  ///
  /// Clamped at zero: someone dictating slowly in a language the model handles badly
  /// can genuinely come out behind, and showing them a negative saving is a worse
  /// answer than showing them nothing.
  public static func timeSaved(words: Int, speakingSeconds: Double) -> Double {
    guard words > 0 else { return 0 }
    let typingSeconds = Double(words) / assumedTypingWordsPerMinute * 60
    return max(0, typingSeconds - speakingSeconds)
  }

  // MARK: - Series

  /// The last `days` days ending today, oldest first, with the gaps filled in.
  public func dailySeries(days: Int = 30, asOf now: Date = Date()) throws -> [DailyUsage] {
    guard days > 0 else { return [] }
    let start = shiftDays(-(days - 1), from: now)

    var found: [String: (words: Int, dictations: Int, milliseconds: Int)] = [:]
    for row in try database.query(
      """
      SELECT day, words, dictations, duration_ms FROM usage_daily
      WHERE day >= ? AND day <= ?
      """,
      [.text(dayString(start)), .text(dayString(now))],
      { ($0.string(0), $0.int(1), $0.int(2), $0.int(3)) })
    {
      found[row.0] = (row.1, row.2, row.3)
    }

    return (0..<days).map { offset in
      let date = shiftDays(offset, from: start)
      let day = dayString(date)
      let totals = found[day] ?? (0, 0, 0)
      return DailyUsage(
        day: day, date: date, words: totals.words, dictations: totals.dictations,
        durationMilliseconds: totals.milliseconds)
    }
  }

  /// Words per surface, largest first. A `days` of nil means the whole history.
  public func usageByCategory(days: Int? = nil, asOf now: Date = Date()) throws
    -> [CategoryUsage]
  {
    var clause = ""
    var parameters: [SQLValue] = []
    if let days, days > 0 {
      clause = "WHERE day >= ? AND day <= ?"
      parameters = [.text(dayString(shiftDays(-(days - 1), from: now))), .text(dayString(now))]
    }
    let rows = try database.query(
      "SELECT category, SUM(words) FROM app_usage \(clause) GROUP BY category",
      parameters, { (UsageCategory(rawValue: $0.string(0)) ?? .other, $0.int(1)) })

    // Two rows can land on the same category once an unrecognised value falls back to
    // `.other`, so merge before computing shares or the shares stop summing to one.
    var totals: [UsageCategory: Int] = [:]
    for (category, words) in rows { totals[category, default: 0] += words }
    let sum = totals.values.reduce(0, +)

    return totals
      .map {
        CategoryUsage(
          category: $0.key, words: $0.value,
          share: sum > 0 ? Double($0.value) / Double(sum) : 0)
      }
      .sorted {
        $0.words == $1.words
          ? $0.category.rawValue < $1.category.rawValue : $0.words > $1.words
      }
  }

  // MARK: - Latency

  /// Percentiles per provider and stage, nearest-rank.
  ///
  /// p50/p90/p99 rather than a mean, because transcription latency has a long tail and
  /// the tail is the part anybody notices. A mean of 400ms hides the one call in
  /// twenty that took four seconds.
  public func latencyProfiles() throws -> [LatencyProfile] {
    let rows = try database.query(
      """
      SELECT t.provider, s.stage, s.milliseconds
      FROM latency_samples s
      JOIN transcripts t ON t.id = s.transcript_id
      ORDER BY t.provider, s.stage, s.milliseconds
      """,
      [], { ($0.string(0), $0.string(1), $0.int(2)) })

    var profiles: [LatencyProfile] = []
    var key: (provider: String, stage: String)?
    var bucket: [Int] = []

    func flush() {
      guard let key, !bucket.isEmpty else { return }
      profiles.append(
        LatencyProfile(
          provider: key.provider, stage: key.stage, sampleCount: bucket.count,
          p50: Self.percentile(bucket, 0.50), p90: Self.percentile(bucket, 0.90),
          p99: Self.percentile(bucket, 0.99)))
    }

    // The SQL orders by provider, stage and then duration, so one linear pass both
    // groups the samples and leaves each bucket already sorted for the percentiles.
    for row in rows {
      if key?.provider != row.0 || key?.stage != row.1 {
        flush()
        key = (row.0, row.1)
        bucket.removeAll(keepingCapacity: true)
      }
      bucket.append(row.2)
    }
    flush()
    return profiles
  }

  /// Nearest-rank on an ascending array. No interpolation: these are milliseconds that
  /// actually elapsed, and a percentile reporting a wait nobody had is harder to
  /// defend than one that does.
  static func percentile(_ sorted: [Int], _ fraction: Double) -> Int {
    guard !sorted.isEmpty else { return 0 }
    let rank = Int((fraction * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank, 1), sorted.count) - 1]
  }

  // MARK: - Streaks

  /// Days carrying at least one dictation, ascending. `yyyy-MM-dd` sorts
  /// lexicographically in date order, so SQLite can do the ordering.
  func activeDays() throws -> [String] {
    try database.query(
      "SELECT day FROM usage_daily WHERE dictations > 0 ORDER BY day ASC", [], { $0.string(0) })
  }

  /// Current and longest run of consecutive days.
  ///
  /// Two rules that look fussy right up until they bite:
  ///
  /// - Adjacency is asked of the calendar, never of an 86,400-second subtraction. Two
  ///   consecutive days are 23 or 25 hours apart around a DST change, and arithmetic
  ///   on seconds breaks every streak on exactly one day a year.
  /// - Each day is anchored at noon before anything is compared. DST transitions
  ///   happen in the small hours, and in a zone that springs forward at midnight
  ///   (São Paulo did) local midnight does not exist at all. Noon is never the
  ///   missing hour.
  ///
  /// A streak not yet extended *today* still stands if yesterday was active, because
  /// the day is not over. It breaks the day after that.
  func streaks(in days: [String], asOf now: Date) -> (current: Int, longest: Int) {
    let anchors = days.compactMap(noon(onDay:))
    guard let last = anchors.last else { return (0, 0) }

    var longest = 1
    var run = 1
    var finalRun = 1

    for index in 1..<max(anchors.count, 1) {
      run = isNextDay(anchors[index], after: anchors[index - 1]) ? run + 1 : 1
      longest = max(longest, run)
    }
    finalRun = run

    let today = calendar.startOfDay(for: now)
    let endsToday = calendar.isDate(last, inSameDayAs: today)
    let endsYesterday = isNextDay(today, after: last)
    return ((endsToday || endsYesterday) ? finalRun : 0, longest)
  }

  private func isNextDay(_ later: Date, after earlier: Date) -> Bool {
    guard let next = calendar.date(byAdding: .day, value: 1, to: earlier) else { return false }
    return calendar.isDate(next, inSameDayAs: later)
  }

  // MARK: - Days

  /// `yyyy-MM-dd` built from calendar components rather than a `DateFormatter`, which
  /// is neither `Sendable` nor cheap to build per call. The format matches what
  /// `SQLiteTranscriptStore` writes, which is what makes the string comparisons in the
  /// SQL above legitimate.
  func dayString(_ date: Date) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  private func noon(onDay day: String) -> Date? {
    let parts = day.split(separator: "-")
    guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
      let dayOfMonth = Int(parts[2])
    else { return nil }
    return calendar.date(
      from: DateComponents(year: year, month: month, day: dayOfMonth, hour: 12))
  }

  private func shiftDays(_ count: Int, from date: Date) -> Date {
    calendar.date(byAdding: .day, value: count, to: date) ?? date
  }

  // MARK: - Aggregate reads

  private func totals(where clause: String, _ parameters: [SQLValue]) throws
    -> (words: Int, dictations: Int, milliseconds: Int)
  {
    let row = try database.query(
      """
      SELECT COALESCE(SUM(words), 0), COALESCE(SUM(dictations), 0),
             COALESCE(SUM(duration_ms), 0)
      FROM usage_daily WHERE \(clause)
      """,
      parameters, { ($0.int(0), $0.int(1), $0.int(2)) }
    ).first
    return row ?? (0, 0, 0)
  }

  /// Words per minute, or zero. Guarded on both sides so that an empty history and a
  /// day of zero-length recordings both produce a number rather than a NaN that
  /// spreads into every chart downstream.
  private func rate(words: Int, milliseconds: Int) -> Double {
    guard words > 0, milliseconds > 0 else { return 0 }
    return Double(words) / (Double(milliseconds) / 60_000)
  }
}
