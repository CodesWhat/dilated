#if MAS_CHANNEL
  import DilatedCore
  import Foundation
  import Testing

  @testable import DilatedUI

  private struct StubLauncher: UserScriptLaunching {
    let result: UserScriptRun
    func run(arguments: [String]) async -> UserScriptRun { result }
  }

  @MainActor struct MASChannelClosedLidPermissionTests {
    private func model(_ result: UserScriptRun) -> ClosedLidPermissionModel {
      ClosedLidPermissionModel(
        scriptPermission: ClosedLidScriptPermission(launcher: StubLauncher(result: result)))
    }

    @Test func eachScriptStateShowsItsCopyAndNoSetupButtons() async {
      let cases: [(UserScriptRun, ClosedLidScriptState, String?)] = [
        (
          .missing, .scriptMissing,
          "Closed-lid mode needs the Dilated Closed-Lid Setup companion."
        ),
        (
          .finished(output: "norule\n", failureStatus: 3), .ruleMissing,
          "Closed-lid permission isn't set up. Run Dilated Closed-Lid Setup again."
        ),
        (.finished(output: "ok\n", failureStatus: nil), .ready, nil),
      ]
      for (run, expected, copy) in cases {
        let model = model(run)
        await model.refresh()
        #expect(model.scriptState == expected)
        #expect(model.setUpTitle == nil)
        #expect(!model.canRemove)
        if let copy {
          #expect(model.detail == copy)
          #expect(model.summary == copy)
        } else {
          #expect(model.state == .ready)
        }
      }
    }

    @Test func theAppNeverInstallsOrRemovesTheRule() async {
      let model = model(.missing)
      #expect(await model.install() == .failed)
      #expect(await model.remove() == .failed)
      #expect(model.lastError != nil)
    }
  }
#endif
