import AppKit
import DilatedControl
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct FeedbackTests {
  @Test func oldSettingsStayQuietAndNewPreferencesRoundTrip() throws {
    let settings = try JSONDecoder().decode(
      AppSettings.self, from: Data(#"{"countdown":true}"#.utf8))
    #expect(!settings.feedback.notifications && !settings.feedback.startSound)
    #expect(!settings.feedback.endSound && !settings.feedback.extendSound)
    #expect(!settings.feedback.includeAutomation && settings.feedback.reminderMinutes == 0)
    var value = settings
    value.feedback.notifications = true
    value.feedback.startChoice = .custom(id: UUID(), name: "Mine")
    let saved = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(value))
    #expect(saved == value)
  }

  @Test func manualStartsEndsAndSafetyReasonsAreIndependentOfRecording() async throws {
    let fixture = FeedbackFixture()
    let controller = fixture.controller()
    defer { controller.stop() }
    var settings = FeedbackSettings()
    settings.notifications = true
    settings.startSound = true
    settings.endSound = true
    var engine = WakeEngine()
    controller.update(settings: settings, events: [], holds: [], uptime: 0, baseline: true)
    let hold = try engine.start(source: .manual, label: "Upload", duration: 60)
    controller.update(
      settings: settings, events: engine.takeHistoryEvents(), holds: engine.holds, uptime: 1)
    await fixture.drain()
    #expect(fixture.notices.map(\.kind) == [.started])
    #expect(fixture.played == [.awake])
    engine.updatePower(.init(lowPowerMode: true))
    controller.update(settings: settings, events: engine.takeHistoryEvents(), holds: [], uptime: 2)
    await fixture.drain()
    #expect(fixture.notices.last?.kind == .ended)
    #expect(fixture.notices.last?.body.contains("Low Power Mode") == true)
    #expect(fixture.played == [.awake, .rest])
    #expect(engine.automationPaused == false && engine.holds.isEmpty)
    #expect(hold.source == .manual)
    #expect(fixture.authorizationRequests == 0)
  }

  @Test func failedTransientStartsAndRestoredHoldsStaySilent() throws {
    let fixture = FeedbackFixture()
    let controller = fixture.controller()
    defer { controller.stop() }
    var settings = FeedbackSettings()
    settings.notifications = true
    settings.startSound = true
    settings.endSound = true
    settings.includeAutomation = true
    var engine = WakeEngine()
    let restored = try engine.start(source: .manual, label: "Recovered", duration: 60)
    controller.update(
      settings: settings, events: engine.takeHistoryEvents(), holds: engine.holds, uptime: 0,
      baseline: true)
    let failed = try engine.start(source: .cli, label: "Failed", duration: 60)
    engine.stop(id: failed.id, reason: .helperFailure)
    controller.update(
      settings: settings, events: engine.takeHistoryEvents(), holds: [restored], uptime: 1)
    #expect(fixture.played.isEmpty && fixture.notices.isEmpty)
  }

  @Test func notificationsStillWorkWhenHistoryRecordingIsDisabled() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = FeedbackFixture()
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    model.feedback = fixture.controller()
    defer { model.shutdown() }
    model.settings.historyEnabled = false
    model.settings.feedback.notifications = true
    model.begin()
    model.start(duration: 60)
    await wait { fixture.notices.count == 1 }
    #expect(fixture.notices.first?.kind == .started)
    #expect(model.history.active.isEmpty && model.history.records.isEmpty)
    model.stopAll()
    await wait { fixture.notices.count == 2 }
    #expect(fixture.notices.last?.kind == .ended)
    #expect(model.engine.automationPaused && fixture.authorizationRequests == 0)
  }

  @Test func aClosedLidSafetyStopReportsItsReasonWithoutEndingOtherWork() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = FeedbackFixture()
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    model.feedback = fixture.controller()
    defer { model.shutdown() }
    model.settings.feedback.notifications = true
    model.settings.feedback.sessionStarts = false
    model.settings.feedback.endSound = true
    model.begin()
    model.start(duration: 60)
    let id = try #require(model.engine.holds.first?.id)
    model.closedLid.onEnded?("Closed-lid stopped: battery 19%.")
    await fixture.drain()
    #expect(fixture.notices.last?.title == "Closed-lid stopped")
    #expect(fixture.notices.last?.body.contains("19%") == true)
    #expect(fixture.played == [.rest])
    #expect(model.engine.holds.map(\.id) == [id] && !model.engine.desiredState.closedLid)
  }

  @Test func explicitExtensionSoundsButLeaseRenewalDoesNot() throws {
    let fixture = FeedbackFixture()
    let controller = fixture.controller()
    defer { controller.stop() }
    var settings = FeedbackSettings()
    settings.extendSound = true
    settings.includeAutomation = true
    var engine = WakeEngine()
    let hold = try engine.start(source: .lease, label: "Agent", duration: 60)
    controller.update(
      settings: settings, events: engine.takeHistoryEvents(), holds: engine.holds, uptime: 0,
      baseline: true)
    try engine.renew(id: hold.id, duration: 120)
    controller.update(
      settings: settings, events: engine.takeHistoryEvents(), holds: engine.holds, uptime: 1)
    #expect(fixture.played.isEmpty)
    try engine.extend(id: hold.id, by: 30)
    controller.update(
      settings: settings, events: engine.takeHistoryEvents(), holds: engine.holds, uptime: 2)
    #expect(fixture.played == [.extended])
  }

  @Test func remindersUseMonotonicDeadlinesAndNeverCatchUpAfterAHang() async throws {
    let fixture = FeedbackFixture()
    let controller = fixture.controller()
    defer { controller.stop() }
    var settings = FeedbackSettings()
    settings.notifications = true
    settings.reminderMinutes = 1
    var engine = WakeEngine()
    _ = try engine.start(source: .manual, label: "Timer")
    controller.update(
      settings: settings, events: [], holds: engine.holds, uptime: 0, baseline: true)
    controller.tick(uptime: 59)
    await fixture.drain()
    #expect(fixture.notices.isEmpty)
    controller.tick(uptime: 600)
    await fixture.drain()
    #expect(fixture.notices.map(\.kind) == [.reminder])
    controller.tick(uptime: 601)
    await fixture.drain()
    #expect(fixture.notices.count == 1)
    engine.stopAll()
    controller.update(
      settings: settings, events: engine.takeHistoryEvents(), holds: [], uptime: 602)
    await fixture.drain()
    let reminders = fixture.notices.filter { $0.kind == .reminder }.count
    controller.tick(uptime: 1200)
    await fixture.drain()
    #expect(fixture.notices.filter { $0.kind == .reminder }.count == reminders)
    #expect(engine.automationPaused)
  }

  @Test func triggerAndAutomationScopesCoalesceEachBatch() async throws {
    let fixture = FeedbackFixture()
    let controller = fixture.controller()
    defer { controller.stop() }
    var settings = FeedbackSettings()
    settings.notifications = true
    var engine = WakeEngine()
    controller.update(settings: settings, events: [], holds: [], uptime: 0, baseline: true)
    _ = try engine.start(source: .trigger, label: "AC")
    _ = try engine.start(source: .trigger, label: "Editor")
    _ = try engine.start(source: .lease, label: "Agent", duration: 60)
    controller.update(
      settings: settings, events: engine.takeHistoryEvents(), holds: engine.holds, uptime: 1)
    await fixture.drain()
    #expect(fixture.notices.count == 1)
    #expect(fixture.notices[0].body.contains("AC") && fixture.notices[0].body.contains("Editor"))
    #expect(!fixture.notices[0].body.contains("Agent"))
  }

  @Test func deniedPermissionNeverPromptsFromEventsAndSoundFailureDoesNotChangeHolds() async throws
  {
    let fixture = FeedbackFixture()
    fixture.permission = .denied
    fixture.soundFails = true
    let controller = fixture.controller()
    defer { controller.stop() }
    var settings = FeedbackSettings()
    settings.notifications = true
    settings.startSound = true
    var engine = WakeEngine()
    controller.update(settings: settings, events: [], holds: [], uptime: 0, baseline: true)
    _ = try engine.start(source: .manual, label: "Work")
    controller.update(
      settings: settings, events: engine.takeHistoryEvents(), holds: engine.holds, uptime: 1)
    await fixture.drain()
    #expect(fixture.notices.isEmpty && fixture.authorizationRequests == 0)
    #expect(controller.issue != nil && engine.holds.count == 1)
    #expect(await controller.requestPermission() == false)
    #expect(fixture.authorizationRequests == 1)
  }

  @Test func anIdleRefreshDoesNotCancelTheCompletedEndNotice() async throws {
    let fixture = FeedbackFixture()
    let controller = fixture.controller()
    defer { controller.stop() }
    var settings = FeedbackSettings()
    settings.notifications = true
    var engine = WakeEngine()
    _ = try engine.start(source: .manual, label: "Timer")
    controller.update(
      settings: settings, events: [], holds: engine.holds, uptime: 0, baseline: true)
    engine.stopAll()
    controller.update(settings: settings, events: engine.takeHistoryEvents(), holds: [], uptime: 1)
    await fixture.drain()
    let ended = try #require(fixture.notices.last?.id)
    controller.update(settings: settings, events: [], holds: [], uptime: 2)
    #expect(!fixture.cancelled.contains(ended))
  }

  @Test func lateAuthorizationAfterStopCannotSendAStartOrPrompt() async throws {
    let fixture = FeedbackFixture()
    fixture.delayAuthorization = true
    let controller = fixture.controller()
    defer { controller.stop() }
    var settings = FeedbackSettings()
    settings.notifications = true
    settings.sessionEnds = false
    var engine = WakeEngine()
    controller.update(settings: settings, events: [], holds: [], uptime: 0, baseline: true)
    _ = try engine.start(source: .manual, label: "Timer")
    controller.update(
      settings: settings, events: engine.takeHistoryEvents(), holds: engine.holds, uptime: 1)
    await wait { fixture.authorizationGate != nil }
    let gate = try #require(fixture.authorizationGate)
    engine.stopAll()
    controller.update(settings: settings, events: engine.takeHistoryEvents(), holds: [], uptime: 2)
    gate.resume(returning: .allowed)
    fixture.authorizationGate = nil
    await wait { fixture.authorizationReturned }
    #expect(fixture.notices.isEmpty && fixture.authorizationRequests == 0)
    #expect(engine.automationPaused && engine.holds.isEmpty)
  }

  @Test func aLateSendCancelsOnlyItsOwnRequestAfterANewerManualStart() async throws {
    let fixture = FeedbackFixture()
    fixture.delaySend = true
    let controller = fixture.controller()
    defer { controller.stop() }
    var settings = FeedbackSettings()
    settings.notifications = true
    settings.sessionEnds = false
    var engine = WakeEngine()
    controller.update(settings: settings, events: [], holds: [], uptime: 0, baseline: true)
    _ = try engine.start(source: .manual, label: "Old")
    controller.update(
      settings: settings, events: engine.takeHistoryEvents(), holds: engine.holds, uptime: 1)
    await wait { fixture.sendGate != nil }
    let gate = try #require(fixture.sendGate)
    let oldID = try #require(fixture.notices.first?.id)
    engine.stopAll()
    controller.update(settings: settings, events: engine.takeHistoryEvents(), holds: [], uptime: 2)
    fixture.delaySend = false
    _ = try engine.start(source: .manual, label: "New")
    controller.update(
      settings: settings, events: engine.takeHistoryEvents(), holds: engine.holds, uptime: 3)
    await wait { fixture.notices.count == 2 }
    let newID = try #require(fixture.notices.last?.id)
    let count = fixture.cancelled.filter { $0 == oldID }.count
    gate.resume()
    fixture.sendGate = nil
    await wait { fixture.cancelled.filter { $0 == oldID }.count > count }
    #expect(!fixture.cancelled.contains(newID))
    #expect(engine.automationPaused && engine.holds.count == 1)
  }

  @Test func shutdownDuringExplicitPermissionDiscardsTheLateResult() async throws {
    let fixture = FeedbackFixture()
    fixture.delayPermission = true
    let controller = fixture.controller()
    let request = Task { await controller.requestPermission() }
    await wait { fixture.permissionGate != nil }
    let gate = try #require(fixture.permissionGate)
    controller.stop()
    gate.resume(returning: .allowed)
    fixture.permissionGate = nil
    #expect(await request.value == false)
    #expect(fixture.authorizationRequests == 1 && fixture.notices.isEmpty)
  }

  private func wait(_ predicate: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() && ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(1))
    }
  }

  @Test func customSoundImportIsTransactionalAndSharedChoicesArePreserved() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    let store = FeedbackSoundStore(directory: directory)
    let data = try store.data(for: .awake)
    let custom = try store.save(data, name: "My sound")
    model.settings.feedback.startChoice = custom
    model.settings.feedback.endChoice = custom
    try model.setFeedbackSound(.awake, for: .start)
    #expect(try store.data(for: custom) == data)
    let source = directory.appendingPathComponent("input.wav")
    try data.write(to: source)
    let preferences = directory.appendingPathComponent("settings.json")
    try FileManager.default.removeItem(at: preferences)
    try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) {
      try await model.importFeedbackSound(from: source, for: .end)
    }
    #expect(model.settings.feedback.endChoice == custom)
    #expect(try store.data(for: custom) == data)
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: directory.appendingPathComponent("sounds").path
      ).count == 1)
    try FileManager.default.removeItem(at: preferences)
    try model.setFeedbackSound(.rest, for: .end)
    #expect(throws: (any Error).self) { try store.data(for: custom) }
  }

  @Test func bundledAndCustomSoundsDecodeWithoutPlayingAndFailedImportPreservesData() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FeedbackSoundStore(directory: directory)
    for choice in [FeedbackSound.awake, .rest, .extended] {
      let data = try store.data(for: choice)
      let sound = try #require(NSSound(data: data))
      #expect(sound.duration > 0 && sound.duration < 1)
    }
    let imported = try store.save(try store.data(for: .awake), name: "My cue.wav")
    #expect(try store.data(for: imported) == store.data(for: .awake))
    #expect(throws: (any Error).self) { try store.save(Data([1, 2, 3]), name: "Bad") }
    #expect(throws: (any Error).self) {
      try store.save(Data(repeating: 0, count: 2_000_001), name: "Large")
    }
    #expect(try store.data(for: imported) == store.data(for: .awake))
  }
}

