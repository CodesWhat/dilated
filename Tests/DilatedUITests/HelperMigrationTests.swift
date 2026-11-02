import DilatedControl
import DilatedCore
import Foundation
import ServiceManagement
import Testing

@testable import DilatedUI

/// Fake launchd, power state and sudo path behind the migration's injected seams.
private final class MigrationWorld: @unchecked Sendable {
  private let lock = NSLock()
  private var _job: PackageHelperCheck.JobState
  private var _sleepDisabled: Bool
  private var _marker = false
  private var _revertWorks = true
  private var _reverts = 0

  init(job: PackageHelperCheck.JobState = .loaded, sleepDisabled: Bool = false) {
    _job = job
    _sleepDisabled = sleepDisabled
  }

  var job: PackageHelperCheck.JobState {
    get { lock.withLock { _job } }
    set { lock.withLock { _job = newValue } }
  }
  var marker: Bool {
    get { lock.withLock { _marker } }
    set { lock.withLock { _marker = newValue } }
  }
  var revertWorks: Bool {
    get { lock.withLock { _revertWorks } }
    set { lock.withLock { _revertWorks = newValue } }
  }
  var reverts: Int { lock.withLock { _reverts } }
  var readback: ClosedLidReadback {
    lock.withLock {
      ClosedLidReadback(effectiveDisabled: _sleepDisabled, storedDisabled: _sleepDisabled)
    }
  }
  func revert() -> Bool {
    lock.withLock {
      _reverts += 1
      if _revertWorks { _sleepDisabled = false }
      return _revertWorks
    }
  }
}

@MainActor private func makeMigration(
  _ service: FakeHelperRegistration, _ world: MigrationWorld, _ directory: URL,
  attempts: Int = 3
) -> HelperMigration {
  HelperMigration(
    service: service, stateDirectory: directory, jobState: { world.job },
    readPower: { world.readback }, hasSessionMarker: { world.marker },
    revertSleep: { world.revert() }, sleep: { _ in }, jobAttempts: attempts)
}

private struct UnregisterFailure: LocalizedError {
  var errorDescription: String? { "Operation not permitted" }
}

@MainActor struct HelperMigrationTests {
  private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  @Test(arguments: [SMAppService.Status.enabled, .requiresApproval])
  func aRegisteredHelperIsUnregisteredAndItsJobConfirmedGone(status: SMAppService.Status)
    async throws
  {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = MigrationWorld()
    let service = FakeHelperRegistration(status: status)
    service.onUnregister = { world.job = .absent }
    let migration = makeMigration(service, world, directory)
    await migration.run()
    #expect(service.unregisterCalls == 1 && service.status == .notRegistered)
    #expect(migration.record?.outcome == .removed)
    #expect(migration.needsAttention == false)
    #expect(world.reverts == 0)
    // The result outlives the launch, so Settings can show it.
    let reopened = makeMigration(service, world, directory)
    #expect(reopened.record?.outcome == .removed)
    reopened.dismiss()
    #expect(reopened.record == nil)
    #expect(makeMigration(service, world, directory).record == nil)
  }

  @Test(arguments: [SMAppService.Status.notRegistered, .notFound])
  func nothingRegisteredAndNoJobIsANoOp(status: SMAppService.Status) async {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = MigrationWorld(job: .absent, sleepDisabled: true)
    let service = FakeHelperRegistration(status: status)
    let migration = makeMigration(service, world, directory)
    await migration.run()
    #expect(service.unregisterCalls == 0)
    #expect(migration.record == nil)
    #expect(world.reverts == 0)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
  }

  @Test func aLoadedJobIsMigratedEvenWhenTheServiceReportsNotRegistered() async {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = MigrationWorld()
    let service = FakeHelperRegistration(status: .notRegistered)
    service.onUnregister = { world.job = .absent }
    let migration = makeMigration(service, world, directory)
    await migration.run()
    #expect(service.unregisterCalls == 1)
    #expect(migration.record?.outcome == .removed)
  }

