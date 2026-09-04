import Foundation

/// The things a built-in action is allowed to touch.
///
/// Everything is optional and everything is injected. An action whose port is missing
/// refuses at execution time with `notConfigured`, which means a build that never wires
/// up a command runner cannot run a command — the capability is absent rather than
/// merely switched off, and there is no code path that constructs one on demand.
public struct ActionEnvironment: Sendable {
  public var notes: NoteStore?
  public var pasteboard: PasteboardAccess?
  public var injector: TextInjector?
  public var submitter: ActionSubmitting?
  public var urlOpener: ActionURLOpening?
  public var commandRunner: ActionCommandRunning?
  /// The program the user configured, if they configured one. Nil is the shipped
  /// state, and `LocalCommand`'s initialiser is the only way for it to stop being nil.
  public var command: LocalCommand?
  public var now: @Sendable () -> Date

  public init(
    notes: NoteStore? = nil,
    pasteboard: PasteboardAccess? = nil,
    injector: TextInjector? = nil,
    submitter: ActionSubmitting? = nil,
    urlOpener: ActionURLOpening? = nil,
    commandRunner: ActionCommandRunning? = nil,
    command: LocalCommand? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.notes = notes
    self.pasteboard = pasteboard
    self.injector = injector
    self.submitter = submitter
    self.urlOpener = urlOpener
    self.commandRunner = commandRunner
    self.command = command
    self.now = now
  }
}

/// The capabilities Rant ships with.
///
/// Six of them, and the list is meant to stay short. Each one is a definition rather
/// than a function so the registry can show its permission, its schema and its preview
/// sentence without running anything, and so a reviewer can read the whole surface of
/// "what a voice can cause" in one file.
public enum BuiltInActions {

  public enum ID {
    public static let createNote = "rant.note.create"
    public static let copy = "rant.clipboard.copy"
    public static let pasteAndSend = "rant.text.pasteAndSend"
    public static let openURL = "rant.url.open"
    public static let createReminder = "rant.reminder.create"
    public static let runCommand = "rant.command.run"
  }

  public static func all(_ environment: ActionEnvironment) -> [ActionDefinition] {
    [
      createNote(environment),
      copy(environment),
      pasteAndSend(environment),
      openURL(environment),
      createReminder(environment),
      runCommand(environment),
    ]
  }

  public static func install(into registry: ActionRegistry, environment: ActionEnvironment) async {
    await registry.register(all(environment))
  }

  // MARK: - Local data

  /// Put the text in today's scratchpad.
  ///
  /// Appending to the day's note rather than creating one per utterance matches what
  /// `NoteStore.appendToScratchpad` is for. Undo restores the body that was there
  /// before — or deletes the note when the append created it — because "undo" that
  /// leaves a half-written note behind is not undo.
  static func createNote(_ environment: ActionEnvironment) -> ActionDefinition {
    ActionDefinition(
      id: ID.createNote,
      title: "Save to scratchpad",
      permission: .createsLocalData,
      schema: ActionInputSchema([ActionInputField("text", .text)]),
      undoDescription: "Removes what was just added to the scratchpad.",
      describe: { input in
        let text = input["text"] ?? ""
        return "Add \(text.count) characters to today's scratchpad note."
      },
      perform: { input in
        guard let notes = environment.notes else {
          throw ActionError.notConfigured("The scratchpad")
        }
        let text = try input.string("text")
        let date = environment.now()
        let title = NoteStore.scratchpadTitle(for: date)
        let existing = try notes.notes(titled: title).first
        let note = try notes.appendToScratchpad(text, at: date)
        guard let id = note.id else {
          return ActionEffect(summary: "Saved to the scratchpad.")
        }
        let previousBody = existing?.body
        return ActionEffect(
          summary: "Saved \(text.count) characters to \(title).",
          undo: ActionUndo("Remove that from the scratchpad.") {
            if let previousBody {
              try notes.update(id: id, body: previousBody, at: date)
            } else {
              try notes.delete(id: id)
            }
          })
      })
  }

