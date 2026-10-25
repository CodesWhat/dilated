import CoreAudio
import Foundation

struct NativeAudioOutput: Identifiable, Equatable, Sendable {
  var id: String { uid }
  let uid: String
  let name: String
}

enum AudioOutputCatalog {
  static func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }

  static func defaultUID() -> String? {
    var property = address(kAudioHardwarePropertyDefaultOutputDevice)
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout.size(ofValue: device))
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device) == noErr,
      size == MemoryLayout.size(ofValue: device), device != kAudioObjectUnknown
    else { return nil }
    return string(device, selector: kAudioDevicePropertyDeviceUID)
  }

  static func read() -> [NativeAudioOutput]? {
    var property = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr,
      size % UInt32(MemoryLayout<AudioObjectID>.size) == 0
    else { return nil }
    guard size > 0 else { return [] }
    var devices = [AudioObjectID](
      repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let result = devices.withUnsafeMutableBytes {
      AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!)
    }
    guard result == noErr, Int(size) <= devices.count * MemoryLayout<AudioObjectID>.size else {
      return nil
    }
    return devices.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap { device in
      var streams = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
      var streamSize: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr,
        streamSize > 0, let uid = string(device, selector: kAudioDevicePropertyDeviceUID),
        !uid.isEmpty
      else { return nil }
      return NativeAudioOutput(
        uid: uid, name: string(device, selector: kAudioObjectPropertyName) ?? "Audio output")
    }.sorted {
      let order = $0.name.localizedStandardCompare($1.name)
      return order == .orderedSame ? $0.uid < $1.uid : order == .orderedAscending
    }
  }

  private static func string(_ object: AudioObjectID, selector: AudioObjectPropertySelector)
    -> String?
  {
    var property = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout.size(ofValue: value))
    guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr,
      let value
    else { return nil }
    return value.takeRetainedValue() as String
  }
}

@MainActor final class AudioOutputObserver {
  typealias Registration =
    @MainActor (AudioObjectPropertySelector, @escaping AudioObjectPropertyListenerBlock) -> OSStatus

  private let changed: () -> Void
  private let register: Registration
  private let unregister: Registration
  private static let selectors: [AudioObjectPropertySelector] = [
    kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices,
    kAudioHardwarePropertyServiceRestarted,
  ]
  private var generation = UUID()
  private var listeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
  var isMonitoring: Bool { listeners.count == Self.selectors.count }

  init(
    changed: @escaping () -> Void,
    register: @escaping Registration = { selector, callback in
      var property = AudioOutputCatalog.address(selector)
      return AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &property, .main, callback)
    },
    unregister: @escaping Registration = { selector, callback in
      var property = AudioOutputCatalog.address(selector)
      return AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &property, .main, callback)
    }
  ) {
    self.changed = changed
    self.register = register
    self.unregister = unregister
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
    for selector in Self.selectors {
      let callback: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
        MainActor.assumeIsolated {
          guard let self, self.isMonitoring, self.generation == generation else { return }
          if UnsafeBufferPointer(start: addresses, count: Int(count)).contains(where: {
            $0.mSelector == kAudioHardwarePropertyServiceRestarted
          }) {
            self.stop()
            self.setEnabled(true)
          }
          self.changed()
        }
      }
      guard register(selector, callback) == noErr else {
        stop()
        return
      }
      listeners.append((selector, callback))
    }
  }

  func stop() {
    generation = UUID()
    let registered = listeners
    listeners = []
    for (selector, callback) in registered { _ = unregister(selector, callback) }
  }
}
