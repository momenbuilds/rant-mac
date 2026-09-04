import XCTest
@testable import RantCore

/// The Keychain is the one place a secret is allowed to be, so the rules around it
/// are worth pinning. The real Keychain is deliberately not exercised here: a test
/// that pops a system password dialog is a test nobody runs, and CI has no keychain
/// to unlock.
final class SecretStoreTests: XCTestCase {

  // MARK: - The store contract

  func testWritingAndReadingBack() throws {
    let store = InMemorySecretStore()
    try store.write("a-key-value", for: .assemblyAI)
    XCTAssertEqual(try store.read(.assemblyAI), "a-key-value")
  }

  func testReadingASecretThatWasNeverStoredIsNilRatherThanAnError() throws {
    XCTAssertNil(try InMemorySecretStore().read(.assemblyAI))
  }

  func testWhitespaceIsTrimmedOnTheWayIn() throws {
    let store = InMemorySecretStore()
    try store.write("  key-with-spaces  \n", for: .assemblyAI)
    XCTAssertEqual(try store.read(.assemblyAI), "key-with-spaces")
  }

  /// Storing an empty string is how the UI says "remove it", and it must actually
  /// remove it rather than leave an empty secret that later reads as configured.
  func testWritingAnEmptyValueDeletesTheSecret() throws {
    let store = InMemorySecretStore()
    try store.write("something", for: .assemblyAI)
    try store.write("   ", for: .assemblyAI)
    XCTAssertNil(try store.read(.assemblyAI))
  }

  func testDeletingSomethingThatIsNotThereIsHarmless() throws {
    XCTAssertNoThrow(try InMemorySecretStore().delete(.assemblyAI))
  }

  func testSecretsAreKeptSeparatePerKey() throws {
    let store = InMemorySecretStore()
    try store.write("assembly", for: .assemblyAI)
    try store.write("openai", for: .openAICompatible)
    XCTAssertEqual(try store.read(.assemblyAI), "assembly")
    XCTAssertEqual(try store.read(.openAICompatible), "openai")
  }

  /// The full inventory of what this app can store is meant to be one screenful, so
  /// a new secret is a deliberate decision rather than something that accretes.
  func testTheInventoryOfStorableSecretsIsSmallAndNamed() {
    XCTAssertEqual(SecretKey.allCases.count, 3)
    for key in SecretKey.allCases {
      XCTAssertFalse(key.displayName.isEmpty)
      XCTAssertFalse(key.rawValue.isEmpty)
    }
  }

  // MARK: - Key validation

  func testAPlausibleKeyIsAccepted() {
    XCTAssertEqual(APIKeyValidator.check("0123456789abcdef0123456789abcdef"), .looksValid)
  }

  func testAnEmptyKeyIsReportedAsEmpty() {
    XCTAssertEqual(APIKeyValidator.check("   "), .empty)
  }

  func testAShortKeyIsRejectedBeforeSpendingARequest() {
    XCTAssertEqual(APIKeyValidator.check("too-short"), .tooShort)
  }

  /// The two overwhelmingly common paste mistakes, caught before they turn into a
  /// confusing 401.
  func testPastingAWholeCommandIsRecognised() {
    XCTAssertEqual(
      APIKeyValidator.check("curl -H 'Authorization: abc' https://api.example.com"),
      .looksLikeACommand)
    XCTAssertEqual(APIKeyValidator.check("https://example.com/key"), .looksLikeACommand)
  }

  func testAKeyWithStrayTextIsRecognised() {
    XCTAssertEqual(
      APIKeyValidator.check("Authorization 0123456789abcdef0123456789"), .containsWhitespace)
  }

  func testEveryRejectionExplainsItselfAndAValidKeySaysNothing() {
    XCTAssertNil(APIKeyValidator.Verdict.looksValid.message)
    for verdict in [
      APIKeyValidator.Verdict.empty, .tooShort, .containsWhitespace, .looksLikeACommand,
    ] {
      XCTAssertFalse(verdict.message?.isEmpty ?? true, "\(verdict) has no explanation")
    }
  }

  // MARK: - Redaction

  func testCredentialShapesAreRedacted() {
    let redactor = SecretRedactor()
    for secret in [
      "sk-abcdefghijklmnopqrstuvwxyz012345",  // not-a-real-key
      "ghp_abcdefghijklmnopqrstuvwxyz0123",  // not-a-real-key
      "AKIAIOSFODNN7EXAMPLE",  // not-a-real-key
      "xoxb-1234567890-abcdefghij",  // not-a-real-key
      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijk",
      "api_key = \"averylongsecretvaluegoeshere1234\"",
      "password: hunter2hunter2hunter2",
    ] {
      let redacted = redactor.redact("before \(secret) after")
      XCTAssertFalse(redacted.contains(secret), "not redacted: \(secret)")
      XCTAssertTrue(redacted.contains("redacted"))
    }
  }