  /// A reminder, kept where every other local thing is kept.
  ///
  /// A note tagged `reminder` rather than an entry in the system Reminders app: writing
  /// to Reminders means an EventKit permission prompt and a copy of what the user said
  /// in a database Rant does not control, which is the opposite of what this app
  /// promises. A reminder that stays local is a smaller feature and an honest one.
  static func createReminder(_ environment: ActionEnvironment) -> ActionDefinition {
    ActionDefinition(
      id: ID.createReminder,
      title: "Create a local reminder",
      permission: .createsLocalData,
      schema: ActionInputSchema([
        ActionInputField("text", .text),
        ActionInputField("due", .date, required: false),
      ]),
      undoDescription: "Deletes the reminder note.",
      describe: { input in
        let due = input["due"].map { " due \($0)" } ?? ""
        return "Create a local reminder\(due) in Rant's notes."
      },
      perform: { input in
        guard let notes = environment.notes else {
          throw ActionError.notConfigured("The scratchpad")
        }
        let text = try input.string("text")
        let body = input["due"].map { "Due: \($0)\n\n\(text)" } ?? text
        let note = try notes.create(
          title: "Reminder", body: body, tags: ["reminder"], at: environment.now())
        guard let id = note.id else { return ActionEffect(summary: "Reminder saved.") }
        return ActionEffect(
          summary: "Reminder saved to Rant's notes.",
          undo: ActionUndo("Delete the reminder.") { try notes.delete(id: id) })
      })
  }

  // MARK: - Text and clipboard

  static func copy(_ environment: ActionEnvironment) -> ActionDefinition {
    ActionDefinition(
      id: ID.copy,
      title: "Copy the result",
      permission: .clipboard,
      schema: ActionInputSchema([ActionInputField("text", .text)]),
      undoDescription: "Puts back what was on the clipboard before.",
      describe: { input in
        "Put \((input["text"] ?? "").count) characters on the clipboard."
      },
      perform: { input in
        guard let pasteboard = environment.pasteboard else {
          throw ActionError.notConfigured("The clipboard")
        }
        let text = try input.string("text")
        // Read first: dictation should not cost the user whatever they had copied, and
        // the only moment that value still exists is before the write.
        let previous = pasteboard.read()
        pasteboard.write(text)
        return ActionEffect(
          summary: "Copied \(text.count) characters.",
          undo: ActionUndo("Restore the previous clipboard.") {
            pasteboard.write(previous ?? "")
          })
      })
  }

  /// Paste the text where the user was typing, then press Return.
  ///
  /// Confirmed every time regardless of its permission. The Return is what makes this
  /// different from ordinary injection: it hands the text to somebody else, and no undo
  /// exists for a message that has already been sent.
  static func pasteAndSend(_ environment: ActionEnvironment) -> ActionDefinition {
    ActionDefinition(
      id: ID.pasteAndSend,
      title: "Paste and send",
      permission: .textOnly,
      schema: ActionInputSchema([ActionInputField("text", .text)]),
      confirmation: .always,
      undoDescription: nil,
      describe: { input in
        "Paste \((input["text"] ?? "").count) characters into the focused app and press Return."
      },
      perform: { input in
        guard let injector = environment.injector else {
          throw ActionError.notConfigured("Text injection")
        }
        guard let submitter = environment.submitter else {
          throw ActionError.notConfigured("Sending")
        }
        let text = try input.string("text")
        let outcome = try await injector.inject(InjectionRequest(text: text, target: .cursor))
        // Return is only pressed when the text actually landed. Pressing it after a
        // refusal, or after the text was left on the clipboard, sends an empty message
        // or whatever was already in the field.
        guard outcome == .insertedDirectly || outcome == .pastedViaClipboard else {
          return ActionEffect(summary: "The text was not pasted, so nothing was sent.")
        }
        try await submitter.submit()
        return ActionEffect(summary: "Pasted \(text.count) characters and pressed Return.")
      })
  }

  // MARK: - Outside the app

  static func openURL(_ environment: ActionEnvironment) -> ActionDefinition {
    ActionDefinition(
      id: ID.openURL,
      title: "Open a link",
      permission: .opensURL,
      schema: ActionInputSchema([ActionInputField("url", .url)]),
      undoDescription: nil,
      describe: { input in "Open \(input["url"] ?? "") in your browser." },
      perform: { input in
        guard let opener = environment.urlOpener else {
          throw ActionError.notConfigured("Opening links")
        }
        // Validated twice: the schema refused everything but the allowed schemes, and
        // this is the last point before the URL leaves Rant.
        let url = try ActionURLPolicy.validated(try input.string("url"))
        try await opener.open(url)
        return ActionEffect(summary: "Opened \(url.absoluteString).")
      })
  }

