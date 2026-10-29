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
}
