import AppKit
import DilatedControl
import Foundation
import ImageIO
import Testing

@testable import DilatedUI

private final class FakeVolumeBookmarks: BookmarkFileOperations, @unchecked Sendable {
  private let lock = NSLock()
  private var _mounted = true
  private var _stale = false
  private var _resolved: URL
  private var _options: [URL.BookmarkCreationOptions] = []
  private var _starts = 0
  private var _stops = 0

  init(resolved: URL) { _resolved = resolved }

  var mounted: Bool {
    get { lock.withLock { _mounted } }
    set { lock.withLock { _mounted = newValue } }
  }
  var stale: Bool {
    get { lock.withLock { _stale } }
    set { lock.withLock { _stale = newValue } }
  }
  var resolved: URL {
    get { lock.withLock { _resolved } }
    set { lock.withLock { _resolved = newValue } }
  }
  var options: [URL.BookmarkCreationOptions] { lock.withLock { _options } }
  var starts: Int { lock.withLock { _starts } }
  var stops: Int { lock.withLock { _stops } }

  func makeBookmark(for url: URL, options: URL.BookmarkCreationOptions) throws -> Data {
    lock.withLock { _options.append(options) }
    return Data(("grant-" + url.path).utf8)
  }
  func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
    if !mounted { throw CocoaError(.fileReadNoSuchFile) }
    return (resolved, stale)
  }
  func startAccessing(_ url: URL) -> Bool {
    lock.withLock { _starts += 1 }
    return true
  }
  func stopAccessing(_ url: URL) { lock.withLock { _stops += 1 } }
  func exists(_ url: URL) -> Bool { mounted }
}

private func drive(_ path: String = "/Volumes/Backup", id: String = "uuid:BACKUP")
  -> MountedDrive
{
  MountedDrive(
    volume: DriveAliveVolume(id: id, name: "Backup", path: path), readOnly: false, device0: 1,
    device1: 2)
}

