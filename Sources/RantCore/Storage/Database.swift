import Foundation
import SQLite3

/// A thin, honest wrapper over SQLite.
///
/// Not an ORM. Rant's storage needs are a dozen tables and some full-text search, and
/// a hand-written wrapper keeps the SQL visible — which matters when the schema is
/// also the user's data-ownership guarantee. Anyone can open `rant.sqlite` with the
/// `sqlite3` command and read everything Rant knows about them.
public final class Database: @unchecked Sendable {
  private var handle: OpaquePointer?
  private let lock = NSRecursiveLock()
  private let log = RantLog("Database")

  public enum StorageError: Error, LocalizedError {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)
    case migrationFailed(version: Int, message: String)

    public var errorDescription: String? {
      switch self {
      case .open(let message): "Could not open the Rant database: \(message)"
      case .prepare(let message, let sql): "Bad SQL (\(message)): \(sql)"
      case .step(let message, let sql): "Query failed (\(message)): \(sql)"
      case .migrationFailed(let version, let message):
        "Database migration \(version) failed: \(message)"
      }
    }
  }

  /// Opens (or creates) the database at `url`. Pass nil for a private in-memory
  /// database — which the tests use, so they exercise exactly the same SQL as
  /// production rather than a substitute.
  public init(url: URL?) throws {
    var handle: OpaquePointer?
    let path = url?.path ?? ":memory:"
    if let url {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
      sqlite3_close_v2(handle)
      throw StorageError.open(message)
    }
    self.handle = handle

    // WAL lets a read (history search) run while a write (a finished dictation) is in
    // flight, which is the whole concurrency story this app has.
    if url != nil { try execute("PRAGMA journal_mode = WAL;") }
    try execute("PRAGMA foreign_keys = ON;")
    try execute("PRAGMA synchronous = NORMAL;")
    try execute("PRAGMA busy_timeout = 5000;")
  }

  deinit { sqlite3_close_v2(handle) }

  public func close() {
    lock.withLock {
      sqlite3_close_v2(handle)
      handle = nil
    }
  }

  // MARK: - Executing

  public func execute(_ sql: String) throws {
    try lock.withLock {
      var error: UnsafeMutablePointer<CChar>?
      guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
        let message = error.map { String(cString: $0) } ?? "unknown"
        sqlite3_free(error)
        throw StorageError.step(message, sql: sql)
      }
    }
  }

  /// Runs a statement with bound parameters and no result rows.
  @discardableResult
  public func run(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int64 {
    try lock.withLock {
      let statement = try prepare(sql, parameters)
      defer { sqlite3_finalize(statement) }
      let status = sqlite3_step(statement)
      guard status == SQLITE_DONE || status == SQLITE_ROW else {
        throw StorageError.step(String(cString: sqlite3_errmsg(handle)), sql: sql)
      }
      return sqlite3_last_insert_rowid(handle)
    }
  }

  /// Runs a query and maps each row.
  public func query<T>(
    _ sql: String, _ parameters: [SQLValue] = [], _ decode: (Row) throws -> T
  ) throws -> [T] {
    try lock.withLock {
      let statement = try prepare(sql, parameters)
      defer { sqlite3_finalize(statement) }
      var results: [T] = []
      while true {
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { break }
        guard status == SQLITE_ROW else {
          throw StorageError.step(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        results.append(try decode(Row(statement: statement)))
      }
      return results
    }
  }

  /// Runs `work` inside a transaction, rolling back if it throws. Migrations and
  /// multi-table writes go through here so a crash cannot leave half a record.
  public func transaction<T>(_ work: () throws -> T) throws -> T {
    try lock.withLock {
      try execute("BEGIN IMMEDIATE;")
      do {
        let result = try work()
        try execute("COMMIT;")
        return result
      } catch {
        try? execute("ROLLBACK;")
        throw error
      }
    }
  }

  private func prepare(_ sql: String, _ parameters: [SQLValue]) throws -> OpaquePointer? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw StorageError.prepare(String(cString: sqlite3_errmsg(handle)), sql: sql)
    }
    for (offset, value) in parameters.enumerated() {
      value.bind(to: statement, at: Int32(offset + 1))
    }
    return statement
  }

  // MARK: - Schema version

  public var userVersion: Int {
    get {
      (try? query("PRAGMA user_version;") { $0.int(0) }.first) .flatMap { $0 } ?? 0
    }
  }

  public func setUserVersion(_ version: Int) throws {
    try execute("PRAGMA user_version = \(version);")
  }

  /// Size on disk, for the diagnostics view. Users deserve to know how much of their
  /// machine this is using.
  public var pageCountBytes: Int {
    let pages = (try? query("PRAGMA page_count;") { $0.int(0) }.first ?? 0) ?? 0
    let size = (try? query("PRAGMA page_size;") { $0.int(0) }.first ?? 0) ?? 0
    return pages * size
  }
}

/// A value that can be bound to a statement parameter.
public enum SQLValue: Equatable, Sendable, ExpressibleByStringLiteral,
  ExpressibleByIntegerLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral,
  ExpressibleByBooleanLiteral
{
  case text(String)
  case int(Int)
  case double(Double)
  case blob(Data)
  case null

  public init(stringLiteral value: String) { self = .text(value) }
  public init(integerLiteral value: Int) { self = .int(value) }
  public init(floatLiteral value: Double) { self = .double(value) }
  public init(booleanLiteral value: Bool) { self = .int(value ? 1 : 0) }
  public init(nilLiteral: ()) { self = .null }

  public init(_ value: String?) { self = value.map { .text($0) } ?? .null }
  public init(_ value: Int?) { self = value.map { .int($0) } ?? .null }
  public init(_ value: Double?) { self = value.map { .double($0) } ?? .null }
  public init(_ value: Bool) { self = .int(value ? 1 : 0) }
  public init(_ value: Date) { self = .double(value.timeIntervalSince1970) }
  public init(_ value: Date?) { self = value.map { .double($0.timeIntervalSince1970) } ?? .null }

  func bind(to statement: OpaquePointer?, at index: Int32) {
    // SQLITE_TRANSIENT: SQLite copies the bytes rather than holding our pointer.
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    switch self {
    case .text(let value): sqlite3_bind_text(statement, index, value, -1, transient)
    case .int(let value): sqlite3_bind_int64(statement, index, Int64(value))
    case .double(let value): sqlite3_bind_double(statement, index, value)
    case .blob(let data):
      _ = data.withUnsafeBytes { buffer in
        sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), transient)
      }
    case .null: sqlite3_bind_null(statement, index)
    }
  }
}

/// One result row, read by column index.
public struct Row {
  let statement: OpaquePointer?

  public func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
  public func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
  public func bool(_ index: Int32) -> Bool { int(index) != 0 }
  public func date(_ index: Int32) -> Date { Date(timeIntervalSince1970: double(index)) }

  public func string(_ index: Int32) -> String {
    guard let pointer = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: pointer)
  }

  public func stringOrNil(_ index: Int32) -> String? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : string(index)
  }

  public func intOrNil(_ index: Int32) -> Int? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : int(index)
  }

  public func dateOrNil(_ index: Int32) -> Date? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : date(index)
  }

  public func doubleOrNil(_ index: Int32) -> Double? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : double(index)
  }

  public func data(_ index: Int32) -> Data {
    guard let pointer = sqlite3_column_blob(statement, index) else { return Data() }
    return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, index)))
  }
}
