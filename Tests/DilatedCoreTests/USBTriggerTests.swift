import Foundation
import Testing

@testable import DilatedCore

struct USBTriggerTests {
  @Test func selectedUSBDeviceSurvivesTheRuleCodec() throws {
    let data = Data(
      #"{"usb":{"device":{"vendorID":1234,"productID":5678,"serialNumber":"studio-1"},"name":"Studio USB"}}"#
        .utf8)
    let criterion = try #require(try? JSONDecoder().decode(TriggerCriterion.self, from: data))
    let rule = TriggerRule(name: "USB work", criteria: [criterion])
    #expect(rule.validationMessage == nil)
    #expect(try JSONDecoder().decode(TriggerRule.self, from: JSONEncoder().encode(rule)) == rule)
  }

  @Test func serialMatchesOneUnitWhileMissingSerialMatchesTheModel() {
    let first = USBDeviceIdentity(vendorID: 1234, productID: 5678, serialNumber: "first")
    let second = USBDeviceIdentity(vendorID: 1234, productID: 5678, serialNumber: "second")
    let model = USBDeviceIdentity(vendorID: 1234, productID: 5678)
    #expect(first.matches(first))
    #expect(!first.matches(second) && !first.matches(model))
    #expect(model.matches(first) && model.matches(second) && model.matches(model))
    #expect(!model.matches(.init(vendorID: 1235, productID: 5678)))
    #expect(!model.matches(.init(vendorID: 1234, productID: 5679)))
    for invalid in [
      USBDeviceIdentity(vendorID: 0, productID: 1), .init(vendorID: 1, productID: -1),
      .init(vendorID: 65536, productID: 1), .init(vendorID: 1, productID: 65536),
      .init(vendorID: 1, productID: 1, serialNumber: " "),
      .init(vendorID: 1, productID: 1, serialNumber: "bad\0serial"),
    ] { #expect(!invalid.isValid && !model.matches(invalid)) }
  }

  @Test func removalUnknownInputAndStopOnlyEndTheUSBReason() throws {
    let now = Date()
    let device = USBDeviceIdentity(vendorID: 1234, productID: 5678, serialNumber: "first")
    var rule = TriggerRule(name: "USB work", criteria: [.usb(device: device, name: "Studio USB")])
    rule.graceSeconds = 2
    var input = TriggerInputs()
    var engine = WakeEngine()
    let manual = try engine.start(source: .manual, label: "Other work", now: now)
    var evaluator = TriggerEvaluator()
    #expect(!rule.matches(input, now: now))
    input.usbDevices = [device]
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now, uptime: 0)
    #expect(engine.holds.count == 2)
    input.usbDevices = []
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now, uptime: 1)
    #expect(engine.holds.count == 2)
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now, uptime: 3)
    #expect(engine.holds.map(\.id) == [manual.id])
    input.usbDevices = [device]
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now, uptime: 4)
    #expect(engine.holds.count == 2)
    input.usbDevices = nil
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now, uptime: 5)
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now, uptime: 7)
    #expect(engine.holds.map(\.id) == [manual.id])
    engine.stopAll(now: now)
    input.usbDevices = [device]
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now, uptime: 10)
    #expect(engine.holds.isEmpty && engine.automationPaused)
  }
}
