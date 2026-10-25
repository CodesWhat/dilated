import AppKit
import DilatedControl
import DilatedCore
import Foundation
import IOKit.ps
import Observation

public enum SystemTransition: Sendable { case sleep, userSwitch }

public struct AppSettings: Codable, Equatable, Sendable {
  public var defaultMinutes = 0
  public var allowDisplaySleep = true
  public var glyph = Glyph.bugEyes
  public var useCustomGlyph = false
  public var customGlyph: CustomGlyph?
  public var customGlyphDimIdle = true
  public var motion = Motion.subtle
  public var countdown = false
  public var countdownFormat = CountdownFormat.compact
  public var countdownSeconds = CountdownSeconds.automatic
  public var countdownHourCycle = CountdownHourCycle.system
  public var countdownTextSize = CountdownTextSize.standard
  public var swapClicks = false
  public var lowOpacityIdle = false
  public var batteryFloor = 0
  public var overrideLowPower = false
  public var startAtLaunch = false
  public var startAfterWake = false
  public var stopOnSystemSleep = false
  public var stopOnUserSwitch = false
  public var triggersEnabled = true
  public var feedback = FeedbackSettings()
  public var driveAlive = DriveAliveSettings()
  public var historyEnabled = true
  public var historyRetentionDays = 30
  public var dockMode = "whileWindowOpen"
  public var urlAutomation = true
  public var onboardingComplete = false
  public var closedLidBatteryFloor = 20
  public var closedLidBatteryMinutes = 480
  public var closedLidACOnly = false
  public var closedLidBatteryWarningAccepted = false
  public var closedLidURLAutomation = false
  public var closedLidWarningSound = false
  public var presets = [15, 30, 60, 120, 240, 480]
  public var shortcuts = AwakeShortcut.defaults
  public init() {}
  public init(from decoder: any Decoder) throws {
    self.init()
    let values = try decoder.container(keyedBy: CodingKeys.self)
    defaultMinutes = try values.decodeIfPresent(Int.self, forKey: .defaultMinutes) ?? defaultMinutes
    allowDisplaySleep =
      try values.decodeIfPresent(Bool.self, forKey: .allowDisplaySleep) ?? allowDisplaySleep
    glyph = try values.decodeIfPresent(Glyph.self, forKey: .glyph) ?? glyph
    useCustomGlyph =
      try values.decodeIfPresent(Bool.self, forKey: .useCustomGlyph) ?? useCustomGlyph
    customGlyph = try? values.decodeIfPresent(CustomGlyph.self, forKey: .customGlyph)
    customGlyphDimIdle =
      try values.decodeIfPresent(Bool.self, forKey: .customGlyphDimIdle) ?? customGlyphDimIdle
    motion = try values.decodeIfPresent(Motion.self, forKey: .motion) ?? motion
    countdown = try values.decodeIfPresent(Bool.self, forKey: .countdown) ?? countdown
    countdownFormat =
      (try values.decodeIfPresent(String.self, forKey: .countdownFormat))
      .flatMap(CountdownFormat.init(rawValue:)) ?? countdownFormat
    countdownSeconds =
      (try values.decodeIfPresent(String.self, forKey: .countdownSeconds))
      .flatMap(CountdownSeconds.init(rawValue:)) ?? countdownSeconds
    countdownHourCycle =
      (try? values.decode(String.self, forKey: .countdownHourCycle))
      .flatMap(CountdownHourCycle.init(rawValue:)) ?? countdownHourCycle
    countdownTextSize =
      (try? values.decode(String.self, forKey: .countdownTextSize))
      .flatMap(CountdownTextSize.init(rawValue:)) ?? countdownTextSize
    swapClicks = try values.decodeIfPresent(Bool.self, forKey: .swapClicks) ?? swapClicks
    lowOpacityIdle =
      try values.decodeIfPresent(Bool.self, forKey: .lowOpacityIdle) ?? lowOpacityIdle
    batteryFloor = try values.decodeIfPresent(Int.self, forKey: .batteryFloor) ?? batteryFloor
    overrideLowPower =
      try values.decodeIfPresent(Bool.self, forKey: .overrideLowPower) ?? overrideLowPower
    startAtLaunch = try values.decodeIfPresent(Bool.self, forKey: .startAtLaunch) ?? startAtLaunch
    startAfterWake =
      try values.decodeIfPresent(Bool.self, forKey: .startAfterWake) ?? startAfterWake
    stopOnSystemSleep =
      try values.decodeIfPresent(Bool.self, forKey: .stopOnSystemSleep) ?? stopOnSystemSleep
    stopOnUserSwitch =
      try values.decodeIfPresent(Bool.self, forKey: .stopOnUserSwitch) ?? stopOnUserSwitch
    triggersEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .triggersEnabled) ?? triggersEnabled
    feedback = try values.decodeIfPresent(FeedbackSettings.self, forKey: .feedback) ?? feedback
    driveAlive =
      try values.decodeIfPresent(DriveAliveSettings.self, forKey: .driveAlive) ?? driveAlive
    historyEnabled =
      try values.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? historyEnabled
    historyRetentionDays =
      try values.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? historyRetentionDays
    if ![7, 30, 90].contains(historyRetentionDays) { historyRetentionDays = 30 }
    dockMode = try values.decodeIfPresent(String.self, forKey: .dockMode) ?? dockMode
    urlAutomation = try values.decodeIfPresent(Bool.self, forKey: .urlAutomation) ?? urlAutomation
    onboardingComplete =
      try values.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? onboardingComplete
    closedLidBatteryFloor =
      try values.decodeIfPresent(Int.self, forKey: .closedLidBatteryFloor) ?? closedLidBatteryFloor
    closedLidBatteryMinutes =
      try values.decodeIfPresent(Int.self, forKey: .closedLidBatteryMinutes)
      ?? closedLidBatteryMinutes
    closedLidACOnly =
      try values.decodeIfPresent(Bool.self, forKey: .closedLidACOnly) ?? closedLidACOnly
    closedLidBatteryWarningAccepted =
      try values.decodeIfPresent(Bool.self, forKey: .closedLidBatteryWarningAccepted)
      ?? closedLidBatteryWarningAccepted
    closedLidURLAutomation =
      try values.decodeIfPresent(Bool.self, forKey: .closedLidURLAutomation)
      ?? closedLidURLAutomation
    closedLidWarningSound =
      try values.decodeIfPresent(Bool.self, forKey: .closedLidWarningSound) ?? closedLidWarningSound
    shortcuts =
      try values.decodeIfPresent([ShortcutAction: AwakeShortcut].self, forKey: .shortcuts)
      ?? shortcuts
    presets = try values.decodeIfPresent([Int].self, forKey: .presets) ?? presets
    defaultMinutes = min(10080, max(0, defaultMinutes))
    batteryFloor = batteryFloor == 0 ? 0 : min(100, max(10, batteryFloor))
    closedLidBatteryFloor = min(100, max(10, closedLidBatteryFloor))
    closedLidBatteryMinutes = min(1440, max(1, closedLidBatteryMinutes))
    presets = Array(Set(presets.filter { (1...10080).contains($0) })).sorted().prefix(10).map { $0 }
    if presets.isEmpty { presets = AppSettings().presets }
  }
}

