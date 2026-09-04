import Foundation
import Network

/// Reassembles newline-delimited messages from a byte stream that arrives in
/// whatever sized pieces TCP feels like handing over.
///
/// A framer exists at all because the two obvious shortcuts are both wrong: treating
/// one read as one message loses the second half of anything split across segments,
/// and appending to an unbounded buffer lets a client that never sends a newline eat
/// as much memory as it likes. So the buffer has a ceiling, and crossing it is a
/// reported outcome rather than a fatal one.
struct MCPLineFramer {
  /// What one read produced: the complete messages it finished, or the news that the
  /// caller should give up on this stream.
  enum Outcome: Equatable {
    case messages([String])
    /// No newline arrived before the buffer reached its limit.
    case overflow
  }

  /// The largest unterminated run of bytes tolerated before the stream is abandoned.
  let limit: Int
  private var buffer = Data()

  init(limit: Int) {
    self.limit = limit
  }

  mutating func append(_ incoming: Data) -> Outcome {
    buffer.append(incoming)

    var messages: [String] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      let line = buffer[buffer.startIndex..<newline]
      buffer = buffer[buffer.index(after: newline)...]
      // A line at the limit is still a line: the cap guards the buffer, not the
      // protocol, and `MCPServer` has its own opinion about request size.
      if let text = Self.text(of: line) { messages.append(text) }
    }
    // Rebase so the sliced storage does not grow without bound across reads.
    buffer = Data(buffer)

