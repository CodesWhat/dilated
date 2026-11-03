import Foundation

/// File and bookmark calls behind a seam so tests can fake staleness and missing targets.
protocol BookmarkFileOperations: Sendable {
  func makeBookmark(for url: URL) throws -> Data
  func resolve(_ data: Data) throws -> (url: URL, isStale: Bool)
  func startAccessing(_ url: URL) -> Bool
  func stopAccessing(_ url: URL)
  func exists(_ url: URL) -> Bool
}

struct LiveBookmarkFileOperations: BookmarkFileOperations {
  func makeBookmark(for url: URL) throws -> Data {
    try url.bookmarkData(
      options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
  }

  func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
    var stale = false
    let url = try URL(
      resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
      bookmarkDataIsStale: &stale)
    return (url, stale)
  }

  func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
  func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
  func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

enum BookmarkError: Error, Equatable, LocalizedError {
  case missingTarget
  case accessDenied

  var errorDescription: String? {
    switch self {
    case .missingTarget: "The chosen file or folder is gone. Choose it again."
    case .accessDenied:
      "Dilated no longer has access to the chosen file or folder. Choose it again."
    }
  }
}

/// Holds security-scoped access open and closes it once, on `stop()` or when released.
final class BookmarkAccess: @unchecked Sendable {
  private let lock = NSLock()
  private var release: (@Sendable () -> Void)?

  init(release: @escaping @Sendable () -> Void) { self.release = release }

  func stop() {
    lock.lock()
    let release = self.release
    self.release = nil
    lock.unlock()
    release?()
  }

  deinit { stop() }
}

struct BookmarkResolution {
  let url: URL
  /// Fresh bookmark data when the stored data was stale. Persist it in place of the old data.
  let refreshed: Data?
}

struct SecurityScopedBookmarks: Sendable {
  let operations: any BookmarkFileOperations

  static let live = SecurityScopedBookmarks(operations: LiveBookmarkFileOperations())

  /// Bookmark data for a URL the user picked in an `NSOpenPanel`.
  func create(from url: URL) throws -> Data { try operations.makeBookmark(for: url) }

  /// Resolves stored data. A stale bookmark is re-created from the resolved URL.
  func resolve(_ data: Data) throws -> BookmarkResolution {
    let resolved: (url: URL, isStale: Bool)
    do { resolved = try operations.resolve(data) } catch let error as CocoaError
      where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    {
      throw BookmarkError.missingTarget
    }
    guard operations.exists(resolved.url) else { throw BookmarkError.missingTarget }
    guard resolved.isStale else { return .init(url: resolved.url, refreshed: nil) }
    guard operations.startAccessing(resolved.url) else { throw BookmarkError.accessDenied }
    defer { operations.stopAccessing(resolved.url) }
    return .init(url: resolved.url, refreshed: try operations.makeBookmark(for: resolved.url))
  }

  /// Resolves the data and starts access. The returned handle ends access when stopped or released.
  func access(_ data: Data) throws -> (resolution: BookmarkResolution, access: BookmarkAccess) {
    let resolution = try resolve(data)
    guard operations.startAccessing(resolution.url) else { throw BookmarkError.accessDenied }
    let operations = operations
    let url = resolution.url
    return (resolution, BookmarkAccess { operations.stopAccessing(url) })
  }
}
