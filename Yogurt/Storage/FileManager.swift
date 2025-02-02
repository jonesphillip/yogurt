import Foundation
import OSLog

class NoteFileManager {
  static let shared = NoteFileManager()
  private let logger = Logger(subsystem: kAppSubsystem, category: "FileManager")

  private let fileManager = FileManager.default
  private(set) var yogurtDirectory: URL? = nil

  private init() {
    setupYogurtDirectory()
  }

  private func setupYogurtDirectory() {
    guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
    else {
      logger.error("Could not access Documents directory")
      return
    }

    let yogurtDir = documents.appendingPathComponent("Yogurt Notes", isDirectory: true)
    let archiveDir = yogurtDir.appendingPathComponent(".archive", isDirectory: true)

    do {
      if !fileManager.fileExists(atPath: yogurtDir.path) {
        try fileManager.createDirectory(at: yogurtDir, withIntermediateDirectories: true)
      }
      if !fileManager.fileExists(atPath: archiveDir.path) {
        try fileManager.createDirectory(at: archiveDir, withIntermediateDirectories: true)
      }
      yogurtDirectory = yogurtDir
      logger.info("Yogurt directories setup at: \(yogurtDir.path)")
    } catch {
      logger.error("Failed to create Yogurt directories: \(error.localizedDescription)")
    }
  }

  private func sanitizeFilename(_ filename: String) -> String {
    // Remove or replace invalid characters
    let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
    let sanitized = filename.components(separatedBy: invalidCharacters).joined(separator: "-")

    // Trim whitespace and dots
    let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))

    // Ensure we have a valid filename
    return trimmed.isEmpty ? "Untitled" : trimmed
  }

  private func getNoteDirectory(forId id: String) throws -> URL {
    guard let yogurtDir = yogurtDirectory else {
      throw NoteFileManagerError.directoryNotFound
    }

    let noteDir = yogurtDir.appendingPathComponent(id, isDirectory: true)

    if !fileManager.fileExists(atPath: noteDir.path) {
      try fileManager.createDirectory(at: noteDir, withIntermediateDirectories: true)
    }

    return noteDir
  }

  private func getCurrentNoteFile(inDirectory noteDir: URL, title: String) -> URL {
    let safeTitle = sanitizeFilename(title)
    return noteDir.appendingPathComponent("\(safeTitle).md")
  }

  func saveNote(_ content: String, withId id: String, title: String) throws {
    let noteDir = try getNoteDirectory(forId: id)
    let newFile = getCurrentNoteFile(inDirectory: noteDir, title: title)

    // Try to find any existing note file in the directory
    do {
      let files = try fileManager.contentsOfDirectory(at: noteDir, includingPropertiesForKeys: nil)
      let currentFiles = files.filter { file in
        let filename = file.lastPathComponent
        // Match our specific versioning pattern: " (YYYY-MM-DD HH.mm.ss).md"
        let versionPattern = #" \(\d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}\)\.md$"#
        return filename.hasSuffix(".md")
          && filename.matches(of: try! Regex(versionPattern)).isEmpty  // Not a versioned file
          && filename != ".DS_Store"
      }

      if let existingFile = currentFiles.first {
        if existingFile.lastPathComponent != newFile.lastPathComponent {
          // If the filename would change, move the file
          try fileManager.moveItem(at: existingFile, to: newFile)
          logger.info(
            "Renamed note file from \(existingFile.lastPathComponent) to \(newFile.lastPathComponent)"
          )
        }
      }

      // Save content to the file (whether it was renamed or not)
      try content.write(to: newFile, atomically: true, encoding: .utf8)
      logger.info("Saved note content: \(id)")
    } catch {
      logger.error("Failed to save/rename note \(id): \(error.localizedDescription)")
      throw NoteFileManagerError.saveFailed(error)
    }
  }

  func getFileUrl(forId id: String, title: String) throws -> URL {
    let noteDir = try getNoteDirectory(forId: id)
    return getCurrentNoteFile(inDirectory: noteDir, title: title)
  }

  func readNote(withId id: String, title: String) throws -> String {
    let noteDir = try getNoteDirectory(forId: id)
    let noteFile = getCurrentNoteFile(inDirectory: noteDir, title: title)

    do {
      let content = try String(contentsOf: noteFile, encoding: .utf8)
      logger.debug("Read note: \(id)")
      return content
    } catch {
      logger.error("Failed to read note \(id): \(error.localizedDescription)")
      throw NoteFileManagerError.readFailed(error)
    }
  }

  func deleteNote(withId id: String) throws {
    guard let yogurtDir = yogurtDirectory else {
      throw NoteFileManagerError.directoryNotFound
    }

    let noteDir = yogurtDir.appendingPathComponent(id)

    do {
      if fileManager.fileExists(atPath: noteDir.path) {
        try fileManager.removeItem(at: noteDir)
      }
      logger.info("Deleted note directory: \(id)")
    } catch {
      logger.error("Failed to delete note \(id): \(error.localizedDescription)")
      throw NoteFileManagerError.deleteFailed(error)
    }
  }

  func createVersion(forId id: String, content: String) throws
    -> NoteVersion
  {
    let versionsDir = try getVersionsDirectory(forId: id)
    let versionId = UUID()
    let version = NoteVersion(
      id: versionId,
      timestamp: Date(),
      filePath: "\(versionId).md"
    )

    // Save version content
    let versionFile = versionsDir.appendingPathComponent(version.filePath)
    try content.write(to: versionFile, atomically: true, encoding: .utf8)

    // Save version metadata to database
    try DatabaseManager.shared.saveVersion(version, forNoteId: id)

    return version
  }

  func getVersionContent(forId id: String, version: NoteVersion) throws -> String {
    let versionsDir = try getVersionsDirectory(forId: id)
    let versionFile = versionsDir.appendingPathComponent(version.filePath)
    return try String(contentsOf: versionFile, encoding: .utf8)
  }

  private func getVersionsDirectory(forId id: String) throws -> URL {
    let noteDir = try getNoteDirectory(forId: id)
    let versionsDir = noteDir.appendingPathComponent("versions", isDirectory: true)

    if !fileManager.fileExists(atPath: versionsDir.path) {
      try fileManager.createDirectory(at: versionsDir, withIntermediateDirectories: true)
    }

    return versionsDir
  }

  func getVersions(forId id: String) throws -> [NoteVersion] {
    return try DatabaseManager.shared.getVersions(forNoteId: id)
  }
}