@MainActor @Observable public final class AppModel {
  public private(set) var engine: WakeEngine
  private var preferences: AppSettings
  public var settings: AppSettings {
    get { preferences }
    set {
      do { try applySettings(newValue) } catch {
        message = "Couldn't save settings: \(error.localizedDescription)"
      }
      onChange?()
    }
  }
  private func applySettings(_ value: AppSettings) throws {
    if let error = value.feedback.validationMessage { throw InputError(error) }
    if let error = value.driveAlive.validationMessage { throw InputError(error) }
    try writeSettings(value)
    let old = preferences
    preferences = value
    engine.batteryFloor = value.batteryFloor > 0 ? value.batteryFloor : nil
    if old.closedLidBatteryFloor != value.closedLidBatteryFloor
      || old.closedLidBatteryMinutes != value.closedLidBatteryMinutes
      || old.closedLidACOnly != value.closedLidACOnly
      || old.overrideLowPower != value.overrideLowPower
    {
      resetTriggerLidArming()
      engine.clearClosedLidRequests()
    }
    if old.historyEnabled != value.historyEnabled
      || old.historyRetentionDays != value.historyRetentionDays
    {
      historyNeedsCompaction = true
    }
    if old.triggersEnabled != value.triggersEnabled { reconcileTriggers(lastTriggerInputs) }
    refreshPower()
  }
  public private(set) var history = SessionHistory()
  public private(set) var historyIssue: String?
  @ObservationIgnored private var historyAvailable = true
  @ObservationIgnored private var historyWasEnabled = true
  @ObservationIgnored private var historyNeedsCompaction = true
  @ObservationIgnored private var lastHistoryCheckpoint = Date.distantPast
  @ObservationIgnored private let historyStore: HistoryStore
  public private(set) var triggerRules: [TriggerRule] = []
  public private(set) var triggerStatuses: [UUID: String] = [:]
  public private(set) var armedClosedLidTriggers: Set<UUID> = []
  public private(set) var armingClosedLidTrigger: UUID?
  @ObservationIgnored private var triggerLidRevision = UUID()
  @ObservationIgnored private var triggerLidTask: Task<Void, Never>?
  @ObservationIgnored private var triggerEvaluator = TriggerEvaluator()
  @ObservationIgnored private var triggerMonitor: TriggerMonitor?
  @ObservationIgnored private var lastTriggerInputs = TriggerInputs()
  @ObservationIgnored private var hasBegun = false
  @ObservationIgnored public var onShortcutAssignment:
    (([ShortcutAction: AwakeShortcut]) -> String?)?
  public var shortcutRecording = false { didSet { onChange?() } }
  public var message: String?
  public private(set) var now = Date()
  @ObservationIgnored public var onChange: (() -> Void)?
  @ObservationIgnored public var onBatteryOverrideNeeded: ((TimeInterval?) -> Void)?
  @ObservationIgnored public var onClosedLidBatteryWarning: (() -> Bool)?
  public let closedLid: ClosedLidController
  public let helperInstallation: HelperInstallation
  public let updater = AppUpdater()
  @ObservationIgnored public let endpoint: SocketEndpoint
  @ObservationIgnored private let store: StateStore
  @ObservationIgnored private let readPower: () -> PowerState
  @ObservationIgnored private let assertions: any AssertionControlling
  @ObservationIgnored var feedback: FeedbackController
  @ObservationIgnored var driveAlive = DriveAliveController()
  @ObservationIgnored private var downloads: [UUID: DownloadMonitor] = [:]
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var lastAssertionRefresh = Date.distantPast
  @ObservationIgnored private var stopped = false
  @ObservationIgnored private var preparingToQuit = false
  @ObservationIgnored private var savedForUpdate = false
  @ObservationIgnored private var historyShutdownReason = HoldEndReason.quit
  @ObservationIgnored private var lidChange: Task<Void, any Error>?
  @ObservationIgnored private var pendingLidRequest:
    (operation: UUID, id: UUID, policy: ClosedLidPolicy, automated: Bool)?
  private var settingsFile: URL { endpoint.stateDirectory.appendingPathComponent("settings.json") }
  public private(set) var customGlyphIssue: String?
  var glyphSelectionID: String {
    settings.useCustomGlyph
      ? "custom:" + (settings.customGlyph?.id.uuidString ?? "missing") + ":"
        + settings.glyph.rawValue
      : "builtin:" + settings.glyph.rawValue
  }
  public var attention: String? { message ?? engine.attention ?? customGlyphIssue }
  func menuGlyphImage(frame: String) -> NSImage? {
    guard settings.useCustomGlyph else {
      customGlyphIssue = nil
      return settings.glyph.image(frame: frame)
    }
    do {
      guard let glyph = settings.customGlyph else { throw InputError("Import a custom PNG first.") }
      let image = try CustomGlyphStore(directory: endpoint.stateDirectory).image(glyph)
      customGlyphIssue = nil
      return image
    } catch {
      customGlyphIssue =
        "Couldn't load the custom icon. Using \(settings.glyph.label) until you import or select another icon."
      return settings.glyph.image(frame: engine.holds.isEmpty ? "off" : settings.glyph.stillFrame)
    }
  }
  public var statusText: String {
    guard !engine.holds.isEmpty else { return "Sleeping normally" }
    if engine.holds.contains(where: { $0.expiry == nil }) { return "Awake indefinitely" }
    guard let expiry = engine.holds.compactMap(\.expiry).max() else { return "Keeping awake" }
    return "Awake for \(Self.remaining(until: expiry, now: now)) more"
  }
  public var nativeAssertionTypes: Set<String> { assertions.activeTypes }

