import Foundation

// Core data model for tracking enhancement process
struct EnhancementDebugData: Equatable {
  let step: EnhancementStep
  let startTime: Date
  let duration: TimeInterval?
  let thoughts: String?
  let output: String?
  let error: String?
}

// Main debug state manager
class DebugManager: ObservableObject {
  static let shared = DebugManager()

  @Published private(set) var currentStep: EnhancementStep = .idle
  @Published private(set) var stepData: [EnhancementStep: EnhancementDebugData] = [:]

  func startStep(_ step: EnhancementStep) {
    currentStep = step
    stepData[step] = EnhancementDebugData(
      step: step,
      startTime: Date(),
      duration: nil,
      thoughts: nil,
      output: nil,
      error: nil
    )
  }

  func completeStep(_ step: EnhancementStep, duration: TimeInterval? = nil) {
    guard var data = stepData[step] else { return }
    data = EnhancementDebugData(
      step: step,
      startTime: data.startTime,
      duration: duration ?? Date().timeIntervalSince(data.startTime),
      thoughts: data.thoughts,
      output: data.output,
      error: data.error
    )
    stepData[step] = data
  }

  func updateStepThoughts(_ step: EnhancementStep, thoughts: String) {
    guard var data = stepData[step] else { return }
    data = EnhancementDebugData(
      step: step,
      startTime: data.startTime,
      duration: data.duration,
      thoughts: thoughts,
      output: data.output,
      error: data.error
    )
    stepData[step] = data
  }

  func updateStepOutput(_ step: EnhancementStep, output: String) {
    guard var data = stepData[step] else { return }
    data = EnhancementDebugData(
      step: step,
      startTime: data.startTime,
      duration: data.duration,
      thoughts: data.thoughts,
      output: output,
      error: data.error
    )
    stepData[step] = data
  }

  func setStepError(_ step: EnhancementStep, error: String) {
    guard var data = stepData[step] else { return }
    data = EnhancementDebugData(
      step: step,
      startTime: data.startTime,
      duration: data.duration,
      thoughts: data.thoughts,
      output: data.output,
      error: error
    )
    stepData[step] = data
  }

  func reset() {
    currentStep = .idle
    stepData.removeAll()
  }
}
