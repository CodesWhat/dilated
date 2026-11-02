import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

/// Runs the real `dilated` executable, built next to the test bundle. The watchdog waits on a
/// stand-in "app" (a `sleep` child) and is killed before that child, so it never reaches sudo.
private final class BundleAnchor {}

struct ClosedLidWatchdogSpawnerTests {
  private static var executable: URL? {
    Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("dilated")
  }

  private struct Fixture {
    let app: Process
    let launch: ClosedLidWatchdogLaunch

    init() throws {
      app = Process()
      app.executableURL = URL(fileURLWithPath: "/bin/sleep")
      app.arguments = ["300"]
      try app.run()
      let start = try #require(ProcessStartTime.micros(pid: app.processIdentifier))
      let store = ClosedLidMarkerStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(
          "lid-spawn-\(UUID().uuidString)"))
      let generation = UUID()
      try store.write(
        ClosedLidSessionMarker(
          pid: app.processIdentifier, processStartMicros: start, generation: generation,
          enabledAt: Date()))
      launch = ClosedLidWatchdogLaunch(
        pid: app.processIdentifier, marker: store.file, generation: generation)
    }

    func cleanUp(watchdog: pid_t?) {
      if let watchdog { kill(watchdog, SIGKILL) }
      app.terminate()
      app.waitUntilExit()
      try? FileManager.default.removeItem(at: launch.marker.deletingLastPathComponent())
    }
  }

  @Test func theWatchdogRunsInItsOwnSession() throws {
    let executable = try #require(Self.executable)
    let fixture = try Fixture()
    var watchdog: pid_t?
    defer { fixture.cleanUp(watchdog: watchdog) }
    watchdog = try ClosedLidWatchdogSpawner.spawn(fixture.launch, executable: executable)
    let child = try #require(watchdog)
    #expect(getsid(child) != getsid(0))
    #expect(getsid(child) == child)
  }

  @Test func theWatchdogSurvivesItsSpawnerDying() async throws {
    let executable = try #require(Self.executable)
    let fixture = try Fixture()
    var watchdog: pid_t?
    defer { fixture.cleanUp(watchdog: watchdog) }
    // Stand-in for the app: an intermediate that starts the watchdog in a new session (the
    // posix_spawn SETSID flag has no perl equivalent, so setsid() before exec), then gets killed.
    let intermediate = Process()
    let output = Pipe()
    intermediate.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    intermediate.arguments =
      [
        "-MPOSIX", "-e",
        "my $p = fork; if (!$p) { POSIX::setsid(); exec @ARGV } print \"$p\\n\"; $| = 1; sleep 300",
        executable.path,
      ] + ClosedLidWatchdogCommand.arguments(for: fixture.launch)
    intermediate.standardOutput = output
    try intermediate.run()
    defer { if intermediate.isRunning { kill(intermediate.processIdentifier, SIGKILL) } }
    let line = String(
      decoding: output.fileHandleForReading.availableData, as: UTF8.self)
    let child = try #require(pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)))
    watchdog = child
    kill(intermediate.processIdentifier, SIGKILL)
    intermediate.waitUntilExit()
    try await Task.sleep(for: .milliseconds(600))
    #expect(kill(child, 0) == 0)
    #expect(ProcessStartTime.micros(pid: child) != nil)
  }

  @Test func aNewGenerationReplacesTheOldWatchdog() async throws {
    let executable = try #require(Self.executable)
    let first = try Fixture()
    let second = try Fixture()
    let current = ClosedLidWatchdogSpawner.Current()
    var older: pid_t?
    var newer: pid_t?
    defer {
      first.cleanUp(watchdog: older)
      second.cleanUp(watchdog: newer)
    }
    older = try ClosedLidWatchdogSpawner.spawn(
      first.launch, executable: executable, current: current)
    newer = try ClosedLidWatchdogSpawner.spawn(
      second.launch, executable: executable, current: current)
    let oldPID = try #require(older)
    let newPID = try #require(newer)
    #expect(oldPID != newPID)
    // The replaced watchdog is signalled and reaped; exactly one stays.
    for _ in 0..<200 where ProcessStartTime.micros(pid: oldPID) != nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(ProcessStartTime.micros(pid: oldPID) == nil)
    #expect(ProcessStartTime.micros(pid: newPID) != nil)
    #expect(current.running == newPID)
  }

  @Test func aMissingExecutableIsRefused() {
    #expect(throws: WatchdogSpawnError.self) {
      try ClosedLidWatchdogSpawner.spawn(
        ClosedLidWatchdogLaunch(
          pid: 1, marker: URL(fileURLWithPath: "/tmp/none.json"), generation: UUID()),
        executable: URL(fileURLWithPath: "/nonexistent/dilated"))
    }
  }
}
