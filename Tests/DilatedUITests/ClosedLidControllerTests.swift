import DilatedCore
import Foundation
import ServiceManagement
import Testing

@testable import DilatedUI

@MainActor struct ClosedLidControllerTests {
  @Test func aDifferentHelperBuildCannotEnableClosedLid() async throws {
    let fixture = await ControllerFixture()
    let controller = ClosedLidController(
      transport: fixture.transport, expectedBuild: { "new-build" })
    defer { controller.invalidate() }
    await #expect(throws: (any Error).self) { try await controller.enable(policy: .init()) }
    #expect(!controller.active)
    #expect(controller.lastError?.contains("update") == true)
    let state = await fixture.power.readback()
    #expect(state.confirmedDisabled)
  }

  @Test func aGuardStopEndsIntentAndNeverRearmsOnRefresh() async throws {
    let fixture = await ControllerFixture()
    let controller = fixture.controller()
    defer { controller.invalidate() }
    var ended: String?
    controller.onEnded = { ended = $0 }
    try await controller.enable(policy: .init())
    #expect(controller.active)
    fixture.inputs.overheat()
    await fixture.service.tick()
    try await controller.refresh()
    #expect(!controller.active)
    #expect(ended?.contains("hot") == true)
    fixture.inputs.cool()
    try await controller.refresh()
    await #expect(throws: (any Error).self) { try await controller.heartbeat() }
    #expect(!controller.active)
    let state = await fixture.power.readback()
    #expect(state.confirmedDisabled)
  }

  @Test func stopDuringAnEnableReplyCannotRearmTheClient() async throws {
    let fixture = await ControllerFixture()
    let controller = fixture.controller()
    defer { controller.invalidate() }
    fixture.transport.delayEnableReply = true
    let enabling = Task { try await controller.enable(policy: .init()) }
    await fixture.transport.waitForEnableReply()
    defer { fixture.transport.releaseReply() }
    try await controller.disable()
    fixture.transport.releaseReply()
    await #expect(throws: CancellationError.self) { try await enabling.value }
    #expect(!controller.active)
    #expect(controller.state?.readback.confirmedDisabled == true)
    let state = await fixture.power.readback()
    #expect(state.confirmedDisabled)
  }

  @Test func anUnreachableXPCServiceFailsWithinTheRequestDeadline() async {
    let transport = HelperTransport(
      serviceName: "com.codeswhat.dilated.missing.\(UUID().uuidString)")
    defer { transport.invalidate() }
    let started = ContinuousClock.now
    await #expect(throws: (any Error).self) { try await transport.send(.init(action: .status)) }
    #expect(started.duration(to: .now) < .seconds(9))
  }

  @Test func anUnavailableHelperReportsTheConnectionFailureInsteadOfCancellation() async {
    let transport = HelperTransport(
      serviceName: "com.codeswhat.dilated.missing.\(UUID().uuidString)")
    let controller = ClosedLidController(transport: transport, expectedBuild: { "unused" })
    defer { controller.invalidate() }
    do {
      try await controller.enable(policy: .init())
      Issue.record("An unavailable helper enabled closed-lid.")
    } catch {
      #expect(error.localizedDescription.contains("disconnected"))
    }
    #expect(!controller.active)
  }

