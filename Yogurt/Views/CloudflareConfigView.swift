import OSLog
import SwiftUI

struct CloudflareConfigView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var workerURL: String = ""
  @State private var clientId: String = ""
  @State private var clientSecret: String = ""
  @State private var errorMessage: String?
  @State private var isLoading = false
  @State private var testStatus: TestStatus?
  @State private var hasExistingToken: Bool = false
  @State private var showingTokenFields: Bool = false

  private let logger = Logger(subsystem: kAppSubsystem, category: "CloudflareConfigView")

  private enum TestStatus {
    case testing
    case success
    case failed(String)
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          VStack(alignment: .leading, spacing: 8) {
            Text("Configure Cloudflare Worker")
              .font(.system(size: 20, weight: .semibold))
              .foregroundColor(.white)

            Text("Yogurt needs a Cloudflare Worker to process audio and enhance your notes")
              .font(.system(size: 14))
              .foregroundColor(.white.opacity(0.9))
              .lineSpacing(4)
          }

          Spacer()

          Image(systemName: "cloud")
            .font(.system(size: 24))
            .foregroundColor(.white.opacity(0.9))
        }
      }
      .padding(24)
      .background(
        LinearGradient(
          gradient: Gradient(colors: [
            Color(red: 0.23, green: 0.49, blue: 0.97),
            Color(red: 0.27, green: 0.42, blue: 0.85),
          ]),
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )

      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Worker URL")
              .font(.system(size: 13, weight: .medium))

            TextField("https://your-worker.worker.dev", text: $workerURL)
              .textFieldStyle(.roundedBorder)
              .font(.system(size: 14))

            Text("Required endpoints: /transcribe, /enhance")
              .font(.system(size: 12))
              .foregroundColor(.secondary)
          }

          VStack(alignment: .leading, spacing: 16) {
            HStack {
              Text("Access Service Token")
                .font(.system(size: 13, weight: .medium))

              if hasExistingToken {
                Text("Configured")
                  .font(.system(size: 12))
                  .foregroundColor(.secondary)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(Color.green.opacity(0.1))
                  .foregroundColor(.green)
                  .cornerRadius(4)
              } else {
                Text("Optional")
                  .font(.system(size: 12))
                  .foregroundColor(.secondary)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 2)
                  .background(Color.secondary.opacity(0.1))
                  .cornerRadius(4)
              }

              Spacer()

              Button {
                NSWorkspace.shared.open(
                  URL(
                    string:
                      "https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/")!)
              } label: {
                Text("Learn more")
                  .font(.system(size: 12))
              }
              .buttonStyle(.link)
            }

            if !hasExistingToken || !clientId.isEmpty || !clientSecret.isEmpty || showingTokenFields
            {
              VStack(alignment: .leading, spacing: 12) {
                TextField("Client ID", text: $clientId)
                  .textFieldStyle(.roundedBorder)
                  .font(.system(size: 14))

                SecureField("Client Secret", text: $clientSecret)
                  .textFieldStyle(.roundedBorder)
                  .font(.system(size: 14))
              }
            } else {
              Button("Update Service Token") {
                showingTokenFields = true
              }
              .font(.system(size: 13))
            }
          }

          if let status = testStatus {
            statusView(status)
          }

          if let error = errorMessage {
            Text(error)
              .font(.system(size: 12))
              .foregroundColor(.red)
          }
        }
        .padding(24)
      }

      // Bottom action bar
      HStack(spacing: 12) {
        if CloudflareService.shared.isConfigured {
          Button(role: .destructive, action: clearConfiguration) {
            Text("Clear Configuration")
              .font(.system(size: 13))
          }
        }

        Spacer()

        Button("Cancel") {
          dismiss()
        }
        .keyboardShortcut(.escape)

        Button(action: testAndSaveConfiguration) {
          HStack {
            if isLoading {
              ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
            }
            Text(CloudflareService.shared.isConfigured ? "Update" : "Test & Save")
          }
        }
        .keyboardShortcut(.return)
        .disabled(workerURL.isEmpty || isLoading)
      }
      .padding(16)
      .background(Color(NSColor.windowBackgroundColor))
      .overlay(
        Rectangle()
          .frame(height: 1)
          .foregroundColor(Color.primary.opacity(0.1)),
        alignment: .top
      )
    }
    .frame(width: 520, height: 560)
    .background(Color(NSColor.windowBackgroundColor))
    .onAppear {
      loadCurrentConfig()
    }
  }

  private func loadCurrentConfig() {
    if let url = CloudflareService.shared.getWorkerURL()?.absoluteString {
      workerURL = url
    }
    hasExistingToken = CloudflareService.shared.hasServiceToken
  }

  private func statusView(_ status: TestStatus) -> some View {
    HStack(spacing: 8) {
      switch status {
      case .testing:
        ProgressView()
          .controlSize(.small)
        Text("Testing connection...")
      case .success:
        Image(systemName: "checkmark.circle.fill")
          .foregroundColor(.green)
        Text("Connection successful!")
      case .failed(let reason):
        Image(systemName: "xmark.circle.fill")
          .foregroundColor(.red)
        Text(reason)
      }
    }
    .font(.system(size: 13))
  }

  private func clearConfiguration() {
    do {
      try CloudflareService.shared.clearConfiguration()
      workerURL = ""
      clientId = ""
      clientSecret = ""
      hasExistingToken = false
      showingTokenFields = false
      testStatus = nil
    } catch {
      errorMessage = "Failed to clear configuration"
      logger.error("Failed to clear configuration: \(error.localizedDescription)")
    }
  }

  private func testAndSaveConfiguration() {
    isLoading = true
    errorMessage = nil
    testStatus = .testing

    var normalizedURL = workerURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalizedURL.hasPrefix("http") {
      normalizedURL = "https://" + normalizedURL
    }
    if normalizedURL.hasSuffix("/") {
      normalizedURL.removeLast()
    }

    guard let baseURL = URL(string: normalizedURL),
      let testURL = URL(string: "enhance", relativeTo: baseURL)
    else {
      errorMessage = "Please enter a valid URL"
      isLoading = false
      testStatus = .failed("Invalid URL format")
      return
    }

    var request = URLRequest(url: testURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let testPayload: [String: String] = ["notes": "Test note", "transcript": ""]
    request.httpBody = try? JSONSerialization.data(withJSONObject: testPayload)

    if !clientId.isEmpty && !clientSecret.isEmpty {
      request.setValue(clientId, forHTTPHeaderField: "CF-Access-Client-Id")
      request.setValue(clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
    } else if clientId.isEmpty != clientSecret.isEmpty {
      errorMessage = "Please provide both Client ID and Secret or neither"
      isLoading = false
      testStatus = .failed("Incomplete service token")
      return
    }

    URLSession.shared.dataTask(with: request) { data, response, error in
      DispatchQueue.main.async {
        if let error = error {
          self.errorMessage = "Connection failed: \(error.localizedDescription)"
          self.testStatus = .failed("Connection error")
          self.isLoading = false
          return
        }

        guard let httpResponse = response as? HTTPURLResponse else {
          self.errorMessage = "Invalid response from server"
          self.testStatus = .failed("Invalid response")
          self.isLoading = false
          return
        }

        switch httpResponse.statusCode {
        case 200...299:
          // Success - save configuration
          do {
            try CloudflareService.shared.configure(
              workerURL: normalizedURL,
              clientId: self.clientId.isEmpty ? nil : self.clientId,
              clientSecret: self.clientSecret.isEmpty ? nil : self.clientSecret
            )
            self.testStatus = .success
            self.hasExistingToken = !self.clientId.isEmpty
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
              self.dismiss()
            }
          } catch {
            self.errorMessage = "Failed to save configuration"
            self.testStatus = .failed("Save failed")
          }

        case 401, 403:
          self.errorMessage = "Access denied. Please check your service token credentials."
          self.testStatus = .failed("Access denied")

        case 500:
          self.errorMessage = "Server error. Please check your Worker implementation."
          self.testStatus = .failed("Server error")

        default:
          self.errorMessage = "Server returned status code: \(httpResponse.statusCode)"
          self.testStatus = .failed("Server error")
        }

        self.isLoading = false
      }
    }.resume()
  }
}
