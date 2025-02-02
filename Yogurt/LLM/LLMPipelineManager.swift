import Foundation
import OSLog
import SwiftUI

// A delegate protocol for LLM pipeline events
protocol LLMPipelineDelegate {
  func pipelineDidStart()
  func pipelineDidUpdateStep(_ step: EnhancementStep)
  func pipelineDidReceiveContent(content: String)
  func pipelineDidComplete()
  func pipelineDidFail(error: Error)
}

// Manager for handling the entire LLM processing pipeline
class LLMPipelineManager: ObservableObject {
  static let shared = LLMPipelineManager()

  private let logger = Logger(subsystem: kAppSubsystem, category: "LLMPipelineManager")
  private let noteManager = NoteManager.shared
  private let debugManager = DebugManager.shared
  private var enhancementProgress: EnhancementProgress = .init()
  private let client = HttpLLMClient.shared

  var delegate: LLMPipelineDelegate?

  // Starts the enhancement pipeline for a specific note
  func enhanceNote(_ note: Note, transcript: String) {
    debugManager.reset()

    // Update note state - mark as enhancing and clear any previous states
    DispatchQueue.main.async {
      self.noteManager.clearStates()
      self.noteManager.clearPendingTranscript(noteId: note.id)

      self.noteManager.updateEnhancingState(noteId: note.id)
      self.debugManager.startStep(.transcribingNotes)
      self.delegate?.pipelineDidStart()
      self.delegate?.pipelineDidUpdateStep(.transcribingNotes)

      self.noteManager.refreshNotes()
    }

    // Start the enhancement process
    Task {
      do {
        let baseURL = try getValidatedBaseURL()
        let (_, content) = try await noteManager.getNote(withId: note.id)

        // Step 1: Create transcript notes
        try await processTranscriptionNotes(transcript: transcript, baseURL: baseURL)

        // Step 2: Points of emphasis
        try await processPointsOfEmphasis(content: content, baseURL: baseURL)

        // Step 3: Action items
        try await processActionItems(content: content, baseURL: baseURL)

        // Step 4: Final enhanced notes
        processEnhancedNotes(content: content, baseURL: baseURL)

      } catch {
        handleStepError(error, step: debugManager.currentStep)
      }
    }
  }

  // Finalizes the enhancement process and saves the result
  func finishEnhancement(enhancedContent: String, forNote note: Note, originalContent: String) {
    Task { @MainActor in
      self.noteManager.clearStates()
      self.noteManager.clearPendingTranscript(noteId: note.id)
      self.debugManager.completeStep(.enhancing)

      do {
        // Save the pre-enhancement version
        let preVersion = try self.noteManager.createVersion(
          forNote: note,
          content: originalContent
        )
        self.logger.info("Created pre-enhancement version: \(preVersion.id)")

        // Update note with enhanced content
        try self.noteManager.updateNote(note, withContent: enhancedContent)

        self.noteManager.refreshNotes()
      } catch {
        self.logger.error("Failed to save final enhancement: \(error.localizedDescription)")
        self.debugManager.setStepError(.enhancing, error: error.localizedDescription)
        self.delegate?.pipelineDidFail(error: error)
      }
    }
  }

  // MARK: - Pipeline step helpers

  private func processTranscriptionNotes(transcript: String, baseURL: URL) async throws {
    await MainActor.run {
      self.debugManager.startStep(.transcribingNotes)
    }

    do {
      enhancementProgress.transcriptionNotes = try await client.sendRequest(
        to: "transcription-notes",
        baseURL: baseURL,
        body: ["transcript": transcript],
        step: .transcribingNotes,
        delegate: self,
        model: .L
      )

      await MainActor.run {
        self.debugManager.completeStep(.transcribingNotes)
        self.delegate?.pipelineDidUpdateStep(.findingEmphasis)
      }
    } catch {
      handleStepError(error, step: .transcribingNotes)
      throw error
    }
  }