    if buffer.count > limit { return .overflow }
    return .messages(messages)
  }

  /// Trims the carriage return a Windows-side client leaves behind, and drops blank
  /// keep-alive lines, so neither reaches the JSON parser as a parse error.
  private static func text(of slice: Data) -> String? {
    var bytes = slice
    if bytes.last == 0x0D { bytes = bytes.dropLast() }
    guard let text = String(data: Data(bytes), encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// The reply sent when a client overruns the framing buffer.
///
/// It is a well-formed JSON-RPC error rather than a silent disconnect so the agent
/// on the other end can report something better than "the socket went away".
private func oversizedReply() -> String {
  JSONValue.object([
    "jsonrpc": .string("2.0"), "id": .null,
    "error": .object([
      "code": .int(MCPErrorCode.invalidRequest),
      "message": .string("Request too large."),
    ]),
  ]).encoded()
}

/// One accepted connection: a framer, and the discipline of handling messages one at
/// a time.
///
/// Reads are re-armed only after the current batch has been answered. That costs a
/// little throughput and buys ordering — two requests arriving in a single segment
/// come back in the order they were sent, which is what a client pairing replies to
/// ids by arrival expects.
private actor MCPSocketConnection {
  private let connection: NWConnection
  private let server: MCPServer
  private var framer: MCPLineFramer
  private let onClose: @Sendable () -> Void
  private var closed = false

  init(
    connection: NWConnection, server: MCPServer, limit: Int,
    onClose: @escaping @Sendable () -> Void
  ) {
    self.connection = connection
    self.server = server
    self.framer = MCPLineFramer(limit: limit)
    self.onClose = onClose
  }

  func start(queue: DispatchQueue) {
    connection.start(queue: queue)
    receive()
  }

  func cancel() {
    guard !closed else { return }
    closed = true
    connection.cancel()
  }

  private func receive() {
    guard !closed else { return }
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
      [weak self] data, _, isComplete, error in
      // Nothing from `Network` crosses the actor boundary: the context and the error
      // are reduced to plain values here, where they are still on the queue that
      // produced them.
      let chunk = data ?? Data()
      let finished = isComplete || error != nil
      guard let self else { return }
      Task { await self.ingest(chunk, finished: finished) }
    }
  }

  private func ingest(_ chunk: Data, finished: Bool) async {
    guard !closed else { return }
    if !chunk.isEmpty {
      switch framer.append(chunk) {
      case .overflow:
        // The reply has to be flushed before the socket goes: cancelling a
        // connection with a send still queued drops it, and the client would see a
        // bare disconnect instead of the reason.
        sendThenClose(oversizedReply())
        return
      case .messages(let messages):
        for message in messages {
          if let reply = await server.handle(message) { send(reply) }
        }
      }
    }
    if finished {
      close()
    } else {
      receive()
    }
  }

  private func send(_ line: String) {
    guard let data = (line + "\n").data(using: .utf8) else { return }
    connection.send(content: data, completion: .contentProcessed { _ in })
  }

  /// Sends, then closes once the data has actually been handed to the network.
  ///
  /// Cancelling straight after `send` discards anything still queued, so a client
  /// that broke a rule would see a dropped socket rather than the reason it was
  /// dropped — which is the difference between a diagnosable error and a mystery.
  private func sendThenClose(_ line: String) {
    guard let data = (line + "\n").data(using: .utf8) else {
      close()
      return
    }
    connection.send(
      content: data,
      completion: .contentProcessed { [weak self] _ in
        guard let self else { return }
        Task { await self.close() }
      })
  }

  private func close() {
    guard !closed else { return }
    closed = true
    connection.cancel()
    onClose()
  }
}

/// A loopback listener that speaks newline-delimited JSON-RPC to `MCPServer`.
///
/// The address is an `MCPBindAddress` rather than a host string, so a
/// misconfigured or hostile settings file cannot reach the bind call with anything
/// but loopback — the check happens when the value is made, not when it is used, and
/// there is no second path into this type that skips it.
public actor MCPSocketListener {
  public enum Failure: Error, Equatable, LocalizedError {
    case alreadyRunning
    case notStarted
    case bindFailed(String)

    public var errorDescription: String? {
      switch self {
      case .alreadyRunning: "The MCP listener is already running."
      case .notStarted: "The MCP listener is not running."
      case .bindFailed(let reason): "The MCP listener could not bind: \(reason)."
      }
    }
  }

  private enum Phase: Equatable {
    case idle, starting, ready, failed(String), cancelled
  }

  private let server: MCPServer
  private let address: MCPBindAddress
  private let usesEphemeralPort: Bool
  private let messageLimit: Int
  private let queue = DispatchQueue(label: "dev.rant.mac.mcp.listener")
  private let log = RantLog("MCP")

  private var listener: NWListener?
  private var phase: Phase = .idle
  private var connections: [UUID: MCPSocketConnection] = [:]
  private var readyWaiters: [CheckedContinuation<Void, Error>] = []
  private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
  private var boundPort = 0

  /// - Parameter ephemeralPort: bind port 0 and let the kernel choose. The host is
  ///   still the validated loopback one; only the port is relaxed, because a test
  ///   that hard-codes a port fails the moment anything else on the machine wants it.
  ///   `MCPBindAddress` refuses port 0 by design, so this is the one way to ask for
  ///   it and it cannot widen the interface the socket answers on.
  public init(
    server: MCPServer,
    address: MCPBindAddress,
    ephemeralPort: Bool = false,
    maximumMessageBytes: Int = MCPServer.maximumRequestBytes
  ) {
    self.server = server
    self.address = address
    self.usesEphemeralPort = ephemeralPort
    self.messageLimit = maximumMessageBytes
  }

  /// Convenience for the settings the user actually edited. Throws before anything
  /// is allocated when the host they typed is not loopback.
  public init(
    server: MCPServer,
    settings: MCPSettings,
    maximumMessageBytes: Int = MCPServer.maximumRequestBytes
  ) throws {
    self.init(
      server: server, address: try settings.bindAddress(),
      maximumMessageBytes: maximumMessageBytes)
  }

  /// The port the socket is actually on, which is only interesting when the kernel
  /// picked it. Zero until `start()` has returned.
  public var port: Int { boundPort }

  public var isRunning: Bool { phase == .ready }

  // MARK: - Lifecycle

  /// Starts listening and returns once the socket is accepting, or throws. Waiting
  /// for readiness rather than returning immediately means a caller that starts and
  /// then connects cannot lose the race, and a port already in use is an error here
  /// instead of a connection that mysteriously never arrives.
  public func start() async throws {
    guard listener == nil else { throw Failure.alreadyRunning }

    let parameters = NWParameters.tcp
    // Without this a listener that has just been cancelled can leave the port in
    // TIME_WAIT and the next start fails for no reason the user could act on.
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
      host: Self.loopbackHost(for: address), port: portToBind())

    let listener: NWListener
    do {
      listener = try NWListener(using: parameters)
    } catch {
      throw Failure.bindFailed(String(describing: error))
    }

    listener.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      let summary = Self.summarise(state)
      Task { await self.stateChanged(summary) }
    }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else {
        connection.cancel()
        return
      }
      Task { await self.accept(connection) }
    }

    self.listener = listener
    phase = .starting
    listener.start(queue: queue)

    do {
      try await waitForReady()
    } catch {
      listener.cancel()
      self.listener = nil
      phase = .idle
      throw error
    }

    boundPort = Int(listener.port?.rawValue ?? 0)
    log.info("listener ready on \(address.host):\(boundPort)")
  }

  /// Stops accepting and waits until the socket is genuinely gone, so a caller that
  /// stops and immediately restarts on the same port is not racing the kernel.
  public func stop() async {
    for connection in connections.values { await connection.cancel() }
    connections.removeAll()

    guard let listener else {
      phase = .idle
      return
    }
    self.listener = nil
    listener.cancel()
    if phase != .cancelled {
      await withCheckedContinuation { continuation in
        cancelWaiters.append(continuation)
      }
    }
    phase = .idle
    boundPort = 0
    log.info("listener stopped")
  }

  // MARK: - Internals

  private func portToBind() -> NWEndpoint.Port {
    guard !usesEphemeralPort else { return .any }
    return NWEndpoint.Port(rawValue: UInt16(address.port)) ?? .any
  }

  /// `MCPBindAddress` has already established that this is loopback, so the mapping
  /// only has to pick which loopback literal to hand `Network` — never to decide
  /// whether the host is acceptable.
  private static func loopbackHost(for address: MCPBindAddress) -> NWEndpoint.Host {
    let host = address.host.trimmingCharacters(in: .whitespaces).lowercased()
    if host == "::1" || host == "[::1]" { return .ipv6(.loopback) }
    if let literal = IPv4Address(host) { return .ipv4(literal) }
    return .ipv4(.loopback)
  }

  /// `NWListener.State` is reduced to a value the actor can store. `.waiting` counts
  /// as a failure: for a loopback socket it means the port is taken, and retrying
  /// forever behind the scenes would turn a configuration mistake into a hang.
  private static func summarise(_ state: NWListener.State) -> Phase {
    switch state {
    case .ready: .ready
    case .failed(let error): .failed(String(describing: error))
    case .waiting(let error): .failed(String(describing: error))
    case .cancelled: .cancelled
    default: .starting
    }
  }

  private func stateChanged(_ next: Phase) {
    switch next {
    case .ready:
      phase = .ready
      let waiters = readyWaiters
      readyWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    case .failed(let reason):
      phase = .failed(reason)
      let waiters = readyWaiters
      readyWaiters.removeAll()
      for waiter in waiters { waiter.resume(throwing: Failure.bindFailed(reason)) }
      let cancels = cancelWaiters
      cancelWaiters.removeAll()
      for waiter in cancels { waiter.resume() }
    case .cancelled:
      phase = .cancelled
      let cancels = cancelWaiters
      cancelWaiters.removeAll()
      for waiter in cancels { waiter.resume() }
      let waiters = readyWaiters
      readyWaiters.removeAll()
      for waiter in waiters { waiter.resume(throwing: Failure.notStarted) }
    case .starting, .idle:
      phase = .starting
    }
  }

  private func waitForReady() async throws {
    switch phase {
    case .ready: return
    case .failed(let reason): throw Failure.bindFailed(reason)
    case .cancelled: throw Failure.notStarted
    case .idle, .starting:
      try await withCheckedThrowingContinuation { continuation in
        readyWaiters.append(continuation)
      }
    }
  }

  private func accept(_ connection: NWConnection) async {
    let id = UUID()
    let handler = MCPSocketConnection(
      connection: connection, server: server, limit: messageLimit,
      onClose: { [weak self] in
        Task { await self?.forget(id) }
      })
    connections[id] = handler
    await handler.start(queue: queue)
  }

  private func forget(_ id: UUID) {
    connections[id] = nil
  }
}

