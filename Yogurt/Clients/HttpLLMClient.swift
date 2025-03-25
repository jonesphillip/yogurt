import Foundation
import OSLog

enum AIModel {
  case DS  // Deepseek
  case L  // Llama 3.3 70B (or other non-reasoning model)

  func parseResponse(_ data: Data) throws -> (thoughts: String?, content: String) {
    guard let responseText = String(data: data, encoding: .utf8) else {
      throw AIClientError.invalidResponse
    }
    let fullText =
      responseText
      .components(separatedBy: "\n")
      .compactMap { line -> String? in
        guard line.hasPrefix("data: ") else { return nil }
        let jsonStr = String(line.dropFirst(6))
        guard let data = jsonStr.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let response = json["response"] as? String
        else {
          return nil
        }
        return response
      }
      .joined()

    switch self {
    case .DS:
      if let endIndex = fullText.range(of: "</think>") {
        let thoughts = String(fullText[..<endIndex.lowerBound])
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let content = String(fullText[endIndex.upperBound...])
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return (thoughts: thoughts, content: content)
      }
      return (thoughts: nil, content: fullText)

    case .L:
      return (thoughts: nil, content: fullText)
    }
  }
}

enum AIClientError: Error {
  case invalidURL
  case invalidResponse
  case networkError(Error)
  case serverError(statusCode: Int, retryCount: Int)
  case maxRetriesExceeded(statusCode: Int)
}

/// The built-in retry configuration.
struct RetryConfig {
  let maxRetries: Int
  let initialDelay: TimeInterval
  let shouldRetry: (Int) -> Bool

  static let `default` = RetryConfig(
    maxRetries: 3,
    initialDelay: 1.0,
    shouldRetry: { statusCode in
      (500...599).contains(statusCode)
    }
  )
}

/// A delegate for streaming text output (unchanged from your original).
protocol EnhancementStreamDelegate {
  func didReceiveContent(content: String)
  func didReceiveThoughts(thoughts: String)
  func didReceiveStepOutput(step: EnhancementStep, output: String, thoughts: String?)
  func didComplete()
  func didFail(error: Error)
}

class HttpLLMClient {
  static let shared = HttpLLMClient()
  private let logger = Logger(subsystem: kAppSubsystem, category: "HttpLLMClient")
  private let cloudflareService = CloudflareService.shared
  private let retryConfig: RetryConfig

  private init(retryConfig: RetryConfig = .default) {
    self.retryConfig = retryConfig
  }

  // MARK: - LLMProvider Implementation

  /// Non-streaming request for a final chunk of text
  func sendRequest(
    to endpoint: String,
    baseURL: URL?,
    body: [String: String],
    step: EnhancementStep,
    delegate: EnhancementStreamDelegate?,
    model: AIModel
  ) async throws -> String {
    guard let actualBaseURL = baseURL else {
      throw AIClientError.invalidURL
    }

    var currentRetry = 0
    while true {
      do {
        return try await performRequest(
          to: endpoint,
          baseURL: actualBaseURL,
          body: body,
          step: step,
          delegate: delegate,
          model: model
        )
      } catch AIClientError.serverError(let statusCode, _)
        where retryConfig.shouldRetry(statusCode)
      {
        currentRetry += 1
        if currentRetry >= retryConfig.maxRetries {
          throw AIClientError.maxRetriesExceeded(statusCode: statusCode)
        }
        let delay = retryConfig.initialDelay * pow(2.0, Double(currentRetry - 1))
        logger.info(
          "Request failed with status \(statusCode). Retrying in \(delay) seconds (attempt \(currentRetry + 1)/\(self.retryConfig.maxRetries))"
        )
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        continue
      }
    }
  }

  /// Streaming request that returns partial content
  func sendStreamingRequest(
    to endpoint: String,
    baseURL: URL?,
    body: [String: String],
    model: AIModel,
    delegate: EnhancementStreamDelegate
  ) {
    guard let actualBaseURL = baseURL else {
      delegate.didFail(error: AIClientError.invalidURL)
      return
    }

    do {
      let url = try buildURL(endpoint, baseURL: actualBaseURL)
      let request = try createRequest(url: url, body: body)

      let sessionConfig = URLSessionConfiguration.default
      let session = URLSession(
        configuration: sessionConfig,
        delegate: AIStreamDelegate(
          model: model,
          delegate: delegate,
          retryConfig: retryConfig,
          request: request,
          retriesRemaining: retryConfig.maxRetries
        ),
        delegateQueue: nil
      )
      let task = session.dataTask(with: request)
      task.resume()

    } catch {
      delegate.didFail(error: error)
    }
  }

  // MARK: - Internals

  private func performRequest(
    to endpoint: String,
    baseURL: URL,
    body: [String: String],
    step: EnhancementStep,
    delegate: EnhancementStreamDelegate?,
    model: AIModel
  ) async throws -> String {
    let url = try buildURL(endpoint, baseURL: baseURL)
    let request = try createRequest(url: url, body: body)

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        throw AIClientError.invalidResponse
      }

      if !(200...299).contains(httpResponse.statusCode) {
        throw AIClientError.serverError(statusCode: httpResponse.statusCode, retryCount: 0)
      }

