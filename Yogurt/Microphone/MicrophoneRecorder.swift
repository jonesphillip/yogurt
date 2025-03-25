import AVFoundation
import AudioToolbox
import Foundation
import OSLog
import Observation

@Observable
final class MicrophoneRecorder {
  private let logger = Logger(subsystem: kAppSubsystem, category: "MicrophoneRecorder")
  private var engine: AVAudioEngine?
  private var chunkHandler: ((Data) -> Void)?
  private let flushInterval: TimeInterval = 5.0
  private var lastFlushTime = Date()
  private var pendingBuffer = Data()

  private(set) var isRunning = false

  // Observable amplitude in [0...1].
  var amplitude: Float = 0.0

  // Throttling amplitude updates
  private var lastAmplitudeUpdate = Date()
  private let amplitudeUpdateInterval: TimeInterval = 0.1

  func start(chunkHandler: @escaping (Data) -> Void) throws {
    guard !isRunning else { return }

    self.chunkHandler = chunkHandler

    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let inputFormat = inputNode.inputFormat(forBus: 0)

    let converter = AVAudioMixerNode()
    engine.attach(converter)
    engine.connect(inputNode, to: converter, format: inputFormat)

    // We want 16kHz, mono, 16-bit for transcription
    let desiredFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: 16000,
      channels: 1,
      interleaved: true
    )!

    converter.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
      guard let strongSelf = self else { return }

      // Use AVAudioConverter from buffer.format → desiredFormat
      guard let converter = AVAudioConverter(from: buffer.format, to: desiredFormat) else {
        strongSelf.logger.error("Could not create AVAudioConverter")
        return
      }
      let ratio = 16000.0 / buffer.format.sampleRate
      let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

      guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: desiredFormat, frameCapacity: outFrames)
      else {
        strongSelf.logger.error("Could not create output buffer")
        return
      }

      var error: NSError?
      let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
        outStatus.pointee = .haveData
        return buffer
      }
      converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
      if let e = error {
        strongSelf.logger.error("Conversion error: \(e.localizedDescription)")
        return
      }

      let frameCount = Int(outputBuffer.frameLength)
      guard let int16Ptr = outputBuffer.int16ChannelData?[0] else { return }

      let newAmp = AudioCaptureUtils.computeRMSAmplitude(
        int16Samples: int16Ptr,
        frameCount: frameCount
      )
      strongSelf.throttleAmplitudeUpdate(newAmp)

      let samples = Array(UnsafeBufferPointer(start: int16Ptr, count: frameCount))
      let int16Data = AudioCaptureUtils.int16ArrayToData(samples)
      strongSelf.pendingBuffer.append(int16Data)

      // Flush chunk at set intervals
      let now = Date()
      if now.timeIntervalSince(strongSelf.lastFlushTime) >= strongSelf.flushInterval {
        let wavData = AudioCaptureUtils.makeWavData(
          pcmData: strongSelf.pendingBuffer,
          sampleRate: 16000,
          channels: 1,
          bitsPerSample: 16
        )
        strongSelf.chunkHandler?(wavData)
        strongSelf.pendingBuffer.removeAll()
        strongSelf.lastFlushTime = now
      }
    }

    engine.prepare()
    try engine.start()
    self.engine = engine
    isRunning = true
    logger.info("Microphone recording started")
  }

  func stop() {
    guard isRunning else { return }

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

    engine?.inputNode.removeTap(onBus: 0)
    engine?.stop()
    engine = nil
    isRunning = false
    logger.info("Microphone recording stopped")
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
