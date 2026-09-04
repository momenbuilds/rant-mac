import XCTest

@testable import RantCore

/// Microphone enumeration, against the machine actually running the tests.
///
/// These assert shape rather than a particular device: a CI runner and a laptop have
/// different hardware, and a test that expects "MacBook Pro Microphone" fails for a
/// reason that has nothing to do with the code. What must hold everywhere is that a
/// device we list can be looked up again by the identifier we stored — because that
/// round trip is the whole mechanism behind the microphone picker.
final class AudioDeviceTests: XCTestCase {

  func testEveryListedDeviceHasAUsableIdentityAndName() {
    for device in AudioDevices.inputs() {
      XCTAssertFalse(device.uniqueID.isEmpty, "a device with no UID cannot be stored")
      XCTAssertFalse(device.name.isEmpty, "a device with no name cannot be shown")
      XCTAssertEqual(device.id, device.uniqueID)
    }
  }

  /// The round trip the picker depends on: store a UID, find the device again later.
  func testAListedDeviceCanBeFoundAgainByItsStoredIdentifier() throws {
    let devices = AudioDevices.inputs()
    try XCTSkipIf(devices.isEmpty, "no input devices on this machine")
    for device in devices {
      XCTAssertNotNil(
        AudioDevices.deviceID(forUniqueID: device.uniqueID),
        "\(device.name) was listed but could not be resolved back")
    }
  }

  func testAnUnknownIdentifierResolvesToNothingRatherThanADefault() {
    // Selecting a microphone that has been unplugged must not silently record from a
    // different one; `MicrophoneCapture` falls back to the system default explicitly.
    XCTAssertNil(AudioDevices.deviceID(forUniqueID: "not-a-real-device-uid"))
  }

  func testIdentifiersAreUnique() {
    let ids = AudioDevices.inputs().map(\.uniqueID)
    XCTAssertEqual(ids.count, Set(ids).count, "two devices shared a UID")
  }

  func testTheSystemDefaultInputIsAnInputWeAlsoList() throws {
    let devices = AudioDevices.inputs()
    try XCTSkipIf(devices.isEmpty, "no input devices on this machine")
    let fallback = try XCTUnwrap(
      AudioDevices.defaultInputDeviceID(), "a Mac with inputs should have a default")
    let known = devices.compactMap { AudioDevices.deviceID(forUniqueID: $0.uniqueID) }
    XCTAssertTrue(
      known.contains(fallback),
      "the default input device should appear in the list the picker offers")
  }
}
