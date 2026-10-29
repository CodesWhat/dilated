import AppKit
import DilatedCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct TriggersSettings: View {
  @Bindable var model: AppModel
  @State private var editing: TriggerRule?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsGroup(eyebrow: "AUTOMATION") {
        SettingsRow(
          title: "Enable triggers",
          detail:
            "Turn all triggers on or off while keeping each rule's settings. Stop still pauses automation."
        ) {
          Toggle("Enable triggers", isOn: $model.settings.triggersEnabled).labelsHidden()
        }
        SettingsRow(
          title: model.engine.automationPaused ? "Automation paused" : "Automation running",
          detail: "Stop pauses all automation across relaunch and reboot. Manual timers still work."
        ) {
          if model.engine.automationPaused {
            Button("Resume automation") { model.resumeAutomation() }
          } else {
            Button("Stop") { model.stopAll() }
          }
        }
      }
      ForEach(model.triggerRules) { rule in
        SettingsGroup(eyebrow: rule.name.uppercased()) {
          SettingsRow(
            title: rule.name,
            detail: model.engine.automationPaused
              ? "Automation paused" : model.triggerStatuses[rule.id] ?? "Waiting for conditions"
          ) {
            Toggle(
              "Enable \(rule.name)",
              isOn: Binding(
                get: { rule.enabled }, set: { value in change(rule) { $0.enabled = value } }
              )
            ).labelsHidden()
            Button("Edit") { editing = rule }
            Menu("Pause") {
              Button("5 minutes") {
                change(rule) { $0.pausedUntil = Date().addingTimeInterval(300) }
              }
              Button("1 hour") { change(rule) { $0.pausedUntil = Date().addingTimeInterval(3600) } }
              Button("Until tomorrow") {
                change(rule) {
                  $0.pausedUntil = Calendar.current.date(
                    byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
                }
              }
              Button("Resume this trigger") { model.resumeTrigger(id: rule.id) }
              Button("Turn off") { change(rule) { $0.enabled = false } }
            }.fixedSize()
          }
          ForEach(Array(rule.criteria.enumerated()), id: \.offset) { _, criterion in
            Text(criterion.summary).foregroundStyle(.secondary).fixedSize(
              horizontal: false, vertical: true
            )
            .padding(.vertical, 4)
          }
          if rule.closedLid { TriggerClosedLidControls(model: model, rule: rule) }
        }
      }
      Button("Add trigger…") {
        editing = TriggerRule(name: "New trigger", criteria: [.power(onBattery: false)])
      }
      .buttonStyle(.borderedProminent)
      SettingsNote(
        text:
          "All conditions in a trigger must match. Each matching trigger keeps its own awake reason. Triggers can't wake a sleeping Mac. Closed-lid triggers need explicit arming for this app run. Relaunch, Stop and safety stops require arming again."
      )
    }
    .sheet(item: $editing) { rule in
      TriggerRuleEditor(rule: rule) { edited in
        try model.saveTrigger(edited)
      } remove: {
        model.removeTrigger(id: rule.id)
      }
    }
  }
  private func change(_ rule: TriggerRule, _ update: (inout TriggerRule) -> Void) {
    var edited = rule
    update(&edited)
    do { try model.saveTrigger(edited) } catch { model.message = error.localizedDescription }
  }
}

@MainActor struct TriggerClosedLidControls: View {
  @Bindable var model: AppModel
  var rule: TriggerRule
  private var armed: Bool { model.armedClosedLidTriggers.contains(rule.id) }
  var body: some View {
    SettingsRow(
      title: armed ? "Closed-lid armed for this run" : "Closed-lid automation off",
      detail: "Set up the helper in Closed Lid first. Arming is never saved across relaunch."
    ) {
      Button(armed ? "Disarm closed-lid" : "Arm closed-lid") {
        let disarm = armed
        Task {
          do {
            if disarm {
              try await model.disarmClosedLidTrigger(id: rule.id)
            } else {
              try await model.armClosedLidTrigger(id: rule.id)
            }
          } catch {
            model.message = error.localizedDescription
            model.onChange?()
          }
        }
      }
      .disabled(
        !armed
          && (!rule.enabled || !model.settings.triggersEnabled
            || model.engine.automationPaused || model.armingClosedLidTrigger != nil
            || model.closedLid.busy || model.helperInstallation.busy)
      )
    }
  }
}

