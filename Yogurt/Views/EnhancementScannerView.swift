import SwiftUI

struct EnhancementScannerView: View {
  // MARK: - External Dependencies

  let width: CGFloat

  @Binding var originalLines: [String]
  @Binding var enhancedLines: [String]
  @Binding var currentLineBuffer: String

  @Binding var scanningIndex: Int
  @Binding var isDone: Bool
  @Binding var lastCompletedIndex: Int
  @Binding var textHeights: [Int: CGFloat]
  @Binding var currentLineHeight: CGFloat

  @Binding var progressValue: CGFloat
  @Binding var showCheckmark: Bool

  @Binding var isMorphingToControls: Bool
  @Binding var morphProgress: CGFloat

  // The current enhancement step, used for progress dots, etc.
  let enhancementStep: EnhancementStep

  //  Layout constants
  let fontSize: CGFloat
  let horizontalPadding: CGFloat
  let verticalPadding: CGFloat

  @Binding var isEnhancing: Bool

  // MARK: - Body
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(0..<max(originalLines.count, enhancedLines.count), id: \.self) { idx in
          lineView(for: idx, maxWidth: width)
        }
        Spacer(minLength: 30)
      }
    }
    .padding(.top, 62)
    .padding(.leading, 12)
    .padding(.trailing, 12)
    .background(Color(NSColor.textBackgroundColor))
    .edgesIgnoringSafeArea(.all)

    .overlay(scannerBarOverlay)
  }

  // MARK: - Lines
  private func lineView(for idx: Int, maxWidth: CGFloat) -> some View {
    Group {
      if idx <= lastCompletedIndex && idx < enhancedLines.count {
        completedLineView(
          text: enhancedLines[idx],
          index: idx,
          maxWidth: maxWidth
        )
      } else if idx < originalLines.count {
        pendingLineView(
          text: originalLines[idx],
          index: idx,
          maxWidth: maxWidth
        )
      }
    }
  }

  private func completedLineView(
    text: String,
    index: Int,
    maxWidth: CGFloat
  ) -> some View {
    TextMeasurementView(
      text: text,
      fontSize: fontSize,
      maxWidth: maxWidth - horizontalPadding * 2
    ) { height in
      textHeights[index] = height
    }
    .padding(.leading, horizontalPadding)
    .padding(.vertical, verticalPadding)
    .transition(.opacity)
  }

  private func pendingLineView(
    text: String,
    index: Int,
    maxWidth: CGFloat
  ) -> some View {
    TextMeasurementView(
      text: text,
      fontSize: fontSize,
      maxWidth: maxWidth - horizontalPadding * 2
    ) { height in
      if index == scanningIndex {
        currentLineHeight = height
      }
      textHeights[index] = height
    }
    .padding(.leading, horizontalPadding)
    .padding(.vertical, verticalPadding)
    .foregroundColor(.gray)
    .opacity(index == scanningIndex ? 0 : 1)
  }

  // MARK: - Overlay
  private var scannerBarOverlay: some View {
    GeometryReader { geo in
      let yOffset = calculateScannerYOffset()
      let finalYOffset = geo.size.height - 60
      let currentYOffset =
        isMorphingToControls
        ? mix(yOffset, finalYOffset, progress: morphProgress)
        : yOffset

      let startWidth = geo.size.width - 16
      let endWidth: CGFloat = 120
      let currentWidth =
        isMorphingToControls
        ? mix(startWidth, endWidth, progress: morphProgress)
        : startWidth

      let startHeight: CGFloat = 38
      let endHeight: CGFloat = 38
      let currentHeight =
        isMorphingToControls
        ? mix(startHeight, endHeight, progress: morphProgress)
        : startHeight

      ZStack(alignment: .topLeading) {
        HStack(spacing: 12) {
          if !isMorphingToControls {
            ProgressToCheckmark(
              progress: progressValue,
              showCheckmark: showCheckmark,
              isProcessing: enhancementStep != .idle && !isDone
            )
            .frame(width: 20, height: 20)
            .padding(.leading, 16)

            Spacer()

            if enhancementStep != .idle {
              EnhancementProgressDots(currentStep: enhancementStep)
                .padding(.trailing, 16)
            }
          }
        }
        .opacity(
          isMorphingToControls
            ? Double(1 - min(1, morphProgress * 2.5))
            : 1
        )
        .frame(width: currentWidth, height: currentHeight)
        .background(
          ZStack {
            RoundedRectangle(cornerRadius: 29)
              .fill(
                LinearGradient(
                  gradient: Gradient(colors: [
                    Color.orange.opacity(0.6),
                    Color.orange.opacity(0.85),
                  ]),
                  startPoint: .leading,
                  endPoint: .trailing
                )
              )
              .opacity(1 - morphProgress)

            RoundedRectangle(cornerRadius: 29)
              .fill(Color.gray.opacity(0.6))
              .opacity(morphProgress)
          }
        )
        .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 3)
        .offset(
          x: isMorphingToControls
            ? mix(8, (geo.size.width - currentWidth) / 2, progress: morphProgress)
            : 8,
          y: currentYOffset
        )
      }
      .animation(.easeInOut(duration: 0.3), value: scanningIndex)
      .animation(.easeInOut(duration: 0.3), value: currentLineHeight)
      .animation(.easeInOut(duration: 0.6), value: morphProgress)
    }
  }

  // MARK: - Helpers
  private func calculateScannerYOffset() -> CGFloat {
    var offset: CGFloat = -1
    for idx in 0..<scanningIndex {
      offset += textHeights[idx] ?? 0
      offset += verticalPadding * 2
    }
    return offset
  }

  private func mix(_ from: CGFloat, _ to: CGFloat, progress: CGFloat) -> CGFloat {
    from * (1 - progress) + to * progress
  }
}

