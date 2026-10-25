import Foundation
import Testing

@testable import DilatedCore

@MainActor struct AssertionTests {
  @Test func nativeAssertionsFollowAggregateStateAndRelease() throws {
    var engine = WakeEngine()
    let assertions = NativeAssertions()
    defer { assertions.releaseAll() }
    _ = try engine.start(source: .manual, label: "Dilated test", duration: 10)
    try assertions.synchronize(holds: engine.holds)
    #expect(assertions.activeTypes == ["PreventUserIdleSystemSleep"])
    let display = try engine.start(
      source: .manual, label: "Display test", duration: 10, displayAwake: true)
    try assertions.synchronize(holds: engine.holds)
    #expect(assertions.activeTypes.count == 2)
    engine.stop(id: display.id)
    try assertions.synchronize(holds: engine.holds)
    #expect(assertions.activeTypes == ["PreventUserIdleSystemSleep"])
    engine.stopAll()
    try assertions.synchronize(holds: engine.holds)
    #expect(assertions.activeTypes.isEmpty)
  }
}
