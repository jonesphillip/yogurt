import OSLog
import SwiftUI

// MARK: - Endpoint Testing Types
enum EndpointStatus: Equatable {
  case idle
  case testing
  case success
  case failure(message: String)
}

struct EndpointTest: Identifiable {
  let id = UUID()
  let path: String
  let description: String
  var status: EndpointStatus = .idle
}

struct CloudflareConfigView: View {
  @Environment(\.dismiss) private var dismiss

  @State private var workerURL: String = ""
  @State private var clientId: String = ""
  @State private var clientSecret: String = ""
  @State private var globalMessage: String?
  @State private var isTestingAll: Bool = false

  @State private var endpoints: [EndpointTest] = [
    EndpointTest(
      path: "transcription-notes",
      description: "Convert transcript to comprehensive notes"
    ),
    EndpointTest(
      path: "points-of-emphasis",
      description: "Identify common points between notes"
    ),
    EndpointTest(
      path: "action-items",
      description: "Extract actionable items"
    ),
    EndpointTest(
      path: "final-notes",
      description: "Generate enhanced final notes"
    ),
  ]

  private let logger = Logger(subsystem: kAppSubsystem, category: "CloudflareConfigView")

  var body: some View {
    VStack(spacing: 0) {
      ScrollView(showsIndicators: false) {
        VStack(spacing: 24) {
          introSection
          configurationSection
          Divider()
          endpointsSection
          Spacer(minLength: 24)
        }
        .padding(20)
      }

      footer
    }
    .frame(width: 580, height: 610)
    .background(Color(NSColor.windowBackgroundColor))
    .onAppear { loadCurrentConfig() }
  }

  private var introSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Cloudflare Worker Setup")
        .font(.system(size: 15, weight: .semibold))

