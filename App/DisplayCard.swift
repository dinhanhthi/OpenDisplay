import SwiftUI

/// One display: its name, "Set as main" when it is not the main one, the brightness and volume sliders, the
/// Resolution, Refresh rate and Color profile menus and, on an external display, the Rotation menu and the
/// HiDPI sizes.
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
                    if !display.isMain {
                        // The store changes `isMain` now, so the card follows in this frame.
                        Button("Set as main") { store.setMain(display.id) }
                            .controlSize(.small)
                    }
                }
                brightnessRow
                if display.hasVolume { volumeRow }
                menuRow("Resolution", selection: resolution, values: rows) { row in
                    sizeLabel(row.pointSize) + (row.isHiDPI ? " HiDPI" : "")
                }
                menuRow("Refresh rate", selection: rate, values: rates) { "\($0) Hz" }
                if display.isRotatable {
                    menuRow("Rotation", selection: rotation, values: [0, 90, 180, 270]) { "\($0)°" }
                }
                colorProfileRow
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

    /// The store changes `rotation` now, so the menu follows in this frame; the display turns in the background.
    private var rotation: Binding<Int?> {
        Binding(get: { display.rotation }, set: { degrees in
            guard let degrees, degrees != display.rotation else { return }
            store.setRotation(degrees, on: display.id)
        })
    }

    /// The rows of the Color profile menu under "Factory default": the installed profiles, with the custom
    /// profile in use when the list does not have it, or is not loaded yet.
    private var colorProfiles: [ColorProfile] {
        let profiles = store.colorProfiles ?? []
        guard let custom = display.colorProfile?.custom, !profiles.contains(where: { $0.url == custom.url }) else {
            return profiles
        }
        return profiles + [custom]
    }

    /// By file, because two profiles can have one name; nil is "Factory default". The store changes
    /// `colorProfile` now, so the menu follows in this frame; ColorSync is told in the background.
    private var colorProfile: Binding<URL?> {
        Binding(get: { display.colorProfile?.custom?.url }, set: { url in
            guard url != display.colorProfile?.custom?.url else { return }
            guard let url else {
                store.setColorProfile(nil, on: display.id)
                return
            }
            // A file that is not in the menu is never set, and never taken for "Factory default".
            guard let profile = colorProfiles.first(where: { $0.url == url }) else { return }
            store.setColorProfile(profile, on: display.id)
        })
    }

    /// The name of the profile in use, at most 20 characters: a long one must not push the row out of the card.
    private var colorProfileTitle: String {
        let name = display.colorProfile?.name ?? ""
        return name.count > 20 ? name.prefix(19) + "…" : name
    }

    /// The store changes `current` now, so the menus follow in this frame; the switch runs in the background.
    private func switchTo(_ mode: ModeInfo?) {
        guard let mode, mode != display.current else { return }
        store.setMode(mode, on: display.id)
    }

    /// The brightness slider. The thumb follows the pointer: the store's value changes at once and the
    /// display follows in the background. While the value is read, the same row with the slider off.
    private var brightnessRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "sun.max")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { display.brightness ?? 0 },
                    set: { store.setBrightness($0, on: display.id) }),
                in: 0...1
            ) {
                Text("Brightness")
            }
            .labelsHidden()
            .disabled(display.brightness == nil)
            Group {
                if let brightness = display.brightness {
                    Text("\(Int((brightness * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    DelayedSpinner()
                }
            }
            .frame(width: 40, alignment: .trailing)
            if display.brightnessBackend == .software {
                Text("software")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The volume slider, on a display that has a volume: same shape as the brightness row.
    private var volumeRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.wave.2")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { display.volume ?? 0 },
                    set: { store.setVolume($0, on: display.id) }),
                in: 0...1
            ) {
                Text("Volume")
            }
            .labelsHidden()
            .disabled(display.volume == nil)
            Group {
                if let volume = display.volume {
                    Text("\(Int((volume * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    DelayedSpinner()
                }
            }
            .frame(width: 40, alignment: .trailing)
        }
    }

    /// The Color profile menu: its title is the profile in use, its rows are "Factory default" and the installed
    /// profiles. It opens at once: the list loads in the background when a menu first opens, and until it is
    /// there the rows are "Factory default", the custom profile in use and "Loading…". While the display's
    /// profile is read, the same row with the menu off.
    private var colorProfileRow: some View {
        HStack {
            Text("Color profile")
            Spacer()
            Menu {
                Picker("Color profile", selection: colorProfile) {
                    Text(ColorProfiles.factoryTitle).tag(URL?.none)
                    ForEach(colorProfiles, id: \.url) { Text($0.name).tag(Optional($0.url)) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if store.colorProfiles == nil {
                    Button("Loading…") {}
                        .disabled(true)
                }
            } label: {
                Text(colorProfileTitle)
            }
            .fixedSize()
            .disabled(display.colorProfile == nil)
        }
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
