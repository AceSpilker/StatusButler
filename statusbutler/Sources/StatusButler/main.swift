import AppKit
import StatusButlerCore

// T-002: 入口极薄，一切装配在 AppEnvironment.live()（组合根）
let application = NSApplication.shared
let delegate = StatusButlerCore.AppDelegate()
application.delegate = delegate
application.run()
