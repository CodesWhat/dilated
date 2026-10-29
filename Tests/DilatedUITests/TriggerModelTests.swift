import DilatedControl
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct TriggerModelTests {
  @Test func bluetoothRulesPersistAndStopPauseSurvivesReconstruction() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let endpoint = SocketEndpoint(stateDirectory: directory)
    let model = AppModel(endpoint: endpoint, power: { .init() })
    defer { model.shutdown() }
    model.start(duration: 60)
    let manual = try #require(model.engine.holds.first)
    let identity = try #require(BluetoothDeviceIdentity(address: "01:23:45:67:89:ab"))
    let rule = TriggerRule(
      name: "Bluetooth", criteria: [.bluetooth(device: identity, name: "Studio")])
    try model.saveTrigger(rule)
    var inputs = TriggerInputs()
    inputs.connectedBluetoothDevices = [identity]
    model.reconcileTriggers(inputs)
    #expect(model.engine.holds.count == 2)
    model.reconcileTriggers(.init())
    #expect(model.engine.holds.map(\.id) == [manual.id])
    model.stopAll()
    let restored = AppModel(endpoint: endpoint, power: { .init() })
    defer { restored.shutdown() }
    #expect(restored.triggerRules == [rule])
    restored.reconcileTriggers(inputs)
    #expect(restored.engine.automationPaused && restored.engine.holds.isEmpty)
    restored.resumeAutomation()
    restored.reconcileTriggers(inputs)
    #expect(restored.engine.holds.count == 1)
    restored.removeTrigger(id: rule.id)
    #expect(restored.engine.holds.isEmpty)
  }

  @Test func audioOutputRulePersistsAndOnlyEndsItsOwnReason() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let endpoint = SocketEndpoint(stateDirectory: directory)
    let model = AppModel(endpoint: endpoint, power: { .init() })
    defer { model.shutdown() }
    model.start(duration: 60)
    let manual = try #require(model.engine.holds.first)
    let rule = TriggerRule(
      name: "Studio", criteria: [.audioOutput(uid: "test-output", name: "Speakers")])
    try model.saveTrigger(rule)
    var input = TriggerInputs()
    input.audioOutputUID = "test-output"
    model.reconcileTriggers(input)
    #expect(model.engine.holds.count == 2)
    model.reconcileTriggers(.init())
    #expect(model.engine.holds.map(\.id) == [manual.id])
    model.stopAll()
    let restored = AppModel(endpoint: endpoint, power: { .init() })
    defer { restored.shutdown() }
    #expect(restored.triggerRules == [rule])
    restored.reconcileTriggers(input)
    #expect(restored.engine.automationPaused && restored.engine.holds.isEmpty)
    restored.resumeAutomation()
    restored.reconcileTriggers(input)
    #expect(restored.engine.holds.count == 1)
    restored.removeTrigger(id: rule.id)
    #expect(restored.engine.holds.isEmpty)
  }

  @Test func rulesPersistButConditionsAreReevaluatedAndStopRemainsDurable() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let endpoint = SocketEndpoint(stateDirectory: directory)
    let model = AppModel(endpoint: endpoint, power: { .init() })
    defer { model.shutdown() }
    let rule = TriggerRule(
      name: "Editor", criteria: [.application(bundleID: "test.editor", frontmostOnly: false)])
    try model.saveTrigger(rule)
    var input = TriggerInputs()
    input.applications = ["test.editor"]
    model.reconcileTriggers(input)
    #expect(model.engine.holds.map(\.label) == ["Editor"])
    model.stopAll()
    model.reconcileTriggers(input)
    #expect(model.engine.holds.isEmpty)
    let restored = AppModel(endpoint: endpoint, power: { .init() })
    defer { restored.shutdown() }
    #expect(restored.triggerRules == [rule])
    restored.reconcileTriggers(input)
    #expect(restored.engine.holds.isEmpty)
    restored.resumeAutomation()
    restored.reconcileTriggers(.init())
    #expect(restored.engine.holds.isEmpty)
    restored.reconcileTriggers(input)
    #expect(restored.engine.holds.count == 1)
    restored.removeTrigger(id: rule.id)
    #expect(restored.engine.holds.isEmpty)
  }

  @Test func resumeReevaluatesMatchingConditionsEvenWithoutAnInterveningEvent() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    try model.saveTrigger(
      TriggerRule(
        name: "Editor", criteria: [.application(bundleID: "test.editor", frontmostOnly: false)]))
    var input = TriggerInputs()
    input.applications = ["test.editor"]
    model.reconcileTriggers(input)
    model.stopAll()
    model.resumeAutomation()
    model.reconcileTriggers(input)
    #expect(model.engine.holds.count == 1)
  }

  @Test func invalidRuleDoesNotReplaceSavedConfiguration() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    #expect(throws: (any Error).self) {
      try model.saveTrigger(TriggerRule(name: "Empty", criteria: []))
    }
    #expect(model.triggerRules.isEmpty)
  }
}

struct TriggerCriteriaRowsTests {
  private let power = TriggerCriterion.power(onBattery: true)
  private let process = TriggerCriterion.process(name: "Xcode")
  private let cpu = TriggerCriterion.cpu(percent: 50, atLeast: true)

  @Test func removingByIdKeepsOrderAndSurvivorIdentity() {
    var rows = TriggerCriteriaRows([power, process, cpu])
    let ids = rows.rows.map(\.id)
    rows.remove(id: ids[0])
    #expect(rows.values == [process, cpu])
    #expect(rows.rows.map(\.id) == [ids[1], ids[2]])
    var middle = TriggerCriteriaRows([power, process, cpu])
    let all = middle.rows.map(\.id)
    middle.remove(id: all[0])
    middle.remove(id: all[1])
    #expect(middle.values == [cpu])
    #expect(middle.rows.map(\.id) == [all[2]])
  }

  @Test func removingTheLastItemAndUnknownIdsNeverTrap() {
    var rows = TriggerCriteriaRows([power, process])
    let ids = rows.rows.map(\.id)
    rows.remove(id: ids[1])
    rows.remove(id: ids[1])
    #expect(rows.values == [power])
    rows.remove(id: ids[0])
    #expect(rows.values.isEmpty)
    rows.remove(id: ids[0])
    #expect(rows.rows.isEmpty)
  }

  @Test func valuesAreThePlainListAndAppendRespectsTheCap() {
    var rows = TriggerCriteriaRows([power])
    rows.append(process)
    #expect(rows.values == [power, process])
    for _ in 0..<20 { rows.append(cpu) }
    #expect(rows.rows.count == TriggerCriteriaRows.maximum)
    #expect(!rows.canAdd)
  }

  @Test func editedRuleRoundTripsThroughJSONUnchanged() throws {
    var rule = TriggerRule(name: "Round trip", criteria: [power, process, cpu])
    var rows = TriggerCriteriaRows(rule.criteria)
    rows.remove(id: rows.rows[1].id)
    rows.rows[0].value = .power(onBattery: false)
    rule.criteria = rows.values
    var plain = TriggerRule(name: "Round trip", criteria: [.power(onBattery: false), cpu])
    plain.id = rule.id
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let edited = try encoder.encode(rule)
    #expect(edited == (try encoder.encode(plain)))
    #expect(try JSONDecoder().decode(TriggerRule.self, from: edited) == rule)
  }
}
