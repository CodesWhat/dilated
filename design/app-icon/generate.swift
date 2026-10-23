#!/usr/bin/env swift
import AppKit
import Foundation

let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let root = source.deletingLastPathComponent().deletingLastPathComponent()
let artwork = source.appendingPathComponent("gas-station.svg")
guard let image = NSImage(contentsOf: artwork) else {
  fatalError("Cannot load Gas Station artwork")
}
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
  "dilated-icon-\(UUID().uuidString)")
let iconset = scratch.appendingPathComponent("Dilated.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

for points in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = points * scale
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
    bitmap.bitmapData!.initialize(repeating: 0, count: bitmap.bytesPerRow * pixels)
    bitmap.size = NSSize(width: points, height: points)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(
      in: NSRect(x: 0, y: 0, width: points, height: points), from: .zero,
      operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    let output = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: output, options: .atomic)
  }
}

let output = root.appendingPathComponent("packaging/Dilated.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", output.path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("App icon conversion failed") }
try Data(contentsOf: artwork).write(
  to: root.appendingPathComponent("website/dist/assets/icon-gas-station.svg"), options: .atomic)
print("Generated Gas Station app icon and synchronized website artwork.")
