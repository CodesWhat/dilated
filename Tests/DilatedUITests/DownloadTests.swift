import DilatedControl
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct DownloadTests {
  @Test func nativeFileEventsDeliverChangesAndReleaseTheStream() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var events = 0
    let cancel = try #require(NativeDownloadEvents.subscribe(folder) { events += 1 })
    defer { cancel() }
    // A since-now stream can register after a single write on a loaded runner, so keep
    // modifying the file until the stream reports it.
    let file = folder.appendingPathComponent("native.part")
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(10)
    var nextWrite = clock.now
    var writes = 0
    while events == 0 && clock.now < deadline {
      if clock.now >= nextWrite {
        writes += 1
        try Data(repeating: 1, count: writes).write(to: file)
        nextWrite = clock.now + .milliseconds(500)
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(events > 0)
  }

  @Test func pendingReadsCoalesceAndLateCompletionAfterStopIsIgnored() async throws {
    var continuation: CheckedContinuation<DownloadSnapshot, any Error>?
    var event: (@MainActor @Sendable () -> Void)?
    var reads = 0
    var readReturned = false
    var cancellations = 0
    var ends = 0
    let monitor = DownloadMonitor(
      target: .init(url: URL(fileURLWithPath: "/tmp/test.part"), mode: .file), quietSeconds: 30,
      read: { _ in
        reads += 1
        let snapshot = try await withCheckedThrowingContinuation { continuation = $0 }
        readReturned = true
        return snapshot
      },
      subscribe: { _, changed in
        event = changed
        return { cancellations += 1 }
      }, clock: { 0 }, finished: { _ in ends += 1 })
    try monitor.start()
    for _ in 0..<100 where continuation == nil { try await Task.sleep(for: .milliseconds(1)) }
    try #require(continuation != nil)
    for _ in 0..<100 { event?() }
    #expect(reads == 1)
    monitor.stop()
    continuation?.resume(returning: DownloadFixture.initial)
    continuation = nil
    let deadline = ContinuousClock.now + .seconds(5)
    while !readReturned && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(readReturned)
    event?()
    monitor.tick()
    #expect(reads == 1 && cancellations == 1 && ends == 0)
  }

  @Test func changesDuringTheDeadlineScanMustBeRescannedBeforeEnding() async throws {
    var continuation: CheckedContinuation<DownloadSnapshot, any Error>?
    var event: (@MainActor @Sendable () -> Void)?
    var reads = 0
    var uptime: TimeInterval = 0
    var ends = 0
    let monitor = DownloadMonitor(
      target: .init(url: URL(fileURLWithPath: "/tmp/test.part"), mode: .file), quietSeconds: 30,
      read: { _ in
        reads += 1
        if reads == 2 {
          return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        var snapshot = DownloadFixture.initial
        if reads > 2 { snapshot.files["data"]?.size = 2 }
        return snapshot
      },
      subscribe: { _, changed in
        event = changed
        return {}
      }, clock: { uptime }, finished: { _ in ends += 1 })
    defer { monitor.stop() }
    try monitor.start()
    for _ in 0..<100 where reads == 0 { try await Task.sleep(for: .milliseconds(1)) }
    uptime = 30
    monitor.tick()
    for _ in 0..<100 where continuation == nil { try await Task.sleep(for: .milliseconds(1)) }
    try #require(continuation != nil)
    event?()
    continuation?.resume(returning: DownloadFixture.initial)
    continuation = nil
    let deadline = ContinuousClock.now + .seconds(5)
    while reads < 3 && ends == 0 && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(ends == 0)
    #expect(reads == 3)
  }

  @Test func scannerTracksOnlyPartialDownloadsAndTheirPackageContents() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let target = DownloadTarget(url: folder, mode: .folder)
    try Data([1]).write(to: folder.appendingPathComponent("finished.zip"))
    #expect(try NativeDownloadScanner.read(target).files.isEmpty)
    for name in ["one.crdownload", "two.PART", "three.partial"] {
      try Data([1]).write(to: folder.appendingPathComponent(name))
    }
    let package = folder.appendingPathComponent("four.download")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    let data = package.appendingPathComponent("payload")
    try Data([1]).write(to: data)
    let initial = try NativeDownloadScanner.read(target)
    #expect(initial.files.count == 5)
    try Data([2, 3]).write(to: folder.appendingPathComponent("finished.zip"))
    #expect(try NativeDownloadScanner.read(target) == initial)
    try Data([1, 2]).write(to: data)
    #expect(try NativeDownloadScanner.read(target) != initial)
    try FileManager.default.moveItem(at: package, to: folder.appendingPathComponent("four"))
    #expect(try NativeDownloadScanner.read(target).files.count == 3)
  }

  @Test func scannerRejectsMissingLinksAndExcessiveTrees() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("data.part")
    try Data([1]).write(to: file)
    let target = DownloadTarget(url: file, mode: .file)
    let initial = try NativeDownloadScanner.read(target)
    try Data([1, 2]).write(to: file)
    #expect(try NativeDownloadScanner.read(target) != initial)
    let link = folder.appendingPathComponent("alias.part")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(throws: (any Error).self) {
      try NativeDownloadScanner.read(.init(url: link, mode: .file))
    }
    #expect(throws: (any Error).self) {
      try NativeDownloadScanner.read(.init(url: folder, mode: .folder), maximumEntries: 1)
    }
    try FileManager.default.removeItem(at: file)
    #expect(throws: (any Error).self) { try NativeDownloadScanner.read(target) }
  }

  @Test func unchangedEventsDoNotExtendTheQuietDeadlineButGrowthDoes() async throws {
    let fixture = DownloadFixture()
    let monitor = fixture.monitor()
    try monitor.start()
    await fixture.drain()
    #expect(fixture.reads == 1)
    fixture.uptime = 20
    fixture.event?()
    await fixture.drain()
    fixture.uptime = 29
    monitor.tick()
    #expect(fixture.reads == 2)
    fixture.snapshot.files["data"]?.size = 2
    fixture.event?()
    await fixture.drain()
    fixture.uptime = 30
    monitor.tick()
    #expect(fixture.ends.isEmpty)
    fixture.uptime = 59
    monitor.tick()
    await fixture.drain()
    #expect(fixture.ends.count == 1 && fixture.ends[0] == nil)
    #expect(fixture.cancellations == 1)
    let reads = fixture.reads
    fixture.event?()
    monitor.tick()
    await fixture.drain()
    #expect(fixture.reads == reads && fixture.ends.count == 1)
  }

  @Test func completionAndReadFailureReleaseTheirRegistration() async throws {
    for failure in [false, true] {
      let fixture = DownloadFixture()
      let monitor = fixture.monitor()
      try monitor.start()
      await fixture.drain()
      if failure { fixture.readFails = true } else { fixture.snapshot.files = [:] }
      fixture.event?()
      await fixture.drain()
      #expect(fixture.ends.count == 1)
      #expect((fixture.ends[0] != nil) == failure)
      #expect(fixture.cancellations == 1)
    }
  }

  @Test func selectedFileDisappearingAfterABrowserRenameEndsCleanly() async throws {
    let fixture = DownloadFixture()
    let monitor = fixture.monitor()
    try monitor.start()
    await fixture.drain()
    fixture.readError = CocoaError(.fileReadNoSuchFile)
    fixture.event?()
    await fixture.drain()
    #expect(fixture.ends.count == 1 && fixture.ends[0] == nil)
    #expect(fixture.cancellations == 1)
  }

  @Test func deadlineRescanCatchesChangesWithoutAFileEvent() async throws {
    let fixture = DownloadFixture()
    let monitor = fixture.monitor()
    try monitor.start()
    await fixture.drain()
    fixture.snapshot.files["data"]?.size = 5
    fixture.uptime = 30
    monitor.tick()
    await fixture.drain()
    #expect(fixture.ends.isEmpty && fixture.reads == 2)
    fixture.uptime = 60
    monitor.tick()
    await fixture.drain()
    #expect(fixture.ends.count == 1)
  }

  @Test func emptyInitialSelectionAndWatchFailureDoNotKeepWatching() async throws {
    let fixture = DownloadFixture()
    fixture.snapshot.files = [:]
    let monitor = fixture.monitor()
    try monitor.start()
    await fixture.drain()
    #expect(fixture.ends.count == 1 && fixture.ends[0] != nil)
    #expect(fixture.cancellations == 1)
    let unavailable = DownloadMonitor(
      target: fixture.target, quietSeconds: 30, read: { _ in fixture.snapshot },
      subscribe: { _, _ in nil }, clock: { 0 }, finished: { _ in })
    #expect(throws: (any Error).self) { try unavailable.start() }
    #expect(throws: (any Error).self) {
      try DownloadMonitor(
        target: fixture.target, quietSeconds: .infinity, read: { _ in fixture.snapshot },
        subscribe: { _, _ in {} }, clock: { 0 }, finished: { _ in }
      ).start()
    }
  }

  @Test func downloadCompletionDoesNotInterruptManualWorkAndStopDisposesTheWatcher() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let endpoint = SocketEndpoint(stateDirectory: directory)
    let model = AppModel(endpoint: endpoint, power: { .init() })
    defer { model.shutdown() }
    model.start(duration: 60)
    let manual = try #require(model.engine.holds.first)
    let fixture = DownloadFixture()
    let download = try model.startDownload(
      fixture.target, quietSeconds: 30, makeMonitor: fixture.monitor)
    await fixture.drain()
    #expect(model.engine.holds.count == 2)
    fixture.snapshot.files = [:]
    fixture.event?()
    await fixture.drain()
    #expect(model.engine.holds.map(\.id) == [manual.id])
    #expect(
      model.history.records.contains { $0.holdID == download && $0.endReason == .conditionEnded })
    fixture.snapshot = DownloadFixture.initial
    _ = try model.startDownload(fixture.target, quietSeconds: 30, makeMonitor: fixture.monitor)
    await fixture.drain()
    _ = await model.control(.init(action: .stopAll))
    #expect(model.engine.automationPaused && model.engine.holds.isEmpty)
    #expect(fixture.cancellations == 2)
    let reads = fixture.reads
    fixture.event?()
    await fixture.drain()
    model.resumeAutomation()
    #expect(model.engine.holds.isEmpty && fixture.reads == reads)
    let restored = AppModel(endpoint: endpoint, power: { .init() })
    defer { restored.shutdown() }
    #expect(restored.engine.holds.isEmpty)
  }

  @Test func aFailedStartStillAppliesNewPowerGuardsToExistingWork() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var power = PowerState()
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { power })
    defer { model.shutdown() }
    let fixture = DownloadFixture()
    _ = try model.startDownload(fixture.target, quietSeconds: 30, makeMonitor: fixture.monitor)
    await fixture.drain()
    power.lowPowerMode = true
    #expect(throws: WakeError.lowPowerMode) {
      try model.startDownload(fixture.target, quietSeconds: 30, makeMonitor: fixture.monitor)
    }
    #expect(model.engine.holds.isEmpty && model.nativeAssertionTypes.isEmpty)
    #expect(fixture.cancellations == 1)
  }

  @Test func shutdownAndSafetyEndDownloadsAndLateReadsCannotRecreateHolds() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var power = PowerState()
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { power })
    let fixture = DownloadFixture()
    _ = try model.startDownload(fixture.target, quietSeconds: 30, makeMonitor: fixture.monitor)
    await fixture.drain()
    power.lowPowerMode = true
    model.refreshPower()
    #expect(model.engine.holds.isEmpty && fixture.cancellations == 1)
    power.lowPowerMode = false
    model.refreshPower()
    _ = try model.startDownload(fixture.target, quietSeconds: 30, makeMonitor: fixture.monitor)
    model.shutdown()
    await fixture.drain()
    #expect(model.engine.holds.isEmpty && fixture.cancellations == 2)
  }
}

