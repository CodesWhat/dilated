import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct TriggerCompatibilityTests {
  @Test(arguments: [false, true])
  func downgradeSaveAndReturnPreserveNewRulesAndLegacyEdits(disk: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let edited = TriggerRule(name: "AC", criteria: [.power(onBattery: false)])
    let removed = TriggerRule(name: "Battery", criteria: [.power(onBattery: true)])
    let newer = TriggerRule(
      name: "Transfer",
      criteria: [
        disk
          ? .diskThroughput(kilobytesPerSecond: 250, atLeast: true)
          : .networkThroughput(kilobytesPerSecond: 250, atLeast: true)
      ])
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    for rule in [edited, removed, newer] { try model.saveTrigger(rule) }
    let legacyFile = directory.appendingPathComponent("triggers.json")
    let oldReader = try? JSONDecoder().decode([LegacyRule].self, from: Data(contentsOf: legacyFile))
    #expect(oldReader?.map(\.id) == [edited.id, removed.id])
    var changed = edited
    changed.name = "Edited in older build"
    let added = TriggerRule(name: "Added in older build", criteria: [.power(onBattery: true)])
    try JSONEncoder().encode([changed, added]).write(to: legacyFile, options: .atomic)
    let returned = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { returned.shutdown() }
    #expect(Set(returned.triggerRules.map(\.id)) == [changed.id, added.id, newer.id])
    #expect(returned.triggerRules.first { $0.id == changed.id } == changed)
    #expect(returned.triggerRules.first { $0.id == newer.id } == newer)
    try returned.saveTrigger(added)
    let relaunched = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { relaunched.shutdown() }
    #expect(relaunched.triggerRules == returned.triggerRules)
  }

  @Test func existingBeta12TriggerFileMigratesWithoutDroppingRules() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let newer = TriggerRule(
      name: "Transfer", criteria: [.diskThroughput(kilobytesPerSecond: 80, atLeast: false)])
    let legacyFile = directory.appendingPathComponent("triggers.json")
    try JSONEncoder().encode([newer]).write(to: legacyFile)
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    #expect(model.triggerRules == [newer])
    let compatible = TriggerRule(name: "AC", criteria: [.power(onBattery: false)])
    try model.saveTrigger(compatible)
    #expect(
      try JSONDecoder().decode([LegacyRule].self, from: Data(contentsOf: legacyFile)).map(\.id) == [
        compatible.id
      ])
    let relaunched = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { relaunched.shutdown() }
    #expect(relaunched.triggerRules == [newer, compatible])
  }

  @Test(arguments: [false, true])
  func interruptedProjectionKeepsTheCommittedNewRules(projected: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let old = TriggerRule(name: "Before", criteria: [.power(onBattery: false)])
    var updated = old
    updated.name = "After"
    let newer = TriggerRule(
      name: "Transfer", criteria: [.networkThroughput(kilobytesPerSecond: 100, atLeast: true)])
    let record = CompatibilityRecord(
      schemaVersion: 1, rules: [updated, newer], legacy: [old], pendingLegacy: [updated])
    try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("triggers-v2.json"))
    try JSONEncoder().encode(projected ? [updated] : [old]).write(
      to: directory.appendingPathComponent("triggers.json"))
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    #expect(model.triggerRules == [updated, newer])
    try model.saveTrigger(updated)
    let saved = try JSONDecoder().decode(
      CompatibilityRecord.self,
      from: Data(contentsOf: directory.appendingPathComponent("triggers-v2.json")))
    #expect(saved.pendingLegacy == nil)
    #expect(saved.legacy == [updated])
    let mode =
      try FileManager.default.attributesOfItem(
        atPath: directory.appendingPathComponent("triggers-v2.json").path)[.posixPermissions]
      as? Int
    #expect(mode == 0o600)
  }

  @Test(arguments: [false, true])
  func conflictingOrFutureRecordsBlockWritesWithoutChangingEitherFile(future: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let old = TriggerRule(name: "Before", criteria: [.power(onBattery: false)])
    var updated = old
    updated.name = "After"
    var conflicting = old
    conflicting.name = "External edit after interrupted save"
    let record = CompatibilityRecord(
      schemaVersion: future ? 99 : 1, rules: [updated], legacy: [old], pendingLegacy: [updated])
    let canonical = directory.appendingPathComponent("triggers-v2.json")
    let legacy = directory.appendingPathComponent("triggers.json")
    let canonicalData = try JSONEncoder().encode(record)
    let legacyData = try JSONEncoder().encode([conflicting])
    try canonicalData.write(to: canonical)
    try legacyData.write(to: legacy)
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    #expect(model.triggerRules.isEmpty)
    #expect(throws: (any Error).self) { try model.saveTrigger(updated) }
    #expect(try Data(contentsOf: canonical) == canonicalData)
    #expect(try Data(contentsOf: legacy) == legacyData)
  }

  @Test(arguments: [false, true])
  func duplicateOrExcessLegacyRulesArePreservedWithoutASave(duplicate: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let rule = TriggerRule(name: "AC", criteria: [.power(onBattery: false)])
    let rules =
      duplicate
      ? [rule, rule]
      : (0...100).map { TriggerRule(name: "Rule \($0)", criteria: [.power(onBattery: false)]) }
    let file = directory.appendingPathComponent("triggers.json")
    let original = try JSONEncoder().encode(rules)
    try original.write(to: file)
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    #expect(model.triggerRules.isEmpty)
    #expect(throws: (any Error).self) { try model.saveTrigger(rule) }
    #expect(try Data(contentsOf: file) == original)
  }

  @Test func collidingLegacyRuleCannotReplaceAProtectedNewRule() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let newer = TriggerRule(
      name: "Transfer", criteria: [.diskThroughput(kilobytesPerSecond: 100, atLeast: true)])
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    try model.saveTrigger(newer)
    let protectedFile = directory.appendingPathComponent("triggers-v2.json")
    let original = try Data(contentsOf: protectedFile)
    var collision = TriggerRule(name: "Conflicting old rule", criteria: [.power(onBattery: true)])
    collision.id = newer.id
    let legacyFile = directory.appendingPathComponent("triggers.json")
    let legacyData = try JSONEncoder().encode([collision])
    try legacyData.write(to: legacyFile)
    let returned = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { returned.shutdown() }
    #expect(returned.triggerRules.isEmpty)
    #expect(throws: (any Error).self) { try returned.saveTrigger(collision) }
    #expect(try Data(contentsOf: protectedFile) == original)
    #expect(try Data(contentsOf: legacyFile) == legacyData)
  }

  @Test(arguments: ["triggers.json", "triggers-v2.json"])
  func unreadableTriggerFilesCannotBeOverwrittenByASubsequentSave(name: String) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(name)
    let original = Data("unreadable saved rules".utf8)
    try original.write(to: file)
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    #expect(throws: (any Error).self) {
      try model.saveTrigger(TriggerRule(name: "AC", criteria: [.power(onBattery: false)]))
    }
    #expect(try Data(contentsOf: file) == original)
  }
}

private struct LegacyRule: Decodable {
  let id: UUID
  let criteria: [LegacyCriterion]
}
private enum LegacyCriterion: Decodable {
  case power(onBattery: Bool)
}

private struct CompatibilityRecord: Codable {
  var schemaVersion: Int
  var rules: [TriggerRule]
  var legacy: [TriggerRule]
  var pendingLegacy: [TriggerRule]?
}
