import Foundation
import XCTest

@testable import RantCore

/// The listener's tests do the one thing `MCPTests` refuses to do: open a real
/// socket.
///
/// Every one of them binds port 0 and asks the kernel which port it got, because a
/// hard-coded port turns a test suite into something that fails whenever the
/// developer happens to be running something else. Every wait has an explicit
/// deadline for the same reason a socket test is worth distrusting: the failure mode
/// of a framing bug is a read that never returns, and a hanging test tells you far
/// less than a failing one.
final class MCPTransportTests: XCTestCase {

  // MARK: - Fixtures

  private func freshDatabase() throws -> Database {
    let database = try Database(url: nil)
    try Migrations.migrate(database)
    return database
  }

  private func enabledServer() throws -> MCPServer {
    MCPServer(
      settings: MCPSettings(enabled: true, collections: [.transcripts]),
      database: try freshDatabase())
  }

  private func loopback(port: Int = 1) throws -> MCPBindAddress {
    try MCPBindAddress(host: "127.0.0.1", port: port)
  }

  private func startedListener(
    server: MCPServer, limit: Int = MCPServer.maximumRequestBytes
  ) async throws -> (MCPSocketListener, Int) {
    let listener = MCPSocketListener(
      server: server, address: try loopback(), ephemeralPort: true, maximumMessageBytes: limit)
    try await listener.start()
    let port = await listener.port
    XCTAssertGreaterThan(port, 0, "the kernel should have assigned a port")
    return (listener, port)
  }

  private static let ping = #"{"jsonrpc":"2.0","id":%ID%,"method":"ping"}"#

  private func ping(id: Int) -> String {
    Self.ping.replacingOccurrences(of: "%ID%", with: String(id))
  }

  // MARK: - Round trips

  func testARequestSentOverTheSocketIsAnswered() async throws {
    let (listener, port) = try await startedListener(server: try enabledServer())
    defer { Task { await listener.stop() } }

    let client = try SocketClient(port: port)
    defer { client.close() }
    try client.send(ping(id: 1) + "\n")

    let reply = try XCTUnwrap(client.readLine(timeout: 3), "no reply arrived within 3s")
    XCTAssertTrue(reply.contains("\"id\":1"), reply)
    XCTAssertTrue(reply.contains("\"result\""), reply)
    await listener.stop()
  }

  func testAMessageSplitAcrossTwoWritesIsStillHandled() async throws {
    let (listener, port) = try await startedListener(server: try enabledServer())
    let client = try SocketClient(port: port)
    defer {
      client.close()
    }

    let whole = ping(id: 7) + "\n"
    let split = whole.index(whole.startIndex, offsetBy: 12)
    try client.send(String(whole[whole.startIndex..<split]))
    // A deliberate gap so the two halves cannot be coalesced into one segment; the
    // point of the test is the reassembly, not the scheduling.
    usleep(50_000)
    try client.send(String(whole[split...]))

    let reply = try XCTUnwrap(client.readLine(timeout: 3), "the split message was dropped")
    XCTAssertTrue(reply.contains("\"id\":7"), reply)
    await listener.stop()
  }

  func testTwoMessagesInOneWriteAreBothHandled() async throws {
    let (listener, port) = try await startedListener(server: try enabledServer())
    let client = try SocketClient(port: port)
    defer { client.close() }

    try client.send(ping(id: 11) + "\n" + ping(id: 12) + "\n")

    let first = try XCTUnwrap(client.readLine(timeout: 3), "no first reply")
    let second = try XCTUnwrap(client.readLine(timeout: 3), "only one of two replies arrived")
    XCTAssertTrue(first.contains("\"id\":11"), first)
    XCTAssertTrue(second.contains("\"id\":12"), second)
    await listener.stop()
  }

  func testMalformedJSONProducesAJSONRPCErrorRatherThanACrash() async throws {
    let (listener, port) = try await startedListener(server: try enabledServer())
    let client = try SocketClient(port: port)
    defer { client.close() }

    try client.send("{not json at all}\n")

    let reply = try XCTUnwrap(client.readLine(timeout: 3), "the parse error was never sent")
    XCTAssertTrue(reply.contains("\"code\":\(MCPErrorCode.parse)"), reply)
    XCTAssertTrue(reply.contains("\"jsonrpc\":\"2.0\""), reply)
    await listener.stop()
  }