struct MASChannelDriveAliveGrantTests {
  @Test func grantsAreReadWriteScopedAndKeyedByVolumeIdentity() throws {
    let fake = FakeVolumeBookmarks(resolved: URL(fileURLWithPath: "/Volumes/Backup"))
    let grants = DriveAliveGrants(
      bookmarks: SecurityScopedBookmarks(
        operations: fake, options: SecurityScopedBookmarks.readWriteCreationOptions))
    let volume = try grants.grant(
      for: drive(), chosen: URL(fileURLWithPath: "/Volumes/Backup"), mode: .always)
    #expect(volume.id == "uuid:BACKUP" && volume.mode == .always && volume.grant != nil)
    let options = try #require(fake.options.first)
    #expect(options.contains(.withSecurityScope))
    #expect(!options.contains(.securityScopeAllowOnlyReadAccess))
    #expect(
      SecurityScopedBookmarks.liveReadWrite.options
        == SecurityScopedBookmarks.readWriteCreationOptions)
    #expect(SecurityScopedBookmarks.live.options.contains(.securityScopeAllowOnlyReadAccess))
  }

  @Test func pickingAFolderThatIsNotTheVolumeRootIsRefused() {
    let fake = FakeVolumeBookmarks(resolved: URL(fileURLWithPath: "/Volumes/Backup"))
    let grants = DriveAliveGrants(bookmarks: SecurityScopedBookmarks(operations: fake))
    #expect(throws: DriveAliveError.self) {
      try grants.grant(
        for: drive(), chosen: URL(fileURLWithPath: "/Volumes/Backup/Photos"))
    }
    #expect(fake.options.isEmpty)
  }

  @Test func aVolumeWithoutAGrantIsRequiredToGetOne() {
    let fake = FakeVolumeBookmarks(resolved: URL(fileURLWithPath: "/Volumes/Backup"))
    let grants = DriveAliveGrants(bookmarks: SecurityScopedBookmarks(operations: fake))
    let volume = drive().volume
    #expect(volume.needsGrant(sandboxed: true) && !volume.needsGrant(sandboxed: false))
    #expect {
      try grants.open(volume, current: drive())
    } throws: {
      ($0 as? DriveAliveError)?.errorDescription
        == DriveAliveError.grantRequired.errorDescription
    }
    #expect(fake.starts == 0)
  }

  @Test func theGrantResolvesAfterTheVolumeIsRemounted() throws {
    let root = URL(fileURLWithPath: "/Volumes/Backup")
    let fake = FakeVolumeBookmarks(resolved: root)
    let grants = DriveAliveGrants(bookmarks: SecurityScopedBookmarks(operations: fake))
    var volume = drive().volume
    volume.grant = Data("grant".utf8)
    // Unmounted: the bookmark can't resolve and nothing is left open.
    fake.mounted = false
    #expect(throws: DriveAliveError.self) { try grants.open(volume, current: drive()) }
    #expect(fake.starts == 0)
    // Remounted: the same stored data resolves and access stays open until released.
    fake.mounted = true
    let opened = try grants.open(volume, current: drive())
    #expect(fake.starts == 1 && fake.stops == 0 && opened.refreshed == nil)
    opened.access.stop()
    #expect(fake.stops == 1)
  }

  @Test func aGrantResolvingToADifferentPathIsRefusedAndReleased() {
    let fake = FakeVolumeBookmarks(resolved: URL(fileURLWithPath: "/Volumes/Backup 1"))
    let grants = DriveAliveGrants(bookmarks: SecurityScopedBookmarks(operations: fake))
    var volume = drive().volume
    volume.grant = Data("grant".utf8)
    #expect(throws: DriveAliveError.self) { try grants.open(volume, current: drive()) }
    #expect(fake.starts == 1 && fake.stops == 1)
  }

  @Test func aStaleGrantIsRefreshedReadWrite() throws {
    let fake = FakeVolumeBookmarks(resolved: URL(fileURLWithPath: "/Volumes/Backup"))
    fake.stale = true
    let grants = DriveAliveGrants(
      bookmarks: SecurityScopedBookmarks(
        operations: fake, options: SecurityScopedBookmarks.readWriteCreationOptions))
    var volume = drive().volume
    volume.grant = Data("old".utf8)
    let opened = try grants.open(volume, current: drive())
    defer { opened.access.stop() }
    #expect(opened.refreshed == Data("grant-/Volumes/Backup".utf8))
    #expect(fake.options.allSatisfy { !$0.contains(.securityScopeAllowOnlyReadAccess) })
  }

  @Test func grantsRoundTripAndTheDirectFormatStaysUnchanged() throws {
    let plain = DriveAliveVolume(id: "uuid:A", name: "A", path: "/Volumes/A")
    let encoded = try JSONEncoder().encode(plain)
    #expect(try #require(String(data: encoded, encoding: .utf8)).contains("grant") == false)
    var granted = plain
    granted.grant = Data("g".utf8)
    #expect(
      try JSONDecoder().decode(DriveAliveVolume.self, from: JSONEncoder().encode(granted))
        == granted)
    #expect(try JSONDecoder().decode(DriveAliveVolume.self, from: encoded).grant == nil)
  }
}

