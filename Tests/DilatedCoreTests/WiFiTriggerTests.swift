import Foundation
import Testing

@testable import DilatedCore

struct WiFiTriggerTests {
  @Test func exactSSIDBytesSurviveTheRuleCodec() throws {
    let data = Data(#"{"wifi":{"ssid":"U3R1ZGlv"}}"#.utf8)
    let criterion = try #require(try? JSONDecoder().decode(TriggerCriterion.self, from: data))
    let rule = TriggerRule(name: "Studio Wi-Fi", criteria: [criterion])
    #expect(rule.validationMessage == nil)
    #expect(try JSONDecoder().decode(TriggerRule.self, from: JSONEncoder().encode(rule)) == rule)
  }

  @Test func matchingUsesSSIDBytesWithoutCaseFoldingOrUnicodeNormalization() {
    let ssid = Data("Studio".utf8)
    let rule = TriggerRule(name: "Studio Wi-Fi", criteria: [.wifi(ssid: ssid)])
    var input = TriggerInputs()
    #expect(!rule.matches(input, now: Date()))
    input.wifiSSIDs = [Data("studio".utf8)]
    #expect(!rule.matches(input, now: Date()))
    input.wifiSSIDs = [ssid, Data("Other".utf8)]
    #expect(rule.matches(input, now: Date()))
    let composed = TriggerRule(name: "Unicode", criteria: [.wifi(ssid: Data("Caf\u{e9}".utf8))])
    input.wifiSSIDs = [Data("Cafe\u{301}".utf8)]
    #expect(!composed.matches(input, now: Date()))
    input.wifiSSIDs = [Data("Caf\u{e9}".utf8)]
    #expect(composed.matches(input, now: Date()))
    #expect(!TriggerCriterion.wifi(ssid: Data()).isValid)
    #expect(!TriggerCriterion.wifi(ssid: Data(repeating: 65, count: 33)).isValid)
    #expect(TriggerCriterion.wifi(ssid: Data(repeating: 255, count: 32)).isValid)
    let binary = Data([0, 255, 127])
    input.wifiSSIDs = [binary]
    #expect(
      TriggerRule(name: "Binary", criteria: [.wifi(ssid: binary)]).matches(input, now: Date()))
  }

  @Test func unavailableSSIDEndsOnlyItsReasonAndStopStillWins() throws {
    let now = Date()
    let ssid = Data("Studio".utf8)
    var rule = TriggerRule(name: "Wi-Fi work", criteria: [.wifi(ssid: ssid)])
    rule.graceSeconds = 2
    var input = TriggerInputs()
    input.wifiSSIDs = [ssid]
    var engine = WakeEngine()
    let manual = try engine.start(source: .manual, label: "Other work", now: now)
    var evaluator = TriggerEvaluator()
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now, uptime: 0)
    #expect(engine.holds.count == 2)
    input.wifiSSIDs = nil
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now, uptime: 1)
    #expect(engine.holds.count == 2)
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now, uptime: 3)
    #expect(engine.holds.map(\.id) == [manual.id])
    engine.stopAll(now: now)
    input.wifiSSIDs = [ssid]
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: now, uptime: 4)
    #expect(engine.holds.isEmpty && engine.automationPaused)
  }
}
