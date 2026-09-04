import Foundation

/// Speech-to-text through AssemblyAI's dictation endpoint, using the user's own key.
///
/// One `POST https://dictation.assemblyai.com/transcribe` carries the recorded audio
/// and a JSON `config` part, and comes back with both the verbatim transcript and —
/// when we ask for one — a cleaned-up rewrite. No upload step, no job id, no
/// polling: one request per utterance covers transcription and cleanup together,
/// which is what keeps the round trip short enough to feel immediate.
///
/// The wire contract (endpoint, multipart field names, config keys) is AssemblyAI's;
/// we learned its exact shape from Blurt, which is MIT — see
/// `THIRD_PARTY_NOTICES.md`.
public struct AssemblyAIProvider: TranscriptionProvider {
  public let identifier = "assemblyai"
  public let displayName = "AssemblyAI"
  public let sendsAudioOffDevice = true
  /// The endpoint accepts up to two minutes of audio per request.
  public let maximumUtteranceSeconds: Int? = 120

  private let baseURL: URL
  private let transport: any HTTPTransport
  private let keyProvider: @Sendable () throws -> String?
  private let log = RantLog("AssemblyAI")

  /// Bounds a *stalled* connection rather than total elapsed time — `URLRequest`
  /// resets this whenever bytes move. Generous enough that the server decides when a
  /// slow request has failed, short enough that a dead network cannot leave the
  /// overlay stuck on "Transcribing…" forever.
  static let requestTimeout: TimeInterval = 90

  public init(
    keyProvider: @escaping @Sendable () throws -> String?,
    baseURL: URL = URL(string: "https://dictation.assemblyai.com")!,
    transport: any HTTPTransport = URLSession.shared
  ) {
    self.keyProvider = keyProvider
    self.baseURL = baseURL
    self.transport = transport
  }

  /// Convenience for the app, which reads the key from the Keychain each time so a
  /// key changed in Settings applies to the very next dictation.
  public init(
    secrets: any SecretStoring,
    baseURL: URL = URL(string: "https://dictation.assemblyai.com")!,
    transport: any HTTPTransport = URLSession.shared
  ) {
    self.init(
      keyProvider: { try secrets.read(.assemblyAI) }, baseURL: baseURL, transport: transport)
  }

  // MARK: - Transcribe

  public func transcribe(
    _ audio: AudioBuffer,
    context: TranscriptionContext?,
    options: TranscriptionOptions
  ) async throws -> TranscriptionResult {
    guard let key = try keyProvider(), !key.isEmpty else { throw TranscriptionError.apiKeyMissing }
    guard !audio.isEmpty else { throw TranscriptionError.audioEmpty }
    if let limit = maximumUtteranceSeconds {
      let seconds = audio.durationMilliseconds / 1000
      if seconds > limit { throw TranscriptionError.audioTooLong(seconds: seconds, limit: limit) }
    }

    let config = try makeConfig(audio: audio, context: context, options: options)
    let boundary = "rant-\(UUID().uuidString)"
    let body = multipartBody(pcm: audio.pcm, config: config, boundary: boundary)

    var request = URLRequest(url: baseURL.appendingPathComponent("transcribe"))
    request.httpMethod = "POST"
    request.timeoutInterval = Self.requestTimeout
    // AssemblyAI takes the raw key, with no "Bearer " prefix.
    request.setValue(key, forHTTPHeaderField: "Authorization")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    let started = ContinuousClock.now
    let (data, response): (Data, HTTPURLResponse)
    do {
      (data, response) = try await transport.send(request, body: body)
    } catch is CancellationError {
      throw TranscriptionError.cancelled
    } catch let error as URLError where error.code == .cancelled {
      throw TranscriptionError.cancelled
    } catch {
      throw TranscriptionError.network(error.localizedDescription)
    }
    let latency = Int((ContinuousClock.now - started) / .milliseconds(1))

    switch response.statusCode {
    case 200..<300:
      break
    case 401, 403:
      throw TranscriptionError.unauthorized
    case 429:
      throw TranscriptionError.rateLimited
    default:
      throw TranscriptionError.http(
        status: response.statusCode, message: Self.errorMessage(from: data))
    }

    guard let decoded = try? JSONDecoder().decode(DictationResponse.self, from: data) else {
      throw TranscriptionError.malformedResponse
    }
    log.info("dictation ok audioMs=\(audio.durationMilliseconds) latencyMs=\(latency)")
    if let failure = decoded.llmError {
      log.warning("server cleanup unavailable (\(failure)); using verbatim transcript")
    }

    return TranscriptionResult(
      raw: decoded.text,
      cleaned: decoded.llmResponse,
      provider: identifier,
      language: decoded.languageCode,
      latencyMilliseconds: latency,
      cleanupFailure: decoded.llmError)
  }

  /// Opens the TLS connection while the user is still speaking, so the real request
  /// does not pay DNS + TCP + TLS on the hot path. An unauthenticated throwaway to
  /// the host root is enough to establish the pooled connection; the 4xx that comes
  /// back is discarded and it never counts as a transcription. Failure is fine — it
  /// just means the next request sets up its own connection.
  public func warmUp() async {
    var request = URLRequest(url: baseURL)
    request.httpMethod = "GET"
    request.timeoutInterval = 5
    _ = try? await transport.send(request, body: nil)
  }