@MainActor struct TriggerRuleEditor: View {
  @State var rule: TriggerRule
  @State private var criteria: TriggerCriteriaRows
  var save: (TriggerRule) throws -> Void
  var remove: () -> Void
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss

  init(
    rule: TriggerRule, save: @escaping (TriggerRule) throws -> Void,
    remove: @escaping () -> Void
  ) {
    _rule = State(initialValue: rule)
    _criteria = State(initialValue: TriggerCriteriaRows(rule.criteria))
    self.save = save
    self.remove = remove
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("EDIT TRIGGER").font(DesignFont.heading(28))
      TextField("Name", text: $rule.name)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          ForEach($criteria.rows) { $row in
            VStack(alignment: .leading, spacing: 10) {
              TriggerCriterionEditor(criterion: $row.value)
              Button("Remove condition") { criteria.remove(id: row.id) }
            }.padding(14).background(DesignPalette.surface, in: RoundedRectangle(cornerRadius: 6))
          }
          Button("Add condition") { criteria.append(.power(onBattery: false)) }
            .disabled(!criteria.canAdd)
          Toggle("Keep the display awake", isOn: $rule.displayAwake)
          Toggle("Work with the lid closed", isOn: $rule.closedLid)
          if rule.closedLid {
            Text(
              "Save, then arm closed-lid on this trigger. Stop, relaunch, safety stops and edits disarm it."
            )
            .font(DesignFont.sans(12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
          Toggle("Override Low Power Mode for this trigger", isOn: $rule.lowPowerOverride)
          HStack {
            Text("Dwell before starting (seconds)")
            Spacer()
            TextField("Dwell", value: $rule.dwellSeconds, format: .number).frame(width: 80)
          }
          HStack {
            Text("Grace before ending (seconds)")
            Spacer()
            TextField("Grace", value: $rule.graceSeconds, format: .number).frame(width: 80)
          }
          Text(
            "Battery and closed-lid safety limits still apply. Stop prevents this trigger from restarting until Resume automation."
          )
          .font(DesignFont.sans(12)).foregroundStyle(.secondary).fixedSize(
            horizontal: false, vertical: true)
        }
      }
      if let error {
        Text(error).foregroundStyle(DesignPalette.danger).fixedSize(
          horizontal: false, vertical: true)
      }
      HStack {
        Button("Delete trigger", role: .destructive) {
          remove()
          dismiss()
        }
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save") {
          do {
            var edited = rule
            edited.criteria = criteria.values
            try save(edited)
            dismiss()
          } catch { self.error = error.localizedDescription }
        }.keyboardShortcut(.defaultAction)
      }
    }
    .onChange(of: criteria.values) { old, new in
      rule.criteria = new
      let hadCPU = old.contains {
        if case .cpu = $0 { return true }
        return false
      }
      let hasCPU = new.contains {
        if case .cpu = $0 { return true }
        return false
      }
      if hasCPU && !hadCPU && rule.dwellSeconds == 0 { rule.dwellSeconds = 30 }
    }
    .padding(24).frame(width: 560, height: 600)
    .font(DesignFont.sans(13)).foregroundStyle(DesignPalette.ink).background(DesignPalette.bg)
  }
}

private enum TriggerKind: String, CaseIterable {
  case application = "Application"
  case process = "Process"
  case schedule = "Schedule"
  case power = "Power source"
  case processInstance = "Specific process"
  case mirrored = "Display mirroring"
  case battery = "Battery level"
  case displays = "Displays"
  case network = "IP address or subnet"
  case gateway = "Gateway"
  case dns = "DNS server"
  case wifi = "Wi-Fi network"
  case volume = "Mounted volume"
  case audioOutput = "Audio output"
  case usb = "USB device"
  case bluetooth = "Paired Bluetooth device"
  case cpu = "CPU load"
  case idle = "Idle time"
  var initial: TriggerCriterion {
    switch self {
    case .application: .application(bundleID: "", frontmostOnly: false)
    case .process: .process(name: "")
    case .processInstance: .processInstance(.init(pid: 0, startedAtMicroseconds: 0))
    case .mirrored: .mirrored(true)
    case .schedule: .schedule(.init(weekdays: [2, 3, 4, 5, 6], startMinute: 540, endMinute: 1020))
    case .power: .power(onBattery: false)
    case .battery: .battery(minimum: 20, maximum: 100)
    case .displays: .displays(minimum: 1, maximum: 32, externalOnly: true)
    case .network: .network(address: "")
    case .gateway: .gateway(address: "")
    case .dns: .dns(address: "")
    case .wifi: .wifi(ssid: Data())
    case .volume: .volume(path: "")
    case .audioOutput: .audioOutput(uid: "", name: "")
    case .usb: .usb(device: .init(vendorID: 0, productID: 0), name: "")
    case .bluetooth: .bluetooth(device: nil, name: "")
    case .cpu: .cpu(percent: 20, atLeast: true)
    case .idle: .idle(seconds: 300, atLeast: false)
    }
  }
}

