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
