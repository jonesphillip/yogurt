import AVFoundation
import AudioToolbox
import Foundation
import OSLog

@Observable
final class MicrophoneRecorder {
  private let logger = Logger(subsystem: kAppSubsystem, category: "MicrophoneRecorder")
  private var engine: AVAudioEngine?
  private var chunkHandler: ((Data) -> Void)?
  private let flushInterval: TimeInterval = 5.0
  private var lastFlushTime = Date()
  private var pendingBuffer = Data()
  private var currentFile: AVAudioFile?

  private(set) var isRunning = false

  // Helper for writing integers in little-endian
  private func writeLE<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian) { Array($0) }
  }

  func start(chunkHandler: @escaping (Data) -> Void) throws {
    guard !isRunning else { return }

    self.chunkHandler = chunkHandler

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let inputFormat = input.inputFormat(forBus: 0)

    // Create format converter node
    let converter = AVAudioMixerNode()
    engine.attach(converter)

    // Connect with input format, then get output in desired format
    engine.connect(input, to: converter, format: inputFormat)

    // Create file settings for 16kHz, mono, 16-bit
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]

    // Install tap using input format
    converter.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
      [weak self] buffer, time in
      guard let self = self else { return }

      // Create resampler
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true)!

      guard let converter = AVAudioConverter(from: buffer.format, to: outputFormat) else {
        self.logger.error("Failed to create converter")
        return
      }

      let ratio = 16000.0 / buffer.format.sampleRate
      let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

      guard
        let outputBuffer = AVAudioPCMBuffer(
          pcmFormat: outputFormat,
          frameCapacity: outputFrameCapacity)
      else {
        self.logger.error("Failed to create output buffer")
        return
      }

      var error: NSError?
      let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
        outStatus.pointee = .haveData
        return buffer
      }

      converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

      if let error = error {
        self.logger.error("Conversion error: \(error.localizedDescription)")
        return
      }

      // Create 8-bit data for streaming
      let frameCount = Int(outputBuffer.frameLength)
      var audioData = Data(capacity: frameCount)

      if let samples = outputBuffer.int16ChannelData?[0] {
        for frame in 0..<frameCount {
          let sample = samples[frame]
          let normalized = Float(sample) / Float(Int16.max)
          let mapped = UInt8(max(0, min(255, (normalized + 1.0) * 128)))
          audioData.append(mapped)
        }

        // Accumulate into pending buffer
        self.pendingBuffer.append(audioData)

        // Flush every flushInterval
        let now = Date()
        if now.timeIntervalSince(self.lastFlushTime) >= self.flushInterval {
          let wavData = self.makeWavDataFromPendingBuffer(
            self.pendingBuffer,
            sampleRate: 16000,
            channels: 1
          )

          self.chunkHandler?(wavData)

          self.pendingBuffer.removeAll()
          self.lastFlushTime = now
        }
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

    // Final flush if needed
    if !pendingBuffer.isEmpty, let format = engine?.inputNode.inputFormat(forBus: 0) {
      let wavData = makeWavDataFromPendingBuffer(
        pendingBuffer,
        sampleRate: format.sampleRate,
        channels: UInt32(format.channelCount)
      )
      chunkHandler?(wavData)
      pendingBuffer.removeAll()
    }

    currentFile = nil
    engine?.inputNode.removeTap(onBus: 0)
    engine?.stop()
    engine = nil
    isRunning = false
    logger.info("Microphone recording stopped")
  }

  // Creates WAV data from raw PCM samples
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
    wav.append(contentsOf: writeLE(chunkSize))
    wav.append(contentsOf: "WAVE".utf8)

    // "fmt " chunk
    wav.append(contentsOf: "fmt ".utf8)
    wav.append(contentsOf: writeLE(UInt32(16)))  // PCM
    wav.append(contentsOf: writeLE(UInt16(1)))  // PCM format
    wav.append(contentsOf: writeLE(UInt16(channels)))  // Channels
    wav.append(contentsOf: writeLE(UInt32(sampleRate)))  // Sample rate
    wav.append(contentsOf: writeLE(byteRate))  // Byte rate
    wav.append(contentsOf: writeLE(blockAlign))  // Block align
    wav.append(contentsOf: writeLE(bitsPerSample))  // Bits per sample

    // "data" chunk
    wav.append(contentsOf: "data".utf8)
    wav.append(contentsOf: writeLE(subchunk2Size))
    wav.append(pcmData)

    return wav
  }
}
