import Foundation
import Security
import Testing

@testable import DilatedCore

struct HelperServiceTests {
  private let owner = UUID()

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func oldReadbacksCannotOverwriteANewerEnable(tick: Bool) async throws {
    let hardware = SuspendedReadbackHardware()
    let driver = SerialPowerDriver(runner: hardware, readback: { await hardware.readback() })
    let service = ClosedLidService(
      power: driver,
      environment: { .init(powerSource: .ac, thermal: .nominal, lidClosed: false) },
      clock: { 0 }, buildIdentity: "test-helper")
    await service.start()
    await hardware.suspendNextRead()
    let oldRead = Task { () -> HelperReply? in
      if tick {
        await service.tick()
        return nil
      }
      return await service.handle(.init(action: .status), owner: owner)
    }
    await hardware.waitForRead()
    let enabled = await service.handle(.init(action: .enable, policy: .init()), owner: owner)
    #expect(enabled.ok)
    #expect(enabled.state?.enabled == true)
    await hardware.releaseRead()
    if let status = await oldRead.value {
      #expect(status.state?.enabled == true)
      #expect(status.state?.ready == true)
      #expect(status.state?.readback.confirmedEnabled == true)
    }
    let calls = await hardware.calls
    #expect(calls == [.setSleepDisabled(false), .setSleepDisabled(true)])
  }

  @Test(.timeLimit(.minutes(1)))
  func aReadStartedDuringEnableCannotOverwriteItsCompletion() async throws {
    let hardware = SuspendedReadbackHardware()
    let driver = SerialPowerDriver(runner: hardware, readback: { await hardware.readback() })
    let service = ClosedLidService(
      power: driver,
      environment: { .init(powerSource: .ac, thermal: .nominal, lidClosed: false) },
      clock: { 0 }, buildIdentity: "test-helper")
    await service.start()
    await hardware.suspendNextEnable()
    let enable = Task {
      await service.handle(.init(action: .enable, policy: .init()), owner: owner)
    }
    await hardware.waitForEnable()
    await hardware.suspendNextRead()
    let status = Task { await service.handle(.init(action: .status), owner: owner) }
    await hardware.waitForRead()
    await hardware.releaseEnable()
    let enabled = await enable.value
    #expect(enabled.state?.enabled == true)
    await hardware.releaseRead()
    let observed = await status.value
    #expect(observed.state?.enabled == true)
    #expect(observed.state?.ready == true)
    #expect(observed.state?.readback.confirmedEnabled == true)
  }

  @Test func startupResetsBeforeEnableAndTheProtocolVersionIsChecked() async throws {
    let power = TestHelperPower()
    let inputs = HelperInputs()
    let service = makeService(power, inputs)
    let early = await service.handle(.init(action: .enable, policy: .init()), owner: owner)
    #expect(!early.ok)
    await service.start()
    let unsupported = await service.handle(
      .init(action: .status, protocolVersion: 0), owner: owner)
    #expect(!unsupported.ok)
    #expect(unsupported.code == "protocolMismatch")
    let enabled = await service.handle(.init(action: .enable, policy: .init()), owner: owner)
    #expect(enabled.ok)
    #expect(enabled.state?.enabled == true)
    let calls = await power.calls
    #expect(calls == [false, true])
  }

  @Test func aFailedStartupResetRefusesEnableAndCanBeRetried() async throws {
    let power = TestHelperPower(failReset: true)
    let inputs = HelperInputs()
    let service = makeService(power, inputs)
    await service.start()
    let denied = await service.handle(.init(action: .enable, policy: .init()), owner: owner)
    #expect(!denied.ok)
    #expect(denied.state?.ready == false)
    #expect(denied.state?.phase == .failed)
    #expect(denied.state?.leaseID == nil)
    await power.allowReset()
    await service.tick()
    let status = await service.handle(.init(action: .status), owner: owner)
    #expect(status.state?.ready == true)
    #expect(status.state?.enabled == false)
  }

  @Test func partialReadbackNeverReportsSuccessfulEnableAndTriggersReset() async throws {
    let power = TestHelperPower(partialEnable: true)
    let inputs = HelperInputs()
    let service = makeService(power, inputs)
    await service.start()
    let enabled = await service.handle(.init(action: .enable, policy: .init()), owner: owner)
    #expect(!enabled.ok)
    #expect(enabled.state?.enabled == false)
    #expect(enabled.state?.leaseID == nil)
    let calls = await power.calls
    #expect(calls == [false, true, false])
  }

