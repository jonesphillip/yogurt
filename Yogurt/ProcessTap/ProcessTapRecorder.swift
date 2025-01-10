import AVFoundation
import Foundation
import OSLog

// MARK: - Custom Error
struct TranscriberError: Error, CustomStringConvertible {
  let message: String
  var description: String { "TranscriberError: \(message)" }
}

// A helper for writing integers in little-endian
extension FixedWidthInteger {
  fileprivate var leBytes: [UInt8] {
    withUnsafeBytes(of: self.littleEndian) { Array($0) }
  }
}

final class ProcessTapRecorder {
  private let logger = Logger(subsystem: kAppSubsystem, category: "ProcessTapRecorder")

  private let tap: ProcessTap
  private var chunkHandler: ((Data) -> Void)?
  private let queue = DispatchQueue(label: "ProcessTapRecorderQueue")

  private var isRunning = false
  private var pendingBuffer = Data()
  private var lastFlushTime = Date()
  private let flushInterval: TimeInterval = 5.0

  init(process: AudioProcess, chunkHandler: @escaping (Data) -> Void) {
    let browserFinder = DefaultBrowserFinder()

    // If this is Safari (either as default or selected), use GPU process
    let finalProcess: AudioProcess
    if process.bundleURL?.path != nil,
      let bundleID = Bundle(url: process.bundleURL!)?.bundleIdentifier,
      bundleID == "com.apple.Safari"
    {
      do {
        finalProcess = try browserFinder.findSafariGPUProcess()
      } catch {
        logger.error("Failed to find Safari GPU process: \(error.localizedDescription)")
        finalProcess = process  // Fallback to original process if GPU process not found
      }
    } else {
      finalProcess = process
    }

    self.tap = ProcessTap(process: finalProcess, muteWhenRunning: false)
    self.chunkHandler = chunkHandler
  }

  @MainActor
  func start() throws {
    logger.debug("Starting tap transcriber for process: \(self.tap.process.name)")

    try tap.activate()

    guard var streamDescription = tap.tapStreamDescription else {
      throw TranscriberError(message: "Tap stream description not available.")
    }

    // Modify stream description for optimization
    streamDescription.mSampleRate = 16000
    streamDescription.mChannelsPerFrame = 1
    streamDescription.mBitsPerChannel = 16
    streamDescription.mBytesPerFrame = 2
    streamDescription.mBytesPerPacket = 2
    streamDescription.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked

    let settings: [String: Any] = [
      AVFormatIDKey: streamDescription.mFormatID,
      AVSampleRateKey: streamDescription.mSampleRate,
      AVNumberOfChannelsKey: streamDescription.mChannelsPerFrame,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]

    // Start the tap with I/O callback
    try tap.run(
      on: queue,
      ioBlock: { [weak self] inNow, inInputData, inInputTime, outOutputData, inOutputTime in
        guard let self = self else { return }

        let inputData = inInputData.pointee.mBuffers
        guard inputData.mData != nil, inputData.mDataByteSize > 0 else { return }

        // Calculate frame count from input data
        let frameCount = Int(inputData.mDataByteSize) / (4 * 2)  // 4 bytes per float32, 2 channels

        // Create optimized format PCM buffer with correct capacity
        let format = AVAudioFormat(
          commonFormat: .pcmFormatInt16,
          sampleRate: 16000,
          channels: 1,
          interleaved: true)!

        guard
          let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount))
        else {
          self.logger.error("Failed to create PCM buffer")
          return
        }

        let srcData = inputData.mData?.assumingMemoryBound(to: Float32.self)
        guard let srcSamples = srcData else { return }
        guard let dstSamples = pcmBuffer.int16ChannelData?[0] else { return }

        // Mix stereo to mono and convert float32 to int16
        for frame in 0..<frameCount {
          let leftSample = srcSamples[frame * 2]
          let rightSample = srcSamples[frame * 2 + 1]
          let monoSample = (leftSample + rightSample) / 2.0
          dstSamples[frame] = Int16(max(-32768, min(32767, monoSample * 32767.0)))
        }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Convert to 8-bit for streaming
        var audioData = Data(capacity: frameCount)

        for frame in 0..<frameCount {
          let sample = dstSamples[frame]
          let normalized = Float(sample) / Float(Int16.max)
          let mapped = UInt8(max(0, min(255, (normalized + 1.0) * 128)))
          audioData.append(mapped)
        }

        self.pendingBuffer.append(audioData)

        let now = Date()
        if now.timeIntervalSince(self.lastFlushTime) >= self.flushInterval {
          let wavData = self.makeWavDataFromPendingBuffer(
            self.pendingBuffer,
            sampleRate: 16000,
            channels: 1
          )

          if let handler = self.chunkHandler {
            handler(wavData)
          }

          self.pendingBuffer.removeAll()
          self.lastFlushTime = now
        }
      },
      invalidationHandler: { [weak self] tap in
        guard let self = self else { return }
        self.handleInvalidation()
        self.logger.debug("Tap invalidated for process: \(tap.process.name)")
      })

    isRunning = true
  }

  func stop() {
    logger.debug("Stopping tap transcriber for process: \(self.tap.process.name)")
    guard isRunning else { return }

    do {
      try tap.invalidate()
    } catch {
      logger.error("Error invalidating tap: \(error.localizedDescription)")
    }
    isRunning = false

    // Final flush if needed
    if !pendingBuffer.isEmpty {
      self.logger.info("Final flush of pending buffer on stop()")
      let wavData = makeWavDataFromPendingBuffer(
        pendingBuffer,
        sampleRate: 44100,  // Or use last known sampleRate
        channels: 2  // Or use last known channelCount
      )
      if let handler = self.chunkHandler {
        handler(wavData)
      }
      pendingBuffer.removeAll()
    }
  }

  private func handleInvalidation() {
    guard isRunning else { return }

    logger.debug(#function)
  }

  // Builds a minimal in-memory WAV from raw 8-bit samples
  private func makeWavDataFromPendingBuffer(
    _ pcmData: Data,
    sampleRate: Float64,
    channels: UInt32
  ) -> Data {

    let bitsPerSample: UInt16 = 8
    let blockAlign = UInt16(channels) * bitsPerSample / 8
    let byteRate = UInt32(sampleRate) * UInt32(blockAlign)

    let subchunk2Size = UInt32(pcmData.count)
    let chunkSize = 36 + subchunk2Size

    var wav = Data()

    // "RIFF" header
    wav.append(contentsOf: "RIFF".utf8)
    wav.append(contentsOf: chunkSize.leBytes)
    wav.append(contentsOf: "WAVE".utf8)

    // "fmt " chunk
    wav.append(contentsOf: "fmt ".utf8)
    wav.append(contentsOf: UInt32(16).leBytes)  // PCM
    wav.append(contentsOf: UInt16(1).leBytes)  // PCM format
    wav.append(contentsOf: UInt16(channels).leBytes)  // Channels
    wav.append(contentsOf: UInt32(sampleRate).leBytes)  // Sample rate
    wav.append(contentsOf: byteRate.leBytes)  // Byte rate
    wav.append(contentsOf: blockAlign.leBytes)  // Block align
    wav.append(contentsOf: bitsPerSample.leBytes)  // Bits per sample

    // "data" chunk
    wav.append(contentsOf: "data".utf8)
    wav.append(contentsOf: subchunk2Size.leBytes)
    wav.append(pcmData)

    return wav
  }
}
