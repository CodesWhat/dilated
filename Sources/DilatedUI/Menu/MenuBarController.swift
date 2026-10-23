// Status-item interaction and template image caching adapted from CodesWhat/Mouthtype, Scott Benson, MIT.
import AppKit

@MainActor final class MenuBarController: NSObject, NSMenuDelegate {
  let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let model: AppModel
  private let openSettings: () -> Void
  private var wasAwake = false
  private var began = ProcessInfo.processInfo.systemUptime
  private var burst: Timer?
  private var microMotion: Timer?
  private var cache: [String: NSImage] = [:]
  private var lastFrame = ""
  private var lastGlyph: Glyph?
  private var lastMotion: Motion?
  private var reducedMotion = false

  init(model: AppModel, openSettings: @escaping () -> Void) {
    self.model = model
    self.openSettings = openSettings
    super.init()
    statusItem.button?.target = self
    statusItem.button?.action = #selector(clicked)
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    statusItem.button?.setAccessibilityLabel("Dilated")
    refresh()
  }
  @objc private func clicked() {
    let right = NSApp.currentEvent?.type == .rightMouseUp
    if right != model.settings.swapClicks {
      model.toggle()
      refresh()
      return
    }
    guard let button = statusItem.button else { return }
    let menu = AwakeMenu.make(model: model, openSettings: openSettings)
    menu.delegate = self
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
  }
  func refresh() {
    let awake = !model.engine.holds.isEmpty
    let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if awake != wasAwake || lastGlyph != model.settings.glyph || lastMotion != model.settings.motion
      || reducedMotion != reduce
    {
      wasAwake = awake
      lastGlyph = model.settings.glyph
      lastMotion = model.settings.motion
      reducedMotion = reduce
      began = ProcessInfo.processInfo.systemUptime
      burst?.invalidate()
      microMotion?.invalidate()
      microMotion = nil
      if awake && !reduce && model.settings.motion != .off {
        animateBurst()
        let period: TimeInterval =
          switch model.settings.glyph {
          case .can: 8
          case .spiralEyes: model.settings.motion == .subtle ? 12 : 6
          default: model.settings.motion == .subtle ? 10 : 5
          }
        let timer = Timer(timeInterval: period, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.animateBurst() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        microMotion = timer
      }
    }
    updateImage()
    let expiry = model.engine.holds.compactMap(\.expiry).max()
    statusItem.button?.title =
      model.settings.countdown && awake
      ? " "
        + (model.engine.holds.contains { $0.expiry == nil }
          ? "∞" : expiry.map { AppModel.remaining(until: $0, now: model.now) } ?? "") : ""
    statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    statusItem.button?.alphaValue = !awake && model.settings.lowOpacityIdle ? 0.5 : 1
    statusItem.button?.toolTip = "Dilated: \(model.statusText)"
  }
  private func animateBurst() {
    burst?.invalidate()
    let end = ProcessInfo.processInfo.systemUptime + 2
    let timer = Timer(timeInterval: 0.125, repeats: true) { [weak self] timer in
      guard let self else {
        timer.invalidate()
        return
      }
      MainActor.assumeIsolated {
        guard ProcessInfo.processInfo.systemUptime < end else {
          self.burst?.invalidate()
          return
        }
        self.updateImage()
      }
    }
    timer.tolerance = 0.025
    RunLoop.main.add(timer, forMode: .common)
    burst = timer
  }
  private func updateImage() {
    let glyph = model.settings.glyph
    let frame = glyph.frame(
      awake: !model.engine.holds.isEmpty, elapsed: ProcessInfo.processInfo.systemUptime - began,
      motion: model.settings.motion,
      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    let key = glyph.rawValue + frame
    guard key != lastFrame else { return }
    if cache[key] == nil { cache[key] = glyph.image(frame: frame) }
    guard let image = cache[key] else {
      model.message = "The selected menu bar glyph couldn't be loaded."
      return
    }
    statusItem.button?.image = image
    lastFrame = key
  }
  func stop() {
    burst?.invalidate()
    microMotion?.invalidate()
    NSStatusBar.system.removeStatusItem(statusItem)
  }
}
