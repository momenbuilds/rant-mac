import Combine
import RantCore
import SwiftUI

/// Starts and stops the local MCP server, and reports honestly on what it is doing.
///
/// The whole server — tools, permissions, loopback-only bind validation, and an audit
/// trail — was implemented and tested, and the app had a `mcpEnabled` preference that
/// nothing read. The toggle existed; the server never ran.
///
/// Off by default, and only ever bound to loopback: `MCPBindAddress` refuses anything
/// else before a socket is allocated, so "local only" is enforced by construction
/// rather than by a checkbox somebody could mis-set.
@MainActor
final class MCPController: ObservableObject {
  @Published private(set) var isRunning = false
  @Published private(set) var boundPort: Int?
  @Published private(set) var lastError: String?
  @Published private(set) var audit: [MCPAuditEntry] = []

  private let server: MCPServer
  private var listener: MCPSocketListener?
  private let log = RantLog("MCP")

  init(database: Database, settings: MCPSettings) {
    self.server = MCPServer(settings: settings, database: database)
  }

  /// Bring the server into line with the user's settings.
  ///
  /// Called on launch and whenever the settings change, so turning the toggle off
  /// actually closes the socket rather than only stopping new grants.
  func apply(_ settings: MCPSettings) {
    Task { [weak self] in
      guard let self else { return }
      await server.update(settings: settings)
      if settings.enabled {
        await start(settings)
      } else {
        await stop()
      }
    }
  }

  private func start(_ settings: MCPSettings) async {
    guard listener == nil else { return }
    do {
      let listener = try MCPSocketListener(server: server, settings: settings)
      try await listener.start()
      self.listener = listener
      self.boundPort = await listener.port
      self.isRunning = true
      self.lastError = nil
      log.info("MCP listening on \(settings.host):\(self.boundPort ?? settings.port)")
    } catch {
      // A refused bind is the interesting case — a non-loopback host, or a port
      // already taken — and it must be visible rather than leaving a toggle that
      // looks on with nothing behind it.
      self.lastError = error.localizedDescription
      self.isRunning = false
      self.listener = nil
      log.error("MCP could not start: \(error.localizedDescription)")
    }
  }

  private func stop() async {
    guard let listener else { return }
    await listener.stop()
    self.listener = nil
    isRunning = false
    boundPort = nil
  }

  /// What agents have actually asked for. Shown in Settings because a local server
  /// you cannot inspect is a local server you have to take on trust.
  func refreshAudit() {
    Task { [weak self] in
      guard let self else { return }
      let entries = (try? await server.recentAudit(limit: 100)) ?? []
      self.audit = entries
    }
  }
}
