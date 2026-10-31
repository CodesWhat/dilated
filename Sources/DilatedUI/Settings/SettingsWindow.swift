// Glass window and grouped settings shell adapted from CodesWhat/Mouthtype, Scott Benson, MIT.
import AppKit
import DilatedControl
import DilatedCore
import ServiceManagement
import SwiftUI

@MainActor final class SettingsWindow: NSWindowController, NSWindowDelegate {
  private let model: AppModel
  private let hosting: NSHostingView<SettingsContent>
  private var glass: NSGlassEffectView?
  private var solid: Bool?
  private var accessibilityObserver: NSObjectProtocol?
  var onClose: (() -> Void)?

  init(model: AppModel) {
    self.model = model
    hosting = NSHostingView(rootView: SettingsContent(model: model, solid: false) {})
    hosting.sizingOptions = []
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
    applyContent(solid: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    window.setContentSize(SettingsTheme.windowSize)
    window.center()
    accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.applyContent(
          solid: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
      }
    }
  }
  required init?(coder: NSCoder) { nil }
  var hostingViewForTesting: NSView { hosting }
  func applyContent(solid: Bool) {
    guard let window, solid != self.solid else { return }
    self.solid = solid
    hosting.rootView = SettingsContent(model: model, solid: solid) { [weak self] in self?.close() }
    if solid {
      glass?.contentView = nil
      window.backgroundColor = .windowBackgroundColor
      window.contentView = hosting
    } else {
      window.backgroundColor = .clear
      let glass = self.glass ?? NSGlassEffectView()
      self.glass = glass
      window.contentView = glass
      glass.contentView = hosting
    }
  }
  func dismissSheetForPackage(_ request: ControlRequest, response: ControlResponse) {
    guard response.ok, request.action == .prepareUpdate || request.action == .prepareUninstall,
      let window, let sheet = window.attachedSheet
    else { return }
    window.endSheet(sheet, returnCode: .cancel)
  }