/// The stdio transport, for `claude mcp add`-style clients that launch Rant's helper
/// and talk to it over a pipe.
///
/// The streams are supplied rather than taken from `FileHandle.standardInput`, which
/// is the only reason this is testable: a test hands it two `Pipe`s, and nothing has
/// to redirect the process's own descriptors and hope to put them back.
public struct MCPStdioTransport: Sendable {
  private let server: MCPServer
  private let messageLimit: Int

  public init(server: MCPServer, maximumMessageBytes: Int = MCPServer.maximumRequestBytes) {
    self.server = server
    self.messageLimit = maximumMessageBytes
  }

  /// Reads until the input reaches end of file. Returns when the client goes away.
  public func run(input: FileHandle, output: FileHandle) async {
    await run(input: input) { line in
      guard let data = (line + "\n").data(using: .utf8) else { return }
      // A closed pipe is how the client says goodbye, not something worth crashing on.
      try? output.write(contentsOf: data)
    }
  }

  public func run(input: FileHandle, write: @escaping @Sendable (String) -> Void) async {
    var framer = MCPLineFramer(limit: messageLimit)
    for await chunk in Self.chunks(of: input) {
      switch framer.append(chunk) {
      case .overflow:
        // Answer, then stop reading this stream. Leaving the loop finishes the
        // AsyncStream, whose termination handler releases the reading thread.
        write(oversizedReply())
        return
      case .messages(let messages):
        for message in messages {
          if let reply = await server.handle(message) { write(reply) }
        }
      }
    }
  }

  /// The read is a plain blocking `read(2)` on the descriptor rather than
  /// `FileHandle.read(upToCount:)`: the `FileHandle` variant does not reliably return
  /// as soon as a pipe has bytes in it, which for a request/response protocol reads
  /// as the client being ignored. It happens on a dispatch queue because it blocks,
  /// and parking a cooperative thread for as long as the client stays quiet would
  /// starve everything else.
  private static func chunks(of input: FileHandle) -> AsyncStream<Data> {
    let descriptor = input.fileDescriptor
    return AsyncStream { continuation in
      let queue = DispatchQueue(label: "dev.rant.mac.mcp.stdio")
      queue.async {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
          let count = buffer.withUnsafeMutableBytes { raw in
            read(descriptor, raw.baseAddress, raw.count)
          }
          if count > 0 {
            continuation.yield(Data(buffer[0..<count]))
          } else if count < 0 && errno == EINTR {
            // A signal interrupted the wait; that is not the client hanging up.
            continue
          } else {
            break
          }
        }
        continuation.finish()
      }
    }
  }
}