@MainActor struct MASChannelDriveAliveMountTests {
  @Test func aMountEventWritesImmediatelyThroughTheGrantAndAGrantlessVolumeReportsIt() async throws
  {
    let center = NotificationCenter()
    var pulses: [String] = []
    var now: TimeInterval = 0
    let controller = DriveAliveController(
      clock: { now },
      pulse: { volume in
        pulses.append(volume.id)
        if volume.needsGrant(sandboxed: true) { throw DriveAliveError.grantRequired }
      },
      schedule: { _, _ in {} }, mountEvents: center, watchMounts: true)
    defer { controller.stop() }
    var settings = DriveAliveSettings()
    settings.enabled = true
    settings.onlyWhileAwake = false
    settings.volumes = [DriveAliveVolume(id: "uuid:A", name: "A", path: "/Volumes/A")]
    controller.configure(settings, awake: true, paused: false)
    try await wait { pulses.count == 1 }
    try await wait { controller.statuses["uuid:A"] != nil }
    #expect(
      controller.statuses["uuid:A"] == DriveAliveError.grantRequired.errorDescription)
    now = 5
    center.post(name: NSWorkspace.didMountNotification, object: nil)
    try await wait { pulses.count == 2 }
  }

  @Test func theDirectBuildIgnoresMountEvents() async throws {
    let center = NotificationCenter()
    var count = 0
    let controller = DriveAliveController(
      clock: { 0 }, pulse: { _ in count += 1 }, schedule: { _, _ in {} },
      mountEvents: center, watchMounts: false)
    defer { controller.stop() }
    var settings = DriveAliveSettings()
    settings.enabled = true
    settings.onlyWhileAwake = false
    settings.volumes = [DriveAliveVolume(id: "uuid:A", name: "A", path: "/Volumes/A")]
    controller.configure(settings, awake: true, paused: false)
    try await wait { count == 1 }
    center.post(name: NSWorkspace.didMountNotification, object: nil)
    try await Task.sleep(for: .milliseconds(50))
    #expect(count == 1)
  }

  private func wait(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(2))
    }
    #expect(condition())
  }
}

@MainActor struct MASChannelPickerCopyInTests {
  private func pngData() throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: 32, height: 30, bitsPerComponent: 8, bytesPerRow: 128,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.premultipliedLast.rawValue))
    context.clear(CGRect(x: 0, y: 0, width: 32, height: 30))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 8, y: 7, width: 8, height: 15))
    let data = NSMutableData()
    let destination = try #require(
      CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
  }

  @Test func aPickedGlyphIsCopiedIntoTheStateDirectoryAndNoPathIsStored() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = root.appendingPathComponent("picked", isDirectory: true)
    let state = root.appendingPathComponent("state", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let model = AppModel(endpoint: .init(stateDirectory: state), power: { .init() })
    defer { model.shutdown() }
    let source = outside.appendingPathComponent("icon.png")
    try pngData().write(to: source)
    try await model.importCustomGlyph(from: source)
    let glyph = try #require(model.settings.customGlyph)
    try FileManager.default.removeItem(at: source)
    #expect(try CustomGlyphStore(directory: state).image(glyph).size.width > 0)
    let copied = try FileManager.default.contentsOfDirectory(
      atPath: state.appendingPathComponent("glyphs").path)
    #expect(copied.count == 1)
    let saved = try String(
      contentsOf: state.appendingPathComponent("settings.json"), encoding: .utf8)
    #expect(!saved.contains(outside.path))
  }

  @Test func aPickedSoundIsCopiedIntoTheStateDirectoryAndNoPathIsStored() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = root.appendingPathComponent("picked", isDirectory: true)
    let state = root.appendingPathComponent("state", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let model = AppModel(endpoint: .init(stateDirectory: state), power: { .init() })
    defer { model.shutdown() }
    let source = outside.appendingPathComponent("chime.wav")
    try FeedbackSoundStore(directory: state).data(for: .awake).write(to: source)
    try await model.importFeedbackSound(from: source, for: .end)
    let sound = model.settings.feedback.endChoice
    let id = try #require(sound.customID)
    try FileManager.default.removeItem(at: source)
    #expect(!(try FeedbackSoundStore(directory: state).data(for: sound)).isEmpty)
    #expect(
      FileManager.default.fileExists(
        atPath: state.appendingPathComponent("sounds/\(id.uuidString).sound").path))
    let saved = try String(
      contentsOf: state.appendingPathComponent("settings.json"), encoding: .utf8)
    #expect(!saved.contains(outside.path))
  }
}
