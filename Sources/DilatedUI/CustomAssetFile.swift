import DilatedControl
import DilatedCore
import Foundation

/// File I/O shared by the user-imported assets (custom glyphs and feedback sounds): a bounded,
/// cancellable read of a regular file, a private atomic write, and a tolerant remove.
enum CustomAssetFile {
  static let maximumBytes = 2_000_000

  nonisolated static func read(_ file: URL, notRegular: String, tooLarge: String) throws -> Data {
    guard file.isFileURL,
      try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
        == .typeRegular
    else { throw InputError(notRegular) }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var data = Data()
    while data.count <= maximumBytes {
      try Task.checkCancellation()
      guard
        let next = try handle.read(upToCount: min(65536, maximumBytes + 1 - data.count)),
        !next.isEmpty
      else { break }
      data.append(next)
    }
    guard !data.isEmpty, data.count <= maximumBytes else { throw InputError(tooLarge) }
    return data
  }

  static func write(_ data: Data, to file: URL) throws {
    try PrivateFile.write(data, to: file)
  }

  static func remove(_ file: URL) throws {
    do {
      try FileManager.default.removeItem(at: file)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {}
  }
}