  @Test func modelMergesLidRequestsAndStopClearsThePowerFlag() async throws {
    let fixture = await ControllerFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      closedLid: fixture.controller())
    defer { model.shutdown() }
    model.start(duration: 120)
    model.start(duration: 180)
    let first = model.engine.holds[0].id
    let second = model.engine.holds[1].id
    try await model.setClosedLid(id: first, enabled: true)
    try await model.setClosedLid(id: second, enabled: true)
    #expect(model.engine.desiredState.closedLid)
    model.stop(id: first)
    try await model.synchronizeClosedLid()
    #expect(model.closedLid.active)
    model.stopAll()
    try await model.synchronizeClosedLid()
    #expect(model.engine.automationPaused)
    #expect(!model.closedLid.active)
    let state = await fixture.power.readback()
    #expect(state.confirmedDisabled)
  }

  @Test func aGuardStopClearsModelIntentButKeepsOrdinaryHolds() async throws {
    let fixture = await ControllerFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      closedLid: fixture.controller())
    defer { model.shutdown() }
    model.start(duration: 120)
    try await model.setClosedLid(id: model.engine.holds[0].id, enabled: true)
    fixture.inputs.overheat()
    await fixture.service.tick()
    try await model.closedLid.refresh()
    #expect(!model.engine.desiredState.closedLid)
    #expect(model.engine.holds.count == 1)
    #expect(model.attention?.contains("hot") == true)
    fixture.inputs.cool()
    model.refreshPower()
    #expect(!model.engine.desiredState.closedLid)
  }

  @Test func quitConfirmsResetBeforeDiscardingTimers() async throws {
    let fixture = await ControllerFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      closedLid: fixture.controller())
    defer { model.shutdown() }
    model.start(duration: 120)
    try await model.setClosedLid(id: model.engine.holds[0].id, enabled: true)
    let canQuit = await model.prepareToQuit()
    #expect(canQuit)
    #expect(model.engine.holds.isEmpty)
    let state = await fixture.power.readback()
    #expect(state.confirmedDisabled)
  }

  @Test func repairWaitsForVerifiedResetAndCompletedUnregister() async throws {
    let fixture = await ControllerFixture()
    let controller = fixture.controller()
    defer { controller.invalidate() }
    try await controller.enable(policy: .init())
    let service = InstallationFixture(power: fixture.power)
    let installation = HelperInstallation(service: service)
    await installation.nextStep(controller: controller)
    #expect(installation.lastError == nil)
    #expect(service.operations == ["reset-confirmed", "unregister-completed", "register"])
    #expect(service.openedApproval)
    #expect(installation.status == .requiresApproval)
  }

  @Test func failedResetKeepsQuitBlockedAndStopCannotClaimSuccess() async throws {
    let fixture = await ControllerFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      closedLid: fixture.controller())
    defer { model.shutdown() }
    model.start(duration: 120)
    try await model.setClosedLid(id: model.engine.holds[0].id, enabled: true)
    await fixture.power.denyReset()
    #expect(await model.prepareToQuit() == false)
    #expect(model.engine.holds.count == 1)
    #expect(model.attention?.contains("staying open") == true)
    await #expect(throws: (any Error).self) { try await model.synchronizeClosedLid() }
    await fixture.power.allowReset()
    await fixture.service.tick()
    #expect(await model.prepareToQuit())
  }

  @Test func acceptingTheBatteryWarningNeverOverridesTheClosedLidFloor() async throws {
    let fixture = await ControllerFixture()
    fixture.inputs.battery(percent: 15)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: .init(stateDirectory: directory),
      power: { PowerState(onBattery: true, batteryPercent: 15) }, closedLid: fixture.controller())
    defer { model.shutdown() }
    model.settings.overrideLowPower = true
    var warnings = 0
    model.onClosedLidBatteryWarning = {
      warnings += 1
      return true
    }
    model.start(duration: 120)
    await #expect(throws: (any Error).self) {
      try await model.setClosedLid(id: model.engine.holds[0].id, enabled: true)
    }
    #expect(warnings == 1)
    #expect(model.settings.closedLidBatteryWarningAccepted)
    #expect(!model.engine.desiredState.closedLid)
    let state = await fixture.power.readback()
    #expect(state.confirmedDisabled)
  }

  @Test func controlWaitsForPowerConfirmationAndRenewalsCannotRearm() async throws {
    let fixture = await ControllerFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      closedLid: fixture.controller())
    defer { model.shutdown() }
    let response = await model.control(.init(action: .lease, duration: 60, closedLid: true))
    #expect(response.ok)
    #expect(response.helper?.enabled == true)
    let id = try #require(response.id)
    fixture.inputs.overheat()
    await fixture.service.tick()
    try await model.closedLid.refresh()
    fixture.inputs.cool()
    let denied = await model.control(.init(action: .renew, id: id, duration: 60, closedLid: true))
    #expect(!denied.ok)
    let renewed = await model.control(.init(action: .renew, id: id, duration: 60))
    #expect(renewed.ok)
    #expect(!model.closedLid.active)
    #expect(!model.engine.desiredState.closedLid)
    let stopped = await model.control(.init(action: .stopAll))
    #expect(stopped.ok)
    #expect(stopped.helper?.readback.confirmedDisabled == true)
  }

  @Test func closedLidLinksRequireTheSeparateOptIn() async throws {
    let fixture = await ControllerFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      closedLid: fixture.controller())
    defer { model.shutdown() }
    let url = URL(string: "dilated://awake?for=1h&lid=closed")!
    await model.openURL(url)
    #expect(model.engine.holds.isEmpty)
    #expect(model.message?.contains("Closed Lid") == true)
    model.settings.closedLidURLAutomation = true
    await model.openURL(url)
    #expect(model.closedLid.active)
    #expect(model.engine.holds.count == 1)
    #expect(await model.prepareToQuit())
  }
}

