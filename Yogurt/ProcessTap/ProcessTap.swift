import AVFoundation
import AudioToolbox
import OSLog

struct ProcessTapError: Error, CustomStringConvertible {
  let message: String
  var description: String { "ProcessTapError: \(message)" }
}

enum ProcessAudioSourceType: Equatable {
  case process(AudioObjectID)
  case systemWide
}

struct AudioProcess {
  let id: pid_t
  let name: String
  let bundleURL: URL?
  let sourceType: ProcessAudioSourceType

  static func systemWideAudio() -> AudioProcess {
    return AudioProcess(
      id: 0,
      name: "All System Audio",
      bundleURL: nil,
      sourceType: .systemWide
    )
  }

  static func specificProcess(pid: pid_t, name: String, bundleURL: URL?, objectID: AudioObjectID)
    -> AudioProcess
  {
    return AudioProcess(
      id: pid,
      name: name,
      bundleURL: bundleURL,
      sourceType: .process(objectID)
    )
  }
}

final class ProcessTap {

  typealias InvalidationHandler = (ProcessTap) -> Void

  let process: AudioProcess
  let muteWhenRunning: Bool
  private let logger: Logger

  private var processTapID: AudioObjectID = .unknown
  private var aggregateDeviceID: AudioObjectID = .unknown
  private var deviceProcID: AudioDeviceIOProcID?
  private var invalidationHandler: InvalidationHandler?

  private(set) var tapStreamDescription: AudioStreamBasicDescription?
  private(set) var activated = false

  init(process: AudioProcess, muteWhenRunning: Bool = false) {
    self.process = process
    self.muteWhenRunning = muteWhenRunning
    self.logger = Logger(subsystem: kAppSubsystem, category: "ProcessTap(\(process.name))")
  }

  func activate() throws {
    guard !activated else { return }
    activated = true
    logger.debug(
      "Activating ProcessTap for \(self.process.sourceType == .systemWide ? "system-wide audio" : "process \(self.process.id)")"
    )
    try prepareTap()
  }

  private func createTapDescription() -> CATapDescription {
    let tapDescription: CATapDescription
    switch process.sourceType {
    case .systemWide:
      tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    case .process(let objectID):
      tapDescription = CATapDescription(stereoMixdownOfProcesses: [objectID])
    }
    tapDescription.uuid = UUID()
    tapDescription.muteBehavior =
      muteWhenRunning ? CATapMuteBehavior.mutedWhenTapped : CATapMuteBehavior.unmuted
    return tapDescription
  }

  private func prepareTap() throws {
    // Get system output configuration
    let systemOutputID = try AudioDeviceID.readDefaultSystemOutputDevice()
    let outputUID = try systemOutputID.readDeviceUID()

    // Create and configure tap
    let tapDescription = createTapDescription()
    var tapID: AUAudioObjectID = .unknown
    let status = AudioHardwareCreateProcessTap(tapDescription, &tapID)

    guard status == noErr else {
      logger.error("Process tap creation failed with error: \(status)")
      throw ProcessTapError(message: "Process tap creation failed with error \(status)")
    }

    self.processTapID = tapID
    logger.debug("Created process tap #\(tapID)")

    // Read tap format
    do {
      self.tapStreamDescription = try tapID.readAudioTapStreamBasicDescription()
      logger.debug(
        "Tap format: \(self.tapStreamDescription?.mSampleRate ?? 0) Hz, \(self.tapStreamDescription?.mChannelsPerFrame ?? 0) channels"
      )
    } catch {
      logger.error("Failed to read tap format after creation: \(error)")
      throw error
    }

    // Create aggregate device
    let aggregateUID = UUID().uuidString
    let description: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Tap-\(process.id)",
      kAudioAggregateDeviceUIDKey: aggregateUID,
      kAudioAggregateDeviceMasterSubDeviceKey: outputUID,
      kAudioAggregateDeviceIsPrivateKey: true,
      kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [
        [
          kAudioSubDeviceUIDKey: outputUID,
          kAudioSubDeviceExtraInputLatencyKey: 0,
          kAudioSubDeviceExtraOutputLatencyKey: 0,
          kAudioSubDeviceInputChannelsKey: 2,
          kAudioSubDeviceOutputChannelsKey: 2,
        ]
      ],
      kAudioAggregateDeviceTapListKey: [
        [
          kAudioSubTapDriftCompensationKey: true,
          kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
        ]
      ],
      kAudioAggregateDeviceClockDeviceKey: outputUID,
    ]

