#if canImport(CoreAudio)
import CoreAudio
import Foundation

/// One microphone the user could record from.
public struct AudioInputDevice: Identifiable, Equatable, Sendable {
  /// The stable CoreAudio UID. Survives reboots and re-plugging, unlike the numeric
  /// device ID, which is why this is what gets stored in preferences.
  public let uniqueID: String
  public let name: String

  public var id: String { uniqueID }

  public init(uniqueID: String, name: String) {
    self.uniqueID = uniqueID
    self.name = name
  }
}

/// Enumerates input devices through the CoreAudio HAL.
///
/// `AVCaptureDevice` would be shorter, but its device-type constants have been renamed
/// across the macOS versions Rant supports, and it describes capture devices rather
/// than the HAL devices `AVAudioEngine` is actually configured with. Going to the HAL
/// keeps enumeration and selection talking about the same objects: the UID listed here
/// is exactly what `MicrophoneCapture` sets on the input unit.
public enum AudioDevices {

  /// Every device with at least one input channel, in the order CoreAudio reports.
  public static func inputs() -> [AudioInputDevice] {
    deviceIDs().compactMap { id in
      guard hasInputChannels(id), let uid = uniqueID(of: id) else { return nil }
      return AudioInputDevice(uniqueID: uid, name: name(of: id) ?? uid)
    }
  }

  /// The HAL device for a stored UID, or nil when that microphone is not plugged in.
  public static func deviceID(forUniqueID uid: String) -> AudioDeviceID? {
    deviceIDs().first { uniqueID(of: $0) == uid }
  }

  public static func defaultInputDeviceID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return status == noErr && device != 0 ? device : nil
  }

  // MARK: - HAL plumbing

  private static func deviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
      size > 0
    else { return [] }

    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
    else { return [] }
    return ids
  }

  /// An output-only device has an input stream configuration with no channels, which
  /// is how a microphone list avoids listing your speakers.
  private static func hasInputChannels(_ device: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0
    else { return false }

    let buffer = UnsafeMutableRawPointer.allocate(
      byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { buffer.deallocate() }
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else {
      return false
    }
    let list = UnsafeMutableAudioBufferListPointer(
      buffer.assumingMemoryBound(to: AudioBufferList.self))
    return list.contains { $0.mNumberChannels > 0 }
  }

  private static func uniqueID(of device: AudioDeviceID) -> String? {
    string(device, selector: kAudioDevicePropertyDeviceUID)
  }

  private static func name(of device: AudioDeviceID) -> String? {
    string(device, selector: kAudioObjectPropertyName)
  }

  private static func string(_ device: AudioDeviceID, selector: AudioObjectPropertySelector)
    -> String?
  {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer in
      AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
    }
    guard status == noErr else { return nil }
    let string = value as String
    return string.isEmpty ? nil : string
  }
}
#endif
