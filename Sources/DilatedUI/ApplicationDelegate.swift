import AppKit
import DilatedControl
import DilatedCore
import IOKit.ps

@MainActor public final class ApplicationDelegate: NSObject, NSApplicationDelegate {
  private var model: AppModel?
  private var server: LocalSocketServer?
  private var menu: MenuBarController?
  private var settings: SettingsWindow?
  private var dock: DockPresence?
  private let shortcuts = GlobalShortcuts()
  private lazy var shortcutBindings = ShortcutBindings(registrar: shortcuts)
  private var powerSource: CFRunLoopSource?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []
  private var started = false
  private var awaitingQuit = false

  public func applicationDidFinishLaunching(_ notification: Notification) {
    installMainMenu()
    FontRegistry.registerBundledFonts()
    let model = AppModel()
    self.model = model
    do {
      server = try LocalSocketServer(endpoint: model.endpoint) { [weak self] request in
        let response = await model.control(request)
        await self?.settings?.dismissSheetForPackage(request, response: response)
        return response
      }
    } catch {
      AutomationService.shared.unavailable()
      let alert = NSAlert()
      alert.messageText = "Dilated couldn't start"
      alert.informativeText = error.localizedDescription
      NSApp.activate()
      alert.runModal()
      NSApp.terminate(nil)
      return
    }
    started = true
    settings = SettingsWindow(model: model)
    menu = MenuBarController(model: model) { [weak self] in self?.showSettings() }
    dock = DockPresence(mode: {
      DockIconMode(rawValue: model.settings.dockMode) ?? .whileWindowOpen
    })
    dock?.start()
    model.onChange = { [weak self] in
      self?.menu?.refresh()
      self?.dock?.refresh()
      self?.refreshShortcuts()
    }
    model.onBatteryOverrideNeeded = { [weak model] duration in
      guard let model else { return }
      let alert = NSAlert()
      alert.messageText = "Start below your battery floor?"
      alert.informativeText =
        "Battery is at \(model.engine.power.batteryPercent ?? 0)%. Start Anyway overrides the floor for this hold only."
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: "Start Anyway")
      NSApp.activate()
      if alert.runModal() == .alertSecondButtonReturn {
        model.start(duration: duration, batteryOverride: true)
      }
    }
    model.onClosedLidBatteryWarning = {
      let alert = NSAlert()
      alert.messageText = "Keep working with the lid closed on battery?"
      alert.informativeText =
        "Keep your Mac ventilated. Don't put it in a bag while it's working. Closed-lid mode replaces macOS sleep protections with Dilated's battery, temperature and time limits."
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: "Enable Closed-Lid")
      NSApp.activate()
      return alert.runModal() == .alertSecondButtonReturn
    }
    model.onShortcutAssignment = { [weak self] configuration in
      guard let self else { return "Dilated is quitting." }
      return self.shortcutBindings.update(configuration) { [weak self] in self?.performShortcut($0)
      }
    }
    refreshShortcuts()
    powerSource = IOPSNotificationCreateRunLoopSource(
      { context in
        guard let context else { return }
        let owner = Unmanaged<ApplicationDelegate>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { owner.model?.refreshPower() }
      }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
    if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
    observe(.NSProcessInfoPowerStateDidChange, center: .default) { model.refreshPower() }
    observe(.NSSystemClockDidChange, center: .default) { model.tick() }
    observe(.NSSystemTimeZoneDidChange, center: .default) { model.tick() }
    observe(NSApplication.didBecomeActiveNotification, center: .default) {
      model.refreshHelperStatus()
    }
    observe(NSWorkspace.willSleepNotification, center: NSWorkspace.shared.notificationCenter) {
      model.handleSystemTransition(.sleep)
    }
    observe(
      NSWorkspace.sessionDidResignActiveNotification, center: NSWorkspace.shared.notificationCenter
    ) {
      model.handleSystemTransition(.userSwitch)
    }
    observe(
      NSWorkspace.sessionDidBecomeActiveNotification, center: NSWorkspace.shared.notificationCenter
    ) {
      model.handleSystemTransition(.userReturn)
    }
    observe(NSWorkspace.didWakeNotification, center: NSWorkspace.shared.notificationCenter) {
      model.refreshPower()
      model.tick()
      if model.settings.startAfterWake { model.automaticStart(label: "After wake") }
    }
    observe(
      NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      center: NSWorkspace.shared.notificationCenter
    ) { [weak self] in self?.menu?.refresh() }
    model.begin()
    AutomationService.shared.bind(model)
    if !model.settings.onboardingComplete || CommandLine.arguments.contains("--settings") {
      showSettings()
    }
  }
  private func installMainMenu() {
    let main = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu(title: "Dilated")
    appMenu.addItem(AwakeMenu.action("About Dilated") { NSApp.orderFrontStandardAboutPanel(nil) })
    appMenu.addItem(AwakeMenu.action("Settings…", key: ",") { [weak self] in self?.showSettings() })
    appMenu.addItem(
      AwakeMenu.action("Check for Updates…") { [weak self] in
        self?.model?.updater.checkForUpdates()
      })
    appMenu.addItem(
      AwakeMenu.action("Open Menu Bar Menu") { [weak self] in self?.menu?.showMenu() })
    appMenu.addItem(.separator())
    appMenu.addItem(AwakeMenu.action("Quit Dilated", key: "q") { NSApp.terminate(nil) })
    appItem.submenu = appMenu
    main.addItem(appItem)
    let editItem = NSMenuItem()
    let edit = NSMenu(title: "Edit")
    for (title, selector, key) in [
      ("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
      ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
    ] {
      edit.addItem(NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key))
    }
    editItem.submenu = edit
    main.addItem(editItem)
    NSApp.mainMenu = main
  }
  private func refreshShortcuts() {
    guard let model else { return }
    if model.shortcutRecording {
      shortcutBindings.suspend()
      return
    }
    if let error = shortcutBindings.update(
      model.settings.shortcuts, action: { [weak self] in self?.performShortcut($0) })
    {
      model.message = error
    }
  }
  private func performShortcut(_ action: ShortcutAction) {
    guard let model else { return }
    switch action {
    case .toggle: model.toggle()
    case .startDefault: model.startDefault()
    case .stop: model.stopAll()
    case .start15: model.start(duration: 900)
    case .start60: model.start(duration: 3600)
    case .toggleDisplay: model.toggleDisplaySleep()
    case .openMenu: menu?.showMenu()
    }
  }
  private func observe(
    _ name: Notification.Name, center: NotificationCenter, action: @escaping @MainActor () -> Void
  ) {
    observers.append(
      (
        center,
        center.addObserver(forName: name, object: nil, queue: .main) { _ in
          MainActor.assumeIsolated { action() }
        }
      ))
  }
  @objc private func showSettings() {
    settings?.present()
    dock?.refresh()
  }
  public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
    -> Bool
  {
    showSettings()
    return true
  }
  public func application(_ application: NSApplication, open urls: [URL]) {
    Task { [weak self] in
      for url in urls { await self?.model?.openURL(url) }
    }
  }
  public func applicationWillTerminate(_ notification: Notification) {
    AutomationService.shared.unavailable()
    guard started else { return }
    model?.shutdown()
    server?.stop()
    shortcutBindings.stop()
    menu?.stop()
    settings?.stop()
    if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
    for (center, observer) in observers { center.removeObserver(observer) }
    observers.removeAll()
  }
  public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard started, let model else { return .terminateNow }
    guard !awaitingQuit else { return .terminateLater }
    awaitingQuit = true
    AutomationService.shared.unavailable()
    Task { [weak self] in
      let safe =
        await (model.updater.blocksNewWork ? model.prepareToUpdate() : model.prepareToQuit())
      self?.awaitingQuit = false
      if !safe { AutomationService.shared.bind(model) }
      if !safe { self?.showSettings() }
      sender.reply(toApplicationShouldTerminate: safe)
    }
    return .terminateLater
  }
}