  public func checkReachability() async throws {
    guard let key = try keyProvider(), !key.isEmpty else { throw TranscriptionError.apiKeyMissing }
    // 80 ms of silence: long enough that the service accepts it, short enough to be
    // nearly free. A 2xx or a 400 both prove the key was accepted; only an auth
    // failure means the key is wrong.
    let silence = AudioBuffer(pcm: Data(count: 16_000 / 1000 * 80 * 2), sampleRate: 16_000)
    do {
      _ = try await transcribe(
        silence, context: nil,
        options: TranscriptionOptions(cleanupLevel: .none, allowProviderCleanup: false))
    } catch TranscriptionError.unauthorized {
      throw TranscriptionError.unauthorized
    } catch TranscriptionError.http, TranscriptionError.malformedResponse,
      TranscriptionError.audioEmpty
    {
      // Reached the service and it answered. That is what we were testing.
    }
  }

  // MARK: - Wire format

  /// Builds the JSON `config` part. Internal so the tests can assert on the wiring
  /// without having to parse a multipart body.
  func makeConfig(
    audio: AudioBuffer,
    context: TranscriptionContext?,
    options: TranscriptionOptions,
    contextSettings: ContextSettings = .default
  ) throws -> Data {
    let wantsCleanup = options.allowProviderCleanup && options.cleanupLevel != .none
    let instruction = wantsCleanup ? cleanupInstruction(for: options) : nil

    let config = DictationConfig(
      sampleRate: audio.sampleRate,
      channels: 1,
      languageCode: options.languageCode,
      conversationContext: OutboundContext.wireTurns(context: context, settings: contextSettings),
      wordBoost: OutboundContext.wireKeyTerms(context: context, settings: contextSettings),
      llm: wantsCleanup ? LLMRewrite(instruction: instruction) : nil)
    return try JSONEncoder().encode(config)
  }

  private func cleanupInstruction(for options: TranscriptionOptions) -> String? {
    guard var text = options.cleanupLevel.rewriteInstruction else { return nil }
    if let style = options.styleInstruction?.trimmingCharacters(in: .whitespacesAndNewlines),
      !style.isEmpty
    {
      text += "\n\nWriting style: \(style)"
    }
    return text
  }

  /// The `audio` + `config` multipart payload. Internal, because the framing —
  /// boundaries, part headers, CRLF placement — is exactly the sort of thing that is
  /// wrong in a way no type checker catches, so a test asserts on the bytes.
  func multipartBody(pcm: Data, config: Data, boundary: String) -> Data {
    var body = Data()
    body.reserveCapacity(pcm.count + config.count + 512)
    func append(_ text: String) { body.append(Data(text.utf8)) }

    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"audio\"; filename=\"audio.pcm\"\r\n")
    append("Content-Type: audio/pcm\r\n\r\n")
    body.append(pcm)
    append("\r\n")

    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"config\"\r\n")
    append("Content-Type: application/json\r\n\r\n")
    body.append(config)
    append("\r\n")

    append("--\(boundary)--\r\n")
    return body
  }

  /// The most useful human-readable explanation available for a failure: the
  /// documented `message`, then `detail`, then the raw body. That last arm is not
  /// legacy compatibility — it is what turns a proxy's HTML 502 or a captive portal
  /// page into something diagnosable instead of a bare status code.
  static func errorMessage(from data: Data) -> String? {
    if let parsed = try? JSONDecoder().decode(ErrorResponse.self, from: data),
      let message = parsed.message
    {
      return message
    }
    let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return raw.isEmpty ? nil : String(raw.prefix(500))
  }
}

// MARK: - JSON contract

extension AssemblyAIProvider {
  /// The `config` part. Empty steering fields are *omitted* rather than sent as
  /// `[]`, so a hand-written `encode` replaces the synthesised one — and a property
  /// added above but forgotten here never reaches the wire, which the config tests
  /// catch.
  struct DictationConfig: Encodable {
    let sampleRate: Int
    let channels: Int
    let languageCode: String?
    let conversationContext: [String]
    let wordBoost: [String]
    let llm: LLMRewrite?

    enum CodingKeys: String, CodingKey {
      case sampleRate = "sample_rate"
      case channels
      case languageCode = "language_code"
      case conversationContext = "conversation_context"
      case wordBoost = "word_boost"
      case llm
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(sampleRate, forKey: .sampleRate)
      try container.encode(channels, forKey: .channels)
      try container.encodeIfPresent(languageCode, forKey: .languageCode)
      if !conversationContext.isEmpty {
        try container.encode(conversationContext, forKey: .conversationContext)
      }
      if !wordBoost.isEmpty { try container.encode(wordBoost, forKey: .wordBoost) }
      try container.encodeIfPresent(llm, forKey: .llm)
    }
  }

  /// Asking for the cleanup rewrite. Omitting `instruction` selects the service's
  /// own default; omitting the whole block asks for no rewrite at all.
  struct LLMRewrite: Encodable {
    let instruction: String?
  }

  struct DictationResponse: Decodable {
    /// The verbatim transcript. Always present, never altered by the rewrite.
    let text: String
    /// The rewritten transcript, or nil when the rewrite failed or timed out.
    let llmResponse: String?
    /// `"timeout"` or `"error"` when a requested rewrite did not happen.
    let llmError: String?
    let languageCode: String?

    enum CodingKeys: String, CodingKey {
      case text
      case llmResponse = "llm_response"
      case llmError = "llm_error"
      case languageCode = "language_code"
    }
  }

  /// Two documented failure shapes: `{error_code, message}` for request and server
  /// errors, `{detail}` for auth and rate limiting.
  struct ErrorResponse: Decodable {
    let message: String?
    enum CodingKeys: String, CodingKey { case message, detail }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      func string(_ key: CodingKeys) -> String? { try? container.decode(String.self, forKey: key) }
      message = string(.message) ?? string(.detail)
    }
  }
}
