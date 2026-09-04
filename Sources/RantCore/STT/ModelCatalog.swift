import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// How good a model's transcripts are, relative to the others on offer.
public enum ModelAccuracy: Int, Comparable, Sendable, Codable, CaseIterable {
  case basic
  case fair
  case good
  case best

  public static func < (lhs: ModelAccuracy, rhs: ModelAccuracy) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public var displayName: String {
    switch self {
    case .basic: "Basic"
    case .fair: "Fair"
    case .good: "Good"
    case .best: "Best"
    }
  }
}

/// One downloadable whisper.cpp model.
///
/// Every field here exists because the user is being asked to spend a gigabyte of
/// disk and several minutes of download, and none of it should be a surprise
/// afterwards. Sizes and memory figures come from the whisper.cpp project's own
/// table; the speed figures are rough and are labelled as such wherever they are
/// shown, because promising "real time" on a machine that will not deliver it is the
/// specific dishonesty this type is here to prevent.
public struct WhisperModel: Equatable, Sendable, Codable, Identifiable {
  public let id: String
  public let displayName: String
  /// File name on disk, which is also the file name at the download URL.
  public let fileName: String
  public let downloadURL: URL
  /// Roughly what the download costs. Approximate on purpose: the published files
  /// change by a few kilobytes between rebuilds, and an exact figure would turn a
  /// harmless upstream rebuild into a failed verification.
  public let approximateFileSizeBytes: Int64
  /// Resident memory while transcribing, on top of Rant itself.
  public let approximateMemoryBytes: Int64
  public let accuracy: ModelAccuracy
  /// Decode time as a multiple of the recording's own length on Apple Silicon.
  /// 0.1 means ten seconds of speech takes about one second.
  public let realtimeFactorAppleSilicon: Double
  /// The same figure for an Intel CPU, which is where the honesty matters: these are
  /// several times larger, and the UI shows this number rather than the flattering one.
  public let realtimeFactorIntel: Double
  public let isEnglishOnly: Bool

  public init(
    id: String,
    displayName: String,
    fileName: String,
    downloadURL: URL,
    approximateFileSizeBytes: Int64,
    approximateMemoryBytes: Int64,
    accuracy: ModelAccuracy,
    realtimeFactorAppleSilicon: Double,
    realtimeFactorIntel: Double,
    isEnglishOnly: Bool
  ) {
    self.id = id
    self.displayName = displayName
    self.fileName = fileName
    self.downloadURL = downloadURL
    self.approximateFileSizeBytes = approximateFileSizeBytes
    self.approximateMemoryBytes = approximateMemoryBytes
    self.accuracy = accuracy
    self.realtimeFactorAppleSilicon = realtimeFactorAppleSilicon
    self.realtimeFactorIntel = realtimeFactorIntel
    self.isEnglishOnly = isEnglishOnly
  }

  public func realtimeFactor(on profile: MachineProfile) -> Double {
    profile.isAppleSilicon ? realtimeFactorAppleSilicon : realtimeFactorIntel
  }

  /// What the user should expect after they stop speaking, in their own terms.
  public func expectedSpeedDescription(on profile: MachineProfile) -> String {
    let factor = realtimeFactor(on: profile)
    let tenSeconds = factor * 10
    let wait = tenSeconds < 1.5
      ? "under two seconds"
      : "about \(Int(tenSeconds.rounded())) seconds"
    let chip = profile.isAppleSilicon ? "Apple Silicon" : "this Intel CPU"
    return "Roughly \(wait) of processing for ten seconds of speech on \(chip)."
  }
}

/// Whether this machine can realistically run a model, and if not, why not.
public enum ModelSuitability: Equatable, Sendable {
  /// Enough memory and quick enough to dictate with.
  case comfortable
  /// It will run and the transcripts will be right; you will wait for them.
  case slow(String)
  /// Not enough RAM. Running it anyway means swapping, which is slower than the next
  /// model down by a wide margin, so we call it unavailable rather than let the user
  /// discover it.
  case tooLargeForThisMachine(String)

  public var canRun: Bool {
    if case .tooLargeForThisMachine = self { return false }
    return true
  }

