import Foundation

// MARK: - The socket seam

/// One frame in either direction.
public enum WebSocketMessage: Equatable, Sendable {
  case text(String)
  case binary(Data)
}

/// A live socket. Deliberately four methods wide: everything above it — the
/// handshake URL, the termination handshake, reconnection, cancellation — is ours to
/// get wrong, and all of it is testable against a fake that conforms to this.
public protocol WebSocketChannel: Sendable {
  func send(_ message: WebSocketMessage) async throws
  /// Suspends until the next frame arrives, or throws when the socket ends.
  func receive() async throws -> WebSocketMessage
  func close() async
}

public protocol WebSocketConnecting: Sendable {
  func connect(to request: URLRequest) async throws -> any WebSocketChannel
}

/// `URLSessionWebSocketTask` behind the protocol.
public struct URLSessionWebSocketConnector: WebSocketConnecting {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func connect(to request: URLRequest) async throws -> any WebSocketChannel {
    let task = session.webSocketTask(with: request)
    task.resume()
    return URLSessionWebSocketChannel(task: task)
  }
}

/// Wraps the task rather than subclassing it, and turns a close code into one of our
/// errors — a 4001 close is a rejected key, and telling the user "connection lost"
/// when the truth is "your key is wrong" wastes an afternoon.
final class URLSessionWebSocketChannel: WebSocketChannel, @unchecked Sendable {
  private let task: URLSessionWebSocketTask

  init(task: URLSessionWebSocketTask) {
    self.task = task
  }

  func send(_ message: WebSocketMessage) async throws {
    switch message {
    case .text(let string): try await task.send(.string(string))
    case .binary(let data): try await task.send(.data(data))
    }
  }

  func receive() async throws -> WebSocketMessage {
    do {
      switch try await task.receive() {
      case .string(let string): return .text(string)
      case .data(let data): return .binary(data)
      @unknown default: throw TranscriptionError.malformedResponse
      }
    } catch {
      if task.closeCode != .invalid {
        throw AssemblyAIStreamProvider.error(forCloseCode: task.closeCode.rawValue)
      }
      throw error
    }
  }

  func close() async {
    task.cancel(with: .normalClosure, reason: nil)
  }
}

// MARK: - Reconnection

/// How hard to try when the socket drops mid-sentence.
///
/// Bounded and short: a dictation is seconds long, so a reconnect that takes longer
/// than the utterance is worse than an error. The delay grows so that a provider
/// outage is not hammered by every Rant on the internet at once.
public struct ReconnectPolicy: Equatable, Sendable {
  public var maximumAttempts: Int
  public var baseDelay: Duration
  public var maximumDelay: Duration

  public init(
    maximumAttempts: Int = 3,
    baseDelay: Duration = .milliseconds(250),
    maximumDelay: Duration = .seconds(2)
  ) {
    self.maximumAttempts = maximumAttempts
    self.baseDelay = baseDelay
    self.maximumDelay = maximumDelay
  }

  public static let none = ReconnectPolicy(maximumAttempts: 0)

  /// Doubling, capped. Attempt numbering starts at 1.
  public func delay(forAttempt attempt: Int) -> Duration {
    guard attempt > 1 else { return baseDelay }
    let multiplier = 1 << min(attempt - 1, 16)
    let scaled = baseDelay * multiplier
    return scaled > maximumDelay ? maximumDelay : scaled
  }
}

// MARK: - Provider

/// Live transcription over AssemblyAI's v3 streaming socket.
///
/// The session is billed for as long as it is open, and a socket that is merely
/// dropped stays open on their side until it times out. So every path out of this
/// type — a normal finish, an error, the user cancelling, the overlay going away —
/// goes through `terminate()`, which sends `{"type":"Terminate"}` first. That is the
/// single most important behaviour in this file, and it has its own test.
///
/// Partials are for display only. The final text still comes from the synchronous
/// provider, per `docs/DECISIONS.md` D-003 — so a streaming failure degrades the
/// overlay, never the transcript.
public struct AssemblyAIStreamProvider: StreamingTranscriptionProvider {
  public let identifier = "assemblyai-stream"

  /// The v3 streaming endpoint. Documented in `docs/NETWORK_BEHAVIOR.md`.
  public static let defaultEndpoint = URL(string: "wss://streaming.assemblyai.com/v3/ws")!
  /// The rate the socket is told about and the rate the capture graph produces. One
  /// constant, because a mismatch here is not an error — it is a transcript of
  /// gibberish that costs money to produce.
  public static let sampleRate = 16_000

