import AppKit
import Carbon.HIToolbox
import DilatedControl
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct ShortcutPreferencesTests {
  private var first: AwakeShortcut {
    .init(keyCode: kVK_F19, modifiers: cmdKey | controlKey, keyName: "F19")
  }
  private var second: AwakeShortcut {
    .init(keyCode: kVK_F20, modifiers: cmdKey | controlKey, keyName: "F20")
  }

  @Test func shortcutRowsExposeTheAssignedShortcutAsTheAccessibilityValue() {
    #expect(ShortcutsSettings.accessibilityValue(for: nil) == "Not assigned")
    #expect(ShortcutsSettings.accessibilityValue(for: first) == first.displayName)
  }

  @Test func collisionsRestoreTheWorkingAssignmentsAndCallbacks() {
    let registrar = ShortcutRegistrarFixture()
    let bindings = ShortcutBindings(registrar: registrar)
    var oldCalls = 0
    var newCalls = 0
    #expect(bindings.update([.toggle: first]) { _ in oldCalls += 1 } == nil)
    registrar.reject = second.chord
    #expect(bindings.update([.stop: second]) { _ in newCalls += 1 } != nil)
    #expect(bindings.configuration == [.toggle: first])
    #expect(registrar.active.count == 1)
    registrar.active[first.chord]?()
    #expect(oldCalls == 1 && newCalls == 0)
    bindings.stop()
    #expect(registrar.active.isEmpty)
  }

  @Test func duplicateChordsAndUnmodifiedTypingKeysAreRejectedBeforeRegistration() {
    let registrar = ShortcutRegistrarFixture()
    let bindings = ShortcutBindings(registrar: registrar)
    #expect(bindings.update([.toggle: first, .stop: first]) { _ in } != nil)
    #expect(registrar.registrationCount == 0)
    #expect(!AwakeShortcut(keyCode: kVK_ANSI_A, modifiers: 0, keyName: "A").isValid)
    #expect(!AwakeShortcut(keyCode: -1, modifiers: cmdKey, keyName: "Bad").isValid)
    #expect(!AwakeShortcut(keyCode: 128, modifiers: cmdKey, keyName: "Bad").isValid)
  }

  @Test func failedPersistenceDoesNotInstallAnUnsavedShortcut() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data().write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let model = AppModel(endpoint: .init(stateDirectory: file), power: { .init() })
    defer { model.shutdown() }
    var installed = 0
    model.onShortcutAssignment = { _ in
      installed += 1
      return nil
    }
    let before = model.settings.shortcuts
    #expect(throws: (any Error).self) { try model.assignShortcut(second, to: .stop) }
    #expect(installed == 0)
    #expect(model.settings.shortcuts == before)
  }

  @Test func invalidSavedShortcutDoesNotResetBatterySafetyPreferences() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    var settings = AppSettings()
    settings.batteryFloor = 30
    settings.shortcuts = [.toggle: .init(keyCode: -1, modifiers: cmdKey, keyName: "Invalid")]
    try JSONEncoder().encode(settings).write(to: directory.appendingPathComponent("settings.json"))
    let model = AppModel(
      endpoint: .init(stateDirectory: directory),
      power: { .init(onBattery: true, batteryPercent: 20) })
    defer { model.shutdown() }
    #expect(model.settings.batteryFloor == 30)
    #expect(model.engine.batteryFloor == 30)
    #expect(model.settings.shortcuts.isEmpty)
    #expect(model.message?.contains("shortcut") == true)
  }

  @Test func deniedAssignmentsDoNotChangeSavedPreferences() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    let before = model.settings.shortcuts
    model.onShortcutAssignment = { _ in "Already in use" }
    #expect(throws: (any Error).self) { try model.assignShortcut(second, to: .stop) }
    #expect(model.settings.shortcuts == before)
    model.onShortcutAssignment = { _ in nil }
    try model.assignShortcut(second, to: .stop)
    let restored = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { restored.shutdown() }
    #expect(restored.settings.shortcuts[.stop] == second)
    try model.assignShortcut(nil, to: .toggle)
    #expect(model.settings.shortcuts[.toggle] == nil)
  }
}

@MainActor private final class ShortcutRegistrarFixture: ShortcutRegistering {
  var active: [GlobalShortcuts.Shortcut: @MainActor () -> Void] = [:]
  var reject: GlobalShortcuts.Shortcut?
  var registrationCount = 0
  func register(_ shortcut: GlobalShortcuts.Shortcut, action: @escaping @MainActor () -> Void)
    -> Bool
  {
    registrationCount += 1
    guard shortcut != reject else { return false }
    active[shortcut] = action
    return true
  }
  func unregisterAll() { active = [:] }
}
