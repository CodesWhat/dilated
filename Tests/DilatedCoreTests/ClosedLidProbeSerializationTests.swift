import Foundation
import Testing

@testable import DilatedCore

/// The machine's SleepDisabled value and the order writes reached it.
private final class FakeHardware: @unchecked Sendable {
  private let lock = NSLock()
  private var current = false
  private var writes: [String] = []
  var value: Bool { lock.withLock { current } }
  var log: [String] { lock.withLock { writes } }
  func write(_ value: Bool, by source: String) {
    lock.withLock {
      current = value
      writes.append("\(source) \(value ? 1 : 0)")
    }
  }
  var readback: ClosedLidReadback {
    lock.withLock { ClosedLidReadback(effectiveDisabled: current, storedDisabled: current) }
  }
}

private actor HardwarePower: ClosedLidPowerControlling {
  let hardware: FakeHardware
  init(hardware: FakeHardware) { self.hardware = hardware }
  func setSleepDisabled(_ disabled: Bool) async throws -> ClosedLidReadback {
    hardware.write(disabled, by: "session")
    return hardware.readback
  }
  func readback() async -> ClosedLidReadback { hardware.readback }
  func sleep() async throws {}
}

/// Holds the probe's write open until the test lets it finish.
private actor Gate {
  private var entered = false
  private var waiter: CheckedContinuation<Void, Never>?
  private var opened = false

  func hold() async {
    entered = true
    guard !opened else { return }
    await withCheckedContinuation { waiter = $0 }
  }

  func open() {
    opened = true
    waiter?.resume()
    waiter = nil
  }

  func waitUntilHeld() async {
    for _ in 0..<2_000 where !entered { try? await Task.sleep(for: .milliseconds(5)) }
  }
}

struct ClosedLidProbeSerializationTests {
  private func makeStore() -> ClosedLidMarkerStore {
    ClosedLidMarkerStore(
      directory: FileManager.default.temporaryDirectory.appendingPathComponent(
        "lid-probe-\(UUID().uuidString)"))
  }

  @Test func aRestoreRequestedMidProbeWaitsForTheProbeWrite() async throws {
    let store = makeStore()
    let hardware = FakeHardware()
    let guardian = ClosedLidSessionGuard(power: HardwarePower(hardware: hardware), store: store)
    _ = try await guardian.setSleepDisabled(true)
    #expect(hardware.value)

    let gate = Gate()
    let probe = Task {
      await ClosedLidPermission.probe(
        readCurrent: { hardware.readback },
        lock: {
          let held = try await store.acquireLock()
          return { held.release() }
        },
        run: { arguments in
          if arguments.contains("-k") {
            hardware.write(arguments.last == "1", by: "probe")
            await gate.hold()
          }
          return ProcessOutcome(status: 0, timedOut: false, processID: 1)
        })
    }
    await gate.waitUntilHeld()

    let restore = Task { try await guardian.setSleepDisabled(false) }
    try await Task.sleep(for: .milliseconds(300))
    #expect(hardware.log == ["session 1", "probe 1"], "the restore ran inside the probe")

    await gate.open()
    #expect(await probe.value)
    let observed = try await restore.value
    #expect(observed.confirmedDisabled)
    #expect(hardware.log == ["session 1", "probe 1", "session 0"])
    #expect(!hardware.value)
  }

  @Test func aProbeThatCantTakeTheLockNeverWritesAndTheListingsDecide() async {
    struct Unavailable: Error {}
    let executed = NSLock()
    nonisolated(unsafe) var writes = 0
    let allowed = await ClosedLidPermission.probe(
      readCurrent: { ClosedLidReadback(effectiveDisabled: true, storedDisabled: true) },
      lock: { throw Unavailable() },
      run: { arguments in
        if !arguments.contains("-l") { executed.withLock { writes += 1 } }
        return ProcessOutcome(status: 0, timedOut: false, processID: 1)
      })
    #expect(allowed)
    #expect(executed.withLock { writes } == 0)
  }

  @Test func theLockIsReleasedWhenTheProbeFinishes() async throws {
    let store = makeStore()
    let hardware = FakeHardware()
    let allowed = await ClosedLidPermission.probe(
      readCurrent: { hardware.readback },
      lock: {
        let held = try await store.acquireLock()
        return { held.release() }
      },
      run: { _ in ProcessOutcome(status: 0, timedOut: false, processID: 1) })
    #expect(allowed)
    let again = try await store.acquireLock(timeout: .milliseconds(200))
    again.release()
  }
}