  @Test func leaseExpiryResetsAndRequestsSleepOnlyWhenClosed() async throws {
    let power = TestHelperPower()
    let inputs = HelperInputs()
    inputs.update(now: 0, closed: true)
    let service = makeService(power, inputs)
    await service.start()
    let enabled = await service.handle(.init(action: .enable, policy: .init()), owner: owner)
    let id = try #require(enabled.state?.leaseID)
    inputs.update(now: 90, closed: true)
    await service.tick()
    let status = await service.handle(.init(action: .status), owner: owner)
    #expect(status.state?.readback.confirmedDisabled == true)
    #expect(status.state?.stopReason == .leaseExpired)
    let sleeps = await power.sleeps
    #expect(sleeps == 1)
    let stale = await service.handle(.init(action: .heartbeat, leaseID: id), owner: owner)
    #expect(!stale.ok)
    #expect(stale.state?.leaseID == nil)
  }

  @Test func disconnectEndsTheLeaseAndAnotherConnectionCannotRenewIt() async throws {
    let power = TestHelperPower()
    let inputs = HelperInputs()
    let service = makeService(power, inputs)
    await service.start()
    let enabled = await service.handle(.init(action: .enable, policy: .init()), owner: owner)
    let id = try #require(enabled.state?.leaseID)
    let denied = await service.handle(.init(action: .heartbeat, leaseID: id), owner: UUID())
    #expect(!denied.ok)
    await service.disconnected(owner: owner)
    let status = await service.handle(.init(action: .status), owner: owner)
    #expect(status.state?.readback.confirmedDisabled == true)
    #expect(status.state?.stopReason == .disconnected)
    #expect(status.state?.leaseID == nil)
  }

  @Test func theOwningConnectionCanCancelWithoutWaitingForAnEnableReply() async throws {
    let power = TestHelperPower()
    let service = makeService(power, HelperInputs())
    await service.start()
    _ = await service.handle(.init(action: .enable, policy: .init()), owner: owner)
    let foreign = await service.handle(.init(action: .disable), owner: UUID())
    #expect(!foreign.ok)
    let stopped = await service.handle(.init(action: .disable), owner: owner)
    #expect(stopped.ok)
    #expect(stopped.state?.readback.confirmedDisabled == true)
  }

  @Test func aDroppedPowerFlagCanOnlyBeReappliedForTheSameLiveSafeLease() async throws {
    let power = TestHelperPower()
    let inputs = HelperInputs()
    let service = makeService(power, inputs)
    await service.start()
    let enabled = await service.handle(.init(action: .enable, policy: .init()), owner: owner)
    let id = try #require(enabled.state?.leaseID)
    await power.dropFlag()
    await service.tick()
    let status = await service.handle(.init(action: .status), owner: owner)
    #expect(status.state?.leaseID == id)
    #expect(status.state?.enabled == true)
    inputs.overheat()
    await service.tick()
    inputs.update(now: 2, closed: false)
    await service.tick()
    let stopped = await service.handle(.init(action: .status), owner: owner)
    #expect(stopped.state?.enabled == false)
    #expect(stopped.state?.leaseID == nil)
    #expect(stopped.state?.stopReason == .thermal)
  }

  @Test func heartbeatConfirmsCurrentPowerBeforeAcknowledgingTheLease() async throws {
    let power = TestHelperPower()
    let service = makeService(power, HelperInputs())
    await service.start()
    let enabled = await service.handle(.init(action: .enable, policy: .init()), owner: owner)
    let id = try #require(enabled.state?.leaseID)
    await power.dropFlag()
    let renewed = await service.handle(.init(action: .heartbeat, leaseID: id), owner: owner)
    #expect(renewed.ok)
    #expect(renewed.state?.readback.confirmedEnabled == true)
    let calls = await power.calls
    #expect(calls == [false, true, true])
  }

  @Test func fixedSigningRequirementsParseAsActualSecurityRequirements() {
    for text in [HelperIdentity.appRequirement, HelperIdentity.helperRequirement] {
      var requirement: SecRequirement?
      #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
      #expect(requirement != nil)
    }
  }

  @Test func aChangedPowerSettingCannotBeReportedReadyBeforeRepair() async throws {
    let power = TestHelperPower()
    let service = makeService(power, HelperInputs())
    await service.start()
    _ = try await power.setSleepDisabled(true)
    let status = await service.handle(.init(action: .status), owner: owner)
    #expect(status.state?.ready == false)
    #expect(status.state?.enabled == false)
    await service.tick()
    let repaired = await service.handle(.init(action: .status), owner: owner)
    #expect(repaired.state?.ready == true)
    #expect(repaired.state?.readback.confirmedDisabled == true)
  }