  // MARK: - Limits and lifecycle

  func testAnOversizedMessageIsRefusedRatherThanBuffered() async throws {
    let (listener, port) = try await startedListener(server: try enabledServer(), limit: 512)
    let client = try SocketClient(port: port)
    defer { client.close() }

    // No newline anywhere: the only thing that can stop this is the buffer cap.
    try client.send(String(repeating: "a", count: 4_096))

    let reply = try XCTUnwrap(client.readLine(timeout: 3), "the oversized request was accepted")
    XCTAssertTrue(reply.contains("\"code\":\(MCPErrorCode.invalidRequest)"), reply)
    XCTAssertTrue(reply.contains("Request too large"), reply)
    await listener.stop()
  }

  func testMultipleSequentialClientsAreEachServed() async throws {
    let (listener, port) = try await startedListener(server: try enabledServer())
    defer { Task { await listener.stop() } }

    for id in 1...3 {
      let client = try SocketClient(port: port)
      try client.send(ping(id: id) + "\n")
      let reply = try XCTUnwrap(client.readLine(timeout: 3), "client \(id) got nothing")
      XCTAssertTrue(reply.contains("\"id\":\(id)"), reply)
      client.close()
    }
    await listener.stop()
  }

  func testStoppingTheListenerReleasesThePortForASecondStart() async throws {
    let (first, port) = try await startedListener(server: try enabledServer())
    await first.stop()

    // The same port, explicitly, so this proves the socket was released and not that
    // the kernel handed out a different one.
    let second = MCPSocketListener(
      server: try enabledServer(), address: try loopback(port: port))
    try await second.start()
    let reboundPort = await second.port
    XCTAssertEqual(reboundPort, port)

    let client = try SocketClient(port: port)
    defer { client.close() }
    try client.send(ping(id: 5) + "\n")
    let reply = try XCTUnwrap(client.readLine(timeout: 3), "the restarted listener is deaf")
    XCTAssertTrue(reply.contains("\"id\":5"), reply)
    await second.stop()
  }

  func testADisabledServerAnswersNothingOverTheSocket() async throws {
    let server = MCPServer(settings: .disabled, database: try freshDatabase())
    let (listener, port) = try await startedListener(server: server)
    let client = try SocketClient(port: port)
    defer { client.close() }

    try client.send(ping(id: 9) + "\n")

    // Silence is the contract: a server the user never switched on should look like
    // one that was never built.
    XCTAssertNil(client.readLine(timeout: 1), "a disabled server replied")
    await listener.stop()
  }

  // MARK: - The bind address

  func testANonLoopbackAddressCannotBeConstructedOrBound() async throws {
    for host in ["0.0.0.0", "::", "10.0.0.5", "192.168.1.20", "example.com"] {
      XCTAssertThrowsError(try MCPBindAddress(host: host, port: 7_373), host) { error in
        XCTAssertEqual(error as? MCPBindAddress.Failure, .notLoopback(host))
      }
    }

    // And the settings-shaped route into the listener refuses before it allocates
    // anything, so there is no path to the bind call that skips the check.
    let server = try enabledServer()
    XCTAssertThrowsError(
      try MCPSocketListener(
        server: server, settings: MCPSettings(enabled: true, host: "0.0.0.0", port: 7_373)))
  }

  func testTheListenerRefusesToStartTwice() async throws {
    let (listener, _) = try await startedListener(server: try enabledServer())
    do {
      try await listener.start()
      XCTFail("a second start should have been refused")
    } catch {
      XCTAssertEqual(error as? MCPSocketListener.Failure, .alreadyRunning)
    }
    await listener.stop()
  }

  // MARK: - Framing in isolation

  func testTheFramerRebuildsAMessageFromArbitraryFragments() {
    var framer = MCPLineFramer(limit: 1_024)
    XCTAssertEqual(framer.append(Data("{\"a\":".utf8)), .messages([]))
    XCTAssertEqual(framer.append(Data("1}\n{\"b\":2}\n\n".utf8)), .messages(["{\"a\":1}", "{\"b\":2}"]))
    XCTAssertEqual(framer.append(Data("{\"c\":3}\r\n".utf8)), .messages(["{\"c\":3}"]))
  }

