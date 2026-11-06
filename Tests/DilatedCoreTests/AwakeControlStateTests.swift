import Foundation
import Testing

@testable import DilatedCore

struct AwakeControlStateTests {
  @Test func sharedStoreUsesOnlyItsDistributionDirectory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var requestedGroup: String?
    let store = try #require(
      AwakeControlStateStore.shared(containerURL: { group in
        requestedGroup = group
        return directory
      }))
    #expect(requestedGroup == "3524374A2S.com.codeswhat.dilated.controls")
    let state = AwakeControlState(snapshot: .init(automationPaused: true), appPID: 42)
    try store.write(state)
    #if MAS_CHANNEL
      let own = "mas"
      let other = "direct"
    #else
      let own = "direct"
      let other = "mas"
    #endif
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(own + "/awake.json").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent(other + "/awake.json").path))
    #expect(store.read() == state)
    #expect(AwakeControlStateStore.shared(containerURL: { _ in nil }) == nil)
  }

  @Test func snapshotExpiresAndRequiresLiveHost() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    var engine = WakeEngine(now: now)
    _ = try engine.start(source: .manual, label: "Private label", duration: 60, now: now)
    _ = try engine.start(source: .cli, label: "Another", duration: 120, now: now)
    let state = AwakeControlState(snapshot: engine.snapshot, appPID: 42)
    #expect(state.isAwake(at: now, hostIsRunning: true))
    #expect(!state.isAwake(at: now, hostIsRunning: false))
    #expect(state.isAwake(at: now.addingTimeInterval(119), hostIsRunning: true))
    #expect(!state.isAwake(at: now.addingTimeInterval(120), hostIsRunning: true))
    let encoded = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
    #expect(!encoded.contains("Private label"))
    #expect(!encoded.contains(engine.holds[0].id.uuidString))
  }

  @Test func indefiniteStateDoesNotChangeWithTimedRenewals() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    var engine = WakeEngine(now: now)
    _ = try engine.start(source: .manual, label: "Manual", now: now)
    let initial = AwakeControlState(snapshot: engine.snapshot, appPID: 42)
    _ = try engine.start(source: .cli, label: "CLI", duration: 60, now: now)
    #expect(AwakeControlState(snapshot: engine.snapshot, appPID: 42) == initial)
    #expect(initial.isAwake(at: now.addingTimeInterval(100_000), hostIsRunning: true))
  }

  @Test func storeRoundTripRejectsCorruptionAndUnsupportedSchema() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = AwakeControlStateStore(directory: directory)
    #expect(store.read() == nil)
    let state = AwakeControlState(snapshot: .init(automationPaused: true), appPID: 42)
    try store.write(state)
    #expect(store.read() == state)
    let file = directory.appendingPathComponent("awake.json")
    let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try Data("broken".utf8).write(to: file)
    #expect(store.read() == nil)
    try store.write(state)
    var json = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    json["schemaVersion"] = 999
    try JSONSerialization.data(withJSONObject: json).write(to: file)
    #expect(store.read() == nil)
  }
}
