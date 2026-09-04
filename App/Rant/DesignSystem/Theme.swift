import SwiftUI

/// Rant's visual identity.
///
/// The brief was an original look — not Wispr Flow's teal-on-cream, not Willow's
/// indigo-on-white, not the grey chrome every Mac utility defaults to. What the good
/// ones get right is worth learning from: a warm paper ground rather than grey, one
/// confident accent used sparingly, hairline borders instead of shadows, and a lot of
/// air. What they do not have is a point of view about *this* product.
///
/// Rant's is **ink on paper**. The app is for people who talk messily and want clean
/// writing out of it, so the surface reads like a page: a warm off-white, near-black
/// plum text, and a single clay accent that is warm and a little argumentative
/// without being an alarm. Red stays reserved for one thing — the microphone being
/// live — so it never competes.
enum Theme {

  // MARK: - Palette

  /// The ground. Warm enough to read as paper rather than as "light mode grey".
  static let paper = Color(light: .init(hex: 0xFBF8F3), dark: .init(hex: 0x141317))
  /// Cards and raised surfaces.
  static let surface = Color(light: .init(hex: 0xFFFFFF), dark: .init(hex: 0x1C1B21))
  /// A slightly recessed fill: input wells, quiet chips, table stripes.
  static let sunken = Color(light: .init(hex: 0xF2EDE5), dark: .init(hex: 0x232228))

  /// Text. Near-black with a plum cast, so it sits on the warm ground without the
  /// blue-grey coldness of pure `.primary`.
  static let ink = Color(light: .init(hex: 0x1E1B24), dark: .init(hex: 0xF2EFEA))
  static let inkMuted = Color(light: .init(hex: 0x6B6472), dark: .init(hex: 0xA09AAA))
  static let inkFaint = Color(light: .init(hex: 0x9A93A2), dark: .init(hex: 0x716B7A))

  /// The accent: a warm clay. Distinct from the teal and indigo the alternatives use,
  /// and warm enough to belong on paper.
  static let clay = Color(light: .init(hex: 0xC2553A), dark: .init(hex: 0xE07553))
  static let claySoft = Color(light: .init(hex: 0xF6E7E0), dark: .init(hex: 0x3A2620))

  /// Reserved for one thing only: the microphone is live.
  static let live = Color(light: .init(hex: 0xD03A2E), dark: .init(hex: 0xF0574A))
  /// Confirmation. A muted moss, so a tick does not shout.
  static let moss = Color(light: .init(hex: 0x4A7C59), dark: .init(hex: 0x6FA37E))
  static let mossSoft = Color(light: .init(hex: 0xE4EDE5), dark: .init(hex: 0x1F2E23))

  /// Hairlines. Borders do the separating here, not shadows — a shadow on a warm
  /// ground reads as dirt.
  static let hairline = Color(light: .init(hex: 0x1E1B24).opacity(0.10),
                              dark: .init(hex: 0xF2EFEA).opacity(0.10))
  static let hairlineStrong = Color(light: .init(hex: 0x1E1B24).opacity(0.16),
                                    dark: .init(hex: 0xF2EFEA).opacity(0.16))

  /// Category colours for charts and usage breakdowns. Warm-biased so they sit
  /// together on the clay-and-paper ground rather than looking like a stock palette.
  static let categoryColours: [Color] = [
    Color(light: .init(hex: 0xC2553A), dark: .init(hex: 0xE07553)),
    Color(light: .init(hex: 0x4A7C59), dark: .init(hex: 0x6FA37E)),
    Color(light: .init(hex: 0x8A6BA8), dark: .init(hex: 0xA98CC4)),
    Color(light: .init(hex: 0xC99A2E), dark: .init(hex: 0xDFB755)),
    Color(light: .init(hex: 0x3E7C8C), dark: .init(hex: 0x62A2B2)),
    Color(light: .init(hex: 0xB05070), dark: .init(hex: 0xCC7592)),
    Color(light: .init(hex: 0x7A7285), dark: .init(hex: 0x9A92A5)),
  ]

  // MARK: - Metrics

  enum Spacing {
    static let hair: CGFloat = 4
    static let tight: CGFloat = 8
    static let small: CGFloat = 12
    static let medium: CGFloat = 18
    static let large: CGFloat = 26
    static let section: CGFloat = 38
    /// The page gutter. Generous on purpose — the references all breathe.
    static let page: CGFloat = 34
  }

  enum Radius {
    static let chip: CGFloat = 7
    static let control: CGFloat = 9
    static let card: CGFloat = 14
    static let panel: CGFloat = 18
    static let pill: CGFloat = 999
  }

  // MARK: - Type

  /// A display face for the numbers that carry the page. Rounded, because the rest of
  /// the type is the system serif-less default and the contrast is what makes a stat
  /// read as a stat.
  static func display(_ size: CGFloat) -> Font {
    .system(size: size, weight: .semibold, design: .rounded)
  }

  /// The small uppercase label under a statistic. Tracking is what stops it looking
  /// like shouting.
  static let label = Font.system(size: 10.5, weight: .semibold)

  // MARK: - Motion

  /// Motion is opt-out in one place, so Reduce Motion is honoured by asking rather
  /// than by being remembered at thirty call sites.
  static func animation(_ base: Animation, reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : base
  }

  static let springy = Animation.spring(response: 0.30, dampingFraction: 0.80)
  static let gentle = Animation.easeInOut(duration: 0.16)
}