@MainActor private struct ControllerFixture {
  let inputs: ControllerInputs
  let power: ControllerPower
  let service: ClosedLidService
  let transport: InProcessHelperTransport
  init() async {
    inputs = ControllerInputs()
    power = ControllerPower()
    let readings = inputs
    service = ClosedLidService(
      power: power, environment: { readings.read() }, clock: { 0 }, buildIdentity: "test-build")
    await service.start()
    transport = InProcessHelperTransport(service: service)
  }
  func controller() -> ClosedLidController {
    ClosedLidController(transport: transport, expectedBuild: { "test-build" })
  }
}

@MainActor private final class InProcessHelperTransport: HelperTransporting {
  var onDisconnect: (() -> Void)?
  var delayEnableReply = false
  private let service: ClosedLidService
  private let owner = UUID()
  private var pending: (HelperReply, CheckedContinuation<HelperReply, Never>)?
  private var waiting: CheckedContinuation<Void, Never>?
  init(service: ClosedLidService) { self.service = service }
  func send(_ request: HelperRequest) async throws -> HelperReply {
    let response = await service.handle(request, owner: owner)
    if request.action == .enable && delayEnableReply {
      return await withCheckedContinuation { continuation in
        pending = (response, continuation)
        waiting?.resume()
        waiting = nil
      }
    }
    return response
  }
  func waitForEnableReply() async {
    guard pending == nil else { return }
    await withCheckedContinuation { waiting = $0 }
  }
  func releaseReply() {
    pending?.1.resume(returning: pending!.0)
    pending = nil
  }
  func invalidate() {
    let service = service
    let owner = owner
    Task { await service.disconnected(owner: owner) }
  }
}

private final class ControllerInputs: @unchecked Sendable {
  private let lock = NSLock()
  private var thermal = ClosedLidThermal.nominal
  private var source = ClosedLidPowerSource.ac
  private var percent: Int?
  func read() -> ClosedLidEnvironment {
    lock.withLock {
      ClosedLidEnvironment(
        powerSource: source, batteryPercent: percent, thermal: thermal, lidClosed: false)
    }
  }
  func battery(percent: Int) {
    lock.withLock {
      source = .battery
      self.percent = percent
    }
  }
  func overheat() { lock.withLock { thermal = .serious } }
  func cool() { lock.withLock { thermal = .nominal } }
}
private actor ControllerPower: ClosedLidPowerControlling {
  private var value = ClosedLidReadback(effectiveDisabled: false, storedDisabled: false)
  private var resetDenied = false
  func setSleepDisabled(_ disabled: Bool) throws -> ClosedLidReadback {
    if !disabled && resetDenied { throw ClosedLidPowerError.commandFailed(1) }
    value = ClosedLidReadback(effectiveDisabled: disabled, storedDisabled: disabled)
    return value
  }
  func readback() -> ClosedLidReadback { value }
  func sleep() {}
  func denyReset() { resetDenied = true }
  func allowReset() { resetDenied = false }
}

@MainActor private final class InstallationFixture: HelperInstalling {
  var status = SMAppService.Status.enabled
  var operations: [String] = []
  var openedApproval = false
  private let power: ControllerPower
  init(power: ControllerPower) { self.power = power }
  func register() throws {
    #expect(status == .notRegistered)
    operations.append("register")
    status = .requiresApproval
  }
  func unregister() async throws {
    let state = await power.readback()
    #expect(state.confirmedDisabled)
    operations.append("reset-confirmed")
    await Task.yield()
    status = .notRegistered
    operations.append("unregister-completed")
  }
  func openApproval() { openedApproval = true }
}
