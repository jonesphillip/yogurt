import AVFoundation
import CoreAudio
import Foundation
import OSLog
import Observation

@Observable
final class ProcessTapRecorder {
  private let logger = Logger(subsystem: kAppSubsystem, category: "ProcessTapRecorder")

  private let tap: ProcessTap
  private var chunkHandler: ((Data) -> Void)?
  private let queue = DispatchQueue(label: "ProcessTapRecorderQueue")

  private var isRunning = false
  private var pendingBuffer = Data()
  private var lastFlushTime = Date()
  private let flushInterval: TimeInterval = 5.0

  // amplitude in [0...1], updated after each buffer (throttled)
  var amplitude: Float = 0.0
  private var lastAmplitudeUpdate = Date()
  private let amplitudeUpdateInterval: TimeInterval = 0.1

  init(process: AudioProcess, chunkHandler: @escaping (Data) -> Void) {
    self.tap = ProcessTap(process: process, muteWhenRunning: false)
    self.chunkHandler = chunkHandler
  }

  @MainActor
  func start() throws {
    logger.debug("Starting tap for process: \(self.tap.process.name)")
    try tap.activate()

    // Run the aggregator callback
    try tap.run(
      on: queue,
      ioBlock: { [weak self] _, inData, _, _, _ in
        guard let self = self else { return }

        let input = inData.pointee.mBuffers
        guard let srcPtr = input.mData, input.mDataByteSize > 0 else { return }

        // input is stereo Float32 at system rate, e.g. 48 kHz
        let byteCount = Int(input.mDataByteSize)
        let frames = byteCount / (MemoryLayout<Float32>.size * 2)
        let floatPtr = srcPtr.assumingMemoryBound(to: Float32.self)

        // Downmix to mono Int16
        let monoInt16 = AudioCaptureUtils.downmixStereoFloat32ToMonoInt16(
          srcPtr: floatPtr,
          frameCount: frames
        )

        let int16Data = AudioCaptureUtils.int16ArrayToData(monoInt16)
        self.pendingBuffer.append(int16Data)

        let now = Date()
        if now.timeIntervalSince(self.lastFlushTime) >= self.flushInterval {
          let wavData = AudioCaptureUtils.makeWavData(
            pcmData: self.pendingBuffer,
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
          )
          self.chunkHandler?(wavData)
          self.pendingBuffer.removeAll()
          self.lastFlushTime = now
        }

        // Compute amplitude
        let newAmp = monoInt16.withUnsafeBufferPointer { bufPtr in
          AudioCaptureUtils.computeRMSAmplitude(
            int16Samples: bufPtr.baseAddress!,
            frameCount: frames
          )
        }
        self.throttleAmplitudeUpdate(newAmp)
      },
      invalidationHandler: { [weak self] _ in
        self?.handleInvalidation()
      })

    isRunning = true
  }

  func stop() {
    logger.debug("Stopping tap for process: \(self.tap.process.name)")
    guard isRunning else { return }

    do {
      try tap.invalidate()
    } catch {
      logger.error("Error invalidating tap: \(error.localizedDescription)")
    }
    isRunning = false

    // Final flush
    if !pendingBuffer.isEmpty {
      let wavData = AudioCaptureUtils.makeWavData(
        pcmData: pendingBuffer,
        sampleRate: 16000,
        channels: 1,
        bitsPerSample: 16
      )
      chunkHandler?(wavData)
      pendingBuffer.removeAll()
    }
  }

  private func handleInvalidation() {
    logger.debug("Tap invalidated")
    if isRunning {
      logger.info("Tap forcibly invalidated while running")
    }
  }

  private func throttleAmplitudeUpdate(_ newAmp: Float) {
    let now = Date()
    if now.timeIntervalSince(lastAmplitudeUpdate) > amplitudeUpdateInterval {
      Task { @MainActor in
        self.amplitude = newAmp
      }
      lastAmplitudeUpdate = now
    }
  }
}
