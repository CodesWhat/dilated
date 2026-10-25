import CoreBluetooth
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor private final class TestBluetoothAuthorization: BluetoothAuthorizationSource {
  var status: BluetoothStatus = .notDetermined
  var changed: (@MainActor () -> Void)?
  var activations = 0
  var requests = 0
  var stops = 0
  func activate() { activations += 1 }
  func request() { requests += 1 }
  func stop() { stops += 1 }
}

@MainActor private final class TestBluetoothSession: BluetoothSession {
  var callback: (@MainActor @Sendable () -> Void)?
  var devices: [NativeBluetoothDevice]? = []
  var starts = 0
  var stops = 0
  var fails = false
  func start(_ changed: @escaping @MainActor @Sendable () -> Void) throws {
    callback = changed
    starts += 1
    if fails { throw NSError(domain: "test", code: 1) }
  }
  func stop() { stops += 1 }
  func read() -> [NativeBluetoothDevice]? { devices }
}

@MainActor struct BluetoothTests {
  private func device(_ suffix: String = "ab", connected: Bool = true) -> NativeBluetoothDevice {
    NativeBluetoothDevice(
      address: "01:23:45:67:89:\(suffix)", name: "Studio", paired: true, connected: connected)!
  }

  @Test func permissionRequestIsExplicitAndSourcesStopAfterTheLastConsumer() {
    let source = TestBluetoothAuthorization()
    var creations = 0
    let access = BluetoothAccess {
      creations += 1
      return source
    }
    #expect(creations == 0)
    access.refresh()
    #expect(creations == 1 && source.requests == 0 && source.activations == 0)
    let first = access.observe {}
    let second = access.observe {}
    access.request()
    access.request()
    #expect(source.requests == 1)
    source.status = .denied
    source.changed?()
    access.request()
    #expect(access.status == .denied && source.requests == 1)
    first()
    #expect(source.stops == 0)
    second()
    #expect(source.stops == 1)
  }

  @Test func authorizationAndPowerStatesFailClosedDuringResetAndDenial() {
    #expect(BluetoothStatus(authorization: .notDetermined, state: .poweredOn) == .notDetermined)
    #expect(BluetoothStatus(authorization: .denied, state: .poweredOn) == .denied)
    #expect(BluetoothStatus(authorization: .restricted, state: .poweredOn) == .restricted)
    #expect(BluetoothStatus(authorization: .allowedAlways, state: .poweredOn) == .poweredOn)
    #expect(BluetoothStatus(authorization: .allowedAlways, state: .poweredOff) == .poweredOff)
    #expect(BluetoothStatus(authorization: .allowedAlways, state: .resetting) == .resetting)
    #expect(BluetoothStatus(authorization: .allowedAlways, state: .unsupported) == .unsupported)
    #expect(BluetoothStatus(authorization: .allowedAlways, state: .unauthorized) == .denied)
  }

