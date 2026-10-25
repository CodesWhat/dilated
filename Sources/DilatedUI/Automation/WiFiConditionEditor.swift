import AppKit
import SwiftUI

@MainActor struct WiFiConditionEditor: View {
  @Binding var ssid: Data
  @State private var access = WiFiAccess.shared
  @State private var currentSSIDs: Set<Data>?
  @State private var readFailed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if WiFiSSID.editableName(ssid) != nil {
        TextField(
          "Network name (SSID)",
          text: Binding(
            get: { WiFiSSID.editableName(ssid) ?? "" }, set: { ssid = Data($0.utf8) }))
      } else {
        Text("Selected network: \(WiFiSSID.label(ssid))")
        Button("Enter a network name") { ssid = Data() }
      }
      Text("Matches the exact name, including spaces and capitalization. Maximum 32 UTF-8 bytes.")
        .font(.caption).foregroundStyle(.secondary)
      if ssid.count > 32 {
        Text("This name uses \(ssid.count) bytes. Use at most 32.")
          .font(.caption).foregroundStyle(DesignPalette.danger)
      }
      Text(access.permission.message).font(.caption).foregroundStyle(.secondary)
      if access.permission == .notDetermined {
        Button("Allow Location access") { access.request() }
      } else if access.permission != .allowed {
        Button("Open Location settings") {
          if let url = URL(
            string:
              "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
          {
            NSWorkspace.shared.open(url)
          }
        }
      }
      Button("Get current Wi-Fi network") {
        access.refresh()
        guard access.permission == .allowed else { return }
        currentSSIDs = WiFiCatalog.read()
        readFailed = currentSSIDs == nil
      }.disabled(access.permission != .allowed)
      if readFailed {
        Text("Couldn't read the current Wi-Fi network. Try again.").font(.caption)
      }
      if let currentSSIDs {
        if currentSSIDs.isEmpty {
          Text("No Wi-Fi network name is available. Check your connection and Location access.")
            .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(currentSSIDs.sorted { $0.lexicographicallyPrecedes($1) }, id: \.self) { current in
          Button("Use \(WiFiSSID.label(current))") { ssid = current }
        }
      }
      Text(
        "macOS requires Location access for Wi-Fi names. Dilated doesn't request geographic coordinates. IP, gateway and DNS conditions work without this permission."
      ).font(.caption).foregroundStyle(.secondary)
    }
    .onAppear { access.refresh() }
    .onChange(of: access.permission) { _, _ in
      currentSSIDs = nil
      readFailed = false
    }
  }
}
