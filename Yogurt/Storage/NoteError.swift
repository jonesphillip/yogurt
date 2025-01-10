import Foundation

enum NoteFileManagerError: Error {
  case directoryNotFound
  case saveFailed(Error)
  case readFailed(Error)
  case deleteFailed(Error)
  case noteNotFound
}
