import Foundation
import Testing

@testable import DilatedControl

struct AssertionInspectorCLITests {
  @Test func statusAcceptsAssertionsFlag() throws {
    let input = try CLIInput.parse(["status", "--assertions", "--json"])
    #expect(input.assertions && input.json)
    #expect(input.request?.action == .status)
    #expect(try CLIInput.parse(["status"]).assertions == false)
  }

  @Test func assertionsFlagIsStatusOnly() {
    #expect(throws: (any Error).self) { try CLIInput.parse(["off", "--assertions"]) }
    #expect(throws: (any Error).self) {
      try CLIInput.parse(["status", "--assertions", "--assertions"])
    }
  }

  @Test func statusReplyCarriesAppPIDAndStaysBackwardCompatible() throws {
    let reply = ControlResponse(ok: true, appPID: 42)
    let decoded = try WireJSON.decode(ControlResponse.self, from: try WireJSON.encode(reply))
    #expect(decoded.appPID == 42)
    #expect(
      try WireJSON.decode(ControlResponse.self, from: Data(#"{"ok":true}"#.utf8)).appPID == nil)
  }
}
