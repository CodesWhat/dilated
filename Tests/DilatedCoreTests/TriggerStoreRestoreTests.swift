import Foundation
import Testing

@testable import DilatedCore

struct TriggerStoreRestoreTests {
  private func makeDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  private func rule(_ name: String) -> TriggerRule {
    TriggerRule(name: name, criteria: [.power(onBattery: false)])
  }

  private func backups(_ directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
      atPath: directory.appendingPathComponent("trigger-backups").path
    ).sorted()
  }

  @Test
  func backupNamesCarryTheFullMillisecondStamp() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TriggerStore(directory: directory)
    try store.save([rule("A")])
    try store.save([rule("A"), rule("B")])
    let names = try backups(directory)
    #expect(names.count == 2)
    for name in names {
      let digits = name.dropFirst("triggers-v2-".count).dropLast(".json".count)
      // A 32-bit format would wrap to a negative or truncated number and break name ordering.
      #expect(digits.count == 16 && (Int(digits) ?? 0) > 1_000_000_000_000)
    }
  }

  @Test
  func savesKeepOnlyTheNewestThreeBackups() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TriggerStore(directory: directory)
    for index in 1...5 { try store.save((1...index).map { rule("R\($0)") }) }
    #expect(try backups(directory).count == TriggerStore.backupLimit)
  }

  @Test
  func restorePicksTheNewestLoadableBackupAndKeepsTheUnreadableFile() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TriggerStore(directory: directory)
    let first = [rule("One")]
    let second = [rule("One"), rule("Two")]
    let third = [rule("One"), rule("Two"), rule("Three")]
    try store.save(first)
    try store.save(second)
    try store.save(third)
    let names = try backups(directory)
    // Corrupt the newest backup so restore has to fall back one step.
    try Data("not json".utf8).write(
      to: directory.appendingPathComponent("trigger-backups").appendingPathComponent(names.last!))
    let broken = Data("{\"schemaVersion\":1".utf8)
    try broken.write(to: directory.appendingPathComponent("triggers-v2.json"))

    #expect((try? store.load()) == nil)
    #expect(store.recovery()?.ruleCount == 2)
    let restored = try store.restoreLastGood(confirmed: true)
    #expect(restored == second)
    #expect(try store.load() == second)
    let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix("triggers-v2.unreadable-") }
    #expect(kept.count == 1)
    #expect(try Data(contentsOf: directory.appendingPathComponent(kept[0])) == broken)
  }

  @Test
  func restoreNeedsConfirmationAndChangesNothingWithout() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TriggerStore(directory: directory)
    try store.save([rule("One")])
    let broken = Data("garbage".utf8)
    let file = directory.appendingPathComponent("triggers-v2.json")
    try broken.write(to: file)
    #expect(throws: (any Error).self) { try store.restoreLastGood(confirmed: false) }
    #expect(try Data(contentsOf: file) == broken)
  }

  @Test
  func aNewerSchemaFileIsKeptNotDowngradedAndTheConfirmationSaysSo() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TriggerStore(directory: directory)
    let good = [rule("Good")]
    try store.save(good)
    let newer = Data("{\"schemaVersion\":9,\"rules\":[],\"legacy\":[],\"future\":true}".utf8)
    try newer.write(to: directory.appendingPathComponent("triggers-v2.json"))
    let recovery = try #require(store.recovery())
    #expect(recovery.currentIsNewerSchema)
    #expect(recovery.confirmation.contains("newer file stays beside it"))
    #expect(try store.restoreLastGood(confirmed: true) == good)
    let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix("triggers-v2.unreadable-") }
    #expect(kept.count == 1)
    #expect(try Data(contentsOf: directory.appendingPathComponent(kept[0])) == newer)
  }

  @Test
  func noRecoveryWhenTheStoreLoadsOrNoBackupExists() throws {
    let directory = makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TriggerStore(directory: directory)
    try store.save([rule("One")])
    #expect(store.recovery() == nil)
    try? FileManager.default.removeItem(at: directory.appendingPathComponent("trigger-backups"))
    try Data("garbage".utf8).write(to: directory.appendingPathComponent("triggers-v2.json"))
    #expect(store.recovery() == nil)
    #expect(throws: (any Error).self) { try store.restoreLastGood(confirmed: true) }
  }
}
