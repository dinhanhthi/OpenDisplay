import SwiftUI

/// The "HiDPI resolutions" row of an external display: the HiDPI sizes its override file declares, and Apply and
/// Remove through the system's password dialog.
struct HiDPISection: View {
    let display: DisplayInfo
    /// Tells the popover that an Apply or Remove started (true) or ended (false).
    let installRunning: (Bool) -> Void

    /// What a row shows on its right.
    private enum RowState: String {
        case off, active, restart, reconnect, unsupported

        var text: String {
            switch self {
            case .off: ""
            case .active: "Active"
            case .restart: "Restart your Mac to activate"
            case .reconnect: "Reconnect the display to activate"
            case .unsupported: "Not supported by this display"
            }
        }
    }

    #if DEBUG
    /// With `--open-popover` the override file is read without a click, so the DEBUG line is printed.
    private static let loadsAtOnce = CommandLine.arguments.contains("--open-popover")
    #else
    private static let loadsAtOnce = false
    #endif

    @State private var isExpanded = false
    /// Nil until the override file has been read once.
    @State private var installer: OverrideInstaller?
    /// The ticked sizes; the file's sizes at each opening, until the user changes a checkbox.
    @State private var ticked: Set<CGSize> = []
    /// True while Apply or Remove runs.
    @State private var isBusy = false
    @State private var failure: String?

    var body: some View {
        // Read at each opening, once the display's modes are known (the row states need them).
        let loadsNow = display.modes != nil && (isExpanded || Self.loadsAtOnce)
        DisclosureGroup("HiDPI resolutions", isExpanded: $isExpanded) {
            if let installer {
                content(installer)
            } else {
                DelayedSpinner()
            }
        }
        // Nothing moves when the row opens.
        .animation(nil, value: isExpanded)
        .disabled(display.modes == nil)
        .task(id: [display.modes != nil, isExpanded]) {
            if loadsNow { await load() }
        }
    }

    private func content(_ installer: OverrideInstaller) -> some View {
        let declared = Set(installer.declaredSizes ?? [])
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(rows(installer), id: \.self) { size in
                HStack(alignment: .firstTextBaseline) {
                    Toggle(sizeLabel(size), isOn: Binding(
                        get: { ticked.contains(size) },
                        set: { isOn in
                            if isOn { ticked.insert(size) } else { ticked.remove(size) }
                        }))
                        .toggleStyle(.checkbox)
                        .fixedSize()
                    Spacer()
                    Text(state(of: size, installer).text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            if !declared.isEmpty, installer.needsRestart {
                Text("Restart your Mac once to turn on HiDPI sizes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Apply") { run(installer, sizes: rows(installer).filter(ticked.contains)) }
                    .disabled(isBusy || ticked == declared || installer.isUnreadable)
                if !declared.isEmpty {
                    Button("Remove all") { run(installer, sizes: []) }
                        .disabled(isBusy || installer.isUnreadable)
                }
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            // A file the app cannot read is said at once, not only after a failed Apply.
            if let failure = installer.isUnreadable ? OverrideInstaller.unreadableMessage : failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    /// The presets plus the sizes the file declares that are not presets, wider first.
    private func rows(_ installer: OverrideInstaller) -> [CGSize] {
        var sizes = display.nativePixelSize.map { native in
            HiDPIPresets.presets(nativeWidth: Int(native.width), nativeHeight: Int(native.height),
                                 ceiling: HiDPIPresets.ceiling(vendor: display.vendor, model: display.model))
        } ?? []
        for size in installer.declaredSizes ?? [] where !sizes.contains(size) {
            sizes.append(size)
        }
        return sizes.sorted { ($0.width, $0.height) > ($1.width, $1.height) }
    }

    /// A declared size that is not in the live mode list and cannot get there reads "Not supported",
    /// so no row promises an activation that cannot happen.
    private func state(of size: CGSize, _ installer: OverrideInstaller) -> RowState {
        switch installer.state(of: size, in: display.modes ?? []) {
        case .off: .off
        case .active: .active
        case .restartToActivate: isSupported(size) ? .restart : .unsupported
        case .reconnectToActivate: isSupported(size) ? .reconnect : .unsupported
        }
    }

    /// Smaller than the native size in both dimensions, and within the model's known ceiling.
    private func isSupported(_ size: CGSize) -> Bool {
        if let native = display.nativePixelSize, size.width >= native.width || size.height >= native.height {
            return false
        }
        if let ceiling = HiDPIPresets.ceiling(vendor: display.vendor, model: display.model),
           size.width > ceiling.width || size.height > ceiling.height {
            return false
        }
        return true
    }

    /// Reads the override file again: it may have changed since the last opening (repaired, edited,
    /// or written from the card of another display of the same model).
    private func load() async {
        let installer = self.installer
            ?? OverrideInstaller(vendor: display.vendor, model: display.model, name: display.name)
        await installer.reload()
        let declared = Set(installer.declaredSizes ?? [])
        ticked = declared
        // An error of an earlier Apply does not belong under the reloaded rows.
        failure = nil
        self.installer = installer
        debugLog("HiDPI", "rows id=\(display.hexID) rows="
            + rows(installer).map { "\(Int($0.width))x\(Int($0.height)):\(state(of: $0, installer).rawValue)" }
                .joined(separator: ",")
            + " applyEnabled=\(ticked != declared)")
    }

    /// Apply, or Remove when `sizes` is empty. The popover stays open behind the password dialog.
    private func run(_ installer: OverrideInstaller, sizes: [CGSize]) {
        guard !isBusy else { return }
        isBusy = true
        failure = nil
        installRunning(true)
        Task {
            let outcome = sizes.isEmpty ? await installer.remove() : await installer.apply(sizes: sizes)
            installRunning(false)
            isBusy = false
            switch outcome {
            case .done: ticked = Set(installer.declaredSizes ?? [])
            // Cancel in the password dialog shows nothing.
            case .cancelled: break
            case .failed(let message): failure = message
            }
        }
    }
}
