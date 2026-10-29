import AppKit
import DilatedControl
import DilatedCore
import Testing

@testable import DilatedUI

@MainActor struct SettingsWindowTests {
  @Test func accessibilityChangesKeepOneHostingViewAndSwapOnlyTheContainer() throws {
    _ = NSApplication.shared
    FontRegistry.registerBundledFonts()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(endpoint: .init(stateDirectory: directory), power: { .init() })
    defer { model.shutdown() }
    let controller = SettingsWindow(model: model)
    defer {
      controller.stop()
      controller.close()
    }
    let window = try #require(controller.window)
    let hosting = controller.hostingViewForTesting

    func expectSolid() {
      #expect(window.contentView === hosting)
      #expect(hosting.window === window)
      #expect(window.backgroundColor == .windowBackgroundColor)
    }
    func expectGlass() {
      let glass = window.contentView as? NSGlassEffectView
      #expect(glass != nil)
      #expect(glass?.contentView === hosting)
      #expect(hosting.window === window)
      #expect(hosting.superview != nil)
      #expect(glass.map { hosting.isDescendant(of: $0) } == true)
      #expect(window.backgroundColor == .clear)
    }

    controller.applyContent(solid: true)
    expectSolid()
    controller.applyContent(solid: true)
    expectSolid()
    controller.applyContent(solid: false)
    expectGlass()
    controller.applyContent(solid: false)
    expectGlass()
    controller.applyContent(solid: true)
    expectSolid()
    controller.applyContent(solid: false)
    expectGlass()
    #expect(controller.hostingViewForTesting === hosting)
  }
}
