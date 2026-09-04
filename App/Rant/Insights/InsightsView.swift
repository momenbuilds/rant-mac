import Charts
import RantCore
import SwiftUI

/// What Rant has actually done for you, computed entirely from local aggregates.
///
/// Nothing here is sent anywhere, and nothing here needed to be: every number comes
/// from `usage_daily` and `app_usage`, which are written inside the same transaction
/// as the dictation that produced them.
struct InsightsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var summary: InsightsSummary?
  @State private var daily: [DailyUsage] = []
  @State private var categories: [CategoryUsage] = []
  @State private var latency: [LatencyProfile] = []
  @State private var range = 30

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.large) {
        if let summary, summary.totalDictations > 0 {
          headline(summary)
          streaks(summary)
          wordsChart
          categoryChart
          if model.preferences.developerMode { latencyTable }
        } else {
          ContentUnavailableView {
            Label("Nothing to show yet", systemImage: "chart.bar")
          } description: {
            Text("Dictate something and this fills in. Everything here is computed on your Mac from your own history — none of it is sent anywhere, because there is nowhere to send it.")
          }
        }
      }
      .padding(Theme.Spacing.large)
      .frame(maxWidth: 860, alignment: .leading)
    }
    .frame(maxWidth: .infinity)
    .navigationTitle("Insights")
    .toolbar {
      ToolbarItem {
        Picker("Range", selection: $range) {
          Text("7 days").tag(7)
          Text("30 days").tag(30)
          Text("90 days").tag(90)
        }
        .pickerStyle(.segmented)
      }
    }
    .onAppear(perform: reload)
    .onChange(of: range) { _, _ in reload() }
  }

  private func headline(_ summary: InsightsSummary) -> some View {
    HStack(spacing: Theme.Spacing.medium) {
      stat("Words dictated", summary.totalWords.formatted(), "text.word.spacing")
      stat("Average pace", "\(Int(summary.averageWordsPerMinute)) wpm", "speedometer")
      stat("Time saved", formatted(summary.timeSavedSeconds), "clock.arrow.circlepath")
    }
  }

  private func streaks(_ summary: InsightsSummary) -> some View {
    HStack(spacing: Theme.Spacing.medium) {
      stat("Today", "\(summary.wordsToday) words", "sun.max")
      stat("This week", "\(summary.wordsThisWeek) words", "calendar")
      stat(
        "Streak",
        summary.currentStreakDays == 1 ? "1 day" : "\(summary.currentStreakDays) days",
        "flame")
      stat("Longest", "\(summary.longestStreakDays) days", "trophy")
    }
  }

  private func stat(_ title: String, _ value: String, _ symbol: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.title3.weight(.semibold)).monospacedDigit()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .card()
  }

  private var wordsChart: some View {
    SectionCard(title: "Words per day") {
      Chart(daily, id: \.day) { entry in
        BarMark(x: .value("Day", entry.date, unit: .day), y: .value("Words", entry.words))
          .foregroundStyle(Theme.accent.gradient)
          .cornerRadius(2)
      }
      .frame(height: 180)
      .chartYAxis { AxisMarks(position: .leading) }
    }
  }

  private var categoryChart: some View {
    SectionCard(title: "Where the words went") {
      if categories.isEmpty {
        Text("Not enough history yet.").font(.callout).foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(categories, id: \.category) { usage in
            HStack {
              Text(usage.category.displayName).font(.callout).frame(width: 150, alignment: .leading)
              GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 3)
                  .fill(Theme.accent.opacity(0.75))
                  .frame(width: max(2, geometry.size.width * usage.share))
              }
              .frame(height: 10)
              Text("\(Int(usage.share * 100))%")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            }
          }
        }
      }
    }
  }

  /// Only visible in developer mode. A dictation app that reports its own latency at
  /// you is a dictation app you notice.
  private var latencyTable: some View {
    SectionCard(title: "Latency", subtitle: "Per stage, in milliseconds.") {
      if latency.isEmpty {
        Text("No samples recorded yet.").font(.callout).foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(latency, id: \.stage) { profile in
            HStack {
              Text(profile.stage).font(.caption).frame(width: 140, alignment: .leading)
              Text("\(profile.sampleCount) samples")
                .font(.caption2).foregroundStyle(.tertiary)
              Spacer()
            }
          }
        }
      }
    }
  }

  private func formatted(_ seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes) min" }
    return String(format: "%.1f hours", seconds / 3600)
  }

  private func reload() {
    guard let database = model.databaseHandle else { return }
    let engine = InsightsEngine(database: database)
    summary = try? engine.summary()
    daily = (try? engine.dailySeries(days: range)) ?? []
    categories = (try? engine.usageByCategory(days: range)) ?? []
    latency = (try? engine.latencyProfiles()) ?? []
  }
}
