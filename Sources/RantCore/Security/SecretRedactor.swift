import Foundation

/// Scrubs credential-shaped strings out of text before it can leave the machine.
///
/// This exists because context is genuinely useful — the words before your cursor
/// make the next sentence transcribe better — and because the words before your
/// cursor are sometimes an API key you were pasting into a config file. We cannot
/// ask the user to remember which is which mid-sentence, so the outbound path scrubs
/// unconditionally.
///
/// It is a heuristic and it is documented as one. Being conservative is the whole
/// point: a false positive costs a little transcription context, a false negative
/// leaks a credential to a third party. The tests below the API pin the tradeoff.
public struct SecretRedactor: Sendable {
  public static let placeholder = "[redacted]"

  /// Ordered most-specific first, so a recognisable key shape wins over the generic
  /// "long random-looking run" rule and produces a tighter replacement.
  private static let patterns: [NSRegularExpression] = {
    let sources = [
      // PEM blocks — match the whole block, not just the header.
      #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
      // Vendor-prefixed keys: sk-…, ghp_…, xoxb-…, AKIA…, AIza…, hf_…
      #"\b(?:sk|pk|rk)-[A-Za-z0-9_\-]{16,}"#,
      #"\b(?:gh[pousr]|github_pat)_[A-Za-z0-9_]{16,}"#,
      #"\bxox[baprs]-[A-Za-z0-9\-]{10,}"#,
      #"\bAKIA[0-9A-Z]{16}\b"#,
      #"\bAIza[0-9A-Za-z_\-]{35}\b"#,
      #"\bhf_[A-Za-z0-9]{16,}"#,
      // Authorization headers and assignments: `Authorization: Bearer x`,
      // `api_key = "x"`, `PASSWORD=x`.
      #"(?i)\b(?:authorization|bearer|token|api[_\- ]?key|secret|password|passwd|pwd)\b\s*[:=]\s*["']?[^\s"'\n,;]{6,}"#,
      // JWTs.
      #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#,
      // A bare high-entropy run. Last, and deliberately long: 32+ characters of
      // mixed-case alphanumerics is not something anyone dictates.
      #"\b(?=[A-Za-z0-9_\-]{32,}\b)(?=[^\s]*[a-z])(?=[^\s]*[A-Z])(?=[^\s]*[0-9])[A-Za-z0-9_\-]{32,}\b"#,
      // Long hex runs — session ids, raw keys.
      #"\b[0-9a-fA-F]{40,}\b"#,
    ]
    return sources.compactMap { try? NSRegularExpression(pattern: $0) }
  }()

  public init() {}

  /// Returns `text` with anything credential-shaped replaced by `[redacted]`.
  public func redact(_ text: String) -> String {
    var result = text
    for pattern in Self.patterns {
      let range = NSRange(result.startIndex..., in: result)
      result = pattern.stringByReplacingMatches(
        in: result, range: range, withTemplate: Self.placeholder)
    }
    return result
  }

  /// True when redaction changed anything — used by the diagnostics view to tell the
  /// user that something was withheld, without showing them what.
  public func containsSecret(_ text: String) -> Bool {
    redact(text) != text
  }
}
