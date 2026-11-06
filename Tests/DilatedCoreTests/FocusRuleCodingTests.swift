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
}
