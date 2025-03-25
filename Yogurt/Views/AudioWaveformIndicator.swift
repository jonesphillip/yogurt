import SwiftUI

struct AudioWaveformIndicator: View {
  // Overall amplitude in [0.0 ... 1.0]
  let amplitude: Float

  let isSelected: Bool
  private let barCount = 3
  private let baseHeight: CGFloat = 12.0
  private let barScales: [CGFloat] = [0.8, 1.2, 0.8]
  private let maxFactor: CGFloat = 2.0
  private let randomRange: ClosedRange<CGFloat> = 0.9...1.1

  var body: some View {
    HStack(spacing: 3) {
      ForEach(0..<barCount, id: \.self) { index in
        Capsule()
          .fill(isSelected ? Color.white : Color.orange)
          .frame(width: 3, height: barHeight(for: index))
      }
    }
    .animation(.linear(duration: 0.2), value: amplitude)
  }

  private func barHeight(for index: Int) -> CGFloat {
    let amp = CGFloat(amplitude)

    // Multiply amplitude by barScales[index] so middle bar is naturally larger
    var height = baseHeight * maxFactor * amp * barScales[index]

    // Add some random jitter so each bar doesn't move identically
    let randomMultiplier = CGFloat.random(in: randomRange)
    height *= randomMultiplier

    let minHeight = baseHeight * 0.2
    return max(minHeight, height)
  }
}
