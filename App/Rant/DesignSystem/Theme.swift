import SwiftUI

/// Rant's visual vocabulary.
///
/// The brief was "restrained macOS-native, no giant gradient AI slop", so the whole
/// system is: one accent, system materials, generous spacing, and typography doing
/// the work. Nothing here draws attention to itself — a dictation app you notice is
/// a dictation app that is in your way.
enum Theme {
  /// A warm amber. Chosen because it reads clearly against both light and dark
  /// materials and because it is not the blue that every other utility uses.
  static let accent = Color(red: 0.94, green: 0.62, blue: 0.21)
  static let recording = Color(red: 0.91, green: 0.30, blue: 0.24)
  static let success = Color(red: 0.30, green: 0.72, blue: 0.44)

  enum Spacing {
    static let tight: CGFloat = 6
    static let small: CGFloat = 10
    static let medium: CGFloat = 16
    static let large: CGFloat = 24
    static let section: CGFloat = 32
  }

  enum Radius {
    static let small: CGFloat = 7
    static let medium: CGFloat = 12
    static let large: CGFloat = 18
    static let pill: CGFloat = 999
  }

  /// Motion is opt-out: everything animated here checks Reduce Motion first, via
  /// `Theme.animation(_:reduceMotion:)`, so the setting is honoured in one place
  /// rather than remembered at thirty call sites.
  static func animation(_ base: Animation, reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : base
  }

  static let springy = Animation.spring(response: 0.32, dampingFraction: 0.78)
  static let gentle = Animation.easeInOut(duration: 0.18)
}

/// A card. Used for every grouped block in the main window so the app has one
/// container idea rather than five.
struct CardModifier: ViewModifier {
  var padding: CGFloat = Theme.Spacing.medium

  func body(content: Content) -> some View {
    content
      .padding(padding)
      .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.medium)
          .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
  }
}

extension View {
  func card(padding: CGFloat = Theme.Spacing.medium) -> some View {
    modifier(CardModifier(padding: padding))
  }
}

/// A labelled section with a quiet header, matching the rhythm of System Settings
/// without imitating it.
struct SectionCard<Content: View>: View {
  let title: String
  var subtitle: String?
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.headline)
        if let subtitle {
          Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
      }
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .card()
  }
}

/// The privacy pill that appears wherever a choice affects what leaves the machine.
/// Being explicit at the point of decision is the entire privacy design.
struct PrivacyBadge: View {
  enum Level { case onDevice, network }
  let level: Level

  var body: some View {
    Label(
      level == .onDevice ? "Stays on your Mac" : "Sent to your provider",
      systemImage: level == .onDevice ? "lock.laptopcomputer" : "network"
    )
    .font(.caption)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(
      (level == .onDevice ? Theme.success : Theme.accent).opacity(0.15),
      in: Capsule())
    .foregroundStyle(level == .onDevice ? Theme.success : Theme.accent)
  }
}
