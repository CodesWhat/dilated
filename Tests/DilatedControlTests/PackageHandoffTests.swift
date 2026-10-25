import DilatedCore
import Foundation
import Testing

@testable import DilatedControl

struct PackageHandoffTests {
  @Test func handoffRequiresFreshExplicitPreparationForTheSameApp() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PackageHandoffStore(directory: directory)
    let app = URL(fileURLWithPath: "/Applications/Dilated.app")
    let now = Date()
    #expect(throws: (any Error).self) { try store.requirePrepared(app: app, now: now) }
    try store.save(.init(intent: .update, appPath: app.path, preparedAt: now))
    #expect((try? store.requirePrepared(app: app, now: now))?.intent == .update)
    #expect(throws: (any Error).self) {
      try store.requirePrepared(app: app, now: now.addingTimeInterval(601))
    }
    #expect(throws: (any Error).self) {
      try store.requirePrepared(app: app, now: now.addingTimeInterval(-1))
    }
    #expect(throws: (any Error).self) {
      try store.requirePrepared(app: URL(fileURLWithPath: "/Other/Dilated.app"), now: now)
    }
    try store.clear()
    #expect(throws: (any Error).self) { try store.requirePrepared(app: app, now: now) }
  }
}
