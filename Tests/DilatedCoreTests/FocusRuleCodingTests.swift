import Foundation
import Testing

@testable import DilatedCore

struct FocusRuleCodingTests {
  @Test func oldRulesHaveNoFocusOwnershipAndNewOwnershipRoundTrips() throws {
    let data = Data(
      """
      {"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","enabled":true,"criteria":[{"power":{"onBattery":false}}],"displayAwake":false,"lowPowerOverride":false,"dwellSeconds":0,"graceSeconds":0}
      """.utf8)
    var rule = try JSONDecoder().decode(TriggerRule.self, from: data)
    #expect(!rule.focusControlled)
    rule.focusControlled = true
    #expect(try JSONDecoder().decode(TriggerRule.self, from: JSONEncoder().encode(rule)) == rule)
  }

  @Test func olderReadersCannotRunFocusOwnedRulesAndTheirEditsSurviveReturn() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TriggerStore(directory: directory)
    var focus = TriggerRule(name: "Focus", criteria: [.power(onBattery: false)])
    focus.focusControlled = true
    var other = TriggerRule(name: "Other", criteria: [.power(onBattery: false)])
    try store.save([focus, other])
    let legacy = directory.appendingPathComponent("triggers.json")
    let projected = try JSONDecoder().decode([TriggerRule].self, from: Data(contentsOf: legacy))
    #expect(projected.map(\.id) == [other.id])
    other.name = "Edited by older build"
    try JSONEncoder().encode([other]).write(to: legacy, options: .atomic)
    let returned = try store.load()
    #expect(returned == [focus, other])
    try store.save(returned)
    #expect(try store.load() == [focus, other])
  }
}