@MainActor private final class FeedbackFixture: FeedbackService, FeedbackSoundPlaying {
  var permission = FeedbackAuthorization.allowed
  var authorizationRequests = 0
  var notices: [FeedbackNotice] = []
  var cancelled: [UUID] = []
  var played: [FeedbackSound] = []
  var soundFails = false
  var stops = 0
  var delayAuthorization = false
  var authorizationReturned = false
  var authorizationGate: CheckedContinuation<FeedbackAuthorization, Never>?
  var delayPermission = false
  var permissionGate: CheckedContinuation<FeedbackAuthorization, Never>?
  var delaySend = false
  var sendGate: CheckedContinuation<Void, Never>?
  private weak var lastController: FeedbackController?
  func controller() -> FeedbackController {
    let controller = FeedbackController(service: self, sounds: self)
    lastController = controller
    return controller
  }
  func authorization() async -> FeedbackAuthorization {
    try? await Task.sleep(for: .milliseconds(5))
    if delayAuthorization {
      let result = await withCheckedContinuation { authorizationGate = $0 }
      authorizationReturned = true
      return result
    }
    return permission
  }
  func requestAuthorization() async throws -> FeedbackAuthorization {
    authorizationRequests += 1
    if delayPermission { return await withCheckedContinuation { permissionGate = $0 } }
    return permission
  }
  func send(_ notice: FeedbackNotice) async throws {
    notices.append(notice)
    if delaySend { await withCheckedContinuation { sendGate = $0 } }
  }
  func cancel(_ ids: [UUID]) { cancelled += ids }
  func play(_ choice: FeedbackSound) throws {
    if soundFails { throw InputError("Sound unavailable") }
    played.append(choice)
  }
  func stop() { stops += 1 }
  func drain() async {
    for delivery in lastController?.pendingDeliveriesForTesting ?? [] { await delivery.value }
  }
}
