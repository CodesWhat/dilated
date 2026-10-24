import Darwin
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct TriggerMonitorTests {
  @Test func nativeProcessExitIsObservedAndNoZombieMatchesRemain() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["15"]
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }
    #expect(
      ProcessCatalog.read().contains { $0.id == process.processIdentifier && $0.name == "sleep" })
    var changes = 0
    let monitor = TriggerMonitor(readPower: { .init() }, changed: { changes += 1 })
    defer { monitor.stop() }
    monitor.configure(rules: [
      TriggerRule(name: "Sleep test", criteria: [.process(name: "/bin/sleep")])
    ])
    #expect(monitor.read().processNames.contains("/bin/sleep"))
    process.terminate()
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while changes == 0, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(changes > 0)
    process.waitUntilExit()
    #expect(!ProcessCatalog.read().contains { $0.id == process.processIdentifier })
  }
}
