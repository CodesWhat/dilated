import SwiftUI

@MainActor struct DriveAliveSettingsView: View {
  @Bindable var model: AppModel
  @State private var mounted: [MountedDrive] = []
  @State private var issue: String?
  @State private var refreshing = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsGroup(
        eyebrow: "DRIVE ALIVE",
        footer:
          "Stop pauses Drive Alive until Resume automation. It doesn't wake a sleeping Mac or create an awake hold. A drive's own power settings may still take precedence."
      ) {
        SettingsRow(
          title: "Enable Drive Alive",
          detail: "Write a few bytes to the selected volumes, then remove the temporary file."
        ) {
          Toggle("Enable Drive Alive", isOn: $model.settings.driveAlive.enabled).labelsHidden()
            .accessibilityHint(
              "Write a few bytes to the selected volumes, then remove the temporary file.")
        }
        SettingsRow(title: "Write interval") {
          Stepper(value: $model.settings.driveAlive.intervalSeconds, in: 30...3600, step: 30) {
            Text("\(model.settings.driveAlive.intervalSeconds) seconds").monospacedDigit()
          }.frame(width: 170)
        }
        SettingsRow(title: "Default for volumes", detail: "Each selected volume can override this.")
        {
          Picker("When to write", selection: $model.settings.driveAlive.onlyWhileAwake) {
            Text("While Dilated keeps awake").tag(true)
            Text("Always while Dilated is open").tag(false)
          }.labelsHidden().frame(maxWidth: 260)
        }
      }
      if let validation = model.settings.driveAlive.validationMessage {
        SettingsNote(text: validation, tone: DesignPalette.danger)
      }
      if model.engine.automationPaused && model.settings.driveAlive.enabled {
        SettingsNote(text: "Paused until you choose Resume automation.")
      }
      SettingsGroup(
        eyebrow: "VOLUMES",
        footer:
          "Only selected mounted volumes are written to. Removed or read-only volumes are left alone. The volume root must be writable by your account."
      ) {
        HStack {
          Text("Choose volumes").font(DesignFont.sans(13, .semibold))
          Spacer()
          Button("Refresh") { Task { await refresh() } }.disabled(refreshing)
        }
        if let issue { SettingsNote(text: issue, tone: DesignPalette.danger) }
        if mounted.isEmpty && issue == nil {
          SettingsNote(text: refreshing ? "Reading volumes…" : "No volumes available.")
        }
        ForEach(mounted, id: \.volume.path) { drive in
          SettingsRow(
            title: drive.volume.name,
            detail: drive.volume.path + "\n" + status(for: drive)
          ) {
            if selected(drive.volume.id) { modePicker(for: drive.volume) }
            Toggle("Use \(drive.volume.name)", isOn: binding(for: drive.volume))
              .labelsHidden().disabled(
                (drive.readOnly || ambiguous(drive.volume.id)) && !selected(drive.volume.id))
          }
        }
        ForEach(
          model.settings.driveAlive.volumes.filter { saved in
            !mounted.contains { $0.volume.id == saved.id }
          }
        ) { saved in
          SettingsRow(title: saved.name, detail: "Not mounted. No writes.") {
            modePicker(for: saved)
            Toggle("Use \(saved.name)", isOn: binding(for: saved)).labelsHidden()
          }
        }
      }
    }.task { await refresh() }
  }

  private func selected(_ id: String) -> Bool {
    model.settings.driveAlive.volumes.contains { $0.id == id }
  }
  private func binding(for volume: DriveAliveVolume) -> Binding<Bool> {
    Binding(
      get: { selected(volume.id) },
      set: { enabled in
        var settings = model.settings.driveAlive
        settings.volumes.removeAll { $0.id == volume.id }
        if enabled { settings.volumes.append(volume) }
        model.settings.driveAlive = settings
      })
  }
  private func modePicker(for volume: DriveAliveVolume) -> some View {
    Picker(
      "When to write to \(volume.name)",
      selection: Binding(
        get: { model.settings.driveAlive.volumes.first { $0.id == volume.id }?.mode ?? .inherit },
        set: { mode in
          var settings = model.settings.driveAlive
          guard let index = settings.volumes.firstIndex(where: { $0.id == volume.id }) else {
            return
          }
          settings.volumes[index].mode = mode
          model.settings.driveAlive = settings
        })
    ) {
      ForEach(DriveAliveMode.allCases, id: \.rawValue) { Text($0.label).tag($0) }
    }.labelsHidden().fixedSize()
  }
  private func ambiguous(_ id: String) -> Bool { mounted.filter { $0.volume.id == id }.count > 1 }
  private func status(for drive: MountedDrive) -> String {
    if ambiguous(drive.volume.id) { return "Multiple mounts have this identity. No writes." }
    if drive.readOnly { return "Read-only. No writes." }
    guard let saved = model.settings.driveAlive.volumes.first(where: { $0.id == drive.volume.id }),
      model.settings.driveAlive.enabled
    else { return "Off" }
    if model.engine.automationPaused { return "Paused" }
    if !saved.eligible(
      awake: !model.engine.holds.isEmpty,
      defaultOnlyWhileAwake: model.settings.driveAlive.onlyWhileAwake)
    {
      return "Waiting for an awake hold"
    }
    return model.driveAlive.statuses[drive.volume.id] ?? "Waiting"
  }
  private func refresh() async {
    guard !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    do {
      let drives = try await Task.detached(priority: .utility) { try NativeDriveAlive.mounted() }
        .value
      guard !Task.isCancelled else { return }
      mounted = drives
      issue = nil
    } catch {
      mounted = []
      issue = error.localizedDescription
    }
  }
}
