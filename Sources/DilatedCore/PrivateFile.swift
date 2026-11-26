import Foundation

/// Atomic writes for per-user state: the directory is 0700 and the file is 0600 from the moment
/// it appears, so readers never see a looser mode or a partial file.
public enum PrivateFile {
  public static func write(_ data: Data, to url: URL) throws {
    let manager = FileManager.default
    let directory = url.deletingLastPathComponent()
    try manager.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let temp = directory.appendingPathComponent(
      ".\(url.lastPathComponent).tmp.\(getpid()).\(UUID().uuidString.prefix(8))")
    guard
      manager.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600])
    else {
      // Report the destination, not the random temp name, so repeated failures read identically.
      let denied = errno == EACCES || errno == EPERM || errno == EROFS
      throw CocoaError(
        denied ? .fileWriteNoPermission : .fileWriteUnknown,
        userInfo: [NSFilePathErrorKey: url.path])
    }
    do {
      // The umask may have stripped bits at creation.
      try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
      guard rename(temp.path, url.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    } catch {
      try? manager.removeItem(at: temp)
      throw error
    }
  }
}