  @Test func anUnregisterFailureThatLeavesTheJobIsRecordedWithoutThrowingOrTouchingSleep() async {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = MigrationWorld(sleepDisabled: true)
    let service = FakeHelperRegistration(status: .enabled)
    service.unregisterError = UnregisterFailure()
    let migration = makeMigration(service, world, directory)
    await migration.run()
    #expect(migration.running == false)
    #expect(migration.record?.outcome == .failed)
    #expect(migration.needsAttention)
    #expect(migration.record?.message.contains("Operation not permitted") == true)
    #expect(world.reverts == 0)
  }

  @Test func anUnregisterErrorIsIgnoredWhenTheJobIsGoneAnyway() async {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = MigrationWorld(job: .absent)
    let service = FakeHelperRegistration(status: .requiresApproval)
    service.unregisterError = UnregisterFailure()
    let migration = makeMigration(service, world, directory)
    await migration.run()
    #expect(migration.record?.outcome == .removed)
  }

  @Test func aJobThatNeverLeavesLaunchdIsAFailureAfterBoundedPolling() async {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = MigrationWorld(job: .unknown)
    let service = FakeHelperRegistration(status: .enabled)
    let migration = makeMigration(service, world, directory, attempts: 4)
    await migration.run()
    #expect(migration.record?.outcome == .failed)
    #expect(migration.record?.message.contains("launchd still lists the job") == true)
  }

  @Test func sleepLeftOffByTheHelperIsRevertedThroughTheSudoPath() async {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = MigrationWorld(sleepDisabled: true)
    let service = FakeHelperRegistration(status: .enabled)
    service.onUnregister = { world.job = .absent }
    let migration = makeMigration(service, world, directory)
    await migration.run()
    #expect(world.reverts == 1)
    #expect(migration.record?.outcome == .restoredSleep)
    #expect(world.readback.confirmedDisabled)
  }

  @Test func aFailedRevertSurfacesRestoreNormalSleepAndClearsOnceItWorks() async {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = MigrationWorld(sleepDisabled: true)
    world.revertWorks = false
    let service = FakeHelperRegistration(status: .enabled)
    service.onUnregister = { world.job = .absent }
    let migration = makeMigration(service, world, directory)
    await migration.run()
    #expect(migration.record?.outcome == .needsRestore)
    #expect(migration.needsAttention)
    migration.sleepRestored()
    #expect(migration.record?.outcome == .restoredSleep && !migration.needsAttention)
    // sleepRestored only touches a pending restore.
    migration.dismiss()
    migration.sleepRestored()
    #expect(migration.record == nil)
  }

  @Test func sleepDisabledByADilatedSessionIsLeftToTheSessionGuard() async {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = MigrationWorld(sleepDisabled: true)
    world.marker = true
    let service = FakeHelperRegistration(status: .enabled)
    service.onUnregister = { world.job = .absent }
    let migration = makeMigration(service, world, directory)
    await migration.run()
    #expect(world.reverts == 0)
    #expect(migration.record?.outcome == .removed)
  }

  @Test func theRecordSurvivesUndecodableFilesAndIgnoresThem() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("not json".utf8).write(
      to: directory.appendingPathComponent(HelperMigration.fileName))
    let migration = makeMigration(
      FakeHelperRegistration(status: .notRegistered), MigrationWorld(job: .absent), directory)
    #expect(migration.record == nil)
  }

  @Test func aFailedMigrationNeverBlocksLaunchAndShowsAMessage() async {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = MigrationWorld()
    let service = FakeHelperRegistration(status: .enabled)
    service.unregisterError = UnregisterFailure()
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      closedLid: inertClosedLid(),
      helperMigration: makeMigration(service, world, directory),
      closedLidPermission: readyPermissionModel())
    defer { model.shutdown() }
    model.begin()
    // begin() returns before the migration finishes; the result arrives afterwards.
    for _ in 0..<200 where model.helperMigration.record == nil {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.helperMigration.record?.outcome == .failed)
    for _ in 0..<200 where model.message == nil {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.message?.contains("old background helper") == true)
    model.start(duration: 60)
    #expect(model.engine.holds.count == 1)
  }
}
