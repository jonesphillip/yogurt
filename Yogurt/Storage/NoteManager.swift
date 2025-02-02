import Foundation
import OSLog

struct Note: Codable, Identifiable, Hashable, Equatable {
  let id: String
  var title: String
  var lastModified: Date

  // Recording / Enhancement states
  var isRecording: Bool = false
  var isEnhancing: Bool = false

  var hasPendingTranscript: Bool = false

  init(
    id: String,
    title: String,
    lastModified: Date,
    isRecording: Bool = false,
    isEnhancing: Bool = false,
    hasPendingTranscript: Bool = false
  ) {
    self.id = id
    self.title = title
    self.lastModified = lastModified
    self.isRecording = isRecording
    self.isEnhancing = isEnhancing
    self.hasPendingTranscript = hasPendingTranscript
  }

  var displayTitle: String {
    return title.isEmpty ? "Untitled Note" : title
  }

  static func == (lhs: Note, rhs: Note) -> Bool {
    return lhs.id == rhs.id
      && lhs.isRecording == rhs.isRecording
      && lhs.isEnhancing == rhs.isEnhancing
      && lhs.hasPendingTranscript == rhs.hasPendingTranscript
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
    hasher.combine(isRecording)
    hasher.combine(isEnhancing)
    hasher.combine(hasPendingTranscript)
  }
}

class NoteManager: ObservableObject {
  static let shared = NoteManager()
  private let logger = Logger(subsystem: kAppSubsystem, category: "NoteManager")
  private let fileManager = NoteFileManager.shared
  private let dbManager = DatabaseManager.shared

  // Store ephemeral states in memory
  private var noteStates:
    [String: (isRecording: Bool, isEnhancing: Bool, hasPendingTranscript: Bool)] = [:]

  @Published var notes: [Note] = []

  private init() {
    refreshNotes()
  }

  func refreshNotes() {
    do {
      // Save states before refresh
      let currentStates = notes.reduce(into: [:]) {
        $0[$1.id] = ($1.isRecording, $1.isEnhancing, $1.hasPendingTranscript)
      }

      notes = []
      notes = try dbManager.getAllNotes()

      // Restore ephemeral states
      notes = notes.map { note in
        var noteCopy = note
        if let saved = currentStates[note.id] {
          let (isRecording, isEnhancing, hasPendingTranscript) = saved
          noteCopy.isRecording = isRecording
          noteCopy.isEnhancing = isEnhancing
          noteCopy.hasPendingTranscript = hasPendingTranscript
        }

        noteStates[note.id] = (
          noteCopy.isRecording, noteCopy.isEnhancing, noteCopy.hasPendingTranscript
        )
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
      lastModified: Date()
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

    // Derive title from first line
    let lines = content.components(separatedBy: .newlines)
    let title = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled"

    try fileManager.saveNote(content, withId: note.id, title: title)

    var updatedNote = note
    updatedNote.title = title
    updatedNote.lastModified = Date()

    // Preserve ephemeral states
    let states = noteStates[note.id]
    updatedNote.isRecording = states?.isRecording ?? false
    updatedNote.isEnhancing = states?.isEnhancing ?? false
    updatedNote.hasPendingTranscript = states?.hasPendingTranscript ?? false

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

  // Ephemeral state updates
  func updateNoteStates(recordingId: String?) {
    notes = notes.map { note in
      var copy = note
      if note.id == recordingId {
        copy.isRecording = true
        copy.hasPendingTranscript = false  // recording is in progress
      } else {
        copy.isRecording = false
      }
      copy.isEnhancing = false
      noteStates[note.id] = (copy.isRecording, copy.isEnhancing, copy.hasPendingTranscript)
      return copy
    }
  }

  func updateEnhancingState(noteId: String?) {
    notes = notes.map { note in
      var copy = note
      copy.isRecording = false
      copy.isEnhancing = (note.id == noteId)
      noteStates[note.id] = (copy.isRecording, copy.isEnhancing, copy.hasPendingTranscript)
      return copy
    }
  }

  func markPendingTranscript(noteId: String) {
    notes = notes.map { note in
      var copy = note
      if note.id == noteId {
        copy.isRecording = false
        copy.hasPendingTranscript = true
      }
      noteStates[note.id] = (copy.isRecording, copy.isEnhancing, copy.hasPendingTranscript)
      return copy
    }
  }

  func clearPendingTranscript(noteId: String) {
    notes = notes.map { note in
      var copy = note
      if note.id == noteId {
        copy.hasPendingTranscript = false
      }
      noteStates[note.id] = (copy.isRecording, copy.isEnhancing, copy.hasPendingTranscript)
      return copy
    }
  }

  func clearStates() {
    notes = notes.map { note in
      var copy = note
      copy.isRecording = false
      copy.isEnhancing = false
      noteStates[note.id] = (copy.isRecording, copy.isEnhancing, copy.hasPendingTranscript)
      return copy
    }
  }

  // Versions
  func createVersion(
    forNote note: Note, content: String
  ) throws -> NoteVersion {
    let version = try fileManager.createVersion(
      forId: note.id,
      content: content
    )

    var updatedNote = note
    // preserve ephemeral states
    let states = noteStates[note.id]
    updatedNote.isRecording = states?.isRecording ?? false
    updatedNote.isEnhancing = states?.isEnhancing ?? false
    updatedNote.hasPendingTranscript = states?.hasPendingTranscript ?? false

    try dbManager.updateNote(updatedNote)
    refreshNotes()
    return version
  }

  func getVersionContent(_ version: NoteVersion, forNote note: Note) throws -> String {
    return try fileManager.getVersionContent(forId: note.id, version: version)
  }
}
