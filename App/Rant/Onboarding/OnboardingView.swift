import RantCore
import SwiftUI

/// First run.
///
/// The design rule here: never ask for a permission without saying, in the same
/// breath, what it is for and what happens if you say no. And never leave someone
/// stuck — every step can be skipped, and every denial has a button that opens the
/// exact System Settings pane rather than telling you to go and find it.
struct OnboardingView: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var preferences: Preferences
  @EnvironmentObject private var permissions: Permissions
  @State private var step: Step = .welcome
  @State private var apiKey = ""
  @State private var keyMessage: String?

  enum Step: Int, CaseIterable {
    case welcome, microphone, accessibility, trigger, engine, privacy, done
  }

  var body: some View {
    VStack(spacing: 0) {
      content
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .center)
        .padding(Theme.Spacing.section)
      footer
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    .onAppear { permissions.refresh() }
  }

  @ViewBuilder private var content: some View {
    switch step {
    case .welcome:
      panel(
        icon: "waveform",
        title: "Rant",
        subtitle: "talk messy. write clean."
      ) {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          Text("Hold a key, say what you mean — filler words, false starts, corrections and all — let go, and clean text lands where your cursor already was.")
          Text("Your voice, your Mac, your data. No account, no subscription, no telemetry.")
            .foregroundStyle(.secondary)
        }
      }

    case .microphone:
      permissionPanel(
        copy: .microphone, status: permissions.microphone, pane: .microphone,
        grant: { Task { await permissions.requestMicrophone() } })

    case .accessibility:
      permissionPanel(
        copy: .accessibility, status: permissions.accessibility, pane: .accessibility,
        grant: { permissions.requestAccessibility() })

    case .trigger:
      panel(icon: "keyboard", title: "Pick your key", subtitle: "Hold it to talk. Let go to insert.") {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
          Picker("Key", selection: $preferences.triggerKey) {
            ForEach(TriggerKey.allCases, id: \.self) { Text($0.displayName).tag($0) }
          }
          .pickerStyle(.radioGroup)
          Picker("Behaviour", selection: $preferences.activationMode) {
            ForEach(ActivationMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
          }
          Text("These are lone modifiers: they type nothing by themselves, so Rant can use one without taking a shortcut away from you. Press it together with another key and it behaves exactly as it always did.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }

    case .engine:
      panel(icon: "cpu", title: "Where should the listening happen?", subtitle: nil) {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
          choiceCard(
            title: "AssemblyAI, with your own key",
            detail: "Fast and accurate. Your audio goes to AssemblyAI and nowhere else, on your own account.",
            badge: .network,
            selected: !preferences.localOnly
          ) { preferences.localOnly = false }

          choiceCard(
            title: "Local only",
            detail: "Nothing leaves this Mac, ever. You will need to download a speech model — Rant will tell you how much space it needs first.",
            badge: .onDevice,
            selected: preferences.localOnly
          ) { preferences.localOnly = true }

          if !preferences.localOnly {
            VStack(alignment: .leading, spacing: 6) {
              SecureField("Paste your AssemblyAI API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
              HStack {
                Button("Save to Keychain") {
                  do {
                    try model.saveAPIKey(apiKey)
                    apiKey = ""
                    keyMessage = "Saved to your Keychain."
                  } catch {
                    keyMessage = error.localizedDescription
                  }
                }
                .disabled(APIKeyValidator.check(apiKey) != .looksValid)
                if model.hasAPIKey {
                  Label("Key stored", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(Theme.success)
                }
              }
              if let message = keyMessage ?? (apiKey.isEmpty ? nil : APIKeyValidator.check(apiKey).message) {
                Text(message).font(.caption).foregroundStyle(.secondary)
              }
              Text("You can also do this later in Settings → Speech.")
                .font(.caption).foregroundStyle(.tertiary)
            }
          }
        }
      }

    case .privacy:
      panel(icon: "hand.raised", title: "What Rant does with your words", subtitle: nil) {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          bullet("Transcripts stay in one folder on this Mac. Delete the folder and Rant knows nothing about you.")
          bullet("Audio is thrown away after transcription unless you ask Rant to keep it.")
          bullet("Password fields are never read from and never typed into.")
          bullet("No analytics. No crash reporting. No account. There is no Rant server.")
          Toggle("Let Rant use what I'm working on to write better", isOn: $preferences.contextEnabled)
            .padding(.top, Theme.Spacing.small)
          Text("It can see the app, the window, the site and the text around your cursor. Only your recent dictations and the words just before the cursor are ever sent to your speech provider — and credential-shaped text is stripped out first.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }

    case .done:
      panel(icon: "checkmark.circle", title: "That's it", subtitle: "Try it right now.") {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          Text("Click into any text field — this one, an email, your editor — then hold **\(preferences.triggerKey.displayName)** and say something. Let go.")
          Text("Escape cancels. Double-tap to keep recording hands-free. Everything else lives in the menu bar.")
            .foregroundStyle(.secondary)
          TextField("Try dictating here", text: .constant(""), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(3, reservesSpace: true)
            .padding(.top, Theme.Spacing.small)
        }
      }
    }
  }

  private func panel<Content: View>(
    icon: String, title: String, subtitle: String?, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      Image(systemName: icon)
        .font(.system(size: 34, weight: .light))
        .foregroundStyle(Theme.accent)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.largeTitle.weight(.semibold))
        if let subtitle {
          Text(subtitle).font(.title3).foregroundStyle(.secondary)
        }
      }
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func permissionPanel(
    copy: PermissionCopy, status: Permissions.Status, pane: Permissions.Pane,
    grant: @escaping () -> Void
  ) -> some View {
    panel(icon: "lock.shield", title: copy.title, subtitle: copy.required ? "Rant needs this" : "Optional") {
      VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
        Text(copy.why)
        Text(copy.ifDenied).font(.callout).foregroundStyle(.secondary)
        if status.isGranted {
          Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
        } else {
          HStack {
            Button("Grant \(copy.title)", action: grant).buttonStyle(.borderedProminent)
            Button("Open System Settings") { permissions.open(pane) }
          }
          if status == .denied {
            Text("It looks like this was denied before. macOS will not ask again, so it has to be switched on in System Settings.")
              .font(.caption).foregroundStyle(Theme.accent)
          }
        }
      }
    }
  }

  private func choiceCard(
    title: String, detail: String, badge: PrivacyBadge.Level, selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: Theme.Spacing.small) {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(selected ? Theme.accent : .secondary)
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(title).font(.callout.weight(.medium))
            PrivacyBadge(level: badge)
          }
          Text(detail).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
      }
      .padding(Theme.Spacing.small)
      .background(
        selected ? Theme.accent.opacity(0.08) : Color.clear,
        in: RoundedRectangle(cornerRadius: Theme.Radius.small))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.small)
          .strokeBorder(selected ? AnyShapeStyle(Theme.accent.opacity(0.5)) : AnyShapeStyle(.separator), lineWidth: 1))
    }
    .buttonStyle(.plain)
  }

  private func bullet(_ text: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "checkmark").font(.caption).foregroundStyle(Theme.success)
      Text(text).fixedSize(horizontal: false, vertical: true)
    }
  }

  private var footer: some View {
    HStack {
      if step != .welcome {
        Button("Back") { move(-1) }
          .accessibilityIdentifier("onboarding.back")
      }
      Spacer()
      // Every step is skippable. Trapping someone in onboarding because they will not
      // grant a permission is how an app becomes uninstallable rather than useful.
      if step != .done {
        // Identifiers rather than labels: these are the controls the UI tests drive,
        // and a test that breaks when a word changes is a test people delete.
        Button("Skip") { move(1) }
          .buttonStyle(.link)
          .accessibilityIdentifier("onboarding.skip")
        Button("Continue") { move(1) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("onboarding.continue")
      } else {
        Button("Start using Rant") {
          preferences.hasCompletedOnboarding = true
          model.installHotkeys()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("onboarding.finish")
      }
    }
    .padding(Theme.Spacing.medium)
    .background(.bar)
  }

  private func move(_ delta: Int) {
    permissions.refresh()
    let next = max(0, min(Step.allCases.count - 1, step.rawValue + delta))
    step = Step(rawValue: next) ?? .welcome
  }
}
