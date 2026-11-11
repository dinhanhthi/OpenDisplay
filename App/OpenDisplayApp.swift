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

    /// The connected displays and their modes.
    let displayStore = DisplayStore()

    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The launch refresh: the modes load while the status item is set up.
        displayStore.refresh()
        statusItemController = StatusItemController(updater: updater, displayStore: displayStore)
        updater.start()
    }
}
