import Foundation

/// Rewriting through a local model served over an OpenAI-compatible or Ollama-native
/// HTTP endpoint.
///
/// Default is Ollama on `localhost:11434`, which means "high" cleanup can work with
/// no API key, no account and no data leaving the machine. Point it at any
/// OpenAI-compatible base URL and it works the same way — at which point it stops
/// being on-device, which is why `sendsTextOffDevice` is computed from the host
/// rather than hard-coded.
public struct OllamaEnhancer: EnhancementProvider {
  public let identifier = "ollama"
  public var displayName: String { "Local model (\(model))" }

  private let endpoint: URL
  private let model: String
  private let transport: any HTTPTransport
  private let redactor = SecretRedactor()
  private let log = RantLog("Enhancement")

  public init(
    endpoint: URL = URL(string: "http://localhost:11434")!,
    model: String = "llama3.2",
    transport: any HTTPTransport = URLSession.shared
  ) {
    self.endpoint = endpoint
    self.model = model
    self.transport = transport
  }

  /// Loopback is on-device; anything else is not, whatever the setting is called.
  public var sendsTextOffDevice: Bool {
    guard let host = endpoint.host?.lowercased() else { return true }
    return !["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(host)
  }

  public func enhance(
    _ text: String, instruction: String, context: TranscriptionContext?
  ) async throws -> String {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }

    // Even for a local model the text is redacted, because "local" can be pointed at
    // a remote host and because the request may be logged by the server.
    let body = try JSONEncoder().encode(
      GenerateRequest(
        model: model,
        prompt: "\(instruction)\n\nText:\n\(redactor.redact(text))",
        stream: false))

    var request = URLRequest(url: endpoint.appendingPathComponent("api/generate"))
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let (data, response) = try await transport.send(request, body: body)
    guard (200..<300).contains(response.statusCode) else {
      throw TranscriptionError.http(status: response.statusCode, message: nil)
    }
    guard let decoded = try? JSONDecoder().decode(GenerateResponse.self, from: data) else {
      throw TranscriptionError.malformedResponse
    }
    let output = decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
    // A model that returns nothing must not erase the user's words.
    return output.isEmpty ? text : output
  }

  public func isAvailable() async -> Bool {
    var request = URLRequest(url: endpoint.appendingPathComponent("api/tags"))
    request.timeoutInterval = 2
    guard let (_, response) = try? await transport.send(request, body: nil) else { return false }
    return (200..<300).contains(response.statusCode)
  }

  struct GenerateRequest: Encodable {
    let model: String
    let prompt: String
    let stream: Bool
  }
  struct GenerateResponse: Decodable {
    let response: String
  }
}
