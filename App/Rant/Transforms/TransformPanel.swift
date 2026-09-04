import RantCore
import SwiftUI

/// The floating panel a transform runs in: pick one, read the diff, accept or reject.
///
/// The diff is the point. A rewrite you cannot inspect is a rewrite you have to trust,
/// and the master prompt (§17) asks for original versus result with accept, reject,
/// copy, and edit-before-applying. All four are here.
struct TransformPanel: View {
  @ObservedObject var controller: TransformController
  @State private var targetLanguage = "Spanish"
  @State private var customInstruction = ""

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      switch controller.phase {
      case .idle:
        Text("Select text in any app and press \(CarbonHotkey.Combination.optionShiftT.displayName).")
          .font(.system(size: 12.5)).foregroundStyle(Theme.inkMuted)

      case .choosing(let selection):
        chooser(selection)

      case .working(let name):
        HStack(spacing: Theme.Spacing.tight) {
          ProgressView().controlSize(.small)
          Text("Running \(name)…").font(.system(size: 12.5)).foregroundStyle(Theme.inkMuted)
        }

      case .reviewing(let preview):
        review(preview)

      case .failed(let message):
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          Text(message).font(.system(size: 12.5)).foregroundStyle(Theme.live)
            .fixedSize(horizontal: false, vertical: true)
          Button("Close") { controller.reject() }.buttonStyle(.quiet)
        }
      }
    }
    .padding(Theme.Spacing.medium)
    .frame(minWidth: 420, minHeight: 240, alignment: .topLeading)
    .background(Theme.paper)
  }

  // MARK: - Choosing

  private func chooser(_ selection: String) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Text("\(selection.split(separator: " ").count) words selected")
        .font(Theme.label).tracking(0.7).foregroundStyle(Theme.inkFaint)
      Text(selection)
        .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)

      Divider().overlay(Theme.hairline)

      ScrollView {
        VStack(spacing: 0) {
          ForEach(controller.transforms) { transform in
            Button {
              controller.run(
                transform,
                targetLanguage: transform.needsTargetLanguage ? targetLanguage : nil,
                custom: transform.needsCustomInstruction ? customInstruction : nil)
            } label: {
              HStack {
                Text(transform.name).font(.system(size: 13))
                  .foregroundStyle(Theme.ink)
                Spacer()
                if transform.needsTargetLanguage { Chip(text: "language") }
              }
              .padding(.vertical, 6)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(transform.needsCustomInstruction && customInstruction.isEmpty)
          }
        }
      }
      .frame(maxHeight: 220)

      // Only the transforms that need them, so the common case stays one click.
      if controller.transforms.contains(where: \.needsTargetLanguage) {
        TextField("Translate into", text: $targetLanguage)
          .textFieldStyle(.roundedBorder).font(.system(size: 12))
      }
      if controller.transforms.contains(where: \.needsCustomInstruction) {
        TextField("Custom instruction", text: $customInstruction)
          .textFieldStyle(.roundedBorder).font(.system(size: 12))
      }
    }
  }

  // MARK: - Reviewing

  private func review(_ preview: TransformPreview) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      let summary = preview.summary
      HStack(spacing: Theme.Spacing.tight) {
        Text("\(summary.inserted) added · \(summary.deleted) removed")
          .font(Theme.label).tracking(0.7).foregroundStyle(Theme.inkFaint)
        if preview.isUnchanged {
          Chip(text: "no change")
        }
        Spacer()
      }

      DiffText(runs: preview.diff)
        .frame(maxHeight: 120)

      Text("Result — edit before applying if you want")
        .font(Theme.label).tracking(0.7).foregroundStyle(Theme.inkFaint)
      TextEditor(text: $controller.edited)
        .font(.system(size: 12.5))
        .frame(minHeight: 70, maxHeight: 140)
        .overlay(
          RoundedRectangle(cornerRadius: Theme.Radius.control)
            .strokeBorder(Theme.hairline, lineWidth: 1))

      HStack(spacing: Theme.Spacing.tight) {
        Button("Replace selection") { controller.accept() }
          .buttonStyle(.clay)
          .keyboardShortcut(.return, modifiers: [])
        Button("Copy") { controller.copyResult() }.buttonStyle(.quiet)
        Button("Back") { controller.backToChoosing() }.buttonStyle(.quiet)
        Spacer()
        Button("Reject") { controller.reject() }
          .buttonStyle(.quiet)
          .keyboardShortcut(.escape, modifiers: [])
      }
    }
  }
}

/// The diff itself: inserted words tinted, deleted words struck through.
///
/// Rendered as flowing text rather than two columns because a transform usually
/// changes a few words in a sentence, and two panes make the reader hunt for them.
struct DiffText: View {
  let runs: [DiffRun]

  var body: some View {
    ScrollView {
      Text(attributed)
        .font(.system(size: 12.5))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var attributed: AttributedString {
    var out = AttributedString()
    for run in runs {
      var piece = AttributedString(run.text + " ")
      switch run.operation {
      case .insert:
        piece.foregroundColor = Theme.moss
        piece.inlinePresentationIntent = .stronglyEmphasized
      case .delete:
        piece.foregroundColor = Theme.live
        piece.strikethroughStyle = .single
      case .equal:
        piece.foregroundColor = Theme.ink
      }
      out.append(piece)
    }
    return out
  }
}
