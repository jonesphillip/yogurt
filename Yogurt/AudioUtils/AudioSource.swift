import AVFoundation
import CoreAudio
import Foundation
import OSLog
import SwiftUI

enum AudioSourceType {
  case process
  case inputDevice
}

struct AudioSource: Identifiable, Equatable {
  let id: String
  let name: String
  let type: AudioSourceType
  let bundleURL: URL?
  let objectID: AudioObjectID
  var isSupported: Bool = true
  let bundleIdentifier: String?

  static func == (lhs: AudioSource, rhs: AudioSource) -> Bool {
    lhs.id == rhs.id && lhs.type == rhs.type
  }

  static let allApplications = AudioSource(
    id: "system-audio",
    name: "All Applications",
    type: .process,
    bundleURL: nil,
    objectID: AudioObjectID.unknown,
    isSupported: true,
    bundleIdentifier: nil
  )

  // Helper to create from AudioProcess
  static func from(process: AudioProcess) -> AudioSource {
    let bundleID = Bundle(url: process.bundleURL ?? URL(fileURLWithPath: ""))?.bundleIdentifier
    let isSupported = !(bundleID?.contains("com.google.Chrome") ?? false)

    let objectID: AudioObjectID
    switch process.sourceType {
    case .process(let id):
      objectID = id
    case .systemWide:
      objectID = AudioObjectID.unknown
    }

    return AudioSource(
      id: String(process.id),
      name: process.name,
      type: .process,
      bundleURL: process.bundleURL,
      objectID: objectID,
      isSupported: isSupported,
      bundleIdentifier: bundleID
    )
  }

  // Helper to create from audio input device
  static func from(deviceID: AudioDeviceID) throws -> AudioSource? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceNameCFString,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var deviceName: CFString?
    var dataSize = UInt32(MemoryLayout<CFString>.size)
    var err = withUnsafeMutablePointer(to: &deviceName) { ptr in
      AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, ptr)
    }
    guard let deviceName = deviceName else { return nil }
    guard err == noErr else { return nil }

    // Get device UID
    address.mSelector = kAudioDevicePropertyDeviceUID
    var deviceUID: CFString?
    dataSize = UInt32(MemoryLayout<CFString>.size)
    err = withUnsafeMutablePointer(to: &deviceUID) { ptr in
      AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, ptr)
    }
    guard let deviceUID = deviceUID else { return nil }
    guard err == noErr else { return nil }

    // Check if it's an input device
    address.mSelector = kAudioDevicePropertyStreamConfiguration
    address.mScope = kAudioDevicePropertyScopeInput

    var propSize: UInt32 = 0
    err = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propSize)
    guard err == noErr else { return nil }

    let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propSize))
    defer { bufferList.deallocate() }

    err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propSize, bufferList)
    guard err == noErr else { return nil }

    // Only create source if device has input channels
    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    let inputChannels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    guard inputChannels > 0 else { return nil }

    return AudioSource(
      id: String(deviceUID as String),
      name: deviceName as String,
      type: .inputDevice,
      bundleURL: nil,
      objectID: deviceID,
      bundleIdentifier: nil  // Input devices don't have bundle IDs
    )
  }
}

struct AudioSelections {
  var selectedProcess: AudioSource?
  var selectedInput: AudioSource?

  static var defaultSelections: AudioSelections {
    AudioSelections(selectedProcess: nil)  // nil process means default browser
  }
}

@Observable
class AudioSourceManager {
  private let logger = Logger(subsystem: kAppSubsystem, category: "AudioSourceManager")
  private let dbManager = DatabaseManager.shared

  private(set) var availableProcesses: [AudioSource] = []
  private(set) var availableInputDevices: [AudioSource] = []
  private(set) var selections = AudioSelections.defaultSelections

  func setSelection(source: AudioSource?) {
    switch source?.type {
    case .process:
      selections.selectedProcess = source
      // Persist process selection using bundle ID
      do {
        logger.debug(
          "Saving process selection - bundleID: \(source?.bundleIdentifier ?? "nil"), name: \(source?.name ?? "nil")"
        )
        try dbManager.saveSelectedAudioProcess(source)
      } catch {
        logger.error("Failed to save process selection: \(error.localizedDescription)")
      }

    case .inputDevice:
      selections.selectedInput = source
      do {
        try dbManager.saveSelectedInputDevice(source?.id)
      } catch {
        logger.error("Failed to save input device selection: \(error.localizedDescription)")
      }

    case nil:
      // Selecting nil means default browser
      selections.selectedProcess = nil
      do {
        try dbManager.saveSelectedAudioProcess(nil)
      } catch {
        logger.error("Failed to save process selection: \(error.localizedDescription)")
      }
    }
  }

  func loadAvailableSources() {
    loadProcesses()
    loadInputDevices()

    if let savedInputId = dbManager.getSelectedInputDevice() {
      if let savedInput = availableInputDevices.first(where: { $0.id == savedInputId }) {
        selections.selectedInput = savedInput
      } else {
        selections.selectedInput = availableInputDevices.first
      }
    } else {
      selections.selectedInput = availableInputDevices.first
    }
  }

  private func loadProcesses() {
    Task {
      let systemAudioSource = AudioSource.allApplications
      let processes = try? AudioObjectID.system.readProcessList().compactMap {
        objID -> AudioSource? in
        var pid: pid_t = -1
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        var address = AudioObjectPropertyAddress(
          mSelector: kAudioProcessPropertyPID,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(objID, &address, 0, nil, &dataSize, &pid) == noErr,
          let app = NSRunningApplication(processIdentifier: pid),
          app.activationPolicy != .prohibited
        else { return nil }

        let process = AudioProcess(
          id: pid,
          name: app.localizedName ?? "Unknown Process",
          bundleURL: app.bundleURL,
          sourceType: .process(objID)
        )
        return .from(process: process)
      }

      await MainActor.run {
        self.availableProcesses =
          [systemAudioSource] + (processes ?? []).sorted { $0.name < $1.name }

        if let stored = dbManager.getSelectedAudioProcess() {
          self.selections.selectedProcess = availableProcesses.first { process in
            process.bundleIdentifier == stored.bundleIdentifier
              && process.bundleURL?.path == stored.bundleURL && process.name == stored.name
          }
        }
      }
    }
  }

  private func loadInputDevices() {
    // Get all audio devices
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    var err = AudioObjectGetPropertyDataSize(AudioObjectID.system, &address, 0, nil, &dataSize)
    guard err == noErr else {
      logger.error("Error getting devices size: \(err)")
      return
    }

    let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

    err = AudioObjectGetPropertyData(AudioObjectID.system, &address, 0, nil, &dataSize, &deviceIDs)
    guard err == noErr else {
      logger.error("Error getting device IDs: \(err)")
      return
    }

    // Convert to AudioSources, filtering for input devices
    var inputDevices: [AudioSource] = []
    for deviceID in deviceIDs {
      if let source = try? AudioSource.from(deviceID: deviceID) {
        inputDevices.append(source)
      }
    }

    self.availableInputDevices = inputDevices.sorted { $0.name < $1.name }
  }
}
