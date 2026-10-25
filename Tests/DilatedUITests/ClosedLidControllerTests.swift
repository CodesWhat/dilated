import DilatedControl
import DilatedCore
import Foundation
import ServiceManagement
import Testing

@testable import DilatedUI

@MainActor struct ClosedLidControllerTests {
  @Test func appControlCanRepairAnUnreachableOffHelperWithoutChangingManualWorkOrPause()
    async throws
  {
    let fixture = await ControllerFixture()
    fixture.transport.failures = [.disconnected]
    let service = InstallationFixture(power: fixture.power)
    service.registrationStatus = .enabled
    let installation = HelperInstallation(
      service: service,
      readPower: {
        .init(effectiveDisabled: false, storedDisabled: false)
      })
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      closedLid: fixture.controller(), helperInstallation: installation)
    defer { model.shutdown() }
    model.stopAll()
    model.start(duration: 60)
    let manual = try #require(model.engine.holds.first)
    let response = await model.control(.init(action: .helperSetup))
    #expect(response.ok && response.helper?.ready == true)
    #expect(
      response.snapshot?.automationPaused == true
        && response.snapshot?.holds.map(\.id) == [manual.id])
    #expect(service.operations == ["reset-confirmed", "unregister-completed", "register"])
  }

  @Test func anUnreachableOffHelperCanBeRepairedWithoutItsAcknowledgement() async throws {
    let fixture = await ControllerFixture()
    fixture.transport.failures = [.disconnected]
    let controller = fixture.controller()
    defer { controller.invalidate() }
    let service = InstallationFixture(power: fixture.power)
    service.registrationStatus = .enabled
    let installation = HelperInstallation(
      service: service,
      readPower: {
        .init(effectiveDisabled: false, storedDisabled: false)
      })
    await installation.nextStep(controller: controller)
    #expect(installation.lastError == nil)
    #expect(service.operations == ["reset-confirmed", "unregister-completed", "register"])
    #expect(controller.state?.ready == true && !controller.hasLease)
  }

  @Test func anUnreachableOffHelperCanBeRemovedWithIndependentReadbackChecks() async throws {
    let fixture = await ControllerFixture()
    fixture.transport.failures = [.timedOut]
    let controller = fixture.controller()
    let service = InstallationFixture(power: fixture.power)
    var reads = 0
    let installation = HelperInstallation(
      service: service,
      readPower: {
        reads += 1
        return .init(effectiveDisabled: false, storedDisabled: false)
      })
    try await installation.remove(controller: controller)
    #expect(service.status == .notRegistered && reads == 3)
    #expect(service.operations == ["reset-confirmed", "unregister-completed"])
  }

  @Test func offRecoveryRejectsUnsafeReadbacksAndErrorsOtherThanLostTransport() async throws {
    let cases: [(HelperClientError, ClosedLidReadback)] = [
      (.disconnected, .init(effectiveDisabled: true, storedDisabled: false)),
      (.disconnected, .init(effectiveDisabled: false, storedDisabled: true)),
      (.timedOut, .init(effectiveDisabled: nil, storedDisabled: false)),
      (.timedOut, .init(effectiveDisabled: false, storedDisabled: nil)),
      (.invalidReply, .init(effectiveDisabled: false, storedDisabled: false)),
      (.rejected("Reset failed"), .init(effectiveDisabled: false, storedDisabled: false)),
    ]
    for (error, reading) in cases {
      let fixture = await ControllerFixture()
      fixture.transport.failures = [error]
      let service = InstallationFixture(power: fixture.power)
      let installation = HelperInstallation(service: service, readPower: { reading })
      await installation.nextStep(controller: fixture.controller())
      #expect(installation.lastError != nil && service.operations.isEmpty)
    }
  }

  @Test func aLeaseActiveBeforeMaintenanceCannotUseOffRecoveryAfterLosingTransport() async throws {
    let fixture = await ControllerFixture()
    let controller = fixture.controller()
    defer { controller.invalidate() }
    try await controller.enable(policy: .init())
    fixture.transport.failures = [.disconnected]
    let service = InstallationFixture(power: fixture.power)
    let installation = HelperInstallation(
      service: service,
      readPower: {
        .init(effectiveDisabled: false, storedDisabled: false)
      })
    await installation.nextStep(controller: controller)
    #expect(installation.lastError != nil && service.operations.isEmpty)
  }

  @Test func offRecoveryRechecksBeforeAndAfterUnregisterAndRejectsUnknownPower() async throws {
    for unknownAt in [2, 3] {
      let fixture = await ControllerFixture()
      fixture.transport.failures = [.disconnected]
      let service = InstallationFixture(power: fixture.power)
      var reads = 0
      let installation = HelperInstallation(
        service: service,
        readPower: {
          reads += 1
          return .init(effectiveDisabled: reads >= unknownAt ? nil : false, storedDisabled: false)
        })
      await installation.nextStep(controller: fixture.controller())
      #expect(installation.lastError != nil)
      if unknownAt == 2 {
        #expect(service.status == .enabled && service.operations.isEmpty)
      } else {
        #expect(service.status == .notRegistered)
        #expect(service.operations == ["reset-confirmed", "unregister-completed"])
      }
    }
  }

  @Test func pendingEnableBeforeMaintenanceCannotUseOffRecovery() async throws {
    let fixture = await ControllerFixture()
    let controller = fixture.controller()
    defer { controller.invalidate() }
    fixture.transport.delayEnableReply = true
    let enable = Task { try await controller.enable(policy: .init()) }
    await fixture.transport.waitForEnableReply()
    #expect(controller.pendingEnable)
    fixture.transport.failures = [.timedOut]
    let service = InstallationFixture(power: fixture.power)
    let installation = HelperInstallation(
      service: service,
      readPower: {
        .init(effectiveDisabled: false, storedDisabled: false)
      })
    await installation.nextStep(controller: controller)
    #expect(installation.lastError != nil && service.operations.isEmpty)
    fixture.transport.releaseReply()
    await #expect(throws: (any Error).self) { try await enable.value }
  }

  @Test func cancelledMaintenanceCannotUseTheOffRecoveryPath() async throws {
    let fixture = await ControllerFixture()
    fixture.transport.failures = [.disconnected]
    let service = InstallationFixture(power: fixture.power)
    let installation = HelperInstallation(
      service: service,
      readPower: {
        .init(effectiveDisabled: false, storedDisabled: false)
      })
    let operation = Task { await installation.nextStep(controller: fixture.controller()) }
    operation.cancel()
    await operation.value
    #expect(installation.lastError != nil && service.operations.isEmpty)
  }

  @Test func pendingApprovalCanBeRemovedWithoutConnectingToAnUnapprovedDaemon() async throws {
    let fixture = await ControllerFixture()
    let service = InstallationFixture(power: fixture.power)
    service.status = .requiresApproval
    let installation = HelperInstallation(
      service: service,
      readPower: {
        .init(effectiveDisabled: false, storedDisabled: false)
      })
    try await installation.remove(controller: fixture.controller())
    #expect(service.status == .notRegistered)
    #expect(fixture.transport.actions.isEmpty)
  }

  @Test func pendingApprovalCannotBeRemovedWithUnknownOrEnabledPowerState() async throws {
    let fixture = await ControllerFixture()
    let service = InstallationFixture(power: fixture.power)
    service.status = .requiresApproval
    let installation = HelperInstallation(
      service: service,
      readPower: {
        .init(effectiveDisabled: true, storedDisabled: true)
      })
    await #expect(throws: (any Error).self) {
      try await installation.remove(controller: fixture.controller())
    }
    #expect(service.operations.isEmpty)
    #expect(fixture.transport.actions.isEmpty)
  }

  @Test func packageUpdateDoesNotRestoreAnApprovalRevokedSinceLaunch() async throws {
    let fixture = await ControllerFixture()
    let service = InstallationFixture(power: fixture.power)
    let installation = HelperInstallation(
      service: service,
      readPower: {
        .init(effectiveDisabled: false, storedDisabled: false)
      })
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      closedLid: fixture.controller(), helperInstallation: installation)
    defer { model.shutdown() }
    service.status = .requiresApproval
    #expect(await model.prepareForPackage(.update))
    let handoff = try PackageHandoffStore(directory: directory).requirePrepared(
      app: Bundle.main.bundleURL)
    #expect(!handoff.helperWasApproved)
  }
  @Test func packageUpdateRestoresOnlyAPreviouslyApprovedHelperOnNextLaunch() async throws {
    let fixture = await ControllerFixture()
    let service = InstallationFixture(power: fixture.power)
    service.registrationStatus = .enabled
    let installation = HelperInstallation(
      service: service,
      readPower: {
        .init(effectiveDisabled: false, storedDisabled: false)
      })
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      closedLid: fixture.controller(), helperInstallation: installation)
    defer { model.shutdown() }
    #expect(await model.prepareForPackage(.update))
    #expect(service.status == .notRegistered)
    let restored = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      closedLid: fixture.controller(), helperInstallation: installation)
    defer { restored.shutdown() }
    restored.begin()
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while service.status != .enabled && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(service.status == .enabled)
    #expect(!restored.closedLid.active)
    #expect(!restored.engine.desiredState.closedLid)
  }
  @Test func failedRemovalNeverReturnsSuccessfulControlAcknowledgement() async throws {
    let fixture = await ControllerFixture()
    let service = InstallationFixture(power: fixture.power)
    service.status = .notRegistered
    let installation = HelperInstallation(
      service: service,
      readPower: {
        .init(effectiveDisabled: true, storedDisabled: true)
      })
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      closedLid: fixture.controller(), helperInstallation: installation)
    defer { model.shutdown() }
    let response = await model.control(.init(action: .helperRemove))
    #expect(!response.ok)
    #expect(response.message?.contains("normal sleep") == true)
    #expect(service.operations.isEmpty)
  }

  @Test func removingAnUnusedHelperNeedsConfirmedNormalSleep() async throws {
    let fixture = await ControllerFixture()
    let controller = fixture.controller()
    defer { controller.invalidate() }
    let service = InstallationFixture(power: fixture.power)
    service.status = .notRegistered
    let installation = HelperInstallation(
      service: service,
      readPower: {
        .init(effectiveDisabled: false, storedDisabled: false)
      })
    try await installation.remove(controller: controller)
    #expect(service.operations.isEmpty)
    let unsafe = HelperInstallation(
      service: service,
      readPower: {
        .init(effectiveDisabled: true, storedDisabled: true)
      })
    await #expect(throws: (any Error).self) { try await unsafe.remove(controller: controller) }
    #expect(service.operations.isEmpty)
  }

  @Test func relaunchRepairsAnApprovedHelperOnlyWhenItsBuildChanged() async throws {
    let fixture = await ControllerFixture()
    let controller = ClosedLidController(
      transport: fixture.transport, expectedBuild: { "updated-build" })
    defer { controller.invalidate() }
    let service = InstallationFixture(power: fixture.power)
    let installation = HelperInstallation(service: service)
    await installation.reconcileAfterLaunch(controller: controller)
    #expect(service.operations == ["reset-confirmed", "unregister-completed", "register"])
    #expect(installation.status == .requiresApproval)
    #expect(!controller.hasLease)
  }

  @Test func anUpdateCannotEndAnActiveClosedLidSession() async throws {
    let fixture = await ControllerFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      closedLid: fixture.controller())
    defer { model.shutdown() }
    model.start(duration: 120)
    try await model.setClosedLid(id: model.engine.holds[0].id, enabled: true)
    #expect(await model.prepareToUpdate() == false)
    #expect(model.closedLid.active)
    #expect(model.engine.holds.count == 1)
    try await model.setClosedLid(id: model.engine.holds[0].id, enabled: false)
    #expect(await model.prepareToUpdate())
    let restored = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { restored.shutdown() }
    #expect(restored.engine.holds.count == 1)
    #expect(!restored.engine.desiredState.closedLid)
  }

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

  @Test func replacementRecoversFromTheServiceRegistrationRace() async throws {
    let fixture = await ControllerFixture()
    let controller = fixture.controller()
    defer { controller.invalidate() }
    let service = InstallationFixture(power: fixture.power)
    service.registerErrors = [NSError(domain: SMAppServiceErrorDomain, code: 1)]
    let installation = HelperInstallation(service: service)
    await installation.nextStep(controller: controller)
    #expect(installation.lastError == nil)
    #expect(installation.status == .requiresApproval)
    #expect(service.openedApproval)
    #expect(
      service.operations == ["reset-confirmed", "unregister-completed", "register", "register"])
    #expect(!controller.hasLease)
    #expect(!installation.busy)
  }

  @Test func persistentReplacementRegistrationFailureIsBoundedAndVisible() async throws {
    let fixture = await ControllerFixture()
    let controller = fixture.controller()
    defer { controller.invalidate() }
    let service = InstallationFixture(power: fixture.power)
    service.registerErrors = Array(
      repeating: NSError(domain: SMAppServiceErrorDomain, code: 1), count: 10)
    let installation = HelperInstallation(service: service)
    await installation.nextStep(controller: controller)
    #expect(installation.lastError != nil)
    #expect(installation.status == .notRegistered)
    #expect(service.operations.filter { $0 == "register" }.count == 5)
    #expect(!service.openedApproval)
    #expect(!installation.busy)
    #expect(!controller.hasLease)
    #expect(await fixture.power.readback().confirmedDisabled)
  }

  @Test func initialSetupAndOtherRegistrationFailuresAreNotRetried() async throws {
    for (initialStatus, error) in [
      (SMAppService.Status.notRegistered, NSError(domain: SMAppServiceErrorDomain, code: 1)),
      (.enabled, NSError(domain: SMAppServiceErrorDomain, code: 4)),
      (.enabled, NSError(domain: NSPOSIXErrorDomain, code: 1)),
    ] {
      let fixture = await ControllerFixture()
      let controller = fixture.controller()
      defer { controller.invalidate() }
      let service = InstallationFixture(power: fixture.power)
      service.status = initialStatus
      service.registerErrors = [error]
      let installation = HelperInstallation(service: service)
      await installation.nextStep(controller: controller)
      #expect(installation.lastError != nil)
      #expect(service.operations.filter { $0 == "register" }.count == 1)
      #expect(!service.openedApproval)
      #expect(!installation.busy)
    }
  }

  @Test func setupWaitsUntilTheRegisteredHelperCompletesItsStartupReset() async throws {
    let fixture = await ControllerFixture(start: false)
    let controller = fixture.controller()
    defer {
      controller.onChange = nil
      controller.invalidate()
    }
    let service = InstallationFixture(power: fixture.power)
    service.status = .notRegistered
    service.registrationStatus = .enabled
    let installation = HelperInstallation(service: service)
    let firstStatus = AsyncStream<Void>.makeStream()
    controller.onChange = {
      if controller.state?.phase == .starting {
        firstStatus.continuation.yield(())
        firstStatus.continuation.finish()
      }
    }
    let setup = Task { await installation.nextStep(controller: controller) }
    for await _ in firstStatus.stream { break }
    #expect(installation.busy)
    #expect(controller.state?.ready == false)
    await fixture.service.start()
    await setup.value
    #expect(installation.lastError == nil)
    #expect(installation.status == .enabled)
    #expect(controller.state?.ready == true)
    #expect(controller.state?.readback.confirmedDisabled == true)
    #expect(!controller.hasLease)
  }

  @Test func aRegisteredHelperThatFailsStartupIsReportedAsAnError() async throws {
    let fixture = await ControllerFixture(start: false)
    await fixture.power.denyReset()
    await fixture.service.start()
    let controller = fixture.controller()
    defer { controller.invalidate() }
    let service = InstallationFixture(power: fixture.power)
    service.status = .notRegistered
    service.registrationStatus = .enabled
    let installation = HelperInstallation(service: service)
    await installation.nextStep(controller: controller)
    #expect(installation.lastError != nil)
    #expect(controller.state?.ready == false)
    #expect(!installation.busy)
    #expect(!controller.hasLease)
  }

  @Test func setupReportsAnUnfinishedStartupResetAfterItsDeadline() async throws {
    let fixture = await ControllerFixture(start: false)
    let controller = fixture.controller()
    defer { controller.invalidate() }
    let service = InstallationFixture(power: fixture.power)
    service.status = .notRegistered
    service.registrationStatus = .enabled
    let installation = HelperInstallation(service: service)
    await installation.nextStep(controller: controller)
    #expect(installation.lastError?.contains("startup reset") == true)
    #expect(!installation.busy)
    #expect(!controller.hasLease)
    #expect(controller.state?.ready == false)
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

  @Test func automationAwaitsHelperConfirmationAndCannotRearmWhilePaused() async throws {
    let fixture = await ControllerFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      assertions: ControllerAssertions(), closedLid: fixture.controller(),
      helperInstallation: HelperInstallation(service: InstallationFixture(power: fixture.power)))
    defer { model.shutdown() }
    let service = AutomationService()
    service.bind(model)
    let id = try await service.start(duration: 120)
    let deadline = model.engine.holds.first?.expiry
    try await service.setClosedLid(id: id, enabled: true)
    #expect(model.closedLid.state?.enabled == true)
    #expect(model.engine.holds.first?.expiry == deadline)
    try await service.stop()
    #expect(await fixture.power.readback().confirmedDisabled)
    model.start(duration: 120)
    let manual = try #require(model.engine.holds.first?.id)
    let enableCount = fixture.transport.actions.filter { $0 == .enable }.count
    await #expect(throws: (any Error).self) {
      try await service.setClosedLid(id: manual, enabled: true)
    }
    try await service.setClosedLid(id: manual, enabled: false)
    #expect(fixture.transport.actions.filter { $0 == .enable }.count == enableCount)
    #expect(model.engine.automationPaused)
  }

  @Test func stoppingDuringAutomationEnableCannotReturnSuccessfulEnable() async throws {
    let fixture = await ControllerFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      assertions: ControllerAssertions(), closedLid: fixture.controller(),
      helperInstallation: HelperInstallation(service: InstallationFixture(power: fixture.power)))
    defer { model.shutdown() }
    let service = AutomationService()
    service.bind(model)
    let id = try await service.start(duration: 120)
    fixture.transport.delayEnableReply = true
    let enabling = Task { try await service.setClosedLid(id: id, enabled: true) }
    await fixture.transport.waitForEnableReply()
    try await service.stop()
    fixture.transport.releaseReply()
    await #expect(throws: (any Error).self) { try await enabling.value }
    #expect(model.engine.holds.isEmpty)
    #expect(model.engine.automationPaused)
    #expect(await fixture.power.readback().confirmedDisabled)
  }

  @Test func automationPersistenceFailureResetsHelperInsteadOfAcknowledgingEnable() async throws {
    let fixture = await ControllerFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      assertions: ControllerAssertions(), closedLid: fixture.controller(),
      helperInstallation: HelperInstallation(service: InstallationFixture(power: fixture.power)))
    defer { model.shutdown() }
    let service = AutomationService()
    service.bind(model)
    let id = try await service.start(duration: 120)
    let file = StateStore(directory: directory).file
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) {
      try await service.setClosedLid(id: id, enabled: true)
    }
    #expect(!model.engine.desiredState.closedLid)
    #expect(await fixture.power.readback().confirmedDisabled)
  }

  @Test func automationNeverPromptsForUnreviewedBatteryWarningOrHelperApproval() async throws {
    let fixture = await ControllerFixture()
    fixture.inputs.battery(percent: 25)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let installation = InstallationFixture(power: fixture.power)
    let model = AppModel(
      endpoint: .init(stateDirectory: directory),
      power: { .init(onBattery: true, batteryPercent: 25) },
      assertions: ControllerAssertions(), closedLid: fixture.controller(),
      helperInstallation: HelperInstallation(service: installation))
    defer { model.shutdown() }
    let service = AutomationService()
    service.bind(model)
    var prompts = 0
    model.onClosedLidBatteryWarning = {
      prompts += 1
      return true
    }
    let id = try await service.start(duration: 120)
    await #expect(throws: (any Error).self) {
      try await service.setClosedLid(id: id, enabled: true)
    }
    #expect(prompts == 0)
    #expect(!fixture.transport.actions.contains(.enable))
    model.settings.closedLidBatteryWarningAccepted = true
    installation.status = .requiresApproval
    await #expect(throws: (any Error).self) {
      try await service.setClosedLid(id: id, enabled: true)
    }
    #expect(!installation.openedApproval)
    #expect(!fixture.transport.actions.contains(.enable))
  }

  @Test(arguments: [false, true])
  func passiveStatusAndPowerRefreshDoNotCancelAPendingEnable(automated: Bool) async throws {
    let fixture = await ControllerFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      assertions: ControllerAssertions(), closedLid: fixture.controller(),
      helperInstallation: HelperInstallation(service: InstallationFixture(power: fixture.power)))
    defer { model.shutdown() }
    let service = AutomationService()
    service.bind(model)
    let id: UUID
    if automated {
      id = try await service.start(duration: 120)
    } else {
      model.stopAll()
      model.start(duration: 120)
      id = try #require(model.engine.holds.first?.id)
    }
    fixture.transport.delayEnableReply = true
    let enabling = Task {
      if automated {
        try await service.setClosedLid(id: id, enabled: true)
      } else {
        try await model.setClosedLid(id: id, enabled: true)
      }
    }
    await fixture.transport.waitForEnableReply()
    #expect(try await service.status().contains("Helper state: changing"))
    await #expect(throws: (any Error).self) { try await service.script(.closedLidEnabled) }
    model.refreshPower()
    #expect(!fixture.transport.actions.contains(.disable))
    fixture.transport.releaseReply()
    try await enabling.value
    #expect(model.engine.desiredState.closedLid)
    try await service.stop()
    #expect(await fixture.power.readback().confirmedDisabled)
  }

  @Test func cancellingAutomationDuringEnableResetsRatherThanCommitting() async throws {
    let fixture = await ControllerFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      assertions: ControllerAssertions(), closedLid: fixture.controller(),
      helperInstallation: HelperInstallation(service: InstallationFixture(power: fixture.power)))
    defer { model.shutdown() }
    let service = AutomationService()
    service.bind(model)
    let id = try await service.start(duration: 120)
    fixture.transport.delayEnableReply = true
    let enabling = Task { try await service.setClosedLid(id: id, enabled: true) }
    await fixture.transport.waitForEnableReply()
    enabling.cancel()
    fixture.transport.releaseReply()
    await #expect(throws: CancellationError.self) { try await enabling.value }
    #expect(!model.engine.desiredState.closedLid)
    #expect(await fixture.power.readback().confirmedDisabled)
    try await service.stop()
  }

  @Test func policyChangesDuringAnEnableInvalidateTheOldRequest() async throws {
    let fixture = await ControllerFixture()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { .init() },
      assertions: ControllerAssertions(), closedLid: fixture.controller(),
      helperInstallation: HelperInstallation(service: InstallationFixture(power: fixture.power)))
    defer { model.shutdown() }
    let service = AutomationService()
    service.bind(model)
    let id = try await service.start(duration: 120)
    fixture.transport.delayEnableReply = true
    let enabling = Task { try await service.setClosedLid(id: id, enabled: true) }
    await fixture.transport.waitForEnableReply()
    model.settings.closedLidBatteryFloor = 25
    fixture.transport.releaseReply()
    await #expect(throws: (any Error).self) { try await enabling.value }
    try await model.synchronizeClosedLid()
    #expect(!model.engine.desiredState.closedLid)
    #expect(await fixture.power.readback().confirmedDisabled)
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

