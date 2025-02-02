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

  private let config = Table("config")
  private let key = SQLite.Expression<String>("key")
  private let value = SQLite.Expression<String?>("value")

  private let versions = Table("versions")
  private let versionId = SQLite.Expression<UUID>("id")
  private let noteId = SQLite.Expression<String>("note_id")
  private let versionTimestamp = SQLite.Expression<Date>("timestamp")
  private let versionPath = SQLite.Expression<String>("file_path")

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

      try migrateDatabase()
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
      })

    try db.run(notes.createIndex(lastModified, ifNotExists: true))

    // Add versions table
    try db.run(
      versions.create(ifNotExists: true) { t in
        t.column(versionId, primaryKey: true)
        t.column(noteId)
        t.column(versionTimestamp)
        t.column(versionPath)

        // Add foreign key constraint
        t.foreignKey(noteId, references: notes, id, update: .cascade, delete: .cascade)
      })

    // Add indexes
    try db.run(versions.createIndex(noteId, versionTimestamp, ifNotExists: true))
  }

  func insertNote(_ note: Note) throws {
    guard let db = db else { throw DatabaseError.notConnected }

    let insert = notes.insert(
      or: .replace,
      id <- note.id,
      title <- note.title,
      lastModified <- note.lastModified
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
        lastModified <- note.lastModified
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
        lastModified: row[lastModified]
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
      lastModified: row[lastModified]
    )
  }

  // Note versions
  func saveVersion(_ version: NoteVersion, forNoteId noteId: String) throws {
    guard let db = db else { throw DatabaseError.notConnected }

    let insert = versions.insert(
      versionId <- version.id,
      self.noteId <- noteId,
      versionTimestamp <- version.timestamp,
      versionPath <- version.filePath
    )

    try db.run(insert)
    logger.info("Saved version \(version.id) for note: \(noteId)")
  }

  func getVersions(forNoteId noteId: String) throws -> [NoteVersion] {
    guard let db = db else { throw DatabaseError.notConnected }

    let query = versions.filter(self.noteId == noteId)
      .order(versionTimestamp.desc)

    return try db.prepare(query).map { row in
      NoteVersion(
        id: row[versionId],
        timestamp: row[versionTimestamp],
        filePath: row[versionPath]
      )
    }
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

  // Database migrations
  private func migrateDatabase() throws {
    guard let db = db else { return }

    // Check if the legacy column exists
    let pragmaStatement = "PRAGMA table_info(notes)"
    var hasEnhancementColumn = false

    // Each row from PRAGMA table_info returns: cid, name, type, notnull, dflt_value, pk
    for row in try db.prepare(pragmaStatement) {
      if let columnName = row[1] as? String, columnName == "has_enhanced_version" {
        hasEnhancementColumn = true
        break
      }
    }

    // If the legacy column exists, perform the migration
    if hasEnhancementColumn {
      logger.info("Legacy 'has_enhanced_version' column detected. Migrating notes table…")
      try db.transaction {
        // Create a temporary table with the new schema.
        try db.run(
          """
          CREATE TABLE notes_new (
              id TEXT PRIMARY KEY,
              title TEXT,
              last_modified DATE
          )
          """)

        // Copy data from the old table to the new table
        try db.run(
          """
          INSERT INTO notes_new (id, title, last_modified)
          SELECT id, title, last_modified FROM notes
          """)

        // Drop the old table
        try db.run("DROP TABLE notes")

        // Rename the new table to the original name
        try db.run("ALTER TABLE notes_new RENAME TO notes")

        // Recreate any indexes that existed on the old table
        try db.run("CREATE INDEX IF NOT EXISTS index_notes_last_modified ON notes(last_modified)")
      }
      logger.info("Migration complete: 'has_enhanced_version' column removed.")
    } else {
      logger.info("No migration needed for notes table.")
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
