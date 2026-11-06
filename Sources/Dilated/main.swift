import AppIntents
import AppKit
import DilatedUI

let automation = AutomationService.shared
AppDependencyManager.shared.add(dependency: automation)
automation.restoreFocusFilter {
  do { return try await SetAwakeFocusFilterIntent.current.rule?.id } catch SetFocusFilterIntentError
    .notFound
  { return nil }
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = ApplicationDelegate()
application.delegate = delegate
application.run()