  private func processPointsOfEmphasis(content: String, baseURL: URL) async throws {
    await MainActor.run {
      self.debugManager.startStep(.findingEmphasis)
    }

    do {
      enhancementProgress.pointsOfEmphasis = try await client.sendRequest(
        to: "points-of-emphasis",
        baseURL: baseURL,
        body: [
          "userNotes": content,
          "transcriptNotes": enhancementProgress.transcriptionNotes,
        ],
        step: .findingEmphasis,
        delegate: self,
        model: .L
      )

      await MainActor.run {
        self.debugManager.completeStep(.findingEmphasis)
        self.delegate?.pipelineDidUpdateStep(.extractingActions)
      }
    } catch {
      handleStepError(error, step: .findingEmphasis)
      throw error
    }
  }

  private func processActionItems(content: String, baseURL: URL) async throws {
    await MainActor.run {
      self.debugManager.startStep(.extractingActions)
    }

    do {
      enhancementProgress.actionItems = try await client.sendRequest(
        to: "action-items",
        baseURL: baseURL,
        body: [
          "userNotes": content,
          "transcriptNotes": enhancementProgress.transcriptionNotes,
        ],
        step: .extractingActions,
        delegate: self,
        model: .L
      )

      await MainActor.run {
        self.debugManager.completeStep(.extractingActions)
        self.delegate?.pipelineDidUpdateStep(.enhancing)
      }
    } catch {
      handleStepError(error, step: .extractingActions)
      throw error
    }
  }

  private func processEnhancedNotes(content: String, baseURL: URL) {
    Task { @MainActor in
      self.debugManager.startStep(.enhancing)

      client.sendStreamingRequest(
        to: "final-notes",
        baseURL: baseURL,
        body: [
          "userNotes": content,
          "transcriptNotes": enhancementProgress.transcriptionNotes,
          "pointsOfEmphasis": enhancementProgress.pointsOfEmphasis,
          "actionItems": enhancementProgress.actionItems,
        ],
        model: .L,
        delegate: self
      )
    }
  }

  private func getValidatedBaseURL() throws -> URL {
    guard let baseURL = CloudflareService.shared.getWorkerURL() else {
      throw NSError(
        domain: "EnhancementError",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Cloudflare Worker URL not configured"]
      )
    }
    return baseURL
  }

  private func handleStepError(_ error: Error, step: EnhancementStep) {
    DispatchQueue.main.async {
      // Ensure all debug manager updates happen on the main thread
      if self.debugManager.stepData[step] == nil {
        self.debugManager.startStep(step)
      }
      self.debugManager.setStepError(step, error: error.localizedDescription)
      self.noteManager.clearStates()
      self.delegate?.pipelineDidFail(error: error)
    }
  }
}

extension LLMPipelineManager: EnhancementStreamDelegate {
  func didReceiveStepOutput(step: EnhancementStep, output: String, thoughts: String?) {
    DispatchQueue.main.async {
      // Make sure the step exists before updating it
      if self.debugManager.stepData[step] == nil {
        self.debugManager.startStep(step)
      }

      if let thoughts = thoughts {
        self.debugManager.updateStepThoughts(step, thoughts: thoughts)
      }
      self.debugManager.updateStepOutput(step, output: output)
    }
  }

  func didReceiveContent(content: String) {
    DispatchQueue.main.async {
      self.delegate?.pipelineDidReceiveContent(content: content)

      if self.debugManager.stepData[.enhancing] != nil {
        let currentOutput = self.debugManager.stepData[.enhancing]?.output ?? ""
        self.debugManager.updateStepOutput(.enhancing, output: currentOutput + content)
      } else {
        self.debugManager.startStep(.enhancing)
        self.debugManager.updateStepOutput(.enhancing, output: content)
      }
    }
  }

  func didReceiveThoughts(thoughts: String) {
    DispatchQueue.main.async {
      if self.debugManager.stepData[.enhancing] == nil {
        self.debugManager.startStep(.enhancing)
      }
      self.debugManager.updateStepThoughts(.enhancing, thoughts: thoughts)
    }
  }

  func didComplete() {
    DispatchQueue.main.async {
      if self.debugManager.stepData[.enhancing] == nil {
        self.debugManager.startStep(.enhancing)
      }
      let enhancedContent = self.debugManager.stepData[.enhancing]?.output ?? ""

      // Notify the delegate that the process is complete with the final content
      self.delegate?.pipelineDidComplete()
    }
  }

  func didFail(error: Error) {
    handleStepError(error, step: .enhancing)
  }
}
