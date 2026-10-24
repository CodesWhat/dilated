import AppKit
import Darwin
import DilatedCore
import SystemConfiguration

struct NativeProcess: Identifiable, Sendable {
  let id: Int32
  let name: String
  let path: String
  let identity: ProcessIdentity
}

enum ProcessCatalog {
  static func read() -> [NativeProcess] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [Int32](repeating: 0, count: Int(count) + 128)
    let found = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard found > 0 else { return [] }
    return pids.prefix(min(Int(found), pids.count)).compactMap { pid in
      guard pid > 0 else { return nil }
      var info = proc_bsdinfo()
      guard
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0,
        info.pbi_status != SZOMB
      else { return nil }
      var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
      let length = proc_pidpath(pid, &path, UInt32(path.count))
      let executable = length > 0 ? String(cString: path) : ""
      var name = [CChar](repeating: 0, count: 256)
      guard proc_name(pid, &name, UInt32(name.count)) > 0 else { return nil }
      return NativeProcess(
        id: pid,
        name: executable.isEmpty
          ? String(cString: name) : URL(fileURLWithPath: executable).lastPathComponent,
        path: executable,
        identity: ProcessIdentity(
          pid: pid, startedAtMicroseconds: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
      )
    }
  }
}

@MainActor final class TriggerMonitor {
  private let changed: () -> Void
  private let readPower: () -> PowerState
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  private var processTimer: Timer?
  private var boundaryTimer: Timer?
  private var exits: [Int32: any DispatchSourceProcess] = [:]
  private var network: SCDynamicStore?
  private var needsProcesses = false
  private var processNames: Set<String> = []
  private var processInstances: Set<ProcessIdentity> = []

  init(readPower: @escaping () -> PowerState, changed: @escaping () -> Void) {
    self.changed = changed
    self.readPower = readPower
    let workspace = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
      NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification,
    ] { observe(name, center: workspace) }
    for name in [
      NSApplication.didChangeScreenParametersNotification, .NSSystemClockDidChange,
      .NSSystemTimeZoneDidChange,
    ] { observe(name, center: .default) }
    var context = SCDynamicStoreContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    network = SCDynamicStoreCreate(
      nil, "Dilated triggers" as CFString,
      { _, _, info in
        guard let info else { return }
        MainActor.assumeIsolated {
          Unmanaged<TriggerMonitor>.fromOpaque(info).takeUnretainedValue().changed()
        }
      }, &context)
    if let network {
      SCDynamicStoreSetNotificationKeys(network, nil, ["State:/Network/.*"] as CFArray)
      SCDynamicStoreSetDispatchQueue(network, .main)
    }
  }

  func configure(rules: [TriggerRule]) {
    let rules = rules.filter { $0.pausedUntil.map { $0 <= Date() } ?? true }
    processNames = Set(
      rules.flatMap(\.criteria).compactMap {
        if case .process(let name) = $0 { return name }
        return nil
      })
    processInstances = Set(
      rules.flatMap(\.criteria).compactMap {
        if case .processInstance(let identity) = $0 { return identity }
        return nil
      })
    needsProcesses = !processNames.isEmpty || !processInstances.isEmpty
    if needsProcesses && processTimer == nil {
      let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.changed() }
      }
      timer.tolerance = 1
      RunLoop.main.add(timer, forMode: .common)
      processTimer = timer
    } else if !needsProcesses {
      processTimer?.invalidate()
      processTimer = nil
      for source in exits.values { source.cancel() }
      exits = [:]
    }
  }

  func read() -> TriggerInputs {
    var input = TriggerInputs()
    input.applications = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    input.frontmostApplication = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    input.power = readPower()
    var displays = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    if CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success {
      input.displayCount = Int(count)
      input.mirroredDisplays = displays.prefix(Int(count)).contains {
        CGDisplayIsInMirrorSet($0) != 0
      }
      input.externalDisplayCount =
        displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.count
    }
    if let network,
      let values = SCDynamicStoreCopyMultiple(
        network, nil, ["State:/Network/Global/.*", "State:/Network/Service/.*/IPv[46]"] as CFArray)
        as? [String: Any]
    {
      for case let value as [String: Any] in values.values {
        input.addresses.formUnion(value["Addresses"] as? [String] ?? [])
        if let router = value["Router"] as? String { input.gateways.insert(router) }
        input.dnsServers.formUnion(value["ServerAddresses"] as? [String] ?? [])
      }
    }
    if needsProcesses {
      let processes = ProcessCatalog.read()
      input.processInstances = Set(processes.map(\.identity))
      input.processNames = Set(processes.flatMap { [$0.name, $0.path] }.filter { !$0.isEmpty })
      let pids = Set(
        processes.filter {
          processNames.contains($0.name) || processNames.contains($0.path)
            || processInstances.contains($0.identity)
        }.map(
          \.id))
      for pid in exits.keys.filter({ !pids.contains($0) }) {
        exits.removeValue(forKey: pid)?.cancel()
      }
      for pid in pids where exits[pid] == nil {
        let source = DispatchSource.makeProcessSource(
          identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
          MainActor.assumeIsolated {
            self?.exits.removeValue(forKey: pid)?.cancel()
            self?.changed()
          }
        }
        exits[pid] = source
        source.resume()
      }
    }
    return input
  }

  func schedule(at date: Date?) {
    boundaryTimer?.invalidate()
    boundaryTimer = nil
    guard let date else { return }
    let timer = Timer(fire: max(date, Date().addingTimeInterval(0.05)), interval: 0, repeats: false)
    { [weak self] _ in
      MainActor.assumeIsolated { self?.changed() }
    }
    timer.tolerance = 0.1
    RunLoop.main.add(timer, forMode: .common)
    boundaryTimer = timer
  }

  func stop() {
    processTimer?.invalidate()
    boundaryTimer?.invalidate()
    processTimer = nil
    boundaryTimer = nil
    for source in exits.values { source.cancel() }
    exits = [:]
    for (center, observer) in observers { center.removeObserver(observer) }
    observers = []
    if let network { SCDynamicStoreSetDispatchQueue(network, nil) }
    network = nil
  }

  private func observe(_ name: Notification.Name, center: NotificationCenter) {
    observers.append(
      (
        center,
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.changed() }
        }
      ))
  }
}
