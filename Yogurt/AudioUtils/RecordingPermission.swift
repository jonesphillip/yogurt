import AVFoundation
import OSLog
import Observation
import SwiftUI

@Observable
final class RecordingPermission {
  private let logger = Logger(subsystem: kAppSubsystem, category: "RecordingPermission")

  enum Status {
    case unknown
    case denied
    case authorized
  }

  private(set) var microphoneStatus: Status = .unknown
  private(set) var systemAudioStatus: Status = .unknown

  var areAllPermissionsGranted: Bool {
    microphoneStatus == .authorized && systemAudioStatus == .authorized
  }

  init() {
    updateMicrophoneStatus()
    updateSystemAudioStatus()

    #if ENABLE_TCC_SPI
      NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        self.updateSystemAudioStatus()
      }
    #endif
  }

  func requestMicrophonePermission() async -> Bool {
    logger.debug("Requesting microphone permission...")

    return await withCheckedContinuation { continuation in
      AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
        self?.logger.info("Microphone permission request result: \(granted)")
        DispatchQueue.main.async {
          self?.microphoneStatus = granted ? .authorized : .denied
        }
        continuation.resume(returning: granted)
      }
    }
  }

  func requestSystemAudioPermission() async -> Bool {
    #if ENABLE_TCC_SPI
      logger.debug("Requesting system audio permission...")

      return await withCheckedContinuation { continuation in
        guard let request = Self.requestSPI else {
          logger.fault("Request SPI missing")
          continuation.resume(returning: false)
          return
        }

        request("kTCCServiceAudioCapture" as CFString, nil) { [weak self] granted in
          guard let self else {
            continuation.resume(returning: false)
            return
          }

          self.logger.info("System audio request finished with result: \(granted)")

          DispatchQueue.main.async {
            self.systemAudioStatus = granted ? .authorized : .denied
          }
          continuation.resume(returning: granted)
        }
      }
    #else
      return true
    #endif
  }

  func requestAllPermissions() async -> Bool {
    let micGranted = await requestMicrophonePermission()
    let sysAudioGranted = await requestSystemAudioPermission()
    return micGranted && sysAudioGranted
  }

  private func updateMicrophoneStatus() {
    let currentStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    logger.debug("Current microphone status: \(currentStatus.rawValue)")

    switch currentStatus {
    case .authorized:
      microphoneStatus = .authorized
      logger.info("Microphone access is authorized")
    case .denied, .restricted:
      microphoneStatus = .denied
      logger.info("Microphone access is denied/restricted")
    case .notDetermined:
      microphoneStatus = .unknown
      logger.info("Microphone access is not determined")
    @unknown default:
      microphoneStatus = .unknown
      logger.info("Microphone access status unknown")
    }
  }

  private func updateSystemAudioStatus() {
    #if ENABLE_TCC_SPI
      logger.debug("Updating system audio status")

      guard let preflight = Self.preflightSPI else {
        logger.fault("Preflight SPI missing")
        return
      }

      let result = preflight("kTCCServiceAudioCapture" as CFString, nil)

      systemAudioStatus =
        switch result {
        case 0: .authorized
        case 1: .denied
        default: .unknown
        }
    #else
      systemAudioStatus = .authorized
    #endif
  }

  #if ENABLE_TCC_SPI
    private typealias PreflightFuncType = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFuncType = @convention(c) (
      CFString, CFDictionary?, @escaping (Bool) -> Void
    ) -> Void

    private static let apiHandle: UnsafeMutableRawPointer? = {
      let tccPath = "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"

      guard let handle = dlopen(tccPath, RTLD_NOW) else {
        assertionFailure("dlopen failed")
        return nil
      }

      return handle
    }()

    private static let preflightSPI: PreflightFuncType? = {
      guard let apiHandle else { return nil }

      guard let funcSym = dlsym(apiHandle, "TCCAccessPreflight") else {
        assertionFailure("Couldn't find symbol")
        return nil
      }

      return unsafeBitCast(funcSym, to: PreflightFuncType.self)
    }()

    private static let requestSPI: RequestFuncType? = {
      guard let apiHandle else { return nil }

      guard let funcSym = dlsym(apiHandle, "TCCAccessRequest") else {
        assertionFailure("Couldn't find symbol")
        return nil
      }

      return unsafeBitCast(funcSym, to: RequestFuncType.self)
    }()
  #endif
}
