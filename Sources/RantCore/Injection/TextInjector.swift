import Foundation

/// Where the finished text should end up.
public enum InjectionTarget: String, Equatable, Sendable, Codable {
  /// The app that had focus when dictation started.
  case cursor
  /// Clipboard only — the user will paste it themselves.
  case clipboard
  /// Replace the current selection rather than inserting at a caret.
  case replaceSelection
}

public struct InjectionRequest: Equatable, Sendable {
  public var text: String
  public var target: InjectionTarget
  public var context: TranscriptionContext?

  public init(text: String, target: InjectionTarget = .cursor, context: TranscriptionContext? = nil) {
    self.text = text
    self.target = target
    self.context = context
  }
}

public enum InjectionOutcome: Equatable, Sendable {
  /// Written straight into the focused element through Accessibility. The good path:
  /// no keystrokes synthesised, no clipboard touched.
  case insertedDirectly
  /// Put on the clipboard and pasted with a synthesised ⌘V.
  case pastedViaClipboard
  /// Left on the clipboard for the user, because the target went away or refused.
  case leftOnClipboard(reason: String)
  /// Nothing happened, and nothing should have.
  case refused(reason: String)
}

public enum InjectionError: Error, Equatable, LocalizedError {
  case accessibilityPermissionMissing
  case secureField
  case noFocusedElement
  case pasteFailed(String)

  public var errorDescription: String? {
    switch self {
    case .accessibilityPermissionMissing:
      "Rant needs Accessibility permission to type into other apps."
    case .secureField:
      "Rant will not type into a password field."
    case .noFocusedElement:
      "There was no text field to type into."
    case .pasteFailed(let detail):
      "Could not paste: \(detail)"
    }
  }
}

/// Anything that can put text where the user was typing.
public protocol TextInjector: Sendable {
  func inject(_ request: InjectionRequest) async throws -> InjectionOutcome
}

/// The clipboard, behind a protocol so clipboard save/restore can be tested without
/// fighting the real pasteboard — and without a test run stealing what the developer
/// had copied.
public protocol PasteboardAccess: Sendable {
  func read() -> String?
  func write(_ text: String)
  /// Monotonic counter that changes whenever anything writes to the pasteboard.
  var changeCount: Int { get }
}

/// Decides how to inject, and what to do about the clipboard, without touching the OS.
///
/// The rules it encodes are the ones that are easy to get wrong:
///
/// - **Never type into a password field.** Not a preference; see `SECURITY.md`.
/// - **Preserve what the user had copied.** Dictation should not cost you your
///   clipboard.
/// - **Do not restore the clipboard too early.** The paste is asynchronous — the
///   target app reads the pasteboard some time after ⌘V is synthesised. Restoring
///   immediately is a race that loses often enough to be maddening and rarely enough
///   to be hard to reproduce.
/// - **Never lose the text.** If the target app quit mid-dictation, the transcript
///   stays on the clipboard rather than evaporating.
public struct InjectionPolicy: Sendable {
  /// How long to wait after synthesising ⌘V before putting the user's clipboard
  /// back. Long enough for the target app to have read the pasteboard.
  public var clipboardRestoreDelay: Duration = .milliseconds(600)
  /// Text longer than this is pasted rather than typed, whatever else we know —
  /// synthesised keystrokes get lossy at length.
  public var directInsertionCharacterLimit = 20_000

  public init() {}

  /// Roles Accessibility uses for password fields.
  public static let secureFieldRoles: Set<String> = [
    "AXSecureTextField", "AXSecureTextArea",
  ]

  /// The one refusal that has no override.
  public func mustRefuse(_ context: TranscriptionContext?) -> InjectionError? {
    guard let context else { return nil }
    if context.isSecureField { return .secureField }
    if let role = context.fieldRole, Self.secureFieldRoles.contains(role) { return .secureField }
    return nil
  }
}

/// Test double that records what it was asked to do.
public final class RecordingInjector: TextInjector, @unchecked Sendable {
  public private(set) var requests: [InjectionRequest] = []
  public var outcome: InjectionOutcome = .insertedDirectly
  public var error: Error?
  private let lock = NSLock()

  public init() {}

  public func inject(_ request: InjectionRequest) async throws -> InjectionOutcome {
    lock.withLock { requests.append(request) }
    if let error { throw error }
    return outcome
  }

  public var lastText: String? { lock.withLock { requests.last?.text } }
}

/// In-memory pasteboard for tests.
public final class FakePasteboard: PasteboardAccess, @unchecked Sendable {
  private var value: String?
  private var counter = 0
  private let lock = NSLock()

  public init(_ initial: String? = nil) {
    value = initial
    counter = initial == nil ? 0 : 1
  }

  public func read() -> String? { lock.withLock { value } }
  public func write(_ text: String) { lock.withLock { value = text; counter += 1 } }
  public var changeCount: Int { lock.withLock { counter } }
}
