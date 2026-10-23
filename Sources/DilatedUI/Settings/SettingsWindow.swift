// Glass window and grouped settings shell adapted from CodesWhat/Mouthtype, Scott Benson, MIT.
import AppKit
import DilatedControl
import DilatedCore
import ServiceManagement
import SwiftUI

@MainActor final class SettingsWindow: NSWindowController, NSWindowDelegate {
  private let model: AppModel
  private var accessibilityObserver: NSObjectProtocol?
  var onClose: (() -> Void)?

  init(model: AppModel) {
    self.model = model
    let window = SettingsNSWindow(
      contentRect: NSRect(origin: .zero, size: SettingsTheme.windowSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = "Dilated Settings"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.contentMinSize = SettingsTheme.minimumSize
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    applyContent()
    window.setContentSize(SettingsTheme.windowSize)
    window.center()
    accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
      queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.applyContent() } }
  }
  required init?(coder: NSCoder) { nil }
  private func applyContent() {
    guard let window else { return }
    let solid = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    let hosting = NSHostingView(
      rootView: SettingsContent(model: model, solid: solid) { [weak self] in self?.close() })
    hosting.sizingOptions = []
    if solid {
      window.backgroundColor = .windowBackgroundColor
      window.contentView = hosting
    } else {
      window.backgroundColor = .clear
      let glass = NSGlassEffectView()
      glass.contentView = hosting
      window.contentView = glass
    }
  }
  func present() {
    showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }
  func windowWillClose(_ notification: Notification) {
    if !model.settings.onboardingComplete { model.settings.onboardingComplete = true }
    onClose?()
  }
  func stop() {
    if let accessibilityObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
    }
    accessibilityObserver = nil
  }
}

