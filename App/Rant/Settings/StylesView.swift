import RantCore
import SwiftUI

/// Writing styles, and where each one applies.
///
/// The screen is built around the resolution order rather than around a list,
/// because the question people actually have is "which style will I get *here*",
/// and a flat list of styles cannot answer it.
struct StylesView: View {
  @EnvironmentObject private var model: AppModel
  @State private var selection: String?

  private var styles: [WritingStyle] { WritingStyle.builtIns }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      PageTitle(
        title: "Styles",
        subtitle: "How Rant writes for you, and where each one applies.")
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, Theme.Spacing.page)
      Divider().overlay(Theme.hairline)
      HSplitView {
        List(styles, selection: $selection) { style in
        VStack(alignment: .leading, spacing: 2) {
          HStack {
            Text(style.name).fontWeight(.medium)
            if style.builtIn {
              Text("built in").font(.caption2).foregroundStyle(.tertiary)
            }
          }
          if let category = style.category {
            Text("default for \(category.displayName.lowercased())")
              .font(.caption2).foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 2)
        .tag(style.id)
      }
      .frame(minWidth: 220, idealWidth: 240)

        detail
          .frame(minWidth: 380)
      }
      .frame(maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Theme.paper)
  }

  @ViewBuilder private var detail: some View {
    if let style = styles.first(where: { $0.id == selection }) ?? styles.first {
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
          VStack(alignment: .leading, spacing: 4) {
            Text(style.name).font(.title2.weight(.semibold))
            Text("This is the whole instruction. Nothing is hidden behind the label.")
              .font(.caption).foregroundStyle(.secondary)
          }

          SectionCard(title: "Instruction") {
            Text(style.instructions)
              .font(.callout)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }

          SectionCard(
            title: "How Rant chooses",
            subtitle: "Most specific wins, so something you set deliberately is never overruled by a general rule."
          ) {
            VStack(alignment: .leading, spacing: 8) {
              precedence(1, "A one-off override for this dictation")
              precedence(2, "A rule for the site you are on")
              precedence(3, "A rule for the app you are in")
              precedence(4, "The default for that kind of writing")
              precedence(5, "Your global default")
            }
          }
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: 640, alignment: .leading)
      }
    } else {
      EmptyState(icon: "paintbrush.pointed", title: "Select a style", message: "")
    }
  }

  private func precedence(_ number: Int, _ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("\(number)")
        .font(.caption.monospacedDigit())
        .foregroundStyle(Theme.clay)
        .frame(width: 16, alignment: .trailing)
      Text(text).font(.callout)
    }
  }
}

/// Modes: the whole pipeline, not just the wording.
struct ModesView: View {
  @State private var selection: String?
  private var modes: [Mode] { Mode.builtIns }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      PageTitle(title: "Modes", subtitle: "The whole pipeline, not just the wording.")
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.top, Theme.Spacing.page)
      Divider().overlay(Theme.hairline)
      HSplitView {
        List(modes, selection: $selection) { mode in
        VStack(alignment: .leading, spacing: 2) {
          Text(mode.name).fontWeight(.medium)
          Text(triggerSummary(mode)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .tag(mode.id)
      }
      .frame(minWidth: 220, idealWidth: 240)

      if let mode = modes.first(where: { $0.id == selection }) ?? modes.first {
        ScrollView {
          VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            Text(mode.name).font(.title2.weight(.semibold))

            SectionCard(title: "Pipeline") {
              VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Cleanup", value: mode.configuration.cleanupLevel.displayName)
                LabeledContent("Style", value: mode.configuration.styleName ?? "—")
                LabeledContent("Output", value: outputName(mode.configuration.outputTarget))
                LabeledContent("Enhancement", value: mode.configuration.enhancementEnabled ? "On" : "Off")
              }
            }

            if mode.name == "Terminal" {
              SectionCard(title: "Why cleanup is off here") {
                Text("A shell command must be transcribed, not prettified. A helpfully added full stop turns a working command into a broken one.")
                  .font(.callout).foregroundStyle(.secondary)
              }
            }

            SectionCard(title: "Switches on automatically for") {
              if mode.configuration.appTriggers.isEmpty && mode.configuration.siteTriggers.isEmpty {
                Text("Nothing — choose it yourself.").font(.callout).foregroundStyle(.secondary)
              } else {
                VStack(alignment: .leading, spacing: 4) {
                  ForEach(mode.configuration.appTriggers, id: \.self) { trigger in
                    Label(trigger, systemImage: "app").font(.caption)
                  }
                  ForEach(mode.configuration.siteTriggers, id: \.self) { trigger in
                    Label(trigger, systemImage: "globe").font(.caption)
                  }
                }
              }
            }
          }
          .padding(Theme.Spacing.large)
          .frame(maxWidth: 640, alignment: .leading)
        }
        } else {
          EmptyState(icon: "slider.horizontal.3", title: "Select a mode", message: "")
        }
      }
      .frame(maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Theme.paper)
  }

  private func triggerSummary(_ mode: Mode) -> String {
    let count = mode.configuration.appTriggers.count + mode.configuration.siteTriggers.count
    return count == 0 ? "manual" : "\(count) automatic trigger\(count == 1 ? "" : "s")"
  }

  private func outputName(_ target: InjectionTarget) -> String {
    switch target {
    case .cursor: "At my cursor"
    case .clipboard: "Clipboard"
    case .replaceSelection: "Replace selection"
    }
  }
}
