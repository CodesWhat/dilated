import DilatedCore
import ServiceManagement
import SwiftUI

@MainActor struct ClosedLidSettings: View {
  @Bindable var model: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      SettingsGroup(eyebrow: "HELPER") {
        SettingsRow(
          title: model.closedLid.active ? "Closed-lid armed" : model.helperInstallation.statusText,
          detail: model.helperInstallation.lastError ?? model.closedLid.lastError
            ?? model.closedLid.state?.message
            ?? "Approve the signed background helper in Login Items. Regular awake holds work without it."
        ) {
          Button(model.helperInstallation.buttonTitle) { Task { await model.setupHelper() } }
            .disabled(model.helperInstallation.busy || model.closedLid.busy)
        }
        SettingsRow(title: "Check helper status") {
          Button("Refresh") { model.refreshHelperStatus() }
            .disabled(model.helperInstallation.busy || model.closedLid.busy)
        }
        if let state = model.closedLid.state {
          SettingsRow(title: "Power setting", detail: state.stopReason?.localizedDescription) {
            Text(
              state.readback.confirmedDisabled
                ? "Off, confirmed" : state.enabled ? "On, confirmed" : "Needs attention")
          }
          SettingsRow(title: "Lid") {
            Text(state.environment.lidClosed.map { $0 ? "Closed" : "Open" } ?? "Unavailable")
          }
        }
      }
      SettingsGroup(eyebrow: "LIMITS") {
        SettingsRow(
          title: "Closed-lid battery floor",
          detail: "Always applies. Minimum 10%, even with other overrides."
        ) {
          Picker("Closed-lid battery floor", selection: $model.settings.closedLidBatteryFloor) {
            ForEach(
              Array(
                Set([10, 15, 20, 25, 30, 40, 50, 75, 100, model.settings.closedLidBatteryFloor])
              ).sorted(), id: \.self
            ) {
              Text("\($0)%").tag($0)
            }
          }.labelsHidden().fixedSize()
        }
        SettingsRow(
          title: "Maximum time closed on battery",
          detail:
            "Counts while the lid is closed on battery. Reopening the lid or connecting power resets this limit."
        ) {
          Picker(
            "Maximum time closed on battery", selection: $model.settings.closedLidBatteryMinutes
          ) {
            ForEach(
              Array(
                Set([1, 30, 60, 120, 240, 480, 720, 1440, model.settings.closedLidBatteryMinutes])
              ).sorted(), id: \.self
            ) {
              Text($0 < 60 ? "\($0) minutes" : "\($0 / 60)h \($0 % 60)m").tag($0)
            }
          }.labelsHidden().fixedSize()
        }
        SettingsRow(title: "Require a power adapter") {
          Toggle("", isOn: $model.settings.closedLidACOnly).labelsHidden()
        }
        SettingsRow(title: "Play a sound when closed-lid stops") {
          Toggle("", isOn: $model.settings.closedLidWarningSound).labelsHidden()
        }
        SettingsNote(
          text:
            "Dilated stops closed-lid when macOS reports serious thermal pressure. Low Power Mode stops it unless you've enabled the override in Battery & Safety. Changing these limits stops active closed-lid requests."
        )
      }
      if !model.engine.holds.isEmpty {
        SettingsGroup(eyebrow: "AWAKE REASONS") {
          ForEach(model.engine.holds) { hold in
            SettingsRow(title: hold.label, detail: "Keep working with the lid closed") {
              Toggle(
                "",
                isOn: Binding(
                  get: { hold.closedLid == true },
                  set: { enabled in
                    Task {
                      do { try await model.setClosedLid(id: hold.id, enabled: enabled) } catch {
                        model.message = error.localizedDescription
                        model.onChange?()
                      }
                    }
                  }
                )
              ).labelsHidden().disabled(model.closedLid.busy || model.helperInstallation.busy)
            }
          }
        }
      }
      SettingsNote(
        text:
          "Keep your Mac ventilated. Don't put it in a bag while it works. The helper checks battery, temperature and its 90-second app lease independently. A crash, reboot or safety stop requires enabling closed-lid again."
      )
      if model.helperInstallation.status == .enabled {
        Button("Turn off and remove helper") { Task { await model.removeHelper() } }
          .disabled(model.closedLid.busy || model.helperInstallation.busy)
      }
    }
  }
}
