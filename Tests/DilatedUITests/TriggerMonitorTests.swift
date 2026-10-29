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

  @Test func pickerListSortsByNaturalNameThenPid() {
    func native(_ id: Int32, _ name: String) -> NativeProcess {
      NativeProcess(
        id: id, name: name, path: "",
        identity: ProcessIdentity(pid: id, startedAtMicroseconds: 1))
    }
    let sorted = ProcessCatalog.pickerList([
      native(5, "b"), native(9, "a10"), native(3, "a9"), native(7, "a"), native(2, "a"),
    ])
    #expect(sorted.map(\.id) == [2, 7, 3, 9, 5])
  }

  @Test func pickerListContainsLiveProcessWithItsCatalogIdentity() throws {
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
    let pid = process.processIdentifier
    let identity = try #require(ProcessCatalog.read().first { $0.id == pid }?.identity)
    #expect(ProcessCatalog.pickerList().contains { $0.identity == identity })
  }
}
