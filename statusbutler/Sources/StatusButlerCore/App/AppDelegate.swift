import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let environment = AppEnvironment.live()
        self.environment = environment
        environment.start()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        environment?.stop()
    }
}