  /// The redactor is deliberately conservative, but it must not eat ordinary prose —
  /// a cleaner that mangles what you dictated is worse than one that misses an
  /// unusual key shape.
  func testOrdinaryDictationIsLeftAlone() {
    let redactor = SecretRedactor()
    for sentence in [
      "Let us ship the migration on Wednesday.",
      "My password manager is 1Password, by the way.",
      "The API key is in the usual place.",
      "Call Marcus about the Supabase migration.",
    ] {
      XCTAssertEqual(redactor.redact(sentence), sentence, "over-redacted: \(sentence)")
    }
  }

  func testAPrivateKeyBlockIsRemovedEntirelyRatherThanJustItsHeader() {
    let block = """
      -----BEGIN RSA PRIVATE KEY-----
      MIIEowIBAAKCAQEAvx0Fake0Key0Material0For0Tests0Only
      -----END RSA PRIVATE KEY-----
      """
    let redacted = SecretRedactor().redact("here it is\n\(block)\ndone")
    XCTAssertFalse(redacted.contains("Fake0Key0Material"))
    XCTAssertFalse(redacted.contains("BEGIN RSA"))
  }

  func testContainsSecretAgreesWithRedact() {
    let redactor = SecretRedactor()
    XCTAssertTrue(redactor.containsSecret("token: abcdefghijklmnopqrstuvwx"))
    XCTAssertFalse(redactor.containsSecret("just some ordinary words"))
  }

  func testRedactionDoesNotHangOnLargeInput() {
    let redactor = SecretRedactor()
    let started = ContinuousClock.now
    _ = redactor.redact(String(repeating: "some ordinary words here ", count: 5_000))
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
  }
}

/// The caching layer exists to bound how often macOS can raise a password dialog, so
/// "how many times did it actually ask" is the thing worth asserting.
extension SecretStoreTests {

  /// Counts reads so the test can assert on them.
  private final class CountingStore: SecretStoring, @unchecked Sendable {
    private let inner = InMemorySecretStore()
    private let lock = NSLock()
    private var reads = 0
    var readCount: Int { lock.withLock { reads } }

    func read(_ key: SecretKey) throws -> String? {
      lock.withLock { reads += 1 }
      return try inner.read(key)
    }
    func write(_ value: String, for key: SecretKey) throws { try inner.write(value, for: key) }
    func delete(_ key: SecretKey) throws { try inner.delete(key) }
  }

  func testTheKeychainIsAskedOnlyOncePerSecret() throws {
    let counting = CountingStore()
    try counting.write("a-stored-key-value", for: .assemblyAI)
    let store = CachingSecretStore(counting)

    for _ in 0..<20 {
      XCTAssertEqual(try store.read(.assemblyAI), "a-stored-key-value")
    }
    XCTAssertEqual(counting.readCount, 1, "the Keychain was asked \(counting.readCount) times")
  }

  /// A missing secret must be cached too, or the app asks on every redraw for a key
  /// that is not there — which is exactly the case where the prompt is most confusing.
  func testAnAbsentSecretIsAlsoRememberedRatherThanAskedForRepeatedly() throws {
    let counting = CountingStore()
    let store = CachingSecretStore(counting)

    for _ in 0..<10 { XCTAssertNil(try store.read(.assemblyAI)) }
    XCTAssertEqual(counting.readCount, 1)
  }

  func testWritingAKeyMakesTheNextReadSeeIt() throws {
    let store = CachingSecretStore(InMemorySecretStore())
    XCTAssertNil(try store.read(.assemblyAI))
    try store.write("the-new-key-value", for: .assemblyAI)
    XCTAssertEqual(try store.read(.assemblyAI), "the-new-key-value")
  }

  func testDeletingAKeyMakesTheNextReadSeeItGone() throws {
    let store = CachingSecretStore(InMemorySecretStore(["assemblyAI": ""].isEmpty ? [:] : [:]))
    try store.write("something", for: .assemblyAI)
    XCTAssertNotNil(try store.read(.assemblyAI))
    try store.delete(.assemblyAI)
    XCTAssertNil(try store.read(.assemblyAI))
  }

  func testInvalidateForcesAFreshLook() throws {
    let counting = CountingStore()
    let store = CachingSecretStore(counting)
    _ = try store.read(.assemblyAI)
    store.invalidate()
    _ = try store.read(.assemblyAI)
    XCTAssertEqual(counting.readCount, 2)
  }

  func testEachSecretIsCachedSeparately() throws {
    let counting = CountingStore()
    try counting.write("one", for: .assemblyAI)
    try counting.write("two", for: .openAICompatible)
    let store = CachingSecretStore(counting)

    XCTAssertEqual(try store.read(.assemblyAI), "one")
    XCTAssertEqual(try store.read(.openAICompatible), "two")
    XCTAssertEqual(try store.read(.assemblyAI), "one")
    XCTAssertEqual(counting.readCount, 2)
  }
}
