import AppKit
import Carbon.HIToolbox

public enum ShortcutAction: String, Codable, CaseIterable, Identifiable, Sendable {
  case toggle, startDefault, stop, start15, start60, toggleDisplay, openMenu
  public var id: String { rawValue }
  public var label: String {
    switch self {
    case .toggle: "Start or stop"
    case .startDefault: "Start with default duration"
    case .stop: "Stop all and pause automation"
    case .start15: "Keep awake for 15 minutes"
    case .start60: "Keep awake for 1 hour"
    case .toggleDisplay: "Toggle display sleep for active holds"
    case .openMenu: "Open menu bar menu"
    }
  }
}

public struct AwakeShortcut: Codable, Equatable, Sendable {
  public var keyCode: Int
  public var modifiers: Int
  public var keyName: String
  public init(keyCode: Int, modifiers: Int, keyName: String) {
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.keyName = keyName
  }
  public var isValid: Bool {
    (0..<128).contains(keyCode) && modifiers & ~(cmdKey | controlKey | optionKey | shiftKey) == 0
      && modifiers & (cmdKey | controlKey) != 0 && !keyName.isEmpty && keyName.count <= 40
      && !keyName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
  public var displayName: String {
    [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
      .filter { modifiers & $0.0 != 0 }.map(\.1).joined() + keyName
  }
  static let defaults: [ShortcutAction: AwakeShortcut] = [
    .toggle: .init(keyCode: kVK_ANSI_D, modifiers: cmdKey | controlKey | optionKey, keyName: "D")
  ]
  var chord: GlobalShortcuts.Shortcut { .init(keyCode: keyCode, modifiers: modifiers) }

  init?(event: NSEvent) {
    guard event.type == .keyDown, !event.isARepeat else { return nil }
    let flags = event.modifierFlags
    let modifiers =
      (flags.contains(.command) ? cmdKey : 0) | (flags.contains(.control) ? controlKey : 0)
      | (flags.contains(.option) ? optionKey : 0) | (flags.contains(.shift) ? shiftKey : 0)
    self.init(keyCode: Int(event.keyCode), modifiers: modifiers, keyName: Self.name(event))
    guard isValid else { return nil }
  }
  // Key-name lookup adapted from CodesWhat/Mouthtype, Scott Benson, MIT.
  private static func name(_ event: NSEvent) -> String {
    let special: [UInt16: String] = [
      36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape", 71: "Clear",
      76: "Keypad Enter", 114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete",
      119: "End", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    if let name = special[event.keyCode] { return name }
    let functions: [UInt16] = [
      122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]
    if let index = functions.firstIndex(of: event.keyCode) { return "F\(index + 1)" }
    if let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
      !characters.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value)
      })
    {
      return characters.uppercased()
    }
    return "Key \(event.keyCode)"
  }
}

@MainActor protocol ShortcutRegistering: AnyObject {
  func register(_ shortcut: GlobalShortcuts.Shortcut, action: @escaping @MainActor () -> Void)
    -> Bool
  func unregisterAll()
}

@MainActor final class ShortcutBindings {
  private let registrar: any ShortcutRegistering
  private var installed = false
  private var handler: (@MainActor (ShortcutAction) -> Void)?
  private(set) var configuration: [ShortcutAction: AwakeShortcut] = [:]
  init(registrar: any ShortcutRegistering) { self.registrar = registrar }

  nonisolated static func validationError(_ configuration: [ShortcutAction: AwakeShortcut])
    -> String?
  {
    guard configuration.values.allSatisfy(\.isValid) else {
      return "Include Control or Command with a key. Record another shortcut."
    }
    guard Set(configuration.values.map(\.chord)).count == configuration.count else {
      return "That shortcut is already assigned to another Dilated action."
    }
    return nil
  }
  func update(
    _ configuration: [ShortcutAction: AwakeShortcut],
    action: @escaping @MainActor (ShortcutAction) -> Void
  ) -> String? {
    if let error = Self.validationError(configuration) { return error }
    if installed && self.configuration == configuration { return nil }
    let previous = self.configuration
    let previousHandler = handler
    registrar.unregisterAll()
    var failed: ShortcutAction?
    for kind in ShortcutAction.allCases {
      guard let shortcut = configuration[kind] else { continue }
      if !registrar.register(shortcut.chord, action: { action(kind) }) {
        failed = kind
        break
      }
    }
    if let failed {
      registrar.unregisterAll()
      var restored: [ShortcutAction: AwakeShortcut] = [:]
      for kind in ShortcutAction.allCases {
        guard let shortcut = previous[kind] else { continue }
        if registrar.register(shortcut.chord, action: { previousHandler?(kind) }) {
          restored[kind] = shortcut
        }
      }
      self.configuration = restored
      installed = true
      let rollback =
        restored == previous
        ? "Your previous shortcuts are unchanged."
        : "Some previous shortcuts could not be restored."
      return "\(configuration[failed]?.displayName ?? "Shortcut") is unavailable. \(rollback)"
    }
    self.configuration = configuration
    handler = action
    installed = true
    return nil
  }
  func suspend() {
    registrar.unregisterAll()
    installed = false
  }
  func stop() {
    suspend()
    configuration = [:]
    handler = nil
  }
}
