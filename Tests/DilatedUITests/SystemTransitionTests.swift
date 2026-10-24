import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct SystemTransitionTests {
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
}
