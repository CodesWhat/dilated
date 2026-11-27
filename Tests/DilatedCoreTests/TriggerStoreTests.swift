import Foundation
import Testing

@testable import DilatedCore

struct TriggerStoreTests {
  @Test(arguments: [false, true])
  func missingProjectionPreservesRulesWhileAnEmptyProjectionDeletesThem(missing: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TriggerStore(directory: directory)
    let rule = TriggerRule(name: "AC", criteria: [.power(onBattery: false)])
    try store.save([rule])
    let projection = directory.appendingPathComponent("triggers.json")
    if missing {
      try FileManager.default.removeItem(at: projection)
    } else {
      try JSONEncoder().encode([TriggerRule]()).write(to: projection, options: .atomic)
    }
    let expected = missing ? [rule] : []
    let loaded = try store.load()
    #expect(loaded == expected)
    try store.save(loaded)
    #expect(try store.load() == expected)
    #expect(
      try JSONDecoder().decode([TriggerRule].self, from: Data(contentsOf: projection)) == expected)
  }
}

/// The decoding path of the shipped 1.0.0 reader, copied so the schema boundary is checked
/// against that exact code rather than against the current store.
private enum V100Reader {
  struct Record: Codable {
    var schemaVersion = 1
    var rules: [TriggerRule]
    var legacy: [TriggerRule]
    var pendingLegacy: [TriggerRule]?
  }

  struct Rejected: Error {}

  static func load(_ file: URL) throws -> [TriggerRule] {
    let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file))
    guard record.schemaVersion == 1 else { throw Rejected() }
    return record.rules
  }
}

extension TriggerStoreTests {
  @Test
  func focusControlledRulesAreRejectedByTheV100Reader() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TriggerStore(directory: directory)
    let file = directory.appendingPathComponent("triggers-v2.json")
    var focus = TriggerRule(name: "Focus", criteria: [.power(onBattery: false)])
    focus.focusControlled = true
    let ordinary = TriggerRule(name: "AC", criteria: [.power(onBattery: false)])

    try store.save([ordinary])
    #expect(try V100Reader.load(file) == [ordinary])

    try store.save([ordinary, focus])
    #expect(throws: V100Reader.Rejected.self) { try V100Reader.load(file) }
    #expect(try store.load() == [ordinary, focus])

    try store.save([ordinary])
    #expect(try V100Reader.load(file) == [ordinary])
  }

  @Test
  func existingVersionOneFilesStillLoad() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rule = TriggerRule(name: "AC", criteria: [.power(onBattery: false)])
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(V100Reader.Record(rules: [rule], legacy: [rule]))
      .write(to: directory.appendingPathComponent("triggers-v2.json"))
    try JSONEncoder().encode([rule]).write(to: directory.appendingPathComponent("triggers.json"))
    #expect(try TriggerStore(directory: directory).load() == [rule])
  }
}
