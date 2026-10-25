import AppKit
import DilatedCore
import SwiftUI

@MainActor struct BluetoothConditionEditor: View {
  let device: BluetoothDeviceIdentity?
  let name: String
  let choose: (NativeBluetoothDevice) -> Void
  @State private var access = BluetoothAccess.shared
  @State private var devices: [NativeBluetoothDevice] = []
  @State private var readFailed = false
  @State private var cancelAccess: (@MainActor () -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker(
        "Paired device",
        selection: Binding(
          get: { device },
          set: { selected in
            if let selection = devices.first(where: { $0.id == selected }) { choose(selection) }
          })
      ) {
        if !devices.contains(where: { $0.id == device }) {
          Text(device.map { "\(name) · \($0.address) (unavailable)" } ?? "Choose a paired device")
            .tag(device)
        }
        ForEach(devices) { selection in
          Text(selection.label + (selection.connected ? " (connected)" : " (not connected)"))
            .tag(Optional(selection.id))
        }
      }
      Text(access.status.message).font(.caption).foregroundStyle(.secondary)
      switch access.status {
      case .notDetermined:
        Button("Allow Bluetooth access") { access.request() }
      case .denied, .restricted:
        Button("Open Bluetooth privacy settings") {
          openSettings("com.apple.preference.security?Privacy_Bluetooth")
        }
      case .poweredOff:
        Button("Open Bluetooth settings") { openSettings("com.apple.BluetoothSettings") }
      default: EmptyView()
      }
      Button("Refresh paired devices") {
        access.refresh()
        refreshDevices()
      }.disabled(access.status != .poweredOn)
      if readFailed {
        Text("Couldn't read paired devices. Check access and try again.").font(.caption)
      } else if access.status == .poweredOn && devices.isEmpty {
        Text("No paired devices are available. Pair the device in macOS Bluetooth settings first.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Text(
        "Matches this paired device by its Bluetooth address while connected. Doesn't scan, pair, connect or disconnect devices."
      ).font(.caption).foregroundStyle(.secondary)
    }
    .onAppear {
      cancelAccess = access.observe { refreshDevices() }
      refreshDevices()
    }
    .onDisappear {
      cancelAccess?()
      cancelAccess = nil
    }
  }

  private func refreshDevices() {
    guard access.status == .poweredOn else {
      devices = []
      readFailed = false
      return
    }
    let current = BluetoothCatalog.read()
    devices = current ?? []
    readFailed = current == nil
  }

  private func openSettings(_ path: String) {
    if let url = URL(string: "x-apple.systempreferences:\(path)") { NSWorkspace.shared.open(url) }
  }
}
