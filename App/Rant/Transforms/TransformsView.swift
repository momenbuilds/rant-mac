import RantCore
import SwiftUI

/// Transforms: select text anywhere, press a key, and have it rewritten.
///
/// The screen shows the whole instruction for each one. A transform whose prompt you
/// cannot read is a transform you have to trust rather than understand, and the point
/// of an open-source dictation tool is that you do not have to.
struct TransformsView: View {
  @EnvironmentObject private var model: AppModel
  @State private var selection: String?

  private var transforms: [Transform] { Transform.builtIns }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.large) {
      PageTitle(
        title: "Transforms",
        subtitle: "Select text in any app, press \(CarbonHotkey.Combination.optionShiftT.displayName), and choose one.",
        accessory: AnyView(
          Button {
            model.beginTransform()
          } label: {
            Label("Transform selection", systemImage: "wand.and.stars")
          }
          .buttonStyle(.clay)
          .help("Reads whatever is selected in the app you were last using")))

      Card(fill: Theme.claySoft) {
        HStack(spacing: 10) {
          Image(systemName: "info.circle")
            .font(.system(size: 12)).foregroundStyle(Theme.clay)
            .accessibilityHidden(true)
          Text("Every transform shows you the result as a diff before it replaces anything. You can accept it, reject it, copy it, or edit it first. Reading your selection needs Accessibility permission.")
            .font(.system(size: 12.5)).foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
          Spacer()
        }
      }

      Section2("Built in", subtitle: "\(transforms.count) available") {
        Card(padding: 0) {
          VStack(spacing: 0) {
            ForEach(Array(transforms.enumerated()), id: \.element.id) { index, transform in
              row(transform)
              if index < transforms.count - 1 {
                Divider().overlay(Theme.hairline).padding(.leading, Theme.Spacing.medium)
              }
            }
          }
        }
      }
    }
    .page()
  }

  private func row(_ transform: Transform) -> some View {
    let expanded = selection == transform.id
    return VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
      Button {
        selection = expanded ? nil : transform.id
      } label: {
        HStack(spacing: Theme.Spacing.small) {
          VStack(alignment: .leading, spacing: 2) {
            Text(transform.name)
              .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
            Text(transform.instruction)
              .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
              .lineLimit(expanded ? nil : 1)
              .fixedSize(horizontal: false, vertical: expanded)
              .multilineTextAlignment(.leading)
          }
          Spacer(minLength: Theme.Spacing.small)
          if transform.needsTargetLanguage {
            Chip(text: "needs a language")
          }
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.inkFaint)
            .rotationEffect(.degrees(expanded ? 90 : 0))
            .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }
}
