import RantCore
import SwiftUI

/// Writing styles, and where each one applies.
///
/// The screen is built around the resolution order rather than around a list,
/// because the question people actually have is "which style will I get *here*",
/// and a flat list of styles cannot answer it.
struct StylesView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var preferences: Preferences
  @State private var selection: String?
  @State private var editing: WritingStyle?
  @State private var newRuleKey = ""

  private var styles: [WritingStyle] { preferences.allStyles }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      PageTitle(
        title: "Styles",
        subtitle: "How Rant writes for you, and where each one applies.",
        accessory: AnyView(
          Button {
            editing = WritingStyle(
              name: "My style", instructions: "Write the way I would.", builtIn: false)
          } label: {
            Label("New style", systemImage: "plus")
          }
          .buttonStyle(.clay)))
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
    .sheet(item: $editing) { style in
      StyleEditor(style: style) { saved in
        var custom = preferences.customStyles
        if let index = custom.firstIndex(where: { $0.name == style.name }) {
          custom[index] = saved
        } else {
          custom.append(saved)
        }
        preferences.customStyles = custom
        selection = saved.id
        editing = nil
      } onCancel: {
        editing = nil
      }
    }
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

          rules(style)

          if !style.builtIn {
            HStack(spacing: Theme.Spacing.tight) {
              Button("Edit") { editing = style }.buttonStyle(.quiet)
              Button("Delete", role: .destructive) { delete(style) }.buttonStyle(.quiet)
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

  /// The rules that make a style apply somewhere.
  ///
  /// Editable here rather than in a separate settings pane, because "where does this
  /// style apply" is the question you have while looking at the style.
  @ViewBuilder private func rules(_ style: WritingStyle) -> some View {
    SectionCard(
      title: "Where this applies",
      subtitle: "Rant matches the app you are in and the site you are on."
    ) {
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        Toggle(
          "Use as my global default",
          isOn: Binding(
            get: { preferences.styleResolver.defaultStyleName == style.name },
            set: { on in
              var resolver = preferences.styleResolver
              resolver.defaultStyleName = on ? style.name : "Natural"
              preferences.styleResolver = resolver
            }))

        Picker(
          "Default for",
          selection: Binding<String>(
            get: {
              preferences.styleResolver.perCategory
                .first { $0.value == style.name }?.key.rawValue ?? ""
            },
            set: { raw in
              var resolver = preferences.styleResolver
              for (category, name) in resolver.perCategory where name == style.name {
                resolver.perCategory[category] = nil
              }
              if let category = UsageCategory(rawValue: raw) {
                resolver.perCategory[category] = style.name
              }
              preferences.styleResolver = resolver
            })
        ) {
          Text("No category").tag("")
          ForEach(UsageCategory.allCases, id: \.self) { category in
            Text(category.displayName).tag(category.rawValue)
          }
        }

        ruleList(
          title: "Apps", entries: preferences.styleResolver.perApp, style: style,
          placeholder: "com.apple.mail"
        ) { key, add in
          var resolver = preferences.styleResolver
          if add { resolver.perApp[key] = style.name } else { resolver.perApp[key] = nil }
          preferences.styleResolver = resolver
        }

        ruleList(
          title: "Sites", entries: preferences.styleResolver.perSite, style: style,
          placeholder: "github.com"
        ) { key, add in
          var resolver = preferences.styleResolver
          if add { resolver.perSite[key] = style.name } else { resolver.perSite[key] = nil }
          preferences.styleResolver = resolver
        }
      }
    }
  }

  @ViewBuilder private func ruleList(
    title: String, entries: [String: String], style: WritingStyle, placeholder: String,
    change: @escaping (String, Bool) -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title.uppercased()).font(Theme.label).tracking(0.7)
        .foregroundStyle(Theme.inkFaint)
      ForEach(entries.filter { $0.value == style.name }.keys.sorted(), id: \.self) { key in
        HStack {
          Text(key).font(.system(size: 12))
          Spacer()
          Button {
            change(key, false)
          } label: {
            Image(systemName: "minus.circle").foregroundStyle(Theme.inkFaint)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Remove \(key)")
        }
      }
      HStack {
        TextField(placeholder, text: $newRuleKey)
          .textFieldStyle(.roundedBorder).font(.system(size: 12))
        Button("Add") {
          let key = newRuleKey.trimmingCharacters(in: .whitespaces).lowercased()
          guard !key.isEmpty else { return }
          change(key, true)
          newRuleKey = ""
        }
        .buttonStyle(.quiet)
        .disabled(newRuleKey.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
  }

  private func delete(_ style: WritingStyle) {
    preferences.customStyles.removeAll { $0.name == style.name }
    var resolver = preferences.styleResolver
    // A rule pointing at a style that no longer exists would silently fall through to
    // the default, which looks like the rule being ignored.
    resolver.perApp = resolver.perApp.filter { $0.value != style.name }
    resolver.perSite = resolver.perSite.filter { $0.value != style.name }
    resolver.perCategory = resolver.perCategory.filter { $0.value != style.name }
    if resolver.defaultStyleName == style.name { resolver.defaultStyleName = "Natural" }
    preferences.styleResolver = resolver
    selection = nil
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

/// Write a style in your own words.
///
/// The instruction is a plain text field rather than a set of switches on purpose: the
/// whole prompt is shown on the detail screen, so what you type here is exactly what
/// Rant will be told, with nothing added behind your back.
struct StyleEditor: View {
  @State private var name: String
  @State private var instructions: String
  private let original: WritingStyle
  private let onSave: (WritingStyle) -> Void
  private let onCancel: () -> Void

  init(
    style: WritingStyle, onSave: @escaping (WritingStyle) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.original = style
    self._name = State(initialValue: style.name)
    self._instructions = State(initialValue: style.instructions)
    self.onSave = onSave
    self.onCancel = onCancel
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      Text(original.builtIn ? "Copy of a built-in style" : "Your style")
        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)

      TextField("Name", text: $name)
        .textFieldStyle(.roundedBorder)

      Text("Instruction")
        .font(Theme.label).tracking(0.7).foregroundStyle(Theme.inkFaint)
      TextEditor(text: $instructions)
        .font(.system(size: 12.5))
        .frame(minHeight: 120)
        .overlay(
          RoundedRectangle(cornerRadius: Theme.Radius.control)
            .strokeBorder(Theme.hairline, lineWidth: 1))

      HStack {
        Spacer()
        Button("Cancel", action: onCancel).buttonStyle(.quiet)
        Button("Save") {
          onSave(
            WritingStyle(
              name: name.trimmingCharacters(in: .whitespaces),
              instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
              builtIn: false))
        }
        .buttonStyle(.clay)
        .disabled(
          name.trimmingCharacters(in: .whitespaces).isEmpty
            || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(Theme.Spacing.large)
    .frame(width: 460)
    .background(Theme.paper)
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
