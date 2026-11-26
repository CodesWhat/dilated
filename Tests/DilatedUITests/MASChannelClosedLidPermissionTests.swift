#if MAS_CHANNEL
  import DilatedCore
  import Foundation
  import Testing

  @testable import DilatedUI

  private struct StubLauncher: UserScriptLaunching {
    let result: UserScriptRun
    func run(arguments: [String]) async -> UserScriptRun { result }
  }

  private final class RecordingRunner: PowerCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PowerCommand] = []
    let error: (any Error)?
    init(error: (any Error)? = nil) { self.error = error }
    var commands: [PowerCommand] { lock.withLock { recorded } }
    func run(_ command: PowerCommand) async throws {
      lock.withLock { recorded.append(command) }
      if let error { throw error }
    }
  }

  private struct RestoreFailure: LocalizedError {
    var errorDescription: String? { "the script said no" }
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
        (
          .finished(output: "noagent\n", failureStatus: 3), .agentMissing,
          "The closed-lid repair agent isn't running. Run Dilated Closed-Lid Setup again."
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

    @Test func restoreRunsTheScriptOffVerbAndNeedsTheAcknowledgement() async {
      let runner = RecordingRunner()
      let model = ClosedLidPermissionModel(
        scriptPermission: ClosedLidScriptPermission(
          launcher: StubLauncher(result: .finished(output: "ok\n", failureStatus: nil))),
        acknowledgeRestore: { true }, masRestoreRunner: runner)
      #expect(await model.restoreNormalSleep() == .done)
      #expect(runner.commands == [.setSleepDisabled(false)])
      #expect(model.lastError == nil)
    }

    @Test func restoreWithoutAcknowledgementFailsAndKeepsTheRetryMessage() async {
      let runner = RecordingRunner()
      let model = ClosedLidPermissionModel(
        scriptPermission: ClosedLidScriptPermission(
          launcher: StubLauncher(result: .finished(output: "ok\n", failureStatus: nil))),
        acknowledgeRestore: { false }, masRestoreRunner: runner)
      #expect(await model.restoreNormalSleep() == .failed)
      #expect(model.lastError == "macOS hasn't confirmed normal sleep yet. Try again.")
    }

    @Test func aRestoreTheScriptRefusesSurfacesItsReasonAndSkipsTheAcknowledgement() async {
      var acknowledged = false
      let model = ClosedLidPermissionModel(
        acknowledgeRestore: {
          acknowledged = true
          return true
        }, masRestoreRunner: RecordingRunner(error: RestoreFailure()))
      #expect(await model.restoreNormalSleep() == .failed)
      #expect(model.lastError == "the script said no")
      #expect(!acknowledged)
    }
  }
#endif
