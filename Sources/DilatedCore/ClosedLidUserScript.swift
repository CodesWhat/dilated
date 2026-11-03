import Foundation

/// What running the user-installed `dilated-power` script came to.
public enum UserScriptRun: Equatable, Sendable {
  /// No script in the Application Scripts folder, or it couldn't be loaded.
  case missing
  /// The script ran to the end. `failureStatus` is nil on a clean exit, else the status the
  /// failure carried (1 when it carried none).
  case finished(output: String, failureStatus: Int32?)
  case timedOut
}

public protocol UserScriptLaunching: Sendable {
  func run(arguments: [String]) async -> UserScriptRun
}

extension UserScriptRun {
  /// The first whitespace-separated word of stdout. The exit status isn't reliable here:
  /// `NSUserUnixTask` only reports an `Error`, so the script's one-word contract carries the answer.
  var firstWord: String? {
    guard case .finished(let output, _) = self else { return nil }
    return output.split(whereSeparator: \.isWhitespace).first.map(String.init)
  }
}

/// Runs the script that Dilated Closed-Lid Setup installs in
/// `~/Library/Application Scripts/<bundle id>/`. The sandboxed app can't spawn sudo; the script
/// runs unsandboxed as the user and the sudoers rule does the elevation.
///
/// Compiled for both channels so it type-checks in the direct build. Only the Mac App Store
/// build uses it.
public struct LiveUserScriptLauncher: UserScriptLaunching {
  public static let scriptName = "dilated-power"
  static let timeout: Duration = .seconds(3)

  public init() {}

  public func run(arguments: [String]) async -> UserScriptRun {
    guard
      let directory = try? FileManager.default.url(
        for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil,
        create: false)
    else { return .missing }
    let url = directory.appendingPathComponent(Self.scriptName)
    guard let task = try? NSUserUnixTask(url: url) else { return .missing }

    let output = Pipe()
    let errors = Pipe()
    task.standardOutput = output.fileHandleForWriting
    task.standardError = errors.fileHandleForWriting
    let box = TaskBox(task)

    return await withCheckedContinuation {
      (continuation: CheckedContinuation<UserScriptRun, Never>) in
      let gate = ResumeOnce(continuation)
      // An NSUserUnixTask can't be killed. On timeout the script is left to finish on its own
      // and its result is dropped.
      DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(3)) {
        gate.resume(.timedOut)
      }
      box.task.execute(withArguments: arguments) { error in
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
        let status: Int32? = error.map { error in
          let nsError = error as NSError
          return nsError.domain == NSPOSIXErrorDomain && nsError.code != 0
            ? Int32(truncatingIfNeeded: nsError.code) : 1
        }
        gate.resume(.finished(output: String(decoding: data, as: UTF8.self), failureStatus: status))
      }
    }
  }

  private final class TaskBox: @unchecked Sendable {
    let task: NSUserUnixTask
    init(_ task: NSUserUnixTask) { self.task = task }
  }

  private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UserScriptRun, Never>?

    init(_ continuation: CheckedContinuation<UserScriptRun, Never>) {
      self.continuation = continuation
    }

    func resume(_ value: UserScriptRun) {
      let held = lock.withLock {
        let held = continuation
        continuation = nil
        return held
      }
      held?.resume(returning: value)
    }
  }
}

/// Runs `pmset` through the user-installed script. The sandboxed Mac App Store build's
/// counterpart to `SudoPowerRunner`.
public struct UserScriptPowerRunner: PowerCommandRunning {
  private let launcher: any UserScriptLaunching

  public init(launcher: any UserScriptLaunching = LiveUserScriptLauncher()) {
    self.launcher = launcher
  }

  public func run(_ command: PowerCommand) async throws {
    switch command {
    case .setSleepDisabled(let disabled):
      let result = await launcher.run(arguments: [disabled ? "on" : "off"])
      switch result {
      case .missing: throw ClosedLidPowerError.permissionUnavailable
      case .timedOut: throw ClosedLidPowerError.commandTimedOut
      case .finished(_, let failureStatus):
        switch (result.firstWord, failureStatus) {
        case ("ok", nil): return
        case ("norule", _): throw ClosedLidPowerError.permissionUnavailable
        default: throw ClosedLidPowerError.commandFailed(failureStatus ?? 1)
        }
      }
    case .sleep:
      try NativePowerRunner.requestSystemSleep()
    }
  }
}

public enum ClosedLidScriptState: Equatable, Sendable {
  case scriptMissing, ruleMissing, ready
}

/// What the `probe` verb says about the user-installed script and the sudoers rule behind it.
public struct ClosedLidScriptPermission: Sendable {
  private let launcher: any UserScriptLaunching

  public init(launcher: any UserScriptLaunching = LiveUserScriptLauncher()) {
    self.launcher = launcher
  }

  public func state() async -> ClosedLidScriptState {
    let result = await launcher.run(arguments: ["probe"])
    switch result {
    case .missing: return .scriptMissing
    // A timeout or a failure can't tell a missing rule from a broken sudo, and either way
    // closed-lid can't run, so both ask the user to run the setup companion again.
    case .timedOut: return .ruleMissing
    case .finished(_, let failureStatus):
      return result.firstWord == "ok" && failureStatus == nil ? .ready : .ruleMissing
    }
  }
}
