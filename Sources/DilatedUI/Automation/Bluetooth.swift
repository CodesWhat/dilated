import AppKit
import CoreBluetooth
import DilatedControl
import DilatedCore
import Foundation
import IOBluetooth
import Observation

enum BluetoothStatus: Equatable {
  case notDetermined, denied, restricted, unknown, resetting, unsupported, poweredOff, poweredOn

  init(authorization: CBManagerAuthorization, state: CBManagerState) {
    switch authorization {
    case .notDetermined: self = .notDetermined
    case .denied: self = .denied
    case .restricted: self = .restricted
    case .allowedAlways:
      self =
        switch state {
        case .unknown: .unknown
        case .resetting: .resetting
        case .unsupported: .unsupported
        case .unauthorized: .denied
        case .poweredOff: .poweredOff
        case .poweredOn: .poweredOn
        @unknown default: .unknown
        }
    @unknown default: self = .denied
    }
  }

  var message: String {
    switch self {
    case .notDetermined: "Allow Bluetooth access to choose a paired device."
    case .denied: "Bluetooth access denied. Allow Dilated in Privacy & Security → Bluetooth."
    case .restricted: "Bluetooth access is restricted on this Mac."
    case .unknown: "Checking Bluetooth availability…"
    case .resetting: "Bluetooth is restarting. Device conditions are waiting."
    case .unsupported: "Bluetooth isn't available on this Mac."
    case .poweredOff: "Bluetooth is off. Turn it on to use device conditions."
    case .poweredOn: "Bluetooth access allowed."
    }
  }
}

@MainActor protocol BluetoothAuthorizationSource: AnyObject {
  var status: BluetoothStatus { get }
  var changed: (@MainActor () -> Void)? { get set }
  func activate()
  func request()
  func stop()
}

@MainActor
private final class NativeBluetoothAuthorization: NSObject,
  BluetoothAuthorizationSource, CBCentralManagerDelegate
{
  private var manager: CBCentralManager?
  var changed: (@MainActor () -> Void)?
  var status: BluetoothStatus {
    BluetoothStatus(authorization: CBManager.authorization, state: manager?.state ?? .unknown)
  }

  func activate() {
    switch CBManager.authorization {
    case .allowedAlways: createManager()
    case .denied, .restricted: stop()
    default: break
    }
  }
  func request() {
    guard CBManager.authorization == .notDetermined else { return }
    createManager()
  }
  private func createManager() {
    guard manager == nil else { return }
    manager = CBCentralManager(
      delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
  }
  func stop() {
    manager?.delegate = nil
    manager = nil
  }
  isolated deinit { stop() }
  nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
    Task { @MainActor [weak self] in self?.changed?() }
  }
}

@MainActor @Observable final class BluetoothAccess {
  static let shared = BluetoothAccess()
  private(set) var status: BluetoothStatus = .notDetermined
  @ObservationIgnored private let makeSource: () -> any BluetoothAuthorizationSource
  @ObservationIgnored private var source: (any BluetoothAuthorizationSource)?
  @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]
  @ObservationIgnored private var activationObserver: NSObjectProtocol?
  @ObservationIgnored private var requested = false

  init(makeSource: (() -> any BluetoothAuthorizationSource)? = nil) {
    self.makeSource = makeSource ?? { NativeBluetoothAuthorization() }
  }

  isolated deinit {
    source?.changed = nil
    source?.stop()
    if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
  }

  func refresh() {
    if source == nil {
      source = makeSource()
      source?.changed = { [weak self] in self?.refresh() }
    }
    if !observers.isEmpty { source?.activate() }
    guard let next = source?.status, next != status else { return }
    status = next
    for changed in Array(observers.values) { changed() }
  }

  func request() {
    refresh()
    guard status == .notDetermined, !requested else { return }
    requested = true
    source?.request()
  }

  func observe(_ changed: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
    let id = UUID()
    observers[id] = changed
    if activationObserver == nil {
      activationObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }
    refresh()
    return { [weak self] in
      guard let self, self.observers.removeValue(forKey: id) != nil else { return }
      if self.observers.isEmpty {
        self.source?.stop()
        if let observer = self.activationObserver {
          NotificationCenter.default.removeObserver(observer)
        }
        self.activationObserver = nil
      }
    }
  }
}

