import RantCore
import SwiftUI

/// Chooses between onboarding and the main window.
struct RootView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var preferences: Preferences

  var body: some View {
    if preferences.hasCompletedOnboarding {
      MainWindow()
    } else {
      OnboardingView()
    }
  }
}

/// The sidebar and its destinations.
struct MainWindow: View {
  @EnvironmentObject private var model: AppModel
  @State private var selection: Destination = .home

  enum Destination: String, CaseIterable, Identifiable {
    case home, history, insights, dictionary, snippets, styles, scratchpad, migrate, settings
    var id: String { rawValue }

    var title: String {
      switch self {
      case .home: "Home"
      case .history: "History"
      case .insights: "Insights"
      case .dictionary: "Dictionary"
      case .snippets: "Snippets"
      case .styles: "Styles"
      case .scratchpad: "Scratchpad"
      case .migrate: "Migrate"
      case .settings: "Settings"
      }
    }

    var systemImage: String {
      switch self {
      case .home: "house"
      case .history: "clock"
      case .insights: "chart.bar"
      case .dictionary: "character.book.closed"
      case .snippets: "text.badge.plus"
      case .styles: "paintbrush"
      case .scratchpad: "note.text"
      case .migrate: "arrow.down.doc"
      case .settings: "gearshape"
      }
    }
  }

  var body: some View {
    NavigationSplitView {
      List(Destination.allCases, selection: $selection) { destination in
        NavigationLink(value: destination) {
          Label(destination.title, systemImage: destination.systemImage)
        }
      }
      .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 260)
      .safeAreaInset(edge: .bottom) { statusFooter }
    } detail: {
      Group {
        switch selection {
        case .home: HomeView()
        case .history: HistoryView()
        case .dictionary: DictionaryView()
        case .snippets: SnippetsView()
        case .settings: SettingsView()
        default: ComingSoonView(destination: selection)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// A permanent, honest statement of what Rant is currently doing with your data.
  /// It sits in the sidebar rather than buried in Settings because a privacy claim
  /// you have to go looking for is a privacy claim nobody checks.
  private var statusFooter: some View {
    VStack(alignment: .leading, spacing: 6) {
      Divider()
      HStack(spacing: 6) {
        Circle()
          .fill(model.hasAPIKey || model.preferences.localOnly ? Theme.success : Theme.accent)
          .frame(width: 7, height: 7)
        Text(providerSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let problem = model.hotkeyProblem {
        Label(problem, systemImage: "exclamationmark.triangle")
          .font(.caption2)
          .foregroundStyle(Theme.recording)
          .lineLimit(3)
      }
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 10)
  }

  private var providerSummary: String {
    if model.preferences.localOnly { return "Local only — nothing leaves this Mac" }
    if !model.hasAPIKey { return "No API key yet" }
    return "AssemblyAI · your key"
  }
}

struct ComingSoonView: View {
  let destination: MainWindow.Destination

  var body: some View {
    ContentUnavailableView {
      Label(destination.title, systemImage: destination.systemImage)
    } description: {
      Text("This part of Rant is still being built. See TASKS.md in the repository for exactly what is done and what is next.")
    }
  }
}