  func testTheFramerReportsOverflowInsteadOfGrowing() {
    var framer = MCPLineFramer(limit: 16)
    XCTAssertEqual(framer.append(Data(repeating: 0x61, count: 8)), .messages([]))
    XCTAssertEqual(framer.append(Data(repeating: 0x61, count: 64)), .overflow)
  }

  // MARK: - stdio

  func testTheStdioTransportAnswersOnASuppliedPipe() async throws {
    let input = Pipe()
    let collected = Collected()
    let transport = MCPStdioTransport(server: try enabledServer())

    let task = Task {
      await transport.run(input: input.fileHandleForReading) { line in
        collected.append(line)
      }
    }

    try input.fileHandleForWriting.write(contentsOf: Data((ping(id: 21) + "\n").utf8))
    let first = try await collected.wait(forLines: 1, timeout: 3)
    XCTAssertTrue(first[0].contains("\"id\":21"), first[0])

    try input.fileHandleForWriting.write(contentsOf: Data((ping(id: 22) + "\n").utf8))
    let both = try await collected.wait(forLines: 2, timeout: 3)
    XCTAssertTrue(both[1].contains("\"id\":22"), both[1])

    // Closing the write end is end of file, which is how the transport is meant to
    // finish rather than being cancelled from outside.
    try input.fileHandleForWriting.close()
    _ = await task.value
  }

  func testTheStdioTransportRefusesAnOversizedMessage() async throws {
    let input = Pipe()
    let collected = Collected()
    let transport = MCPStdioTransport(server: try enabledServer(), maximumMessageBytes: 256)

    let task = Task {
      await transport.run(input: input.fileHandleForReading) { line in
        collected.append(line)
      }
    }

    try input.fileHandleForWriting.write(contentsOf: Data(String(repeating: "a", count: 2_048).utf8))
    let lines = try await collected.wait(forLines: 1, timeout: 3)
    XCTAssertTrue(lines[0].contains("Request too large"), lines[0])
    try? input.fileHandleForWriting.close()
    _ = await task.value
  }
}

// MARK: - Helpers

/// Lines written by a transport under test, readable from the test's own thread.
private final class Collected: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String] = []

  func append(_ line: String) { lock.withLock { lines.append(line) } }
  var all: [String] { lock.withLock { lines } }

  /// Polls rather than waits on a condition variable, and gives up out loud: an
  /// assertion that never fires is worse than one that fails.
  func wait(forLines count: Int, timeout: TimeInterval) async throws -> [String] {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      let current = all
      if current.count >= count { return current }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw Timeout.expired
  }

  enum Timeout: Error { case expired }
}

/// A deliberately plain blocking client. Using POSIX sockets rather than
/// `Network` keeps the test side free of the machinery it is testing, and a receive
/// timeout means a framing bug shows up as a failed assertion rather than a suite
/// that never finishes.
private final class SocketClient {
  private let descriptor: Int32
  private var pending = Data()

  init(port: Int) throws {
    descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw Failure.couldNotOpen }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")

    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
        connect(descriptor, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else {
      Darwin.close(descriptor)
      throw Failure.couldNotConnect
    }
  }

  enum Failure: Error { case couldNotOpen, couldNotConnect, couldNotSend }

  func send(_ text: String) throws {
    let bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
      let written = bytes.withUnsafeBytes { buffer in
        write(descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
      }
      guard written > 0 else { throw Failure.couldNotSend }
      offset += written
    }
  }

  /// One line, or nil if none arrived before the deadline.
  func readLine(timeout: TimeInterval) -> String? {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      if let index = pending.firstIndex(of: 0x0A) {
        let line = pending[pending.startIndex..<index]
        pending = Data(pending[pending.index(after: index)...])
        return String(data: Data(line), encoding: .utf8)
      }
      let remaining = deadline.timeIntervalSinceNow
      if remaining <= 0 { return nil }
      setReceiveTimeout(remaining)

      var buffer = [UInt8](repeating: 0, count: 4_096)
      let count = recv(descriptor, &buffer, buffer.count, 0)
      if count > 0 {
        pending.append(contentsOf: buffer[0..<count])
      } else {
        // Zero is a closed connection, negative is the timeout expiring. Neither is
        // worth retrying in a tight loop.
        return nil
      }
    }
  }

  private func setReceiveTimeout(_ seconds: TimeInterval) {
    var value = timeval(
      tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
    setsockopt(
      descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
  }

  func close() {
    Darwin.close(descriptor)
  }
}
