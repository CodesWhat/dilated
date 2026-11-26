import Foundation
import Testing

@testable import DilatedCore

@Suite struct PrivateStateWriterTests {
  private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  private func mode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? Int ?? -1) & 0o777
  }

  private func leftovers(_ directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).filter {
      $0.contains(".tmp.")
    }
  }

  @Test func stateStoreWritesPrivatelyAndReplaces() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = StateStore(directory: directory)
    try store.save(EngineSnapshot())
    try store.save(EngineSnapshot(automationPaused: true))
    #expect(try mode(store.file) == 0o600)
    #expect(try mode(directory) == 0o700)
    #expect(try store.load().automationPaused)
    #expect(try leftovers(directory).isEmpty)
  }

  @Test func awakeControlStateWritesPrivatelyAndReplaces() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AwakeControlStateStore(directory: directory)
    try store.write(AwakeControlState(snapshot: EngineSnapshot(), appPID: 7))
    try store.write(
      AwakeControlState(snapshot: EngineSnapshot(automationPaused: true), appPID: 8))
    let file = directory.appendingPathComponent("awake.json")
    #expect(try mode(file) == 0o600)
    #expect(try mode(directory) == 0o700)
    #expect(try leftovers(directory).isEmpty)
  }

  @Test func triggerStoreWritesPrivatelyAndReplaces() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TriggerStore(directory: directory)
    try store.save([])
    try store.save([])
    #expect(try mode(directory) == 0o700)
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(!files.isEmpty)
    for name in files { #expect(try mode(directory.appendingPathComponent(name)) == 0o600) }
    #expect(try leftovers(directory).isEmpty)
  }

  @Test func historyStoreWritesPrivatelyAndReplaces() throws {
    let directory = scratch()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = HistoryStore(directory: directory)
    try store.save(SessionHistory())
    try store.save(SessionHistory())
    #expect(try mode(directory) == 0o700)
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(!files.isEmpty)
    for name in files { #expect(try mode(directory.appendingPathComponent(name)) == 0o600) }
    #expect(try leftovers(directory).isEmpty)
  }
}
