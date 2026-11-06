import AppKit
import Darwin
import DilatedControl
import DilatedCore
import Foundation

@main struct DilatedCommand {
  @MainActor static func main() async {
    if let launch = ClosedLidWatchdogCommand.parse(Array(CommandLine.arguments.dropFirst())) {
      exit(await ClosedLidWatchdogCommand.run(launch))
    }
    if AgentRenewerCommand.matches(Array(CommandLine.arguments.dropFirst())) {
      exit(await AgentRenewerCommand.run(Array(CommandLine.arguments.dropFirst())))
    }
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.count >= 2, arguments[0] == "agent",
      let tool = AgentHookTool.allCases.first(where: { $0.commandName == arguments[1] })
    {
      // Hook failures must never block an agent or add text to its context.
      do {
        guard arguments.count == 4, arguments[2] == "--pid" else { return }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let pid = Int32(arguments[3]) else { return }
        let command = try AgentHookInput.command(data: data, pid: pid, tool: tool)
        if command.verb != .end { _ = try AgentCommand.validate(pid: arguments[3]) }
        _ = try await runAgent(command)
      } catch {}
      return
    }
    do {
      let input = try CLIInput.parse(Array(CommandLine.arguments.dropFirst()))
      if input.help {
        print(help)
        return
      }
      if input.packageCheck {
        let executable =
          (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
          .resolvingSymlinksInPath()
        let app = executable.deletingLastPathComponent().deletingLastPathComponent()
          .deletingLastPathComponent()
        guard app.pathExtension == "app" else {
          throw InputError("Use the command line tool inside the installed Dilated app.")
        }
        guard
          NSRunningApplication.runningApplications(withBundleIdentifier: "com.codeswhat.dilated")
            .isEmpty
        else {
          throw InputError(
            "Dilated is still running. Use prepare-update or prepare-uninstall first.")
        }
        try await PackageHelperCheck.verifyAbsent(
          appExecutable: app.appendingPathComponent("Contents/MacOS/DilatedApp"))
        _ = try PackageHandoffStore(directory: SocketEndpoint.current.stateDirectory)
          .requirePrepared(app: app)
        guard NativeClosedLidPower.readback().confirmedDisabled else {
          throw InputError(
            "macOS hasn't confirmed sleep-disable is off. Run dilated lid-permission status, then restore normal sleep from Dilated's Settings."
          )
        }
        print("Package preparation verified.")
        return
      }
      if let agent = input.agent { exit(try await runAgent(agent)) }
      if !input.command.isEmpty { exit(try await run(input)) }
      guard let request = input.request else { throw InputError("Missing command.") }
      let endpoint = SocketEndpoint.current
      if input.assertions {
        // Read-only: works without the app, in which case nothing is tagged as ours.
        let appPID = (try? LocalSocketClient.send(request, to: endpoint))?.appPID
        let report = AssertionInspector.report(appPID: appPID)
        if input.json {
          print(String(decoding: try report.jsonData(), as: UTF8.self))
        } else {
          print(report.text)
        }
        return
      }
      let response: ControlResponse
      do {
        response = try LocalSocketClient.send(request, to: endpoint)
      } catch let error as AppConnectionUnavailable {
        guard ![.status, .helperStatus, .lidPermissionStatus].contains(request.action) else {
          throw error
        }
        try await launchApp(endpoint: endpoint)
        response = try LocalSocketClient.send(request, to: endpoint)
      }
      if response.ok, request.action == .prepareUpdate || request.action == .prepareUninstall {
        try await finishPackagePreparation(pid: response.appPID)
      }
      if input.json {
        print(String(decoding: try WireJSON.encode(response), as: UTF8.self))
      } else if response.ok {
        if [.leaving, .cancelLeaving].contains(request.action) {
          print(
            request.action == .leaving ? "Sleep when idle is armed." : "Sleep when idle cancelled.")
        } else if request.action == .lidPermissionStatus, let word = response.lidPermission {
          print(word)
        } else if [.lidPermissionInstall, .lidPermissionRemove].contains(request.action) {
          print(response.message ?? "Closed-lid permission updated.")
        } else if [.helperStatus, .helperSetup, .helperRemove, .prepareUpdate, .prepareUninstall]
          .contains(
            request.action)
        {
          print(response.message ?? "Done.")
        } else if let id = response.id {
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
          if response.helper?.enabled == true { print("Closed-lid armed.") }
          if response.leavingPending == true { print("Sleep when idle is armed.") }
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

  @MainActor private static func finishPackagePreparation(pid: Int32?) async throws {
    guard let pid else {
      throw InputError("Dilated didn't identify the prepared app. Update both app and CLI.")
    }
    guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
    guard app.bundleIdentifier == "com.codeswhat.dilated" else {
      throw InputError("The prepared app process changed. Package preparation must be repeated.")
    }
    guard app.terminate() else {
      throw InputError("Dilated prepared its state but couldn't quit. Quit it before continuing.")
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !app.isTerminated, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    guard app.isTerminated else {
      throw InputError("Dilated hasn't finished quitting. The package operation must wait.")
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

  @MainActor private static func runAgent(_ command: AgentCommand) async throws -> Int32 {
    let endpoint = SocketEndpoint.current
    var launched = false
    let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
      .resolvingSymlinksInPath()
    let spawnRenewer: @Sendable (AgentCommand, Int32) throws -> Int32 = { command, pid in
      try AgentRenewerSpawner.spawn(
        executable: executable, agent: command.agent, run: command.run, pid: pid)
    }
    let lifecycle = AgentLifecycle(
      stateDirectory: endpoint.stateDirectory, spawnRenewer: spawnRenewer
    ) { request in
      do {
        return try LocalSocketClient.send(request, to: endpoint)
      } catch let error as AppConnectionUnavailable {
        // begin and renew launch the app like hold does; end never wakes a closed app.
        guard command.verb != .end, !launched,
          !command.decidedByHook || command.verb == .begin
        else { throw error }
        launched = true
        try await launchApp(endpoint: endpoint)
        return try LocalSocketClient.send(request, to: endpoint)
      }
    }
    let response = try await lifecycle.run(command)
    if command.decidedByHook { return 0 }
    if command.json {
      print(String(decoding: try WireJSON.encode(response), as: UTF8.self))
    } else if response.ok {
      print(response.id?.uuidString ?? response.message ?? "Done.")
    } else {
      writeError(response.message ?? "Dilated rejected the request.")
    }
    return response.ok ? 0 : response.code == "automationPaused" ? 4 : 1
  }

  @MainActor private static func run(_ input: CLIInput) async throws -> Int32 {
    let endpoint = SocketEndpoint.current
    let store = StateStore(directory: endpoint.stateDirectory)
    let options = input.request!
    if options.closedLid {
      do {
        _ = try LocalSocketClient.send(ControlRequest(action: .status), to: endpoint)
      } catch is AppConnectionUnavailable {
        try await launchApp(endpoint: endpoint)
      }
    }
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
        displayAwake: options.displayAwake, lowPowerOverride: lowPowerOverride,
        closedLid: options.closedLid), to: endpoint)
    {
      guard response.ok else {
        throw InputError(response.message ?? "Couldn't keep awake for this command.")
      }
      managedID = response.id
    } else {
      if options.closedLid {
        throw InputError("Closed-lid run requires the app and closed-lid permission.")
      }
      if try store.load().automationPaused { throw WakeError.automationPaused }
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
    Usage: dilated status [--json] [--assertions]
           dilated leaving [--cancel] [--json]
           dilated on [--for 2h | --until 17:00] [--label NAME] [--display-awake] [--lid]
           dilated off [--id ID | --label NAME]
           dilated hold [--ttl 10m | --for "until 5pm"] [--label NAME] [--id ID | --lid]
           dilated release --id ID
           dilated agent begin|renew|end --agent NAME --run ID [--pid N] [--json]
           dilated run [--label NAME] [--lid] -- command arguments
           dilated lid-permission status|install|remove [--json]
           dilated helper status|setup|remove [--json]   (deprecated, use lid-permission)
           dilated prepare-update [--json]
           dilated prepare-uninstall [--remove-lid-permission] [--json]
           dilated package-check

    status --assertions lists every process's power assertions (read-only); Dilated's are starred.
    Starts allow display sleep unless --display-awake is supplied.
    --override-low-power explicitly allows a new hold in Low Power Mode.
    --lid requires closed-lid permission (see lid-permission) and the app's safety limits.
    lid-permission status prints notInstalled, needsRepair, blocked, ready, notAdmin or
    allowedByOtherRule (another app's sudo rule already covers closed-lid).
    lid-permission install and remove ask for your administrator password in the app.
    The helper commands are deprecated aliases of lid-permission and go away in a later release.
    prepare-update turns closed-lid off and quits while preserving only unexpired timers.
    prepare-uninstall turns closed-lid off, removes the login item and owned CLI link, then
    discards holds and quits. It leaves the sudo rule alone unless you pass --remove-lid-permission,
    which asks for your administrator password.
    Reopen Dilated after upgrading. Package preparation expires after ten minutes.
    Renewals preserve an active lid request but can't re-enable a stopped one.
    A new hold prints its unique ID. Pass it to hold --id to renew, or release.
    Stop pauses CLI/URL starts and renewals until Resume automation in the app.
    agent keeps one 10-minute hold per run ID: begin is idempotent, renew never recreates an
    ended hold, and end releases only that run's hold. NAME and ID use letters, digits, - and _.
    begin --pid N (your agent's process ID) also renews the hold every 2 minutes until that
    process exits or end runs.
    run works without the app. Ending its awake hold never terminates the command.
    """
}
