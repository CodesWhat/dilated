import DilatedCore
import Foundation
import IOKit
import IOKit.usb

struct NativeUSBDevice: Identifiable, Equatable, Sendable {
  var id: USBDeviceIdentity { identity }
  let identity: USBDeviceIdentity
  let name: String
  var label: String {
    name + (identity.serialNumber.map { " · \($0)" } ?? " · any matching model")
  }

  init?(properties: [String: Any]) {
    func number(_ key: String) -> Int? {
      guard let value = properties[key] as? NSNumber,
        CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
        (0...65535).contains(value.doubleValue), value.doubleValue.rounded() == value.doubleValue
      else { return nil }
      return value.intValue
    }
    guard let vendor = number(kUSBVendorID), let product = number(kUSBProductID) else {
      return nil
    }
    let rawSerial = properties[kUSBSerialNumberString] ?? properties["USB Serial Number"]
    guard rawSerial == nil || rawSerial is String else { return nil }
    let serial = (rawSerial as? String).flatMap {
      $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
    }
    identity = .init(vendorID: vendor, productID: product, serialNumber: serial)
    guard identity.isValid else { return nil }
    let productName = (properties[kUSBProductString] ?? properties["USB Product Name"]) as? String
    name = productName.flatMap { $0.isEmpty ? nil : $0 } ?? "USB device"
  }
}

enum USBDeviceCatalog {
  static func read() -> [NativeUSBDevice]? {
    guard let matching = IOServiceMatching(kIOUSBHostDeviceClassName) else { return nil }
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
    else {
      return nil
    }
    defer { IOObjectRelease(iterator) }
    var devices: [USBDeviceIdentity: NativeUSBDevice] = [:]
    while true {
      let service = IOIteratorNext(iterator)
      guard service != 0 else { break }
      defer { IOObjectRelease(service) }
      var properties: Unmanaged<CFMutableDictionary>?
      guard
        IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
          == KERN_SUCCESS,
        let values = properties?.takeRetainedValue() as? [String: Any],
        let device = NativeUSBDevice(properties: values)
      else { continue }
      devices[device.identity] = device
    }
    return devices.values.sorted {
      $0.label.localizedStandardCompare($1.label) == .orderedAscending
    }
  }
}

@MainActor private enum NativeUSBNotifications {
  nonisolated static let notification = Notification.Name("DilatedUSBDevicesChanged")

  nonisolated static func drain(_ iterator: io_iterator_t) {
    while true {
      let service = IOIteratorNext(iterator)
      guard service != 0 else { return }
      IOObjectRelease(service)
    }
  }

  static func subscribe(_ changed: @escaping @MainActor @Sendable () -> Void)
    -> (@MainActor () -> Void)?
  {
    guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
    IONotificationPortSetDispatchQueue(port, .main)
    var iterators: [io_iterator_t] = []
    var ready = false
    defer {
      if !ready {
        IONotificationPortSetDispatchQueue(port, nil)
        for iterator in iterators { IOObjectRelease(iterator) }
        IONotificationPortDestroy(port)
      }
    }
    for event in [kIOFirstMatchNotification, kIOTerminatedNotification] {
      guard let matching = IOServiceMatching(kIOUSBHostDeviceClassName) else { return nil }
      var iterator: io_iterator_t = 0
      let result = IOServiceAddMatchingNotification(
        port, event, matching,
        { _, iterator in
          NativeUSBNotifications.drain(iterator)
          NotificationCenter.default.post(name: NativeUSBNotifications.notification, object: nil)
        }, nil, &iterator)
      guard result == KERN_SUCCESS, iterator != 0 else {
        if iterator != 0 { IOObjectRelease(iterator) }
        return nil
      }
      iterators.append(iterator)
      drain(iterator)
    }
    let observer = NotificationCenter.default.addObserver(
      forName: notification, object: nil, queue: .main
    ) { _ in MainActor.assumeIsolated { changed() } }
    ready = true
    return {
      NotificationCenter.default.removeObserver(observer)
      IONotificationPortSetDispatchQueue(port, nil)
      for iterator in iterators { IOObjectRelease(iterator) }
      IONotificationPortDestroy(port)
    }
  }
}

@MainActor final class USBDeviceObserver {
  typealias Subscription =
    @MainActor (@escaping @MainActor @Sendable () -> Void) -> (@MainActor () -> Void)?
  private let changed: () -> Void
  private let subscribe: Subscription
  private var cancellation: (@MainActor () -> Void)?
  private var generation = UUID()
  var isMonitoring: Bool { cancellation != nil }

  init(changed: @escaping () -> Void, subscribe: Subscription? = nil) {
    self.changed = changed
    self.subscribe = subscribe ?? NativeUSBNotifications.subscribe
  }

  isolated deinit { stop() }

  func setEnabled(_ enabled: Bool) {
    guard enabled else {
      stop()
      return
    }
    guard !isMonitoring else { return }
    let generation = UUID()
    self.generation = generation
    cancellation = subscribe { [weak self] in
      guard let self, self.isMonitoring, self.generation == generation else { return }
      self.changed()
    }
  }

  func stop() {
    generation = UUID()
    let cancel = cancellation
    cancellation = nil
    cancel?()
  }
}