@MainActor private struct TriggerCriterionEditor: View {
  @Binding var criterion: TriggerCriterion
  @State private var processes: [NativeProcess] = []
  @State private var audioOutputs: [NativeAudioOutput] = []
  @State private var usbDevices: [NativeUSBDevice] = []
  private var kind: TriggerKind {
    switch criterion {
    case .application: .application
    case .process: .process
    case .processInstance: .processInstance
    case .mirrored: .mirrored
    case .schedule: .schedule
    case .power: .power
    case .battery: .battery
    case .displays: .displays
    case .network: .network
    case .gateway: .gateway
    case .dns: .dns
    case .wifi: .wifi
    case .volume: .volume
    case .audioOutput: .audioOutput
    case .usb: .usb
    case .bluetooth: .bluetooth
    case .cpu: .cpu
    case .idle: .idle
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker("Condition", selection: Binding(get: { kind }, set: { criterion = $0.initial })) {
        ForEach(TriggerKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      switch criterion {
      case .application(let bundleID, let frontmostOnly):
        HStack {
          TextField(
            "Bundle identifier",
            text: Binding(
              get: { bundleID },
              set: { criterion = .application(bundleID: $0, frontmostOnly: frontmostOnly) }))
          Button("Choose app…") { chooseApplication(frontmostOnly: frontmostOnly) }
        }
        Toggle(
          "Only while frontmost",
          isOn: Binding(
            get: { frontmostOnly },
            set: { criterion = .application(bundleID: bundleID, frontmostOnly: $0) }))
      case .process(let name):
        TextField(
          "Executable name or full path",
          text: Binding(get: { name }, set: { criterion = .process(name: $0) }))
        Text(
          "Exact name, such as make, or a full executable path. Ends when the last matching process exits."
        )
        .font(.caption).foregroundStyle(.secondary)
      case .processInstance(let identity):
        Picker(
          "Process",
          selection: Binding(get: { identity }, set: { criterion = .processInstance($0) })
        ) {
          if !processes.contains(where: { $0.identity == identity }) {
            Text(identity.pid == 0 ? "Choose a process" : "PID \(identity.pid) (ended)").tag(
              identity)
          }
          ForEach(processes) { process in
            Text("\(process.name) (\(process.id))").tag(process.identity)
          }
        }
        Button("Refresh processes") {
          processes = ProcessCatalog.pickerList()
        }
        Text("Tracks this process instance. A future process with the same PID won't match.").font(
          .caption
        ).foregroundStyle(.secondary)
          .onAppear { processes = ProcessCatalog.pickerList() }
      case .mirrored(let mirrored):
        Toggle(
          "Displays are mirrored",
          isOn: Binding(get: { mirrored }, set: { criterion = .mirrored($0) }))
      case .power(let onBattery):
        Picker(
          "Source",
          selection: Binding(get: { onBattery }, set: { criterion = .power(onBattery: $0) })
        ) {
          Text("Power adapter").tag(false)
          Text("Battery").tag(true)
        }
      case .battery(let minimum, let maximum):
        Stepper(
          "At least \(minimum)%",
          value: Binding(
            get: { minimum }, set: { criterion = .battery(minimum: $0, maximum: max($0, maximum)) }),
          in: 0...100)
        Stepper(
          "At most \(maximum)%",
          value: Binding(
            get: { maximum }, set: { criterion = .battery(minimum: min(minimum, $0), maximum: $0) }),
          in: 0...100)
      case .displays(let minimum, let maximum, let externalOnly):
        Stepper(
          "At least \(minimum)",
          value: Binding(
            get: { minimum },
            set: {
              criterion = .displays(
                minimum: $0, maximum: max($0, maximum), externalOnly: externalOnly)
            }), in: 0...32)
        Stepper(
          "At most \(maximum)",
          value: Binding(
            get: { maximum },
            set: {
              criterion = .displays(
                minimum: min(minimum, $0), maximum: $0, externalOnly: externalOnly)
            }), in: 0...32)
        Toggle(
          "Ignore built-in display",
          isOn: Binding(
            get: { externalOnly },
            set: { criterion = .displays(minimum: minimum, maximum: maximum, externalOnly: $0) }))
      case .volume(let path):
        TextField(
          "Mount path", text: Binding(get: { path }, set: { criterion = .volume(path: $0) }))
        Menu("Choose mounted volume") {
          let paths = NativeActivityInputs.mountedVolumes()?.sorted() ?? []
          if paths.isEmpty { Text("No mounted volumes available") }
          ForEach(paths, id: \.self) { path in
            Button(path) { criterion = .volume(path: path) }
          }
        }
        Text(
          "Matches the exact mount path, including a disk image or network volume. Doesn't read or write its files."
        ).font(.caption).foregroundStyle(.secondary)
      case .audioOutput(let uid, let name):
        Picker(
          "Sound output",
          selection: Binding(
            get: { uid },
            set: { selected in
              if let output = audioOutputs.first(where: { $0.uid == selected }) {
                criterion = .audioOutput(uid: output.uid, name: output.name)
              }
            })
        ) {
          if !audioOutputs.contains(where: { $0.uid == uid }) {
            Text(uid.isEmpty ? "Choose an output" : "\(name) (unavailable)").tag(uid)
          }
          ForEach(audioOutputs) { output in Text(output.name).tag(output.uid) }
        }
        Button("Refresh outputs") { audioOutputs = AudioOutputCatalog.read() ?? [] }
        Text("Matches the Mac’s selected sound output. It doesn’t require audio to be playing.")
          .font(.caption).foregroundStyle(.secondary)
          .onAppear { audioOutputs = AudioOutputCatalog.read() ?? [] }
      case .usb(let device, let name):
        Picker(
          "USB device",
          selection: Binding(
            get: { device },
            set: { selected in
              if let connected = usbDevices.first(where: { $0.identity == selected }) {
                criterion = .usb(device: connected.identity, name: connected.name)
              }
            })
        ) {
          if !usbDevices.contains(where: { $0.identity == device }) {
            Text(device.isValid ? "\(name) (not connected)" : "Choose a USB device").tag(device)
          }
          ForEach(usbDevices) { connected in Text(connected.label).tag(connected.identity) }
        }
        Button("Refresh devices") { usbDevices = USBDeviceCatalog.read() ?? [] }
        Text(
          device.serialNumber == nil
            ? "Without a serial number, this matches any connected device of the same model."
            : "Matches this device by its serial number, including after reconnecting to another port."
        ).font(.caption).foregroundStyle(.secondary)
          .onAppear { usbDevices = USBDeviceCatalog.read() ?? [] }
      case .cpu(let percent, let atLeast):
        Picker(
          "CPU load",
          selection: Binding(
            get: { atLeast }, set: { criterion = .cpu(percent: percent, atLeast: $0) })
        ) {
          Text("At least").tag(true)
          Text("At most").tag(false)
        }
        Stepper(
          "\(percent)%",
          value: Binding(
            get: { percent }, set: { criterion = .cpu(percent: $0, atLeast: atLeast) }), in: 0...100
        )
        Text(
          "System-wide CPU use, sampled every five seconds. Use 30 seconds of dwell to avoid short spikes."
        ).font(.caption).foregroundStyle(.secondary)
      case .idle(let seconds, let atLeast):
        Picker(
          "Idle time",
          selection: Binding(
            get: { atLeast }, set: { criterion = .idle(seconds: seconds, atLeast: $0) })
        ) {
          Text("At least").tag(true)
          Text("At most").tag(false)
        }
        HStack {
          Text("Minutes since last input")
          TextField(
            "Minutes",
            value: Binding(
              get: { seconds / 60 }, set: { criterion = .idle(seconds: $0 * 60, atLeast: atLeast) }),
            format: .number
          ).frame(width: 100)
        }
        Text(
          "Quartz session idle time, checked every five seconds. This reads elapsed time without recording input or changing presence."
        ).font(.caption).foregroundStyle(.secondary)
      case .schedule(let schedule):
        scheduleEditor(schedule)
      case .wifi(let ssid):
        WiFiConditionEditor(
          ssid: Binding(get: { ssid }, set: { criterion = .wifi(ssid: $0) }))
      case .bluetooth(let device, let name):
        BluetoothConditionEditor(device: device, name: name) { selected in
          criterion = .bluetooth(device: selected.id, name: selected.name)
        }
      case .network(let address), .gateway(let address), .dns(let address):
        TextField(
          "IPv4, IPv6 or CIDR range",
          text: Binding(
            get: { address },
            set: { value in
              switch kind {
              case .gateway: criterion = .gateway(address: value)
              case .dns: criterion = .dns(address: value)
              default: criterion = .network(address: value)
              }
            }))
        Text("Uses network configuration without Location permission.").font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
  private func scheduleEditor(_ schedule: WeeklySchedule) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        ForEach(1...7, id: \.self) { day in
          Toggle(
            Calendar.current.shortWeekdaySymbols[day - 1],
            isOn: Binding(
              get: { schedule.weekdays.contains(day) },
              set: { selected in
                var edited = schedule
                if selected { edited.weekdays.insert(day) } else { edited.weekdays.remove(day) }
                criterion = .schedule(edited)
              }
            )
          ).toggleStyle(.button)
        }
      }
      DatePicker(
        "From", selection: minuteBinding(schedule, start: true), displayedComponents: .hourAndMinute
      )
      DatePicker(
        "Until", selection: minuteBinding(schedule, start: false),
        displayedComponents: .hourAndMinute)
      Text("Overnight windows finish the following day. Equal times mean the whole selected day.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
  private func minuteBinding(_ schedule: WeeklySchedule, start: Bool) -> Binding<Date> {
    Binding(
      get: {
        let minute = start ? schedule.startMinute : schedule.endMinute
        return Calendar.current.date(
          bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
      },
      set: { date in
        var edited = schedule
        let minute =
          Calendar.current.component(.hour, from: date) * 60
          + Calendar.current.component(.minute, from: date)
        if start { edited.startMinute = minute } else { edited.endMinute = minute }
        criterion = .schedule(edited)
      })
  }
  private func chooseApplication(frontmostOnly: Bool) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.applicationBundle]
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier
    else { return }
    criterion = .application(bundleID: id, frontmostOnly: frontmostOnly)
  }
}

extension TriggerCriterion {
  var summary: String {
    switch self {
    case .application(let bundleID, let frontmost):
      "\(bundleID) is \(frontmost ? "frontmost" : "running")"
    case .process(let name): "\(name) is running"
    case .processInstance(let identity): "Process \(identity.pid) is running"
    case .mirrored(let mirrored): mirrored ? "Displays are mirrored" : "Displays are not mirrored"
    case .schedule(let schedule):
      "Schedule: \(schedule.weekdays.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")) · \(Self.time(schedule.startMinute))–\(Self.time(schedule.endMinute))"
    case .power(let onBattery): onBattery ? "On battery" : "Power adapter connected"
    case .battery(let minimum, let maximum): "Battery \(minimum)–\(maximum)%"
    case .displays(let minimum, let maximum, let external):
      "\(minimum)–\(maximum) \(external ? "external " : "")displays"
    case .network(let address): "IP address in \(address)"
    case .gateway(let address): "Gateway in \(address)"
    case .dns(let address): "DNS server in \(address)"
    case .wifi(let ssid): "Wi-Fi network is \(WiFiSSID.label(ssid))"
    case .volume(let path): "Volume mounted at \(path)"
    case .audioOutput(_, let name): "Sound output is \(name)"
    case .usb(let device, let name):
      "USB connected: \(name)" + (device.serialNumber == nil ? " (any matching model)" : "")
    case .bluetooth(_, let name): "Paired Bluetooth connected: \(name)"
    case .cpu(let percent, let atLeast): "CPU use \(atLeast ? "at least" : "at most") \(percent)%"
    case .idle(let seconds, let atLeast):
      "Idle \(atLeast ? "at least" : "at most") \(seconds / 60) minutes"
    }
  }
  private static func time(_ minute: Int) -> String {
    String(format: "%02d:%02d", minute / 60, minute % 60)
  }
}