      HStack(spacing: 4) {
        Text("Configure your Worker endpoint and access credentials.")
          .font(.system(size: 12))
          .foregroundColor(.secondary)

        Link(
          "View reference implementation",
          destination: URL(string: "https://github.com/jonesphillip/yogurt-worker")!
        )
        .font(.system(size: 12))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var configurationSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Worker URL")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(.secondary)

        TextField("https://your-worker.worker.dev", text: $workerURL)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 13))
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Access Service Token (Optional)")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(.secondary)

        VStack(spacing: 6) {
          TextField("Client ID", text: $clientId)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13))

          SecureField("Client Secret", text: $clientSecret)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13))
        }
      }

      if let message = globalMessage {
        Text(message)
          .font(.system(size: 12))
          .foregroundColor(message.contains("Success") ? .green : .red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var endpointsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Required Endpoints")
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.secondary)

      VStack(spacing: 6) {
        ForEach(endpoints) { endpoint in
          EndpointStatusRow(endpoint: endpoint)
        }
      }
    }
  }

  private var footer: some View {
    HStack {
      if CloudflareService.shared.isConfigured {
        Button("Clear Configuration", role: .destructive) {
          clearConfiguration()
        }
      }

      Spacer()

      HStack(spacing: 8) {
        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.escape)

        Button(action: testAndSaveConfiguration) {
          if isTestingAll {
            Text(CloudflareService.shared.isConfigured ? "Updating..." : "Testing...")
          } else {
            Text(CloudflareService.shared.isConfigured ? "Update" : "Save")
          }
        }
        .keyboardShortcut(.return)
        .disabled(workerURL.isEmpty || isTestingAll)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(Color(NSColor.controlBackgroundColor))
  }

  // MARK: - Helper Methods
  private func loadCurrentConfig() {
    if let url = CloudflareService.shared.getWorkerURL()?.absoluteString {
      workerURL = url
    }

    if let clientId = CloudflareService.shared.getClientId() {
      self.clientId = clientId
    }

    if let clientSecret = CloudflareService.shared.getClientSecret() {
      self.clientSecret = clientSecret
    }
  }

  private func clearConfiguration() {
    do {
      try CloudflareService.shared.clearConfiguration()
      workerURL = ""
      clientId = ""
      clientSecret = ""
      endpoints.indices.forEach { endpoints[$0].status = .idle }
      globalMessage = nil
    } catch {
      globalMessage = "Failed to clear configuration."
      logger.error("Clear config error: \(error.localizedDescription)")
    }
  }

  private func testPayload(for endpoint: String) -> [String: String] {
    switch endpoint {
    case "transcription-notes":
      return ["transcript": "This is a test transcript."]
    case "points-of-emphasis":
      return [
        "userNotes": "Test note content.",
        "transcriptNotes": "Test transcript notes.",
      ]
    case "action-items":
      return [
        "userNotes": "Test note content.",
        "transcriptNotes": "Test transcript notes.",
      ]
    case "final-notes":
      return [
        "userNotes": "Test note content.",
        "transcriptNotes": "Test transcript notes.",
        "pointsOfEmphasis": "Key points",
        "actionItems": "Action items list",
      ]
    default:
      return [:]
    }
  }

  private func testAndSaveConfiguration() {
    globalMessage = nil
    endpoints.indices.forEach { endpoints[$0].status = .idle }
    isTestingAll = true

    // Normalize the URL
    var normalizedURL = workerURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalizedURL.hasPrefix("http") {
      normalizedURL = "https://" + normalizedURL
    }
    if normalizedURL.hasSuffix("/") {
      normalizedURL.removeLast()
    }

    guard let baseURL = URL(string: normalizedURL) else {
      globalMessage = "Please enter a valid URL."
      isTestingAll = false
      return
    }

    Task {
      await withTaskGroup(of: (Int, Bool, String?).self) { group in
        for idx in endpoints.indices {
          group.addTask {
            return await self.testEndpoint(at: idx, baseURL: baseURL)
          }
        }

        var allPassed = true
        for await (idx, passed, errorMsg) in group {
          if passed {
            updateEndpointStatus(at: idx, to: .success)
          } else {
            updateEndpointStatus(at: idx, to: .failure(message: errorMsg ?? "Unknown error"))
            allPassed = false
          }
        }

        DispatchQueue.main.async {
          isTestingAll = false
          if allPassed {
            do {
              try CloudflareService.shared.configure(
                workerURL: normalizedURL,
                clientId: clientId.isEmpty ? nil : clientId,
                clientSecret: clientSecret.isEmpty ? nil : clientSecret
              )
              globalMessage = "Successfully configured!"

              DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                dismiss()
              }
            } catch {
              globalMessage = "Configuration save failed."
            }
          } else {
            globalMessage = "Some endpoints failed. Please check the error messages below."
          }
        }
      }
    }
  }

  private func testEndpoint(at index: Int, baseURL: URL) async -> (Int, Bool, String?) {
    await MainActor.run {
      updateEndpointStatus(at: index, to: .testing)
    }

    let ep = endpoints[index]
    guard let url = URL(string: ep.path, relativeTo: baseURL) else {
      return (index, false, "Invalid endpoint path.")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let payload = testPayload(for: ep.path)
    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    } catch {
      return (index, false, "Failed to create test payload.")
    }

    if !clientId.isEmpty && !clientSecret.isEmpty {
      request.setValue(clientId, forHTTPHeaderField: "CF-Access-Client-Id")
      request.setValue(clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
    } else if clientId.isEmpty != clientSecret.isEmpty {
      return (index, false, "Both Client ID and Secret must be provided.")
    }

    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        return (index, false, "Invalid response from server.")
      }

      switch httpResponse.statusCode {
      case 200...299:
        return (index, true, nil)
      case 401, 403:
        return (index, false, "Access denied. Please check your credentials.")
      case 404:
        return (index, false, "Endpoint not found. Please check your Worker URL.")
      case 500:
        return (index, false, "Server error. Please check your Worker implementation.")
      default:
        return (index, false, "Unexpected response (Status \(httpResponse.statusCode))")
      }
    } catch {
      if error.localizedDescription.contains("Could not connect") {
        return (index, false, "Could not connect to server. Please check the URL.")
      }
      return (index, false, error.localizedDescription)
    }
  }

  private func updateEndpointStatus(at index: Int, to status: EndpointStatus) {
    endpoints[index].status = status
  }
}

struct EndpointStatusRow: View {
  let endpoint: EndpointTest

  var body: some View {
    HStack(spacing: 12) {
      statusIcon
        .frame(width: 16, height: 16)

      VStack(alignment: .leading, spacing: 2) {
        Text("/\(endpoint.path)")
          .font(.system(size: 13, weight: .medium))

        Text(endpoint.description)
          .font(.system(size: 12))
          .foregroundColor(.secondary)

        if case .failure(let message) = endpoint.status {
          Text(message)
            .font(.system(size: 12))
            .foregroundColor(.red)
            .padding(.top, 2)
        }
      }

      Spacer()
    }
    .padding(10)
    .background(Color(NSColor.controlBackgroundColor))
    .cornerRadius(6)
  }

  private var statusIcon: some View {
    Group {
      switch endpoint.status {
      case .idle:
        Image(systemName: "circle")
          .foregroundColor(.secondary)
      case .testing:
        ProgressView()
          .scaleEffect(0.7)
      case .success:
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.green)
      case .failure:
        Image(systemName: "xmark.circle.fill")
          .foregroundColor(.red)
      }
    }
  }
}

#Preview {
  CloudflareConfigView()
}
