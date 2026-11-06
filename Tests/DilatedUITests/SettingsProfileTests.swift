import DilatedCore
import Foundation
import Testing

@testable import DilatedUI

@MainActor struct SettingsProfileTests {
  @Test func portablePreferencesRoundTripWithoutLocalPolicyOrAssets() throws {
    var source = AppSettings()
    source.defaultMinutes = 45
    source.presets = [15, 45]
    source.glyph = .spiralEyes
    source.useCustomGlyph = true
    source.closedLidBatteryWarningAccepted = true
    source.overrideLowPower = true
    let profile = SettingsProfile(settings: source)
    let data = try profile.encoded()
    #expect(try SettingsProfile.decode(data) == profile)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for local in [
      "closedLidBatteryWarningAccepted", "overrideLowPower", "customGlyph", "shortcuts",
      "driveAlive", "triggersEnabled",
    ] {
      #expect(object[local] == nil)
    }
    var local = AppSettings()
    local.batteryFloor = 50
    local.closedLidBatteryFloor = 60
    local.startAtLaunch = false
    local.urlAutomation = false
    let applied = try profile.applying(to: local)
    #expect(applied.defaultMinutes == 45 && applied.presets == [15, 45])
    #expect(applied.glyph == .spiralEyes && !applied.useCustomGlyph)
    #expect(applied.batteryFloor == 50 && applied.closedLidBatteryFloor == 60)
    #expect(!applied.overrideLowPower && !applied.startAtLaunch && !applied.urlAutomation)
  }

  @Test func foreignKeysCannotChangeLocalSafetyOrAutomation() throws {
    let data = try SettingsProfile(settings: AppSettings()).encoded()
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["closedLidBatteryFloor"] = 10
    object["overrideLowPower"] = true
    object["triggersEnabled"] = true
    object["startAfterWake"] = true
    let profile = try SettingsProfile.decode(JSONSerialization.data(withJSONObject: object))
    var local = AppSettings()
    local.closedLidBatteryFloor = 80
    local.triggersEnabled = false
    let imported = try profile.applying(to: local)
    #expect(imported.closedLidBatteryFloor == 80 && !imported.triggersEnabled)
    #expect(!imported.overrideLowPower && !imported.startAfterWake)
  }

  @Test func malformedUnsupportedAndOutOfRangeFilesAreRejected() throws {
    let valid = try SettingsProfile(settings: AppSettings()).encoded()
    let original = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
    for (key, value) in [
      ("schemaVersion", 2 as Any), ("defaultMinutes", -1), ("defaultMinutes", 10081),
      ("defaultMinutes", 1),
      ("presets", []), ("presets", [15, 15]), ("presets", Array(1...11)),
      ("presets", [10081]), ("dockMode", "unknown"), ("glyph", "missing"),
      ("countdown", "yes"),
    ] {
      var invalid = original
      invalid[key] = value
      let data = try JSONSerialization.data(withJSONObject: invalid)
      #expect(throws: (any Error).self) { try SettingsProfile.decode(data) }
    }
    #expect(throws: (any Error).self) { try SettingsProfile.decode(Data("broken".utf8)) }
    #expect(throws: (any Error).self) {
      try SettingsProfile.decode(Data(repeating: 32, count: 65537))
    }
  }

  @Test func fileReadIsBoundedAndExportHasPrivatePermissions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("preferences.json")
    let profile = SettingsProfile(settings: AppSettings())
    try profile.write(to: file)
    #expect(try SettingsProfile.read(from: file) == profile)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
    #expect(throws: (any Error).self) { try SettingsProfile.read(from: directory) }
    try Data(repeating: 32, count: 65537).write(to: file)
    #expect(throws: (any Error).self) { try SettingsProfile.read(from: file) }
  }

  @Test func applyPreservesStopAndManualHoldsAndFailedWritesPreservePreferences() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    model.stopAll()
    model.start(duration: 120)
    let holds = model.engine.holds
    var source = AppSettings()
    source.defaultMinutes = 45
    source.presets = [15, 45]
    source.allowDisplaySleep = false
    let profile = SettingsProfile(settings: source)
    try model.applySettingsProfile(profile)
    #expect(model.settings.defaultMinutes == 45)
    #expect(model.engine.automationPaused && model.engine.holds == holds)
    let before = model.settings
    let file = directory.appendingPathComponent("settings.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) {
      try model.applySettingsProfile(SettingsProfile(settings: AppSettings()))
    }
    #expect(model.settings == before && model.engine.holds == holds)
    model.shutdown()
    #expect(throws: (any Error).self) { try model.applySettingsProfile(profile) }
  }
}
