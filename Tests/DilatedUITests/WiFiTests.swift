import CoreLocation
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor private final class TestWiFiAuthorization: WiFiAuthorizationSource {
  var permission: WiFiPermission = .notDetermined
  var changed: (@MainActor () -> Void)?
  var requests = 0
  func request() { requests += 1 }
}

@MainActor struct WiFiTests {
  @Test func locationRequestsAreExplicitAndDenialDoesNotPromptAgain() {
    let source = TestWiFiAuthorization()
    var creations = 0
    let access = WiFiAccess {
      creations += 1
      return source
    }
    #expect(creations == 0 && source.requests == 0)
    access.refresh()
    access.refresh()
    #expect(creations == 1 && source.requests == 0)
    access.request()
    access.request()
    #expect(source.requests == 1)
    source.permission = .denied
    source.changed?()
    #expect(access.permission == .denied)
    access.request()
    #expect(source.requests == 1)
    #expect(WiFiPermission(status: .authorizedAlways, servicesEnabled: true) == .allowed)
    #expect(WiFiPermission(status: .authorizedAlways, servicesEnabled: false) == .disabled)
    #expect(WiFiPermission(status: .restricted, servicesEnabled: true) == .restricted)
    #expect(WiFiPermission(status: .notDetermined, servicesEnabled: true) == .notDetermined)
    #expect(WiFiPermission(status: .denied, servicesEnabled: true) == .denied)
  }

  @Test func permissionLossPreventsReadsAndNeverReturnsThePreviousSSID() {
    let source = TestWiFiAuthorization()
    let access = WiFiAccess { source }
    var reads = 0
    let observer = WiFiObserver(
      access: access,
      readSSIDs: {
        reads += 1
        return [Data("Studio".utf8)]
      }, changed: {})
    defer { observer.stop() }
    observer.setEnabled(true)
    #expect(!observer.isAuthorized && observer.read() == nil)
    #expect(source.requests == 0 && reads == 0)
    source.permission = .allowed
    source.changed?()
    #expect(observer.isAuthorized)
    #expect(observer.read() == [Data("Studio".utf8)] && reads == 1)
    source.permission = .denied
    source.changed?()
    #expect(!observer.isAuthorized && observer.read() == nil && reads == 1)
    source.permission = .allowed
    source.changed?()
    #expect(observer.read() == [Data("Studio".utf8)] && reads == 2)
    observer.stop()
    #expect(!observer.isAuthorized && observer.read() == nil && reads == 2)
  }

  @Test func queuedPermissionChangesAreIgnoredAfterStopOrDeinit() {
    let source = TestWiFiAuthorization()
    let access = WiFiAccess { source }
    var changes = 0
    var pending: [@MainActor @Sendable () -> Void] = []
    var observer: WiFiObserver? = WiFiObserver(
      access: access, readSSIDs: { [] }, schedule: { pending.append($0) }, changed: { changes += 1 }
    )
    observer?.setEnabled(true)
    observer?.setEnabled(true)
    source.permission = .allowed
    source.changed?()
    source.permission = .denied
    source.changed?()
    observer?.stop()
    for callback in pending { callback() }
    pending.removeAll()
    #expect(changes == 0)
    observer?.setEnabled(true)
    source.permission = .allowed
    source.changed?()
    for callback in pending { callback() }
    pending.removeAll()
    #expect(changes == 1)
    weak var released = observer
    source.permission = .denied
    source.changed?()
    observer = nil
    #expect(released == nil)
    for callback in pending { callback() }
    pending.removeAll()
    #expect(changes == 1)
  }

  @Test func failedAndDisconnectedReadsCannotReuseStaleNetworkState() {
    let source = TestWiFiAuthorization()
    source.permission = .allowed
    let access = WiFiAccess { source }
    var current: Set<Data>? = [Data("Studio".utf8)]
    let observer = WiFiObserver(access: access, readSSIDs: { current }, changed: {})
    defer { observer.stop() }
    observer.setEnabled(true)
    #expect(observer.read() == current)
    current = nil
    #expect(observer.read() == nil)
    current = []
    #expect(observer.read() == [])
    current = [Data("Other".utf8)]
    #expect(observer.read() == current)
  }

  @Test func ssidLabelsKeepRawIdentityAndShowUnusualNamesSafely() {
    #expect(WiFiSSID.label(Data("Studio".utf8)) == "Studio")
    #expect(WiFiSSID.label(Data([0, 255])) == "SSID 0x00ff")
    #expect(WiFiSSID.label(Data("line\nbreak".utf8)).hasPrefix("SSID 0x"))
    #expect(WiFiSSID.editableName(Data([255])) == nil)
    #expect(WiFiSSID.editableName(Data()) == "")
    #expect(TriggerCriterion.wifi(ssid: Data("Studio".utf8)).summary.contains("Studio"))
  }

  @Test func authorizedSSIDRulesSharePollingAndOtherNetworkRulesNeedNoLocation() {
    let source = TestWiFiAuthorization()
    source.permission = .allowed
    var creations = 0
    let access = WiFiAccess {
      creations += 1
      return source
    }
    let monitor = TriggerMonitor(
      readPower: { .init() }, wifiAccess: access, readWiFi: { [Data("Studio".utf8)] }, changed: {})
    defer { monitor.stop() }
    monitor.configure(rules: [
      TriggerRule(name: "IP", criteria: [.network(address: "192.0.2.0/24")])
    ])
    #expect(monitor.read().wifiSSIDs == nil && monitor.pollingInterval == nil && creations == 0)
    var rule = TriggerRule(name: "Wi-Fi", criteria: [.wifi(ssid: Data("Studio".utf8))])
    monitor.configure(rules: [rule])
    #expect(creations == 1 && source.requests == 0 && monitor.pollingInterval == 5)
    #expect(monitor.read().wifiSSIDs == [Data("Studio".utf8)])
    source.permission = .denied
    monitor.configure(rules: [rule])
    #expect(monitor.read().wifiSSIDs == nil && monitor.pollingInterval == nil)
    source.permission = .allowed
    rule.pausedUntil = Date().addingTimeInterval(60)
    monitor.configure(rules: [rule])
    #expect(monitor.read().wifiSSIDs == nil && monitor.pollingInterval == nil)
    rule.pausedUntil = nil
    rule.enabled = false
    monitor.configure(rules: [rule])
    #expect(monitor.read().wifiSSIDs == nil && monitor.pollingInterval == nil)
    rule.enabled = true
    monitor.configure(rules: [
      rule, TriggerRule(name: "CPU", criteria: [.cpu(percent: 20, atLeast: true)]),
    ])
    #expect(monitor.pollingInterval == 5)
    monitor.stop()
    #expect(monitor.pollingInterval == nil && monitor.read().wifiSSIDs == nil)
  }
}