// MARK: - Colour helpers

extension Color {
  /// A colour that resolves per appearance. SwiftUI's asset-catalogue equivalent
  /// without an asset catalogue, so the whole palette stays readable in one file.
  init(light: Color, dark: Color) {
    self.init(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
          ? NSColor(dark) : NSColor(light)
      })
  }

  init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: 1)
  }
}

// MARK: - Components

/// The card everything sits in. Hairline border, no shadow, generous padding.
struct Card<Content: View>: View {
  var padding: CGFloat = Theme.Spacing.medium
  var fill: Color = Theme.surface
  @ViewBuilder var content: Content

  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.card)
          .strokeBorder(Theme.hairline, lineWidth: 1))
  }
}

/// A titled block. The heading sits *outside* the card, which is what gives the
/// reference layouts their rhythm — the card is the content, not the whole section.
struct Section2<Content: View>: View {
  let title: String
  var subtitle: String?
  var accessory: AnyView?
  @ViewBuilder var content: Content

  init(
    _ title: String,
    subtitle: String? = nil,
    accessory: AnyView? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.accessory = accessory
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
          if let subtitle {
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
          }
        }
        Spacer()
        accessory
      }
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A statistic: a large rounded number over a small uppercase label. The single
/// strongest pattern in both references, and the thing that makes a dashboard read at
/// a glance rather than needing to be studied.
struct Stat: View {
  let value: String
  let label: String
  var unit: String?
  var tint: Color = Theme.ink

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(value)
          .font(Theme.display(30))
          .foregroundStyle(tint)
          .monospacedDigit()
          .contentTransition(.numericText())
        if let unit {
          Text(unit).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.inkMuted)
        }
      }
      Text(label.uppercased())
        .font(Theme.label)
        .tracking(0.7)
        .foregroundStyle(Theme.inkFaint)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// A small pill. Used for the privacy indicator, mode chips and key caps.
struct Chip: View {
  let text: String
  var systemImage: String?
  var tint: Color = Theme.inkMuted
  var fill: Color = Theme.sunken

  var body: some View {
    HStack(spacing: 4) {
      if let systemImage {
        Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
      }
      Text(text).font(.system(size: 11, weight: .medium))
    }
    .foregroundStyle(tint)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(fill, in: Capsule())
  }
}

/// A keyboard key, drawn as a key. Both references put the hotkey at the top of the
/// home screen, and drawing it as a cap rather than as text is what makes it read as
/// something you press.
struct KeyCap: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 12, weight: .semibold, design: .rounded))
      .foregroundStyle(Theme.ink)
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.chip)
          .strokeBorder(Theme.hairlineStrong, lineWidth: 1))
  }
}

/// Says whether a choice keeps your words on the machine. Sits at the point of
/// decision rather than in a help article — that placement is the privacy design.
struct PrivacyBadge: View {
  enum Level { case onDevice, network }
  let level: Level

  var body: some View {
    Chip(
      text: level == .onDevice ? "Stays on your Mac" : "Sent to your provider",
      systemImage: level == .onDevice ? "lock.laptopcomputer" : "arrow.up.right",
      tint: level == .onDevice ? Theme.moss : Theme.clay,
      fill: level == .onDevice ? Theme.mossSoft : Theme.claySoft)
  }
}

/// The primary button. One filled style in the whole app, so "the important one" is
/// never ambiguous.
struct ClayButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 7)
      .background(
        Theme.clay.opacity(configuration.isPressed ? 0.85 : 1),
        in: RoundedRectangle(cornerRadius: Theme.Radius.control))
  }
}

/// The quiet button: a bordered control that does not compete with the clay one.
struct QuietButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(Theme.ink)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(
        configuration.isPressed ? Theme.sunken : Theme.surface,
        in: RoundedRectangle(cornerRadius: Theme.Radius.control))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.control)
          .strokeBorder(Theme.hairlineStrong, lineWidth: 1))
  }
}

extension ButtonStyle where Self == ClayButtonStyle {
  static var clay: ClayButtonStyle { ClayButtonStyle() }
}
extension ButtonStyle where Self == QuietButtonStyle {
  static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

extension View {
  /// The standard page: paper ground, page gutter, and a sensible reading width so
  /// text never runs the full width of a large display.
  func page(maxWidth: CGFloat = 900) -> some View {
    ScrollView {
      self
        .padding(Theme.Spacing.page)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Theme.paper)
  }
}

// MARK: - Compatibility

/// The older section container, re-expressed in the new system.
///
/// Kept so every screen picked up the redesign in one step rather than being ported
/// one at a time — the heading now sits outside the card, which is what gives the
/// layout its rhythm, and the card inside is the new one. New code should use
/// `Section2` and `Card` directly.
struct SectionCard<Content: View>: View {
  let title: String
  var subtitle: String?
  @ViewBuilder var content: Content

  var body: some View {
    Section2(title, subtitle: subtitle) {
      Card { content }
    }
  }
}

extension View {
  func card(padding: CGFloat = Theme.Spacing.medium) -> some View {
    self
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.card)
          .strokeBorder(Theme.hairline, lineWidth: 1))
  }

  /// Applies the app's ground and type colour to a screen that has not been ported to
  /// `page()` yet.
  func paperBackground() -> some View {
    background(Theme.paper).foregroundStyle(Theme.ink)
  }
}
