// Adapted from CodesWhat/Mouthtype, authored by Scott Benson, relicensed under MIT.
import AppKit
import Carbon.HIToolbox
import OSLog

/// System-wide key shortcuts through Carbon `RegisterEventHotKey`, which needs no extra permissions.
@MainActor
final class GlobalShortcuts: ShortcutRegistering {
  struct Shortcut: Equatable, Hashable {
    var keyCode: Int
    var modifiers: Int

    static let toggle = Shortcut(keyCode: kVK_ANSI_D, modifiers: cmdKey | controlKey | optionKey)
  }

  private static let signature: OSType = 0x4449_4C41  // 'DILA'

  private var actions: [UInt32: @MainActor () -> Void] = [:]
  private var refs: [EventHotKeyRef] = []
  private var handler: EventHandlerRef?
  private var nextID: UInt32 = 1

  /// False when the system refused the combination (another app holds it).
  @discardableResult
  func register(_ shortcut: Shortcut, action: @escaping @MainActor () -> Void) -> Bool {
    guard (0..<128).contains(shortcut.keyCode), shortcut.modifiers >= 0,
      shortcut.modifiers & ~(cmdKey | controlKey | optionKey | shiftKey) == 0
    else { return false }
    installHandlerIfNeeded()
    let id = nextID
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(shortcut.keyCode), UInt32(shortcut.modifiers),
      EventHotKeyID(signature: Self.signature, id: id),
      GetApplicationEventTarget(), 0, &ref
    )
    guard status == noErr, let ref else {
      Logger(subsystem: "com.codeswhat.dilated", category: "App").error(
        "global shortcut \(shortcut.keyCode, privacy: .public) not registered: \(status, privacy: .public)"
      )
      return false
    }
    nextID += 1
    refs.append(ref)
    actions[id] = action
    return true
  }

  func unregisterAll() {
    for ref in refs { UnregisterEventHotKey(ref) }
    refs = []
    actions = [:]
    if let handler {
      RemoveEventHandler(handler)
      self.handler = nil
    }
  }

  fileprivate func fire(_ id: UInt32) {
    actions[id]?()
  }

  private func installHandlerIfNeeded() {
    guard handler == nil else { return }
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(), hotKeyCallback, 1, &spec,
      Unmanaged.passUnretained(self).toOpaque(), &handler
    )
  }
}

private let hotKeyCallback: EventHandlerUPP = { _, event, userData in
  guard let event, let userData else { return OSStatus(eventNotHandledErr) }
  var id = EventHotKeyID()
  let status = GetEventParameter(
    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
    MemoryLayout<EventHotKeyID>.size, nil, &id
  )
  guard status == noErr else { return status }
  let shortcuts = Unmanaged<GlobalShortcuts>.fromOpaque(userData)
  MainActor.assumeIsolated { shortcuts.takeUnretainedValue().fire(id.id) }
  return noErr
}
