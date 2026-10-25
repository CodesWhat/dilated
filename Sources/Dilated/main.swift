import AppIntents
import AppKit
import DilatedUI

let automation = AutomationService.shared
AppDependencyManager.shared.add(dependency: automation)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = ApplicationDelegate()
application.delegate = delegate
application.run()
