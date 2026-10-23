import AppKit
import DilatedControl
import DilatedCore
import Foundation
import IOKit.ps
import Observation

public struct AppSettings: Codable, Equatable, Sendable {
  public var defaultMinutes = 0
  public var allowDisplaySleep = true
  public var glyph = Glyph.bugEyes
  public var motion = Motion.subtle
  public var countdown = false
  public var swapClicks = false
  public var lowOpacityIdle = false
  public var batteryFloor = 0
  public var overrideLowPower = false
  public var startAtLaunch = false
  public var startAfterWake = false
  public var dockMode = "whileWindowOpen"
  public var urlAutomation = true
  public var onboardingComplete = false
  public var presets = [15, 30, 60, 120, 240, 480]
  public init() {}
  public init(from decoder: any Decoder) throws {
    self.init()
    let values = try decoder.container(keyedBy: CodingKeys.self)
    defaultMinutes = try values.decodeIfPresent(Int.self, forKey: .defaultMinutes) ?? defaultMinutes
    allowDisplaySleep =
      try values.decodeIfPresent(Bool.self, forKey: .allowDisplaySleep) ?? allowDisplaySleep
    glyph = try values.decodeIfPresent(Glyph.self, forKey: .glyph) ?? glyph
    motion = try values.decodeIfPresent(Motion.self, forKey: .motion) ?? motion
    countdown = try values.decodeIfPresent(Bool.self, forKey: .countdown) ?? countdown
    swapClicks = try values.decodeIfPresent(Bool.self, forKey: .swapClicks) ?? swapClicks
    lowOpacityIdle =
      try values.decodeIfPresent(Bool.self, forKey: .lowOpacityIdle) ?? lowOpacityIdle
    batteryFloor = try values.decodeIfPresent(Int.self, forKey: .batteryFloor) ?? batteryFloor
    overrideLowPower =
      try values.decodeIfPresent(Bool.self, forKey: .overrideLowPower) ?? overrideLowPower
    startAtLaunch = try values.decodeIfPresent(Bool.self, forKey: .startAtLaunch) ?? startAtLaunch
    startAfterWake =
      try values.decodeIfPresent(Bool.self, forKey: .startAfterWake) ?? startAfterWake
    dockMode = try values.decodeIfPresent(String.self, forKey: .dockMode) ?? dockMode
    urlAutomation = try values.decodeIfPresent(Bool.self, forKey: .urlAutomation) ?? urlAutomation
    onboardingComplete =
      try values.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? onboardingComplete
    presets = try values.decodeIfPresent([Int].self, forKey: .presets) ?? presets
    defaultMinutes = min(10080, max(0, defaultMinutes))
    batteryFloor = batteryFloor == 0 ? 0 : min(100, max(10, batteryFloor))
    presets = Array(Set(presets.filter { (1...10080).contains($0) })).sorted().prefix(10).map { $0 }
    if presets.isEmpty { presets = AppSettings().presets }
  }
}

@MainActor @Observable public final class AppModel {
  public private(set) var engine: WakeEngine
  public var settings: AppSettings {
    didSet {
      do {
        try JSONEncoder().encode(settings).write(to: settingsFile, options: .atomic)
        engine.batteryFloor = settings.batteryFloor > 0 ? settings.batteryFloor : nil
        refreshPower()
      } catch { message = "Couldn't save settings: \(error.localizedDescription)" }
      onChange?()
    }
  }
  public var message: String?
  public private(set) var now = Date()
  @ObservationIgnored public var onChange: (() -> Void)?
  @ObservationIgnored public var onBatteryOverrideNeeded: ((TimeInterval?) -> Void)?
  @ObservationIgnored public let endpoint: SocketEndpoint
  @ObservationIgnored private let store: StateStore
  @ObservationIgnored private let readPower: () -> PowerState
  @ObservationIgnored private let assertions: any AssertionControlling
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var lastAssertionRefresh = Date.distantPast
  @ObservationIgnored private var stopped = false
  private var settingsFile: URL { endpoint.stateDirectory.appendingPathComponent("settings.json") }
  public var attention: String? { message ?? engine.attention }
  public var statusText: String {
    guard !engine.holds.isEmpty else { return "Sleeping normally" }
    if engine.holds.contains(where: { $0.expiry == nil }) { return "Awake indefinitely" }
    guard let expiry = engine.holds.compactMap(\.expiry).max() else { return "Keeping awake" }
    return "Awake for \(Self.remaining(until: expiry, now: now)) more"
  }
  public var nativeAssertionTypes: Set<String> { assertions.activeTypes }

