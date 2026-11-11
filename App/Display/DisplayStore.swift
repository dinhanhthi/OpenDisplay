import AppKit
import Observation

/// One connected display. `modes` is nil until its modes are loaded.
struct DisplayInfo: Identifiable, Equatable, Sendable {
    /// Not stable: it can change after a replug or a restart. Match a monitor by `vendor` and `model`.
    let id: CGDirectDisplayID
    var vendor: UInt32
    var model: UInt32
    var serial: UInt32
    /// The name macOS shows for it.
    var name: String
    var isBuiltIn: Bool
    var isMain: Bool
    /// The panel's pixel size; nil until the modes are loaded.
    var nativePixelSize: CGSize?
    /// The mode the display is in; it may not be one of `modes`.
    var current: ModeInfo?
    /// The modes the menus may offer; nil while loading.
    var modes: [ModeInfo]?

    /// "vendorHex:modelHex", the `id=` field of the DEBUG lines (for example `1e6d:7826`).
    var hexID: String { "\(String(vendor, radix: 16)):\(String(model, radix: 16))" }
}

/// The connected displays and their modes. The display list is read on the main actor (cheap);
/// mode lists and mode switches run off it, in `Modes`.
@MainActor
@Observable
final class DisplayStore {
    private(set) var displays: [DisplayInfo] = []

    /// The store the reconfiguration callback reports to (a C callback cannot capture one).
    fileprivate static weak var reconfigurationTarget: DisplayStore?

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var firstRefresh: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var runningRefreshes = 0
    @ObservationIgnored private var lastRefreshEnd: ContinuousClock.Instant?
    /// The mode switches in flight, per display: a refresh leaves `current` alone meanwhile.
    @ObservationIgnored private var switching: [CGDirectDisplayID: Int] = [:]

    init() {
        Self.reconfigurationTarget = self
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)
    }

    isolated deinit {
        CGDisplayRemoveReconfigurationCallback(displayReconfigured, nil)
        debounceTask?.cancel()
    }

    // MARK: Refresh

    /// Lists the displays again and reloads their modes. Refreshes run one after the other.
    func refresh() {
        let previous = refreshTask
        runningRefreshes += 1
        let task = Task {
            await previous?.value
            await reload()
            runningRefreshes -= 1
            lastRefreshEnd = .now
        }
        refreshTask = task
        if firstRefresh == nil { firstRefresh = task }
    }

    /// For the popover: refreshes only when no refresh is running and the last one finished more
    /// than 2 seconds ago.
    func refreshIfStale() {
        guard runningRefreshes == 0, let lastRefreshEnd, ContinuousClock.now - lastRefreshEnd > .seconds(2) else {
            return
        }
        refresh()
    }

    /// Returns once the first `refresh()` (the one at launch) has loaded every display's modes.
    func waitForFirstRefresh() async {
        await firstRefresh?.value
    }

    /// A display was added, removed or changed: refreshes 300 ms after the last such call.
    fileprivate func displaysReconfigured() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
            self?.refresh()
        }
    }

    private func reload() async {
        let listed = connectedDisplays()
        // A display that is still connected keeps what was loaded until its new read arrives.
        let merged = listed.map { display -> DisplayInfo in
            guard let old = displays.first(where: {
                $0.id == display.id && $0.vendor == display.vendor && $0.model == display.model
            }) else { return display }
            var display = display
            display.nativePixelSize = old.nativePixelSize
            display.current = old.current
            display.modes = old.modes
            return display
        }
        if displays != merged { displays = merged }

        await withTaskGroup(of: (DisplayInfo, Modes.Loaded, Int).self) { group in
            for display in listed {
                group.addTask {
                    let start = ContinuousClock.now
                    let loaded = await Modes.load(display.id, vendor: display.vendor, model: display.model)
                    return (display, loaded, Int((ContinuousClock.now - start) / .milliseconds(1)))
                }
            }
            for await (display, loaded, milliseconds) in group {
                apply(loaded, to: display, milliseconds: milliseconds)
            }
        }
    }

    private func connectedDisplays() -> [DisplayInfo] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
            return DisplayInfo(
                id: id,
                vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id),
                // A mirrored display has no screen of its own.
                name: screen?.localizedName ?? "Display",
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                isMain: CGDisplayIsMain(id) != 0)
        }
    }

    private func apply(_ loaded: Modes.Loaded, to display: DisplayInfo, milliseconds: Int) {
        // By id: the list may have changed while the modes were read.
        if let index = displays.firstIndex(where: { $0.id == display.id }) {
            var updated = displays[index]
            updated.modes = loaded.modes
            updated.nativePixelSize = loaded.nativePixelSize
            if switching[display.id] == nil { updated.current = loaded.current }
            if displays[index] != updated { displays[index] = updated }
        }
        debugLog("Timing", "modes.load id=\(display.hexID) ms=\(milliseconds) modes=\(loaded.modes.count)"
            + " native=\(loaded.nativePixelSize.map(Self.text) ?? "none") name=\(display.name)")
        debugLog("Modes", "hidpi.rows id=\(display.hexID) rows=\(Self.hiDPIRows(of: loaded.modes))")
    }

    // MARK: Mode switch

    /// Switches a display to `mode`. `current` changes before this returns and goes back to the
    /// mode before if the switch fails; the task's value says whether it worked.
    @discardableResult
    func setMode(_ mode: ModeInfo, on id: CGDirectDisplayID) -> Task<Bool, Never> {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return Task { false } }
        let display = displays[index]
        displays[index].current = mode
        switching[id, default: 0] += 1
        return Task {
            let start = ContinuousClock.now
            let ok = await Modes.set(mode, on: id)
            debugLog("Timing", "mode.switch id=\(display.hexID)"
                + " ms=\(Int((ContinuousClock.now - start) / .milliseconds(1))) ok=\(ok)")
            let left = (switching[id] ?? 1) - 1
            switching[id] = left > 0 ? left : nil
            // Back to the mode before, unless another pick came in meanwhile.
            if !ok, let index = displays.firstIndex(where: { $0.id == id }), displays[index].current == mode {
                displays[index].current = display.current
            }
            return ok
        }
    }

    // MARK: DEBUG text

    private static func text(_ size: CGSize) -> String {
        "\(Int(size.width))x\(Int(size.height))"
    }

    /// The HiDPI rows of the Resolution menu with their refresh rates: "2560x1080@100/85/50,...".
    private static func hiDPIRows(of modes: [ModeInfo]) -> String {
        ModeGrouping.resolutions(from: modes).filter(\.isHiDPI).map { row in
            let rates = ModeGrouping.refreshRates(for: row, in: modes).map(String.init)
            return "\(text(row.pointSize))@\(rates.joined(separator: "/"))"
        }.joined(separator: ",")
    }
}

/// CoreGraphics calls this before and after each display change, on the thread that drives the
/// change (a mode switch runs off the main actor), so it hops to the main actor.
private func displayReconfigured(
    _ id: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?
) {
    guard !flags.contains(.beginConfigurationFlag) else { return }
    Task { @MainActor in DisplayStore.reconfigurationTarget?.displaysReconfigured() }
}
