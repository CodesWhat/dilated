import AppKit
import Darwin
import DilatedControl
import DilatedCore
import Foundation

@main struct DilatedCommand {
  @MainActor static func main() async {
    do {
      let input = try CLIInput.parse(Array(CommandLine.arguments.dropFirst()))
      if input.help {
        print(help)
        return
      }
      if !input.command.isEmpty { exit(try await run(input)) }
      guard let request = input.request else { throw InputError("Missing command.") }
      let endpoint = SocketEndpoint.current
      let response: ControlResponse
      do { response = try LocalSocketClient.send(request, to: endpoint) } catch {
        guard request.action != .status else { throw error }
        try await launchApp(endpoint: endpoint)
        response = try LocalSocketClient.send(request, to: endpoint)
      }
      if input.json {
        print(String(decoding: try WireJSON.encode(response), as: UTF8.self))
      } else if response.ok {
        if let id = response.id {
          print(id.uuidString)
        } else if let snapshot = response.snapshot {
          if snapshot.holds.isEmpty {
            print(
              snapshot.automationPaused
                ? "Sleeping normally. Automation paused." : "Sleeping normally.")
          } else {
            for hold in snapshot.holds {
              print(
                "\(hold.id.uuidString)  \(hold.label)  \(hold.expiry.map { "until " + $0.formatted() } ?? "indefinitely")"
              )
            }
          }
        }
      }
      guard response.ok else {
        if !input.json { writeError(response.message ?? "Dilated rejected the request.") }
        exit(response.code == "automationPaused" ? 4 : 1)
      }
    } catch {
      writeError(error.localizedDescription)
      exit(1)
    }
  }

  @MainActor private static func launchApp(endpoint: SocketEndpoint) async throws {
    let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
      .resolvingSymlinksInPath()
    let bundled = executable.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let configured = ProcessInfo.processInfo.environment["DILATED_APP_PATH"].map {
      URL(fileURLWithPath: $0)
    }
    let appURL =
      configured
      ?? (bundled.pathExtension == "app"
        ? bundled
        : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.codeswhat.dilated"))
    guard let appURL else { throw InputError("Start Dilated before using this command.") }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    if let directory = ProcessInfo.processInfo.environment["DILATED_STATE_DIR"] {
      configuration.environment = ["DILATED_STATE_DIR": directory]
    }
    _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    for _ in 0..<30 {
      if (try? LocalSocketClient.send(ControlRequest(action: .status), to: endpoint)) != nil {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw InputError("Dilated launched but its control connection isn't ready.")
  }

  @MainActor private static func run(_ input: CLIInput) async throws -> Int32 {
    let endpoint = SocketEndpoint.current
    let store = StateStore(directory: endpoint.stateDirectory)
    let options = input.request!
    var floor: Int?
    var lowPowerOverride = options.lowPowerOverride
    let settingsFile = endpoint.stateDirectory.appendingPathComponent("settings.json")
    if FileManager.default.fileExists(atPath: settingsFile.path),
      let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsFile))
        as? [String: Any]
    {
      if let configuredFloor = settings["batteryFloor"] as? Int, configuredFloor > 0 {
        floor = min(100, max(10, configuredFloor))
      }
      lowPowerOverride = lowPowerOverride || settings["overrideLowPower"] as? Bool == true
    }
    var local = WakeEngine(power: SystemPower.read(), batteryFloor: floor)
    let hold = try local.start(
      source: .runner, label: options.label, duration: 30,
      displayAwake: options.displayAwake, lowPowerOverride: lowPowerOverride)
    let assertions = NativeAssertions()
    defer { assertions.releaseAll() }
    var managedID: UUID?
    var keepingAwake = true
    if let response = try? LocalSocketClient.send(
      ControlRequest(
        action: .runner, label: options.label, duration: 30,
        displayAwake: options.displayAwake, lowPowerOverride: lowPowerOverride), to: endpoint)
    {
      guard response.ok else {
        throw InputError(response.message ?? "Couldn't keep awake for this command.")
      }
      managedID = response.id
    } else if try store.load().automationPaused {
      throw WakeError.automationPaused
    }
    try assertions.synchronize(holds: local.holds)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = input.command
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    defer {
      if let managedID {
        _ = try? LocalSocketClient.send(
          ControlRequest(action: .release, id: managedID), to: endpoint)
      }
    }
    try process.run()
    let signalSources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
      Darwin.signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler { if process.isRunning { kill(process.processIdentifier, number) } }
      source.resume()
      return source
    }
    defer { for source in signalSources { source.cancel() } }
    while process.isRunning {
      try await Task.sleep(for: .seconds(1))
      guard keepingAwake else { continue }
      local.updatePower(SystemPower.read())
      if local.holds.isEmpty {
        assertions.releaseAll()
        keepingAwake = false
        continue
      }
      do {
        let response: ControlResponse
        if let id = managedID {
          response = try LocalSocketClient.send(
            ControlRequest(action: .renew, id: id, duration: 30), to: endpoint)
        } else {
          response = try LocalSocketClient.send(
            ControlRequest(
              action: .runner, label: options.label, duration: 30,
              displayAwake: options.displayAwake, lowPowerOverride: lowPowerOverride), to: endpoint)
          if response.ok { managedID = response.id }
        }
        if !response.ok {
          assertions.releaseAll()
          keepingAwake = false
          writeError(
            "Keep-awake ended: \(response.message ?? "hold ended"). The command is still running.")
          continue
        }
      } catch {
        let snapshot = try store.load()
        if snapshot.automationPaused
          || managedID.map({ id in !snapshot.holds.contains { $0.id == id } }) == true
        {
          assertions.releaseAll()
          keepingAwake = false
          continue
        }
      }
      try local.renew(id: hold.id, duration: 30)
      try assertions.synchronize(holds: local.holds)
    }
    process.waitUntilExit()
    return process.terminationReason == .uncaughtSignal
      ? 128 + process.terminationStatus : process.terminationStatus
  }

  private static func writeError(_ text: String) {
    FileHandle.standardError.write(Data(("dilated: " + text + "\n").utf8))
  }
  private static let help = """
    Usage: dilated status [--json]
           dilated on [--for 2h | --until 17:00] [--label NAME] [--display-awake]
           dilated off [--id ID | --label NAME]
           dilated hold --ttl 10m [--label NAME] [--id ID]
           dilated release --id ID
           dilated run [--label NAME] -- command arguments

    Starts allow display sleep unless --display-awake is supplied.
    --override-low-power explicitly allows a new hold in Low Power Mode.
    A new hold prints its unique ID. Pass it to hold --id to renew, or release.
    Stop pauses CLI/URL starts and renewals until Resume automation in the app.
    run works without the app. Ending its awake hold never terminates the command.
    """
}
