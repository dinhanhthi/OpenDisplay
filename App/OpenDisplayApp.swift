// The app entry: an AppKit delegate that owns the updater and the menu bar item.
import AppKit

/// AppKit entry point: no SwiftUI `App`, so SwiftUI is only loaded inside the popover.
@main
@MainActor
enum OpenDisplayApp {
    // NSApplication.delegate is weak; keep the delegate alive for the app lifetime.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        // Menu bar only: no Dock icon, no main menu, no windows.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Owns the updater and the status item for the app lifetime.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Sparkle; stays off until `SUPublicEDKey` is set.
    let updater = Updater()

    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(updater: updater)
        updater.start()
    }
}