final class SettingsNSWindow: NSWindow {
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.type == .keyDown,
      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
      event.charactersIgnoringModifiers?.lowercased() == "w"
    {
      performClose(nil)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
  case overview = "Overview"
  case general = "General"
  case menuBar = "Menu Bar"
  case keepAwake = "Keep Awake"
  case safety = "Battery & Safety"
  case closedLid = "Closed Lid"
  case automation = "Automation"
  case advanced = "Advanced"
  var id: String { rawValue }
  var symbol: String {
    switch self {
    case .overview: "eye"
    case .general: "gearshape"
    case .menuBar: "menubar.rectangle"
    case .keepAwake: "sun.max"
    case .safety: "battery.50percent"
    case .closedLid: "laptopcomputer"
    case .automation: "terminal"
    case .advanced: "wrench.and.screwdriver"
    }
  }
  var detail: String {
    switch self {
    case .overview: "What's keeping your Mac awake, and why."
    case .general: "Make Dilated fit how you work."
    case .menuBar: "A small sign that your Mac is staying awake."
    case .keepAwake: "Choose what happens when you start keeping awake."
    case .safety: "Set limits for battery use and Low Power Mode."
    case .closedLid: "Keep work running with the lid shut, within your safety limits."
    case .automation: "Keep work alive from scripts and agents."
    case .advanced: "Inspect the current state and export diagnostics."
    }
  }
}

@MainActor struct SettingsContent: View {
  @Bindable var model: AppModel
  var solid = false
  var close: () -> Void = {}
  @State private var page: SettingsPage? = .overview
  @State private var presets = ""
  @State private var loginRefresh = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let loginItem = LoginItem()

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 3) {
          if let eyes = Glyph.bugEyes.image(frame: Glyph.bugEyes.stillFrame) {
            Image(nsImage: eyes).resizable().interpolation(.none)
              .frame(width: 44, height: 41).accessibilityHidden(true)
          }
          Text("dilated").font(DesignFont.wordmark(46))
        }
        .foregroundStyle(DesignPalette.sideSelection)
        .padding(.horizontal, 22).padding(.top, 40)
        ScrollView {
          VStack(spacing: 4) {
            ForEach(SettingsPage.allCases) { item in
              Button {
                page = item
              } label: {
                HStack(spacing: 10) {
                  Image(systemName: item.symbol).frame(width: 18)
                  Text(item.rawValue).font(DesignFont.sans(13, .semibold))
                  Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .foregroundStyle(page == item ? Color.white : DesignPalette.sideInk)
                .background(
                  page == item ? DesignPalette.sideSelection : .clear,
                  in: RoundedRectangle(cornerRadius: 4)
                )
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain).help(item.detail)
              .accessibilityAddTraits(page == item ? .isSelected : [])
            }
          }.padding(.horizontal, 12)
        }
        Text("KEEP YOUR WORK AWAKE")
          .font(DesignFont.mono(10)).tracking(0.5).foregroundStyle(DesignPalette.sideInk)
          .padding(.horizontal, 22).padding(.bottom, 22)
      }
      .frame(width: SettingsTheme.sidebarWidth).background(DesignSidebarBackground(solid: solid))
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          if !model.settings.onboardingComplete { welcome }
          Text((page ?? .overview).rawValue.uppercased()).font(DesignFont.heading(34))
          Text((page ?? .overview).detail).foregroundStyle(DesignPalette.ink2).padding(.top, -14)
          if let attention = model.attention {
            Text(attention).fixedSize(horizontal: false, vertical: true).padding(12)
              .frame(maxWidth: .infinity, alignment: .leading).background(
                .quaternary, in: RoundedRectangle(cornerRadius: 10))
          }
          pageContent
        }
        .padding(28).padding(.top, 18).frame(maxWidth: .infinity, alignment: .leading)
      }.background(DesignPalette.bg)
    }
    .font(DesignFont.sans(13)).foregroundStyle(DesignPalette.ink).tint(SettingsTheme.control)
    .frame(minWidth: 860, minHeight: 600)
    .onAppear { presets = model.settings.presets.map(String.init).joined(separator: ", ") }
  }
  private var welcome: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Meet your awake button").font(DesignFont.heading(28))
      Text(
        "Click the eyes in the menu bar to open Dilated. Right-click to start or stop. Pick your look in Menu Bar, or change clicks in General."
      )
      .fixedSize(horizontal: false, vertical: true)
      Button("Get started") {
        model.settings.onboardingComplete = true
        close()
      }.buttonStyle(.borderedProminent)
    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(
      DesignPalette.accentSoft, in: RoundedRectangle(cornerRadius: 4))
  }
  @ViewBuilder private var pageContent: some View {
    switch page ?? .overview {
    case .overview: overview
    case .general: general
    case .menuBar: menuBar
    case .keepAwake: keepAwake
    case .safety: safety
    case .closedLid: ClosedLidSettings(model: model)
    case .automation: automation
    case .advanced: advanced
    }
  }
  private var overview: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsGroup(eyebrow: "RIGHT NOW") {
        SettingsRow(
          title: model.statusText,
          detail: model.engine.automationPaused
            ? "Automation is paused. Manual awake holds still work."
            : "Agents and scripts can request awake holds."
        ) {
          Button(model.engine.holds.isEmpty ? "Keep Awake" : "Stop") { model.toggle() }.buttonStyle(
            .borderedProminent)
        }
        if model.engine.automationPaused {
          SettingsRow(
            title: "Automation paused", detail: "This stays paused across relaunch and reboot."
          ) {
            Button("Resume automation") { model.resumeAutomation() }
          }
        }
      }
      if !model.engine.holds.isEmpty {
        SettingsGroup(eyebrow: "AWAKE REASONS") {
          ForEach(model.engine.holds) { hold in
            SettingsRow(
              title: hold.label,
              detail:
                "\(hold.source.rawValue) · \(hold.expiry.map { AppModel.remaining(until: $0, now: model.now) + " left" } ?? "Indefinite")"
            ) {
              Button("Stop") { model.stop(id: hold.id) }
            }
          }
        }
      }
      Text(
        model.closedLid.active
          ? "Closed-lid is armed. Your Mac will keep working with its lid shut."
          : "Set up the helper in Closed Lid, then enable it for an awake reason."
      )
      .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
  private var general: some View {
    VStack(spacing: 18) {
      SettingsGroup(eyebrow: "STARTUP") {
        SettingsRow(title: "Launch at login", detail: loginDescription) {
          Button(
            loginItem.menuState == .on
              ? "Turn off" : loginItem.menuState == .mixed ? "Open Login Items" : "Turn on"
          ) {
            loginItem.toggle()
            if let error = loginItem.lastError { model.message = error }
            loginRefresh += 1
          }.id(loginRefresh)
        }
        SettingsRow(title: "Keep awake at launch") {
          Toggle("", isOn: $model.settings.startAtLaunch).labelsHidden()
        }
        SettingsRow(
          title: "Keep awake after wake",
          detail: "Respects your automation pause and safety limits."
        ) {
          Toggle("", isOn: $model.settings.startAfterWake).labelsHidden()
        }
      }
      SettingsGroup(eyebrow: "BEHAVIOR") {
        SettingsRow(title: "Show in Dock") {
          Picker("Show in Dock", selection: $model.settings.dockMode) {
            ForEach(DockIconMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
          }.labelsHidden().fixedSize()
        }
        SettingsRow(title: "Menu bar clicks") {
          Picker("Menu bar clicks", selection: $model.settings.swapClicks) {
            Text("Left opens menu").tag(false)
            Text("Right opens menu").tag(true)
          }.labelsHidden().fixedSize()
        }
        SettingsRow(
          title: "Global shortcut",
          detail: "Starts with your default duration, or stops every hold."
        ) {
          Text("⌃⌥⌘D").font(DesignFont.mono(13))
        }
      }
      SettingsGroup(eyebrow: "UPDATES") {
        SettingsRow(title: "App updates", detail: model.updater.statusText) {
          Button("Check for Updates…") { model.updater.checkForUpdates() }
            .disabled(!model.updater.canCheckForUpdates)
        }
        if model.updater.isAvailable {
          SettingsRow(
            title: "Check automatically", detail: "Downloading and installing always asks first."
          ) {
            Toggle(
              "Check automatically",
              isOn: Binding(
                get: { model.updater.automaticallyChecksForUpdates },
                set: { model.updater.setAutomaticChecks($0) }
              )
            ).labelsHidden()
          }
        }
      }
    }
  }
  private var loginDescription: String {
    _ = loginRefresh
    switch SMAppService.mainApp.status {
    case .enabled: return "Enabled."
    case .requiresApproval: return "Waiting for approval in System Settings → Login Items."
    case .notFound: return "Off."
    default: return "Off."
    }
  }
  private var menuBar: some View {
    VStack(spacing: 18) {
      SettingsGroup(eyebrow: "GLYPH") {
        HStack(spacing: 10) {
          ForEach(Glyph.allCases, id: \.rawValue) { glyph in
            Button {
              model.settings.glyph = glyph
            } label: {
              VStack(spacing: 10) {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                  let frame = glyph.frame(
                    awake: true, elapsed: context.date.timeIntervalSinceReferenceDate,
                    motion: model.settings.motion, reduceMotion: reduceMotion)
                  if let image = glyph.image(frame: frame) {
                    Image(nsImage: image).resizable().interpolation(.none).frame(
                      width: 32, height: 30)
                  }
                }
                Text(glyph.label).font(DesignFont.sans(11))
              }.padding(12).frame(maxWidth: .infinity)
                .background(
                  model.settings.glyph == glyph ? DesignPalette.accentSoft : .clear,
                  in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay(
                  RoundedRectangle(cornerRadius: 10).stroke(
                    model.settings.glyph == glyph ? SettingsTheme.control : .clear))
            }.buttonStyle(.plain).accessibilityLabel(glyph.label)
              .accessibilityAddTraits(model.settings.glyph == glyph ? .isSelected : [])
          }
        }.padding(.vertical, 10)
      }
      SettingsGroup(eyebrow: "APPEARANCE") {
        SettingsRow(title: "Animation", detail: "Reduce Motion always uses a still frame.") {
          Picker("Animation", selection: $model.settings.motion) {
            ForEach(Motion.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0) }
          }.labelsHidden().fixedSize()
        }
        SettingsRow(title: "Show time remaining") {
          Toggle("", isOn: $model.settings.countdown).labelsHidden()
        }
        SettingsRow(title: "Dim the glyph when idle") {
          Toggle("", isOn: $model.settings.lowOpacityIdle).labelsHidden()
        }
      }
    }
  }
  private var keepAwake: some View {
    SettingsGroup(eyebrow: "DEFAULTS") {
      SettingsRow(title: "Keep awake for") {
        Picker("Default duration", selection: $model.settings.defaultMinutes) {
          Text("Indefinitely").tag(0)
          ForEach(model.settings.presets, id: \.self) { Text("\($0) minutes").tag($0) }
        }.labelsHidden().fixedSize()
      }
      SettingsRow(
        title: "Allow display sleep", detail: "Your Mac keeps working while the screen sleeps."
      ) {
        Toggle("", isOn: $model.settings.allowDisplaySleep).labelsHidden()
      }
      SettingsRow(
        title: "Duration presets", detail: "Minutes, separated by commas. Press Return to save."
      ) {
        TextField("15, 30, 60", text: $presets).frame(width: 180).onSubmit(savePresets)
      }
    }
  }
  private func savePresets() {
    let parts = presets.split(separator: ",", omittingEmptySubsequences: false)
    let values = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard !values.isEmpty, values.count == parts.count, values.count <= 10,
      values.allSatisfy({ (1...10080).contains($0) })
    else {
      model.message = "Use up to 10 durations between 1 and 10080 minutes."
      return
    }
    model.settings.presets = Array(Set(values)).sorted()
    if model.settings.defaultMinutes != 0
      && !model.settings.presets.contains(model.settings.defaultMinutes)
    {
      model.settings.defaultMinutes = 0
    }
  }
  private var safety: some View {
    SettingsGroup(eyebrow: "POWER") {
      SettingsRow(
        title: "Battery floor",
        detail: "Ends awake holds below this level on battery. Doesn't apply on AC."
      ) {
        Picker("Battery floor", selection: $model.settings.batteryFloor) {
          Text("Off").tag(0)
          ForEach([10, 15, 20, 25, 30, 40, 50], id: \.self) { Text("\($0)%").tag($0) }
        }.labelsHidden().fixedSize()
      }
      SettingsRow(
        title: "Override Low Power Mode",
        detail:
          "New holds can continue in Low Power Mode, including agent work. The battery floor still applies."
      ) {
        Toggle("", isOn: $model.settings.overrideLowPower).labelsHidden()
      }
      SettingsNote(
        text:
          "Low Power Mode ends existing holds unless they were started with an override. Ending a hold doesn't stop the work itself."
      )
    }
  }
  private var automation: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsGroup(eyebrow: "CONTROL") {
        SettingsRow(
          title: "Allow automation links",
          detail: "Allows dilated://awake, dilated://stop and dilated://toggle links."
        ) {
          Toggle("", isOn: $model.settings.urlAutomation).labelsHidden()
        }
        SettingsRow(
          title: "Command line tool",
          detail: "Install into ~/.local/bin. Add that directory to your PATH if needed."
        ) {
          Button("Install command line tool", action: installCLI)
        }
        if model.engine.automationPaused {
          SettingsRow(
            title: "Automation paused", detail: "CLI starts, links and agent renewals are blocked."
          ) {
            Button("Resume automation") { model.resumeAutomation() }
          }
        }
      }
      Text(
        "dilated on --for 2h\ndilated hold --label build --ttl 10m\ndilated hold --id ID --ttl 10m\ndilated release --id ID\ndilated run -- make test\ndilated status --json"
      )
      .font(DesignFont.mono(12)).textSelection(.enabled).padding(16).frame(
        maxWidth: .infinity, alignment: .leading
      )
      .background(DesignPalette.surface, in: RoundedRectangle(cornerRadius: 12))
      Text(
        "Each hold returns its own ID. Renew that ID while the agent works, then release it. Automatic agent setup comes later."
      )
      .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }
  private func installCLI() {
    guard let executable = Bundle.main.executableURL else { return }
    let source = executable.deletingLastPathComponent().appendingPathComponent("dilated")
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      ".local/bin")
    let link = directory.appendingPathComponent("dilated")
    do {
      guard FileManager.default.isExecutableFile(atPath: source.path) else {
        throw InputError("The command line tool isn't available in this copy of Dilated.")
      }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      if let existing = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
        existing == source.path
      {
        model.message = "The command line tool is already installed."
        return
      }
      guard !FileManager.default.fileExists(atPath: link.path),
        (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil
      else {
        throw InputError("A different command already exists at \(link.path).")
      }
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
      model.message = "Installed the command line tool at \(link.path)."
    } catch { model.message = error.localizedDescription }
  }
  private var advanced: some View {
    SettingsGroup(eyebrow: "DIAGNOSTICS") {
      SettingsRow(title: "Active power assertions") {
        Text(model.nativeAssertionTypes.sorted().joined(separator: ", ")).font(DesignFont.mono(11))
          .textSelection(.enabled)
      }
      SettingsRow(title: "Power source") {
        Text(model.engine.power.onBattery ? "Battery" : "Power adapter")
      }
      SettingsRow(title: "Battery") {
        Text(model.engine.power.batteryPercent.map { "\($0)%" } ?? "Not available")
      }
      SettingsRow(
        title: "Export current state",
        detail: "Includes current reason labels and awake state. Review labels before sharing."
      ) {
        Button("Export…", action: exportDiagnostics)
      }
    }
  }
  private func exportDiagnostics() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Dilated-diagnostics.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let response = ControlResponse(
        ok: true, snapshot: model.engine.snapshot, message: model.attention)
      try WireJSON.encode(response).write(to: url, options: .atomic)
    } catch { model.message = error.localizedDescription }
  }
}