// MARK: - Subviews

private struct TextMeasurementView: View {
  let text: String
  let fontSize: CGFloat
  let maxWidth: CGFloat
  let onHeightChange: (CGFloat) -> Void

  var body: some View {
    Text(text)
      .font(.system(size: fontSize, weight: .regular, design: .rounded))
      .frame(maxWidth: maxWidth, alignment: .leading)
      .background(
        GeometryReader { geometry in
          Color.clear.onAppear {
            onHeightChange(geometry.size.height)
          }
        }
      )
  }
}

private struct ProgressToCheckmark: View {
  let progress: CGFloat
  let showCheckmark: Bool
  let isProcessing: Bool

  @State private var rotation: Double = 0
  @State private var trimEnd: CGFloat = 0

  var body: some View {
    ZStack {
      if !showCheckmark {
        Circle()
          .stroke(
            Color.white.opacity(0.3),
            lineWidth: 2
          )

        if isProcessing {
          // Spinning circle
          Circle()
            .trim(from: 0, to: 0.8)
            .stroke(
              Color.white,
              style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            .rotationEffect(.degrees(rotation))
            .onAppear {
              withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                rotation = 360
              }
            }
        } else {
          // Static progress
          Circle()
            .trim(from: 0, to: progress)
            .stroke(
              Color.white,
              style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
        }
      } else {
        CheckmarkShape()
          .trim(from: 0, to: trimEnd)
          .stroke(
            Color.white,
            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
          )
          .frame(width: 12, height: 12)
          .onAppear {
            withAnimation(.easeOut(duration: 0.3).delay(0.1)) {
              trimEnd = 1
            }
          }
      }
    }
  }
}

private struct CheckmarkShape: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let midX = rect.midX
    let midY = rect.midY

    path.move(to: CGPoint(x: midX - 4, y: midY))
    path.addLine(to: CGPoint(x: midX - 1, y: midY + 3))
    path.addLine(to: CGPoint(x: midX + 4, y: midY - 3))
    return path
  }
}

// The 4-step dotted indicator during notes enhancement
private struct EnhancementProgressDots: View {
  let currentStep: EnhancementStep

  var body: some View {
    HStack(spacing: 4) {
      HStack(spacing: 6) {
        statusEmoji
        Text(statusText)
      }
      .frame(width: 180, alignment: .trailing)
      .foregroundColor(.white)
      .font(.system(size: 14, weight: .semibold))

      HStack(spacing: 4) {
        ForEach(EnhancementStep.allCases.dropFirst(), id: \.self) { step in
          Capsule()
            .fill(Color.white.opacity(stepOpacity(for: step)))
            .frame(width: isCurrentStep(step) ? 12 : 4, height: 4)
        }
      }
      .padding(.leading, 8)
    }
  }

  private var statusText: String {
    switch currentStep {
    case .idle: return ""
    case .transcribingNotes: return "Creating Notes"
    case .findingEmphasis: return "Finding Key Points"
    case .extractingActions: return "Extracting Actions"
    case .enhancing: return "Enhancing Notes"
    }
  }

  private var statusEmoji: some View {
    switch currentStep {
    case .idle: return AnyView(EmptyView())
    case .transcribingNotes: return AnyView(AnimatedEmoji(emoji: "📝"))
    case .findingEmphasis: return AnyView(AnimatedEmoji(emoji: "🔍"))
    case .extractingActions: return AnyView(AnimatedEmoji(emoji: "📋"))
    case .enhancing: return AnyView(AnimatedEmoji(emoji: "✨"))
    }
  }

  private func stepOpacity(for step: EnhancementStep) -> Double {
    if step.rawValue < currentStep.rawValue {
      return 0.8
    } else if step == currentStep {
      return 1.0
    } else {
      return 0.3
    }
  }

  private func isCurrentStep(_ step: EnhancementStep) -> Bool {
    step == currentStep
  }
}

private struct AnimatedEmoji: View {
  let emoji: String
  @State private var opacity: Double = 1.0

  var body: some View {
    Text(emoji)
      .opacity(opacity)
      .onAppear {
        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
          opacity = 0.7
        }
      }
  }
}
