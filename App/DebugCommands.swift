// DEBUG only: launch arguments that drive a control without a click, for the checks an agent runs
// from a shell. Absent from Release.
#if DEBUG
import AppKit

/// The launch arguments:
/// - `--debug-brightness <vendorHex:modelHex>`: sets that display's brightness, reads it back, restores
///   it, then quits the app.
/// - `--debug-main <vendorHex:modelHex>`: makes that display the main one for 3 seconds, makes the
///   display that was main the main one again, then quits the app.
/// - `--open-popover` (the popover itself is opened by `StatusItemController`): loads the list of
///   installed color profiles once, after the launch refresh. Nothing is set and the app keeps running.
///
/// At most one of the two `--debug-…` commands runs, the first in the order above: each quits the app.
/// A new command is one more `else if let` in `run(store:)` and one function here.
@MainActor
enum DebugCommands {
    /// Runs the command the launch arguments name, if any. Called once, after the launch refresh started.
    static func run(store: DisplayStore) {
        // The list loads when a menu first opens, which a shell cannot do.
        if CommandLine.arguments.contains("--open-popover") {
            Task {
                await store.waitForFirstRefresh()
                store.loadColorProfiles()
            }
        }
        if let hexID = value(of: "--debug-brightness") {
            Task {
                await store.waitForFirstRefresh()
                await brightness(hexID, store: store)
                // The command quits the app itself, so nothing kills it between "set" and "restore".
                NSApp.terminate(nil)
            }
        } else if let hexID = value(of: "--debug-main") {
            Task {
                await store.waitForFirstRefresh()
                await mainDisplay(hexID, store: store)
                // The command quits the app itself, so nothing kills it between "set" and "restore".
                NSApp.terminate(nil)
            }
        }
    }

    /// The argument after `flag`; "" when the flag is last, nil when it is absent.
    private static func value(of flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        return arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
    }

    /// Sets through the store, as the slider does. Every value logged is a new read from the display.
    /// Nothing is set unless the original value could be read; after the first set, nothing returns
    /// before the original value is set again.
    private static func brightness(_ hexID: String, store: DisplayStore) async {
        guard let display = store.displays.first(where: { $0.hexID == hexID }),
              let backend = display.brightnessBackend,
              let before = await Brightness.shared.read(display, backend: backend)
        else {
            debugLog("Brightness", "aborted: cannot read original")
            return
        }
        debugLog("Brightness", "before value=\(text(before))")
        // Always different from the original.
        let target = abs(before - 0.5) <= 0.1 ? 0.8 : 0.5
        debugLog("Brightness", "target value=\(text(target))")

        store.setBrightness(target, on: display.id)
        try? await Task.sleep(for: .seconds(1))
        let read = await Brightness.shared.read(display, backend: backend)
        debugLog("Brightness", "read value=\(text(read))")

        store.setBrightness(before, on: display.id)
        try? await Task.sleep(for: .seconds(1))
        let restored = await Brightness.shared.read(display, backend: backend)
        debugLog("Brightness", "restored.read value=\(text(restored))")
    }

    /// Sets through the store, as the button does. Every display logged is a new `CGMainDisplayID()`.
    /// After the first swap nothing returns before the restore was tried.
    private static func mainDisplay(_ hexID: String, store: DisplayStore) async {
        let original = CGMainDisplayID()
        let vendor = CGDisplayVendorNumber(original), model = CGDisplayModelNumber(original)
        let before = Arrangement.hexID(of: original)
        debugLog("Arrangement", "main.before \(before)")
        guard let display = store.displays.first(where: { $0.hexID == hexID }),
              Arrangement.onlineDisplays().contains(display.id), display.id != original, !display.isMain
        else {
            debugLog("Arrangement", "aborted: nothing to swap")
            return
        }

        _ = await store.setMain(display.id).value
        try? await Task.sleep(for: .seconds(3))
        debugLog("Arrangement", "main.now \(Arrangement.hexID(of: CGMainDisplayID()))")

        // Found again by vendor and model (a display id can change after a reconfiguration), and
        // set without the store, which may not have refreshed yet.
        let matches = Arrangement.onlineDisplays().filter {
            CGDisplayVendorNumber($0) == vendor && CGDisplayModelNumber($0) == model
        }
        // With two monitors of one model, the one that kept the original id.
        if let restore = matches.contains(original) ? original : matches.first {
            _ = await Arrangement.shared.setMain(restore)
        } else {
            debugLog("Arrangement", "restore: \(before) is not online")
        }
        try? await Task.sleep(for: .seconds(2))
        debugLog("Arrangement", "main.restored \(Arrangement.hexID(of: CGMainDisplayID()))")
    }

    /// Three decimals, or "failed" for a read that gave nothing.
    private static func text(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "failed"
    }
}
#endif
