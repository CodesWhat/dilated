import DilatedControl
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

private final class FakeBookmarkOperations: BookmarkFileOperations, @unchecked Sendable {
  private let lock = NSLock()
  private var _stale = false
  private var _present = true
  private var _grants = true
  private var _starts = 0
  private var _stops = 0
  private var _created: [URL] = []
  private var _options: [URL.BookmarkCreationOptions] = []
  private var _events: [String] = []
  let resolved: URL

  init(resolved: URL) { self.resolved = resolved }

  var stale: Bool {
    get { lock.withLock { _stale } }
    set { lock.withLock { _stale = newValue } }
  }
  var present: Bool {
    get { lock.withLock { _present } }
    set { lock.withLock { _present = newValue } }
  }
  var grants: Bool {
    get { lock.withLock { _grants } }
    set { lock.withLock { _grants = newValue } }
  }
  var starts: Int { lock.withLock { _starts } }
  var stops: Int { lock.withLock { _stops } }
  var created: [URL] { lock.withLock { _created } }
  var options: [URL.BookmarkCreationOptions] { lock.withLock { _options } }
  var events: [String] { lock.withLock { _events } }

  func makeBookmark(for url: URL, options: URL.BookmarkCreationOptions) throws -> Data {
    lock.withLock {
      _created.append(url)
      _options.append(options)
    }
    return Data("bookmark-\(url.path)-\(created.count)".utf8)
  }
  func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
    if !present { throw CocoaError(.fileReadNoSuchFile) }
    return (resolved, stale)
  }
  func startAccessing(_ url: URL) -> Bool {
    lock.withLock {
      _starts += 1
      _events.append("start")
      return _grants
    }
  }
  func stopAccessing(_ url: URL) {
    lock.withLock {
      _stops += 1
      _events.append("stop")
    }
  }
  func exists(_ url: URL) -> Bool {
    lock.withLock { _events.append("exists") }
    return present
  }
}

struct MASChannelBookmarkStoreTests {
  private let url = URL(fileURLWithPath: "/tmp/chosen-folder")

  @Test func roundTripCreatesThenResolvesWithoutRefresh() throws {
    let fake = FakeBookmarkOperations(resolved: url)
    let store = SecurityScopedBookmarks(operations: fake)
    let data = try store.create(from: url)
    #expect(!data.isEmpty && fake.created == [url])
    let resolution = try store.resolve(data)
    #expect(resolution.url == url && resolution.refreshed == nil)
  }

  @Test func staleBookmarkIsRecreatedUnderScopedAccess() throws {
    let fake = FakeBookmarkOperations(resolved: url)
    fake.stale = true
    let store = SecurityScopedBookmarks(operations: fake)
    let original = Data("old".utf8)
    let resolution = try store.resolve(original)
    let refreshed = try #require(resolution.refreshed)
    #expect(refreshed != original && fake.created == [url])
    #expect(fake.starts == 1 && fake.stops == 1)
  }

  @Test func bookmarksAreCreatedReadOnlyScoped() throws {
    let fake = FakeBookmarkOperations(resolved: url)
    _ = try SecurityScopedBookmarks(operations: fake).create(from: url)
    let options = try #require(fake.options.first)
    #expect(options.contains(.withSecurityScope))
    #expect(options.contains(.securityScopeAllowOnlyReadAccess))
  }

  @Test func resolveStartsAccessBeforeCheckingExistence() throws {
    let fake = FakeBookmarkOperations(resolved: url)
    _ = try SecurityScopedBookmarks(operations: fake).resolve(Data("x".utf8))
    #expect(fake.events == ["start", "exists", "stop"])
  }

  @Test func missingTargetStopsAccessOnce() {
    // Resolves fine but the target is gone.
    let late = OrderedMissing(resolved: url)
    #expect(throws: BookmarkError.missingTarget) {
      try SecurityScopedBookmarks(operations: late).resolve(Data("x".utf8))
    }
    #expect(late.events == ["start", "exists", "stop"])
  }

  @Test func missingTargetThrowsFromResolveOrExistenceCheck() {
    let fake = FakeBookmarkOperations(resolved: url)
    let store = SecurityScopedBookmarks(operations: fake)
    fake.present = false
    #expect(throws: BookmarkError.missingTarget) { try store.resolve(Data("x".utf8)) }
    // Resolves, but the target was deleted afterwards.
    let late = LateMissing(resolved: url)
    #expect(throws: BookmarkError.missingTarget) {
      try SecurityScopedBookmarks(operations: late).resolve(Data("x".utf8))
    }
  }

  @Test func deniedAccessIsReported() {
    let fake = FakeBookmarkOperations(resolved: url)
    fake.grants = false
    #expect(throws: BookmarkError.accessDenied) {
      try SecurityScopedBookmarks(operations: fake).access(Data("x".utf8))
    }
  }

  @Test func accessHandleStopsOnceAndOnRelease() throws {
    let fake = FakeBookmarkOperations(resolved: url)
    let store = SecurityScopedBookmarks(operations: fake)
    var handle: BookmarkAccess? = try store.access(Data("x".utf8)).access
    #expect(fake.starts == 1 && fake.stops == 0)
    handle?.stop()
    handle?.stop()
    #expect(fake.stops == 1)
    handle = nil
    #expect(fake.stops == 1)
    var released: BookmarkAccess? = try store.access(Data("x".utf8)).access
    #expect(released != nil)
    released = nil
    #expect(fake.stops == 2)
  }
}