  public var warning: String? {
    switch self {
    case .comfortable: nil
    case .slow(let text), .tooLargeForThisMachine(let text): text
    }
  }
}

/// What this Mac is, for the purposes of choosing a model.
///
/// Architecture is detected at runtime rather than with `#if arch(arm64)` because an
/// x86_64 build running under Rosetta on an M-series Mac would otherwise report
/// itself as Intel and talk the user out of the model their machine handles best.
public struct MachineProfile: Equatable, Sendable {
  public var isAppleSilicon: Bool
  public var physicalMemoryBytes: Int64
  public var coreCount: Int

  public init(isAppleSilicon: Bool, physicalMemoryBytes: Int64, coreCount: Int) {
    self.isAppleSilicon = isAppleSilicon
    self.physicalMemoryBytes = physicalMemoryBytes
    self.coreCount = coreCount
  }

  public static var current: MachineProfile {
    MachineProfile(
      isAppleSilicon: detectAppleSilicon(),
      physicalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory),
      coreCount: ProcessInfo.processInfo.processorCount)
  }

  static func detectAppleSilicon() -> Bool {
    #if arch(arm64)
      return true
    #elseif canImport(Darwin)
      // A native x86_64 process on an Intel Mac reports 0; the same binary translated
      // by Rosetta on an M-series Mac reports 1.
      var translated: Int32 = 0
      var size = MemoryLayout<Int32>.size
      let status = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0)
      return status == 0 && translated == 1
    #else
      return false
    #endif
  }
}