struct NativeBluetoothDevice: Identifiable, Equatable, Sendable {
  let id: BluetoothDeviceIdentity
  let name: String
  let connected: Bool
  var label: String { "\(name) · \(id.address)" }

  init?(address: String, name: String?, paired: Bool, connected: Bool) {
    guard paired, let identity = BluetoothDeviceIdentity(address: address) else { return nil }
    id = identity
    let cleaned = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.name = cleaned.isEmpty ? "Bluetooth device" : String(cleaned.prefix(255))
    self.connected = connected
  }
}

@MainActor enum BluetoothCatalog {
  static func read() -> [NativeBluetoothDevice]? {
    guard CBManager.authorization == .allowedAlways else { return nil }
    guard let paired = IOBluetoothDevice.pairedDevices() else { return [] }
    var devices: [BluetoothDeviceIdentity: NativeBluetoothDevice] = [:]
    for case let device as IOBluetoothDevice in paired {
      guard let address = device.addressString,
        let selection = NativeBluetoothDevice(
          address: address, name: device.name, paired: device.isPaired(),
          connected: device.isConnected())
      else { continue }
      devices[selection.id] = selection
    }
    return devices.values.sorted {
      $0.label.localizedStandardCompare($1.label) == .orderedAscending
    }
  }
}

private final class BluetoothNotificationTarget: NSObject, @unchecked Sendable {
  private let changed: @MainActor @Sendable () -> Void
  init(changed: @escaping @MainActor @Sendable () -> Void) { self.changed = changed }
  @objc func deviceChanged(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
    Task { @MainActor [changed] in changed() }
  }
}

