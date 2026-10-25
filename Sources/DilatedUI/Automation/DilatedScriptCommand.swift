import AppKit
import Carbon
import DilatedControl

// Cocoa needs a converter before it can deliver arbitrary record fields to the command.
@objc(DilatedScriptOptionsRecord) final class DilatedScriptOptionsRecord: NSObject {
  @objc let descriptor: NSAppleEventDescriptor
  private init(descriptor: NSAppleEventDescriptor) { self.descriptor = descriptor }
  @objc(scriptingSessionOptionsWithDescriptor:)
  class func scriptingSessionOptions(with descriptor: NSAppleEventDescriptor)
    -> DilatedScriptOptionsRecord
  {
    DilatedScriptOptionsRecord(descriptor: descriptor)
  }
}

@MainActor @objc(DilatedScriptCommand) public final class DilatedScriptCommand: NSScriptCommand {
  public nonisolated override func performDefaultImplementation() -> Any? {
    guard Thread.isMainThread else {
      scriptErrorNumber = -1708
      scriptErrorString = "Dilated scripting commands must be delivered on the application thread."
      return nil
    }
    let receiver = MainThreadScriptReceiver(command: self)
    MainActor.assumeIsolated { receiver.command.beginReply() }
    return nil
  }
  private func beginReply() {
    do {
      guard commandDescription.appleEventClassCode == 0x616d_7068,
        let operation = ScriptOperation.allCases.first(where: {
          $0.eventID == commandDescription.appleEventCode
        })
      else { throw InputError("Unsupported Dilated scripting command.") }
      let options =
        operation == .start
        ? try ScriptStartOptions.parse(appleEvent?.paramDescriptor(forKeyword: 0x6f70_746e)) : nil
      let reply = PendingScriptReply(command: self)
      suspendExecution()
      Task { await reply.perform(operation, options: options) }
    } catch {
      scriptErrorNumber = -1700
      scriptErrorString = error.localizedDescription
    }
  }
}

// Only crosses the synchronous actor assertion after the app-thread check above.
private struct MainThreadScriptReceiver: @unchecked Sendable {
  let command: DilatedScriptCommand
}

@MainActor private final class PendingScriptReply {
  private let command: NSScriptCommand
  init(command: NSScriptCommand) { self.command = command }
  func perform(_ operation: ScriptOperation, options: ScriptStartOptions?) async {
    do {
      let value = try await AutomationService.shared.script(operation, options: options)
      let result: Any?
      switch value {
      case .none: result = nil
      case .boolean(let value): result = NSNumber(value: value)
      case .integer(let value): result = NSNumber(value: value)
      }
      command.resumeExecution(withResult: result)
    } catch {
      command.scriptErrorNumber = -10000
      command.scriptErrorString = error.localizedDescription
      command.resumeExecution(withResult: nil)
    }
  }
}
