import AppKit
import DilatedControl
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CustomGlyphVariant: Sendable { case active, idle }

public struct CustomGlyph: Codable, Equatable, Sendable {
  public let id: UUID
  public let name: String
  init(id: UUID = UUID(), name: String) {
    self.id = id
    self.name = name
  }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    guard !name.isEmpty, name.count <= 200 else {
      throw DecodingError.dataCorruptedError(
        forKey: .name, in: values, debugDescription: "Invalid custom glyph name.")
    }
  }
}

@MainActor struct CustomGlyphStore {
  let directory: URL
  private var folder: URL { directory.appendingPathComponent("glyphs", isDirectory: true) }
  nonisolated static func readInput(_ file: URL) throws -> Data {
    guard file.isFileURL,
      try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
        == .typeRegular
    else { throw InputError("Choose a regular PNG file.") }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var data = Data()
    while data.count <= 2_000_000 {
      try Task.checkCancellation()
      guard let next = try handle.read(upToCount: min(65536, 2_000_001 - data.count)), !next.isEmpty
      else { break }
      data.append(next)
    }
    guard !data.isEmpty, data.count <= 2_000_000 else {
      throw InputError("Choose a PNG up to 2 MB.")
    }
    return data
  }
  func save(_ data: Data, name: String) throws -> CustomGlyph {
    let image = try Self.decode(data)
    let normalized = try Self.canvas(image, width: 32, height: 30)
    try Self.validateAlpha(normalized)
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else {
      throw InputError("Couldn't prepare the custom icon.")
    }
    CGImageDestinationAddImage(destination, normalized, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw InputError("Couldn't encode the custom icon.")
    }
    let label = String(name.prefix(200))
    let glyph = CustomGlyph(name: label.isEmpty ? "Custom PNG" : label)
    let file = folder.appendingPathComponent(glyph.id.uuidString + ".png")
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    do {
      try (output as Data).write(to: file, options: [.atomic])
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } catch {
      try? FileManager.default.removeItem(at: file)
      throw error
    }
    return glyph
  }
  func image(_ glyph: CustomGlyph) throws -> NSImage {
    let data = try Self.readInput(folder.appendingPathComponent(glyph.id.uuidString + ".png"))
    let decoded = try Self.decode(data)
    guard decoded.width == 32, decoded.height == 30 else {
      throw InputError("The saved custom icon is invalid. Import it again.")
    }
    let image = NSImage(size: NSSize(width: 16, height: 15))
    for (width, height) in [(16, 15), (32, 30)] {
      let representation = NSBitmapImageRep(
        cgImage: try Self.canvas(decoded, width: width, height: height))
      representation.size = image.size
      image.addRepresentation(representation)
    }
    image.isTemplate = true
    image.accessibilityDescription = "Dilated, \(glyph.name)"
    return image
  }
  func remove(_ glyph: CustomGlyph) throws {
    do {
      try FileManager.default.removeItem(
        at: folder.appendingPathComponent(glyph.id.uuidString + ".png"))
    } catch let error as CocoaError where error.code == .fileNoSuchFile {}
  }
  private static func decode(_ data: Data) throws -> CGImage {
    guard !data.isEmpty, data.count <= 2_000_000,
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetType(source) == UTType.png.identifier as CFString,
      CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
      let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
      (1...512).contains(width.intValue), (1...512).contains(height.intValue),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw InputError("Choose one static PNG, up to 512 × 512 pixels and 2 MB.") }
    try validateAlpha(image)
    return image
  }
  private static func context(width: Int, height: Int) throws -> CGContext {
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
          | CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw InputError("Couldn't prepare the icon pixels.") }
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    return context
  }
  private static func validateAlpha(_ image: CGImage) throws {
    let context = try context(width: image.width, height: image.height)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
      throw InputError("Couldn't read the icon pixels.")
    }
    var visible = false
    var clear = false
    for offset in stride(from: 3, to: image.width * image.height * 4, by: 4) {
      visible = visible || bytes[offset] > 0
      clear = clear || bytes[offset] == 0
      if visible && clear { return }
    }
    throw InputError("Use a visible icon on a transparent background.")
  }
  private static func canvas(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
    let context = try context(width: width, height: height)
    let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
    let fittedWidth = Double(image.width) * scale
    let fittedHeight = Double(image.height) * scale
    context.interpolationQuality = .high
    context.draw(
      image,
      in: CGRect(
        x: (Double(width) - fittedWidth) / 2, y: (Double(height) - fittedHeight) / 2,
        width: fittedWidth, height: fittedHeight))
    context.setBlendMode(.sourceIn)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let result = context.makeImage() else {
      throw InputError("Couldn't resize the custom icon.")
    }
    return result
  }
}
