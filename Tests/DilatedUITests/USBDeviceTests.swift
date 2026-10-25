import DilatedCore
import Foundation
import IOKit.usb
import Testing

@testable import DilatedUI

@MainActor struct USBDeviceTests {
  @Test func registryPropertiesKeepIdentityAndExplainModelMatching() throws {
    let unit = try #require(
      NativeUSBDevice(properties: [
        kUSBVendorID: 1234, kUSBProductID: 5678, kUSBSerialNumberString: "studio-1",
        kUSBProductString: "Studio USB",
      ]))
    #expect(unit.identity == .init(vendorID: 1234, productID: 5678, serialNumber: "studio-1"))
    #expect(unit.label.contains("studio-1"))
    let model = try #require(
      NativeUSBDevice(properties: [
        kUSBVendorID: 1234, kUSBProductID: 5678, "USB Product Name": "Studio USB",
      ]))
    #expect(model.identity.serialNumber == nil)
    #expect(model.label.contains("any matching model"))
    let legacy = try #require(
      NativeUSBDevice(properties: [
        kUSBVendorID: 1234, kUSBProductID: 5678, "USB Serial Number": "older-driver",
      ]))
    #expect(legacy.identity.serialNumber == "older-driver")
    #expect(NativeUSBDevice(properties: [kUSBVendorID: -1, kUSBProductID: 1]) == nil)
    #expect(NativeUSBDevice(properties: [kUSBVendorID: 1]) == nil)
    #expect(NativeUSBDevice(properties: [kUSBVendorID: true, kUSBProductID: 1]) == nil)
    #expect(NativeUSBDevice(properties: [kUSBVendorID: 1.5, kUSBProductID: 1]) == nil)
    #expect(
      NativeUSBDevice(properties: [
        kUSBVendorID: 1, kUSBProductID: 1, kUSBSerialNumberString: 1234,
      ]) == nil)
  }

  @Test func subscriptionsAreIdempotentAndOldCallbacksDoNotSurviveRestart() {
    var callbacks: [@MainActor @Sendable () -> Void] = []
    var cancellations = 0
    var changes = 0
    let observer = USBDeviceObserver(
      changed: { changes += 1 },
      subscribe: { callback in
        callbacks.append(callback)
        return { cancellations += 1 }
      })
    defer { observer.stop() }
    observer.setEnabled(true)
    observer.setEnabled(true)
    #expect(observer.isMonitoring && callbacks.count == 1)
    callbacks[0]()
    #expect(changes == 1)
    observer.stop()
    #expect(!observer.isMonitoring && cancellations == 1)
    callbacks[0]()
    #expect(changes == 1)
    observer.setEnabled(true)
    #expect(callbacks.count == 2)
    callbacks[0]()
    callbacks[1]()
    #expect(changes == 2)
  }

  @Test func failedSubscriptionStaysInactiveAndDeinitCancelsAnActiveOne() {
    let failed = USBDeviceObserver(changed: {}, subscribe: { _ in nil })
    failed.setEnabled(true)
    #expect(!failed.isMonitoring)
    var cancellations = 0
    var observer: USBDeviceObserver? = USBDeviceObserver(
      changed: {}, subscribe: { _ in { cancellations += 1 } })
    observer?.setEnabled(true)
    #expect(observer?.isMonitoring == true)
    observer = nil
    #expect(cancellations == 1)
  }

  @Test func nativeCatalogAndNotificationRegistrationWorkWithoutPolling() throws {
    let devices = try #require(USBDeviceCatalog.read())
    print("Native USB selections: \(devices.count)")
    #expect(devices.allSatisfy { $0.identity.isValid && !$0.name.isEmpty })
    #expect(Set(devices.map(\.identity)).count == devices.count)
    let observer = USBDeviceObserver(changed: {})
    defer { observer.stop() }
    observer.setEnabled(true)
    #expect(observer.isMonitoring)
    observer.setEnabled(false)
    #expect(!observer.isMonitoring)
    let monitor = TriggerMonitor(readPower: { .init() }, changed: {})
    defer { monitor.stop() }
    var rule = TriggerRule(
      name: "USB", criteria: [.usb(device: .init(vendorID: 1234, productID: 5678), name: "USB")])
    monitor.configure(rules: [rule])
    #expect(monitor.pollingInterval == nil)
    #expect(monitor.read().usbDevices != nil)
    rule.enabled = false
    monitor.configure(rules: [rule])
    #expect(monitor.read().usbDevices == nil)
    rule.enabled = true
    rule.pausedUntil = Date().addingTimeInterval(60)
    monitor.configure(rules: [rule])
    #expect(monitor.read().usbDevices == nil && monitor.pollingInterval == nil)
  }
}