@MainActor private final class ControllerAssertions: AssertionControlling {
  var activeTypes: Set<String> { [] }
  func synchronize(holds: [Hold], now: Date) throws {}
  func releaseAll() {}
}

@MainActor private struct ControllerFixture {
  let inputs: ControllerInputs
  let power: ControllerPower
  let service: ClosedLidService
  let transport: InProcessHelperTransport
  init(start: Bool = true) async {
    inputs = ControllerInputs()
    power = ControllerPower()
    let readings = inputs
    service = ClosedLidService(
      power: power, environment: { readings.read() }, clock: { 0 }, buildIdentity: "test-build")
    if start { await service.start() }
    transport = InProcessHelperTransport(service: service)
  }
  func controller() -> ClosedLidController {
    ClosedLidController(transport: transport, expectedBuild: { "test-build" })
  }
}

@MainActor private final class InProcessHelperTransport: HelperTransporting {
  var onDisconnect: (() -> Void)?
  var actions: [HelperAction] = []
  var delayEnableReply = false
  var failures: [HelperClientError] = []
  private let service: ClosedLidService
  private let owner = UUID()
  private var pending: (HelperReply, CheckedContinuation<HelperReply, Never>)?
  private var waiting: CheckedContinuation<Void, Never>?
  init(service: ClosedLidService) { self.service = service }
  func send(_ request: HelperRequest) async throws -> HelperReply {
    actions.append(request.action)
    if !failures.isEmpty { throw failures.removeFirst() }
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
  var registerErrors: [NSError] = []
  var registrationStatus = SMAppService.Status.requiresApproval
  private let power: ControllerPower
  init(power: ControllerPower) { self.power = power }
  func register() throws {
    #expect(status == .notRegistered)
    operations.append("register")
    if !registerErrors.isEmpty { throw registerErrors.removeFirst() }
    status = registrationStatus
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
