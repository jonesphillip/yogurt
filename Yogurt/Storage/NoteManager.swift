import Foundation
import OSLog

struct Note: Codable, Identifiable, Hashable, Equatable {
  let id: String
  var title: String
  var lastModified: Date
  var hasEnhancedVersion: Bool
  var isRecording: Bool = false
  var isEnhancing: Bool = false

  var displayTitle: String {
    return title.isEmpty ? "Untitled Note" : title
  }

  static func == (lhs: Note, rhs: Note) -> Bool {
    return lhs.id == rhs.id && lhs.isRecording == rhs.isRecording
      && lhs.isEnhancing == rhs.isEnhancing
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(isRecording)
    hasher.combine(isEnhancing)
  }
}

class NoteManager: ObservableObject {
  static let shared = NoteManager()
  private let logger = Logger(subsystem: kAppSubsystem, category: "NoteManager")
  private let fileManager = NoteFileManager.shared
  private let dbManager = DatabaseManager.shared
  private var noteStates: [String: (isRecording: Bool, isEnhancing: Bool)] = [:]

  @Published var notes: [Note] = []

  private init() {
    refreshNotes()
  }

  func updateNoteStates(recordingId: String?) {
    logger.debug("Updating recording state for note: \(recordingId ?? "nil")")
    notes = notes.map { note in
      var noteCopy = note
      noteCopy.isRecording = note.id == recordingId
      noteCopy.isEnhancing = false
      noteStates[note.id] = (noteCopy.isRecording, noteCopy.isEnhancing)
      return noteCopy
    }
  }

  func updateEnhancingState(noteId: String?) {
    logger.debug("Updating enhancing state for note: \(noteId ?? "nil")")
    notes = notes.map { note in
      var noteCopy = note
      noteCopy.isRecording = false
      noteCopy.isEnhancing = note.id == noteId
      noteStates[note.id] = (noteCopy.isRecording, noteCopy.isEnhancing)
      return noteCopy
    }
  }

  func clearStates() {
    notes = notes.map { note in
      var noteCopy = note
      noteCopy.isRecording = false
      noteCopy.isEnhancing = false
      return noteCopy
    }
    noteStates.removeAll()
  }

  func refreshNotes() {
    do {
      // Save current states before refresh
      let currentStates = notes.reduce(into: [:]) { dict, note in
        dict[note.id] = (note.isRecording, note.isEnhancing)
      }

      notes = []
      notes = try dbManager.getAllNotes()

      // Restore states after refresh
      notes = notes.map { note in
        var noteCopy = note
        if let states = currentStates[note.id] {
          noteCopy.isRecording = states.0
          noteCopy.isEnhancing = states.1
        }
        return noteCopy
      }

    } catch {
      logger.error("Failed to refresh notes: \(error.localizedDescription)")
    }
  }

  func createNote() -> Note {
    let note = Note(
      id: UUID().uuidString,
      title: "",
      lastModified: Date(),
      hasEnhancedVersion: false
    )

    do {
      try dbManager.insertNote(note)

      try fileManager.saveNote("", withId: note.id, title: note.title)

      logger.info("Created new note: \(note.id)")
    } catch {
      logger.error("Failed to create note: \(error.localizedDescription)")
    }

    refreshNotes()
    return note
  }

  func updateNote(_ note: Note, withContent content: String) throws {
    do {
      if let existingContent = try? fileManager.readNote(withId: note.id, title: note.title),
        existingContent == content
      {
        logger.debug("Content unchanged for note \(note.id), skipping save")
        return
      }
    }

    // Extract title from first line
    let lines = content.components(separatedBy: .newlines)
    let title = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled"

    try fileManager.saveNote(content, withId: note.id, title: title)

    let updatedNote = Note(
      id: note.id,
      title: title,
      lastModified: Date(),
      hasEnhancedVersion: note.hasEnhancedVersion,
      isRecording: note.isRecording,
      isEnhancing: note.isEnhancing
    )
    try dbManager.updateNote(updatedNote)

    refreshNotes()
  }

  func getAllNotes() -> [Note] {
    do {
      return try dbManager.getAllNotes()
    } catch {
      logger.error("Failed to get notes: \(error.localizedDescription)")
      return []
    }
  }

  func getNote(withId id: String) throws -> (note: Note, content: String) {
    guard let note = try dbManager.getNote(withId: id) else {
      throw NoteFileManagerError.noteNotFound
    }

    let content = try fileManager.readNote(withId: id, title: note.title)
    return (note, content)
  }

  func deleteNote(withId id: String) throws {
    try dbManager.deleteNote(withId: id)
    try fileManager.deleteNote(withId: id)
    refreshNotes()
  }

  func getFileUrl(forId id: String) -> URL? {
    guard let note = try? dbManager.getNote(withId: id) else { return nil }
    return try? fileManager.getFileUrl(forId: id, title: note.title)
  }
}
