import RantCore
import SwiftUI

/// The menu bar menu — the surface most people will actually use day to day.
struct MenuBarContent: View {
  @EnvironmentObject private var model: AppModel
  @EnvironmentObject private var preferences: Preferences
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button(model.state.isBusy ? "Stop Dictation" : "Start Dictation") {
      model.toggleDictation()
    }
    .keyboardShortcut("d", modifiers: [.command, .shift])

    Button("Paste Last Transcript") { model.pasteLast() }
      .disabled(model.recentTranscripts.isEmpty)

    if case .failure(_, true) = model.state {
      Button("Retry Last Dictation") { model.retryLast() }
    }

    Divider()

    Menu("Cleanup: \(preferences.cleanupLevel.displayName)") {
      ForEach(CleanupLevel.allCases, id: \.self) { level in
        Button {
          preferences.cleanupLevel = level
        } label: {
          if preferences.cleanupLevel == level {
            Label(level.displayName, systemImage: "checkmark")
          } else {
            Text(level.displayName)
          }
        }
      }
    }

    // The context kill switch, one click from anywhere. Deliberately at the top
    // level rather than inside a submenu: if you need it, you need it now.
    Toggle("Use context from what I'm doing", isOn: Binding(
      get: { preferences.contextEnabled },
      set: { preferences.contextEnabled = $0 }))

    Toggle("Local only (nothing leaves this Mac)", isOn: Binding(
      get: { preferences.localOnly },
      set: { preferences.localOnly = $0; model.buildSession() }))

    Divider()

    if let latest = model.recentTranscripts.first {
      Section("Most recent") {
        Button(latest.finalText.prefix(48) + (latest.finalText.count > 48 ? "…" : "")) {
          model.copy(latest.finalText)
        }
      }
    }

    Button("Open Rant") {
      NSApp.activate(ignoringOtherApps: true)
      openWindow(id: "main")
    }

    Divider()
    Button("Quit Rant") { NSApp.terminate(nil) }
      .keyboardShortcut("q")
  }
}
