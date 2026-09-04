import RantCore
import SwiftUI

@main
struct RantApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup("Rant") {
      RootView()
        .environmentObject(model)
        .environmentObject(model.preferences)
        .environmentObject(model.permissions)
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { model.start() }
        .onReceive(NotificationCenter.default.publisher(for: .rantCancelDictation)) { _ in
          model.cancelDictation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .rantFinishDictation)) { _ in
          model.stopDictation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .rantRetryDictation)) { _ in
          model.retryLast()
        }
        // Clicking a failed bar brings the app forward on History, where the full
        // error and whatever text survived the failure can actually be read.
        .onReceive(NotificationCenter.default.publisher(for: .rantOpenAfterFailure)) { _ in
          model.destination = "history"
          NSApp.activate(ignoringOtherApps: true)
        }
    }
    .defaultSize(width: 1_100, height: 720)
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandMenu("Dictation") {
        Button("Start or Stop Dictation") { model.toggleDictation() }
          .keyboardShortcut("d", modifiers: [.command, .shift])
        Button("Paste Last Transcript") { model.pasteLast() }
          .keyboardShortcut("v", modifiers: [.command, .shift, .option])
        Button("Retry Last") { model.retryLast() }
        Divider()
        Button("Cancel") { model.cancelDictation() }
          .keyboardShortcut(.escape, modifiers: [])
      }
    }

    MenuBarExtra {
      MenuBarContent()
        .environmentObject(model)
        .environmentObject(model.preferences)
    } label: {
      // The menu bar icon is the app's only always-visible surface, so it carries the
      // one piece of state that matters: whether the microphone is live.
      Image(systemName: model.state.isBusy ? "waveform.circle.fill" : "waveform")
        .accessibilityLabel(model.state.isBusy ? "Rant is listening" : "Rant")
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Closing the window leaves Rant running in the menu bar, which is where it does
    // its job. Quit is an explicit choice.
    false
  }
}
