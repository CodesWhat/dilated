import AppKit
import DilatedControl
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import DilatedUI

@MainActor struct CustomGlyphTests {
  @Test func importsProducePrivateTemplateImagesAtBothResolutions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CustomGlyphStore(directory: directory)
    let glyph = try store.save(try glyphPNG(width: 96, height: 48), name: "Wide.png")
    let image = try store.image(glyph)
    #expect(image.isTemplate && image.size == NSSize(width: 16, height: 15))
    let sizes = image.representations.map { [$0.pixelsWide, $0.pixelsHigh] }
    #expect(sizes == [[16, 15], [32, 30]])
    let bitmap = try #require(image.representations.last as? NSBitmapImageRep)
    #expect(bitmap.colorAt(x: 16, y: 0)?.alphaComponent == 0)
    #expect(bitmap.colorAt(x: 12, y: 15)?.alphaComponent ?? 0 > 0)
    let file = directory.appendingPathComponent("glyphs/\(glyph.id.uuidString).png")
    let permissions =
      try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    #expect(glyph.name == "Wide.png")
  }

  @Test func importedColorsBecomeABlackAlphaTemplate() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CustomGlyphStore(directory: directory)
    let glyph = try store.save(
      try glyphPNG(color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)), name: "Red.png")
    let bitmap = try #require(try store.image(glyph).representations.last as? NSBitmapImageRep)
    let color = try #require(bitmap.colorAt(x: 12, y: 15)?.usingColorSpace(.deviceRGB))
    #expect(color.alphaComponent > 0)
    #expect(color.redComponent == 0 && color.greenComponent == 0 && color.blueComponent == 0)
  }

  @Test func malformedOversizedOpaqueAndEmptyImagesAreRejected() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CustomGlyphStore(directory: directory)
    for bytes in [
      Data(), Data([1, 2, 3]), Data(repeating: 0, count: 2_000_001),
      try glyphPNG(width: 513, height: 16), try glyphPNG(opaque: true),
      try glyphPNG(empty: true),
    ] {
      #expect(throws: (any Error).self) { try store.save(bytes, name: "Invalid.png") }
    }
    #expect(
      !FileManager.default.fileExists(atPath: directory.appendingPathComponent("glyphs").path))
  }

  @Test func legacyAndMalformedImagePreferencesKeepOtherSettings() throws {
    let old = try JSONDecoder().decode(
      AppSettings.self, from: Data(#"{"glyph":"can","batteryFloor":30}"#.utf8))
    #expect(!old.useCustomGlyph && old.customGlyph == nil && old.customGlyphDimIdle)
    let broken = try JSONDecoder().decode(
      AppSettings.self,
      from: Data(
        #"{"glyph":"can","useCustomGlyph":true,"customGlyph":{"id":"bad","name":"Old"},"batteryFloor":30}"#
          .utf8))
    #expect(broken.glyph == .can && broken.batteryFloor == 30)
    #expect(broken.useCustomGlyph && broken.customGlyph == nil)
  }

  @Test func replacementAndRemovalAreTransactionalAndPreserveThePauseAndBundledChoice() async throws
  {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    model.settings.glyph = .catCans
    model.settings.lowOpacityIdle = false
    model.stopAll()
    let input = directory.appendingPathComponent("input.png")
    try glyphPNG().write(to: input)
    try await model.importCustomGlyph(from: input)
    let original = try #require(model.settings.customGlyph)
    #expect(model.settings.useCustomGlyph && model.settings.customGlyphDimIdle)
    #expect(model.settings.glyph == .catCans && !model.settings.lowOpacityIdle)
    #expect(model.engine.automationPaused && model.engine.holds.isEmpty)
    let settingsFile = directory.appendingPathComponent("settings.json")
    try FileManager.default.removeItem(at: settingsFile)
    try FileManager.default.createDirectory(at: settingsFile, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) { try await model.importCustomGlyph(from: input) }
    #expect(model.settings.customGlyph == original)
    #expect(throws: (any Error).self) { try model.removeCustomGlyph() }
    #expect(try CustomGlyphStore(directory: directory).image(original).isTemplate)
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: directory.appendingPathComponent("glyphs").path
      ).count == 1)
    try FileManager.default.removeItem(at: settingsFile)
    try await model.importCustomGlyph(from: input)
    let replacement = try #require(model.settings.customGlyph)
    #expect(replacement.id != original.id)
    #expect(throws: (any Error).self) { try CustomGlyphStore(directory: directory).image(original) }
    let restored = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: settingsFile))
    #expect(restored.customGlyph == replacement && restored.useCustomGlyph)
    try model.removeCustomGlyph()
    #expect(!model.settings.useCustomGlyph && model.settings.customGlyph == nil)
    #expect(model.settings.glyph == .catCans && model.engine.automationPaused)
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: directory.appendingPathComponent("glyphs").path
      ).isEmpty)
  }

  @Test func aMissingCustomFileFallsBackWithoutLosingTheStatusItem() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    model.settings.useCustomGlyph = true
    model.settings.customGlyph = .init(id: UUID(), name: "Missing")
    let controller = MenuBarController(model: model, openSettings: {})
    defer { controller.stop() }
    let image = try #require(controller.statusItem.button?.image)
    #expect(image.isTemplate && image.size.width == 16)
    #expect(model.customGlyphIssue != nil && model.engine.holds.isEmpty)
    model.settings.useCustomGlyph = false
    controller.refresh()
    #expect(model.customGlyphIssue == nil)
  }

  @Test func aStaticBundledGlyphDoesNotScheduleMotionWork() {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    model.settings.glyph = .catCans
    model.settings.motion = .lively
    model.start(duration: 60)
    var scheduled = 0
    let controller = MenuBarController(
      model: model, openSettings: {},
      makeTimer: { seconds, repeats, _ in
        scheduled += 1
        return Timer(timeInterval: seconds, repeats: repeats) { _ in }
      })
    defer { controller.stop() }
    #expect(controller.statusItem.button?.image != nil)
    #expect(scheduled == 0)
  }

  @Test func animatedPNGAndOtherTransparentFormatsAreRejected() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CustomGlyphStore(directory: directory)
    let animated = try glyphPNG(animated: true)
    let source = try #require(CGImageSourceCreateWithData(animated as CFData, nil))
    try #require(CGImageSourceGetCount(source) == 2)
    #expect(throws: (any Error).self) { try store.save(animated, name: "Animated.png") }
    let gif = try glyphPNG(format: .gif)
    #expect(throws: (any Error).self) { try store.save(gif, name: "Disguised.png") }
  }

  @Test func aCustomSelectionCancelsMotionAndRefreshesTheImageWhenReplaced() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    var timers: [Timer] = []
    let controller = MenuBarController(
      model: model, openSettings: {},
      makeTimer: { seconds, repeats, _ in
        let timer = Timer(timeInterval: seconds, repeats: repeats) { _ in }
        timers.append(timer)
        return timer
      })
    defer { controller.stop() }
    model.start(duration: 60)
    controller.refresh()
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      #expect(timers.count == 2 && timers.allSatisfy(\.isValid))
    }
    let input = directory.appendingPathComponent("input.png")
    try glyphPNG().write(to: input)
    try await model.importCustomGlyph(from: input)
    controller.refresh()
    #expect(timers.allSatisfy { !$0.isValid })
    let count = timers.count
    let before = try #require(controller.statusItem.button?.image?.tiffRepresentation)
    try glyphPNG(right: true).write(to: input)
    try await model.importCustomGlyph(from: input)
    controller.refresh()
    let after = try #require(controller.statusItem.button?.image?.tiffRepresentation)
    #expect(before != after && timers.count == count)
    #expect(controller.statusItem.button?.alphaValue == 1)
    model.stopAll()
    controller.refresh()
    #expect(controller.statusItem.button?.alphaValue == 0.5)
    model.settings.customGlyphDimIdle = false
    controller.refresh()
    #expect(controller.statusItem.button?.alphaValue == 1)
    #expect(model.engine.automationPaused && timers.count == count)
  }
}

@MainActor private func glyphPNG(
  width: Int = 32, height: Int = 30, opaque: Bool = false, empty: Bool = false, right: Bool = false,
  format: UTType = .png, animated: Bool = false, color: CGColor = CGColor(gray: 0, alpha: 1)
) throws -> Data {
  let context = try #require(
    CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    ))
  context.clear(CGRect(x: 0, y: 0, width: width, height: height))
  context.setFillColor(color)
  if opaque {
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  } else if !empty {
    let start = right ? width / 2 : width / 4
    context.fill(CGRect(x: start, y: height / 4, width: max(1, width / 4), height: height / 2))
  }
  let image = try #require(context.makeImage())
  let data = NSMutableData()
  let destination = try #require(
    CGImageDestinationCreateWithData(data, format.identifier as CFString, animated ? 2 : 1, nil))
  let properties =
    animated
    ? [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1]] as CFDictionary : nil
  CGImageDestinationAddImage(destination, image, properties)
  if animated { CGImageDestinationAddImage(destination, image, properties) }
  try #require(CGImageDestinationFinalize(destination))
  return data as Data
}
