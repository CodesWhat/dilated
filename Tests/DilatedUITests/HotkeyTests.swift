import AppKit
import Carbon.HIToolbox
import Testing

@testable import DilatedUI

@MainActor struct HotkeyTests {
  @Test func carbonHotkeyDispatchInvokesTheRegisteredAction() throws {
    _ = NSApplication.shared
    let shortcuts = GlobalShortcuts()
    var calls = 0
    try #require(
      shortcuts.register(
        .init(keyCode: kVK_F20, modifiers: cmdKey | optionKey | controlKey | shiftKey)
      ) { calls += 1 })
    defer { shortcuts.unregisterAll() }
    var event: EventRef?
    #expect(
      CreateEvent(
        nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(), 0,
        &event) == noErr)
    let keyEvent = try #require(event)
    defer { ReleaseEvent(keyEvent) }
    var id = EventHotKeyID(signature: 0x4449_4C41, id: 1)
    #expect(
      SetEventParameter(
        keyEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        MemoryLayout<EventHotKeyID>.size, &id) == noErr)
    #expect(SendEventToEventTarget(keyEvent, GetApplicationEventTarget()) == noErr)
    #expect(calls == 1)
    shortcuts.unregisterAll()
    _ = SendEventToEventTarget(keyEvent, GetApplicationEventTarget())
    #expect(calls == 1)
  }
}
