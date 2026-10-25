import Darwin
import Foundation
import Testing

@testable import DilatedCore

struct PowerDriverTests {
  @Test func unknownOrPartialReadbackNeverConfirmsTheRequestedPowerState() {
    #expect(!ClosedLidReadback().confirmedDisabled)
    #expect(!ClosedLidReadback(effectiveDisabled: true, storedDisabled: false).confirmedEnabled)
    #expect(ClosedLidReadback(effectiveDisabled: false, storedDisabled: false).confirmedDisabled)
    #expect(ClosedLidReadback(effectiveDisabled: true, storedDisabled: true).confirmedEnabled)
  }

  @Test func storedPowerReadbackUsesThePreferencesService() throws {
    let preferences = try PowerPreferencesFixture()
    defer { preferences.remove() }
    try preferences.writeDisk(false)
    preferences.set(true)
    #expect(preferences.read() == true)
    preferences.set(false)
    #expect(preferences.read() == false)
  }

  @Test func missingOrNonBooleanPowerPreferencesStayUnknown() throws {
    let preferences = try PowerPreferencesFixture()
    defer { preferences.remove() }
    #expect(preferences.read() == nil)
    for value: Any in ["true", 1, 0, 2] {
      preferences.set(value)
      #expect(preferences.read() == nil)
    }
  }

  @Test func anOverdueChildIsKilledAndReaped() async throws {
    let result = try await BoundedProcess.run(
      executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.05)
    #expect(result.timedOut)
    #expect(kill(result.processID, 0) == -1)
    #expect(errno == ESRCH)
  }

  @Test func exitStatusAndLaunchErrorsArePreserved() async throws {
    let result = try await BoundedProcess.run(
      executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], timeout: 1)
    #expect(result.status == 1)
    #expect(!result.timedOut)
    await #expect(throws: (any Error).self) {
      try await BoundedProcess.run(
        executable: URL(fileURLWithPath: "/nonexistent/dilated-program"), arguments: [], timeout: 1)
    }
  }

  @Test func aPendingEnableCannotOvertakeAFollowingReset() async throws {
    let runner = GatedPowerRunner()
    let driver = SerialPowerDriver(runner: runner, readback: { await runner.readback() })
    let enable = Task { try await driver.setSleepDisabled(true) }
    await runner.waitForEnable()
    let disable = await driver.enqueue(.setSleepDisabled(false))
    await runner.releaseEnable()
    _ = try await enable.value
    _ = try await disable.value
    let state = await driver.readback()
    #expect(state.confirmedDisabled)
    let calls = await runner.calls
    #expect(calls == [.setSleepDisabled(true), .setSleepDisabled(false)])
  }
}

private actor GatedPowerRunner: PowerCommandRunning {
  var calls: [PowerCommand] = []
  private var enabled = false
  private var enableStarted = false
  private var startedWaiter: CheckedContinuation<Void, Never>?
  private var release: CheckedContinuation<Void, Never>?

  func run(_ command: PowerCommand) async throws {
    calls.append(command)
    if command == .setSleepDisabled(true) {
      enableStarted = true
      startedWaiter?.resume()
      startedWaiter = nil
      await withCheckedContinuation { release = $0 }
      enabled = true
    } else if command == .setSleepDisabled(false) {
      enabled = false
    }
  }
  func waitForEnable() async {
    if !enableStarted { await withCheckedContinuation { startedWaiter = $0 } }
  }
  func releaseEnable() {
    release?.resume()
    release = nil
  }
  func readback() -> ClosedLidReadback {
    ClosedLidReadback(effectiveDisabled: enabled, storedDisabled: enabled)
  }
}

private struct PowerPreferencesFixture {
  let directory: URL
  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dilated-power-readback-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  }
  var domain: CFString { directory.appendingPathComponent("preferences").path as CFString }
  var file: URL { directory.appendingPathComponent("preferences.plist") }
  func writeDisk(_ value: Bool) throws {
    try PropertyListSerialization.data(
      fromPropertyList: ["SystemPowerSettings": ["SleepDisabled": value]],
      format: .binary, options: 0
    ).write(to: file)
  }
  func set(_ value: Any) {
    CFPreferencesSetValue(
      "SystemPowerSettings" as CFString, ["SleepDisabled": value] as CFDictionary,
      domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    #expect(CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
  }
  func read() -> Bool? {
    NativeClosedLidPower.storedSleepDisabled(
      domain: domain, user: kCFPreferencesCurrentUser, host: kCFPreferencesAnyHost)
  }
  func remove() {
    CFPreferencesSetValue(
      "SystemPowerSettings" as CFString, nil,
      domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    _ = CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    try? FileManager.default.removeItem(at: directory)
  }
}
