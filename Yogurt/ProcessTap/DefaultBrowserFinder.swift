import AppKit
import AudioToolbox
import Foundation
import OSLog

struct BrowserProcessNotFoundError: Error, LocalizedError {
  var errorDescription: String? {
    "Could not find a running audio process for the default browser."
  }
}

final class DefaultBrowserFinder {

  private let logger = Logger(subsystem: kAppSubsystem, category: "DefaultBrowserFinder")

  func findDefaultBrowserProcess() throws -> AudioProcess {
    guard let testURL = URL(string: "https://www.example.com") else {
      throw BrowserProcessNotFoundError()
    }
    guard let browserAppURL = NSWorkspace.shared.urlForApplication(toOpen: testURL) else {
      throw BrowserProcessNotFoundError()
    }

    let browserBundleID = Bundle(url: browserAppURL)?.bundleIdentifier
    logger.info("Default browser bundle ID: \(browserBundleID ?? "unknown", privacy: .public)")

    if browserBundleID == "com.apple.Safari" {
      return try findSafariGPUProcess()
    }

    let runningApps = NSWorkspace.shared.runningApplications
    let candidateApp = runningApps.first {
      if let bid = browserBundleID {
        return $0.bundleIdentifier == bid
      } else {
        return $0.bundleURL == browserAppURL
      }
    }

    guard let browserApp = candidateApp else {
      throw BrowserProcessNotFoundError()
    }

    let pid = browserApp.processIdentifier
    let processObjectIDs = try AudioObjectID.system.readProcessList()

    for objID in processObjectIDs {
      do {
        var address = AudioObjectPropertyAddress(
          mSelector: kAudioProcessPropertyPID,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain
        )
        var readPID: pid_t = -1
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        let err = AudioObjectGetPropertyData(objID, &address, 0, nil, &dataSize, &readPID)
        if err == noErr, readPID == pid {
          let name = browserApp.localizedName ?? "Browser"
          return AudioProcess(
            id: pid,
            name: name,
            bundleURL: browserApp.bundleURL,
            sourceType: .process(objID)
          )
        }
        if err != noErr {
          throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
      } catch {
        logger.error(
          "Could not read PID for \(objID): \(error.localizedDescription, privacy: .public)")
      }
    }

    throw BrowserProcessNotFoundError()
  }

  var isDefaultBrowserChrome: Bool {
    guard let testURL = URL(string: "https://www.example.com"),
      let browserAppURL = NSWorkspace.shared.urlForApplication(toOpen: testURL),
      let bundleID = Bundle(url: browserAppURL)?.bundleIdentifier
    else {
      return false
    }
    return bundleID.contains("com.google.Chrome")
  }

  /// Finds Safari's GPU/Media process
  func findSafariGPUProcess() throws -> AudioProcess {
    let safariGPUBundleID = "com.apple.WebKit.GPU"

    let runningApps = NSWorkspace.shared.runningApplications
    guard
      let gpuApp = runningApps.first(where: {
        $0.bundleIdentifier == safariGPUBundleID && $0.localizedName == "Safari Graphics and Media"
      })
    else {
      throw BrowserProcessNotFoundError()
    }

    let pid = gpuApp.processIdentifier
    let processObjectIDs = try AudioObjectID.system.readProcessList()

    for objID in processObjectIDs {
      do {
        var address = AudioObjectPropertyAddress(
          mSelector: kAudioProcessPropertyPID,
          mScope: kAudioObjectPropertyScopeGlobal,
          mElement: kAudioObjectPropertyElementMain
        )
        var readPID: pid_t = -1
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        let err = AudioObjectGetPropertyData(objID, &address, 0, nil, &dataSize, &readPID)
        if err == noErr, readPID == pid {
          return AudioProcess(
            id: pid,
            name: "Safari Graphics and Media",
            bundleURL: gpuApp.bundleURL,
            sourceType: .process(objID))
        }
        if err != noErr {
          throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }
      } catch {
        logger.error(
          "Could not read PID for \(objID): \(error.localizedDescription, privacy: .public)")
      }
    }

    throw BrowserProcessNotFoundError()
  }
}
