import Foundation

/// The persisted form of a download target. `bookmark` is additive: records written before it existed decode
/// with `nil`, and the direct build never sets it.
struct DownloadTargetRecord: Codable, Equatable, Sendable {
  var path: String
  var isFolder: Bool
  var bookmark: Data?

  init(path: String, isFolder: Bool, bookmark: Data? = nil) {
    self.path = path
    self.isFolder = isFolder
    self.bookmark = bookmark
  }

  /// Builds a record from an open-panel URL. The Mac App Store build also stores a security-scoped bookmark.
  init(
    chosen url: URL, isFolder: Bool,
    bookmarks: SecurityScopedBookmarks = .live, sandboxed: Bool = DownloadTargetRecord.isSandboxed
  ) throws {
    self.init(
      path: url.path, isFolder: isFolder,
      bookmark: sandboxed ? try bookmarks.create(from: url) : nil)
  }

  #if MAS_CHANNEL
    static let isSandboxed = true
  #else
    static let isSandboxed = false
  #endif

  struct Resolved {
    let target: DownloadTarget
    let access: BookmarkAccess?
    /// The record to persist when the bookmark was refreshed.
    let updated: DownloadTargetRecord?
  }

  /// A plain path when there's no bookmark. With one, resolves it and holds scoped access for the watch.
  func resolve(bookmarks: SecurityScopedBookmarks = .live) throws -> Resolved {
    let mode: DownloadTarget.Mode = isFolder ? .folder : .file
    guard let bookmark else {
      return .init(
        target: .init(url: URL(fileURLWithPath: path), mode: mode), access: nil, updated: nil)
    }
    let (resolution, access) = try bookmarks.access(bookmark)
    var updated: DownloadTargetRecord?
    if let refreshed = resolution.refreshed {
      updated = self
      updated?.path = resolution.url.path
      updated?.bookmark = refreshed
    }
    return .init(
      target: .init(url: resolution.url, mode: mode), access: access, updated: updated)
  }
}