private final class OrderedMissing: BookmarkFileOperations, @unchecked Sendable {
  private let lock = NSLock()
  private var _events: [String] = []
  let resolved: URL
  init(resolved: URL) { self.resolved = resolved }
  var events: [String] { lock.withLock { _events } }
  private func log(_ event: String) { lock.withLock { _events.append(event) } }
  func makeBookmark(for url: URL, options: URL.BookmarkCreationOptions) throws -> Data { Data() }
  func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) { (resolved, true) }
  func startAccessing(_ url: URL) -> Bool {
    log("start")
    return true
  }
  func stopAccessing(_ url: URL) { log("stop") }
  func exists(_ url: URL) -> Bool {
    log("exists")
    return false
  }
}

private struct LateMissing: BookmarkFileOperations {
  let resolved: URL
  func makeBookmark(for url: URL, options: URL.BookmarkCreationOptions) throws -> Data { Data() }
  func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) { (resolved, false) }
  func startAccessing(_ url: URL) -> Bool { true }
  func stopAccessing(_ url: URL) {}
  func exists(_ url: URL) -> Bool { false }
}

struct MASChannelDownloadRecordTests {
  @Test func recordsWrittenBeforeBookmarksDecodeUnchanged() throws {
    let old = Data(#"{"path":"/Users/me/Downloads","isFolder":true}"#.utf8)
    let record = try JSONDecoder().decode(DownloadTargetRecord.self, from: old)
    #expect(record == .init(path: "/Users/me/Downloads", isFolder: true, bookmark: nil))
    let resolved = try record.resolve(
      bookmarks: .init(operations: LateMissing(resolved: .init(filePath: "/"))))
    #expect(resolved.target.url.path == "/Users/me/Downloads" && resolved.target.mode == .folder)
    #expect(resolved.access == nil && resolved.updated == nil)
  }

  @Test func recordWithBookmarkRoundTripsThroughJSON() throws {
    let record = DownloadTargetRecord(path: "/a/b.part", isFolder: false, bookmark: Data([1, 2]))
    let decoded = try JSONDecoder().decode(
      DownloadTargetRecord.self, from: JSONEncoder().encode(record))
    #expect(decoded == record)
  }

  @Test func directBuildKeepsPlainPathsAndSandboxedBuildStoresABookmark() throws {
    let url = URL(fileURLWithPath: "/tmp/watched.part")
    let fake = FakeBookmarkOperations(resolved: url)
    let store = SecurityScopedBookmarks(operations: fake)
    let plain = try DownloadTargetRecord(
      chosen: url, isFolder: false, bookmarks: store, sandboxed: false)
    #expect(plain.bookmark == nil && plain.path == url.path && fake.created.isEmpty)
    let scoped = try DownloadTargetRecord(
      chosen: url, isFolder: false, bookmarks: store, sandboxed: true)
    #expect(scoped.bookmark != nil && fake.created == [url])
    #if MAS_CHANNEL
      #expect(DownloadTargetRecord.isSandboxed)
    #else
      #expect(!DownloadTargetRecord.isSandboxed)
    #endif
  }

  @Test func staleRecordResolvesToUpdatedRecordAndHoldsAccess() throws {
    let folder = URL(fileURLWithPath: "/tmp/moved-folder")
    let fake = FakeBookmarkOperations(resolved: folder)
    fake.stale = true
    let record = DownloadTargetRecord(
      path: "/tmp/old-folder", isFolder: true, bookmark: Data("old".utf8))
    var resolved: DownloadTargetRecord.Resolved? = try record.resolve(
      bookmarks: .init(operations: fake))
    #expect(resolved?.target.url == folder)
    #expect(resolved?.updated?.path == folder.path)
    #expect(resolved?.updated?.bookmark != record.bookmark)
    #expect(fake.starts == 1 && fake.stops == 0)
    resolved = nil
    #expect(fake.stops == 1)
  }

  @Test func missingBookmarkTargetFailsResolve() {
    let fake = FakeBookmarkOperations(resolved: URL(fileURLWithPath: "/tmp/gone"))
    fake.present = false
    let record = DownloadTargetRecord(path: "/tmp/gone", isFolder: true, bookmark: Data("x".utf8))
    #expect(throws: BookmarkError.missingTarget) {
      try record.resolve(bookmarks: .init(operations: fake))
    }
  }

  @Test func systemDownloadsIsTheRealFolderNotTheHome() throws {
    let target = try #require(DownloadTarget.systemDownloads())
    #expect(target.mode == .folder && target.url.lastPathComponent == "Downloads")
  }

  @MainActor @Test func modelHoldsScopedAccessForTheWatchAndReleasesItWhenTheHoldEnds() async throws
  {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let model = AppModel(endpoint: SocketEndpoint(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    // An empty folder ends the watch right away ("No partial downloads"), which releases the monitor.
    let fake = FakeBookmarkOperations(resolved: directory)
    let record = DownloadTargetRecord(
      path: directory.path, isFolder: true, bookmark: Data("x".utf8))
    _ = try model.startDownload(record, quietSeconds: 30, bookmarks: .init(operations: fake))
    #expect(fake.starts == 1)
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while fake.stops == 0 && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(fake.stops == 1)
    #expect(model.engine.holds.isEmpty)
  }

  @MainActor @Test func modelReportsAMissingBookmarkTargetWithoutStartingAHold() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: SocketEndpoint(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    let fake = FakeBookmarkOperations(resolved: directory)
    fake.present = false
    let record = DownloadTargetRecord(path: "/x", isFolder: true, bookmark: Data("x".utf8))
    #expect(throws: BookmarkError.missingTarget) {
      try model.startDownload(record, quietSeconds: 30, bookmarks: .init(operations: fake))
    }
    #expect(model.engine.holds.isEmpty)
    #expect(model.message == BookmarkError.missingTarget.errorDescription)
  }
}
