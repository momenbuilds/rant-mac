import Foundation

/// The seam between our provider code and `URLSession`.
///
/// It exists so the request-construction tests — which are the ones that matter,
/// because a wrong header or a wrong field name is a silent 400 in production — can
/// run with no network, no API key and no money spent. `URLProtocol`-based mocking
/// cannot reliably observe the body of an upload, and the multipart framing is
/// exactly what we most want to assert on.
public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest, body: Data?) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
  public func send(_ request: URLRequest, body: Data?) async throws -> (Data, HTTPURLResponse) {
    let (data, response): (Data, URLResponse)
    if let body {
      (data, response) = try await upload(for: request, from: body)
    } else {
      (data, response) = try await self.data(for: request)
    }
    guard let http = response as? HTTPURLResponse else {
      throw TranscriptionError.malformedResponse
    }
    return (data, http)
  }
}

/// Records what it was asked to send and replays a scripted answer.
public final class FakeHTTPTransport: HTTPTransport, @unchecked Sendable {
  public struct Exchange: Sendable {
    public var request: URLRequest
    public var body: Data?
  }

  public private(set) var exchanges: [Exchange] = []
  private var responses: [Result<(Data, HTTPURLResponse), Error>]
  private let lock = NSLock()

  /// `responses` is consumed in order; the last one repeats once exhausted, so a
  /// retry test does not have to enumerate every attempt.
  public init(responses: [Result<(Data, HTTPURLResponse), Error>]) {
    self.responses = responses
  }

  public convenience init(json: String, status: Int = 200, url: String = "https://example.invalid") {
    let response = HTTPURLResponse(
      url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: nil)!
    self.init(responses: [.success((Data(json.utf8), response))])
  }

  public convenience init(failure: Error) {
    self.init(responses: [.failure(failure)])
  }

  public func send(_ request: URLRequest, body: Data?) async throws -> (Data, HTTPURLResponse) {
    let result: Result<(Data, HTTPURLResponse), Error> = lock.withLock {
      exchanges.append(Exchange(request: request, body: body))
      if responses.count > 1 { return responses.removeFirst() }
      return responses.first ?? .failure(TranscriptionError.malformedResponse)
    }
    return try result.get()
  }

  public var lastBody: Data? { lock.withLock { exchanges.last?.body } }
  public var lastRequest: URLRequest? { lock.withLock { exchanges.last?.request } }
  public var requestCount: Int { lock.withLock { exchanges.count } }
}
