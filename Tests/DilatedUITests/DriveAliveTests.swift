import DilatedControl
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct DriveAliveTests {
  @Test func defaultsStayOffAndConfigurationRoundTrips() throws {
    let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"countdown":true}"#.utf8))
    #expect(!old.driveAlive.enabled && old.driveAlive.onlyWhileAwake)
    #expect(old.driveAlive.intervalSeconds == 60 && old.driveAlive.volumes.isEmpty)
    var settings = old
    settings.driveAlive = DriveFixture.configuration
    let saved = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(saved == settings)
    for interval in [0, 29, 3601] {
      var invalid = DriveFixture.configuration
      invalid.intervalSeconds = interval
      #expect(invalid.validationMessage != nil)
    }
    var duplicate = DriveFixture.configuration
    duplicate.volumes.append(duplicate.volumes[0])
    #expect(duplicate.validationMessage != nil)
  }

  @Test func partialSavedConfigurationKeepsTheSafeDefaults() throws {
    let settings = try JSONDecoder().decode(
      AppSettings.self, from: Data(#"{"driveAlive":{"enabled":false},"countdown":true}"#.utf8))
    #expect(settings.countdown && settings.driveAlive == DriveAliveSettings())
  }

  @Test func awakeAndPauseGatesOwnTheOnlyScheduledCycle() async {
    let fixture = DriveFixture()
    let controller = fixture.controller()
    controller.configure(.init(), awake: true, paused: false)
    await fixture.drain()
    #expect(fixture.pulses.isEmpty && fixture.schedules.isEmpty)
    let settings = DriveFixture.configuration
    controller.configure(settings, awake: false, paused: false)
    await fixture.drain()
    #expect(fixture.pulses.isEmpty)
    controller.configure(settings, awake: true, paused: false)
    await fixture.drain()
    #expect(fixture.pulses == [DriveFixture.volume.id])
    #expect(fixture.schedules.count == 1 && fixture.schedules[0].0 == 60)
    for _ in 0..<10 { controller.configure(settings, awake: true, paused: false) }
    await fixture.drain()
    #expect(fixture.pulses.count == 1 && fixture.schedules.count == 1)
    controller.configure(settings, awake: true, paused: true)
    #expect(fixture.cancellations == 1)
    fixture.schedules[0].1()
    await fixture.drain()
    #expect(fixture.pulses.count == 1)
    controller.configure(settings, awake: true, paused: false)
    await fixture.drain()
    #expect(fixture.pulses.count == 2)
    controller.stop()
    #expect(fixture.cancellations == 2)
  }

  @Test func alwaysModeDoesNotNeedAnAwakeHoldButStillObeysStopAndShutdown() async {
    let fixture = DriveFixture()
    let controller = fixture.controller()
    var settings = DriveFixture.configuration
    settings.onlyWhileAwake = false
    controller.configure(settings, awake: false, paused: false)
    await fixture.drain()
    #expect(fixture.pulses.count == 1)
    controller.stop()
    fixture.schedules[0].1()
    controller.configure(settings, awake: true, paused: false)
    await fixture.drain()
    #expect(fixture.pulses.count == 1)
  }

  @Test func volumeFailuresAreVisibleAndWaitForTheNextCycle() async {
    let fixture = DriveFixture()
    fixture.failed = true
    let controller = fixture.controller()
    defer { controller.stop() }
    controller.configure(DriveFixture.configuration, awake: true, paused: false)
    await fixture.drain()
    #expect(fixture.pulses.count == 1 && fixture.schedules.count == 1)
    #expect(controller.statuses[DriveFixture.volume.id]?.contains("read-only") == true)
    fixture.failed = false
    fixture.schedules[0].1()
    await fixture.drain()
    #expect(fixture.pulses.count == 2 && fixture.schedules.count == 2)
    #expect(controller.statuses[DriveFixture.volume.id] == "Active")
  }

  @Test func shutdownDuringAWriteDoesNotStartAnotherVolumeOrTimer() async throws {
    var continuation: CheckedContinuation<Void, Never>?
    var pulses = 0
    var writeFinished = false
    var schedules = 0
    let controller = DriveAliveController(
      pulse: { _ in
        pulses += 1
        await withCheckedContinuation { continuation = $0 }
        writeFinished = true
      },
      schedule: { _, _ in
        schedules += 1
        return {}
      })
    var settings = DriveFixture.configuration
    settings.volumes.append(.init(id: "second", name: "Second", path: "/Volumes/Second"))
    controller.configure(settings, awake: true, paused: false)
    for _ in 0..<100 where continuation == nil { try await Task.sleep(for: .milliseconds(1)) }
    try #require(continuation != nil)
    controller.stop()
    continuation?.resume()
    continuation = nil
    let deadline = ContinuousClock.now + .seconds(5)
    while !writeFinished && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(writeFinished)
    #expect(pulses == 1 && schedules == 0)
  }

  @Test func changingSettingsWaitsForTheExistingWriteBeforeStartingAnotherCycle() async throws {
    var continuation: CheckedContinuation<Void, Never>?
    var pulses = 0
    var delays: [TimeInterval] = []
    let controller = DriveAliveController(
      pulse: { _ in
        pulses += 1
        if pulses == 1 { await withCheckedContinuation { continuation = $0 } }
      },
      schedule: { seconds, _ in
        delays.append(seconds)
        return {}
      })
    defer { controller.stop() }
    var settings = DriveFixture.configuration
    controller.configure(settings, awake: true, paused: false)
    for _ in 0..<100 where continuation == nil { try await Task.sleep(for: .milliseconds(1)) }
    try #require(continuation != nil)
    settings.intervalSeconds = 120
    controller.configure(settings, awake: true, paused: false)
    #expect(pulses == 1 && delays.isEmpty)
    continuation?.resume()
    continuation = nil
    let deadline = ContinuousClock.now + .seconds(5)
    while delays.isEmpty && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(pulses == 2)
    #expect(delays == [120])
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["DILATED_DRIVE_FIXTURE"] != nil))
  func nativeSelectedVolumeAcceptsWritesOrRejectsReadOnlyMounts() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["DILATED_DRIVE_FIXTURE"])
    let folder = URL(fileURLWithPath: path)
    let selected = try #require(try NativeDriveAlive.mounted().first { $0.volume.path == path })
    let before = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
    if selected.readOnly {
      await #expect(throws: (any Error).self) { try await NativeDriveAlive.pulse(selected.volume) }
    } else {
      try await NativeDriveAlive.pulse(selected.volume)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: path).sorted() == before)
    #expect(try Data(contentsOf: folder.appendingPathComponent("user-file")) == Data([1, 2, 3]))
  }

  @Test func writerCreatesOnlyANewFileAndCleansUpWithoutTouchingExistingFiles() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let existing = folder.appendingPathComponent(".dilated-drive-alive-existing")
    try Data([1, 2, 3]).write(to: existing)
    #expect(throws: (any Error).self) {
      try DriveAliveWriter.write(in: folder, name: existing.lastPathComponent, validate: { _ in })
    }
    #expect(try Data(contentsOf: existing) == Data([1, 2, 3]))
    let pulse = ".dilated-drive-alive-" + UUID().uuidString
    var validated = false
    try DriveAliveWriter.write(in: folder, name: pulse) { _ in validated = true }
    #expect(validated)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: folder.path) == [
        existing.lastPathComponent
      ])
    #expect(throws: (any Error).self) {
      try DriveAliveWriter.write(in: folder, name: pulse) { _ in
        throw CocoaError(.fileWriteVolumeReadOnly)
      }
    }
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(pulse).path))
    let alias = folder.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
    #expect(throws: (any Error).self) {
      try DriveAliveWriter.write(in: alias, name: pulse, validate: { _ in })
    }
  }

  @Test func aMissingVolumeNeverFallsBackToTheSameMountPath() async throws {
    let missing = DriveAliveVolume(id: "uuid:missing", name: "Missing", path: "/")
    await #expect(throws: (any Error).self) { try await NativeDriveAlive.pulse(missing) }
  }

  @Test func modelStopPausesWritesAndManualWorkDoesNotResumeThem() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = DriveFixture()
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    model.driveAlive = fixture.controller()
    model.settings.driveAlive = DriveFixture.configuration
    model.start(duration: 60)
    await fixture.drain()
    #expect(fixture.pulses.count == 1)
    _ = await model.control(.init(action: .stopAll))
    #expect(fixture.cancellations == 1)
    model.start(duration: 60)
    await fixture.drain()
    #expect(fixture.pulses.count == 1 && model.engine.automationPaused)
    model.resumeAutomation()
    await fixture.drain()
    #expect(fixture.pulses.count == 2 && model.engine.holds.count == 1)
    model.shutdown()
    #expect(fixture.cancellations == 2)
  }
}

@MainActor private final class DriveFixture {
  static var volume: DriveAliveVolume {
    .init(id: "uuid:test", name: "Test", path: "/Volumes/Test")
  }
  static var configuration: DriveAliveSettings {
    var configuration = DriveAliveSettings()
    configuration.enabled = true
    configuration.volumes = [volume]
    return configuration
  }
  var failed = false
  var pulses: [String] = []
  var schedules: [(TimeInterval, @MainActor @Sendable () -> Void)] = []
  var cancellations = 0
  func controller() -> DriveAliveController {
    DriveAliveController(
      pulse: { [self] volume in
        pulses.append(volume.id)
        if failed { throw DriveAliveError("The volume is read-only.") }
      },
      schedule: { [self] seconds, fire in
        schedules.append((seconds, fire))
        return { [self] in cancellations += 1 }
      })
  }
  func drain() async { for _ in 0..<20 { await Task.yield() } }
}