    var newAggregateID: AudioObjectID = .unknown
    let createStatus = AudioHardwareCreateAggregateDevice(
      description as CFDictionary, &newAggregateID)

    guard createStatus == noErr else {
      throw ProcessTapError(message: "Failed to create aggregate device: \(createStatus)")
    }

    self.aggregateDeviceID = newAggregateID
    logger.debug("Created aggregate device #\(newAggregateID)")
  }

  func run(
    on queue: DispatchQueue,
    ioBlock: @escaping AudioDeviceIOBlock,
    invalidationHandler: @escaping InvalidationHandler
  ) throws {
    guard activated else {
      throw ProcessTapError(message: "Tap not activated!")
    }
    guard self.invalidationHandler == nil else {
      throw ProcessTapError(message: "Tap is already running!")
    }

    self.invalidationHandler = invalidationHandler

    guard var tapStreamDescription = tapStreamDescription else {
      throw ProcessTapError(message: "No tap stream format available")
    }

    // Modify stream description to ensure mono
    tapStreamDescription.mChannelsPerFrame = 1
    tapStreamDescription.mBytesPerFrame = tapStreamDescription.mBitsPerChannel / 8
    tapStreamDescription.mBytesPerPacket = tapStreamDescription.mBytesPerFrame

    var err = AudioDeviceCreateIOProcIDWithBlock(&deviceProcID, aggregateDeviceID, queue) {
      [weak self] timestamp, inData, inTime, outData, outTime in
      guard let self = self,
        inData.pointee.mNumberBuffers > 0,
        let inputData = inData.pointee.mBuffers.mData,
        inData.pointee.mBuffers.mDataByteSize > 0
      else {
        return
      }

      // Create mono buffer
      var monoBuffer = AudioBuffer()
      monoBuffer.mNumberChannels = 1
      monoBuffer.mDataByteSize = inData.pointee.mBuffers.mDataByteSize / 2
      monoBuffer.mData = malloc(Int(monoBuffer.mDataByteSize))
      defer { free(monoBuffer.mData) }

      // Mix stereo to mono
      let srcBuffer = inData.pointee.mBuffers
      let frameCount = Int(srcBuffer.mDataByteSize) / (2 * 4)  // 2 channels, 4 bytes per sample
      let srcData = inputData.assumingMemoryBound(to: Float32.self)
      let dstData = monoBuffer.mData!.assumingMemoryBound(to: Float32.self)

      // Safely mix stereo to mono
      for i in 0..<frameCount {
        let leftSample = srcData[i * 2]
        let rightSample = srcData[i * 2 + 1]
        dstData[i] = (leftSample + rightSample) / 2.0
      }

      // Create mono buffer list
      var monoBufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: monoBuffer
      )

      // Pass mono buffer to callback
      ioBlock(timestamp, &monoBufferList, inTime, outData, outTime)
    }

    guard err == noErr else {
      throw ProcessTapError(message: "Failed to create device I/O proc: \(err)")
    }

    err = AudioDeviceStart(aggregateDeviceID, deviceProcID)
    guard err == noErr else {
      throw ProcessTapError(message: "Failed to start audio device: \(err)")
    }
  }

  func invalidate() throws {
    guard activated else { return }
    activated = false

    invalidationHandler?(self)
    invalidationHandler = nil

    // 1) Stop aggregator
    if aggregateDeviceID.isValid {
      var err = AudioDeviceStop(aggregateDeviceID, deviceProcID)
      if err != noErr {
        logger.warning("Stop aggregator device error: \(err)")
      }

      if let deviceProcID {
        err = AudioDeviceDestroyIOProcID(aggregateDeviceID, deviceProcID)
        if err != noErr {
          logger.warning("DestroyIOProcID error: \(err)")
        }
        self.deviceProcID = nil
      }

      err = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
      if err != noErr {
        logger.warning("DestroyAggregateDevice error: \(err)")
      }
      aggregateDeviceID = .unknown
    }

    // 2) Destroy tap
    if processTapID.isValid {
      let err = AudioHardwareDestroyProcessTap(processTapID)
      if err != noErr {
        logger.warning("DestroyProcessTap error: \(err)")
      }
      processTapID = .unknown
    }
  }

  deinit {
    try? invalidate()
  }
}
