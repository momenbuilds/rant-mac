import RantCore
import SwiftUI
import UniformTypeIdentifiers

/// The Migration Center.
///
/// The pitch is "bring your voice history home", and the design follows from taking
/// that seriously: you choose a file, you see exactly what Rant found *before*
/// anything is written, and the source is never touched. A dry run is the default
/// because an import you cannot inspect first is an import you cannot trust.
struct MigrateView: View {
  @EnvironmentObject private var model: AppModel

  @State private var source: URL?
  @State private var preview: MigrationPreview?
  @State private var result: MigrationResult?
  @State private var history: [MigrationRunRecord] = []
  @State private var busy = false
  @State private var errorMessage: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.large) {
        header
        chooseStep
        if let preview { previewStep(preview) }
        if let result { resultStep(result) }
        if !history.isEmpty { historySection }
        promises
      }
      .padding(Theme.Spacing.large)
      .frame(maxWidth: 780, alignment: .leading)
    }
    .frame(maxWidth: .infinity)
    .navigationTitle("Migrate")
    .onAppear(perform: reloadHistory)
    .alert("Could not read that", isPresented: .constant(errorMessage != nil)) {
      Button("OK") { errorMessage = nil }
    } message: { Text(errorMessage ?? "") }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Bring your voice history home").font(.largeTitle.weight(.semibold))
      Text("Import from Wispr Flow, VoiceInk, Superwhisper, Otter, or any transcript file you have. Your originals are opened read-only and never changed.")
        .foregroundStyle(.secondary)
    }
  }

  private var chooseStep: some View {
    SectionCard(title: "1 · Choose what to import") {
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        HStack {
          Button("Choose a file…") { choose(directory: false) }
          Button("Choose a folder…") { choose(directory: true) }
          if busy { ProgressView().controlSize(.small) }
        }
        if let source {
          Label(source.lastPathComponent, systemImage: "doc")
            .font(.callout).foregroundStyle(.secondary)
        }
        Text("Supported: Rant Archive, Wispr Flow, VoiceInk, Superwhisper and Otter exports, plus plain TXT, Markdown, JSON, JSONL, CSV, SRT and VTT — or a whole folder of them.")
          .font(.caption).foregroundStyle(.tertiary)
      }
    }
  }

  private func previewStep(_ preview: MigrationPreview) -> some View {
    SectionCard(
      title: "2 · What Rant found",
      subtitle: "Read from \(preview.sourceName). Nothing has been written yet."
    ) {
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        HStack(spacing: Theme.Spacing.large) {
          count("Transcripts", preview.transcripts)
          count("Meetings", preview.meetings)
          count("Notes", preview.notes)
          count("Dictionary", preview.dictionaryEntries)
          count("Snippets", preview.snippets)
        }
        if let earliest = preview.earliest, let latest = preview.latest {
          Text("\(earliest.formatted(date: .abbreviated, time: .omitted)) — \(latest.formatted(date: .abbreviated, time: .omitted))")
            .font(.caption).foregroundStyle(.secondary)
        }
        if preview.unsupported > 0 || preview.malformed > 0 {
          Label(
            "\(preview.unsupported) unsupported, \(preview.malformed) unreadable — these will be listed in the report rather than guessed at",
            systemImage: "info.circle")
            .font(.caption).foregroundStyle(Theme.accent)
        }
        HStack {
          Button("Import \(preview.total) items") { run(dryRun: false) }
            .buttonStyle(.borderedProminent)
            .disabled(busy || preview.total == 0)
          Button("Dry run again") { run(dryRun: true) }
            .disabled(busy)
        }
      }
    }
  }

  private func resultStep(_ result: MigrationResult) -> some View {
    SectionCard(title: "3 · Report") {
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        HStack(spacing: Theme.Spacing.large) {
          count("Imported", result.imported)
          count("Already had", result.duplicatesSkipped)
          count("Skipped", result.malformedSkipped)
          count("Unsupported", result.unsupported)
        }
        if !result.errors.isEmpty {
          VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(result.errors.prefix(12).enumerated()), id: \.offset) { _, issue in
              Text("\(issue.file): \(issue.reason)")
                .font(.caption).foregroundStyle(.secondary)
            }
            if result.errors.count > 12 {
              Text("…and \(result.errors.count - 12) more").font(.caption2).foregroundStyle(.tertiary)
            }
          }
        }
        Text("Re-running the same import is safe: matching records are recognised and skipped rather than duplicated.")
          .font(.caption).foregroundStyle(.tertiary)
      }
    }
  }

  private var historySection: some View {
    SectionCard(title: "Past imports") {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(history) { run in
          HStack {
            VStack(alignment: .leading, spacing: 1) {
              Text(run.sourceName).font(.callout)
              Text(run.startedAt, format: .dateTime.day().month().hour().minute())
                .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(run.dryRun ? "dry run" : "\(run.imported) imported")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var promises: some View {
    SectionCard(title: "What migration will never do") {
      VStack(alignment: .leading, spacing: 6) {
        promise("Change, move or delete anything in the folder you chose")
        promise("Open a file you did not point it at")
        promise("Decrypt anything, or touch another app's passwords or cookies")
        promise("Bypass another app's protection to get at data")
        promise("Send any of it anywhere")
      }
    }
  }

  private func promise(_ text: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "xmark.shield").font(.caption).foregroundStyle(Theme.success)
      Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func count(_ label: String, _ value: Int) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value.formatted()).font(.title3.weight(.semibold)).monospacedDigit()
      Text(label).font(.caption2).foregroundStyle(.secondary)
    }
  }

  // MARK: - Actions

  private func choose(directory: Bool) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = !directory
    panel.canChooseDirectories = directory
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    source = url
    result = nil
    run(dryRun: true)
  }

  private func run(dryRun: Bool) {
    guard let source, let database = model.databaseHandle else { return }
    busy = true
    Task {
      defer { busy = false }
      let runner = MigrationRunner(database: database)
      do {
        if dryRun {
          preview = try await runner.preview(source)
          result = nil
        } else {
          var options = MigrationOptions()
          options.dryRun = false
          result = try await runner.run(source, options: options)
          model.refreshHistory()
          reloadHistory()
        }
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func reloadHistory() {
    guard let database = model.databaseHandle else { return }
    history = (try? MigrationRunner(database: database).history(limit: 10)) ?? []
  }
}
