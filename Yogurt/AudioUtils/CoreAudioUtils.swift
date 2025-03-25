import AudioToolbox
import Foundation

// MARK: - Custom Error

/// A simple struct for throwing Core Audio errors with a message.
struct CAError: Error, CustomStringConvertible {
  let message: String

  var description: String {
    "CAError: \(message)"
  }
}

// MARK: - Constants

extension AudioObjectID {
  /// Convenience for `kAudioObjectSystemObject`.
  static let system = AudioObjectID(kAudioObjectSystemObject)
  /// Convenience for `kAudioObjectUnknown`.
  static let unknown = kAudioObjectUnknown

  /// `true` if this object has the value of `kAudioObjectUnknown`.
  var isUnknown: Bool { self == .unknown }

  /// `false` if this object has the value of `kAudioObjectUnknown`.
  var isValid: Bool { !isUnknown }
}

// MARK: - Concrete Property Helpers

extension AudioObjectID {
  /// Reads the value for `kAudioHardwarePropertyDefaultSystemOutputDevice`.
  static func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
    try AudioDeviceID.system.readDefaultSystemOutputDevice()
  }

  /// Reads `kAudioHardwarePropertyProcessObjectList`.
  func readProcessList() throws -> [AudioObjectID] {
    try requireSystemObject()

    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0

    var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)

    guard err == noErr else {
      throw CAError(message: "Error reading data size for \(address): \(err)")
    }

    var value = [AudioObjectID](
      repeating: .unknown, count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)

    err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &value)

    guard err == noErr else { throw CAError(message: "Error reading array for \(address): \(err)") }

    return value
  }

  /// Reads the value for `kAudioHardwarePropertyDefaultSystemOutputDevice`, should only be called on the system object.
  func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
    try requireSystemObject()

    return try read(
      kAudioHardwarePropertyDefaultSystemOutputDevice, defaultValue: AudioDeviceID.unknown)
  }

  /// Reads the value for `kAudioDevicePropertyDeviceUID` for the device represented by this audio object ID.
  func readDeviceUID() throws -> String { try readString(kAudioDevicePropertyDeviceUID) }

  /// Reads the value for `kAudioTapPropertyFormat` for the device represented by this audio object ID.
  func readAudioTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
    try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
  }

  private func requireSystemObject() throws {
    if self != .system { throw CAError(message: "Only supported for the system object.") }
  }
}

// MARK: - Generic Property Access

extension AudioObjectID {
  func read<T>(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
    defaultValue: T
  ) throws -> T {
    try read(
      AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element),
      defaultValue: defaultValue)
  }

  func read<T>(_ address: AudioObjectPropertyAddress, defaultValue: T) throws -> T {
    try read(address, defaultValue: defaultValue, inQualifierSize: 0, inQualifierData: nil)
  }

  func readString(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
  ) throws -> String {
    try read(
      AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element),
      defaultValue: "" as CFString) as String
  }

  private func read<T>(
    _ inAddress: AudioObjectPropertyAddress, defaultValue: T, inQualifierSize: UInt32 = 0,
    inQualifierData: UnsafeRawPointer? = nil
  ) throws -> T {
    var address = inAddress

    var dataSize: UInt32 = 0

    var err = AudioObjectGetPropertyDataSize(
      self, &address, inQualifierSize, inQualifierData, &dataSize)

    guard err == noErr else {
      throw CAError(message: "Error reading data size for \(inAddress): \(err)")
    }

    var value: T = defaultValue
    err = withUnsafeMutablePointer(to: &value) { ptr in
      AudioObjectGetPropertyData(self, &address, inQualifierSize, inQualifierData, &dataSize, ptr)
    }

    guard err == noErr else {
      throw CAError(message: "Error reading data for \(inAddress): \(err)")
    }

    return value
  }
}
