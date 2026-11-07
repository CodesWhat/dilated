import DilatedControl
import Foundation

struct SettingsProfile: Codable, Equatable, Sendable {
  var schemaVersion = 1
  var defaultMinutes: Int
  var presets: [Int]
  var allowDisplaySleep: Bool
  var glyph: Glyph
  var motion: Motion
  var countdown: Bool
  var countdownFormat: CountdownFormat
  var countdownSeconds: CountdownSeconds
  var countdownHourCycle: CountdownHourCycle
  var countdownTextSize: CountdownTextSize
  var swapClicks: Bool
  var lowOpacityIdle: Bool
  var dockMode: String

  init(settings: AppSettings) {
    defaultMinutes = settings.defaultMinutes
    presets = settings.presets
    allowDisplaySleep = settings.allowDisplaySleep
    glyph = settings.glyph
    motion = settings.motion
    countdown = settings.countdown
    countdownFormat = settings.countdownFormat
    countdownSeconds = settings.countdownSeconds
    countdownHourCycle = settings.countdownHourCycle
    countdownTextSize = settings.countdownTextSize
    swapClicks = settings.swapClicks
    lowOpacityIdle = settings.lowOpacityIdle
    dockMode = settings.dockMode
  }

  private func validate() throws {
    guard schemaVersion == 1 else {
      throw InputError("This preferences file uses an unsupported version.")
    }
    guard (0...10080).contains(defaultMinutes), (1...10).contains(presets.count),
      Set(presets).count == presets.count, presets.allSatisfy({ (1...10080).contains($0) }),
      DockIconMode(rawValue: dockMode) != nil
    else {
      throw InputError("The preferences file contains invalid durations or appearance settings.")
    }
  }

  func encoded() throws -> Data {
    try validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }
  static func decode(_ data: Data) throws -> Self {
    guard data.count <= 65536 else {
      throw InputError("Choose a preferences file smaller than 64 KB.")
    }
    let profile = try JSONDecoder().decode(Self.self, from: data)
    try profile.validate()
    return profile
  }
  static func read(from url: URL) throws -> Self {
    guard url.isFileURL else { throw InputError("Choose a local preferences file.") }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let size = values.fileSize, size <= 65536 else {
      throw InputError("Choose a regular preferences file smaller than 64 KB.")
    }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    return try decode(file.read(upToCount: 65537) ?? Data())
  }
  func write(to url: URL) throws {
    try encoded().write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  func applying(to current: AppSettings) throws -> AppSettings {
    try validate()
    var candidate = current
    candidate.defaultMinutes = defaultMinutes
    candidate.presets = presets.sorted()
    candidate.allowDisplaySleep = allowDisplaySleep
    candidate.glyph = glyph
    candidate.useCustomGlyph = false
    candidate.motion = motion
    candidate.countdown = countdown
    candidate.countdownFormat = countdownFormat
    candidate.countdownSeconds = countdownSeconds
    candidate.countdownHourCycle = countdownHourCycle
    candidate.countdownTextSize = countdownTextSize
    candidate.swapClicks = swapClicks
    candidate.lowOpacityIdle = lowOpacityIdle
    candidate.dockMode = dockMode
    return candidate
  }

  struct Change: Identifiable {
    var id: String { label }
    let label: String
    let before: String
    let after: String
  }
  func changes(from current: AppSettings) -> [Change] {
    let old = SettingsProfile(settings: current)
    let previous = old.descriptions(
      icon: current.useCustomGlyph ? "Custom PNG" : current.glyph.label)
    return zip(previous, descriptions(icon: glyph.label)).compactMap { before, after in
      guard before.1 != after.1 else { return nil }
      return Change(label: after.0, before: before.1, after: after.1)
    }
  }
  private func descriptions(icon: String) -> [(String, String)] {
    [
      ("Default duration", defaultMinutes == 0 ? "Indefinite" : "\(defaultMinutes) minutes"),
      ("Duration presets", presets.sorted().map { "\($0) min" }.joined(separator: ", ")),
      ("Allow display sleep", allowDisplaySleep ? "On" : "Off"),
      ("Menu bar icon", icon), ("Icon motion", motion.rawValue.capitalized),
      ("Show countdown", countdown ? "On" : "Off"),
      ("Countdown format", countdownFormat.label), ("Countdown seconds", countdownSeconds.label),
      ("Clock format", countdownHourCycle.label), ("Countdown text size", countdownTextSize.label),
      ("Menu opens with", swapClicks ? "Right click" : "Left click"),
      ("Dim idle icon", lowOpacityIdle ? "On" : "Off"),
      (
        "Show in Dock",
        dockMode == "always" ? "Always" : dockMode == "never" ? "Never" : "While a window is open"
      ),
    ]
  }
}