  /// Hand the finished text to the program the user configured.
  ///
  /// The text is one element of an argument array and is never part of a command
  /// string; see `LocalCommand`. The action refuses outright when no command has been
  /// configured, so this is a capability the user switches on by naming a program, not
  /// one that ships live and waits for a phrase.
  static func runCommand(_ environment: ActionEnvironment) -> ActionDefinition {
    ActionDefinition(
      id: ID.runCommand,
      title: "Send to your command",
      permission: .runsCommand,
      schema: ActionInputSchema([ActionInputField("text", .text)]),
      undoDescription: nil,
      describe: { input in
        guard let command = environment.command else {
          return "No local command has been configured."
        }
        let arguments = command.fixedArguments.joined(separator: " ")
        let text = input["text"] ?? ""
        return "Run \(command.executablePath) \(arguments) with \(text.count) characters "
          + "of text as its final argument."
      },
      perform: { input in
        guard let command = environment.command else {
          throw ActionError.notConfigured("A local command")
        }
        guard let runner = environment.commandRunner else {
          throw ActionError.notConfigured("The command runner")
        }
        let invocation = command.invocation(with: try input.string("text"))
        let status = try await runner.run(invocation)
        return ActionEffect(
          summary: "Ran \(command.executablePath) and it exited with \(status).")
      })
  }
}

/// The phrases that can name an action, and nothing else.
///
/// The same shape as `CommandParser`: a table of canonical phrases, matched exactly
/// after the filler words come off, with a linear scan and no regular expression. An
/// utterance that is not in the table is not an action — it is dictation, which is the
/// safe default because the cost of a miss is text the user can delete.
///
/// Two of the built-ins are deliberately absent. Opening a link and running a command
/// take an argument that has to be exact, and a dictated URL or file path is the one
/// thing transcription is worst at; those come from a control the user pressed, where
/// what will run is on screen next to the button.
public struct ActionPhrasebook: Sendable {

  static let phrases: [String: String] = {
    var table: [String: String] = [:]
    func add(_ keys: [String], _ id: String) {
      for key in keys { table[key] = id }
    }
    add(
      [
        "save as note", "save to scratchpad", "note that", "save note", "add to scratchpad",
        "put in scratchpad",
      ], BuiltInActions.ID.createNote)
    add(["copy that", "copy result", "copy to clipboard"], BuiltInActions.ID.copy)
    add(["paste and send", "send that", "paste and return"], BuiltInActions.ID.pasteAndSend)
    add(["remind me", "make reminder", "add reminder"], BuiltInActions.ID.createReminder)
    add(["run my command", "send to my tool", "run command"], BuiltInActions.ID.runCommand)
    return table
  }()

  public init() {}

  /// The action the user named, or nil. Nil is the common answer.
  public func actionID(for utterance: String) -> String? {
    let words = utterance.split(whereSeparator: \.isWhitespace)
      .map(String.init)
      .map(CommandParser.normalise)
    guard !words.isEmpty else { return nil }
    var tokens = words
    while let first = tokens.first, CommandParser.leadingWords.contains(first), tokens.count > 1 {
      tokens.removeFirst()
    }
    let canonical = tokens.filter { !CommandParser.objectWords.contains($0) && !$0.isEmpty }
      .joined(separator: " ")
    return Self.phrases[canonical]
  }

  /// An intent from the user's words and the finished text.
  ///
  /// The two arguments do different jobs and never swap: `utterance` chooses the
  /// action, `text` is carried as payload. That is why a transcript full of
  /// instructions cannot start anything — it arrives as `text`, and nothing downstream
  /// reads `text` looking for an action.
  public func intent(utterance: String, text: String) -> ActionIntent? {
    guard let id = actionID(for: utterance) else { return nil }
    return ActionIntent(
      actionID: id, input: ActionInput(["text": text]),
      origin: .spokenCommand(utterance: utterance))
  }
}
