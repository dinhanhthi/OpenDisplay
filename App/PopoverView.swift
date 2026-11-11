import SwiftUI

/// The popover's root: the display area above the footer.
struct PopoverView: View {
    /// For the footer's "Check for Updates…" button.
    let updater: Updater
    /// Closes the popover; the controller owns it.
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                // Empty state; the display cards replace it.
                Text("No displays")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
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
}
