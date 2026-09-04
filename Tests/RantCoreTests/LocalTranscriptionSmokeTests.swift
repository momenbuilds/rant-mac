import XCTest

@testable import RantCore

/// A real transcription through the real macOS recogniser — no fakes anywhere.
///
/// Opt-in, because it needs the Speech Recognition TCC grant and a moment of CPU, and
/// a test that prompts for a permission is a test that hangs a CI runner. Run it with:
///
/// ```
/// bash scripts/local-speech-smoke.sh
/// ```
///
/// It exists because `AppleSpeechTests` proves the provider's *rules* against a fake,
/// and a fake cannot tell you whether this Mac can actually turn speech into text
/// offline. Both halves are needed: the rules, and the fact.
final class LocalTranscriptionSmokeTests: XCTestCase {

  func testTheOnDeviceRecogniserTranscribesRealSpeech() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["RANT_LOCAL_SMOKE"] == "1",
      let path = environment["RANT_LOCAL_SMOKE_WAV"]
    else {
      throw XCTSkip(
        "opt-in — needs the Speech Recognition grant. Run scripts/local-speech-smoke.sh")
    }

    let pcm = try Self.pcmBody(ofWAVAt: URL(fileURLWithPath: path))
    XCTAssertGreaterThan(pcm.count, 1000, "the fixture should contain real audio")

    let provider = AppleSpeechProvider(recogniser: SystemOnDeviceRecogniser())
    let result = try await provider.transcribe(
      AudioBuffer(pcm: pcm, sampleRate: 16_000),
      context: nil,
      options: TranscriptionOptions(languageCode: "en-US"))

    let heard = result.raw.lowercased()
    print("on-device transcript: \(result.raw)")
    XCTAssertFalse(heard.isEmpty, "the recogniser returned nothing")
    // The fixture says "the quick brown fox jumps over the lazy dog". Assert on a
    // couple of distinctive words rather than the whole sentence: this is a check that
    // speech became text on this machine, not a word error rate benchmark.
    XCTAssertTrue(
      heard.contains("quick") || heard.contains("brown") || heard.contains("fox"),
      "expected the pangram, heard: \(result.raw)")
    XCTAssertEqual(result.provider, "apple-on-device")
  }

  /// Strips a canonical WAV header by walking the chunk list to `data`.
  ///
  /// Not assuming a fixed 44-byte offset: `afconvert` writes a `FLLR` padding chunk
  /// before the data on some inputs, and slicing at 44 would feed the recogniser a
  /// block of silence and fail for a reason that has nothing to do with speech.
  static func pcmBody(ofWAVAt url: URL) throws -> Data {
    let bytes = try Data(contentsOf: url)
    guard bytes.count > 12,
      bytes[0..<4].elementsEqual(Array("RIFF".utf8)),
      bytes[8..<12].elementsEqual(Array("WAVE".utf8))
    else { throw CocoaError(.fileReadCorruptFile) }

    var cursor = 12
    while cursor + 8 <= bytes.count {
      let identifier = bytes[cursor..<(cursor + 4)]
      let size = bytes.withUnsafeBytes { raw -> Int in
        Int(raw.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self).littleEndian)
      }
      let body = cursor + 8
      if identifier.elementsEqual(Array("data".utf8)) {
        return Data(bytes[body..<min(body + size, bytes.count)])
      }
      // Chunks are word aligned.
      cursor = body + size + (size % 2)
    }
    throw CocoaError(.fileReadCorruptFile)
  }
}
