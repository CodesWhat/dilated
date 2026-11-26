import DilatedControl
import Testing

struct LeavingCommandTests {
  @Test func parsesArmCancelAndJSONWithoutAcceptingStartOptions() throws {
    let arm = try CLIInput.parse(["leaving", "--json"])
    #expect(arm.request?.action == .leaving && arm.json)
    let cancel = try CLIInput.parse(["leaving", "--cancel", "--json"])
    #expect(cancel.request?.action == .cancelLeaving && cancel.json)
    for arguments in [
      ["leaving", "--cancel", "--cancel"], ["leaving", "--json", "--json"],
      ["leaving", "--for", "10m"], ["leaving", "--lid"], ["leaving", "now"],
    ] {
      #expect(throws: InputError.self) { try CLIInput.parse(arguments) }
    }
  }
}
