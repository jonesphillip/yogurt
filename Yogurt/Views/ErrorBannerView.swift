import SwiftUI

struct ErrorBanner: View {
  let message: String
  let retryCount: Int?
  let maxRetries: Int?
  @Binding var isVisible: Bool

  var body: some View {
    HStack(spacing: 12) {
      // Error icon with pulsing animation
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundColor(.white)
        .font(.system(size: 14))
        .modifier(PulseAnimation())

      VStack(alignment: .leading, spacing: 2) {
        Text(message)
          .foregroundColor(.white)
          .font(.system(size: 13))

        if let retryCount = retryCount, let maxRetries = maxRetries {
          Text("Retrying \(retryCount)/\(maxRetries)")
            .foregroundColor(.white.opacity(0.8))
            .font(.system(size: 12))
        }
      }

      Spacer()

      Button {
        withAnimation(.easeOut(duration: 0.2)) {
          isVisible = false
        }
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(.white.opacity(0.8))
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: 29, style: .continuous)
        .fill(
          LinearGradient(
            gradient: Gradient(colors: [
              Color.red.opacity(0.7),
              Color.red.opacity(0.9),
            ]),
            startPoint: .leading,
            endPoint: .trailing
          )
        )
    )
    .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 3)
    .opacity(isVisible ? 1 : 0)
    .animation(.easeInOut(duration: 0.3), value: isVisible)
  }
}

struct PulseAnimation: ViewModifier {
  @State private var isPulsing = false

  func body(content: Content) -> some View {
    content
      .opacity(isPulsing ? 0.5 : 1.0)
      .onAppear {
        withAnimation(Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
          isPulsing = true
        }
      }
  }
}

struct ErrorState {
  var isVisible = false
  var message = ""
  var retryCount: Int?
  var maxRetries: Int?

  mutating func show(message: String, retryCount: Int? = nil, maxRetries: Int? = nil) {
    self.message = message
    self.retryCount = retryCount
    self.maxRetries = maxRetries
    self.isVisible = true
  }

  mutating func clear() {
    isVisible = false
    message = ""
    retryCount = nil
    maxRetries = nil
  }
}
