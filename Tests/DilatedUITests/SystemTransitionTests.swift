import DilatedControl
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct SystemTransitionTests {
  @Test func optedInUserReturnRestoresHoldsAndReevaluatesCurrentTriggerConditions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"stopOnUserSwitch":true,"resumeOnUserReturn":true}"#.utf8).write(
      to: directory.appendingPathComponent("settings.json"))
    var power = PowerState(onBattery: false, batteryPercent: 100)
    let assertions = TransitionAssertions()
    let model = AppModel(
      endpoint: .init(stateDirectory: directory), power: { power }, assertions: assertions)
    defer { model.shutdown() }
    try model.saveTrigger(.init(name: "AC", criteria: [.power(onBattery: false)]))
    try model.saveTrigger(.init(name: "Battery", criteria: [.power(onBattery: true)]))
    model.begin()
    model.start()
    model.start(duration: 120)
    #expect(await model.control(.init(action: .lease, duration: 60)).ok)
    let ordinary = model.engine.holds.filter { $0.source != .trigger }
    #expect(ordinary.count == 3)
    model.handleSystemTransition(.userSwitch)
    #expect(model.engine.holds.isEmpty && model.engine.automationPaused)
    #expect(assertions.holds.isEmpty)
    #expect(try StateStore(directory: directory).load().holds.isEmpty)
    power.onBattery = true
    model.handleSystemTransition(.userReturn)
    #expect(model.engine.holds.filter { $0.source != .trigger } == ordinary)
    #expect(model.engine.holds.filter { $0.source == .trigger }.map(\.label) == ["Battery"])
    #expect(!model.engine.automationPaused && !model.engine.desiredState.closedLid)
    let resumed = model.engine.holds
    model.handleSystemTransition(.userReturn)
    #expect(model.engine.holds == resumed)
  }
  @Test func defaultPoliciesDoNotChangeExistingHolds() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    model.start(duration: 60)
    model.handleSystemTransition(.sleep)
    model.handleSystemTransition(.userSwitch)
    #expect(model.engine.holds.count == 1)
    #expect(!model.engine.automationPaused)
  }

  @Test func optedInTransitionsStopWorkAndCannotBeUndoneByAMatchingTrigger() throws {
    for transition in [SystemTransition.sleep, .userSwitch] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
      defer { model.shutdown() }
      model.settings.stopOnSystemSleep = true
      model.settings.stopOnUserSwitch = true
      model.start(duration: 60)
      try model.saveTrigger(.init(name: "AC", criteria: [.power(onBattery: false)]))
      model.reconcileTriggers(.init())
      #expect(model.engine.holds.count == 2)
      model.handleSystemTransition(transition)
      model.reconcileTriggers(.init())
      #expect(model.engine.holds.isEmpty)
      #expect(model.engine.automationPaused)
      #expect(!model.engine.desiredState.closedLid)
      #expect(model.attention == nil)
    }
  }

  private func makeModel(
    _ configure: (inout AppSettings) -> Void
  ) -> (AppModel, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    configure(&model.settings)
    return (model, directory)
  }

  @Test func userReturnDoesNothingUnlessOptedIn() {
    let (model, directory) = makeModel { $0.stopOnUserSwitch = true }
    defer { try? FileManager.default.removeItem(at: directory) }
    defer { model.shutdown() }
    model.start(duration: 60)
    model.handleSystemTransition(.userSwitch)
    model.handleSystemTransition(.userReturn)
    #expect(model.engine.holds.isEmpty)
    #expect(model.engine.automationPaused)
  }

  @Test func mainStopWhileAwayCancelsRestoration() {
    let (model, directory) = makeModel {
      $0.stopOnUserSwitch = true
      $0.resumeOnUserReturn = true
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    defer { model.shutdown() }
    model.start(duration: 60)
    model.handleSystemTransition(.userSwitch)
    model.stopAll()
    model.handleSystemTransition(.userReturn)
    #expect(model.engine.holds.isEmpty)
    #expect(model.engine.automationPaused)
  }

  @Test func commandLineOffWhileAwayCancelsRestoration() async {
    let (model, directory) = makeModel {
      $0.stopOnUserSwitch = true
      $0.resumeOnUserReturn = true
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    defer { model.shutdown() }
    model.start(duration: 60)
    model.handleSystemTransition(.userSwitch)
    #expect(await model.control(.init(action: .stopAll)).ok)
    model.handleSystemTransition(.userReturn)
    #expect(model.engine.holds.isEmpty)
    #expect(model.engine.automationPaused)
  }

  @Test func leaseReleasedWhileAwayIsNotRestored() async {
    let (model, directory) = makeModel {
      $0.stopOnUserSwitch = true
      $0.resumeOnUserReturn = true
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    defer { model.shutdown() }
    model.start(duration: 60)
    let lease = await model.control(.init(action: .lease, duration: 60))
    #expect(lease.ok)
    let ordinary = model.engine.holds.filter { $0.id != lease.id }
    #expect(ordinary.count == 1)
    model.handleSystemTransition(.userSwitch)
    model.stop(id: lease.id!)
    model.handleSystemTransition(.userReturn)
    #expect(model.engine.holds == ordinary)
    #expect(!model.engine.automationPaused)
  }

  @Test func leaseReleasedThroughControlWhileAwayIsNotRestored() async {
    let (model, directory) = makeModel {
      $0.stopOnUserSwitch = true
      $0.resumeOnUserReturn = true
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    defer { model.shutdown() }
    model.start(duration: 60)
    let lease = await model.control(.init(action: .lease, duration: 60))
    #expect(lease.ok)
    let ordinary = model.engine.holds.filter { $0.id != lease.id }
    #expect(ordinary.count == 1)
    model.handleSystemTransition(.userSwitch)
    #expect(model.engine.holds.isEmpty)
    let released = await model.control(.init(action: .release, id: lease.id))
    #expect(released.ok)
    model.handleSystemTransition(.userReturn)
    #expect(model.engine.holds == ordinary)
    #expect(!model.engine.automationPaused)
  }

  @Test func runnerReleasedByLabelWhileAwayIsNotRestored() async {
    let (model, directory) = makeModel {
      $0.stopOnUserSwitch = true
      $0.resumeOnUserReturn = true
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    defer { model.shutdown() }
    model.start(duration: 60)
    let runner = await model.control(
      .init(action: .runner, label: "agent-job", duration: 60))
    #expect(runner.ok)
    let ordinary = model.engine.holds.filter { $0.id != runner.id }
    #expect(ordinary.count == 1)
    model.handleSystemTransition(.userSwitch)
    let released = await model.control(.init(action: .release, label: "agent-job"))
    #expect(released.ok)
    model.handleSystemTransition(.userReturn)
    #expect(model.engine.holds == ordinary)
    let missing = await model.control(.init(action: .release, label: "agent-job"))
    #expect(!missing.ok)
  }

  @Test func preExistingPauseSurvivesReturn() throws {
    let (model, directory) = makeModel {
      $0.stopOnUserSwitch = true
      $0.resumeOnUserReturn = true
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    defer { model.shutdown() }
    model.stopAll()
    model.start(duration: 60)
    let manual = model.engine.holds
    #expect(manual.count == 1 && model.engine.automationPaused)
    model.handleSystemTransition(.userSwitch)
    #expect(model.engine.holds.isEmpty)
    model.handleSystemTransition(.userReturn)
    #expect(model.engine.holds == manual)
    #expect(model.engine.automationPaused)
    #expect(model.engine.holds.allSatisfy { $0.source != .trigger })
  }

  @Test func sleepPolicyStopWhileAwayCancelsRestoration() {
    let (model, directory) = makeModel {
      $0.stopOnSystemSleep = true
      $0.stopOnUserSwitch = true
      $0.resumeOnUserReturn = true
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    defer { model.shutdown() }
    model.start(duration: 60)
    model.handleSystemTransition(.userSwitch)
    model.handleSystemTransition(.sleep)
    model.handleSystemTransition(.userReturn)
    #expect(model.engine.holds.isEmpty)
    #expect(model.engine.automationPaused)
  }

  @Test func resumeOnUserReturnRoundTripsAndDefaultsOff() throws {
    var settings = AppSettings()
    #expect(!settings.resumeOnUserReturn)
    settings.resumeOnUserReturn = true
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(decoded == settings && decoded.resumeOnUserReturn)
    let legacy = try JSONDecoder().decode(
      AppSettings.self, from: Data(#"{"stopOnUserSwitch":true}"#.utf8))
    #expect(!legacy.resumeOnUserReturn)
  }
}

@MainActor private final class TransitionAssertions: AssertionControlling {
  var holds: [Hold] = []
  var activeTypes: Set<String> { [] }
  func synchronize(holds: [Hold], now: Date) throws { self.holds = holds }
  func releaseAll() { holds = [] }
}