  public init(
    endpoint: SocketEndpoint = .current, power: @escaping () -> PowerState = SystemPower.read,
    assertions: any AssertionControlling = NativeAssertions()
  ) {
    self.endpoint = endpoint
    self.store = StateStore(directory: endpoint.stateDirectory)
    self.readPower = power
    self.assertions = assertions
    var loadMessage: String?
    var loadedSettings = AppSettings()
    let file = endpoint.stateDirectory.appendingPathComponent("settings.json")
    if FileManager.default.fileExists(atPath: file.path) {
      do {
        loadedSettings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: file))
      } catch { loadMessage = "Couldn't read settings: \(error.localizedDescription)" }
    }
    settings = loadedSettings
    let snapshot: EngineSnapshot
    do { snapshot = try store.load() } catch {
      snapshot = EngineSnapshot(automationPaused: true)
      loadMessage = "Couldn't read saved holds. Automation is paused: \(error.localizedDescription)"
    }
    engine = WakeEngine(
      snapshot: snapshot, power: power(),
      batteryFloor: loadedSettings.batteryFloor > 0 ? loadedSettings.batteryFloor : nil)
    message = loadMessage
  }

  public func begin() {
    commit()
    if settings.startAtLaunch { automaticStart(label: "At launch") }
  }
  public func startDefault() {
    start(duration: settings.defaultMinutes > 0 ? Double(settings.defaultMinutes * 60) : nil)
  }
  public func start(duration: TimeInterval? = nil, batteryOverride: Bool = false) {
    let failure = mutate {
      _ = try $0.start(
        source: .manual, label: duration == nil ? "Keep awake" : "Manual timer", duration: duration,
        displayAwake: !settings.allowDisplaySleep, lowPowerOverride: settings.overrideLowPower,
        batteryOverride: batteryOverride)
    }
    if failure == .lowBattery && !batteryOverride { onBatteryOverrideNeeded?(duration) }
  }
  public func automaticStart(label: String) {
    mutate {
      _ = try $0.start(
        source: .cli, label: label,
        duration: settings.defaultMinutes > 0 ? Double(settings.defaultMinutes * 60) : nil,
        displayAwake: !settings.allowDisplaySleep, lowPowerOverride: settings.overrideLowPower)
    }
  }
  public func stopAll() { mutate { $0.stopAll() } }
  public func stop(id: UUID) { mutate { $0.stop(id: id) } }
  public func resumeAutomation() { mutate { $0.resumeAutomation() } }
  public func extend(id: UUID, seconds: TimeInterval) {
    mutate { try $0.extend(id: id, by: seconds) }
  }
  public func setDisplayAwake(id: UUID, enabled: Bool) {
    mutate { $0.setDisplayAwake(id: id, enabled: enabled) }
  }
  public func toggle() { engine.holds.isEmpty ? startDefault() : stopAll() }
  public func refreshPower() {
    engine.updatePower(readPower())
    commit()
  }
  public func tick() {
    now = Date()
    let previous = engine.holds
    engine.tick(now: now)
    if engine.holds != previous {
      commit()
    } else if now.timeIntervalSince(lastAssertionRefresh) >= 20 {
      synchronizeAssertions()
    }
    onChange?()
  }
  public func control(_ request: ControlRequest) -> ControlResponse {
    engine.updatePower(readPower())
    var effective = request
    effective.lowPowerOverride = request.lowPowerOverride || settings.overrideLowPower
    var response = ControlRouter.handle(effective, engine: &engine)
    if !commit() {
      response.ok = false
      response.message = message
      response.code = "systemFailure"
    }
    response.snapshot = engine.snapshot
    return response
  }
  public func openURL(_ url: URL) {
    guard settings.urlAutomation else {
      message = "URL automation is turned off in Settings."
      onChange?()
      return
    }
    do {
      let response = control(try URLInput.parse(url))
      if !response.ok { message = response.message }
    } catch { message = error.localizedDescription }
    onChange?()
  }
  public func shutdown() {
    guard !stopped else { return }
    stopped = true
    timer?.invalidate()
    timer = nil
    engine.quit()
    do { try store.save(engine.snapshot) } catch {
      message = "Couldn't clear saved holds: \(error.localizedDescription)"
    }
    assertions.releaseAll()
  }
  @discardableResult private func mutate(_ change: (inout WakeEngine) throws -> Void) -> WakeError?
  {
    do {
      engine.updatePower(readPower())
      try change(&engine)
      message = nil
      commit()
      return nil
    } catch {
      message = error.localizedDescription
      onChange?()
      return error as? WakeError
    }
  }
  @discardableResult private func commit() -> Bool {
    now = Date()
    var saved = true
    do { try store.save(engine.snapshot) } catch {
      message = "Couldn't save awake state: \(error.localizedDescription)"
      saved = false
    }
    let applied = synchronizeAssertions()
    if !engine.holds.isEmpty && timer == nil && !stopped {
      let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.tick() }
      }
      timer.tolerance = 0.1
      RunLoop.main.add(timer, forMode: .common)
      self.timer = timer
    } else if engine.holds.isEmpty {
      timer?.invalidate()
      timer = nil
    }
    onChange?()
    return saved && applied
  }
  @discardableResult private func synchronizeAssertions() -> Bool {
    do {
      try assertions.synchronize(holds: engine.holds, now: Date())
      lastAssertionRefresh = Date()
      return true
    } catch {
      message = error.localizedDescription
      return false
    }
  }
  public static func remaining(until date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(ceil(date.timeIntervalSince(now))))
    return seconds >= 3600
      ? "\(seconds / 3600)h \((seconds % 3600) / 60)m"
      : seconds >= 60 ? "\((seconds + 59) / 60)m" : "\(seconds)s"
  }
}
