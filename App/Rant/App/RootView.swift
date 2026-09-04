import RantCore
import SwiftUI

/// Chooses between onboarding and the main window.
struct RootView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var preferences: Preferences

  var body: some View {
    Group {
      if preferences.hasCompletedOnboarding {
        MainWindow()
      } else {
        OnboardingView()
      }
    }
    .tint(Theme.clay)
  }
}

/// The window: a custom sidebar and a paper page.
///
/// `NavigationSplitView`'s stock list gives a system-grey sidebar with system-blue
/// selection, which fights the palette everywhere. The sidebar here is a plain
/// `VStack` of buttons — a few more lines in exchange for a shell that belongs to the
/// app rather than to the template.
struct MainWindow: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var preferences: Preferences
  @State private var selection: Destination = .home

  enum Destination: String, CaseIterable, Identifiable {
    case home, history, notetaker, insights
    case dictionary, snippets, styles, transforms, scratchpad
    case migrate, settings
    var id: String { rawValue }

    var title: String {
      switch self {
      case .home: "Home"
      case .history: "History"
      case .notetaker: "Notetaker"
      case .insights: "Insights"
      case .dictionary: "Dictionary"
      case .snippets: "Snippets"
      case .styles: "Styles"
      case .transforms: "Transforms"
      case .scratchpad: "Scratchpad"
      case .migrate: "Migrate"
      case .settings: "Settings"
      }
    }

    var systemImage: String {
      switch self {
      case .home: "house"
      case .history: "clock.arrow.circlepath"
      case .notetaker: "person.2.wave.2"
      case .insights: "chart.bar"
      case .dictionary: "character.book.closed"
      case .snippets: "text.append"
      case .styles: "paintbrush.pointed"
      case .transforms: "wand.and.sparkles"
      case .scratchpad: "note.text"
      case .migrate: "arrow.down.doc"
      case .settings: "gearshape"
      }
    }

    /// Grouped the way the references do: what you do, what you teach it, what you
    /// own. A flat list of eleven items is a list you have to read every time.
    static let groups: [(String?, [Destination])] = [
      (nil, [.home, .history, .notetaker, .insights]),
      ("Your voice", [.dictionary, .snippets, .styles, .transforms, .scratchpad]),
      ("Your data", [.migrate, .settings]),
    ]
  }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider().overlay(Theme.hairline)
      detail
    }
    .background(Theme.paper)
    .frame(minWidth: 960, minHeight: 620)
  }

  // MARK: - Sidebar

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      wordmark
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
          ForEach(Array(Destination.groups.enumerated()), id: \.offset) { _, group in
            VStack(alignment: .leading, spacing: 1) {
              if let heading = group.0 {
                Text(heading.uppercased())
                  .font(Theme.label)
                  .tracking(0.7)
                  .foregroundStyle(Theme.inkFaint)
                  .padding(.horizontal, 12)
                  .padding(.bottom, 5)
              }
              ForEach(group.1) { destination in
                item(destination)
              }
            }
          }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, Theme.Spacing.medium)
      }
      Spacer(minLength: 0)
      statusFooter
    }
    .frame(width: 228)
    .background(Theme.paper)
  }

  private var wordmark: some View {
    HStack(spacing: 9) {
      RantMark(size: 17)
      Text("Rant").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
      Spacer()
    }
    .padding(.horizontal, 20)
    // Clearance for the traffic lights, which now float over the sidebar because the
    // title bar is hidden.
    .padding(.top, 40)
    .padding(.bottom, 20)
  }

  private func item(_ destination: Destination) -> some View {
    let selected = selection == destination
    return Button {
      selection = destination
    } label: {
      HStack(spacing: 10) {
        Image(systemName: destination.systemImage)
          .font(.system(size: 13, weight: selected ? .semibold : .regular))
          .frame(width: 17)
        Text(destination.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
        Spacer(minLength: 0)
      }
      .foregroundStyle(selected ? Theme.ink : Theme.inkMuted)
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(
        selected ? Theme.surface : .clear,
        in: RoundedRectangle(cornerRadius: Theme.Radius.control))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.control)
          .strokeBorder(selected ? Theme.hairline : .clear, lineWidth: 1))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("sidebar.\(destination.rawValue)")
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }

  /// A permanent statement of what Rant is doing with your words. It lives here
  /// rather than in Settings because a privacy claim you have to go looking for is a
  /// privacy claim nobody checks.
  private var statusFooter: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
      Divider().overlay(Theme.hairline)
      HStack(spacing: 7) {
        Circle()
          .fill(ready ? Theme.moss : Theme.clay)
          .frame(width: 6, height: 6)
        Text(providerSummary)
          .font(.system(size: 11))
          .foregroundStyle(Theme.inkMuted)
          .lineLimit(1)
      }
      .padding(.horizontal, 20)

      if let problem = model.hotkeyProblem {
        Text(problem)
          .font(.system(size: 10.5))
          .foregroundStyle(Theme.clay)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 20)
      }
    }
    .padding(.bottom, 16)
  }

  private var ready: Bool {
    preferences.localOnly || model.hasAPIKey
  }

  private var providerSummary: String {
    if preferences.localOnly { return "Local only — nothing leaves this Mac" }
    if !model.hasAPIKey { return "No API key yet" }
    return "AssemblyAI · your key"
  }

  // MARK: - Detail

  @ViewBuilder private var detail: some View {
    switch selection {
    case .home: HomeView()
    case .history: HistoryView()
    case .notetaker: NotetakerView()
    case .insights: InsightsView()
    case .dictionary: DictionaryView()
    case .snippets: SnippetsView()
    case .styles: StylesView()
    case .transforms: TransformsView()
    case .scratchpad: ScratchpadView()
    case .migrate: MigrateView()
    case .settings: SettingsView()
    }
  }
}

/// A page heading. Every screen uses it, so the pages start the same way.
struct PageTitle: View {
  let title: String
  var subtitle: String?
  var accessory: AnyView?

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.ink)
        if let subtitle {
          Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.inkMuted)
        }
      }
      Spacer()
      accessory
    }
  }
}

/// Empty states, in the app's own voice rather than the system's.
struct EmptyState: View {
  let icon: String
  let title: String
  let message: String
  var actionTitle: String?
  var action: (() -> Void)?
  /// Put on the button rather than on the surrounding view: an identifier on a
  /// container is inherited by its descendants, so a UI test asking for it finds two
  /// elements and refuses to click either.
  var actionIdentifier: String?

  var body: some View {
    VStack(spacing: Theme.Spacing.small) {
      Image(systemName: icon)
        .font(.system(size: 26, weight: .light))
        .foregroundStyle(Theme.clay)
        .accessibilityHidden(true)
      Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
      Text(message)
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.inkMuted)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 380)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(.clay)
          .padding(.top, Theme.Spacing.hair)
          .accessibilityIdentifier(actionIdentifier ?? "")
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, Theme.Spacing.section)
  }
}
