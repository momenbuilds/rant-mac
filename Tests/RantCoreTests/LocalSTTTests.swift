import XCTest

@testable import RantCore

/// The local path carries a promise — "audio stays on this Mac" — and a promise is
/// only as good as the test that would fail if it stopped being true. These tests
/// hold the engine to it: no transport is reachable from the local provider, the
/// registry refuses a cloud provider under local-only rather than quietly using one,
/// and a missing model is an error rather than an upload.
final class LocalSTTTests: XCTestCase {

  // MARK: - Doubles

  /// Stands in for whisper.cpp. Records what it was handed so the audio-format
  /// conversion can be asserted on without a C library or a gigabyte of weights.
  actor FakeWhisperBackend: WhisperBackend {
    private(set) var preparedModels: [URL] = []
    private(set) var receivedSamples: [[Float]] = []
    private(set) var receivedLanguages: [String?] = []
    private var transcript: WhisperTranscript
    private var prepareError: Error?
    private var transcribeError: Error?

    init(
      transcript: WhisperTranscript = WhisperTranscript(text: "hello there", language: "en"),
      prepareError: Error? = nil,
      transcribeError: Error? = nil
    ) {
      self.transcript = transcript
      self.prepareError = prepareError
      self.transcribeError = transcribeError
    }

    func prepare(modelAt url: URL) async throws {
      preparedModels.append(url)
      if let prepareError { throw prepareError }
    }

    func transcribe(samples: [Float], languageCode: String?) async throws -> WhisperTranscript {
      receivedSamples.append(samples)
      receivedLanguages.append(languageCode)
      if let transcribeError { throw transcribeError }
      return transcript
    }

    var prepareCount: Int { preparedModels.count }
    var lastSamples: [Float] { receivedSamples.last ?? [] }
  }

  /// Fails the test if anything touches it. The strongest available statement of "no
  /// network request happened" is a transport that cannot be used quietly.
  final class ExplodingHTTPTransport: HTTPTransport, @unchecked Sendable {
    func send(_ request: URLRequest, body: Data?) async throws -> (Data, HTTPURLResponse) {
      XCTFail("local mode made a network request to \(request.url?.absoluteString ?? "?")")
      throw TranscriptionError.network("should never happen")
    }
  }

  final class ExplodingDownloader: ModelDownloading, @unchecked Sendable {
    func download(
      from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
      XCTFail("a download was started without the user asking for one: \(url)")
    }
  }

  /// Writes bytes the test supplies, reporting progress as it goes.
  final class FakeDownloader: ModelDownloading, @unchecked Sendable {
    private let payload: Data
    private let lock = NSLock()
    private var _requestedURLs: [URL] = []

    init(payload: Data) { self.payload = payload }

    var requestedURLs: [URL] { lock.withLock { _requestedURLs } }

    func download(
      from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
      lock.withLock { _requestedURLs.append(url) }
      progress(0)
      try payload.write(to: destination)
      progress(1)
    }
  }

  // MARK: - Helpers

  private let model = ModelCatalog.tinyEnglish

