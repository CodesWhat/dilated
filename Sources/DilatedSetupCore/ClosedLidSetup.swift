import CryptoKit
import DilatedCore
import Foundation

/// Installs and removes everything the Mac App Store build's closed-lid mode needs outside the
/// sandbox: the sudoers rule, the `dilated-power` script and the repair LaunchAgent.
///
/// The rule is the one the direct build installs (same path, same content), so the two builds
/// share it. That makes one thing unsafe: the direct build's "remove" deletes the rule out from
/// under the Mac App Store build. The companion's remove is careful in the other direction. It
/// deletes the rule only when its own record says it created the file, never when the rule was
/// already there (the direct build's, Amphetamine's or anyone else's).
public struct ClosedLidSetup: Sendable {
  private let paths: ClosedLidSetupPaths
  private let assets: ClosedLidSetupAssets
  private let files: any SetupFileSystem
  private let launchd: any LaunchAgentControlling
  private let power: any PowerScriptRunning
  private let rule: any ClosedLidRuleControlling

  public init(
    paths: ClosedLidSetupPaths, assets: ClosedLidSetupAssets, files: any SetupFileSystem,
    launchd: any LaunchAgentControlling, power: any PowerScriptRunning,
    rule: any ClosedLidRuleControlling
  ) {
    self.paths = paths
    self.assets = assets
    self.files = files
    self.launchd = launchd
    self.power = power
    self.rule = rule
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: Status

  public func status() async -> ClosedLidSetupStatus {
    ClosedLidSetupStatus(
      rule: ClosedLidSetupRuleStatus(await rule.state()),
      script: scriptStatus(),
      agent: await launchd.isLoaded(target: paths.agentTarget) ? .loaded : .notLoaded,
      ruleInstalledByCompanion: loadRecord().ruleInstalledByCompanion)
  }

  private func scriptStatus() -> ClosedLidSetupScriptStatus {
    guard let installed = files.read(paths.scriptPath) else { return .missing }
    return Self.sha256(installed) == assets.expectedScriptSHA256 ? .present : .outdated
  }

  // MARK: Install

  public func install() async -> ClosedLidSetupOutcome {
    // Nothing is written, and no prompt appears, until the bundled files check out.
    guard Self.sha256(assets.script) == assets.expectedScriptSHA256 else {
      return .failed("The bundled dilated-power script doesn't match its expected checksum.")
    }
    guard assets.plistTemplate.contains("__HOME__") else {
      return .failed("The bundled LaunchAgent template is missing or invalid.")
    }

    // 1. Rule. A rule that already allows pmset (ours or another app's) needs no prompt.
    let before = await rule.state()
    if !(before == .ready || before == .allowedByOtherRule) {
      switch await rule.install() {
      case .cancelled: return .cancelled
      case .failed(let message, _): return .failed(message)
      case .completed(let state):
        guard state.isUsable else {
          return .failed("The rule was installed but sudo still doesn't allow the pmset commands.")
        }
      }
      // Only an absent file is ours to remove later. A damaged one existed before we got here.
      if before == .notInstalled { saveRecord(.init(ruleInstalledByCompanion: true)) }
    }

    // 2. Script.
    do {
      try files.writeAtomically(
        assets.script, to: paths.scriptPath, mode: 0o755, directoryMode: 0o755)
    } catch {
      return .failed("Couldn't write the dilated-power script: \(error.localizedDescription)")
    }

    // 3. Agent. Boot out any old copy first so a reinstall picks up the new plist.
    do {
      try files.writeAtomically(
        assets.renderedPlist(home: paths.home), to: paths.agentPlistPath, mode: 0o644,
        directoryMode: 0o755)
      await launchd.bootout(target: paths.agentTarget)
      try await launchd.bootstrap(domain: paths.agentDomain, plistPath: paths.agentPlistPath)
    } catch {
      return .failed("Couldn't load the repair agent: \(error.localizedDescription)")
    }
    // A bootstrap that returned cleanly isn't proof. Until the agent is loaded the script refuses
    // closed-lid enables, so a failure here leaves them blocked rather than unguarded.
    guard await launchd.isLoaded(target: paths.agentTarget) else {
      return .failed("The repair agent didn't load. Closed-lid mode stays off until it does.")
    }
    // A restore-pending latch with no session is a finished removal's leftover. It's cleared only
    // when macOS reads back normal sleep; otherwise it stays and a later Remove still owes the
    // readback (fails closed). The marker is still down, so no `on` can race the check.
    if files.exists(paths.restorePendingFile), !files.exists(paths.sessionFile),
      await power.confirmsNormalSleep()
    {
      try? files.remove(paths.restorePendingFile)
    }
    // Only now can the script accept closed-lid enables again.
    do { try files.remove(paths.removalMarker) } catch {
      return .failed("Couldn't clear the removal marker: \(error.localizedDescription)")
    }
    return .completed
  }

  // MARK: Remove

  public func remove() async -> ClosedLidSetupOutcome {
    // 1. Block new enables and put sleep back before the script that can do it goes away. An
    // installed script from before begin-removal existed is replaced first, since the old one
    // would answer with usage.
    // Only sleep this setup turned off (a session file on disk; a tombstone is a finished revert)
    // has to read back normal. Another app's disablesleep is left alone and never blocks removal.
    var ownedSleep = files.exists(paths.sessionFile) || files.exists(paths.restorePendingFile)
    var installed = files.read(paths.scriptPath)
    if installed == nil, ownedSleep {
      // An owned session with no script: the agent has nothing to run and begin-removal can't
      // answer. Put the bundled script back (only if it checks out), then take the normal staged
      // path. Nothing is deleted when the bundled bytes are bad or the write fails.
      guard Self.sha256(assets.script) == assets.expectedScriptSHA256 else {
        return .failed(
          "The dilated-power script is missing and the bundled copy doesn't match its expected checksum, so the repair agent was kept."
        )
      }
      do {
        try files.writeAtomically(
          assets.script, to: paths.scriptPath, mode: 0o755, directoryMode: 0o755)
      } catch {
        return .failed(
          "Couldn't restore the dilated-power script, so the repair agent was kept: \(error.localizedDescription)"
        )
      }
      installed = assets.script
    }
    if let installed {
      if Self.sha256(installed) != assets.expectedScriptSHA256,
        Self.sha256(assets.script) == assets.expectedScriptSHA256
      {
        do {
          try files.writeAtomically(
            assets.script, to: paths.scriptPath, mode: 0o755, directoryMode: 0o755)
        } catch {
          return .failed("Couldn't update the dilated-power script: \(error.localizedDescription)")
        }
      }
      do { ownedSleep = try await power.beginRemoval(scriptPath: paths.scriptPath) } catch {
        return .failed(
          "Closed-lid mode couldn't be turned off: \(error.localizedDescription)")
      }
    }
    // The recovery assets stay until macOS itself says sleep is back to normal.
    if ownedSleep {
      guard await power.confirmsNormalSleep() else {
        return .failed("macOS hasn't confirmed normal sleep, so the repair agent was kept.")
      }
      // The session record goes only now, so a retry after a failed readback is still ours.
      do { try await power.finishRemoval(scriptPath: paths.scriptPath) } catch {
        return .failed("Couldn't clear the closed-lid session: \(error.localizedDescription)")
      }
    }

    // 2. Agent.
    await launchd.bootout(target: paths.agentTarget)
    // 3. Script, then its folder if nothing else is in it.
    do {
      try files.remove(paths.agentPlistPath)
      try files.remove(paths.scriptPath)
    } catch {
      return .failed("Couldn't delete the installed files: \(error.localizedDescription)")
    }
    files.removeDirectoryIfEmpty(paths.scriptsDirectory)

    // 4. Rule, only if the companion created it.
    if loadRecord().ruleInstalledByCompanion {
      switch await rule.remove() {
      case .cancelled: return .cancelled
      case .failed(let message, _): return .failed(message)
      case .completed(let state):
        if state == .ready || state == .needsRepair || state == .blocked {
          return .failed("The sudoers rule is still in place.")
        }
      }
    }
    do { try files.remove(paths.stateFile) } catch {
      return .failed("Couldn't delete the setup record: \(error.localizedDescription)")
    }
    // The removal marker stays: only a verified install clears it, so an `on` that queued behind
    // this removal can't run without the repair agent.
    files.removeDirectoryIfEmpty(paths.stateDirectory)
    return .completed
  }

  // MARK: Record

  private func loadRecord() -> ClosedLidSetupRecord {
    files.read(paths.stateFile).flatMap {
      try? JSONDecoder().decode(ClosedLidSetupRecord.self, from: $0)
    } ?? ClosedLidSetupRecord(ruleInstalledByCompanion: false)
  }

  private func saveRecord(_ record: ClosedLidSetupRecord) {
    guard let data = try? JSONEncoder().encode(record) else { return }
    try? files.writeAtomically(data, to: paths.stateFile, mode: 0o600, directoryMode: 0o700)
  }
}
