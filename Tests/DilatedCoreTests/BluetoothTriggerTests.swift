import Foundation
import Testing

@testable import DilatedCore

struct BluetoothTriggerTests {
  @Test func pairedBluetoothSelectionSurvivesTheRuleCodec() throws {
    let data = Data(
      #"{"bluetooth":{"device":"01:23:45:67:89:ab","name":"Studio headphones"}}"#.utf8)
    let criterion = try #require(try? JSONDecoder().decode(TriggerCriterion.self, from: data))
    let rule = TriggerRule(name: "Studio Bluetooth", criteria: [criterion])
    #expect(rule.validationMessage == nil)
    #expect(try JSONDecoder().decode(TriggerRule.self, from: JSONEncoder().encode(rule)) == rule)
  }

  @Test func identityNormalizesNativeAddressesAndRejectsInvalidPersistedValues() throws {
    let identity = try #require(BluetoothDeviceIdentity(address: "01-23-45-67-89-AB"))
    #expect(identity.address == "01:23:45:67:89:ab")
    #expect(identity == BluetoothDeviceIdentity(address: "01:23:45:67:89:ab"))
    for invalid in [
      "", "headphones", "01:23:45:67:89", "01:23:45:67:89:gg",
      "01-23:45:67:89:ab", "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff",
    ] {
      #expect(BluetoothDeviceIdentity(address: invalid) == nil)
      #expect(throws: (any Error).self) {
        try JSONDecoder().decode(BluetoothDeviceIdentity.self, from: JSONEncoder().encode(invalid))
      }
    }
    #expect(
      try JSONDecoder().decode(BluetoothDeviceIdentity.self, from: JSONEncoder().encode(identity))
        == identity)
  }

  @Test func disconnectionAndUnavailableBluetoothEndOnlyTheirOwnReason() throws {
    let now = Date()
    let selected = try #require(BluetoothDeviceIdentity(address: "01:23:45:67:89:ab"))
    let other = try #require(BluetoothDeviceIdentity(address: "01:23:45:67:89:ac"))
    let rule = TriggerRule(
      name: "Headphones", criteria: [.bluetooth(device: selected, name: "Studio")])
    var inputs = TriggerInputs()
    inputs.connectedBluetoothDevices = [other]
    #expect(!rule.matches(inputs, now: now))
    inputs.connectedBluetoothDevices = [selected]
    var engine = WakeEngine()
    let manual = try engine.start(source: .manual, label: "Other work", now: now)
    var evaluator = TriggerEvaluator()
    evaluator.reconcile(rules: [rule], inputs: inputs, engine: &engine, now: now)
    #expect(engine.holds.count == 2)
    inputs.connectedBluetoothDevices = []
    evaluator.reconcile(rules: [rule], inputs: inputs, engine: &engine, now: now)
    #expect(engine.holds.map(\.id) == [manual.id])
    inputs.connectedBluetoothDevices = [selected]
    evaluator.reconcile(rules: [rule], inputs: inputs, engine: &engine, now: now)
    inputs.connectedBluetoothDevices = nil
    evaluator.reconcile(rules: [rule], inputs: inputs, engine: &engine, now: now)
    #expect(engine.holds.map(\.id) == [manual.id])
    engine.stopAll(now: now)
    inputs.connectedBluetoothDevices = [selected]
    evaluator.reconcile(rules: [rule], inputs: inputs, engine: &engine, now: now)
    #expect(engine.holds.isEmpty && engine.automationPaused)
    #expect(!TriggerCriterion.bluetooth(device: selected, name: " ").isValid)
    #expect(!TriggerCriterion.bluetooth(device: nil, name: "Studio").isValid)
  }
}
