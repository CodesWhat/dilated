import CoreAudio
import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct AudioOutputTests {
  @Test func outputListenersAreIdempotentAndIgnoreCallbacksAfterStop() {
    var callbacks: [AudioObjectPropertyListenerBlock] = []
    var added: [AudioObjectPropertySelector] = []
    var removed: [AudioObjectPropertySelector] = []
    var changes = 0
    let observer = AudioOutputObserver(
      changed: { changes += 1 },
      register: { selector, callback in
        added.append(selector)
        callbacks.append(callback)
        return noErr
      },
      unregister: { selector, _ in
        removed.append(selector)
        return noErr
      })
    observer.setEnabled(true)
    observer.setEnabled(true)
    #expect(observer.isMonitoring)
    #expect(
      added == [
        kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyServiceRestarted,
      ])
    var address = AudioOutputCatalog.address(kAudioHardwarePropertyDefaultOutputDevice)
    withUnsafePointer(to: &address) { callbacks[0](1, $0) }
    #expect(changes == 1)
    observer.stop()
    #expect(!observer.isMonitoring)
    #expect(removed == added)
    withUnsafePointer(to: &address) { callbacks[0](1, $0) }
    #expect(changes == 1)
    observer.stop()
    #expect(removed == added)
  }

  @Test func serviceRestartReestablishesListenersAndIgnoresOldCallbacks() throws {
    var callbacks: [AudioObjectPropertySelector: AudioObjectPropertyListenerBlock] = [:]
    var registrations = 0
    var removals = 0
    var changes = 0
    let observer = AudioOutputObserver(
      changed: { changes += 1 },
      register: { selector, callback in
        registrations += 1
        callbacks[selector] = callback
        return noErr
      },
      unregister: { _, _ in
        removals += 1
        return noErr
      })
    defer { observer.stop() }
    observer.setEnabled(true)
    let previous = try #require(callbacks[kAudioHardwarePropertyDefaultOutputDevice])
    let restarted = try #require(callbacks[kAudioHardwarePropertyServiceRestarted])
    var address = AudioOutputCatalog.address(kAudioHardwarePropertyServiceRestarted)
    withUnsafePointer(to: &address) { restarted(1, $0) }
    #expect(observer.isMonitoring)
    #expect(registrations == 6 && removals == 3)
    #expect(changes == 1)
    address = AudioOutputCatalog.address(kAudioHardwarePropertyDefaultOutputDevice)
    withUnsafePointer(to: &address) { previous(1, $0) }
    #expect(changes == 1)
  }

  @Test func failedListenerSetupCleansUpPartialRegistration() {
    var removed: [AudioObjectPropertySelector] = []
    var changes = 0
    let observer = AudioOutputObserver(
      changed: { changes += 1 },
      register: { selector, _ in
        selector == kAudioHardwarePropertyDevices ? kAudioHardwareUnspecifiedError : noErr
      },
      unregister: { selector, _ in
        removed.append(selector)
        return noErr
      })
    observer.setEnabled(true)
    #expect(!observer.isMonitoring)
    #expect(removed == [kAudioHardwarePropertyDefaultOutputDevice])
    #expect(changes == 0)
  }

  @Test func releasingTheObserverRemovesItsNativeRegistrations() {
    var removed = 0
    var observer: AudioOutputObserver? = AudioOutputObserver(
      changed: {}, register: { _, _ in noErr },
      unregister: { _, _ in
        removed += 1
        return noErr
      })
    observer?.setEnabled(true)
    #expect(observer?.isMonitoring == true)
    observer = nil
    #expect(removed == 3)
  }

  @Test func nativeOutputCatalogAndListenerLifecycleAreReadable() throws {
    let before = AudioOutputCatalog.defaultUID()
    let outputs = try #require(AudioOutputCatalog.read())
    print("Native audio outputs: \(outputs.count); default available: \(before != nil)")
    #expect(outputs.allSatisfy { !$0.uid.isEmpty && !$0.name.isEmpty })
    #expect(Set(outputs.map(\.uid)).count == outputs.count)
    let observer = AudioOutputObserver(changed: {})
    defer { observer.stop() }
    observer.setEnabled(true)
    #expect(observer.isMonitoring)
    observer.setEnabled(false)
    #expect(!observer.isMonitoring)
    if let before { #expect(!before.isEmpty) }
  }

  @Test func audioRulesUseEventsAndInactiveRulesDoNotReadAnOutput() {
    let monitor = TriggerMonitor(readPower: { .init() }, changed: {})
    defer { monitor.stop() }
    let rule = TriggerRule(
      name: "Studio", criteria: [.audioOutput(uid: "studio-output", name: "Speakers")])
    #expect(monitor.read().audioOutputUID == nil)
    monitor.configure(rules: [rule])
    #expect(monitor.pollingInterval == nil)
    let reading = monitor.read().audioOutputUID
    if let reading { #expect(!reading.isEmpty) }
    var disabled = rule
    disabled.enabled = false
    monitor.configure(rules: [disabled])
    #expect(monitor.read().audioOutputUID == nil)
    var paused = rule
    paused.pausedUntil = Date().addingTimeInterval(60)
    monitor.configure(rules: [paused])
    #expect(monitor.read().audioOutputUID == nil)
    monitor.stop()
    #expect(monitor.pollingInterval == nil)
  }
}
