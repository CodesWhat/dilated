#!/usr/bin/env swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let frames = try JSONDecoder().decode(
  [String: [String]].self, from: Data(contentsOf: root.appendingPathComponent("glyphs.json")))
let runtime = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
  "Sources/DilatedUI/Resources/MenuBar")
for (name, rows) in frames.sorted(by: { $0.key < $1.key }) {
  guard rows.count == 15,
    rows.allSatisfy({ $0.count == 16 && $0.allSatisfy { $0 == "#" || $0 == "." } })
  else {
    fatalError("Invalid 16x15 glyph: \(name)")
  }
  for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 16 * scale, pixelsHigh: 15 * scale,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 16 * scale * 4, bitsPerPixel: 32)!
    let pixels = bitmap.bitmapData!
    pixels.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    for (y, row) in rows.enumerated() {
      for (x, pixel) in row.enumerated() where pixel == "#" {
        for dy in 0..<scale {
          for dx in 0..<scale {
            pixels[(y * scale + dy) * bitmap.bytesPerRow + (x * scale + dx) * 4 + 3] = 255
          }
        }
      }
    }
    let data = bitmap.representation(using: .png, properties: [:])!
    let suffix = scale == 2 ? "@2x" : ""
    for base in [root, runtime] {
      let url = base.appendingPathComponent(name + suffix + ".png")
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
    }
  }
}
print("Generated \(frames.count) glyph frames at 1x and 2x in design and runtime resources.")
