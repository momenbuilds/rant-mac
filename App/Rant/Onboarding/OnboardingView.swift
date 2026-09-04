import RantCore
import SwiftUI

/// First run.
///
/// The rule the whole flow follows: never ask for a permission without saying, in the
/// same breath, what it is for and what happens if you refuse. And never trap anyone —
/// every step is skippable, and every denial has a button that opens the exact System
/// Settings pane rather than telling you to go and find it.
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
      progressRail
      ScrollView {
        VStack {
          Spacer(minLength: Theme.Spacing.section)
          content
            .frame(maxWidth: 520, alignment: .leading)
          Spacer(minLength: Theme.Spacing.section)
        }
        .frame(minHeight: 420)
        .padding(.horizontal, Theme.Spacing.page)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      footer
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.paper)
    .onAppear { permissions.refresh() }
  }

  /// Seven dots rather than "Step 3 of 7". It says the same thing in less space and
  /// shows how much is left without anyone having to do arithmetic.
  private var progressRail: some View {
    HStack(spacing: 5) {
      ForEach(Step.allCases, id: \.rawValue) { item in
        Capsule()
          .fill(item.rawValue <= step.rawValue ? Theme.clay : Theme.hairline)
          .frame(width: item == step ? 20 : 7, height: 4)
          .animation(Theme.gentle, value: step)
      }
      Spacer()
    }
    .padding(.horizontal, Theme.Spacing.page)
    .padding(.top, Theme.Spacing.large)
  }

  @ViewBuilder private var content: some View {
    switch step {
    case .welcome:
      panel(title: "Rant", subtitle: "talk messy. write clean.") {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          Text("Hold a key, say what you mean — filler words, false starts, corrections and all — let go, and clean text lands where your cursor already was.")
            .foregroundStyle(Theme.ink)
          Text("Your voice, your Mac, your data. No account, no subscription, no telemetry.")
            .foregroundStyle(Theme.inkMuted)
        }
        .font(.system(size: 14))
        .fixedSize(horizontal: false, vertical: true)
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
      panel(title: "Pick your key", subtitle: "Hold it to talk. Let go to insert.") {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
          Card(padding: 0) {
            VStack(spacing: 0) {
              ForEach(Array(TriggerKey.allCases.enumerated()), id: \.element) { index, key in
                keyOption(key)
                if index < TriggerKey.allCases.count - 1 {
                  Divider().overlay(Theme.hairline).padding(.leading, 44)
                }
              }
            }
          }

          Picker("Behaviour", selection: $preferences.activationMode) {
            ForEach(ActivationMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
          }
          .labelsHidden()
          .pickerStyle(.segmented)

          Text("These are lone modifiers: they type nothing by themselves, so Rant can use one without taking a shortcut away from you. Press it together with another key and it behaves exactly as it always did.")
            .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

    case .engine:
      panel(title: "Where should the listening happen?", subtitle: nil) {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          choiceCard(
            title: "AssemblyAI, with your own key",
            detail: "Fast and accurate. Your audio goes to AssemblyAI and nowhere else, on your own account.",
            badge: .network, selected: !preferences.localOnly
          ) { preferences.localOnly = false }

          choiceCard(
            title: "Local only",
            detail: "Nothing leaves this Mac, ever. You will need to download a speech model — Rant shows the size and memory it needs before anything is fetched.",
            badge: .onDevice, selected: preferences.localOnly
          ) { preferences.localOnly = true }

          if !preferences.localOnly { keyEntry }
        }
      }

    case .privacy:
      panel(title: "What Rant does with your words", subtitle: nil) {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
              bullet("Transcripts stay in one folder on this Mac. Delete it and Rant knows nothing about you.")
              bullet("Audio is thrown away after transcription unless you ask Rant to keep it.")
              bullet("Password fields are never read from and never typed into.")
              bullet("No analytics. No crash reporting. No account. There is no Rant server.")
            }
          }
          Toggle("Let Rant use what I'm working on to write better", isOn: $preferences.contextEnabled)
            .font(.system(size: 13))
          Text("It can see the app, the window, the site and the text around your cursor. Only your recent dictations and the words just before the cursor are ever sent to your speech provider — and credential-shaped text is stripped out first.")
            .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

    case .done:
      panel(title: "That's it", subtitle: "Try it right now.") {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          HStack(spacing: 7) {
            Text("Click into any text field, hold").font(.system(size: 14))
            KeyCap(text: preferences.triggerKey.displayName)
            Text("and say something.").font(.system(size: 14))
          }
          .foregroundStyle(Theme.ink)

          Text("Escape cancels. Double-tap to keep recording hands-free. Everything else lives in the menu bar.")
            .font(.system(size: 13)).foregroundStyle(Theme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)

          Card(fill: Theme.sunken) {
            TextField("Try dictating here", text: .constant(""), axis: .vertical)
              .textFieldStyle(.plain)
              .font(.system(size: 13))
              .lineLimit(3, reservesSpace: true)
          }
        }
      }
    }
  }

  // MARK: - Pieces

  private func panel<Content: View>(
    title: String, subtitle: String?, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.system(size: 30, weight: .semibold)).foregroundStyle(Theme.ink)
        if let subtitle {
          Text(subtitle).font(.system(size: 16)).foregroundStyle(Theme.inkMuted)
        }
      }
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func keyOption(_ key: TriggerKey) -> some View {
    let selected = preferences.triggerKey == key
    return Button {
      preferences.triggerKey = key
    } label: {
      HStack(spacing: Theme.Spacing.small) {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
          .font(.system(size: 13))
          .foregroundStyle(selected ? Theme.clay : Theme.inkFaint)
          .accessibilityHidden(true)
        KeyCap(text: key.displayName)
        Spacer()
      }
      .padding(.horizontal, Theme.Spacing.medium)
      .padding(.vertical, Theme.Spacing.small)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(key.displayName)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var keyEntry: some View {
    Card {
      VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
        SecureField("Paste your AssemblyAI API key", text: $apiKey)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 13))
        HStack(spacing: Theme.Spacing.tight) {
          Button("Save to Keychain") {
            do {
              try model.saveAPIKey(apiKey)
              apiKey = ""
              keyMessage = "Saved to your Keychain."
            } catch {
              keyMessage = error.localizedDescription
            }
          }
          .buttonStyle(.clay)
          .disabled(APIKeyValidator.check(apiKey) != .looksValid)

          if model.hasAPIKey {
            Chip(text: "Key stored", systemImage: "checkmark", tint: Theme.moss, fill: Theme.mossSoft)
          }
          Spacer()
        }
        if let message = keyMessage ?? (apiKey.isEmpty ? nil : APIKeyValidator.check(apiKey).message) {
          Text(message).font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
        }
        Text("You can also do this later in Settings → Speech.")
          .font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
      }
    }
  }

  private func permissionPanel(
    copy: PermissionCopy, status: Permissions.Status, pane: Permissions.Pane,
    grant: @escaping () -> Void
  ) -> some View {
    panel(title: copy.title, subtitle: copy.required ? "Rant needs this" : "Optional") {
      VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
        Text(copy.why)
          .font(.system(size: 14)).foregroundStyle(Theme.ink)
          .fixedSize(horizontal: false, vertical: true)
        Text(copy.ifDenied)
          .font(.system(size: 13)).foregroundStyle(Theme.inkMuted)
          .fixedSize(horizontal: false, vertical: true)

        if status.isGranted {
          Chip(text: "Granted", systemImage: "checkmark", tint: Theme.moss, fill: Theme.mossSoft)
        } else {
          HStack(spacing: Theme.Spacing.tight) {
            Button("Grant \(copy.title)", action: grant).buttonStyle(.clay)
            Button("Open System Settings") { permissions.open(pane) }.buttonStyle(.quiet)
          }
          if status == .denied {
            Text("It looks like this was denied before. macOS will not ask again, so it has to be switched on in System Settings.")
              .font(.system(size: 12)).foregroundStyle(Theme.clay)
              .fixedSize(horizontal: false, vertical: true)
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
          .font(.system(size: 14))
          .foregroundStyle(selected ? Theme.clay : Theme.inkFaint)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: Theme.Spacing.tight) {
            Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.ink)
            PrivacyBadge(level: badge)
          }
          Text(detail)
            .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
        }
        Spacer(minLength: 0)
      }
      .padding(Theme.Spacing.small)
      .background(
        selected ? Theme.claySoft : Theme.surface,
        in: RoundedRectangle(cornerRadius: Theme.Radius.card))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.card)
          .strokeBorder(selected ? Theme.clay.opacity(0.45) : Theme.hairline, lineWidth: 1))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func bullet(_ text: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "checkmark")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(Theme.moss)
        .padding(.top, 3)
        .accessibilityHidden(true)
      Text(text)
        .font(.system(size: 12.5)).foregroundStyle(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var footer: some View {
    HStack(spacing: Theme.Spacing.tight) {
      if step != .welcome {
        Button("Back") { move(-1) }.buttonStyle(.quiet)
          .accessibilityIdentifier("onboarding.back")
      }
      Spacer()
      // Every step is skippable. Trapping someone in onboarding because they will not
      // grant a permission is how an app becomes uninstallable rather than useful.
      if step != .done {
        Button("Skip") { move(1) }
          .buttonStyle(.plain)
          .font(.system(size: 12))
          .foregroundStyle(Theme.inkMuted)
          .accessibilityIdentifier("onboarding.skip")
        Button("Continue") { move(1) }
          .buttonStyle(.clay)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("onboarding.continue")
      } else {
        Button("Start using Rant") {
          preferences.hasCompletedOnboarding = true
          model.installHotkeys()
        }
        .buttonStyle(.clay)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("onboarding.finish")
      }
    }
    .padding(Theme.Spacing.medium)
    .background(Theme.paper)
    .overlay(alignment: .top) { Divider().overlay(Theme.hairline) }
  }

  private func move(_ delta: Int) {
    permissions.refresh()
    let next = max(0, min(Step.allCases.count - 1, step.rawValue + delta))
    step = Step(rawValue: next) ?? .welcome
  }
}
