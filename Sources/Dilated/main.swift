import AppKit
import DilatedUI

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = ApplicationDelegate()
application.delegate = delegate
application.run()