  private func audio(ms: Int = 500, sampleRate: Int = 16_000) -> AudioBuffer {
    AudioBuffer(pcm: Data(count: sampleRate / 1000 * ms * 2), sampleRate: sampleRate)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("rant-models-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  /// A file that passes verification: the right magic bytes, padded to the model's
  /// advertised size.
  private func plausibleWeights(for model: WhisperModel) -> Data {
    var data = Data("ggml".utf8)
    data.append(Data(count: Int(model.approximateFileSizeBytes) - 4))
    return data
  }

  private func provider(
    backend: any WhisperBackend, installed: Bool = true
  ) -> LocalWhisperProvider {
    let url = URL(fileURLWithPath: "/tmp/rant-test-weights.bin")
    return LocalWhisperProvider(model: model, backend: backend) { installed ? url : nil }
  }

  // MARK: - The privacy promise

  func testTheLocalProviderStatesThatAudioNeverLeavesTheMachine() {
    XCTAssertFalse(provider(backend: FakeWhisperBackend()).sendsAudioOffDevice)
  }

  func testTranscribingWithNoModelThrowsRatherThanFallingBackToTheCloud() async {
    let backend = FakeWhisperBackend()
    await XCTAssertThrowsErrorAsync(
      try await provider(backend: backend, installed: false)
        .transcribe(audio(), context: nil, options: .default)
    ) {
      XCTAssertEqual($0 as? TranscriptionError, .modelUnavailable(model.displayName))
      XCTAssertFalse(($0 as? TranscriptionError)?.isRetryable ?? true)
    }
    let prepared = await backend.prepareCount
    XCTAssertEqual(prepared, 0, "nothing should be loaded when there is no model")
  }

  /// The headline claim, tested end to end: dictate through the registry with a
  /// transport and a downloader that fail loudly if they are touched.
  func testALocalDictationMakesNoNetworkRequestAtAll() async throws {
    let transport = ExplodingHTTPTransport()
    let downloader = ExplodingDownloader()
    _ = ModelStore(directory: try temporaryDirectory(), downloader: downloader)

    let backend = FakeWhisperBackend(transcript: WhisperTranscript(text: "on device"))
    let local = provider(backend: backend)
    let cloud = AssemblyAIProvider(
      keyProvider: { "test-key-0123456789abcdef" },
      baseURL: URL(string: "https://dictation.example.invalid")!,
      transport: transport)

    let registry = ProviderRegistry(
      entries: [
        .local(local, isModelInstalled: { true }),
        .cloud(cloud, hasKey: { true }),
      ],
      localOnly: true)

    let chosen = try registry.resolve()
    XCTAssertFalse(chosen.sendsAudioOffDevice)
    await chosen.warmUp()
    let result = try await chosen.transcribe(audio(), context: nil, options: .default)
    XCTAssertEqual(result.raw, "on device")
    XCTAssertEqual(result.provider, "local-whisper")
  }

  func testCheckingTheLocalProviderTouchesNoNetworkAndReportsAMissingModel() async {
    await XCTAssertThrowsErrorAsync(
      try await provider(backend: FakeWhisperBackend(), installed: false).checkReachability()
    ) { XCTAssertEqual($0 as? TranscriptionError, .modelUnavailable(model.displayName)) }
  }

  // MARK: - Transcription

  func testTheTranscriptIsReturnedVerbatimWithNoProviderCleanup() async throws {
    let backend = FakeWhisperBackend(
      transcript: WhisperTranscript(text: "um so we should ship", language: "en"))
    let result = try await provider(backend: backend)
      .transcribe(audio(), context: nil, options: .default)
    XCTAssertEqual(result.raw, "um so we should ship")
    XCTAssertNil(result.cleaned, "local cleanup is the caller's job, not whisper's")
    XCTAssertEqual(result.best, "um so we should ship")
    XCTAssertEqual(result.language, "en")
    XCTAssertNotNil(result.latencyMilliseconds)
  }

  func testEmptyAudioIsRejectedBeforeTheModelIsLoaded() async {
    let backend = FakeWhisperBackend()
    await XCTAssertThrowsErrorAsync(
      try await provider(backend: backend)
        .transcribe(AudioBuffer(pcm: Data()), context: nil, options: .default)
    ) { XCTAssertEqual($0 as? TranscriptionError, .audioEmpty) }
    let prepared = await backend.prepareCount
    XCTAssertEqual(prepared, 0)
  }

  func testTheRequestedLanguageReachesTheBackend() async throws {
    let backend = FakeWhisperBackend()
    _ = try await provider(backend: backend).transcribe(
      audio(), context: nil, options: TranscriptionOptions(languageCode: "de"))
    let languages = await backend.receivedLanguages
    XCTAssertEqual(languages, ["de"])
  }

  func testCancellationIsReportedAsCancelledRatherThanAsAModelFailure() async {
    let backend = FakeWhisperBackend(transcribeError: CancellationError())
    await XCTAssertThrowsErrorAsync(
      try await provider(backend: backend).transcribe(audio(), context: nil, options: .default)
    ) { XCTAssertEqual($0 as? TranscriptionError, .cancelled) }
  }

  func testWarmUpLoadsTheModelSoTheFirstDictationDoesNotPayForIt() async {
    let backend = FakeWhisperBackend()
    await provider(backend: backend).warmUp()
    let prepared = await backend.prepareCount
    XCTAssertEqual(prepared, 1)
  }

  func testWarmUpIsSilentWhenThereIsNoModelToLoad() async {
    let backend = FakeWhisperBackend()
    await provider(backend: backend, installed: false).warmUp()
    let prepared = await backend.prepareCount
    XCTAssertEqual(prepared, 0)
  }

  // MARK: - Audio format

  func testSixteenBitSamplesBecomeNormalisedFloats() {
    // -32768, 0, 32767 little-endian.
    let pcm = Data([0x00, 0x80, 0x00, 0x00, 0xFF, 0x7F])
    let samples = LocalWhisperProvider.floatSamples(from: pcm)
    XCTAssertEqual(samples.count, 3)
    XCTAssertEqual(samples[0], -1, accuracy: 0.0001)
    XCTAssertEqual(samples[1], 0, accuracy: 0.0001)
    XCTAssertEqual(samples[2], 1, accuracy: 0.001)
  }

  func testATrailingOddByteIsDroppedRatherThanReadPast() {
    let samples = LocalWhisperProvider.floatSamples(from: Data([0x00, 0x00, 0x11]))
    XCTAssertEqual(samples.count, 1)
  }

  /// The failure this prevents is not a crash — it is a transcript of chipmunks,
  /// which is much harder to trace back to a sample rate.
  func testAudioIsResampledToSixteenKilohertzBeforeItReachesTheModel() async throws {
    let backend = FakeWhisperBackend()
    let oneSecondAt48k = audio(ms: 1_000, sampleRate: 48_000)
    _ = try await provider(backend: backend).transcribe(
      oneSecondAt48k, context: nil, options: .default)
    let samples = await backend.lastSamples
    XCTAssertLessThanOrEqual(
      abs(samples.count - 16_000), 2, "one second must arrive as 16k samples, got \(samples.count)")
  }

  func testSixteenKilohertzAudioIsHandedOverUntouched() {
    let buffer = AudioBuffer(pcm: Data([0x00, 0x40, 0x00, 0x40]), sampleRate: 16_000)
    let samples = LocalWhisperProvider.sixteenKilohertzMonoSamples(from: buffer)
    XCTAssertEqual(samples.count, 2)
  }

  // MARK: - Output tidying

  func testWhisperNonSpeechAnnotationsAreStrippedFromTheTranscript() {
    let strip = LocalWhisperProvider.strippingNonSpeechAnnotations
    XCTAssertEqual(strip("[BLANK_AUDIO]"), "")
    XCTAssertEqual(strip("(MUSIC) let us ship on Friday"), "let us ship on Friday")
    XCTAssertEqual(strip("hello [ Silence ] world"), "hello  world")
  }

  func testWordsInBracketsThatLookLikeSpeechAreKept() {
    let strip = LocalWhisperProvider.strippingNonSpeechAnnotations
    XCTAssertEqual(strip("the fee (about ten pounds) applies"), "the fee (about ten pounds) applies")
  }

  /// A pathological input used to hang this project when bracket handling was a
  /// regular expression. A scanner cannot backtrack, and this asserts it returns.
  func testDeeplyNestedBracketsDoNotHangTheStripper() {
    let pathological = String(repeating: "[", count: 5_000) + "hello"
    let output = LocalWhisperProvider.strippingNonSpeechAnnotations(pathological)
    XCTAssertTrue(output.contains("hello"), "an unterminated annotation must not eat the words")
  }

  // MARK: - The catalogue

  func testEveryOfferedModelStatesItsSizeMemorySpeedAndAccuracy() {
    for model in ModelCatalog.all {
      XCTAssertGreaterThan(model.approximateFileSizeBytes, 0, "\(model.id) has no size")
      XCTAssertGreaterThan(model.approximateMemoryBytes, 0, "\(model.id) has no memory figure")
      XCTAssertGreaterThan(model.realtimeFactorAppleSilicon, 0)
      XCTAssertGreaterThan(model.realtimeFactorIntel, 0)
      XCTAssertFalse(model.displayName.isEmpty)
      XCTAssertEqual(model.downloadURL.lastPathComponent, model.fileName)
    }
  }

  /// The temptation is to quote the Apple Silicon figure everywhere because it reads
  /// better. This machine is Intel; the catalogue has to say so.
  func testTheCatalogueIsHonestThatIntelIsSlowerThanAppleSilicon() {
    for model in ModelCatalog.all {
      XCTAssertGreaterThan(
        model.realtimeFactorIntel, model.realtimeFactorAppleSilicon,
        "\(model.id) claims Intel is at least as fast, which it is not")
    }
    let intel = MachineProfile(
      isAppleSilicon: false, physicalMemoryBytes: 16_000_000_000, coreCount: 8)
    XCTAssertTrue(ModelCatalog.medium.expectedSpeedDescription(on: intel).contains("Intel"))
  }

  func testAModelIsRefusedOnAMachineWithoutTheMemoryForIt() {
    let small = MachineProfile(
      isAppleSilicon: false, physicalMemoryBytes: 4_000_000_000, coreCount: 4)
    let verdict = ModelCatalog.suitability(of: ModelCatalog.medium, on: small)
    XCTAssertFalse(verdict.canRun)
    XCTAssertNotNil(verdict.warning)
  }

  func testASlowButUsableModelIsLabelledSlowRatherThanHidden() {
    let intel = MachineProfile(
      isAppleSilicon: false, physicalMemoryBytes: 32_000_000_000, coreCount: 8)
    let verdict = ModelCatalog.suitability(of: ModelCatalog.medium, on: intel)
    XCTAssertTrue(verdict.canRun)
    guard case .slow(let reason) = verdict else {
      return XCTFail("medium on Intel should be usable but slow, got \(verdict)")
    }
    XCTAssertTrue(reason.contains("Intel"))
  }

  func testTheRecommendationOnAnIntelMacIsNotAModelThatWillCrawl() {
    let intel = MachineProfile(
      isAppleSilicon: false, physicalMemoryBytes: 32_000_000_000, coreCount: 8)
    let recommended = ModelCatalog.recommended(for: intel)
    XCTAssertEqual(ModelCatalog.suitability(of: recommended, on: intel), .comfortable)
    XCTAssertLessThan(recommended.realtimeFactorIntel, ModelCatalog.slowRealtimeFactor)
  }

  func testAppleSiliconIsOfferedMoreThanIntelBecauseItCanActuallyRunIt() {
    let memory: Int64 = 32_000_000_000
    let apple = MachineProfile(isAppleSilicon: true, physicalMemoryBytes: memory, coreCount: 10)
    let intel = MachineProfile(isAppleSilicon: false, physicalMemoryBytes: memory, coreCount: 8)
    XCTAssertGreaterThanOrEqual(
      ModelCatalog.recommended(for: apple).accuracy,
      ModelCatalog.recommended(for: intel).accuracy)
  }

  // MARK: - Downloading

  func testTheDownloadPlanStatesSizeAndMemoryBeforeAnyBytesMove() async throws {
    let downloader = ExplodingDownloader()
    let store = ModelStore(directory: try temporaryDirectory(), downloader: downloader)
    let plan = store.plan(for: ModelCatalog.baseEnglish)

    XCTAssertEqual(plan.downloadSizeDescription, "142 MB")
    XCTAssertTrue(plan.memoryRequirementDescription.contains("RAM"))
    XCTAssertTrue(plan.summary.contains("142 MB"))
    XCTAssertTrue(plan.summary.contains("RAM"))
    XCTAssertEqual(plan.sourceURL.host, "huggingface.co", "the user is shown where bytes come from")
    // The exploding downloader would have failed the test had building the plan
    // started anything.
  }

  func testDownloadingWritesVerifiesAndInstallsTheModel() async throws {
    let directory = try temporaryDirectory()
    let downloader = FakeDownloader(payload: plausibleWeights(for: model))
    let store = ModelStore(directory: directory, downloader: downloader)

    let progressBox = ProgressBox()
    let url = try await store.download(store.plan(for: model)) { value in
      progressBox.record(value)
    }

    XCTAssertEqual(url.lastPathComponent, model.fileName)
    let installed = await store.isInstalled(model)
    XCTAssertTrue(installed)
    XCTAssertEqual(downloader.requestedURLs, [model.downloadURL])
    let seen = progressBox.values
    XCTAssertTrue(seen.contains(1), "the UI needs to be told the download finished")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertEqual(leftovers, [model.fileName], "no .partial file should survive a good download")
  }

  func testATruncatedDownloadIsRejectedAndNothingIsInstalled() async throws {
    let directory = try temporaryDirectory()
    var truncated = Data("ggml".utf8)
    truncated.append(Data(count: 1_000))
    let store = ModelStore(directory: directory, downloader: FakeDownloader(payload: truncated))

    await XCTAssertThrowsErrorAsync(try await store.download(store.plan(for: model))) {
      guard case ModelError.verificationFailed = $0 else {
        return XCTFail("expected a verification failure, got \($0)")
      }
    }
    let installed = await store.isInstalled(model)
    XCTAssertFalse(installed)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
  }

  /// A captive portal answers every request with an HTML login page. Saved under a
  /// `.bin` name it is a decoder crash later; caught here it is a sentence.
  func testAnHtmlErrorPageIsRejectedRatherThanInstalledAsAModel() async throws {
    let directory = try temporaryDirectory()
    var page = Data("<!doctype html><title>Sign in</title>".utf8)
    page.append(Data(count: Int(model.approximateFileSizeBytes) - page.count))
    let store = ModelStore(directory: directory, downloader: FakeDownloader(payload: page))

    await XCTAssertThrowsErrorAsync(try await store.download(store.plan(for: model))) {
      guard case ModelError.verificationFailed = $0 else {
        return XCTFail("expected a verification failure, got \($0)")
      }
    }
    let installed = await store.isInstalled(model)
    XCTAssertFalse(installed)
  }

  func testDownloadIsRefusedForAModelThisMachineCannotRun() async throws {
    let store = ModelStore(
      directory: try temporaryDirectory(), downloader: ExplodingDownloader())
    let tiny = MachineProfile(
      isAppleSilicon: false, physicalMemoryBytes: 4_000_000_000, coreCount: 4)
    let plan = store.plan(for: ModelCatalog.medium, profile: tiny)
    await XCTAssertThrowsErrorAsync(try await store.download(plan)) {
      guard case ModelError.tooLargeForThisMachine = $0 else {
        return XCTFail("expected a refusal, got \($0)")
      }
    }
  }

  func testDeletingAModelRemovesItFromDisk() async throws {
    let directory = try temporaryDirectory()
    let store = ModelStore(
      directory: directory, downloader: FakeDownloader(payload: plausibleWeights(for: model)))
    _ = try await store.download(store.plan(for: model))

    try await store.delete(model)
    let installed = await store.isInstalled(model)
    XCTAssertFalse(installed)
    await XCTAssertThrowsErrorAsync(try await store.delete(model)) {
      XCTAssertEqual($0 as? ModelError, .notInstalled(model.displayName))
    }
  }

  func testTheMagicBytesCheckAcceptsGgmlAndGgufAndNothingElse() {
    XCTAssertTrue(ModelStore.hasModelMagic(Data("ggml".utf8)))
    XCTAssertTrue(ModelStore.hasModelMagic(Data("GGUF".utf8)))
    XCTAssertFalse(ModelStore.hasModelMagic(Data("<!do".utf8)))
    XCTAssertFalse(ModelStore.hasModelMagic(Data()))
  }

  // MARK: - The registry

  private func registry(localOnly: Bool, modelInstalled: Bool = true) -> ProviderRegistry {
    let local = provider(backend: FakeWhisperBackend(), installed: modelInstalled)
    let cloud = AssemblyAIProvider(
      keyProvider: { "test-key-0123456789abcdef" },
      baseURL: URL(string: "https://dictation.example.invalid")!,
      transport: ExplodingHTTPTransport())
    return ProviderRegistry(
      entries: [
        .local(local, isModelInstalled: { modelInstalled }),
        .cloud(cloud, hasKey: { true }),
      ],
      localOnly: localOnly)
  }

  func testTheRegistryListsEachProviderWithItsPrivacyIndicatorAndStatus() {
    let descriptors = registry(localOnly: false).descriptors()
    XCTAssertEqual(descriptors.map(\.identifier), ["local-whisper", "assemblyai"])
    XCTAssertFalse(descriptors[0].sendsAudioOffDevice)
    XCTAssertTrue(descriptors[1].sendsAudioOffDevice)
    XCTAssertEqual(descriptors[0].privacyLabel, "Audio stays on this Mac")
    XCTAssertEqual(descriptors[1].privacyLabel, "Audio is sent to the provider")
    XCTAssertTrue(descriptors.allSatisfy(\.isConfigured))
    XCTAssertTrue(descriptors.allSatisfy(\.isSelectable))
  }

  func testTheRegistryRefusesACloudProviderInLocalOnlyModeRatherThanFallingBack() throws {
    let registry = registry(localOnly: true)
    XCTAssertThrowsError(try registry.provider(withIdentifier: "assemblyai")) {
      XCTAssertEqual(
        $0 as? TranscriptionError, .localOnlyViolation(provider: "AssemblyAI"))
    }
    let cloud = try XCTUnwrap(registry.descriptor(for: "assemblyai"))
    XCTAssertEqual(cloud.status, .blockedByLocalOnly)
    XCTAssertFalse(cloud.isSelectable)
    XCTAssertTrue(cloud.isConfigured, "it is set up; it is just not allowed")
  }

  /// The scenario the whole feature turns on: local-only is set and the model is
  /// missing. The only acceptable outcome is an error naming the model.
  func testAMissingLocalModelNeverCausesASilentFallbackToTheCloud() {
    let registry = registry(localOnly: true, modelInstalled: false)
    XCTAssertThrowsError(try registry.resolve()) {
      XCTAssertEqual($0 as? TranscriptionError, .modelUnavailable(model.displayName))
    }
    XCTAssertFalse(registry.hasUsableProvider)
  }

  func testAnExplicitChoiceIsHonouredOrRefusedButNeverSubstituted() throws {
    let registry = registry(localOnly: false, modelInstalled: false)
    XCTAssertThrowsError(try registry.provider(withIdentifier: "local-whisper")) {
      XCTAssertEqual($0 as? TranscriptionError, .modelUnavailable(model.displayName))
    }
    // The cloud provider is ready, but asking for local must not hand it back.
    XCTAssertEqual(try registry.provider(withIdentifier: "assemblyai").identifier, "assemblyai")
  }

  func testAnUnknownProviderIdentifierIsAnErrorRatherThanADefault() {
    XCTAssertThrowsError(try registry(localOnly: false).provider(withIdentifier: "nope"))
  }

  func testStatusFollowsTheModelBecomingAvailableWithoutRebuildingTheRegistry() throws {
    let installed = InstalledFlag()
    let local = provider(backend: FakeWhisperBackend())
    let registry = ProviderRegistry(
      entries: [.local(local, isModelInstalled: { installed.value })], localOnly: true)

    XCTAssertEqual(
      registry.descriptor(for: "local-whisper")?.status,
      .needsModelDownload(model.displayName))
    installed.value = true
    XCTAssertEqual(registry.descriptor(for: "local-whisper")?.status, .ready)
    XCTAssertEqual(try registry.resolve().identifier, "local-whisper")
  }

  func testAMissingKeyIsReportedAsAMissingKeyRatherThanAsAMissingModel() {
    let cloud = AssemblyAIProvider(
      keyProvider: { nil },
      baseURL: URL(string: "https://dictation.example.invalid")!,
      transport: ExplodingHTTPTransport())
    let registry = ProviderRegistry(entries: [.cloud(cloud, hasKey: { false })])
    XCTAssertThrowsError(try registry.resolve()) {
      XCTAssertEqual($0 as? TranscriptionError, .apiKeyMissing)
    }
  }
}

// MARK: - Small mutable helpers

/// A flag a `@Sendable` closure can read, so a test can change the world between two
/// reads of the same registry.
final class InstalledFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = false
  var value: Bool {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

/// Collects progress values from inside the callback, synchronously.
///
/// It used to be an actor, which forced the callback to do `Task { await record(...) }`
/// — an unawaited task that had not necessarily run by the time the test read the
/// values back. That made "was the UI told the download finished?" a race, and it
/// failed on a loaded CI runner while passing on a developer machine. Worse, the
/// failure was invisible: `check.sh` reported PASS whenever a run had both a skip and
/// a failure, so this had been red on CI without anyone being told.
///
/// A lock rather than an actor, so recording happens *in* the callback and the value
/// is there the moment the download returns.
final class ProgressBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Double] = []
  func record(_ value: Double) { lock.withLock { storage.append(value) } }
  var values: [Double] { lock.withLock { storage } }
}
