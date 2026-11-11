import SwiftUI

/// One display: its name, the Resolution and Refresh rate menus and, on an external display, the HiDPI sizes.
struct DisplayCard: View {
    let display: DisplayInfo
    let store: DisplayStore
    /// Tells the popover that a HiDPI Apply or Remove started (true) or ended (false).
    let installRunning: (Bool) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(display.name)
                        .font(.headline)
                        .lineLimit(1)
                    if display.isMain {
                        Text("Main")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    // The placeholder: the same card with its menus off, until the modes are loaded.
                    if display.modes == nil { DelayedSpinner() }
                }
                menuRow("Resolution", selection: resolution, values: rows) { row in
                    sizeLabel(row.pointSize) + (row.isHiDPI ? " HiDPI" : "")
                }
                menuRow("Refresh rate", selection: rate, values: rates) { "\($0) Hz" }
                if !display.isBuiltIn {
                    HiDPISection(display: display, installRunning: installRunning)
                }
            }
            .padding(4)
        }
    }

    /// The modes the menus offer, with the current mode when macOS does not list it as usable.
    private var modes: [ModeInfo] {
        let modes = display.modes ?? []
        guard let current = display.current, !modes.contains(current) else { return modes }
        return modes + [current]
    }

    private var rows: [ResolutionRow] { ModeGrouping.resolutions(from: modes) }

    private var currentRow: ResolutionRow? {
        display.current.map { ResolutionRow(pointSize: $0.pointSize, isHiDPI: $0.isHiDPI) }
    }

    private var rates: [Int] {
        currentRow.map { ModeGrouping.refreshRates(for: $0, in: modes) } ?? []
    }

    private var resolution: Binding<ResolutionRow?> {
        Binding(get: { currentRow }, set: { row in
            guard let row else { return }
            switchTo(ModeGrouping.bestMode(for: row, preferredRate: display.current?.refreshRate ?? 0, in: modes))
        })
    }

    private var rate: Binding<Int?> {
        Binding(get: { display.current?.roundedRate }, set: { rate in
            guard let rate, let currentRow else { return }
            switchTo(ModeGrouping.bestMode(for: currentRow, preferredRate: Double(rate), in: modes))
        })
    }

    /// The store changes `current` now, so the menus follow in this frame; the switch runs in the background.
    private func switchTo(_ mode: ModeInfo?) {
        guard let mode, mode != display.current else { return }
        store.setMode(mode, on: display.id)
    }

    /// A title on the left and a menu on the right. The menu is off while the modes load.
    private func menuRow<Value: Hashable>(
        _ title: String, selection: Binding<Value?>, values: [Value], label: @escaping (Value) -> String
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: selection) {
                // Nothing selected (still loading): an empty row, so the selection always has a tag.
                if selection.wrappedValue == nil { Text("").tag(Value?.none) }
                ForEach(values, id: \.self) { Text(label($0)).tag(Optional($0)) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(display.modes == nil)
        }
    }
}

/// "2560 x 1080".
func sizeLabel(_ size: CGSize) -> String {
    "\(Int(size.width)) x \(Int(size.height))"
}

/// A small spinner that fades in after 150 ms, so a fast load never flashes it. Opacity only: nothing moves.
struct DelayedSpinner: View {
    @State private var isVisible = false

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(isVisible ? 1 : 0)
            .task {
                // Cancelled when the load ends first.
                guard (try? await Task.sleep(for: .milliseconds(150))) != nil else { return }
                withAnimation(.easeIn(duration: 0.15)) { isVisible = true }
            }
    }
}