  private let endpoint: URL
  private let speechModel: String
  private let connector: any WebSocketConnecting
  private let keyProvider: @Sendable () throws -> String?
  private let reconnectPolicy: ReconnectPolicy
  private let contextSettings: ContextSettings
  /// How long to keep listening after `Terminate` goes out, for the server's final
  /// turn and its `Termination` acknowledgement.
  private let terminationGrace: Duration

  public init(
    keyProvider: @escaping @Sendable () throws -> String?,
    endpoint: URL = AssemblyAIStreamProvider.defaultEndpoint,
    // AssemblyAI rejects the bare family name: the parameter wants a specific model,
    // `universal-streaming-english` or `universal-streaming-multilingual`. Sending
    // "universal-streaming" gets a 400 on every connection — which nothing noticed
    // while no caller existed, and which appeared as a warning on every dictation the
    // moment the live preview was wired up.
    speechModel: String = "universal-streaming-english",
    connector: any WebSocketConnecting = URLSessionWebSocketConnector(),
    reconnectPolicy: ReconnectPolicy = ReconnectPolicy(),
    contextSettings: ContextSettings = .default,
    terminationGrace: Duration = .seconds(3)
  ) {
    self.keyProvider = keyProvider
    self.endpoint = endpoint
    self.speechModel = speechModel
    self.connector = connector
    self.reconnectPolicy = reconnectPolicy
    self.contextSettings = contextSettings
    self.terminationGrace = terminationGrace
  }

  public init(
    secrets: any SecretStoring,
    endpoint: URL = AssemblyAIStreamProvider.defaultEndpoint,
    connector: any WebSocketConnecting = URLSessionWebSocketConnector()
  ) {
    self.init(
      keyProvider: { try secrets.read(.assemblyAI) }, endpoint: endpoint, connector: connector)
  }

  // MARK: - Handshake construction

  /// The upgrade request. Internal because a mistyped query parameter here is a 400
  /// the user sees as "streaming just does not work", with nothing in the log to say
  /// why — so a test asserts on every part of it.
  func makeRequest(
    context: TranscriptionContext?, options: TranscriptionOptions, key: String
  ) -> URLRequest {
    var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
    var items = [
      URLQueryItem(name: "sample_rate", value: String(Self.sampleRate)),
      URLQueryItem(name: "encoding", value: "pcm_s16le"),
      URLQueryItem(name: "speech_model", value: speechModel),
      URLQueryItem(name: "format_turns", value: "true"),
    ]
    // The only context allowed out of the machine, through the one sanctioned
    // function. Key terms bias recognition; nothing else here is sent.
    let keyTerms = OutboundContext.wireKeyTerms(context: context, settings: contextSettings)
    if !keyTerms.isEmpty,
      let encoded = try? JSONEncoder().encode(keyTerms)
    {
      items.append(
        URLQueryItem(name: "keyterms_prompt", value: String(decoding: encoded, as: UTF8.self)))
    }
    if let language = options.languageCode {
      items.append(URLQueryItem(name: "language_code", value: language))
    }
    components.queryItems = items

    var request = URLRequest(url: components.url ?? endpoint)
    // AssemblyAI takes the raw key on the handshake, with no "Bearer " prefix.
    request.setValue(key, forHTTPHeaderField: "Authorization")
    return request
  }

  public func stream(
    context: TranscriptionContext?,
    options: TranscriptionOptions
  ) async throws -> TranscriptionStream {
    guard let key = try keyProvider(), !key.isEmpty else { throw TranscriptionError.apiKeyMissing }
    let request = makeRequest(context: context, options: options, key: key)

    let session = StreamingSession(
      request: request,
      connector: connector,
      policy: reconnectPolicy,
      terminationGrace: terminationGrace)

    let (partials, continuation) = AsyncThrowingStream<TranscriptionPartial, Error>.makeStream()

    // Cancelling the consuming task tears the stream down, and this is where that
    // becomes a polite `Terminate` rather than a socket dropped on the floor and a
    // session that bills until it times out.
    continuation.onTermination = { @Sendable _ in
      Task { await session.terminate() }
    }

    Task { await session.run(yielding: continuation) }

    return TranscriptionStream(
      partials: partials,
      send: { data in await session.send(data) },
      finish: { await session.terminate() })
  }

