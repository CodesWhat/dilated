import DilatedCore
import Foundation
import Testing

@testable import DilatedControl

struct ControlTests {
  @Test func minimalWireRequestsUseSafeDefaults() throws {
    let request = try WireJSON.decode(ControlRequest.self, from: Data(#"{"action":"status"}"#.utf8))
    #expect(request.action == .status)
    #expect(!request.displayAwake)
    #expect(!request.lowPowerOverride)
    #expect(!request.closedLid)
  }
  @Test func cliParsesFiniteWorkAndPreservesCommandArguments() throws {
    let start = try CLIInput.parse(["on", "--for", "90m", "--display-awake", "--label", "Build"])
    #expect(start.request?.duration == 5400)
    #expect(start.request?.displayAwake == true)
    #expect(start.request?.label == "Build")
    let run = try CLIInput.parse([
      "run", "--label", "Test", "--", "/bin/echo", "--for", "hello world",
    ])
    #expect(run.command == ["/bin/echo", "--for", "hello world"])
    for bad in [
      ["on", "--for", "1h", "--until", "17:00"], ["on", "--wat"], ["hold"], ["run"], ["release"],
    ] {
      #expect(throws: (any Error).self) { try CLIInput.parse(bad) }
    }
  }
  @Test func urlAllowsCombinedParametersButRejectsAmbiguity() throws {
    let request = try URLInput.parse(URL(string: "dilated://awake?for=90m&display=allow")!)
    #expect(request.duration == 5400)
    #expect(!request.displayAwake)
    #expect(try URLInput.parse(URL(string: "dilated://stop")!).action == .stopAll)
    for url in [
      "dilated://awake?for=1h&for=2h", "dilated://awake?lid=bad", "dilated://awake?wat=1",
      "other://awake",
    ] {
      #expect(throws: (any Error).self) { try URLInput.parse(URL(string: url)!) }
    }
  }
  @Test func closedLidInputRequiresAnExplicitStartAndTheAppHelper() throws {
    for arguments in [
      ["on", "--lid"], ["hold", "--ttl", "10m", "--lid"], ["run", "--lid", "--", "make"],
    ] {
      #expect(try CLIInput.parse(arguments).request?.closedLid == true)
    }
    #expect(try URLInput.parse(URL(string: "dilated://awake?lid=closed")!).closedLid)
    #expect(throws: (any Error).self) {
      try CLIInput.parse(["hold", "--id", UUID().uuidString, "--ttl", "10m", "--lid"])
    }
    var engine = WakeEngine()
    let direct = ControlRouter.handle(.init(action: .start, closedLid: true), engine: &engine)
    #expect(!direct.ok)
    #expect(engine.holds.isEmpty)
  }
  @Test func routerUsesOneEngineAndCannotBypassPause() throws {
    var engine = WakeEngine()
    let first = ControlRouter.handle(
      ControlRequest(action: .lease, label: "Agent", duration: 60), engine: &engine)
    #expect(first.ok)
    let id = try #require(first.id)
    #expect(
      ControlRouter.handle(ControlRequest(action: .renew, id: id, duration: 60), engine: &engine).ok
    )
    #expect(ControlRouter.handle(ControlRequest(action: .stopAll), engine: &engine).ok)
    for action in [ControlAction.start, .lease, .runner] {
      let blocked = ControlRouter.handle(
        ControlRequest(action: action, duration: 60), engine: &engine)
      #expect(!blocked.ok)
      #expect(blocked.code == "automationPaused")
    }
    #expect(
      !ControlRouter.handle(ControlRequest(action: .renew, id: id, duration: 60), engine: &engine)
        .ok)
    #expect(engine.holds.isEmpty)
    engine.resumeAutomation()
    let next = ControlRouter.handle(ControlRequest(action: .lease, duration: 60), engine: &engine)
    #expect(next.ok)
    #expect(next.id != id)
  }
}