      let result = try model.parseResponse(data)
      // If the delegate is set, inform it.
      delegate?.didReceiveStepOutput(step: step, output: result.content, thoughts: result.thoughts)
      return result.content

    } catch let error as AIClientError {
      throw error
    } catch {
      logger.error("Request failed: \(error.localizedDescription)")
      throw AIClientError.networkError(error)
    }
  }

  private func buildURL(_ endpoint: String, baseURL: URL) throws -> URL {
    guard let fullURL = URL(string: endpoint, relativeTo: baseURL) else {
      throw AIClientError.invalidURL
    }
    return fullURL
  }

  private func createRequest(url: URL, body: [String: Any]) throws -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    cloudflareService.prepareRequest(&request)
    return request
  }
}

/// This delegate’s job is to parse SSE lines and call our `EnhancementStreamDelegate`.
class AIStreamDelegate: NSObject, URLSessionDataDelegate {
  private var delegate: EnhancementStreamDelegate?
  private let model: AIModel
  private var partialBuffer = Data()
  private var thoughtBuffer = ""
  private var contentBuffer = ""
  private var isProcessingThoughts = true
  private var isFirstAfterThoughts = false
  private let logger = Logger(subsystem: kAppSubsystem, category: "AIStreamDelegate")
  private let retryConfig: RetryConfig
  private let request: URLRequest
  private var retriesRemaining: Int
  private var hasCompleted = false

  init(
    model: AIModel,
    delegate: EnhancementStreamDelegate,
    retryConfig: RetryConfig,
    request: URLRequest,
    retriesRemaining: Int
  ) {
    self.model = model
    self.delegate = delegate
    self.retryConfig = retryConfig
    self.request = request
    self.retriesRemaining = retriesRemaining
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    partialBuffer.append(data)

    // Process complete lines in the buffer
    while let newlineRange = partialBuffer.range(of: Data([0x0A])) {
      let lineData = partialBuffer.subdata(in: 0..<newlineRange.lowerBound)
      partialBuffer.removeSubrange(0..<(newlineRange.upperBound))

      guard
        let lineStr = String(data: lineData, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !lineStr.isEmpty
      else { continue }

      // Check for SSE event prefix and handle as proper SSE message
      if lineStr.hasPrefix("data: ") {
        let eventData = String(lineStr.dropFirst(6))

        // Handle special DONE message
        if eventData == "[DONE]" {
          if !hasCompleted {
            hasCompleted = true
            delegate?.didComplete()
          }
          return
        }

        // Parse the JSON content
        guard let data = eventData.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let response = json["response"] as? String
        else {
          logger.error("Failed to parse JSON from line: \(eventData)")
          continue
        }

        // Skip empty responses to avoid unnecessary updates
        if response.isEmpty {
          continue
        }

        // Handle model-specific processing
        if case .DS = model, isProcessingThoughts {
          if response.contains("</think>") {
            isProcessingThoughts = false
            isFirstAfterThoughts = true
            let components = response.components(separatedBy: "</think>")
            let thoughts = (thoughtBuffer + components[0])
              .trimmingCharacters(in: .whitespacesAndNewlines)
            delegate?.didReceiveThoughts(thoughts: thoughts)

            if components.count > 1 {
              let content = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
              if !content.isEmpty {
                contentBuffer += content
                delegate?.didReceiveContent(content: content)
                isFirstAfterThoughts = false
              }
            }
            thoughtBuffer = ""
          } else {
            thoughtBuffer += response
          }
        } else {
          // For non-thoughts content, accumulate and send
          contentBuffer += response
          delegate?.didReceiveContent(content: response)
          isFirstAfterThoughts = false
        }
      } else {
        // Handle non-data lines
        logger.debug("Received non-data SSE line: \(lineStr)")
      }
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    if let error = error {
      logger.error("Stream completed with error: \(error.localizedDescription)")
      delegate?.didFail(error: error)
    } else {
      logger.debug("Stream completed successfully")
      if !hasCompleted {
        hasCompleted = true
        delegate?.didComplete()
      }
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let httpResponse = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      delegate?.didFail(error: AIClientError.invalidResponse)
      return
    }

    if retryConfig.shouldRetry(httpResponse.statusCode) {
      completionHandler(.cancel)
      handleRetry(session: session, statusCode: httpResponse.statusCode)
      return
    }

    completionHandler(.allow)
  }

  private func handleRetry(session: URLSession, statusCode: Int) {
    guard retriesRemaining > 0 else {
      delegate?.didFail(error: AIClientError.maxRetriesExceeded(statusCode: statusCode))
      return
    }
    retriesRemaining -= 1
    let delay =
      retryConfig.initialDelay
      * pow(2.0, Double(retryConfig.maxRetries - retriesRemaining - 1))

    logger.info(
      "Stream failed with status \(statusCode). Retrying in \(delay)s (attempt \(self.retryConfig.maxRetries - self.retriesRemaining)/\(self.retryConfig.maxRetries))"
    )
    Task {
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      let task = session.dataTask(with: request)
      task.resume()
    }
  }
}
