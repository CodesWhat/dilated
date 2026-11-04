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

  static func run(
    _ executable: String, _ arguments: [String], home: String = NSHomeDirectory(),
    timeout: TimeInterval = 10
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
        do { try process.run() } catch {
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
        process.waitUntilExit()
        watchdog.cancel()
        continuation.resume(
          returning: Result(
            status: process.terminationStatus, output: String(decoding: data, as: UTF8.self),
            timedOut: flag.value))
      }
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
    _ = await SetupProcess.run(Self.launchctl, ["bootout", target])
  }

  public func isLoaded(target: String) async -> Bool {
    await SetupProcess.run(Self.launchctl, ["print", target])?.status == 0
  }
}

public struct LivePowerScript: PowerScriptRunning {
  public init() {}

  public func off(scriptPath: String) async throws {
    guard let result = await SetupProcess.run("/bin/bash", [scriptPath, "off"]) else {
      throw ClosedLidSetupLiveError(message: "The script couldn't start.")
    }
    let word = result.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    guard !result.timedOut, result.status == 0, word == "ok" else {
      throw ClosedLidSetupLiveError(message: "dilated-power off printed '\(word)'.")
    }
  }
}

extension ClosedLidSetup {
  /// The real thing. `allowAdminPrompt: false` makes the rule step fail instead of asking, for
  /// headless runs.
  public static func live(allowAdminPrompt: Bool = true) -> ClosedLidSetup {
    ClosedLidSetup(
      paths: .current(), assets: .bundled(), files: LiveSetupFileSystem(),
      launchd: LiveLaunchAgentControl(), power: LivePowerScript(),
      rule: ClosedLidPermission(
        runner: allowAdminPrompt ? OsascriptAdminRunner() : RefusingAdminRunner()))
  }
}

/// Stands in for the administrator prompt when the caller has said not to show one.
struct RefusingAdminRunner: PrivilegedScriptRunning {
  func run(script: String) async -> PrivilegedScriptOutcome {
    .failed("This needs an administrator prompt, which was turned off.")
  }
}
