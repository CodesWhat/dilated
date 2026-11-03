import Foundation

/// File and bookmark calls behind a seam so tests can fake staleness and missing targets.
protocol BookmarkFileOperations: Sendable {
  func makeBookmark(for url: URL, options: URL.BookmarkCreationOptions) throws -> Data
  func resolve(_ data: Data) throws -> (url: URL, isStale: Bool)
  func startAccessing(_ url: URL) -> Bool
  func stopAccessing(_ url: URL)
  func exists(_ url: URL) -> Bool
}

struct LiveBookmarkFileOperations: BookmarkFileOperations {
  func makeBookmark(for url: URL, options: URL.BookmarkCreationOptions) throws -> Data {
    try url.bookmarkData(
      options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
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

  /// The MAS entitlement is `files.user-selected.read-only`, so bookmarks are read-only scoped.
  static let creationOptions: URL.BookmarkCreationOptions = [
    .withSecurityScope, .securityScopeAllowOnlyReadAccess,
  ]

  /// Bookmark data for a URL the user picked in an `NSOpenPanel`.
  func create(from url: URL) throws -> Data {
    try operations.makeBookmark(for: url, options: Self.creationOptions)
  }

  /// Resolves stored data. A stale bookmark is re-created from the resolved URL.
  func resolve(_ data: Data) throws -> BookmarkResolution {
    let resolution = try resolveHoldingAccess(data)
    operations.stopAccessing(resolution.url)
    return resolution
  }

  /// Resolves the data and starts access. The returned handle ends access when stopped or released.
  func access(_ data: Data) throws -> (resolution: BookmarkResolution, access: BookmarkAccess) {
    let resolution = try resolveHoldingAccess(data)
    let operations = operations
    let url = resolution.url
    return (resolution, BookmarkAccess { operations.stopAccessing(url) })
  }

  /// Starts scoped access before anything touches the target, since the sandbox can hide it
  /// until then. Access stays open on success and is stopped here on every failure.
  private func resolveHoldingAccess(_ data: Data) throws -> BookmarkResolution {
    let resolved: (url: URL, isStale: Bool)
    do { resolved = try operations.resolve(data) } catch let error as CocoaError
      where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    {
      throw BookmarkError.missingTarget
    }
    guard operations.startAccessing(resolved.url) else { throw BookmarkError.accessDenied }
    do {
      guard operations.exists(resolved.url) else { throw BookmarkError.missingTarget }
      guard resolved.isStale else { return .init(url: resolved.url, refreshed: nil) }
      return .init(
        url: resolved.url,
        refreshed: try operations.makeBookmark(for: resolved.url, options: Self.creationOptions))
    } catch {
      operations.stopAccessing(resolved.url)
      throw error
    }
  }
}