/// The models Rant offers, and the machine-aware advice that goes with them.
public enum ModelCatalog {
  /// Weights come from the whisper.cpp author's own Hugging Face repository — the
  /// same files whisper.cpp's `download-ggml-model.sh` fetches. Documented in
  /// `docs/NETWORK_BEHAVIOR.md`; the download happens only on an explicit press, and
  /// the URL is shown before it starts.
  public static let weightsBaseURL = URL(
    string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/")!

  private static func model(
    id: String,
    displayName: String,
    file: String,
    sizeMB: Int64,
    memoryMB: Int64,
    accuracy: ModelAccuracy,
    apple: Double,
    intel: Double,
    englishOnly: Bool
  ) -> WhisperModel {
    WhisperModel(
      id: id,
      displayName: displayName,
      fileName: file,
      downloadURL: weightsBaseURL.appendingPathComponent(file),
      approximateFileSizeBytes: sizeMB * 1_000_000,
      approximateMemoryBytes: memoryMB * 1_000_000,
      accuracy: accuracy,
      realtimeFactorAppleSilicon: apple,
      realtimeFactorIntel: intel,
      isEnglishOnly: englishOnly)
  }

  public static let tinyEnglish = model(
    id: "tiny.en", displayName: "Tiny (English)", file: "ggml-tiny.en.bin",
    sizeMB: 75, memoryMB: 273, accuracy: .basic, apple: 0.04, intel: 0.15, englishOnly: true)

  public static let baseEnglish = model(
    id: "base.en", displayName: "Base (English)", file: "ggml-base.en.bin",
    sizeMB: 142, memoryMB: 388, accuracy: .fair, apple: 0.07, intel: 0.30, englishOnly: true)

  public static let base = model(
    id: "base", displayName: "Base (multilingual)", file: "ggml-base.bin",
    sizeMB: 142, memoryMB: 388, accuracy: .fair, apple: 0.08, intel: 0.35, englishOnly: false)

  public static let smallEnglish = model(
    id: "small.en", displayName: "Small (English)", file: "ggml-small.en.bin",
    sizeMB: 466, memoryMB: 852, accuracy: .good, apple: 0.18, intel: 0.90, englishOnly: true)

  public static let small = model(
    id: "small", displayName: "Small (multilingual)", file: "ggml-small.bin",
    sizeMB: 466, memoryMB: 852, accuracy: .good, apple: 0.20, intel: 1.00, englishOnly: false)

  public static let medium = model(
    id: "medium", displayName: "Medium (multilingual)", file: "ggml-medium.bin",
    sizeMB: 1_500, memoryMB: 2_100, accuracy: .best, apple: 0.50, intel: 2.60, englishOnly: false)

  public static let largeTurbo = model(
    id: "large-v3-turbo", displayName: "Large v3 Turbo", file: "ggml-large-v3-turbo.bin",
    sizeMB: 1_620, memoryMB: 1_620, accuracy: .best, apple: 0.30, intel: 1.60, englishOnly: false)

  /// Smallest first, so the list reads as a ramp the user walks up until the wait
  /// stops being worth it.
  public static let all: [WhisperModel] = [
    tinyEnglish, baseEnglish, base, smallEnglish, small, largeTurbo, medium,
  ]

  public static func model(withID id: String) -> WhisperModel? {
    all.first { $0.id == id }
  }

  /// Rant needs to leave room for the operating system, the browser the user is
  /// dictating into, and everything else already resident. Two gigabytes of headroom
  /// on top of the model's own footprint is the line below which decoding starts to
  /// swap.
  public static let memoryHeadroomBytes: Int64 = 2_000_000_000

  /// A decode that takes longer than the recording itself changes the interaction:
  /// you stop dictating and start waiting. That is the threshold for calling a model
  /// slow rather than comfortable.
  public static let slowRealtimeFactor = 1.0

  public static func suitability(
    of model: WhisperModel, on profile: MachineProfile = .current
  ) -> ModelSuitability {
    let needed = model.approximateMemoryBytes + memoryHeadroomBytes
    if profile.physicalMemoryBytes < needed {
      return .tooLargeForThisMachine(
        "Needs about \(byteDescription(model.approximateMemoryBytes)) of RAM while "
          + "transcribing, and this Mac has \(byteDescription(profile.physicalMemoryBytes)) in "
          + "total. Choose a smaller model.")
    }
    let factor = model.realtimeFactor(on: profile)
    if factor >= slowRealtimeFactor {
      return .slow(
        "On \(profile.isAppleSilicon ? "this Mac" : "this Intel CPU") it takes about "
          + "\(String(format: "%.1f", factor))× the length of the recording, so a "
          + "thirty-second thought is roughly \(Int((factor * 30).rounded())) seconds of "
          + "waiting. Accurate, but not conversational.")
    }
    return .comfortable
  }

  /// The best model this machine will not struggle with. On an Intel Mac this lands
  /// on Base rather than Small, which is the honest answer even though Small would
  /// read better in a feature comparison.
  public static func recommended(for profile: MachineProfile = .current) -> WhisperModel {
    let usable = all.filter { suitability(of: $0, on: profile) == .comfortable }
    guard !usable.isEmpty else { return tinyEnglish }
    return usable.max { lhs, rhs in
      if lhs.accuracy != rhs.accuracy { return lhs.accuracy < rhs.accuracy }
      return lhs.realtimeFactor(on: profile) > rhs.realtimeFactor(on: profile)
    } ?? tinyEnglish
  }

  /// Human sizes in the units a download dialogue uses — decimal MB and GB, matching
  /// what Finder and the browser will show for the same file.
  public static func byteDescription(_ bytes: Int64) -> String {
    if bytes >= 1_000_000_000 {
      return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
    return "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
  }
}

// MARK: - What the user is told before anything is downloaded

/// Everything the user must see *before* a download begins: how big it is, how much
/// memory it will want, how fast it will be on their machine, and where the bytes
/// come from.
///
/// `ModelStore.download` takes one of these rather than a bare model, so the numbers
/// cannot be skipped by a caller in a hurry — building the plan is the only way to
/// start a download, and building it is what produces the text to show.
public struct DownloadPlan: Equatable, Sendable {
  public let model: WhisperModel
  public let downloadSizeDescription: String
  public let memoryRequirementDescription: String
  public let expectedSpeedDescription: String
  public let suitability: ModelSuitability

  public var sourceURL: URL { model.downloadURL }

  public init(model: WhisperModel, profile: MachineProfile = .current) {
    self.model = model
    self.downloadSizeDescription = ModelCatalog.byteDescription(model.approximateFileSizeBytes)
    self.memoryRequirementDescription =
      "\(ModelCatalog.byteDescription(model.approximateMemoryBytes)) of RAM while transcribing"
    self.expectedSpeedDescription = model.expectedSpeedDescription(on: profile)
    self.suitability = ModelCatalog.suitability(of: model, on: profile)
  }

  /// One paragraph for the confirmation sheet.
  public var summary: String {
    var text = "\(model.displayName) — \(downloadSizeDescription) download, "
      + "\(memoryRequirementDescription). \(expectedSpeedDescription)"
    if let warning = suitability.warning { text += " \(warning)" }
    return text
  }
}

// MARK: - Download, verify, delete

public enum ModelError: Error, Equatable, LocalizedError {
  case downloadFailed(String)
  case verificationFailed(String)
  case notInstalled(String)
  case tooLargeForThisMachine(String)

  public var errorDescription: String? {
    switch self {
    case .downloadFailed(let detail): "The model download failed. \(detail)"
    case .verificationFailed(let detail): "The downloaded model looks wrong. \(detail)"
    case .notInstalled(let name): "\(name) is not downloaded."
    case .tooLargeForThisMachine(let detail): detail
    }
  }
}

/// Fetching bytes to a file, with progress. A protocol so the store's logic —
/// verification, cleanup of a half-written file, refusing a model this machine cannot
/// run — is testable without a network.
public protocol ModelDownloading: Sendable {
  func download(
    from url: URL,
    to destination: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws
}

/// Streams the body to disk rather than buffering it, because a 1.5 GB model held in
/// memory while it downloads is a memory spike on exactly the machines least able to
/// absorb one.
public struct URLSessionModelDownloader: ModelDownloading {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func download(
    from url: URL,
    to destination: URL,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    let (bytes, response) = try await session.bytes(from: url)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw ModelError.downloadFailed("The server answered \(http.statusCode).")
    }
    let expected = response.expectedContentLength

    FileManager.default.createFile(atPath: destination.path, contents: nil)
    guard let handle = try? FileHandle(forWritingTo: destination) else {
      throw ModelError.downloadFailed("Could not write to \(destination.lastPathComponent).")
    }
    defer { try? handle.close() }

    var buffer = Data()
    buffer.reserveCapacity(1 << 20)
    var written: Int64 = 0
    for try await byte in bytes {
      buffer.append(byte)
      if buffer.count >= 1 << 20 {
        try handle.write(contentsOf: buffer)
        written += Int64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
        if expected > 0 { progress(min(1, Double(written) / Double(expected))) }
      }
    }
    if !buffer.isEmpty {
      try handle.write(contentsOf: buffer)
      written += Int64(buffer.count)
    }
    progress(1)
  }
}

/// The downloaded models on this machine.
///
/// An actor because downloads, deletions and "is it installed?" all touch the same
/// directory, and a delete racing a download is how you end up with a half-file that
/// loads as a model and crashes the decoder.
public actor ModelStore {
  public nonisolated let directory: URL
  private let downloader: any ModelDownloading
  private let fileManager: FileManager
  private let profile: MachineProfile
  private let log = RantLog("Models")

  public init(
    directory: URL,
    downloader: any ModelDownloading = URLSessionModelDownloader(),
    profile: MachineProfile = .current,
    fileManager: FileManager = .default
  ) {
    self.directory = directory
    self.downloader = downloader
    self.profile = profile
    self.fileManager = fileManager
  }

  /// The default location: inside the app's own Application Support directory, so an
  /// uninstall takes the weights with it and no privileged location is touched.
  public static func defaultDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appendingPathComponent("dev.rant.mac/Models", isDirectory: true)
  }

  public nonisolated func url(for model: WhisperModel) -> URL {
    directory.appendingPathComponent(model.fileName)
  }

  public func isInstalled(_ model: WhisperModel) -> Bool {
    installedURL(for: model) != nil
  }

  /// Present *and* plausible. A file that exists but failed verification is worse
  /// than no file, because it turns into a decoder crash rather than a prompt to
  /// download.
  public func installedURL(for model: WhisperModel) -> URL? {
    let candidate = url(for: model)
    guard fileManager.fileExists(atPath: candidate.path) else { return nil }
    guard (try? Self.verify(fileAt: candidate, against: model, fileManager: fileManager)) != nil
    else { return nil }
    return candidate
  }

  public func installedModels() -> [WhisperModel] {
    ModelCatalog.all.filter { isInstalled($0) }
  }

  /// The confirmation the UI shows. Cheap, touches nothing, and is the only way to
  /// obtain the token `download` requires.
  public nonisolated func plan(for model: WhisperModel, profile: MachineProfile = .current)
    -> DownloadPlan
  {
    DownloadPlan(model: model, profile: profile)
  }

  /// Fetches the weights. Takes a plan rather than a model so that the size and
  /// memory figures have provably been produced before a single byte moves.
  @discardableResult
  public func download(
    _ plan: DownloadPlan,
    onProgress: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws -> URL {
    let model = plan.model
    if case .tooLargeForThisMachine(let reason) = plan.suitability {
      throw ModelError.tooLargeForThisMachine(reason)
    }
    if let existing = installedURL(for: model) { return existing }

    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = url(for: model)
    // Download beside the final name and move into place, so an interrupted download
    // never looks installed.
    let partial = destination.appendingPathExtension("partial")
    try? fileManager.removeItem(at: partial)

    log.info("downloading model \(model.id) (\(plan.downloadSizeDescription))")
    do {
      try await downloader.download(from: model.downloadURL, to: partial, progress: onProgress)
    } catch {
      try? fileManager.removeItem(at: partial)
      if error is CancellationError { throw TranscriptionError.cancelled }
      if let modelError = error as? ModelError { throw modelError }
      throw ModelError.downloadFailed(error.localizedDescription)
    }

    do {
      try Self.verify(fileAt: partial, against: model, fileManager: fileManager)
    } catch {
      try? fileManager.removeItem(at: partial)
      throw error
    }

    try? fileManager.removeItem(at: destination)
    try fileManager.moveItem(at: partial, to: destination)
    log.info("model \(model.id) installed")
    return destination
  }

  public func delete(_ model: WhisperModel) throws {
    let target = url(for: model)
    guard fileManager.fileExists(atPath: target.path) else {
      throw ModelError.notInstalled(model.displayName)
    }
    try fileManager.removeItem(at: target)
    log.info("model \(model.id) deleted")
  }

  // MARK: - Verification

  /// Two cheap checks that between them catch every download failure seen in the
  /// wild: the magic bytes catch a captive portal's HTML login page saved under a
  /// `.bin` name, and the size band catches a truncated transfer. There is no
  /// checksum here because publishing a digest we had not actually computed against
  /// the served file would be theatre — the magic and the length are things we can
  /// genuinely assert.
  static let sizeTolerance = 0.10

  static func verify(
    fileAt url: URL, against model: WhisperModel, fileManager: FileManager = .default
  ) throws {
    let attributes = try? fileManager.attributesOfItem(atPath: url.path)
    let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    let expected = model.approximateFileSizeBytes
    let lower = Int64(Double(expected) * (1 - sizeTolerance))
    let upper = Int64(Double(expected) * (1 + sizeTolerance))
    guard size >= lower, size <= upper else {
      throw ModelError.verificationFailed(
        "Expected about \(ModelCatalog.byteDescription(expected)) but got "
          + "\(ModelCatalog.byteDescription(size)). The download was probably interrupted.")
    }
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      throw ModelError.verificationFailed("The file could not be read.")
    }
    defer { try? handle.close() }
    let head = (try? handle.read(upToCount: 4)) ?? Data()
    guard hasModelMagic(head) else {
      throw ModelError.verificationFailed(
        "The file does not start like a GGML model — the server may have sent an error page.")
    }
  }

  /// whisper.cpp weights begin with `ggml` (the original format) or `GGUF`.
  static func hasModelMagic(_ head: Data) -> Bool {
    head == Data("ggml".utf8) || head == Data("GGUF".utf8)
  }
}
