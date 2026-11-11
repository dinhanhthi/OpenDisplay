import AppKit
import os
import SwiftUI

/// The menu bar item and its popover. The popover is `.applicationDefined`: the app closes it itself (a second
/// click on the icon, Esc, or a click outside), so it stays open across display changes. While Sparkle holds an
/// update found by a scheduled check, the logo has a download badge.
@MainActor
final class StatusItemController: NSObject {
    /// While true, a click outside the popover does not close it.
    var keepsOpen = false

    private let updater: Updater
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    /// The logo without the update badge; nil when the item shows the "od" title.
    private var logo: NSImage?
    private let popover = NSPopover()
    /// Whether the popover is meant to be open; the system may close it during a display change.
    private var isOpen = false
    private var escapeMonitor: Any?
    private var outsideClickMonitor: Any?
    /// Refreshed when the popover opens; the display cards read it.
    private let displayStore: DisplayStore

    init(updater: Updater, displayStore: DisplayStore) {
        self.updater = updater
        self.displayStore = displayStore
        super.init()
        setUpButton()
        // Only with the logo: the "od" title has no badge, so Sparkle shows its own alert.
        if logo != nil {
            updater.onAvailableUpdateChange = { [weak self] in self?.refreshUpdateState() }
            refreshUpdateState()
        }
        popover.behavior = .applicationDefined
        let hostingController = NSHostingController(
            rootView: PopoverView(
                updater: updater, store: displayStore,
                setKeepsOpen: { [weak self] in self?.keepsOpen = $0 },
                onClose: { [weak self] in self?.close() }))
        // The popover's size follows the SwiftUI content.
        hostingController.sizingOptions = .preferredContentSize
        // Load and lay out the view now, so the first click does not pay for it.
        hostingController.view.layoutSubtreeIfNeeded()
        _ = hostingController.view.fittingSize
        popover.contentViewController = hostingController
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        #if DEBUG
        if CommandLine.arguments.contains("--open-popover") {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.togglePopover()
            }
        }
        #endif
    }

    isolated deinit {
        removeMonitors()
        NotificationCenter.default.removeObserver(self)
        updater.onAvailableUpdateChange = nil
    }

    /// The logo in full color at 18 pt, or the title "od" so the item is never invisible.
    private func setUpButton() {
        let image = NSImage(named: "MenuBarIcon")
        debugLog("StatusItem", "image=\(image != nil)")
        guard let button = statusItem.button else { return }
        if let image {
            image.isTemplate = false
            image.size = NSSize(width: 18, height: 18)
            image.accessibilityDescription = "OpenDisplay"
            button.image = image
            logo = image
        } else {
            Logger(subsystem: "com.math2it.opendisplay", category: "StatusItem")
                .error("MenuBarIcon is missing from the asset catalog; showing the title instead")
            button.title = "od"
        }
        button.target = self
        button.action = #selector(togglePopover)
    }

    /// The plain logo, or, while an update waits, the logo with a download badge at its bottom-right corner.
    private func refreshUpdateState() {
        guard updater.availableUpdateVersion != nil else {
            statusItem.button?.image = logo
            return
        }
        let logo = logo
        let badged = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            // Full color, not a template: drawn as is.
            logo?.draw(in: rect)
            let badge = NSRect(x: rect.maxX - 9, y: rect.minY, width: 9, height: 9)
            // A white disc, then a bold arrow in a deep green (the system green, 45 % of the way to black).
            NSColor.white.setFill()
            NSBezierPath(ovalIn: badge).fill()
            let green = NSColor.systemGreen.blended(withFraction: 0.45, of: .black) ?? .systemGreen
            let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .black)
                .applying(NSImage.SymbolConfiguration(paletteColors: [green]))
            if let arrow = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                // Aspect-fit in the disc's inner square, centred.
                let inner = badge.insetBy(dx: 1, dy: 1)
                let size = arrow.size
                let scale = min(inner.width / size.width, inner.height / size.height)
                let fitted = NSSize(width: size.width * scale, height: size.height * scale)
                arrow.draw(in: NSRect(x: badge.midX - fitted.width / 2, y: badge.midY - fitted.height / 2,
                                      width: fitted.width, height: fitted.height))
            }
            return true
        }
        badged.accessibilityDescription = "OpenDisplay, update available"
        statusItem.button?.image = badged
    }

    @objc private func togglePopover() {
        // The system closed the popover (a display change): it counts as closed, and this click opens it.
        if isOpen, !popover.isShown {
            isOpen = false
            removeMonitors()
        }
        if isOpen { close() } else { open() }
    }

    private func open() {
        let start = ContinuousClock.now
        guard show() else { return }
        // Up to the return of `show`, without the system's show animation.
        debugLog("Timing", "popover.open ms=\(Int((ContinuousClock.now - start) / .milliseconds(1)))")
        isOpen = true
        // Starts in the background, and only when the last refresh is more than 2 s old.
        displayStore.refreshIfStale()
        // Key window in an active app, so Esc and text focus work. The plain `activate()` can be denied for an
        // app without a Dock icon.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        installMonitors()
    }

    private func close() {
        guard isOpen else { return }
        isOpen = false
        removeMonitors()
        popover.close()
    }

    /// Shows the popover under the button, or re-anchors it there when it is already shown.
    @discardableResult
    private func show() -> Bool {
        // `show` raises when the view has no window.
        guard let button = statusItem.button, button.window != nil else { return false }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        return true
    }

    /// Also reopens the popover if the system closed it during the reconfiguration.
    @objc private func screensChanged() {
        if isOpen { show() }
    }

    private func installMonitors() {
        // Never two sets of monitors.
        removeMonitors()
        // Esc in the popover's window, whatever has focus there.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self,
                  event.window == self.popover.contentViewController?.view.window else { return event }
            self.close()
            return nil
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, !self.keepsOpen else { return }
            // The global monitor also sees clicks on this app's own status button (macOS 27): those are left to
            // the button's action, or the popover would close on mouse-down and reopen on mouse-up.
            if let frame = self.statusItem.button?.window?.frame, frame.contains(NSEvent.mouseLocation) { return }
            self.close()
        }
    }

    private func removeMonitors() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        escapeMonitor = nil
        outsideClickMonitor = nil
    }
}
