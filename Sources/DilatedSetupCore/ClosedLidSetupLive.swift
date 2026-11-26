import DilatedCore
import Foundation

public struct ClosedLidSetupLiveError: Error, LocalizedError, Sendable {
  public var message: String
  public var errorDescription: String? { message }
}

/// Runs one executable with a fixed environment and returns its combined output.
enum SetupProcess {
  struct Result {
    var status: Int32
    var output: String
    var timedOut: Bool
  }

  /// Cancelling the calling task terminates the child, so a cancelled setup doesn't wait out the
  /// timeout. A child that was cancelled before it started never launches.
  static func run(
    _ executable: String, _ arguments: [String], home: String = NSHomeDirectory(),
    timeout: TimeInterval = 10
  ) async -> Result? {
    let handle = ProcessHandle()
    return await withTaskCancellationHandler {
      await launch(executable, arguments, home: home, timeout: timeout, handle: handle)
    } onCancel: {
      handle.cancel()
    }
  }

  private static func launch(
    _ executable: String, _ arguments: [String], home: String, timeout: TimeInterval,
    handle: ProcessHandle
  ) async -> Result? {
    await withCheckedContinuation { (continuation: CheckedContinuation<Result?, Never>) in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        guard handle.launch(process) else {
          continuation.resume(returning: nil)
          return
        }
        let flag = TimeoutFlag()
        let watchdog = DispatchWorkItem {
          flag.set()
          if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        // Foundation's waitUntilExit can spin its run loop after the child is gone; poll instead.
        while process.isRunning { usleep(10_000) }
        watchdog.cancel()
        continuation.resume(
          returning: Result(
            status: process.terminationStatus, output: String(decoding: data, as: UTF8.self),
            timedOut: flag.value))
      }
    }
  }

  private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// Checks for cancellation and starts the child under one lock, so `cancel()` either stops the
    /// launch or finds a started process to terminate. False when nothing was launched.
    func launch(_ process: Process) -> Bool {
      lock.withLock {
        if cancelled { return false }
        do { try process.run() } catch { return false }
        self.process = process
        return true
      }
    }

    func cancel() {
      let target = lock.withLock { () -> Process? in
        cancelled = true
        return process
      }
      if target?.isRunning == true { target?.terminate() }
    }
  }

  private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
  }
}

public struct LiveSetupFileSystem: SetupFileSystem {
  public init() {}

  public func read(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }

  public func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
  }

  public func writeAtomically(
    _ data: Data, to path: String, mode: UInt16, directoryMode: UInt16
  ) throws {
    let manager = FileManager.default
    let url = URL(fileURLWithPath: path)
    try manager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: Int(directoryMode)])
    let temp = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).tmp.\(getpid())")
    try? manager.removeItem(at: temp)
    guard
      manager.createFile(
        atPath: temp.path, contents: data, attributes: [.posixPermissions: Int(mode)])
    else { throw ClosedLidSetupLiveError(message: "Couldn't create \(temp.path).") }
    do {
      // The umask may have stripped bits at creation.
      try manager.setAttributes([.posixPermissions: Int(mode)], ofItemAtPath: temp.path)
      guard rename(temp.path, path) == 0 else {
        throw ClosedLidSetupLiveError(message: String(cString: strerror(errno)))
      }
    } catch {
      try? manager.removeItem(at: temp)
      throw error
    }
  }

  public func remove(_ path: String) throws {
    guard exists(path) else { return }
    try FileManager.default.removeItem(atPath: path)
  }

  public func removeDirectoryIfEmpty(_ path: String) {
    guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path),
      contents.isEmpty
    else { return }
    rmdir(path)
  }
}

public struct LiveLaunchAgentControl: LaunchAgentControlling {
  static let launchctl = "/bin/launchctl"
  public init() {}

  public func bootstrap(domain: String, plistPath: String) async throws {
    // launchd can still be tearing the old job down right after a bootout.
    var last = ""
    for attempt in 0..<5 {
      if attempt > 0 { try? await Task.sleep(for: .milliseconds(300)) }
      guard let result = await SetupProcess.run(Self.launchctl, ["bootstrap", domain, plistPath])
      else { throw ClosedLidSetupLiveError(message: "launchctl couldn't start.") }
      if result.status == 0 { return }
      last = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    throw ClosedLidSetupLiveError(message: last.isEmpty ? "launchctl bootstrap failed." : last)
  }

  public func bootout(target: String) async {
    // Committed cleanup: removal deletes the plist next, so a cancelled task must not skip this.
    _ = await Task.detached { await SetupProcess.run(Self.launchctl, ["bootout", target]) }.value
  }

  public func isLoaded(target: String) async -> Bool {
    await SetupProcess.run(Self.launchctl, ["print", target])?.status == 0
  }
}

public struct LivePowerScript: PowerScriptRunning {
  public init() {}

  public func beginRemoval(scriptPath: String) async throws -> Bool {
    // The script may wait out a legacy `on` that is queued on its lock (about 5s) before it restores.
    guard
      let result = await SetupProcess.run(
        "/bin/bash", [scriptPath, "begin-removal"], timeout: 30)
    else {
      throw ClosedLidSetupLiveError(message: "The script couldn't start.")
    }
    let word = result.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    guard !result.timedOut, result.status == 0, word == "ok" || word == "none" else {
      throw ClosedLidSetupLiveError(message: "dilated-power begin-removal printed '\(word)'.")
    }
    return word == "ok"
  }

  public func finishRemoval(scriptPath: String) async throws {
    guard let result = await SetupProcess.run("/bin/bash", [scriptPath, "finish-removal"]) else {
      throw ClosedLidSetupLiveError(message: "The script couldn't start.")
    }
    let word = result.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    guard !result.timedOut, result.status == 0, word == "ok" else {
      throw ClosedLidSetupLiveError(message: "dilated-power finish-removal printed '\(word)'.")
    }
  }

  public func confirmsNormalSleep() async -> Bool {
    NativeClosedLidPower.readback().confirmedDisabled
  }
}

extension ClosedLidSetup {
  /// The real thing. `allowAdminPrompt: false` makes the rule step fail instead of asking, for
  /// headless runs.
  public static func live(allowAdminPrompt: Bool = true) -> ClosedLidSetup {
    let paths = ClosedLidSetupPaths.current()
    return ClosedLidSetup(
      paths: paths, assets: .bundled(), files: LiveSetupFileSystem(),
      launchd: LiveLaunchAgentControl(), power: LivePowerScript(),
      rule: ClosedLidPermission(
        seams: .live(lockFile: URL(fileURLWithPath: paths.sessionLockFile)),
        runner: allowAdminPrompt ? OsascriptAdminRunner() : RefusingAdminRunner()))
  }
}

/// Stands in for the administrator prompt when the caller has said not to show one.
struct RefusingAdminRunner: PrivilegedScriptRunning {
  func run(script: String) async -> PrivilegedScriptOutcome {
    .failed("This needs an administrator prompt, which was turned off.")
  }
}