  // MARK: - Error mapping

  /// Close codes we can say something useful about. Anything else is reported as a
  /// network failure, which is retryable — the safe default when we do not know.
  static func error(forCloseCode code: Int, reason: String? = nil) -> TranscriptionError {
    switch code {
    case 1000, 1001: .cancelled
    case 4001, 4003: .unauthorized
    case 4002: .http(status: 400, message: reason ?? "The streaming session was rejected.")
    case 4029: .rateLimited
    default: .network(reason ?? "The streaming connection closed (code \(code)).")
    }
  }
}

// MARK: - Session

/// One live socket, its receive loop, and the guarantee that it is terminated exactly
/// once.
///
/// An actor because `send` is called from the audio callback while `run` is parked in
/// `receive()` and `terminate` can arrive from either the user or stream teardown.
/// The `didTerminate` flag is the whole reason: without serialised access, cancelling
/// during a normal finish sends `Terminate` twice, and the second one arrives on a
/// closed socket and throws inside a deinit path.
actor StreamingSession {
  private let request: URLRequest
  private let connector: any WebSocketConnecting
  private let policy: ReconnectPolicy
  private let terminationGrace: Duration
  private let log = RantLog("AssemblyAIStream")

  private var channel: (any WebSocketChannel)?
  private var didTerminate = false
  private var isFinished = false
  /// Terminate has gone out and we are waiting for the last turns. Receive errors in
  /// this state are the expected end of the session, not something to reconnect from.
  private var isDraining = false
  /// Set when the session was ended before the socket finished opening. Without it,
  /// a dictation cancelled during the handshake connects a moment later and then
  /// bills until the provider times it out — the exact failure this file exists to
  /// prevent, arriving through the one door nobody watches.
  private var terminateRequested = false
  /// Audio captured while the socket was still opening, or between a drop and a
  /// reconnect. Bounded: past a few seconds the words are stale enough that dropping
  /// the oldest beats growing without limit.
  private var outbound: [Data] = []
  static let maximumBufferedFrames = 64

  /// The politeness that stops the meter. Sent as text, exactly this shape.
  static let terminateMessage = #"{"type":"Terminate"}"#

  init(
    request: URLRequest,
    connector: any WebSocketConnecting,
    policy: ReconnectPolicy,
    terminationGrace: Duration
  ) {
    self.request = request
    self.connector = connector
    self.policy = policy
    self.terminationGrace = terminationGrace
  }

  // MARK: Loop

  func run(yielding continuation: AsyncThrowingStream<TranscriptionPartial, Error>.Continuation) async {
    do {
      await adopt(try await connector.connect(to: request))
    } catch {
      finish(continuation, with: Self.mapped(error))
      return
    }

    var reconnectAttempt = 0
    while !isFinished {
      guard let channel else {
        finish(continuation, with: .network("The streaming connection closed."))
        return
      }
      do {
        let message = try await channel.receive()
        reconnectAttempt = 0
        if let event = Self.decode(message) {
          switch event {
          case .partial(let partial):
            continuation.yield(partial)
          case .terminated:
            finish(continuation, with: nil)
          case .failure(let error):
            finish(continuation, with: error)
          case .ignored:
            break
          }
        }
      } catch {
        if isDraining || isFinished {
          // The server acknowledged and went away, which is what we asked for.
          finish(continuation, with: nil)
          return
        }
        let mapped = Self.mapped(error)
        // A rejected key will be rejected again; only a transport failure is worth
        // another socket.
        guard mapped.isRetryable else {
          finish(continuation, with: mapped)
          return
        }
        await self.channel?.close()
        self.channel = nil

        var reconnected = false
        while reconnectAttempt < policy.maximumAttempts, !reconnected, !isFinished {
          reconnectAttempt += 1
          log.warning("streaming socket dropped; reconnect attempt \(reconnectAttempt)")
          try? await Task.sleep(for: policy.delay(forAttempt: reconnectAttempt))
          if isFinished { return }
          if let fresh = try? await connector.connect(to: request) {
            await adopt(fresh)
            reconnected = true
          }
        }
        guard reconnected else {
          finish(continuation, with: mapped)
          return
        }
      }
    }
  }

  // MARK: Audio

  func send(_ data: Data) async {
    guard !isFinished, !isDraining, !data.isEmpty else { return }
    guard let channel else {
      // Still opening, or between a drop and a reconnect. Hold the audio rather than
      // lose the first syllable of every dictation.
      outbound.append(data)
      if outbound.count > Self.maximumBufferedFrames { outbound.removeFirst() }
      return
    }
    // Binary frames of 16-bit mono PCM, exactly as captured. A failed frame is not
    // worth failing the session over: the receive loop will notice the socket is gone.
    try? await channel.send(.binary(data))
  }

  /// Takes ownership of a freshly opened socket: flush what was captured while it was
  /// opening, then honour a termination that arrived first.
  private func adopt(_ fresh: any WebSocketChannel) async {
    channel = fresh
    let queued = outbound
    outbound.removeAll()
    for frame in queued {
      try? await fresh.send(.binary(frame))
    }
    if terminateRequested { await terminate() }
  }

  // MARK: Termination

  /// Sends `Terminate`, once, and closes the socket after the grace period whatever
  /// the server does. Safe to call from anywhere, any number of times.
  func terminate() async {
    guard !didTerminate else { return }
    isDraining = true
    guard let channel else {
      // The socket is still opening. `adopt` will send this the instant it is there.
      terminateRequested = true
      return
    }
    didTerminate = true
    terminateRequested = false
    outbound.removeAll()
    try? await channel.send(.text(Self.terminateMessage))
    log.info("streaming session terminate sent")
    let grace = terminationGrace
    Task { [weak self] in
      try? await Task.sleep(for: grace)
      await self?.forceClose()
    }
  }

  private func forceClose() async {
    guard let open = channel else { return }
    channel = nil
    await open.close()
  }

  private func finish(
    _ continuation: AsyncThrowingStream<TranscriptionPartial, Error>.Continuation,
    with error: TranscriptionError?
  ) {
    guard !isFinished else { return }
    isFinished = true
    if let error {
      continuation.finish(throwing: error)
    } else {
      continuation.finish()
    }
    // Never leave a session open behind a finished stream.
    Task { [weak self] in
      await self?.terminate()
      await self?.forceClose()
    }
  }

  // MARK: Wire format

  enum Event: Equatable {
    case partial(TranscriptionPartial)
    case terminated
    case failure(TranscriptionError)
    case ignored
  }

  /// `Begin`, `Turn`, `Termination` — plus an `error` shape that arrives instead of a
  /// close frame often enough to be worth handling. Unknown types are ignored rather
  /// than treated as failures, so a new server message type does not break dictation.
  static func decode(_ message: WebSocketMessage) -> Event? {
    let data: Data
    switch message {
    case .text(let string): data = Data(string.utf8)
    // The server does not send us binary; if it starts, ignoring is safer than
    // guessing.
    case .binary: return .ignored
    }
    guard let frame = try? JSONDecoder().decode(ServerFrame.self, from: data) else {
      return .failure(.malformedResponse)
    }
    if let error = frame.error {
      return .failure(.http(status: frame.status ?? 400, message: error))
    }
    switch frame.type {
    case "Begin":
      return .ignored
    case "Turn":
      let text = frame.transcript ?? ""
      let isFinal = frame.endOfTurn ?? false
      // An empty non-final turn is the server saying "still listening". Yielding it
      // would blank the overlay mid-sentence.
      if text.isEmpty && !isFinal { return .ignored }
      return .partial(TranscriptionPartial(text: text, isFinal: isFinal))
    case "Termination":
      return .terminated
    default:
      return .ignored
    }
  }

  static func mapped(_ error: Error) -> TranscriptionError {
    if let known = error as? TranscriptionError { return known }
    if error is CancellationError { return .cancelled }
    if let urlError = error as? URLError {
      if urlError.code == .cancelled { return .cancelled }
      if urlError.code == .userAuthenticationRequired { return .unauthorized }
      return .network(urlError.localizedDescription)
    }
    return .network(error.localizedDescription)
  }

  struct ServerFrame: Decodable {
    let type: String?
    let transcript: String?
    let endOfTurn: Bool?
    let error: String?
    let status: Int?

    enum CodingKeys: String, CodingKey {
      case type
      case transcript
      case endOfTurn = "end_of_turn"
      case error
      case status
    }
  }
}
