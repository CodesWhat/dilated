#if !MAS_CHANNEL
  import Darwin
  import DilatedCore
  import Foundation
  import Testing

  @testable import DilatedUI

  @MainActor struct TriggerMonitorTests {
    @Test func nativeProcessExitIsObservedAndNoZombieMatchesRemain() async throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sleep")
      process.arguments = ["120"]
      try process.run()
      defer {
        if process.isRunning {
          process.terminate()
          waitForExit(process)
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
      let scanDeadline = ContinuousClock.now.advanced(by: .seconds(30))
      while !monitor.read().processNames.contains("/bin/sleep"), ContinuousClock.now < scanDeadline
      {
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(monitor.read().processNames.contains("/bin/sleep"))
      changes = 0
      process.terminate()
      let deadline = ContinuousClock.now.advanced(by: .seconds(3))
      while changes == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(changes > 0)
      #expect(waitForExit(process), "The child did not exit.")
      #expect(!ProcessCatalog.read().contains { $0.id == process.processIdentifier })
    }

    private final class ScanProbe: @unchecked Sendable {
      private let lock = NSLock()
      private let gate = DispatchSemaphore(value: 0)
      private var _scans = 0
      private var _processes: [NativeProcess]
      init(_ processes: [NativeProcess]) { _processes = processes }
      var scans: Int { lock.withLock { _scans } }
      func set(_ processes: [NativeProcess]) { lock.withLock { _processes = processes } }
      func release() { gate.signal() }
      func scan() -> [NativeProcess] {
        lock.withLock { _scans += 1 }
        gate.wait()
        return lock.withLock { _processes }
      }
    }

    private static func fake(_ pid: Int32, _ name: String) -> NativeProcess {
      NativeProcess(
        id: pid, name: name, path: "/bin/\(name)",
        identity: ProcessIdentity(pid: pid, startedAtMicroseconds: UInt64(pid)))
    }

    private func settle(_ condition: () -> Bool) async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(30))
      while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    @Test func processScansCoalesceAndApplyResultsInOrder() async throws {
      let probe = ScanProbe([Self.fake(900_001, "make")])
      var changes = 0
      let monitor = TriggerMonitor(
        readPower: { .init() }, readProcesses: { probe.scan() },
        workspaceNotifications: NotificationCenter(), changed: { changes += 1 })
      defer { monitor.stop() }
      monitor.configure(rules: [TriggerRule(name: "Make", criteria: [.process(name: "make")])])
      #expect(monitor.read().processNames.isEmpty)
      try await settle { probe.scans == 1 }
      for _ in 0..<10 { _ = monitor.read() }
      #expect(probe.scans == 1)
      probe.release()
      try await settle { probe.scans == 2 }
      #expect(probe.scans == 2)
      probe.set([Self.fake(900_002, "make")])
      probe.release()
      try await settle { changes >= 2 }
      #expect(changes >= 2)
      #expect(monitor.read().processNames.contains("make"))
      probe.release()
      probe.release()
    }

    @Test func readInsideChangeNotificationDoesNotStartAScan() async throws {
      let probe = ScanProbe([Self.fake(900_004, "make")])
      var monitor: TriggerMonitor?
      var changes = 0
      monitor = TriggerMonitor(
        readPower: { .init() }, readProcesses: { probe.scan() },
        workspaceNotifications: NotificationCenter(),
        changed: {
          changes += 1
          _ = monitor?.read()
        })
      defer { monitor?.stop() }
      monitor?.configure(rules: [TriggerRule(name: "Make", criteria: [.process(name: "make")])])
      _ = monitor?.read()
      probe.release()
      try await settle { changes == 1 }
      try await Task.sleep(for: .milliseconds(50))
      #expect(probe.scans == 1)
      probe.release()
    }

    @Test func unchangedProcessListDoesNotNotify() async throws {
      let probe = ScanProbe([Self.fake(900_003, "make")])
      var changes = 0
      let monitor = TriggerMonitor(
        readPower: { .init() }, readProcesses: { probe.scan() },
        workspaceNotifications: NotificationCenter(), changed: { changes += 1 })
      defer { monitor.stop() }
      monitor.configure(rules: [TriggerRule(name: "Make", criteria: [.process(name: "make")])])
      _ = monitor.read()
      probe.release()
      try await settle { changes == 1 }
      _ = monitor.read()
      try await settle { probe.scans == 2 }
      let before = changes
      probe.release()
      try await Task.sleep(for: .milliseconds(50))
      #expect(changes == before)
      let input = monitor.read()
      #expect(input.processNames.contains("make") && input.processNames.contains("/bin/make"))
      probe.release()
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
          waitForExit(process)
        }
      }
      let pid = process.processIdentifier
      let identity = try #require(ProcessCatalog.read().first { $0.id == pid }?.identity)
      #expect(ProcessCatalog.pickerList().contains { $0.identity == identity })
    }
  }
#endif
