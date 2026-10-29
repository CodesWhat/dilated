import AppKit
import DilatedCore
import SwiftUI
import Testing

@testable import DilatedUI

@MainActor struct SettingsGroupLayoutTests {
  @Test func groupHeightIsUnchangedByRowIdentityKeying() {
    _ = NSApplication.shared
    FontRegistry.registerBundledFonts()
    let view = NSHostingView(
      rootView: SettingsGroup(eyebrow: "TEST") {
        Text("a")
        Text("b")
        Text("c")
      }.frame(width: 400))
    view.setFrameSize(NSSize(width: 400, height: 10))
    view.layoutSubtreeIfNeeded()
    #expect(view.fittingSize.height == 130)
  }
  @Test func groupHeightIsUnchangedWithANarrowRow() {
    _ = NSApplication.shared
    FontRegistry.registerBundledFonts()
    let view = NSHostingView(
      rootView: SettingsGroup(eyebrow: "TEST") {
        Text("a")
        Button("x") {}
      }.frame(width: 400))
    view.setFrameSize(NSSize(width: 400, height: 10))
    view.layoutSubtreeIfNeeded()
    #expect(view.fittingSize.height == 105)
  }
  @Test func loneNarrowRowStaysAtTheLeadingEdge() throws {
    _ = NSApplication.shared
    FontRegistry.registerBundledFonts()
    let view = NSHostingView(
      rootView: SettingsGroup(eyebrow: "TEST") {
        Color(red: 1, green: 0, blue: 0).frame(width: 20, height: 20)
      }.frame(width: 400))
    view.setFrameSize(NSSize(width: 400, height: 10))
    view.setFrameSize(view.fittingSize)
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    var leftmost = bitmap.pixelsWide
    for y in (bitmap.pixelsHigh * 3 / 5)..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide {
        guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        if c.redComponent > 0.7 && c.greenComponent < 0.4 && c.blueComponent < 0.4 {
          leftmost = min(leftmost, x)
        }
      }
    }
    #expect(leftmost < bitmap.pixelsWide / 4)
  }
}
