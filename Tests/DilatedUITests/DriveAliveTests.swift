import DilatedControl
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct DriveAliveTests {
  @Test func volumeModesPreserveLegacyChoicesAndUnknownValuesCannotStartIdleWrites() throws {
    let json =
      #"{"driveAlive":{"enabled":true,"onlyWhileAwake":false,"volumes":[{"id":"uuid:test","name":"Test","path":"/Volumes/Test"}]},"countdown":true}"#
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    #expect(settings.countdown && settings.driveAlive.volumes[0].mode == .inherit)
    #expect(settings.driveAlive.eligibleVolumes(awake: false, paused: false).count == 1)
    var object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    var drive = try #require(object["driveAlive"] as? [String: Any])
    for value: Any in ["future", 4, NSNull()] {
      var volume = try #require((drive["volumes"] as? [[String: Any]])?.first)
      volume["mode"] = value
      drive["volumes"] = [volume]
      object["driveAlive"] = drive
      let saved = try JSONDecoder().decode(
        AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
      #expect(saved.countdown && saved.driveAlive.volumes[0].mode == .awakeOnly)
      #expect(saved.driveAlive.eligibleVolumes(awake: false, paused: false).isEmpty)
    }
    var configured = settings
    configured.driveAlive.volumes[0].mode = .always
    #expect(
      try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(configured))
        == configured)
  }

  @Test func mixedModesRespectGlobalOffPauseAndEachVolumesOwnChoice() {
    var settings = DriveFixture.configuration
    var always = DriveFixture.volume
    always.mode = .always
    let awake = DriveAliveVolume(
      id: "awake", name: "Awake", path: "/Volumes/Awake", mode: .awakeOnly)
    let inherited = DriveAliveVolume(id: "inherit", name: "Inherited", path: "/Volumes/Inherited")
    settings.volumes = [always, awake, inherited]
    #expect(settings.eligibleVolumes(awake: false, paused: false).map(\.id) == [always.id])
    settings.onlyWhileAwake = false
    #expect(
      settings.eligibleVolumes(awake: false, paused: false).map(\.id) == [always.id, inherited.id])
    #expect(settings.eligibleVolumes(awake: true, paused: false).count == 3)
    #expect(settings.eligibleVolumes(awake: true, paused: true).isEmpty)
    settings.enabled = false
    #expect(settings.eligibleVolumes(awake: true, paused: false).isEmpty)
  }

  @Test func awakeningAddsOnlyNewlyEligibleVolumesAndKeepsAlwaysWritesOnTheirCadence() async {
    let fixture = DriveFixture()
    let controller = fixture.controller()
    defer { controller.stop() }
    var settings = DriveFixture.configuration
    var always = DriveFixture.volume
    always.mode = .always
    let awake = DriveAliveVolume(
      id: "awake", name: "Awake", path: "/Volumes/Awake", mode: .awakeOnly)
    settings.volumes = [always, awake]
    controller.configure(settings, awake: false, paused: false)
    await fixture.drain()
    #expect(fixture.pulses == [always.id])
    fixture.now += 10
    controller.configure(settings, awake: true, paused: false)
    await fixture.drain()
    #expect(fixture.pulses == [always.id, awake.id])
    #expect(fixture.schedules.last?.0 == 50)
    fixture.now += 5
    controller.configure(settings, awake: false, paused: false)
    await fixture.drain()
    #expect(fixture.pulses == [always.id, awake.id])
    #expect(fixture.schedules.last?.0 == 45)
    fixture.fire(at: fixture.schedules.count - 1)
    await fixture.drain()
    #expect(fixture.pulses == [always.id, awake.id, always.id])
    #expect(fixture.schedules.last?.0 == 60)
    #expect(controller.statuses[awake.id] == nil)
  }

  @Test func losingAwakeEligibilityCancelsThatWriteAndContinuesOtherEligibleVolumesSerially()
    async throws
  {
    var continuation: CheckedContinuation<Void, Never>?
    var pulses: [String] = []
    var schedules = 0
    var overlapping = false
    var writing = false
    let controller = DriveAliveController(
      pulse: { volume in
        overlapping = overlapping || writing
        writing = true
        pulses.append(volume.id)
        if volume.id == "awake" { await withCheckedContinuation { continuation = $0 } }
        writing = false
      },
      schedule: { _, _ in
        schedules += 1
        return {}
      })
    defer { controller.stop() }
    var settings = DriveFixture.configuration
    var always = DriveFixture.volume
    always.mode = .always
    settings.volumes = [
      .init(id: "awake", name: "Awake", path: "/Volumes/Awake", mode: .awakeOnly), always,
    ]
    controller.configure(settings, awake: true, paused: false)
    for _ in 0..<100 where continuation == nil { try await Task.sleep(for: .milliseconds(1)) }
    try #require(continuation != nil)
    controller.configure(settings, awake: false, paused: false)
    #expect(pulses == ["awake"] && schedules == 0)
    continuation?.resume()
    continuation = nil
    let deadline = ContinuousClock.now + .seconds(1)
    while schedules == 0 && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(pulses == ["awake", always.id] && schedules == 1 && !overlapping)
    #expect(controller.statuses["awake"] == nil)
    #expect(controller.statuses[always.id] == "Active")
  }

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
    fixture.fire(at: 0)
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
    fixture.fire(at: 0)
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
    fixture.fire(at: 0)
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
      clock: { 1000 },
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

  @Test(.enabled(if: ProcessInfo.processInfo.environment["DILATED_DRIVE_FIXTURE"] != nil))
  func nativeMixedModesPulseOnlyTheEligibleVolumeAndStillPause() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["DILATED_DRIVE_FIXTURE"])
    let mount = try #require(try NativeDriveAlive.mounted().first { $0.volume.path == path })
    let before = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
    var selected = mount.volume
    selected.mode = .always
    var pulses: [String] = []
    var scheduled: (@MainActor @Sendable () -> Void)?
    let controller = DriveAliveController(
      clock: { 1000 },
      pulse: { volume in
        pulses.append(volume.id)
        try await NativeDriveAlive.pulse(volume)
      },
      schedule: { _, fire in
        scheduled = fire
        return {}
      })
    defer { controller.stop() }
    var settings = DriveAliveSettings()
    settings.enabled = true
    settings.volumes = [
      .init(id: "native-awake-only", name: "Inactive", path: "/Volumes/Missing", mode: .awakeOnly),
      selected,
    ]
    controller.configure(settings, awake: false, paused: false)
    let deadline = ContinuousClock.now + .seconds(5)
    while scheduled == nil && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(scheduled != nil)
    #expect(pulses == [selected.id])
    #expect(controller.statuses["native-awake-only"] == nil)
    if mount.readOnly {
      #expect(controller.statuses[selected.id]?.contains("read-only") == true)
    } else {
      #expect(controller.statuses[selected.id] == "Active")
    }
    controller.configure(settings, awake: false, paused: true)
    scheduled?()
    for _ in 0..<20 { await Task.yield() }
    #expect(pulses == [selected.id])
    #expect(try FileManager.default.contentsOfDirectory(atPath: path).sorted() == before)
    #expect(
      try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("user-file"))
        == Data([1, 2, 3]))
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

  @Test(arguments: [DriveAliveMode.inherit, .always])
  func modelStopPausesWritesAndManualWorkDoesNotResumeThem(mode: DriveAliveMode) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = DriveFixture()
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    model.driveAlive = fixture.controller()
    var settings = DriveFixture.configuration
    settings.volumes[0].mode = mode
    model.settings.driveAlive = settings
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
  var now: TimeInterval = 1000
  var failed = false
  var pulses: [String] = []
  var schedules: [(TimeInterval, @MainActor @Sendable () -> Void)] = []
  var cancellations = 0
  func controller() -> DriveAliveController {
    DriveAliveController(
      clock: { [self] in now },
      pulse: { [self] volume in
        pulses.append(volume.id)
        if failed { throw DriveAliveError("The volume is read-only.") }
      },
      schedule: { [self] seconds, fire in
        schedules.append((seconds, fire))
        return { [self] in cancellations += 1 }
      })
  }
  func fire(at index: Int) {
    now += schedules[index].0
    schedules[index].1()
  }
  func drain() async { for _ in 0..<20 { await Task.yield() } }
}
