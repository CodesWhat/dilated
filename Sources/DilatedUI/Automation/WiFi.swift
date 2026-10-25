import AppKit
import CoreLocation
import CoreWLAN
import Foundation
import Observation

enum WiFiSSID {
  static func editableName(_ data: Data) -> String? {
    guard let text = String(data: data, encoding: .utf8),
      !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return nil }
    return text
  }

  static func label(_ data: Data) -> String {
    if let text = editableName(data), !text.isEmpty { return text }
    return "SSID 0x" + data.map { String(format: "%02x", $0) }.joined()
  }
}

enum WiFiCatalog {
  static func read(client: CWWiFiClient = .shared()) -> Set<Data>? {
    guard let interfaces = client.interfaces() else { return nil }
    return Set(
      interfaces.compactMap { interface in
        guard interface.powerOn(), let ssid = interface.ssidData(), (1...32).contains(ssid.count)
        else { return nil }
        return ssid
      })
  }
}

enum WiFiPermission: Equatable {
  case notDetermined, allowed, denied, restricted, disabled

  init(status: CLAuthorizationStatus, servicesEnabled: Bool) {
    guard servicesEnabled else {
      self = .disabled
      return
    }
    self =
      switch status {
      case .notDetermined: .notDetermined
      case .authorizedAlways: .allowed
      case .denied: .denied
      case .restricted: .restricted
      @unknown default: .denied
      }
  }

  var message: String {
    switch self {
    case .notDetermined: "Allow Location access to read Wi-Fi network names."
    case .allowed: "Location access allowed."
    case .denied: "Location access denied. Allow Dilated in Privacy & Security → Location Services."
    case .restricted: "Location access is restricted on this Mac."
    case .disabled: "Location Services is off. Enable it in Privacy & Security → Location Services."
    }
  }
}

@MainActor protocol WiFiAuthorizationSource: AnyObject {
  var permission: WiFiPermission { get }
  var changed: (@MainActor () -> Void)? { get set }
  func request()
}

@MainActor
private final class NativeWiFiAuthorization: NSObject, WiFiAuthorizationSource,
  CLLocationManagerDelegate
{
  private let manager = CLLocationManager()
  var changed: (@MainActor () -> Void)?
  var permission: WiFiPermission {
    WiFiPermission(
      status: manager.authorizationStatus,
      servicesEnabled: CLLocationManager.locationServicesEnabled())
  }
  override init() {
    super.init()
    manager.delegate = self
  }
  func request() { manager.requestWhenInUseAuthorization() }
  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    Task { @MainActor [weak self] in self?.changed?() }
  }
}

@MainActor @Observable final class WiFiAccess {
  static let shared = WiFiAccess()
  private(set) var permission: WiFiPermission = .notDetermined
  @ObservationIgnored private let makeSource: () -> any WiFiAuthorizationSource
  @ObservationIgnored private var source: (any WiFiAuthorizationSource)?
  @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]
  @ObservationIgnored private var activationObserver: NSObjectProtocol?
  @ObservationIgnored private var requested = false

  init(makeSource: (() -> any WiFiAuthorizationSource)? = nil) {
    self.makeSource = makeSource ?? { NativeWiFiAuthorization() }
  }

  isolated deinit {
    source?.changed = nil
    if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
  }

  func refresh() {
    if source == nil {
      let source = makeSource()
      self.source = source
      source.changed = { [weak self] in self?.refresh() }
      activationObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }
    guard let next = source?.permission, next != permission else { return }
    permission = next
    for changed in Array(observers.values) { changed() }
  }

  func request() {
    refresh()
    guard permission == .notDetermined, !requested else { return }
    requested = true
    source?.request()
  }

  func observe(_ changed: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
    let id = UUID()
    observers[id] = changed
    return { [weak self] in self?.observers.removeValue(forKey: id) }
  }
}

@MainActor final class WiFiObserver {
  private let suppliedAccess: WiFiAccess?
  private let readSSIDs: () -> Set<Data>?
  private let changed: () -> Void
  private var access: WiFiAccess?
  private var cancelAccess: (@MainActor () -> Void)?
  private var generation = UUID()
  private var notificationPending = false
  var isAuthorized: Bool { access?.permission == .allowed }

  init(
    access: WiFiAccess? = nil, readSSIDs: (() -> Set<Data>?)? = nil,
    changed: @escaping () -> Void
  ) {
    suppliedAccess = access
    self.readSSIDs = readSSIDs ?? { WiFiCatalog.read() }
    self.changed = changed
  }

  isolated deinit { stop() }

  func setEnabled(_ enabled: Bool) {
    guard enabled else {
      stop()
      return
    }
    if access == nil {
      let access = suppliedAccess ?? WiFiAccess.shared
      self.access = access
      access.refresh()
      cancelAccess = access.observe { [weak self] in self?.notifyChanged() }
    } else {
      access?.refresh()
    }
  }

  func read() -> Set<Data>? {
    guard let access else { return nil }
    access.refresh()
    guard access.permission == .allowed else { return nil }
    return readSSIDs()
  }

  func stop() {
    generation = UUID()
    notificationPending = false
    cancelAccess?()
    cancelAccess = nil
    access = nil
  }

  private func notifyChanged() {
    guard !notificationPending else { return }
    notificationPending = true
    let generation = generation
    Task { @MainActor [weak self] in
      guard let self, self.access != nil, self.generation == generation else { return }
      self.notificationPending = false
      self.changed()
    }
  }
}
