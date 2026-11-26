import DilatedCore
import Foundation
import Testing

@testable import DilatedControl

struct ReleaseSignalTests {
  private func runner(_ engine: inout WakeEngine) throws -> UUID {
    let started = ControlRouter.handle(
      ControlRequest(action: .runner, label: "build", duration: 30), engine: &engine)
    return try #require(started.id)
  }

  @Test func renewingAReleasedHoldIsMarkedReleased() throws {
    var engine = WakeEngine()
    let id = try runner(&engine)
    _ = ControlRouter.handle(ControlRequest(action: .release, id: id), engine: &engine)
    let renewed = ControlRouter.handle(
      ControlRequest(action: .renew, id: id, duration: 30), engine: &engine)
    #expect(!renewed.ok)
    #expect(renewed.code == WakeError.holdNotFound.rawValue)
    #expect(renewed.released == true)
  }

  @Test func renewingAnExpiredOrUnknownHoldIsNotMarkedReleased() throws {
    var engine = WakeEngine()
    let id = try runner(&engine)
    let later = Date().addingTimeInterval(600)
    let expired = ControlRouter.handle(
      ControlRequest(action: .renew, id: id, duration: 30), engine: &engine, now: later)
    #expect(!expired.ok)
    #expect(expired.released == nil)
    let unknown = ControlRouter.handle(
      ControlRequest(action: .renew, id: UUID(), duration: 30), engine: &engine)
    #expect(unknown.released == nil)
  }

  @Test func anOlderAppResponseWithoutTheFieldDecodesAsNotReleased() throws {
    let json = #"{"ok":false,"code":"holdNotFound"}"#
    let response = try JSONDecoder().decode(ControlResponse.self, from: Data(json.utf8))
    #expect(response.released == nil)
  }
}
