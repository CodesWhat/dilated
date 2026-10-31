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
    case .bugEyes: ["off", "on0", "on1", "look-left", "look-right"]
    case .can: ["off", "wake0", "wake1", "wake2", "on", "blink"]
    case .spiralEyes: ["off", "on0", "on1", "on2", "on3"]
    case .catCans: ["off", "on"]
    }
  }
  public var stillFrame: String { self == .bugEyes || self == .spiralEyes ? "on0" : "on" }
  @MainActor private static var imageCache: [String: NSImage] = [:]
  @MainActor public func image(frame: String) -> NSImage? {
    let key = "\(rawValue)/\(frame)"
    if let cached = Self.imageCache[key] { return cached }
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
    Self.imageCache[key] = image
    return image
  }
  public func previewFrame(elapsed: TimeInterval, reduceMotion: Bool) -> String {
    guard !reduceMotion, elapsed.isFinite else { return stillFrame }
    let phase = max(0, elapsed).truncatingRemainder(dividingBy: Double(frames.count) * 0.75)
    return frames[Int(phase / 0.75)]
  }
  public func animates(motion: Motion, reduceMotion: Bool) -> Bool {
    motion != .off && !reduceMotion && self != .catCans
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
      let phase = elapsed.truncatingRemainder(dividingBy: motion == .subtle ? 10 : 5)
      if (0.25..<0.75).contains(phase) { return "look-left" }
      if (1..<1.5).contains(phase) { return "look-right" }
      return stillFrame
    case .spiralEyes:
      let phase = elapsed.truncatingRemainder(dividingBy: motion == .subtle ? 12 : 6)
      return phase < 2 ? "on\(Int(phase * 8) % 4)" : stillFrame
    case .catCans: return "on"
    }
  }
}
