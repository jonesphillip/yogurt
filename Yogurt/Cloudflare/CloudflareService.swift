import Foundation
import OSLog
import Security

class CloudflareService: ObservableObject {
  static let shared = CloudflareService()
  @Published private(set) var isConfigured: Bool = false
  @Published private(set) var hasServiceToken: Bool = false

  private let logger = Logger(subsystem: kAppSubsystem, category: "CloudflareService")

  private let keychainService = "com.pr.projects.Yogurt"
  private let clientIdKey = "cf_access_client_id"
  private let clientSecretKey = "cf_access_client_secret"

  private var cachedWorkerURL: URL?
  private var cachedClientId: String?
  private var cachedClientSecret: String?

  private init() {
    loadCredentials()
  }

  private func loadCredentials() {
    isConfigured = getWorkerURL() != nil
    hasServiceToken = getClientId() != nil && getClientSecret() != nil
  }

  func getWorkerURL() -> URL? {
    if let cached = cachedWorkerURL {
      return cached
    }

    if let urlString = DatabaseManager.shared.getCloudflareWorkerURL(),
      let url = URL(string: urlString)
    {
      cachedWorkerURL = url
      return url
    }
    return nil
  }

  func getClientId() -> String? {
    if let cached = cachedClientId {
      return cached
    }
    return getKeychainString(forKey: clientIdKey)
  }

  func getClientSecret() -> String? {
    if let cached = cachedClientSecret {
      return cached
    }
    return getKeychainString(forKey: clientSecretKey)
  }

  func configure(workerURL: String, clientId: String? = nil, clientSecret: String? = nil) throws {
    // Validate URL
    guard URL(string: workerURL) != nil else {
      throw CloudflareError.invalidURL
    }

    // If service token is provided, both parts must be present
    if clientId != nil || clientSecret != nil {
      guard let cid = clientId, !cid.isEmpty,
        let secret = clientSecret, !secret.isEmpty
      else {
        throw CloudflareError.incompleteServiceToken
      }
    }

    // Save URL to database
    try DatabaseManager.shared.saveCloudflareWorkerURL(workerURL)
    cachedWorkerURL = URL(string: workerURL)

    // Save credentials to keychain if provided
    if let cid = clientId, let secret = clientSecret {
      try saveToKeychain(key: clientIdKey, string: cid)
      try saveToKeychain(key: clientSecretKey, string: secret)
      cachedClientId = cid
      cachedClientSecret = secret
    }

    logger.info("Cloudflare configuration saved successfully")
    loadCredentials()
  }

  func clearConfiguration() throws {
    try DatabaseManager.shared.saveCloudflareWorkerURL(nil)
    try removeFromKeychain(key: clientIdKey)
    try removeFromKeychain(key: clientSecretKey)

    cachedWorkerURL = nil
    cachedClientId = nil
    cachedClientSecret = nil

    logger.info("Cloudflare configuration cleared")
    loadCredentials()
  }

  func prepareRequest(_ request: inout URLRequest) {
    if let clientId = getClientId(),
      let clientSecret = getClientSecret()
    {
      logger.debug("Adding Cloudflare Access authentication headers")

      request.setValue(clientId, forHTTPHeaderField: "CF-Access-Client-Id")
      request.setValue(clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")

      // Verify headers were set
      if let setClientId = request.value(forHTTPHeaderField: "CF-Access-Client-Id"),
        let setClientSecret = request.value(forHTTPHeaderField: "CF-Access-Client-Secret")
      {
        logger.debug("Authentication headers successfully set")
      } else {
        logger.error("Failed to set authentication headers")
      }
    } else {
      logger.debug("No Cloudflare Access credentials configured")
    }
  }

  private func getKeychainString(forKey key: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)

    guard status == errSecSuccess,
      let data = item as? Data,
      let string = String(data: data, encoding: .utf8)
    else {
      return nil
    }

    return string
  }

  private func saveToKeychain(key: String, string: String) throws {
    let data = string.data(using: .utf8)!

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: key,
      kSecValueData as String: data,
    ]

    SecItemDelete(query as CFDictionary)

    let status = SecItemAdd(query as CFDictionary, nil)

    guard status == errSecSuccess else {
      throw CloudflareError.keychainError(status: status)
    }
  }

  private func removeFromKeychain(key: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: key,
    ]

    let status = SecItemDelete(query as CFDictionary)

    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CloudflareError.keychainError(status: status)
    }
  }
}

enum CloudflareError: Error {
  case invalidURL
  case incompleteServiceToken
  case keychainError(status: OSStatus)
}
