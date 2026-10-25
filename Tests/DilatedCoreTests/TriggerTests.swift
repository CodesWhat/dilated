import Foundation
import Testing

@testable import DilatedCore

struct TriggerTests {
  private let start = Date(timeIntervalSince1970: 1_800_000_000)

  @Test func legacyRulesDefaultClosedLidOffAndExposeIndependentActiveHoldIDs() throws {
    var rule = TriggerRule(name: "Build", criteria: [.process(name: "make")])
    rule.closedLid = true
    let data = try JSONEncoder().encode(rule)
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "closedLid")
    let restored = try JSONDecoder().decode(
      TriggerRule.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(!restored.closedLid)
    #expect(try JSONDecoder().decode(TriggerRule.self, from: data) == rule)
    var evaluator = TriggerEvaluator()
    var engine = WakeEngine(now: start)
    var input = TriggerInputs()
    input.processNames = ["make"]
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: start)
    #expect(evaluator.activeHoldIDs[rule.id] == engine.holds.first?.id)
    #expect(!engine.desiredState.closedLid)
    evaluator.reconcile(rules: [], inputs: input, engine: &engine, now: start)
    #expect(evaluator.activeHoldIDs.isEmpty && engine.holds.isEmpty)
  }

  @Test func everyMatchingRuleOwnsItsHoldAndOptionsMerge() throws {
    let app = TriggerRule(
      name: "Editor", criteria: [.application(bundleID: "test.editor", frontmostOnly: false)])
    var process = TriggerRule(name: "Build", criteria: [.process(name: "make")])
    process.displayAwake = true
    var evaluator = TriggerEvaluator()
    var engine = WakeEngine(now: start)
    var input = TriggerInputs()
    input.applications = ["test.editor"]
    input.processNames = ["make"]
    evaluator.reconcile(rules: [app, process], inputs: input, engine: &engine, now: start)
    #expect(engine.holds.map(\.label) == ["Editor", "Build"])
    #expect(engine.desiredState.displayAwake)
    input.processNames = []
    evaluator.reconcile(rules: [app, process], inputs: input, engine: &engine, now: start)
    #expect(engine.holds.map(\.label) == ["Editor"])
    #expect(!engine.desiredState.displayAwake)
  }

  @Test func criteriaAreAndedAndFrontmostIsDistinctFromRunning() {
    let rule = TriggerRule(
      name: "Editor on AC",
      criteria: [
        .application(bundleID: "test.editor", frontmostOnly: true), .power(onBattery: false),
      ])
    var input = TriggerInputs()
    input.applications = ["test.editor"]
    #expect(!rule.matches(input, now: start))
    input.frontmostApplication = "test.editor"
    #expect(rule.matches(input, now: start))
    input.power.onBattery = true
    #expect(!rule.matches(input, now: start))
  }

  @Test func stopPauseAndIndividualSuppressionCannotRestartWork() throws {
    let rule = TriggerRule(name: "Build", criteria: [.process(name: "make")])
    var input = TriggerInputs()
    input.processNames = ["make"]
    var evaluator = TriggerEvaluator()
    var engine = WakeEngine(now: start)
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: start)
    let id = try #require(engine.holds.first?.id)
    engine.stop(id: id)
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: start)
    #expect(engine.holds.isEmpty)
    input.processNames = []
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: start)
    input.processNames = ["make"]
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: start)
    #expect(engine.holds.count == 1)
    engine.stopAll()
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: start)
    engine.startManualForTest(now: start)
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: start)
    #expect(engine.holds.count == 1)
    engine.resumeAutomation()
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: start)
    #expect(engine.holds.count == 2)
  }

  @Test func dwellAndGraceRejectFlappingAndUseElapsedTime() {
    var rule = TriggerRule(name: "Build", criteria: [.process(name: "make")])
    rule.dwellSeconds = 30
    rule.graceSeconds = 10
    var input = TriggerInputs()
    var evaluator = TriggerEvaluator()
    var engine = WakeEngine(now: start)
    input.processNames = ["make"]
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: start, uptime: 100)
    evaluator.reconcile(
      rules: [rule], inputs: input, engine: &engine, now: start.addingTimeInterval(5000),
      uptime: 129)
    #expect(engine.holds.isEmpty)
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: start, uptime: 130)
    #expect(engine.holds.count == 1)
    input.processNames = []
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: start, uptime: 131)
    #expect(engine.holds.count == 1)
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: start, uptime: 141)
    #expect(engine.holds.isEmpty)
  }

  @Test func overnightScheduleUsesTheStartDayAndNextBoundary() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let schedule = WeeklySchedule(weekdays: [2], startMinute: 22 * 60, endMinute: 6 * 60)
    let monday = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 23)))
    let tuesday = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 5)))
    #expect(schedule.contains(monday, calendar: calendar))
    #expect(schedule.contains(tuesday, calendar: calendar))
    #expect(!schedule.contains(tuesday.addingTimeInterval(3600), calendar: calendar))
    #expect(
      schedule.nextBoundary(after: tuesday, calendar: calendar) == tuesday.addingTimeInterval(3600))
  }

  @Test func restorationDoesNotTrustSavedConditionHolds() throws {
    var engine = WakeEngine(now: start)
    try engine.start(source: .trigger, label: "Build", duration: 100, now: start)
    let restored = WakeEngine(snapshot: engine.snapshot, now: start)
    #expect(restored.holds.isEmpty)
  }

  @Test func resumingAnActiveRuleDoesNotLeaveAnOrphanHold() {
    let rule = TriggerRule(name: "Build", criteria: [.process(name: "make")])
    var input = TriggerInputs()
    input.processNames = ["make"]
    var evaluator = TriggerEvaluator()
    var engine = WakeEngine(now: start)
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: start)
    evaluator.resume(id: rule.id, engine: &engine)
    evaluator.reconcile(rules: [rule], inputs: input, engine: &engine, now: start)
    #expect(engine.holds.count == 1)
  }

  @Test func processIdentityDoesNotFollowAReusedPIDAndMirroringIsExplicit() {
    let selected = ProcessIdentity(pid: 123, startedAtMicroseconds: 10)
    var input = TriggerInputs()
    input.processInstances = [ProcessIdentity(pid: 123, startedAtMicroseconds: 20)]
    let process = TriggerRule(name: "Selected process", criteria: [.processInstance(selected)])
    #expect(!process.matches(input, now: start))
    input.processInstances = [selected]
    #expect(process.matches(input, now: start))
    let mirrored = TriggerRule(name: "Mirrored", criteria: [.mirrored(true)])
    #expect(!mirrored.matches(input, now: start))
    input.mirroredDisplays = true
    #expect(mirrored.matches(input, now: start))
  }

  @Test func unknownDisplayStateCannotMatchDisconnectedOrUnmirroredConditions() {
    let absent = TriggerRule(
      name: "No display", criteria: [.displays(minimum: 0, maximum: 0, externalOnly: true)])
    let unmirrored = TriggerRule(name: "Not mirrored", criteria: [.mirrored(false)])
    #expect(!absent.matches(.init(), now: start))
    #expect(!unmirrored.matches(.init(), now: start))
  }

  @Test func invalidOrEmptyRulesNeverMatch() {
    #expect(!TriggerRule(name: "Empty", criteria: []).matches(.init(), now: start))
    let invalid = TriggerRule(name: "Bad range", criteria: [.battery(minimum: 90, maximum: 10)])
    #expect(!invalid.matches(.init(), now: start))
  }
}

extension WakeEngine {
  fileprivate mutating func startManualForTest(now: Date) {
    _ = try? start(source: .manual, label: "Manual", now: now)
  }
}

struct TriggerNetworkTests {
  @Test func ipv4AndIpv6RangesDoNotMatchOtherFamiliesOrInvalidInput() {
    var input = TriggerInputs()
    input.addresses = ["192.168.8.42", "fd01:abcd::12"]
    let rule = TriggerRule(name: "Office", criteria: [.network(address: "192.168.8.0/24")])
    #expect(rule.matches(input, now: .now))
    #expect(
      !TriggerRule(name: "Elsewhere", criteria: [.network(address: "192.168.9.0/24")]).matches(
        input, now: .now))
    #expect(
      TriggerRule(name: "IPv6", criteria: [.network(address: "fd01:abcd::/64")]).matches(
        input, now: .now))
    #expect(!TriggerCriterion.network(address: "192.168.8.1/33").isValid)
    #expect(!TriggerCriterion.network(address: "192.168.8.1/").isValid)
  }
}
