import AVFoundation
import Foundation

struct AudioCaptureUtils {

  /// Downmixes a stereo Float32 buffer to mono Int16 PCM data.
  /// - Parameters:
  ///   - srcPtr: Pointer to the stereo Float32 samples
  ///   - frameCount: Number of *frames* (each frame has 2 channels)
  /// - Returns: A newly allocated [Int16] with mono samples
  static func downmixStereoFloat32ToMonoInt16(
    srcPtr: UnsafePointer<Float32>,
    frameCount: Int
  ) -> [Int16] {
    var monoSamples = [Int16](repeating: 0, count: frameCount)
    for i in 0..<frameCount {
      let left = srcPtr[i * 2]
      let right = srcPtr[i * 2 + 1]
      let average = (left + right) * 0.5
      let clamped = max(-1.0, min(1.0, average))
      monoSamples[i] = Int16(clamped * Float32(Int16.max))
    }
    return monoSamples
  }

  /// Converts a `[Int16]` array into raw PCM `Data`.
  static func int16ArrayToData(_ samples: [Int16]) -> Data {
    return samples.withUnsafeBufferPointer { bufferPtr in
      Data(buffer: bufferPtr)
    }
  }

  /// Creates a minimal WAV header and appends the provided PCM data.
  /// - sampleRate: e.g. 16000 or 48000
  /// - channels: e.g. 1 for mono
  /// - bitsPerSample: e.g. 16 if we've converted to 16-bit
  static func makeWavData(
    pcmData: Data,
    sampleRate: Float64,
    channels: UInt16,
    bitsPerSample: UInt16
  ) -> Data {
    let blockAlign = UInt16(channels) * bitsPerSample / 8
    let byteRate = UInt32(sampleRate) * UInt32(blockAlign)
    let subchunk2Size = UInt32(pcmData.count)
    let chunkSize = 36 + subchunk2Size

    func writeLE<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
      withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    var wav = Data()

    // RIFF header
    wav.append(contentsOf: "RIFF".utf8)
    wav.append(contentsOf: writeLE(chunkSize))
    wav.append(contentsOf: "WAVE".utf8)

    // fmt chunk
    wav.append(contentsOf: "fmt ".utf8)
    wav.append(contentsOf: writeLE(UInt32(16)))  // PCM
    wav.append(contentsOf: writeLE(UInt16(1)))  // PCM format
    wav.append(contentsOf: writeLE(channels))  // # of channels
    wav.append(contentsOf: writeLE(UInt32(sampleRate)))  // sample rate
    wav.append(contentsOf: writeLE(byteRate))  // byte rate
    wav.append(contentsOf: writeLE(blockAlign))  // block align
    wav.append(contentsOf: writeLE(bitsPerSample))  // bits per sample

    // data chunk
    wav.append(contentsOf: "data".utf8)
    wav.append(contentsOf: writeLE(subchunk2Size))
    wav.append(pcmData)

    return wav
  }

  /// Computes RMS amplitude of a mono Int16 buffer
  /// (result is scaled to [0..1]).
  static func computeRMSAmplitude(int16Samples: UnsafePointer<Int16>, frameCount: Int) -> Float {
    if frameCount == 0 { return 0.0 }
    var sum: Double = 0
    for i in 0..<frameCount {
      let sample = Double(int16Samples[i]) / Double(Int16.max)
      sum += sample * sample
    }
    let rms = sqrt(sum / Double(frameCount))
    // Convert RMS to decibels, clamp at -60dB
    let db = 20.0 * log10(rms)
    let minDb: Double = -60
    let clampedDb = max(minDb, db)
    // Map -60...0 → 0...1
    return Float((clampedDb - minDb) / -minDb)
  }
}