@MainActor private enum NativeBluetoothNotifications {
  static func connect(_ changed: @escaping @MainActor @Sendable () -> Void) -> (
    @MainActor () -> Void
  )? {
    guard CBManager.authorization == .allowedAlways else { return nil }
    let target = BluetoothNotificationTarget(changed: changed)
    guard
      let notification = IOBluetoothDevice.register(
        forConnectNotifications: target,
        selector: #selector(BluetoothNotificationTarget.deviceChanged(_:device:)))
    else { return nil }
    return { withExtendedLifetime(target) { notification.unregister() } }
  }

  static func disconnect(
    _ id: BluetoothDeviceIdentity, _ changed: @escaping @MainActor @Sendable () -> Void
  )
    -> (@MainActor () -> Void)?
  {
    guard CBManager.authorization == .allowedAlways,
      let device = IOBluetoothDevice(addressString: id.address)
    else { return nil }
    let target = BluetoothNotificationTarget(changed: changed)
    guard
      let notification = device.register(
        forDisconnectNotification: target,
        selector: #selector(BluetoothNotificationTarget.deviceChanged(_:device:)))
    else { return nil }
    return { withExtendedLifetime(target) { notification.unregister() } }
  }
}

@MainActor protocol BluetoothSession: AnyObject {
  func start(_ changed: @escaping @MainActor @Sendable () -> Void) throws
  func stop()
  func read() -> [NativeBluetoothDevice]?
}

@MainActor final class NativeBluetoothSession: BluetoothSession {
  typealias Subscription =
    @MainActor (@escaping @MainActor @Sendable () -> Void) -> (@MainActor () -> Void)?
  typealias DisconnectSubscription =
    @MainActor (BluetoothDeviceIdentity, @escaping @MainActor @Sendable () -> Void) -> (
      @MainActor () -> Void
    )?
  private let readDevices: () -> [NativeBluetoothDevice]?
  private let connect: Subscription
  private let disconnect: DisconnectSubscription
  private var cancelConnect: (@MainActor () -> Void)?
  private var disconnects: [BluetoothDeviceIdentity: @MainActor () -> Void] = [:]
  private var signal: (@MainActor @Sendable () -> Void)?
  private var generation = UUID()

  init(
    readDevices: (() -> [NativeBluetoothDevice]?)? = nil,
    connect: Subscription? = nil, disconnect: DisconnectSubscription? = nil
  ) {
    self.readDevices = readDevices ?? BluetoothCatalog.read
    self.connect = connect ?? NativeBluetoothNotifications.connect
    self.disconnect = disconnect ?? NativeBluetoothNotifications.disconnect
  }
  isolated deinit { stop() }

  func start(_ changed: @escaping @MainActor @Sendable () -> Void) throws {
    stop()
    let generation = generation
    let signal: @MainActor @Sendable () -> Void = { [weak self] in
      guard let self, self.cancelConnect != nil, self.generation == generation else { return }
      changed()
    }
    self.signal = signal
    cancelConnect = connect(signal)
    guard cancelConnect != nil, read() != nil else {
      stop()
      throw InputError("Bluetooth device monitoring isn't available. Check access and try again.")
    }
  }

  func read() -> [NativeBluetoothDevice]? {
    guard cancelConnect != nil, let signal, let devices = readDevices() else { return nil }
    let connected = Set(devices.filter(\.connected).map(\.id))
    for id in disconnects.keys.filter({ !connected.contains($0) }) {
      disconnects.removeValue(forKey: id)?()
    }
    for id in connected where disconnects[id] == nil {
      guard let cancel = disconnect(id, signal) else { return nil }
      disconnects[id] = cancel
    }
    return devices
  }

  func stop() {
    generation = UUID()
    signal = nil
    cancelConnect?()
    cancelConnect = nil
    let previous = disconnects
    disconnects = [:]
    for cancel in previous.values { cancel() }
  }
}

@MainActor final class BluetoothObserver {
  private let suppliedAccess: BluetoothAccess?
  private let makeSession: () -> any BluetoothSession
  private let changed: () -> Void
  private var access: BluetoothAccess?
  private var cancelAccess: (@MainActor () -> Void)?
  private var session: (any BluetoothSession)?
  private var generation = UUID()
  private var notificationPending = false
  var isMonitoring: Bool { session != nil }

  init(
    access: BluetoothAccess? = nil, makeSession: (() -> any BluetoothSession)? = nil,
    changed: @escaping () -> Void
  ) {
    suppliedAccess = access
    self.makeSession = makeSession ?? { NativeBluetoothSession() }
    self.changed = changed
  }
  isolated deinit { stop() }

  func setEnabled(_ enabled: Bool) {
    guard enabled else {
      stop()
      return
    }
    if access == nil {
      let access = suppliedAccess ?? BluetoothAccess.shared
      self.access = access
      access.refresh()
      cancelAccess = access.observe { [weak self] in
        self?.synchronize()
        self?.notifyChanged()
      }
    } else {
      access?.refresh()
    }
    synchronize()
  }

  func read() -> Set<BluetoothDeviceIdentity>? {
    guard let access else { return nil }
    access.refresh()
    guard access.status == .poweredOn else { return nil }
    return session?.read().map { Set($0.filter(\.connected).map(\.id)) }
  }

  func stop() {
    cancelAccess?()
    cancelAccess = nil
    access = nil
    stopSession()
  }
  private func stopSession() {
    generation = UUID()
    notificationPending = false
    let previous = session
    session = nil
    previous?.stop()
  }
  private func synchronize() {
    guard access?.status == .poweredOn else {
      if session != nil { stopSession() }
      return
    }
    guard session == nil else { return }
    let generation = UUID()
    self.generation = generation
    let next = makeSession()
    do {
      try next.start { [weak self] in
        guard let self, self.isMonitoring, self.generation == generation else { return }
        self.notifyChanged()
      }
      session = next
    } catch { next.stop() }
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
