// Image loading adapted from CodesWhat/Mouthtype StatusIcon.swift, Scott Benson, MIT.
import AppKit

public enum Motion: String, Codable, CaseIterable, Sendable { case subtle, lively, off }
public enum Glyph: String, Codable, CaseIterable, Sendable {
  case bugEyes = "bug-eyes"
  case can
  case spiralEyes = "spiral-eyes"
  case catCans = "cat-cans"
  public var label: String {
    switch self {
    case .bugEyes: "Bug eyes"
    case .can: "Can"
    case .spiralEyes: "Spiral eyes"
    case .catCans: "Cat cans"
    }
  }
  public var frames: [String] {
    switch self {
    case .bugEyes: ["off", "on0", "on1"]
    case .can: ["off", "wake0", "wake1", "wake2", "on", "blink"]
    case .spiralEyes: ["off", "on0", "on1", "on2", "on3"]
    case .catCans: ["off", "on"]
    }
  }
  public var stillFrame: String { self == .bugEyes || self == .spiralEyes ? "on0" : "on" }
  @MainActor public func image(frame: String) -> NSImage? {
    let image = NSImage(size: NSSize(width: 16, height: 15))
    for suffix in ["", "@2x"] {
      guard
        let url = Bundle.module.url(
          forResource: "\(rawValue)-\(frame)\(suffix)", withExtension: "png",
          subdirectory: "MenuBar/\(rawValue)"),
        let data = try? Data(contentsOf: url), let representation = NSBitmapImageRep(data: data)
      else { return nil }
      representation.size = image.size
      image.addRepresentation(representation)
    }
    image.isTemplate = true
    image.accessibilityDescription = "Dilated, \(label)"
    return image
  }
  public func frame(awake: Bool, elapsed: TimeInterval, motion: Motion, reduceMotion: Bool)
    -> String
  {
    guard awake else { return "off" }
    guard motion != .off && !reduceMotion else { return stillFrame }
    let elapsed = max(0, elapsed)
    switch self {
    case .can:
      if elapsed < 0.45 { return "wake\(min(2, Int(elapsed / 0.15)))" }
      return elapsed > 4 && elapsed.truncatingRemainder(dividingBy: 8) < 0.25 ? "blink" : "on"
    case .bugEyes:
      return elapsed.truncatingRemainder(dividingBy: motion == .subtle ? 10 : 5) < 0.35
        ? "on1" : "on0"
    case .spiralEyes:
      let phase = elapsed.truncatingRemainder(dividingBy: motion == .subtle ? 12 : 6)
      return phase < 2 ? "on\(Int(phase * 8) % 4)" : stillFrame
    case .catCans: return "on"
    }
  }
}
