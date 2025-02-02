import SwiftUI

// Main debug view
struct DebugView: View {
  @StateObject private var debugManager = DebugManager.shared

  var body: some View {
    VStack(spacing: 0) {
      headerView

      ScrollView {
        VStack(spacing: 16) {
          progressOverview
          stepsList
        }
        .padding(16)
      }
    }
  }

  private var headerView: some View {
    HStack {
      Text("Enhancement Progress")
        .font(.system(size: 13, weight: .medium))
      Spacer()
      Text("⌘D to toggle")
        .font(.system(size: 11))
        .foregroundColor(.secondary)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.secondary.opacity(0.1))
  }

  private var progressOverview: some View {
    StepProgressView(currentStep: debugManager.currentStep)
  }

  private var stepsList: some View {
    VStack(spacing: 12) {
      ForEach(EnhancementStep.allCases, id: \.self) { step in
        if let data = debugManager.stepData[step] {
          StepDetailView(data: data)
        }
      }
    }
  }
}

struct StepProgressView: View {
  let currentStep: EnhancementStep

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Progress")
        .font(.system(size: 12, weight: .medium))

      HStack(spacing: 12) {
        ForEach(EnhancementStep.allCases, id: \.self) { step in
          if step != .idle {
            StepIndicator(step: step, currentStep: currentStep)
            if step != .enhancing {
              Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
            }
          }
        }
      }
    }
    .padding(12)
    .background(Color.secondary.opacity(0.05))
    .cornerRadius(8)
  }
}

struct StepIndicator: View {
  let step: EnhancementStep
  let currentStep: EnhancementStep

  var body: some View {
    VStack(spacing: 4) {
      Circle()
        .fill(indicatorColor)
        .frame(width: 8, height: 8)

      Text(step.shortName)
        .font(.system(size: 9))
        .foregroundColor(.secondary)
    }
  }

  private var indicatorColor: Color {
    if step == currentStep {
      return .blue
    }
    return step.rawValue < currentStep.rawValue ? .green : .secondary.opacity(0.3)
  }
}

struct StepDetailView: View {
  let data: EnhancementDebugData
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      if isExpanded {
        content
      }
    }
    .padding(12)
    .background(Color.secondary.opacity(0.05))
    .cornerRadius(8)
  }

  private var header: some View {
    Button(action: { isExpanded.toggle() }) {
      HStack {
        Circle()
          .fill(stepColor)
          .frame(width: 6, height: 6)
        Text(data.step.displayName)
          .font(.system(size: 12, weight: .medium))
        Spacer()
        if let duration = data.duration {
          Text(String(format: "%.1fs", duration))
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
        Image(systemName: "chevron.right")
          .font(.system(size: 9))
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .foregroundColor(.secondary)
      }
    }
    .buttonStyle(.plain)
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 12) {
      switch data.step {
      case .transcribingNotes:
        if let output = data.output {
          ExpandableSection(title: "Transcript Notes", content: output)
        }
      case .findingEmphasis:
        if let output = data.output {
          ExpandableSection(title: "Points of Emphasis", content: output)
        }
      case .extractingActions:
        if let output = data.output {
          ExpandableSection(title: "Action Items", content: output)
        }
      case .enhancing:
        if let output = data.output {
          ExpandableSection(title: "Enhanced Notes", content: output)
        }
      default:
        if let output = data.output {
          ExpandableSection(title: "Output", content: output)
        }
      }

      if let thoughts = data.thoughts {
        ExpandableSection(title: "Thoughts", content: thoughts)
      }

      if let error = data.error {
        ExpandableSection(
          title: "Error",
          content: error,
          textColor: .red
        )
      }
    }
    .padding(.leading, 12)
    .transition(.opacity)
  }

  private var stepColor: Color {
    if data.error != nil {
      return .red
    }
    if data.duration != nil {
      return .green
    }
    return .blue
  }
}

struct ExpandableSection: View {
  let title: String
  let content: String
  var textColor: Color = .secondary
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button(action: { isExpanded.toggle() }) {
        HStack {
          Text(title)
            .font(.system(size: 11))
            .foregroundColor(textColor)
          Spacer()
          Image(systemName: "chevron.right")
            .font(.system(size: 9))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .foregroundColor(.secondary)
        }
      }
      .buttonStyle(.plain)

      if isExpanded {
        Text(content)
          .font(.system(size: 11))
          .foregroundColor(textColor)
          .textSelection(.enabled)
          .padding(.top, 4)
          .transition(.opacity)
      }
    }
  }
}