  @Test func malformedAndOversizedMessagesCannotReachPowerOperations() async throws {
    let power = TestHelperPower()
    let service = makeService(power, HelperInputs())
    await service.start()
    var oversized = try JSONEncoder().encode(HelperRequest(action: .status))
    oversized.append(Data(repeating: 32, count: 16 * 1024))
    for payload in [Data("{bad}".utf8), oversized] {
      let data = await service.handlePayload(payload, owner: owner)
      let response = try JSONDecoder().decode(HelperReply.self, from: data)
      #expect(!response.ok)
      #expect(response.code == "invalidRequest")
    }
    let calls = await power.calls
    #expect(calls == [false])
  }

  @Test func helperBuildIdentityComesFromTheSignedExecutable() throws {
    let file = URL(fileURLWithPath: "/usr/bin/true")
    let first = try HelperCodeIdentity.executable(at: file)
    #expect(!first.isEmpty)
    #expect(first == (try HelperCodeIdentity.executable(at: file)))
    #expect(throws: (any Error).self) {
      try HelperCodeIdentity.executable(at: URL(fileURLWithPath: "/missing-dilated-helper"))
    }
  }

  private func makeService(_ power: TestHelperPower, _ inputs: HelperInputs) -> ClosedLidService {
    ClosedLidService(
      power: power, environment: { inputs.environment() }, clock: { inputs.now() },
      buildIdentity: "test-helper")
  }
}

private final class HelperInputs: @unchecked Sendable {
  private let lock = NSLock()
  private var instant: TimeInterval = 0
  private var value = ClosedLidEnvironment(powerSource: .ac, thermal: .nominal, lidClosed: false)
  func now() -> TimeInterval { lock.withLock { instant } }
  func environment() -> ClosedLidEnvironment { lock.withLock { value } }
  func update(now: TimeInterval, closed: Bool) {
    lock.withLock {
      instant = now
      value.lidClosed = closed
      value.thermal = .nominal
    }
  }
  func overheat() { lock.withLock { value.thermal = .serious } }
}

private actor TestHelperPower: ClosedLidPowerControlling {
  var calls: [Bool] = []
  var sleeps = 0
  private var state = ClosedLidReadback(effectiveDisabled: true, storedDisabled: true)
  private var failReset: Bool
  private let partialEnable: Bool
  init(failReset: Bool = false, partialEnable: Bool = false) {
    self.failReset = failReset
    self.partialEnable = partialEnable
  }
  func setSleepDisabled(_ disabled: Bool) throws -> ClosedLidReadback {
    calls.append(disabled)
    if !disabled && failReset { throw ClosedLidPowerError.commandFailed(1) }
    state = ClosedLidReadback(
      effectiveDisabled: disabled && !partialEnable, storedDisabled: disabled)
    return state
  }
  func readback() -> ClosedLidReadback { state }
  func sleep() { sleeps += 1 }
  func allowReset() { failReset = false }
  func dropFlag() { state = ClosedLidReadback(effectiveDisabled: false, storedDisabled: false) }
}

private actor SuspendedReadbackHardware: PowerCommandRunning {
  var calls: [PowerCommand] = []
  private var enabled = false
  private var suspendRead = false
  private let entered = AsyncStream<Void>.makeStream()
  private let released = AsyncStream<Void>.makeStream()
  private let enableEntered = AsyncStream<Void>.makeStream()
  private let enableReleased = AsyncStream<Void>.makeStream()
  private var suspendEnable = false

  func run(_ command: PowerCommand) async {
    calls.append(command)
    if case .setSleepDisabled(let value) = command {
      if value && suspendEnable {
        suspendEnable = false
        enableEntered.continuation.yield(())
        enableEntered.continuation.finish()
        var iterator = enableReleased.stream.makeAsyncIterator()
        _ = await iterator.next()
      }
      enabled = value
    }
  }
  func suspendNextEnable() { suspendEnable = true }
  func waitForEnable() async {
    var iterator = enableEntered.stream.makeAsyncIterator()
    _ = await iterator.next()
  }
  func releaseEnable() {
    enableReleased.continuation.yield(())
    enableReleased.continuation.finish()
  }
  func suspendNextRead() { suspendRead = true }
  func readback() async -> ClosedLidReadback {
    let observed = ClosedLidReadback(effectiveDisabled: enabled, storedDisabled: enabled)
    if suspendRead {
      suspendRead = false
      entered.continuation.yield(())
      entered.continuation.finish()
      var iterator = released.stream.makeAsyncIterator()
      _ = await iterator.next()
    }
    return observed
  }
  func waitForRead() async {
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
  }
  func releaseRead() {
    released.continuation.yield(())
    released.continuation.finish()
  }
}
