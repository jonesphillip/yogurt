import Foundation
import OSLog
import SQLite

class DatabaseManager {
  static let shared = DatabaseManager()
  private let logger = Logger(subsystem: kAppSubsystem, category: "DatabaseManager")

  private var db: Connection?

  // Table definition
  private let notes = Table("notes")
  private let id = SQLite.Expression<String>("id")
  private let title = SQLite.Expression<String>("title")
  private let lastModified = SQLite.Expression<Date>("last_modified")
  private let hasEnhancedVersion = SQLite.Expression<Bool>("has_enhanced_version")

  private let config = Table("config")
  private let key = SQLite.Expression<String>("key")
  private let value = SQLite.Expression<String?>("value")

  private let workerURLKey = "cloudflare_worker_url"
  private let selectedProcessKey = "selected_audio_process"
  private let selectedInputDeviceKey = "selected_input_device"

  private init() {
    setupDatabase()
  }

  private func setupDatabase() {
    do {
      let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      ).first!
      let dbDir = appSupport.appendingPathComponent(kAppSubsystem)

      // Make sure the directory exists
      if !FileManager.default.fileExists(atPath: dbDir.path) {
        try FileManager.default.createDirectory(
          at: dbDir,
          withIntermediateDirectories: true
        )
      }

      let dbURL = dbDir.appendingPathComponent("notes.sqlite3")
      logger.info("Attempting to create/open database at: \(dbURL.path)")

      db = try Connection(dbURL.path)

      // Enable foreign keys and WAL mode for better performance
      try db?.execute("PRAGMA foreign_keys = ON")
      try db?.execute("PRAGMA journal_mode = WAL")

      try createTables()
      try setupConfigTable()
      logger.info("Database setup complete at: \(dbURL.path)")
    } catch {
      logger.error(
        "Database setup failed: \(error.localizedDescription), underlying error: \(error)")
    }
  }

  private func createTables() throws {
    guard let db = db else { return }

    try db.run(
      notes.create(ifNotExists: true) { t in
        t.column(id, primaryKey: true)
        t.column(title)
        t.column(lastModified)
        t.column(hasEnhancedVersion)
      })

    try db.run(notes.createIndex(lastModified, ifNotExists: true))
  }

  func insertNote(_ note: Note) throws {
    guard let db = db else { throw DatabaseError.notConnected }

    let insert = notes.insert(
      or: .replace,
      id <- note.id,
      title <- note.title,
      lastModified <- note.lastModified,
      hasEnhancedVersion <- note.hasEnhancedVersion
    )

    try db.run(insert)
    logger.info("Inserted note: \(note.id)")
  }

  func updateNote(_ note: Note) throws {
    guard let db = db else { throw DatabaseError.notConnected }

    let noteRecord = notes.filter(id == note.id)
    try db.run(
      noteRecord.update(
        title <- note.title,
        lastModified <- note.lastModified,
        hasEnhancedVersion <- note.hasEnhancedVersion
      ))

    logger.info("Updated note: \(note.id)")
  }

  func deleteNote(withId noteId: String) throws {
    guard let db = db else { throw DatabaseError.notConnected }

    let noteRecord = notes.filter(id == noteId)
    try db.run(noteRecord.delete())
    logger.info("Deleted note: \(noteId)")
  }

  func getAllNotes() throws -> [Note] {
    guard let db = db else { throw DatabaseError.notConnected }

    var allNotes: [Note] = []
    let query = notes.order(lastModified.desc)

    for row in try db.prepare(query) {
      let note = Note(
        id: row[id],
        title: row[title],
        lastModified: row[lastModified],
        hasEnhancedVersion: row[hasEnhancedVersion]
      )
      allNotes.append(note)
    }

    return allNotes
  }

  func getNote(withId noteId: String) throws -> Note? {
    guard let db = db else { throw DatabaseError.notConnected }

    let query = notes.filter(id == noteId)
    guard let row = try db.pluck(query) else { return nil }

    return Note(
      id: row[id],
      title: row[title],
      lastModified: row[lastModified],
      hasEnhancedVersion: row[hasEnhancedVersion]
    )
  }

  // Cloudflare app configuration
  func setupConfigTable() throws {
    guard let db = db else { return }

    try db.run(
      config.create(ifNotExists: true) { t in
        t.column(key, primaryKey: true)
        t.column(value)
      })
  }

  func getCloudflareWorkerURL() -> String? {
    guard let db = db else { return nil }

    do {
      let query = config.filter(key == workerURLKey)
      return try db.pluck(query)?[value]
    } catch {
      logger.error("Failed to get worker URL: \(error.localizedDescription)")
      return nil
    }
  }

  func saveCloudflareWorkerURL(_ url: String?) throws {
    guard let db = db else { throw DatabaseError.notConnected }

    let upsert = config.insert(
      or: .replace,
      key <- workerURLKey,
      value <- url
    )

    try db.run(upsert)
    logger.info("Saved worker URL successfully")
  }

  // Audio and input config
  func saveSelectedAudioProcess(_ source: AudioSource?) throws {
    guard let db = db else { throw DatabaseError.notConnected }

    let jsonString =
      source.map { source in
        let stored = StoredAudioSource.from(source)
        let data = try? JSONEncoder().encode(stored)
        return data.flatMap { String(data: $0, encoding: .utf8) }
      } ?? nil

    let upsert = config.insert(or: .replace, key <- selectedProcessKey, value <- jsonString)
    try db.run(upsert)
  }

  func getSelectedAudioProcess() -> StoredAudioSource? {
    guard let db = db,
      let jsonString = try? db.pluck(config.filter(key == selectedProcessKey))?[value],
      let jsonData = jsonString.data(using: .utf8)
    else { return nil }
    return try? JSONDecoder().decode(StoredAudioSource.self, from: jsonData)
  }

  func saveSelectedInputDevice(_ deviceId: String?) throws {
    guard let db = db else { throw DatabaseError.notConnected }

    let upsert = config.insert(
      or: .replace,
      key <- selectedInputDeviceKey,
      value <- deviceId
    )

    try db.run(upsert)
    logger.info("Saved selected input device: \(deviceId ?? "none")")
  }

  func getSelectedInputDevice() -> String? {
    guard let db = db else { return nil }

    do {
      let query = config.filter(key == selectedInputDeviceKey)
      return try db.pluck(query)?[value]
    } catch {
      logger.error("Failed to get selected input device: \(error.localizedDescription)")
      return nil
    }
  }
}

enum DatabaseError: Error {
  case notConnected
}

struct StoredAudioSource: Codable {
  let name: String
  let bundleIdentifier: String?
  let bundleURL: String?

  static func from(_ source: AudioSource) -> StoredAudioSource {
    StoredAudioSource(
      name: source.name,
      bundleIdentifier: source.bundleIdentifier,
      bundleURL: source.bundleURL?.path
    )
  }
}
