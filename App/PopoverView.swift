import SwiftUI

/// The popover's root: the display area above the footer.
struct PopoverView: View {
    /// For the footer's "Check for Updates…" button.
    let updater: Updater
    /// The connected displays, one card each.
    let store: DisplayStore
    /// Sets the controller's `keepsOpen`.
    let setKeepsOpen: (Bool) -> Void
    /// Closes the popover; the controller owns it.
    let onClose: () -> Void

    /// The HiDPI Apply and Remove calls in flight; two displays can each run one.
    @State private var installsRunning = 0

    var body: some View {
        // The main display first, the others in the system's order.
        let displays = store.displays.filter(\.isMain) + store.displays.filter { !$0.isMain }
        VStack(spacing: 0) {
            ScrollView {
                if displays.isEmpty {
                    Text("No displays")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    VStack(spacing: 8) {
                        ForEach(displays) { display in
                            DisplayCard(display: display, store: store, installRunning: installRunning)
                        }
                    }
                    .padding(12)
                }
            }
            Divider()
            // The footer keeps its height; only the display area scrolls.
            FooterView(updater: updater)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 320)
        // As tall as the content, up to 640 pt; above that the display area scrolls.
        .frame(maxHeight: 640)
        // Esc, while a SwiftUI control has focus; the controller's key monitor covers the rest.
        .onExitCommand { onClose() }
    }

    /// The popover stays open behind the password dialog until the last call has returned.
    private func installRunning(_ running: Bool) {
        installsRunning += running ? 1 : -1
        setKeepsOpen(installsRunning > 0)
    }
}