@MainActor private final class DownloadFixture {
  static var initial: DownloadSnapshot {
    .init(files: ["data": .init(size: 1, modified: .distantPast, device: 1, inode: 1)])
  }
  let target = DownloadTarget(url: URL(fileURLWithPath: "/tmp/example.part"), mode: .file)
  var snapshot = initial
  var uptime: TimeInterval = 0
  var reads = 0
  var readFails = false
  var readError: CocoaError?
  var cancellations = 0
  var ends: [String?] = []
  var event: (@MainActor @Sendable () -> Void)?
  func monitor() -> DownloadMonitor {
    monitor(target, 30) { [weak self] in self?.ends.append($0) }
  }
  func monitor(
    _ target: DownloadTarget, _ quietSeconds: TimeInterval,
    _ finished: @escaping @MainActor (String?) -> Void
  ) -> DownloadMonitor {
    DownloadMonitor(
      target: target, quietSeconds: quietSeconds,
      read: { [self] _ in
        reads += 1
        if readFails { throw CocoaError(.fileReadNoPermission) }
        if let readError { throw readError }
        return snapshot
      },
      subscribe: { [self] _, event in
        self.event = event
        return { [self] in cancellations += 1 }
      }, clock: { [self] in uptime }, finished: finished)
  }
  func drain() async { for _ in 0..<20 { await Task.yield() } }
}
