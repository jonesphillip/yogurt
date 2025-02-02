import Foundation

struct NoteVersion: Codable, Identifiable, Hashable {
  let id: UUID
  let timestamp: Date
  let filePath: String

  static func == (lhs: NoteVersion, rhs: NoteVersion) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}