  func present() {
    showWindow(nil)
    NSApp.activate()
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
  case hotKeys = "Hot Keys"
  case triggers = "Triggers"
  case driveAlive = "Drive Alive"
  case notifications = "Notifications & Sounds"
  case statistics = "Statistics"
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
    case .hotKeys: "command"
    case .triggers: "switch.2"
    case .driveAlive: "externaldrive"
    case .notifications: "bell"
    case .statistics: "chart.bar"
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
    case .hotKeys: "Assign shortcuts to your awake controls."
    case .triggers: "Keep awake while your conditions match."
    case .driveAlive: "Keep selected drives active with small periodic writes."
    case .notifications: "Choose when Dilated speaks up."
    case .statistics: "Recent awake reasons, end causes and local totals."
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
  @FocusState private var focusedPage: SettingsPage?
  @State private var presets = ""
  @FocusState private var presetsFocused: Bool
  @State private var loginRefresh = 0
  @State private var cliRefresh = 0
  @State private var confirmSettingsReset = false
  @State private var recoveryError: String?
  @State private var recoveryNote: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let loginItem = LoginItem()
  private let cliInstallation = CommandLineInstallation()

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 10) {
          if let eyes = Glyph.bugEyes.image(frame: Glyph.bugEyes.stillFrame) {
            Image(nsImage: eyes).resizable().interpolation(.none)
              .frame(width: 36, height: 34).accessibilityHidden(true)
          }
          Text("dilated").font(DesignFont.wordmark(38)).fixedSize()
        }
        .foregroundStyle(DesignPalette.sideSelection)
        .padding(.horizontal, 22).padding(.top, 8)
        ScrollView {
          VStack(spacing: 4) {
            ForEach(SettingsPage.allCases) { item in
              Button {
                page = item
                focusedPage = item
              } label: {
                HStack(spacing: 10) {
                  Image(systemName: item.symbol).frame(width: 18).accessibilityHidden(true)
                  Text(item.rawValue).font(DesignFont.sans(13, .semibold))
                  Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .foregroundStyle(page == item ? Color.primary : DesignPalette.sideInk)
                .background(
                  page == item ? Color.primary.opacity(0.10) : .clear,
                  in: RoundedRectangle(cornerRadius: 4)
                )
                .overlay {
                  RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(
                      focusedPage == item && page != item
                        ? Color.primary.opacity(0.35) : .clear, lineWidth: 1)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain).focusEffectDisabled().help(item.detail)
              .focused($focusedPage, equals: item)
              .accessibilityLabel(item.rawValue)
              .accessibilityAddTraits(page == item ? .isSelected : [])
            }
          }.padding(.horizontal, 12)
            .onMoveCommand { direction in
              guard direction == .up || direction == .down else { return }
              let pages = SettingsPage.allCases
              let index = pages.firstIndex(of: focusedPage ?? page ?? .overview) ?? 0
              let next = pages[max(0, min(pages.count - 1, index + (direction == .down ? 1 : -1)))]
              page = next
              focusedPage = next
            }
        }
        Spacer(minLength: 0).frame(height: 14)
      }
      .frame(width: SettingsTheme.sidebarWidth).background(DesignSidebarBackground(solid: solid))
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          if !model.settings.onboardingComplete, model.settingsRecoveryIssue == nil { welcome }
          Text((page ?? .overview).rawValue.uppercased()).font(DesignFont.heading(34))
          Text((page ?? .overview).detail).foregroundStyle(DesignPalette.ink2).padding(.top, -14)
          if model.settingsRecoveryIssue != nil {
            settingsRecovery
          } else {
            if let recoveryNote {
              Text(recoveryNote).textSelection(.enabled).fixedSize(
                horizontal: false, vertical: true)
            }
            if let attention = model.attention {
              Text(attention).fixedSize(horizontal: false, vertical: true).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading).background(
                  .quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            pageContent
          }
        }
        .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
      }.background(DesignPalette.bg)
    }
    .font(DesignFont.sans(13)).foregroundStyle(DesignPalette.ink).tint(SettingsTheme.control)
    .frame(minWidth: 860, minHeight: 600)
    .onAppear { presets = AppModel.presetsText(model.settings.presets) }
    .onChange(of: model.settings.presets) { _, saved in
      if !presetsFocused { presets = AppModel.presetsText(saved) }
    }
    .onChange(of: presetsFocused) { _, focused in
      guard !focused else { return }
      if presets != AppModel.presetsText(model.settings.presets) {
        commitPresets()
      } else {
        model.clearPresetsError()
      }
    }
  }
  private var settingsRecovery: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Settings couldn't be read").font(DesignFont.heading(26))
      Text(
        "No saved timers were restored. Holds and automation stay off until you recover settings, so unreadable battery and safety preferences can't be bypassed."
      ).fixedSize(horizontal: false, vertical: true)
      Text(model.settingsRecoveryIssue ?? "").foregroundStyle(DesignPalette.ink2)
        .fixedSize(horizontal: false, vertical: true)
      if let message = model.message, !message.hasPrefix("Couldn't read settings:") {
        Text(message).fixedSize(horizontal: false, vertical: true)
      }
      Text(
        "Reset saves a private copy of the unreadable file and restores defaults. Triggers and history are kept. Automation stays paused until you resume it."
      ).fixedSize(horizontal: false, vertical: true)
      if let recoveryError { Text(recoveryError).fixedSize(horizontal: false, vertical: true) }
      Button("Reset unreadable settings…") { confirmSettingsReset = true }
        .buttonStyle(.borderedProminent)
        .alert("Reset unreadable settings?", isPresented: $confirmSettingsReset) {
          Button("Reset settings", role: .destructive) {
            do {
              let backup = try model.resetUnreadableSettings()
              recoveryError = nil
              recoveryNote =
                "Settings reset. Automation is paused. Previous settings: \(backup.path)"
            } catch { recoveryError = error.localizedDescription }
          }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text(
            "Your previous file will be saved privately before defaults are written. Saved timers won't restart. Review Battery & Safety before starting another hold."
          )
        }
    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
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
      Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
  }
  @ViewBuilder private var pageContent: some View {
    switch page ?? .overview {
    case .overview: overview
    case .general: general
    case .menuBar: menuBar
    case .keepAwake: keepAwake
    case .safety: safety
    case .closedLid: ClosedLidSettings(model: model)
    case .hotKeys: ShortcutsSettings(model: model)
    case .triggers: TriggersSettings(model: model)
    case .driveAlive: DriveAliveSettingsView(model: model)
    case .notifications: FeedbackSettingsView(model: model)
    case .statistics: HistorySettings(model: model)
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
          Toggle("Keep awake at launch", isOn: $model.settings.startAtLaunch).labelsHidden()
        }
        SettingsRow(
          title: "Keep awake after wake",
          detail: "Respects your automation pause and safety limits."
        ) {
          Toggle("Keep awake after wake", isOn: $model.settings.startAfterWake).labelsHidden()
            .accessibilityHint("Respects your automation pause and safety limits.")
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
          detail: "Starts with your default duration, or stops every hold. Change it in Hot Keys."
        ) {
          Text(model.settings.shortcuts[.toggle]?.displayName ?? "Not assigned").font(
            DesignFont.mono(13))
        }
      }
      SettingsGroup(eyebrow: "SLEEP & USER SWITCHING") {
        SettingsRow(
          title: "Stop when the Mac sleeps",
          detail:
            "Ends all holds and pauses automation until Resume. Applies to every system sleep."
        ) {
          Toggle("Stop when the Mac sleeps", isOn: $model.settings.stopOnSystemSleep).labelsHidden()
            .accessibilityHint(
              "Ends all holds and pauses automation until Resume. Applies to every system sleep.")
        }
        SettingsRow(
          title: "Stop when switching users",
          detail: "Ends all holds and pauses automation."
        ) {
          Toggle("Stop when switching users", isOn: $model.settings.stopOnUserSwitch).labelsHidden()
            .accessibilityHint("Ends all holds and pauses automation.")
        }
        SettingsRow(
          title: "Resume when you return",
          detail:
            "Restores the holds that were running when you switched away, with their original deadlines, and re-checks triggers. Closed-lid is never restored."
        ) {
          Toggle("Resume when you return", isOn: $model.settings.resumeOnUserReturn).labelsHidden()
            .accessibilityHint(
              "Restores the holds that were running when you switched away, with their original deadlines, and re-checks triggers. Closed-lid is never restored."
            )
            .disabled(!model.settings.stopOnUserSwitch)
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
              var settings = model.settings
              settings.glyph = glyph
              settings.useCustomGlyph = false
              model.settings = settings
            } label: {
              VStack(spacing: 10) {
                if !reduceMotion {
                  TimelineView(.periodic(from: .now, by: 0.75)) { context in
                    let frame = glyph.previewFrame(
                      elapsed: context.date.timeIntervalSinceReferenceDate,
                      reduceMotion: reduceMotion)
                    if let image = glyph.image(frame: frame) {
                      Image(nsImage: image).resizable().interpolation(.none).frame(
                        width: 32, height: 30)
                    }
                  }
                } else if let image = glyph.image(frame: glyph.stillFrame) {
                  Image(nsImage: image).resizable().interpolation(.none).frame(
                    width: 32, height: 30)
                }
                Text(glyph.label).font(DesignFont.sans(11))
              }.padding(12).frame(maxWidth: .infinity)
                .background(
                  !model.settings.useCustomGlyph && model.settings.glyph == glyph
                    ? Color.primary.opacity(0.08) : .clear,
                  in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay(
                  RoundedRectangle(cornerRadius: 10).stroke(
                    !model.settings.useCustomGlyph && model.settings.glyph == glyph
                      ? SettingsTheme.control : .clear))
            }.buttonStyle(.plain).accessibilityLabel(glyph.label)
              .accessibilityAddTraits(
                !model.settings.useCustomGlyph && model.settings.glyph == glyph ? .isSelected : [])
          }
        }.padding(.vertical, 10)
      }
      CustomGlyphSettingsView(model: model)
      SettingsGroup(eyebrow: "APPEARANCE") {
        SettingsRow(
          title: "Animation",
          detail: "Custom and Cat cans icons stay still. Reduce Motion always uses a still frame."
        ) {
          Picker("Animation", selection: $model.settings.motion) {
            ForEach(Motion.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0) }
          }.labelsHidden().fixedSize().disabled(
            model.settings.useCustomGlyph || model.settings.glyph == .catCans)
        }
        SettingsRow(title: "Show session time") {
          Toggle("Show session time", isOn: $model.settings.countdown).labelsHidden()
        }
        SettingsRow(title: "Time format") {
          Picker("Time format", selection: $model.settings.countdownFormat) {
            ForEach(CountdownFormat.allCases, id: \.rawValue) {
              Text($0.label(seconds: model.settings.countdownSeconds)).tag($0)
            }
          }.labelsHidden().fixedSize().disabled(!model.settings.countdown)
        }
        SettingsRow(
          title: "Seconds",
          detail:
            "Format default preserves the usual display. Clock without seconds uses hours:minutes."
        ) {
          Picker("Seconds", selection: $model.settings.countdownSeconds) {
            ForEach(CountdownSeconds.allCases, id: \.rawValue) { Text($0.label).tag($0) }
          }.labelsHidden().fixedSize().disabled(!model.settings.countdown)
        }
        SettingsRow(
          title: "End-time clock", detail: "Only changes end time, not countdown durations."
        ) {
          Picker("End-time clock", selection: $model.settings.countdownHourCycle) {
            ForEach(CountdownHourCycle.allCases, id: \.rawValue) { Text($0.label).tag($0) }
          }.labelsHidden().fixedSize().disabled(
            !model.settings.countdown || model.settings.countdownFormat != .endTime)
        }
        SettingsRow(title: "Time text size", detail: "Time beside the menu bar icon.") {
          Picker("Time text size", selection: $model.settings.countdownTextSize) {
            ForEach(CountdownTextSize.allCases, id: \.rawValue) { Text($0.label).tag($0) }
          }.labelsHidden().fixedSize().disabled(!model.settings.countdown)
        }
        SettingsRow(title: "Dim the glyph when idle") {
          Toggle(
            "Dim the glyph when idle",
            isOn: Binding(
              get: {
                model.settings.useCustomGlyph
                  ? model.settings.customGlyphDimIdle : model.settings.lowOpacityIdle
              },
              set: { value in
                if model.settings.useCustomGlyph {
                  model.settings.customGlyphDimIdle = value
                } else {
                  model.settings.lowOpacityIdle = value
                }
              })
          ).labelsHidden()
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
        Toggle("Allow display sleep", isOn: $model.settings.allowDisplaySleep).labelsHidden()
          .accessibilityHint("Your Mac keeps working while the screen sleeps.")
      }
      SettingsRow(
        title: "Duration presets",
        detail: "Minutes, separated by commas. Saved when you press Return or leave the field."
      ) {
        TextField("15, 30, 60", text: $presets).frame(width: 180)
          .focused($presetsFocused)
          .onSubmit(commitPresets)
      }
    }
  }
  private func commitPresets() {
    if model.applyPresets(text: presets) {
      presets = AppModel.presetsText(model.settings.presets)
    }
  }
  private var safety: some View {
    SettingsGroup(eyebrow: "POWER") {
      SettingsRow(
        title: "Battery floor",
        detail: "Ends awake holds below this level. Start Anyway overrides it for one hold."
      ) {
        Picker("Battery floor", selection: $model.settings.batteryFloor) {
          Text("Off").tag(0)
          ForEach([10, 15, 20, 25, 30, 40, 50], id: \.self) { Text("\($0)%").tag($0) }
        }.labelsHidden().fixedSize()
      }
      SettingsRow(
        title: "Ignore battery floor on AC",
        detail:
          "Allows holds below the floor while connected to power. Closed-lid limits are separate."
      ) {
        Toggle("Ignore battery floor on AC", isOn: $model.settings.batteryFloorIgnoresAC)
          .labelsHidden().accessibilityHint(
            "Allows holds below the floor while connected to power. Closed-lid limits are separate."
          )
          .disabled(model.settings.batteryFloor == 0)
      }
      SettingsRow(
        title: "Override Low Power Mode",
        detail:
          "New holds can continue in Low Power Mode, including agent work. The battery floor still applies."
      ) {
        Toggle("Override Low Power Mode", isOn: $model.settings.overrideLowPower).labelsHidden()
          .accessibilityHint(
            "New holds can continue in Low Power Mode, including agent work. The battery floor still applies."
          )
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
          Toggle("Allow automation links", isOn: $model.settings.urlAutomation).labelsHidden()
            .accessibilityHint("Allows dilated://awake, dilated://stop and dilated://toggle links.")
        }
        SettingsRow(
          title: "Command line tool",
          detail: "Install into ~/.local/bin. Add that directory to your PATH if needed."
        ) {
          Button(
            cliInstallation.isInstalled ? "Remove command line tool" : "Install command line tool",
            action: changeCLIInstallation
          ).id(cliRefresh)
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
  private func changeCLIInstallation() {
    do {
      model.message =
        try cliInstallation.isInstalled
        ? cliInstallation.remove() : cliInstallation.install()
    } catch { model.message = error.localizedDescription }
    cliRefresh += 1
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