  @Test func nativeDeviceSelectionKeepsIdentityAndFiltersUnpairedOrInvalidDevices() {
    let first = device()
    let second = device("ac")
    #expect(first.name == second.name && first.id != second.id)
    #expect(first.label != second.label && first.label.contains(first.id.address))
    #expect(
      NativeBluetoothDevice(address: "bad", name: "Studio", paired: true, connected: true) == nil)
    #expect(
      NativeBluetoothDevice(
        address: first.id.address, name: "Studio", paired: false, connected: true) == nil)
    let unnamed = NativeBluetoothDevice(
      address: first.id.address, name: nil, paired: true, connected: false)
    #expect(unnamed?.name == "Bluetooth device" && unnamed?.connected == false)
  }

  @Test func nativeSessionTracksDisconnectRegistrationsAndRejectsOldCallbacks() throws {
    var devices: [NativeBluetoothDevice]? = []
    var connectSignals: [@MainActor @Sendable () -> Void] = []
    var disconnectSignals: [BluetoothDeviceIdentity: @MainActor @Sendable () -> Void] = [:]
    var cancelled: [BluetoothDeviceIdentity] = []
    var connectCancellations = 0
    var changes = 0
    let session = NativeBluetoothSession(
      readDevices: { devices },
      connect: { signal in
        connectSignals.append(signal)
        return { connectCancellations += 1 }
      },
      disconnect: { id, signal in
        disconnectSignals[id] = signal
        return { cancelled.append(id) }
      })
    defer { session.stop() }
    try session.start { changes += 1 }
    devices = [device(), device("ac", connected: false)]
    connectSignals[0]()
    #expect(changes == 1)
    #expect(session.read() == devices && disconnectSignals.count == 1)
    let first = device().id
    let staleDisconnect = disconnectSignals[first]
    devices = [device(connected: false)]
    staleDisconnect?()
    #expect(changes == 2 && session.read() == devices && cancelled == [first])
    session.stop()
    #expect(connectCancellations == 1 && session.read() == nil)
    connectSignals[0]()
    staleDisconnect?()
    #expect(changes == 2)
    try session.start { changes += 1 }
    connectSignals[0]()
    connectSignals[1]()
    #expect(changes == 3)
  }

  @Test func partialNativeSetupAndReadFailureDoNotLeaveSubscriptionsOrStaleDevices() {
    var devices: [NativeBluetoothDevice]? = [device(), device("ac")]
    var connectCancellations = 0
    var disconnectAttempts = 0
    var disconnectCancellations = 0
    let registerDisconnect: NativeBluetoothSession.DisconnectSubscription = { _, _ in
      disconnectAttempts += 1
      guard disconnectAttempts == 1 else { return nil }
      return { disconnectCancellations += 1 }
    }
    let session = NativeBluetoothSession(
      readDevices: { devices }, connect: { _ in { connectCancellations += 1 } },
      disconnect: registerDisconnect)
    #expect(throws: (any Error).self) { try session.start {} }
    #expect(connectCancellations == 1 && disconnectCancellations == 1 && session.read() == nil)
    devices = nil
    #expect(throws: (any Error).self) { try session.start {} }
    #expect(connectCancellations == 2 && session.read() == nil)
  }

  @Test func powerPermissionAndStoppedGenerationsControlTheEventSession() async {
    let source = TestBluetoothAuthorization()
    let access = BluetoothAccess { source }
    var sessions: [TestBluetoothSession] = []
    var changes = 0
    let observer = BluetoothObserver(
      access: access,
      makeSession: {
        let session = TestBluetoothSession()
        session.devices = [device()]
        sessions.append(session)
        return session
      }, changed: { changes += 1 })
    defer { observer.stop() }
    observer.setEnabled(true)
    #expect(sessions.isEmpty && source.requests == 0 && observer.read() == nil)
    source.status = .poweredOn
    source.changed?()
    #expect(observer.isMonitoring && sessions.count == 1)
    observer.setEnabled(true)
    #expect(sessions[0].starts == 1 && observer.read() == [device().id])
    let stale = sessions[0].callback
    source.status = .resetting
    source.changed?()
    #expect(!observer.isMonitoring && observer.read() == nil && sessions[0].stops == 1)
    source.status = .poweredOn
    source.changed?()
    #expect(sessions.count == 2 && observer.isMonitoring)
    sessions[1].devices = nil
    #expect(observer.read() == nil)
    source.status = .denied
    source.changed?()
    #expect(!observer.isMonitoring && observer.read() == nil && sessions[1].stops == 1)
    observer.stop()
    await Task.yield()
    let before = changes
    stale?()
    sessions[1].callback?()
    await Task.yield()
    #expect(changes == before && !observer.isMonitoring)
  }

  @Test func failedSessionAndDeinitReleaseResources() {
    let source = TestBluetoothAuthorization()
    source.status = .poweredOn
    let access = BluetoothAccess { source }
    let session = TestBluetoothSession()
    session.fails = true
    var observer: BluetoothObserver? = BluetoothObserver(
      access: access, makeSession: { session }, changed: {})
    observer?.setEnabled(true)
    #expect(observer?.isMonitoring == false && observer?.read() == nil && session.stops == 1)
    session.fails = false
    observer?.setEnabled(true)
    #expect(observer?.isMonitoring == true)
    observer = nil
    #expect(session.stops == 2 && source.stops == 1)
  }

  @Test func disabledPausedAndUnrelatedRulesDoNotStartBluetoothOrAddPolling() {
    let source = TestBluetoothAuthorization()
    source.status = .poweredOn
    var creations = 0
    let access = BluetoothAccess {
      creations += 1
      return source
    }
    let session = TestBluetoothSession()
    session.devices = [device()]
    let monitor = TriggerMonitor(
      readPower: { .init() }, bluetoothAccess: access, makeBluetoothSession: { session },
      changed: {})
    defer { monitor.stop() }
    monitor.configure(rules: [TriggerRule(name: "Power", criteria: [.power(onBattery: false)])])
    #expect(creations == 0 && monitor.read().connectedBluetoothDevices == nil)
    var rule = TriggerRule(
      name: "Bluetooth", criteria: [.bluetooth(device: device().id, name: "Studio")])
    rule.enabled = false
    monitor.configure(rules: [rule])
    #expect(creations == 0 && monitor.pollingInterval == nil)
    rule.enabled = true
    rule.pausedUntil = Date().addingTimeInterval(60)
    monitor.configure(rules: [rule])
    #expect(creations == 0)
    rule.pausedUntil = nil
    monitor.configure(rules: [rule])
    #expect(creations == 1 && source.requests == 0 && session.starts == 1)
    #expect(
      monitor.read().connectedBluetoothDevices == [device().id] && monitor.pollingInterval == nil)
    monitor.stop()
    #expect(session.stops == 1 && monitor.read().connectedBluetoothDevices == nil)
  }

  @Test func nativeAuthorizationAndCatalogRespectTheCurrentGrantWithoutRequestingOne() throws {
    let authorization = CBManager.authorization
    print("Native Bluetooth authorization: \(authorization.rawValue)")
    let access = BluetoothAccess()
    access.refresh()
    let expected = BluetoothStatus(authorization: authorization, state: .unknown)
    #expect(access.status == expected)
    if authorization == .allowedAlways {
      let devices = try #require(BluetoothCatalog.read())
      print("Native paired Bluetooth selections: \(devices.count)")
      #expect(Set(devices.map(\.id)).count == devices.count)
    } else {
      #expect(BluetoothCatalog.read() == nil)
    }
  }
}