  public init(
    endpoint: SocketEndpoint = .current, power: @escaping () -> PowerState = SystemPower.read,
    assertions: any AssertionControlling = NativeAssertions(),
    closedLid: ClosedLidController? = nil,
    helperInstallation: HelperInstallation? = nil
  ) {
    self.endpoint = endpoint
    self.store = StateStore(directory: endpoint.stateDirectory)
    self.historyStore = HistoryStore(directory: endpoint.stateDirectory)
    self.readPower = power
    self.assertions = assertions
    self.feedback = FeedbackController(
      service: NativeFeedbackService(),
      sounds: NativeFeedbackSounds(directory: endpoint.stateDirectory))
    self.closedLid = closedLid ?? ClosedLidController()
    self.helperInstallation = helperInstallation ?? HelperInstallation()
    var loadMessage: String?
    var loadedSettings = AppSettings()
    let file = endpoint.stateDirectory.appendingPathComponent("settings.json")
    if FileManager.default.fileExists(atPath: file.path) {
      do {
        loadedSettings = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: file))
        if let error = ShortcutBindings.validationError(loadedSettings.shortcuts) {
          loadedSettings.shortcuts = [:]
          loadMessage = "Saved shortcuts were disabled: \(error)"
        }
      } catch { loadMessage = "Couldn't read settings: \(error.localizedDescription)" }
    }
    let triggerFile = endpoint.stateDirectory.appendingPathComponent("triggers.json")
    if FileManager.default.fileExists(atPath: triggerFile.path) {
      do {
        let rules = try JSONDecoder().decode(
          [TriggerRule].self, from: Data(contentsOf: triggerFile))
        guard rules.count <= 100, Set(rules.map(\.id)).count == rules.count,
          rules.allSatisfy({ $0.validationMessage == nil })
        else { throw TriggerConfigurationError("Saved triggers contain invalid rules.") }
        triggerRules = rules
      } catch { loadMessage = "Couldn't load triggers: \(error.localizedDescription)" }
    }
    preferences = loadedSettings
    historyWasEnabled = loadedSettings.historyEnabled
    do { history = try historyStore.load(retentionDays: loadedSettings.historyRetentionDays) } catch
    {
      historyIssue =
        "Couldn't load history: \(error.localizedDescription) Clear history to start again."
      historyAvailable = false
    }
    let snapshot: EngineSnapshot
    do { snapshot = try store.load() } catch {
      snapshot = EngineSnapshot(automationPaused: true)
      loadMessage = "Couldn't read saved holds. Automation is paused: \(error.localizedDescription)"
    }
    engine = WakeEngine(
      snapshot: snapshot, power: power(),
      batteryFloor: loadedSettings.batteryFloor > 0 ? loadedSettings.batteryFloor : nil)
    message = loadMessage
    self.closedLid.onChange = { [weak self] in self?.onChange?() }
    self.closedLid.onEnded = { [weak self] reason in
      guard let self, !self.stopped else { return }
      self.resetTriggerLidArming()
      self.engine.clearClosedLidRequests()
      self.message = reason
      self.commit()
      self.feedback.closedLidEnded(reason, playSound: !self.settings.closedLidWarningSound)
      if self.settings.closedLidWarningSound { NSSound.beep() }
    }
    updater.activity = { [weak self] in self?.updateActivity ?? .starting }
  }

  public func begin() {
    hasBegun = true
    let handoff = PackageHandoffStore(directory: endpoint.stateDirectory)
    let prepared = try? handoff.requirePrepared(app: Bundle.main.bundleURL)
    let restoreHelper = prepared?.intent == .update && prepared?.helperWasApproved == true
    do { try handoff.clear() } catch {
      message = "Couldn't clear package preparation: \(error.localizedDescription)"
    }
    commit()
    if settings.startAtLaunch { automaticStart(label: "At launch") }
    if helperInstallation.status == .enabled || restoreHelper {
      Task { [weak self] in
        guard let self else { return }
        if restoreHelper, self.helperInstallation.status == .notRegistered {
          await self.helperInstallation.nextStep(controller: self.closedLid)
        } else {
          await self.helperInstallation.reconcileAfterLaunch(controller: self.closedLid)
        }
        if let error = self.helperInstallation.lastError { self.message = error }
      }
    }
    updater.start()
    refreshTriggers()
  }
  var updateActivity: UpdateActivity {
    if helperInstallation.busy { return .helperChange }
    if engine.desiredState.closedLid || closedLid.hasLease || closedLid.pendingEnable
      || closedLid.busy
    {
      return .closedLid
    }
    if closedLid.state.map({ !$0.readback.confirmedDisabled }) == true { return .recovering }
    return .idle
  }
  public func startDefault() {
    start(duration: settings.defaultMinutes > 0 ? Double(settings.defaultMinutes * 60) : nil)
  }
  public func start(duration: TimeInterval? = nil, batteryOverride: Bool = false) {
    guard allowNewWork() else { return }
    let failure = mutate {
      _ = try $0.start(
        source: .manual, label: duration == nil ? "Keep awake" : "Manual timer", duration: duration,
        displayAwake: !settings.allowDisplaySleep, lowPowerOverride: settings.overrideLowPower,
        batteryOverride: batteryOverride)
    }
    if failure == .lowBattery && !batteryOverride { onBatteryOverrideNeeded?(duration) }
  }
  @discardableResult func startDownload(
    _ target: DownloadTarget, quietSeconds: TimeInterval,
    makeMonitor: (DownloadTarget, TimeInterval, @escaping @MainActor (String?) -> Void)
      -> DownloadMonitor = { target, seconds, finished in
        DownloadMonitor(target: target, quietSeconds: seconds, finished: finished)
      }
  ) throws -> UUID {
    guard allowNewWork() else { throw InputError(message ?? "Dilated is unavailable.") }
    let hold: Hold
    do {
      engine.updatePower(readPower())
      hold = try engine.start(
        source: .manual, label: "Download: \(target.url.lastPathComponent)",
        displayAwake: !settings.allowDisplaySleep, lowPowerOverride: settings.overrideLowPower)
    } catch {
      message = error.localizedDescription
      commit()
      throw error
    }
    let monitor = makeMonitor(target, quietSeconds) { [weak self] issue in
      guard let self, self.downloads[hold.id] != nil else { return }
      self.downloads.removeValue(forKey: hold.id)?.stop()
      self.engine.stop(id: hold.id, reason: .conditionEnded)
      if let issue { self.message = issue }
      self.commit()
    }
    downloads[hold.id] = monitor
    message = nil
    do {
      guard commit() else { throw InputError(message ?? "Couldn't keep the Mac awake.") }
      try monitor.start()
      return hold.id
    } catch {
      downloads.removeValue(forKey: hold.id)?.stop()
      engine.stop(id: hold.id, reason: .conditionEnded)
      commit()
      throw error
    }
  }
  public func automaticStart(label: String) {
    guard allowNewWork() else { return }
    mutate {
      _ = try $0.start(
        source: .cli, label: label,
        duration: settings.defaultMinutes > 0 ? Double(settings.defaultMinutes * 60) : nil,
        displayAwake: !settings.allowDisplaySleep, lowPowerOverride: settings.overrideLowPower)
    }
  }
  public func stopAll() { mutate { $0.stopAll() } }
  public func handleSystemTransition(_ transition: SystemTransition) {
    let shouldStop =
      switch transition {
      case .sleep: settings.stopOnSystemSleep
      case .userSwitch: settings.stopOnUserSwitch
      }
    if shouldStop { mutate { $0.stopAll(reason: transition == .sleep ? .sleep : .userSwitch) } }
  }
  public func stop(id: UUID) { mutate { $0.stop(id: id) } }
  public func resumeAutomation() {
    let wasPaused = engine.automationPaused
    mutate { $0.resumeAutomation() }
    if wasPaused { triggerEvaluator = TriggerEvaluator() }
    refreshTriggers()
  }
  public func extend(id: UUID, seconds: TimeInterval) {
    guard allowNewWork() else { return }
    mutate { try $0.extend(id: id, by: seconds) }
  }
  public func setDisplayAwake(id: UUID, enabled: Bool) {
    mutate { $0.setDisplayAwake(id: id, enabled: enabled) }
  }
  public var closedLidPolicy: ClosedLidPolicy {
    ClosedLidPolicy(
      batteryFloor: settings.closedLidBatteryFloor,
      maximumBatteryClosedSeconds: Double(settings.closedLidBatteryMinutes * 60),
      acOnly: settings.closedLidACOnly, overrideLowPower: settings.overrideLowPower)
  }
  public func setClosedLid(
    id: UUID, enabled: Bool, allowPrompt: Bool = true, requireAutomation: Bool = false
  ) async throws {
    guard !stopped, !preparingToQuit, !updater.blocksNewWork, !helperInstallation.busy else {
      throw HelperClientError.rejected("Dilated is finishing a helper operation.")
    }
    guard engine.holds.contains(where: { $0.id == id }) else { throw WakeError.holdNotFound }
    if enabled && requireAutomation && engine.automationPaused { throw WakeError.automationPaused }
    if !enabled {
      if let ruleID = triggerRuleID(for: id) { resetTriggerLidArming(ids: [ruleID]) }
      if pendingLidRequest?.id == id { pendingLidRequest = nil }
      engine.setClosedLid(id: id, enabled: false)
      let committed = commit()
      try await synchronizeClosedLid()
      if !committed { throw InputError(message ?? "Couldn't save closed-lid state.") }
      return
    }
    guard pendingLidRequest == nil, !closedLid.busy else {
      throw HelperClientError.rejected("Closed-lid is already changing. Wait for it to finish.")
    }
    try confirmClosedLidBatteryWarning(allowPrompt: allowPrompt)
    let operation = UUID()
    let policy = closedLidPolicy
    pendingLidRequest = (operation, id, policy, requireAutomation)
    defer {
      if pendingLidRequest?.operation == operation { pendingLidRequest = nil }
      queueTriggerClosedLid()
    }
    do {
      if closedLid.hasLease {
        try await closedLid.heartbeat()
      } else {
        try await closedLid.enable(policy: policy)
      }
      engine.updatePower(readPower())
      guard !Task.isCancelled, pendingLidRequest?.operation == operation, validPendingLidRequest
      else {
        throw CancellationError()
      }
      engine.setClosedLid(id: id, enabled: true)
      message = nil
      if !commit() {
        let issue = message ?? "Couldn't save closed-lid state."
        engine.setClosedLid(id: id, enabled: false)
        throw InputError(issue)
      }
    } catch {
      if pendingLidRequest?.operation == operation { pendingLidRequest = nil }
      commit()
      try await synchronizeClosedLid()
      throw error
    }
  }
  private func confirmClosedLidBatteryWarning(allowPrompt: Bool) throws {
    if readPower().onBattery && !settings.closedLidBatteryWarningAccepted {
      guard allowPrompt, onClosedLidBatteryWarning?() == true else {
        throw HelperClientError.rejected(
          "Enable closed-lid from the menu once to review the battery warning.")
      }
      var value = settings
      value.closedLidBatteryWarningAccepted = true
      try applySettings(value)
    }
  }
  public func synchronizeClosedLid() async throws {
    queueClosedLidReset()
    try await lidChange?.value
    if !engine.desiredState.closedLid,
      closedLid.state.map({ !$0.readback.confirmedDisabled }) == true
    {
      try await closedLid.disable()
    }
  }
  private func queueClosedLidReset() {
    guard !engine.desiredState.closedLid, !validPendingLidRequest, lidChange == nil,
      closedLid.hasLease || closedLid.pendingEnable
    else { return }
    lidChange = Task { [weak self] in
      guard let self else { return }
      defer {
        self.lidChange = nil
        self.queueTriggerClosedLid()
      }
      do { try await self.closedLid.disable() } catch {
        self.resetTriggerLidArming()
        if !self.stopped {
          self.message = error.localizedDescription
          self.onChange?()
        }
        throw error
      }
    }
  }
  private var validPendingLidRequest: Bool {
    guard let request = pendingLidRequest else { return false }
    let triggerAllowed =
      !request.automated
      || triggerRuleID(for: request.id).map {
        armedClosedLidTriggers.contains($0)
      } ?? true
    return triggerAllowed && !stopped && !preparingToQuit && !updater.blocksNewWork
      && request.policy == closedLidPolicy
      && (!request.automated || !engine.automationPaused)
      && engine.holds.contains {
        $0.id == request.id && ($0.expiry.map { $0 > Date() } ?? true)
      }
  }
  public func sleepNow() async {
    resetTriggerLidArming()
    engine.stopAll(reason: .sleep)
    commit(resetClosedLid: false)
    do {
      try await lidChange?.value
      try await closedLid.sleepNow()
    } catch { message = error.localizedDescription }
    onChange?()
  }
  public func refreshHelperStatus() {
    helperInstallation.refreshStatus()
    if helperInstallation.status == .enabled && !closedLid.busy && !helperInstallation.busy {
      Task { [weak self] in try? await self?.closedLid.refresh() }
    }
    onChange?()
  }
  public func setupHelper() async {
    guard allowNewWork() else { return }
    resetTriggerLidArming()
    engine.clearClosedLidRequests()
    commit()
    do { try await synchronizeClosedLid() } catch {
      message = error.localizedDescription
      return
    }
    await helperInstallation.nextStep(controller: closedLid)
    message = helperInstallation.lastError
    onChange?()
  }
  @discardableResult public func removeHelper() async -> Bool {
    guard allowNewWork() else { return false }
    resetTriggerLidArming()
    engine.clearClosedLidRequests()
    commit()
    do {
      try await synchronizeClosedLid()
      try await helperInstallation.remove(controller: closedLid)
      message = nil
      onChange?()
      return true
    } catch {
      message = error.localizedDescription
      onChange?()
      return false
    }
  }
  public func prepareToQuit() async -> Bool {
    guard !stopped else { return true }
    guard !preparingToQuit else { return false }
    preparingToQuit = true
    resetTriggerLidArming()
    defer { preparingToQuit = false }
    engine.clearClosedLidRequests()
    commit()
    do {
      try await synchronizeClosedLid()
      if helperInstallation.status == .enabled
        || closedLid.state.map({ !$0.readback.confirmedDisabled }) == true
      {
        try await closedLid.disable()
      }
      shutdown()
      return true
    } catch {
      message =
        "Couldn't confirm closed-lid is off. Dilated is staying open: \(error.localizedDescription)"
      onChange?()
      return false
    }
  }
  public func prepareToUpdate() async -> Bool {
    guard !stopped else { return true }
    guard !preparingToQuit, updateActivity == .idle else {
      message = "Turn off closed-lid and finish helper changes before updating."
      onChange?()
      return false
    }
    preparingToQuit = true
    resetTriggerLidArming()
    defer { preparingToQuit = false }
    do {
      try await synchronizeClosedLid()
      if helperInstallation.status == .enabled { try await closedLid.disable() }
      let restored = WakeEngine(
        snapshot: engine.snapshot, power: readPower(), batteryFloor: engine.batteryFloor)
      try store.save(restored.snapshot)
      savedForUpdate = true
      historyShutdownReason = .update
      shutdown()
      return true
    } catch {
      message =
        "Couldn't prepare the update. Dilated is staying open: \(error.localizedDescription)"
      onChange?()
      return false
    }
  }
  public func prepareForPackage(
    _ intent: PackageIntent, app: URL = Bundle.main.bundleURL,
    removeLoginItem: (() throws -> Void)? = nil,
    removeCommandLine: (() throws -> Void)? = nil
  ) async -> Bool {
    guard !stopped, !preparingToQuit, !updater.blocksNewWork, updateActivity == .idle else {
      message = "Turn off closed-lid and finish helper changes before preparing the package."
      onChange?()
      return false
    }
    preparingToQuit = true
    resetTriggerLidArming()
    defer { preparingToQuit = false }
    let handoff = PackageHandoffStore(directory: endpoint.stateDirectory)
    do {
      try handoff.clear()
      try await synchronizeClosedLid()
      helperInstallation.refreshStatus()
      let helperWasApproved = helperInstallation.status == .enabled
      try await helperInstallation.remove(controller: closedLid)
      if intent == .uninstall {
        if let removeLoginItem {
          try removeLoginItem()
        } else {
          let service = SystemLoginItemService()
          if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
          }
        }
        if let removeCommandLine {
          try removeCommandLine()
        } else {
          let cli = CommandLineInstallation(
            source: app.appendingPathComponent("Contents/MacOS/dilated"))
          if cli.isInstalled { _ = try cli.remove() }
        }
      }
      var prepared = WakeEngine(
        snapshot: engine.snapshot, power: readPower(), batteryFloor: engine.batteryFloor)
      if intent == .uninstall { prepared.quit() }
      try store.save(prepared.snapshot)
      try handoff.save(
        .init(
          intent: intent, appPath: app.resolvingSymlinksInPath().path, preparedAt: Date(),
          helperWasApproved: intent == .update && helperWasApproved))
      savedForUpdate = true
      historyShutdownReason = intent == .update ? .update : .packageRemoval
      shutdown()
      message =
        intent == .update
        ? "Prepared for update. Unexpired timers will keep their original deadlines."
        : "Prepared for removal. Helper, login item and owned command line link are removed."
      return true
    } catch {
      try? handoff.clear()
      message =
        "Couldn't prepare the package. Dilated is staying open: \(error.localizedDescription)"
      onChange?()
      return false
    }
  }
  public func toggle() { engine.holds.isEmpty ? startDefault() : stopAll() }
  public func refreshPower() {
    engine.updatePower(readPower())
    commit()
    refreshTriggers()
  }
  public func tick() {
    now = Date()
    let previous = engine.holds
    engine.tick(now: now)
    for monitor in Array(downloads.values) { monitor.tick() }
    feedback.tick(uptime: ProcessInfo.processInfo.systemUptime)
    if engine.holds != previous {
      commit()
    } else if now.timeIntervalSince(lastAssertionRefresh) >= 20 {
      synchronizeAssertions()
      recordHistory()
    }
    onChange?()
  }
  public func control(
    _ request: ControlRequest, origin: ControlOrigin = .commandLine
  ) async -> ControlResponse {
    guard !stopped, !preparingToQuit else {
      return ControlResponse(ok: false, message: "Dilated is quitting.", code: "unavailable")
    }
    if updater.blocksNewWork, ![.status, .stopAll, .release].contains(request.action) {
      return ControlResponse(
        ok: false, message: "Dilated is installing an update.", code: "unavailable")
    }
    if request.action == .prepareUpdate || request.action == .prepareUninstall {
      let ready = await prepareForPackage(request.action == .prepareUpdate ? .update : .uninstall)
      return ControlResponse(
        ok: ready, message: message, code: ready ? nil : "packageFailure",
        helperInstallation: helperInstallation.statusCode,
        appPID: ready ? ProcessInfo.processInfo.processIdentifier : nil)
    }
    if [.helperStatus, .helperSetup, .helperRemove].contains(request.action) {
      return await controlHelper(request.action)
    }
    guard !request.closedLid || [.start, .lease, .runner, .toggle].contains(request.action) else {
      return ControlResponse(
        ok: false, message: "Renewals can't enable closed-lid. Start a new hold or use the menu.",
        code: "invalidRequest")
    }
    engine.updatePower(readPower())
    var effective = request
    effective.closedLid = false
    effective.lowPowerOverride = request.lowPowerOverride || settings.overrideLowPower
    var response = ControlRouter.handle(effective, engine: &engine, origin: origin)
    if !commit() {
      response.ok = false
      response.message = message
      response.code = "systemFailure"
    }
    if response.ok, request.closedLid, let id = response.id {
      do { try await setClosedLid(id: id, enabled: true, allowPrompt: false) } catch {
        engine.stop(id: id, reason: .helperFailure)
        commit()
        try? await synchronizeClosedLid()
        response.ok = false
        response.id = nil
        response.message = error.localizedDescription
        response.code = "helperFailure"
      }
    }
    if response.ok, [.stopAll, .release, .toggle].contains(request.action) {
      do { try await synchronizeClosedLid() } catch {
        response.ok = false
        response.message = error.localizedDescription
        response.code = "helperFailure"
      }
    }
    response.snapshot = engine.snapshot
    response.helper = closedLid.state
    return response
  }
  private func controlHelper(_ action: ControlAction) async -> ControlResponse {
    helperInstallation.refreshStatus()
    guard !helperInstallation.busy || action == .helperStatus else {
      return ControlResponse(
        ok: false, message: "The helper setup is still running.", code: "unavailable")
    }
    var removalSucceeded = false
    if action == .helperSetup {
      await setupHelper()
    } else if action == .helperRemove {
      removalSucceeded = await removeHelper()
    } else if helperInstallation.status == .enabled {
      do { try await closedLid.refresh() } catch { message = error.localizedDescription }
    }
    let ok: Bool
    switch action {
    case .helperSetup:
      ok =
        helperInstallation.status == .enabled && helperInstallation.lastError == nil
        && closedLid.state?.ready == true
    case .helperRemove: ok = removalSucceeded
    default: ok = true
    }
    return ControlResponse(
      ok: ok, snapshot: engine.snapshot,
      message: action == .helperRemove && ok
        ? "Closed-lid is off and the helper has been removed."
        : action == .helperStatus
          ? helperInstallation.statusText : message ?? helperInstallation.statusText,
      code: ok
        ? nil
        : helperInstallation.status == .requiresApproval ? "approvalRequired" : "helperFailure",
      helper: closedLid.state, helperInstallation: helperInstallation.statusCode)
  }
  public func openURL(_ url: URL) async {
    guard settings.urlAutomation else {
      message = "URL automation is turned off in Settings."
      onChange?()
      return
    }
    do {
      let request = try URLInput.parse(url)
      guard !request.closedLid || settings.closedLidURLAutomation else {
        throw HelperClientError.rejected(
          "Allow closed-lid automation links in Closed Lid settings first.")
      }
      let response = await control(request, origin: .url)
      if !response.ok { message = response.message }
    } catch { message = error.localizedDescription }
    onChange?()
  }
  public func shutdown() {
    guard !stopped else { return }
    stopped = true
    resetTriggerLidArming()
    triggerLidTask?.cancel()
    triggerMonitor?.stop()
    triggerMonitor = nil
    timer?.invalidate()
    timer = nil
    closedLid.invalidate()
    feedback.stop()
    driveAlive.stop()
    for monitor in downloads.values { monitor.stop() }
    downloads.removeAll()
    engine.quit(reason: historyShutdownReason)
    now = Date()
    recordHistory()
    if !savedForUpdate {
      do { try store.save(engine.snapshot) } catch {
        message = "Couldn't clear saved holds: \(error.localizedDescription)"
      }
    }
    assertions.releaseAll()
  }
  private func allowNewWork() -> Bool {
    guard !stopped, !preparingToQuit, !updater.blocksNewWork else {
      message = "Dilated is finishing an update or quitting."
      onChange?()
      return false
    }
    return true
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
      commit()
      onChange?()
      return error as? WakeError
    }
  }
  @discardableResult private func commit(
    resetClosedLid: Bool = true, saveState: Bool = true
  ) -> Bool {
    now = Date()
    if engine.automationPaused || !settings.triggersEnabled {
      if !armedClosedLidTriggers.isEmpty || armingClosedLidTrigger != nil {
        resetTriggerLidArming()
      }
    }
    let activeIDs = Set(engine.holds.map(\.id))
    for id in Array(downloads.keys) where !activeIDs.contains(id) {
      downloads.removeValue(forKey: id)?.stop()
    }
    if engine.automationPaused {
      triggerMonitor?.stop()
      triggerMonitor = nil
    }
    var saved = true
    if saveState {
      do { try store.save(engine.snapshot) } catch {
        message = "Couldn't save awake state: \(error.localizedDescription)"
        saved = false
      }
    }
    recordHistory()
    let applied = synchronizeAssertions()
    driveAlive.configure(
      settings.driveAlive, awake: applied && !engine.holds.isEmpty, paused: engine.automationPaused)
    if resetClosedLid { queueClosedLidReset() }
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
    updateTriggerLidStatuses()
    if saved && applied { queueTriggerClosedLid() }
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
  private func recordHistory() {
    let events = engine.takeHistoryEvents()
    if events.contains(where: { $0.endReason == .lowBattery || $0.endReason == .lowPowerMode }),
      !armedClosedLidTriggers.isEmpty || armingClosedLidTrigger != nil
    {
      resetTriggerLidArming()
      for hold in engine.holds where hold.source == .trigger {
        engine.setClosedLid(id: hold.id, enabled: false)
      }
    }
    feedback.update(
      settings: settings.feedback, events: events, holds: engine.holds,
      uptime: ProcessInfo.processInfo.systemUptime, baseline: !hasBegun)
    guard historyAvailable else { return }
    let changedRecording = historyWasEnabled != settings.historyEnabled
    if settings.historyEnabled {
      if changedRecording {
        history.receive(engine.holds.map { .init(hold: $0, at: now) }, now: now)
      }
      history.receive(events, now: now)
    } else if changedRecording {
      history.finishActive(at: now, reason: .recordingDisabled)
    }
    historyWasEnabled = settings.historyEnabled
    let completed = events.contains { $0.endReason != nil }
    historyNeedsCompaction = historyNeedsCompaction || changedRecording || completed
    guard
      historyNeedsCompaction || changedRecording || !events.isEmpty
        || (!history.active.isEmpty && now.timeIntervalSince(lastHistoryCheckpoint) >= 20)
    else { return }
    do {
      history = try historyStore.save(
        history, now: now, retentionDays: settings.historyRetentionDays,
        includingRecords: historyNeedsCompaction || changedRecording || completed)
      historyNeedsCompaction = false
      lastHistoryCheckpoint = now
      historyIssue = nil
    } catch { historyIssue = "Couldn't save history: \(error.localizedDescription)" }
  }
  public func clearHistory() {
    now = Date()
    history.clear(at: now)
    historyAvailable = true
    if settings.historyEnabled {
      history.receive(engine.holds.map { .init(hold: $0, at: now) }, now: now)
    }
    historyNeedsCompaction = true
    recordHistory()
    onChange?()
  }
  public func exportHistory() throws -> Data {
    guard historyAvailable else { throw HistoryError(historyIssue ?? "History is unavailable.") }
    return try historyStore.export(history, now: Date())
  }
  private func writeSettings(_ value: AppSettings) throws {
    try FileManager.default.createDirectory(
      at: endpoint.stateDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try JSONEncoder().encode(value).write(to: settingsFile, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: settingsFile.path)
  }
  func startScript(_ options: ScriptStartOptions) async throws -> UUID {
    guard allowNewWork() else { throw InputError(message ?? "Dilated is unavailable.") }
    engine.updatePower(readPower())
    var candidate = engine
    let previous = candidate.holds.filter { $0.source == .appleScript }.map(\.id)
    let duration =
      options.usesDefaultDuration
      ? (settings.defaultMinutes > 0 ? Double(settings.defaultMinutes * 60) : nil)
      : options.duration
    let hold: Hold
    do {
      hold = try candidate.start(
        source: .appleScript, label: "AppleScript", duration: duration,
        displayAwake: !(options.displaySleepAllowed ?? settings.allowDisplaySleep),
        lowPowerOverride: settings.overrideLowPower)
      for id in previous { candidate.stop(id: id, reason: .reconfigured) }
      try store.save(candidate.snapshot)
    } catch {
      commit()
      throw error
    }
    engine = candidate
    guard commit(saveState: false) else {
      throw InputError(message ?? "Couldn't apply awake state.")
    }
    try await synchronizeClosedLid()
    return hold.id
  }
  func scriptClosedLidTarget() throws -> UUID {
    let holds = engine.holds.filter { $0.expiry.map { $0 > Date() } ?? true }
    let own = holds.filter { $0.source == .appleScript }
    if own.count == 1 { return own[0].id }
    if own.isEmpty && holds.count == 1 { return holds[0].id }
    throw InputError(
      "Closed-lid needs an AppleScript hold or exactly one active hold. Supply a hold ID in Shortcuts when several holds are active."
    )
  }
  func setAutomationClosedLid(id: UUID, enabled: Bool) async throws {
    engine.updatePower(readPower())
    commit()
    if enabled {
      if engine.automationPaused { throw WakeError.automationPaused }
      helperInstallation.refreshStatus()
      guard helperInstallation.status == .enabled else {
        throw InputError("Set up and approve the closed-lid helper in Dilated first.")
      }
    }
    try await setClosedLid(id: id, enabled: enabled, allowPrompt: false, requireAutomation: true)
  }
  func setTriggersEnabled(_ enabled: Bool) throws {
    guard allowNewWork() else { throw InputError(message ?? "Dilated is unavailable.") }
    var value = settings
    value.triggersEnabled = enabled
    try applySettings(value)
    reconcileTriggers(lastTriggerInputs)
    refreshTriggers()
    guard commit() else { throw InputError(message ?? "Couldn't apply trigger state.") }
  }
  func setScriptDisplayAwake(_ enabled: Bool) throws {
    guard allowNewWork() else { throw InputError(message ?? "Dilated is unavailable.") }
    engine.updatePower(readPower())
    if engine.holds.isEmpty {
      var value = settings
      value.allowDisplaySleep = !enabled
      try applySettings(value)
    } else {
      for id in engine.holds.map(\.id) { engine.setDisplayAwake(id: id, enabled: enabled) }
    }
    guard commit() else { throw InputError(message ?? "Couldn't apply display sleep state.") }
  }
  func importCustomGlyph(from file: URL) async throws {
    let read = Task.detached(priority: .utility) { try CustomGlyphStore.readInput(file) }
    let data = try await withTaskCancellationHandler {
      try await read.value
    } onCancel: {
      read.cancel()
    }
    try Task.checkCancellation()
    guard allowNewWork() else { throw InputError(message ?? "Dilated is unavailable.") }
    let store = CustomGlyphStore(directory: endpoint.stateDirectory)
    let imported = try store.save(data, name: file.lastPathComponent)
    let old = settings.customGlyph
    var value = settings
    value.customGlyph = imported
    value.useCustomGlyph = true
    do { try applySettings(value) } catch {
      try? store.remove(imported)
      throw error
    }
    customGlyphIssue = nil
    if let old {
      do { try store.remove(old) } catch {
        message =
          "The new icon is saved, but its previous file couldn't be removed: \(error.localizedDescription)"
      }
    }
    onChange?()
  }
  func removeCustomGlyph() throws {
    let old = settings.customGlyph
    var value = settings
    value.customGlyph = nil
    value.useCustomGlyph = false
    try applySettings(value)
    customGlyphIssue = nil
    if let old { try CustomGlyphStore(directory: endpoint.stateDirectory).remove(old) }
    onChange?()
  }
  func enableFeedbackNotifications() async -> Bool {
    guard allowNewWork(), await feedback.requestPermission(), allowNewWork() else { return false }
    var value = settings
    value.feedback.notifications = true
    do {
      try applySettings(value)
      onChange?()
      return true
    } catch {
      message = "Couldn't save notification settings: \(error.localizedDescription)"
      onChange?()
      return false
    }
  }
  func importFeedbackSound(from file: URL, for cue: FeedbackCue) async throws {
    let read = Task.detached(priority: .utility) { try FeedbackSoundStore.readInput(file) }
    let data = try await withTaskCancellationHandler {
      try await read.value
    } onCancel: {
      read.cancel()
    }
    try Task.checkCancellation()
    guard allowNewWork() else { throw InputError(message ?? "Dilated is unavailable.") }
    let store = FeedbackSoundStore(directory: endpoint.stateDirectory)
    let sound = try store.save(data, name: file.lastPathComponent)
    do { try setFeedbackSound(sound, for: cue) } catch {
      if let id = sound.customID { try? store.remove(id) }
      throw error
    }
  }
  func setFeedbackSound(_ sound: FeedbackSound, for cue: FeedbackCue) throws {
    guard allowNewWork() else { throw InputError(message ?? "Dilated is unavailable.") }
    let old = settings.feedback[keyPath: cue.choice]
    var value = settings
    value.feedback[keyPath: cue.choice] = sound
    try applySettings(value)
    if let id = old.customID,
      ![value.feedback.startChoice, value.feedback.endChoice, value.feedback.extendChoice].contains(
        where: { $0.customID == id })
    {
      do { try FeedbackSoundStore(directory: endpoint.stateDirectory).remove(id) } catch {
        message =
          "The new sound is saved, but the previous imported file couldn't be removed: \(error.localizedDescription)"
      }
    }
    onChange?()
  }
  public func assignShortcut(_ shortcut: AwakeShortcut?, to action: ShortcutAction) throws {
    var configuration = settings.shortcuts
    configuration[action] = shortcut
    if let error = ShortcutBindings.validationError(configuration) {
      throw InputError(error)
    }
    var candidate = settings
    candidate.shortcuts = configuration
    try writeSettings(candidate)
    if let issue = onShortcutAssignment?(configuration) {
      do { try writeSettings(settings) } catch {
        throw InputError("\(issue) Couldn't restore saved shortcuts: \(error.localizedDescription)")
      }
      throw InputError(issue)
    }
    settings = candidate
  }
  public func toggleDisplaySleep() {
    guard !engine.holds.isEmpty else {
      message = "Start an awake hold first."
      onChange?()
      return
    }
    let enabled = !engine.desiredState.displayAwake
    mutate { engine in
      for id in engine.holds.map(\.id) { engine.setDisplayAwake(id: id, enabled: enabled) }
    }
  }
  public func armClosedLidTrigger(id: UUID) async throws {
    guard allowNewWork(), armingClosedLidTrigger == nil, !helperInstallation.busy,
      !closedLid.busy, pendingLidRequest == nil
    else {
      throw InputError("Finish the current helper operation before arming a trigger.")
    }
    guard !engine.automationPaused else { throw WakeError.automationPaused }
    guard settings.triggersEnabled,
      let rule = triggerRules.first(where: { $0.id == id }), rule.enabled, rule.closedLid,
      rule.pausedUntil.map({ $0 > Date() }) != true
    else {
      throw InputError("Enable this trigger and its closed-lid option first.")
    }
    helperInstallation.refreshStatus()
    guard helperInstallation.status == .enabled else {
      throw InputError("Set up and approve the closed-lid helper in Dilated first.")
    }
    armingClosedLidTrigger = id
    let revision = triggerLidRevision
    defer {
      armingClosedLidTrigger = nil
      onChange?()
    }
    try confirmClosedLidBatteryWarning(allowPrompt: true)
    try await closedLid.refresh()
    guard !Task.isCancelled, revision == triggerLidRevision, !stopped, !preparingToQuit,
      !updater.blocksNewWork, !engine.automationPaused, settings.triggersEnabled,
      triggerRules.first(where: { $0.id == id }) == rule
    else { throw CancellationError() }
    guard closedLid.state?.ready == true else {
      throw InputError("The helper isn't ready. Check Closed Lid settings before arming a trigger.")
    }
    guard commit() else { throw InputError(message ?? "Couldn't save awake state.") }
    armedClosedLidTriggers.insert(id)
    message = nil
    updateTriggerLidStatuses()
    queueTriggerClosedLid()
    onChange?()
    await triggerLidTask?.value
    guard armedClosedLidTriggers.contains(id) else {
      throw InputError(message ?? "Closed-lid disarmed. Arm this trigger again to continue.")
    }
  }
  public func disarmClosedLidTrigger(id: UUID) async throws {
    resetTriggerLidArming(ids: [id])
    if let holdID = triggerEvaluator.activeHoldIDs[id] {
      engine.setClosedLid(id: holdID, enabled: false)
    }
    let committed = commit()
    try await synchronizeClosedLid()
    if !committed { throw InputError(message ?? "Couldn't save closed-lid state.") }
  }
  private func resetTriggerLidArming(ids: Set<UUID>? = nil) {
    if let ids {
      if ids.isDisjoint(with: armedClosedLidTriggers)
        && armingClosedLidTrigger.map({ !ids.contains($0) }) != false
      {
        return
      }
      armedClosedLidTriggers.subtract(ids)
    } else {
      armedClosedLidTriggers.removeAll()
    }
    triggerLidRevision = UUID()
  }
  private func triggerRuleID(for holdID: UUID) -> UUID? {
    triggerEvaluator.activeHoldIDs.first { $0.value == holdID }?.key
  }
  private var triggerLidCandidates: [UUID] {
    guard !stopped, !preparingToQuit, !updater.blocksNewWork, !engine.automationPaused,
      settings.triggersEnabled
    else { return [] }
    let active = triggerEvaluator.activeHoldIDs
    let pending = Set(engine.holds.filter { $0.closedLid != true }.map(\.id))
    return triggerRules.filter { $0.closedLid && armedClosedLidTriggers.contains($0.id) }
      .compactMap { rule in
        guard let id = active[rule.id], pending.contains(id) else { return nil }
        return id
      }
  }
  private func queueTriggerClosedLid() {
    guard triggerLidTask == nil, lidChange == nil, !closedLid.busy, !helperInstallation.busy,
      pendingLidRequest == nil, !triggerLidCandidates.isEmpty
    else { return }
    let candidates = triggerLidCandidates
    triggerLidTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.triggerLidTask = nil
        self.updateTriggerLidStatuses()
        self.onChange?()
        self.queueTriggerClosedLid()
      }
      for id in candidates {
        guard !Task.isCancelled, self.lidChange == nil, !self.closedLid.busy,
          !self.helperInstallation.busy, self.pendingLidRequest == nil
        else { return }
        guard self.triggerLidCandidates.contains(id) else { continue }
        do {
          try await self.setClosedLid(
            id: id, enabled: true, allowPrompt: false, requireAutomation: true)
        } catch {
          if !self.triggerLidCandidates.contains(id) { continue }
          self.resetTriggerLidArming()
          self.engine.clearClosedLidRequests()
          self.message = "Closed-lid triggers disarmed: \(error.localizedDescription)"
          self.commit()
          return
        }
      }
    }
  }
  private func updateTriggerLidStatuses() {
    let active = triggerEvaluator.activeHoldIDs
    let holds = Dictionary(uniqueKeysWithValues: engine.holds.map { ($0.id, $0) })
    for rule in triggerRules where rule.closedLid {
      guard let id = active[rule.id], let hold = holds[id]
      else { continue }
      let base = triggerEvaluator.statuses[rule.id] ?? "Keeping awake"
      let lid =
        hold.closedLid == true
        ? "closed-lid armed"
        : armedClosedLidTriggers.contains(rule.id)
          ? "closed-lid waiting" : "arm closed-lid to use it"
      triggerStatuses[rule.id] = "\(base); \(lid)"
    }
  }
  public func saveTrigger(_ rule: TriggerRule) throws {
    if let error = rule.validationMessage { throw TriggerConfigurationError(error) }
    var rules = triggerRules
    if let index = rules.firstIndex(where: { $0.id == rule.id }) {
      rules[index] = rule
    } else {
      rules.append(rule)
    }
    guard rules.count <= 100 else { throw TriggerConfigurationError("Keep up to 100 triggers.") }
    try writeTriggers(rules)
    refreshTriggers()
  }
  public func resumeTrigger(id: UUID) {
    guard var rule = triggerRules.first(where: { $0.id == id }) else { return }
    rule.enabled = true
    rule.pausedUntil = nil
    do {
      try saveTrigger(rule)
      triggerEvaluator.resume(id: id, engine: &engine)
      refreshTriggers()
    } catch { message = error.localizedDescription }
  }
  public func removeTrigger(id: UUID) {
    do {
      try writeTriggers(triggerRules.filter { $0.id != id })
      reconcileTriggers(lastTriggerInputs)
      refreshTriggers()
    } catch { message = error.localizedDescription }
  }
  private func writeTriggers(_ rules: [TriggerRule]) throws {
    try FileManager.default.createDirectory(
      at: endpoint.stateDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let file = endpoint.stateDirectory.appendingPathComponent("triggers.json")
    try JSONEncoder().encode(rules).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let updated = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
    let changed = Set(triggerRules.filter { updated[$0.id] != $0 }.map(\.id))
    resetTriggerLidArming(ids: changed)
    let active = triggerEvaluator.activeHoldIDs
    for id in changed.compactMap({ active[$0] }) {
      engine.setClosedLid(id: id, enabled: false)
    }
    triggerRules = rules
  }
  func reconcileTriggers(_ input: TriggerInputs) {
    guard !stopped, !preparingToQuit, !updater.blocksNewWork else { return }
    var input = input
    input.power = readPower()
    lastTriggerInputs = input
    let before = engine.holds
    engine.updatePower(input.power)
    let rules = triggerRules.map { rule in
      var rule = rule
      rule.enabled = rule.enabled && settings.triggersEnabled
      return rule
    }
    triggerEvaluator.reconcile(rules: rules, inputs: input, engine: &engine)
    triggerStatuses = triggerEvaluator.statuses
    if before != engine.holds { commit() }
    updateTriggerLidStatuses()
  }
  private func refreshTriggers() {
    guard hasBegun, !stopped, !preparingToQuit, !updater.blocksNewWork else { return }
    let rules = triggerRules.filter(\.enabled)
    guard !rules.isEmpty, settings.triggersEnabled, !engine.automationPaused else {
      triggerMonitor?.stop()
      triggerMonitor = nil
      reconcileTriggers(lastTriggerInputs)
      return
    }
    if triggerMonitor == nil {
      triggerMonitor = TriggerMonitor(readPower: readPower) { [weak self] in self?.refreshTriggers()
      }
    }
    guard let triggerMonitor else { return }
    triggerMonitor.configure(rules: rules)
    reconcileTriggers(triggerMonitor.read())
    let current = Date()
    let boundary = rules.flatMap { rule -> [Date] in
      var dates = rule.criteria.compactMap { criterion -> Date? in
        if case .schedule(let schedule) = criterion { return schedule.nextBoundary(after: current) }
        return nil
      }
      if let pause = rule.pausedUntil, pause > current { dates.append(pause) }
      return dates
    }.min()
    let deadline = triggerEvaluator.nextEvaluation(now: current)
    triggerMonitor.schedule(at: [boundary, deadline].compactMap { $0 }.min())
  }
  public static func remaining(until date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(ceil(date.timeIntervalSince(now))))
    return seconds >= 3600
      ? "\(seconds / 3600)h \((seconds % 3600) / 60)m"
      : seconds >= 60 ? "\((seconds + 59) / 60)m" : "\(seconds)s"
  }
}

struct TriggerConfigurationError: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}
