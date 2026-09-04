import RantCore
import SwiftUI

/// What Rant has done for you, computed entirely from local aggregates.
///
/// Nothing here is sent anywhere, and nothing here needed to be: every number comes
/// from tables written inside the same transaction as the dictation that produced them.
struct InsightsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var summary: InsightsSummary?
  @State private var daily: [DailyUsage] = []
  @State private var categories: [CategoryUsage] = []
  @State private var range = 30

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.large) {
      PageTitle(
        title: "Insights",
        subtitle: "Worked out on your Mac, from your own history.",
        accessory: AnyView(rangePicker))

      if let summary, summary.totalDictations > 0 {
        headline(summary)
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
          wordsChart
          categoryBreakdown
        }
        streakGrid(summary)
      } else {
        Card {
          EmptyState(
            icon: "chart.bar",
            title: "Nothing to show yet",
            message: "Dictate something and this fills in. None of it is sent anywhere, because there is nowhere to send it.")
        }
      }
    }
    .page(maxWidth: 1_000)
    .onAppear(perform: reload)
    .onChange(of: range) { _, _ in reload() }
  }

  private var rangePicker: some View {
    HStack(spacing: 2) {
      ForEach([7, 30, 90], id: \.self) { days in
        Button {
          range = days
        } label: {
          Text("\(days)d")
            .font(.system(size: 11.5, weight: range == days ? .semibold : .regular))
            .foregroundStyle(range == days ? Theme.ink : Theme.inkMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
              range == days ? Theme.surface : .clear,
              in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(2)
    .background(Theme.sunken, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
  }

  private func headline(_ summary: InsightsSummary) -> some View {
    Card(padding: Theme.Spacing.large) {
      HStack(alignment: .top, spacing: Theme.Spacing.large) {
        Stat(value: summary.totalWords.formatted(), label: "Total words")
        rule
        Stat(
          value: "\(Int(summary.averageWordsPerMinute))", label: "Words per minute", unit: "wpm")
        rule
        Stat(value: "\(summary.currentStreakDays)", label: "Day streak", tint: Theme.clay)
        rule
        Stat(value: formatted(summary.timeSavedSeconds), label: "Time saved")
      }
    }
  }

  private var rule: some View {
    Rectangle().fill(Theme.hairline).frame(width: 1, height: 38)
  }

  private var wordsChart: some View {
    Section2("Words per day") {
      Card {
        if daily.allSatisfy({ $0.words == 0 }) {
          Text("No activity in this period.")
            .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
            .frame(height: 150)
        } else {
          let peak = max(1, daily.map(\.words).max() ?? 1)
          HStack(alignment: .bottom, spacing: 3) {
            ForEach(daily, id: \.day) { entry in
              VStack(spacing: 0) {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 2)
                  .fill(entry.words == 0 ? Theme.sunken : Theme.clay.opacity(0.85))
                  .frame(height: max(3, CGFloat(entry.words) / CGFloat(peak) * 150))
              }
              .help("\(entry.words) words")
            }
          }
          .frame(height: 150)
        }
      }
    }
  }

  private var categoryBreakdown: some View {
    Section2("Where the words went") {
      Card {
        if categories.isEmpty {
          Text("Not enough history yet.")
            .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
            .frame(height: 150, alignment: .top)
        } else {
          VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(categories.prefix(6).enumerated()), id: \.element.category) { index, usage in
              HStack(spacing: 9) {
                Circle()
                  .fill(Theme.categoryColours[index % Theme.categoryColours.count])
                  .frame(width: 7, height: 7)
                Text(usage.category.displayName)
                  .font(.system(size: 12.5))
                  .foregroundStyle(Theme.ink)
                Spacer(minLength: Theme.Spacing.tight)
                Text("\(Int(usage.share * 100))%")
                  .font(.system(size: 12).monospacedDigit())
                  .foregroundStyle(Theme.inkMuted)
              }
              GeometryReader { geometry in
                ZStack(alignment: .leading) {
                  Capsule().fill(Theme.sunken)
                  Capsule()
                    .fill(Theme.categoryColours[index % Theme.categoryColours.count].opacity(0.8))
                    .frame(width: max(3, geometry.size.width * usage.share))
                }
              }
              .frame(height: 5)
            }
          }
          .frame(minHeight: 150, alignment: .top)
        }
      }
    }
  }

  /// A contribution grid. It is the clearest way to show a streak, and unlike a
  /// number it also shows the shape of the habit.
  private func streakGrid(_ summary: InsightsSummary) -> some View {
    Section2(
      "Your streak",
      subtitle: "Longest so far: \(summary.longestStreakDays) days"
    ) {
      Card {
        let peak = max(1, daily.map(\.words).max() ?? 1)
        HStack(spacing: 3) {
          ForEach(daily, id: \.day) { entry in
            RoundedRectangle(cornerRadius: 2.5)
              .fill(fill(for: entry.words, peak: peak))
              .frame(width: 13, height: 13)
              .help("\(TranscriptList.dayLabel(entry.date)): \(entry.words) words")
          }
          Spacer(minLength: 0)
        }
      }
    }
  }

  private func fill(for words: Int, peak: Int) -> Color {
    guard words > 0 else { return Theme.sunken }
    let intensity = Double(words) / Double(peak)
    return Theme.clay.opacity(0.28 + 0.72 * min(1, intensity))
  }

  private func formatted(_ seconds: Double) -> String {
    if seconds < 60 { return "0m" }
    if seconds < 3_600 { return "\(Int(seconds / 60))m" }
    return String(format: "%.1fh", seconds / 3_600)
  }

  private func reload() {
    guard let database = model.databaseHandle else { return }
    let engine = InsightsEngine(database: database)
    summary = try? engine.summary()
    daily = (try? engine.dailySeries(days: range)) ?? []
    categories = (try? engine.usageByCategory(days: range)) ?? []
  }
}
