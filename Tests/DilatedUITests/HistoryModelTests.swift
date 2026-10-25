import DilatedControl
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct HistoryModelTests {
  @Test func manualCliTriggerAndSystemEndingsReachHistory() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    model.start(duration: 120)
    let response = await model.control(.init(action: .start, label: "CLI", duration: 120))
    #expect(response.ok)
    try model.saveTrigger(.init(name: "AC", criteria: [.power(onBattery: false)]))
    model.reconcileTriggers(.init())
    #expect(model.history.active.count == 3)
    model.settings.stopOnUserSwitch = true
    model.handleSystemTransition(.userSwitch)
    #expect(model.history.active.isEmpty)
    #expect(model.history.records.count == 3)
    #expect(model.history.records.allSatisfy { $0.endReason == .userSwitch })
    #expect(model.historyIssue == nil)
  }

  @Test func automationLinksKeepTheirOwnSourceInHistory() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    await model.openURL(try #require(URL(string: "dilated://awake?for=1m")))
    #expect(model.engine.holds.first?.source == .url)
    #expect(model.history.active.first?.source == .url)
    model.stopAll()
    #expect(model.history.records.first?.source == .url)
  }

  @Test func disablingRecordingKeepsPastRecordsAndStartsAFreshSegmentWhenEnabled() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    model.start(duration: 120)
    let first = model.history.active.first?.id
    model.settings.historyEnabled = false
    #expect(model.history.records.count == 1)
    #expect(model.history.records[0].endReason == .recordingDisabled)
    #expect(model.history.active.isEmpty)
    model.settings.historyEnabled = true
    #expect(model.history.active.count == 1)
    #expect(model.history.active[0].id != first)
    model.clearHistory()
    #expect(model.history.records.isEmpty)
    #expect(model.history.active.count == 1)
    model.stopAll()
    #expect(model.history.records.count == 1)
  }

  @Test func aFailedCompletedWriteRetriesWithoutLosingTheEndCause() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    model.start(duration: 60)
    let file = directory.appendingPathComponent("history.jsonl")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    model.stopAll()
    #expect(model.historyIssue != nil)
    try FileManager.default.removeItem(at: file)
    model.refreshPower()
    let loaded = try HistoryStore(directory: directory).load()
    #expect(loaded.records.count == 1)
    #expect(loaded.records.first?.endReason == .stopped)
    #expect(model.historyIssue == nil)
  }

  @Test func intentionalQuitAndUpdateHaveDifferentHistoryReasons() async throws {
    for updating in [false, true] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
      model.start(duration: 60)
      if updating { #expect(await model.prepareToUpdate()) } else { model.shutdown() }
      let loaded = try HistoryStore(directory: directory).load()
      #expect(loaded.records.count == 1)
      #expect(loaded.records.first?.endReason == (updating ? .update : .quit))
      #expect(loaded.active.isEmpty)
    }
  }

  @Test func corruptHistoryIsPreservedUntilExplicitClearAndDoesNotBlockAwakeWork() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("history.jsonl")
    try Data("invalid history\n".utf8).write(to: file)
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    #expect(model.historyIssue != nil)
    model.start(duration: 120)
    #expect(model.engine.holds.count == 1)
    #expect(try String(contentsOf: file, encoding: .utf8) == "invalid history\n")
    model.clearHistory()
    #expect(model.historyIssue == nil)
    #expect(model.history.active.count == 1)
    model.stopAll()
    #expect(try HistoryStore(directory: directory).load().records.count == 1)
  }
}
