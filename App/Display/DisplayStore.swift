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
    /// The rotation in degrees: 0, 90, 180 or 270.
    var rotation: Int
    /// Whether the card shows a Rotation menu: an external display that MonitorPanel can turn;
    /// false until it was asked.
    var isRotatable = false
    /// The panel's pixel size; nil until the modes are loaded.
    var nativePixelSize: CGSize?
    /// The mode the display is in; it may not be one of `modes`.
    var current: ModeInfo?
    /// The modes the menus may offer; nil while loading.
    var modes: [ModeInfo]?
    /// Whether the monitor answers DDC for brightness and for volume; false until it was asked.
    var ddcBrightness = false
    var ddcVolume = false
    /// Brightness, 0...1; nil while it is read.
    var brightness: Double?
    /// How the brightness is read and set; nil until a refresh has chosen it.
    var brightnessBackend: BrightnessBackend?
    /// Volume, 0...1; nil while it is read.
    var volume: Double?
    /// The color profile in use; nil until it was read.
    var colorProfile: DisplayColorProfile?

    /// How the volume is read and set: over DDC when the monitor answers, the built-in speakers
    /// for the built-in display.
    var volumeBackend: VolumeBackend { ddcVolume ? .ddc : isBuiltIn ? .coreaudio : .none }
    /// Whether the card shows a volume row.
    var hasVolume: Bool { volumeBackend != .none }

    /// "vendorHex:modelHex", the `id=` field of the DEBUG lines (for example `1e6d:7826`).
    var hexID: String { "\(String(vendor, radix: 16)):\(String(model, radix: 16))" }
}

/// The connected displays and their modes. The display list is read on the main actor (cheap);
/// mode lists and mode switches run off it, in `Modes`.
@MainActor
@Observable
final class DisplayStore {
    private(set) var displays: [DisplayInfo] = []
    /// The installed display profiles, sorted by name, for every card's Color profile menu; nil
    /// until they were loaded, which the first menu that opens starts.
    private(set) var colorProfiles: [ColorProfile]?

    /// The store the reconfiguration callback reports to (a C callback cannot capture one).
    fileprivate static weak var reconfigurationTarget: DisplayStore?

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var firstRefresh: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var runningRefreshes = 0
    @ObservationIgnored private var lastRefreshEnd: ContinuousClock.Instant?
    /// The mode switches in flight, per display: a refresh leaves `current` alone meanwhile.
    @ObservationIgnored private var switching: [CGDirectDisplayID: Int] = [:]
    /// The main-display changes and, per display, the rotations in flight: a refresh leaves
    /// `isMain` and `rotation` alone meanwhile.
    @ObservationIgnored private var settingMain = 0
    @ObservationIgnored private var rotating: [CGDirectDisplayID: Int] = [:]
    /// The color profile changes in flight, per display: a refresh leaves `colorProfile` alone meanwhile.
    @ObservationIgnored private var settingProfile: [CGDirectDisplayID: Int] = [:]
    /// True once the profile list was asked for: it loads once.
    @ObservationIgnored private var colorProfilesRequested = false
    /// The latest brightness not yet sent, and the displays that have a send loop running.
    @ObservationIgnored private var pendingBrightness: [CGDirectDisplayID: Double] = [:]
    @ObservationIgnored private var sendingBrightness: Set<CGDirectDisplayID> = []
    /// The same for the volume.
    @ObservationIgnored private var pendingVolume: [CGDirectDisplayID: Double] = [:]
    @ObservationIgnored private var sendingVolume: Set<CGDirectDisplayID> = []
    /// How many values were set, per display: a refresh drops a read that a set overtook.
    @ObservationIgnored private var brightnessWrites: [CGDirectDisplayID: Int] = [:]
    @ObservationIgnored private var volumeWrites: [CGDirectDisplayID: Int] = [:]
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var quitObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var menuObserver: (any NSObjectProtocol)?

    init() {
        Self.reconfigurationTarget = self
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)
        // A wake resets the gamma table: the refresh dims the displays that are dimmed in software again.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { DisplayStore.reconfigurationTarget?.displaysReconfigured() }
        }
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            Brightness.restoreAtQuit()
        }
        // The profile list loads when a menu first opens. SwiftUI does not say which menu opened,
        // so any menu of the app starts it; the popover's opening never does.
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { DisplayStore.reconfigurationTarget?.loadColorProfiles() }
        }
    }

    isolated deinit {
        CGDisplayRemoveReconfigurationCallback(displayReconfigured, nil)
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
        if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
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

    /// Returns once the first `refresh()` (the one at launch) has loaded every display's modes, DDC support,
    /// brightness, volume and color profile.
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
            if settingMain > 0 { display.isMain = old.isMain }
            if rotating[display.id] != nil { display.rotation = old.rotation }
            display.isRotatable = old.isRotatable
            display.nativePixelSize = old.nativePixelSize
            display.current = old.current
            display.modes = old.modes
            display.ddcBrightness = old.ddcBrightness
            display.ddcVolume = old.ddcVolume
            display.brightness = old.brightness
            display.brightnessBackend = old.brightnessBackend
            display.volume = old.volume
            display.colorProfile = old.colorProfile
            return display
        }
        if displays != merged { displays = merged }

        // MonitorPanel is asked first, so its lookup and the DDC exchanges never overlap; DDC is
        // asked while the modes load.
        let rotatable = await Arrangement.shared.rotatable(listed.filter { !$0.isBuiltIn }.map(\.id))
        async let ddc = DDC.shared.refresh(listed)
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
        apply(rotatable: rotatable)
        apply(ddc: await ddc)
        await loadBrightness()
        await loadVolume()
        await loadColorProfile()
    }

    /// Reads the color profile each display uses. Nothing is set.
    private func loadColorProfile() async {
        for display in displays {
            guard let profile = await ColorProfiles.shared.current(of: display.id) else {
                debugLog("ColorProfile", "read.failed id=\(display.hexID) name=\(display.name)")
                continue
            }
            debugLog("ColorProfile", "current id=\(display.hexID) profile=\(profile.name)")
            // A profile that is being set keeps its row.
            guard settingProfile[display.id] == nil,
                  let index = displays.firstIndex(where: { $0.id == display.id }),
                  displays[index].colorProfile != profile
            else { continue }
            displays[index].colorProfile = profile
        }
    }

    /// Chooses each display's brightness backend (it needs the DDC answer) and reads its value.
    private func loadBrightness() async {
        for display in displays {
            // Taken before the read: a value still being sent, or set while the read runs, is newer than it.
            let writes = brightnessWrites[display.id]
            let sending = sendingBrightness.contains(display.id)
            let (backend, value) = await Brightness.shared.load(display)
            debugLog("Brightness", "backend id=\(display.hexID) backend=\(backend.rawValue) name=\(display.name)")
            guard let index = displays.firstIndex(where: { $0.id == display.id }) else { continue }
            var updated = displays[index]
            updated.brightnessBackend = backend
            // The slider keeps the value the user set.
            if let value, !sending, brightnessWrites[display.id] == writes { updated.brightness = value }
            if displays[index] != updated { displays[index] = updated }
        }
    }

    /// Reads each display's volume (its backend needs the DDC answer). Nothing is set.
    private func loadVolume() async {
        for display in displays {
            // Taken before the read: a value still being sent, or set while the read runs, is newer than it.
            let writes = volumeWrites[display.id]
            let sending = sendingVolume.contains(display.id)
            let value = await Volume.shared.read(display)
            debugLog("Volume", "backend id=\(display.hexID) backend=\(display.volumeBackend.rawValue)"
                + " value=\(value.map { String(format: "%.3f", $0) } ?? "-") name=\(display.name)")
            // The slider keeps the value the user set.
            guard let value, !sending, volumeWrites[display.id] == writes,
                  let index = displays.firstIndex(where: { $0.id == display.id }),
                  displays[index].volume != value
            else { continue }
            displays[index].volume = value
        }
    }

    /// Keeps which displays can be turned (never the built-in one). Nothing is changed.
    private func apply(rotatable: Set<CGDirectDisplayID>) {
        for index in displays.indices {
            let isRotatable = rotatable.contains(displays[index].id)
            if displays[index].isRotatable != isRotatable { displays[index].isRotatable = isRotatable }
            let display = displays[index]
            debugLog("Arrangement", "state id=\(display.hexID) main=\(display.isMain ? "yes" : "no")"
                + " rotation=\(display.rotation) rotatable=\(isRotatable ? "yes" : "no") name=\(display.name)")
        }
    }

    /// Keeps which DDC controls each display supports; a display without a DDC service has none.
    private func apply(ddc: [CGDirectDisplayID: Set<UInt8>]) {
        for index in displays.indices {
            let codes = ddc[displays[index].id] ?? []
            var updated = displays[index]
            updated.ddcBrightness = codes.contains(DDC.brightness)
            updated.ddcVolume = codes.contains(DDC.volume)
            if displays[index] != updated { displays[index] = updated }
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
                isMain: CGDisplayIsMain(id) != 0,
                rotation: Arrangement.rotation(of: id))
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

    // MARK: Main display and rotation

    /// Makes a display the main one. `isMain` changes before this returns and goes back to what
    /// macOS reports if the change fails; the task's value says whether it worked.
    @discardableResult
    func setMain(_ id: CGDirectDisplayID) -> Task<Bool, Never> {
        guard let index = displays.firstIndex(where: { $0.id == id }), !displays[index].isMain else {
            return Task { false }
        }
        for index in displays.indices { displays[index].isMain = displays[index].id == id }
        settingMain += 1
        return Task {
            let ok = await Arrangement.shared.setMain(id)
            settingMain -= 1
            // Unless another pick is still in flight.
            if !ok, settingMain == 0 {
                for index in displays.indices { displays[index].isMain = CGDisplayIsMain(displays[index].id) != 0 }
            }
            return ok
        }
    }

    /// Turns a display to 0, 90, 180 or 270 degrees. `rotation` changes before this returns and
    /// goes back to what macOS reports if the change fails; the task's value says whether it worked.
    @discardableResult
    func setRotation(_ degrees: Int, on id: CGDirectDisplayID) -> Task<Bool, Never> {
        guard let index = displays.firstIndex(where: { $0.id == id }), displays[index].isRotatable else {
            return Task { false }
        }
        displays[index].rotation = degrees
        rotating[id, default: 0] += 1
        return Task {
            let ok = await Arrangement.shared.setRotation(degrees, on: id)
            let left = (rotating[id] ?? 1) - 1
            rotating[id] = left > 0 ? left : nil
            // Unless another pick is still in flight.
            if !ok, left == 0, let index = displays.firstIndex(where: { $0.id == id }) {
                displays[index].rotation = Arrangement.rotation(of: id)
            }
            return ok
        }
    }

    // MARK: Brightness

    /// Sets a display's brightness, 0...1. `brightness` changes before this returns; the display
    /// follows in the background, with at most one write every 50 ms and always the last value.
    func setBrightness(_ value: Double, on id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }),
              let backend = displays[index].brightnessBackend
        else { return }
        let display = displays[index]
        displays[index].brightness = value
        brightnessWrites[id, default: 0] += 1
        pendingBrightness[id] = value
        guard sendingBrightness.insert(id).inserted else { return }
        Task {
            // A value that arrives while one is being written is picked up by the next turn.
            while let value = pendingBrightness.removeValue(forKey: id) {
                await Brightness.shared.write(value, to: display, backend: backend)
                try? await Task.sleep(for: .milliseconds(50))
            }
            sendingBrightness.remove(id)
        }
    }

    // MARK: Volume

    /// Sets a display's volume, 0...1. `volume` changes before this returns; the monitor or the
    /// built-in speakers follow in the background, with at most one write every 50 ms and always
    /// the last value.
    func setVolume(_ value: Double, on id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }), displays[index].hasVolume else { return }
        let display = displays[index]
        displays[index].volume = value
        volumeWrites[id, default: 0] += 1
        pendingVolume[id] = value
        guard sendingVolume.insert(id).inserted else { return }
        Task {
            // A value that arrives while one is being written is picked up by the next turn.
            while let value = pendingVolume.removeValue(forKey: id) {
                await Volume.shared.write(value, to: display)
                try? await Task.sleep(for: .milliseconds(50))
            }
            sendingVolume.remove(id)
        }
    }

    // MARK: Color profile

    /// Loads the list of installed profiles, once and off the main actor. Returns at once.
    func loadColorProfiles() {
        guard !colorProfilesRequested else { return }
        colorProfilesRequested = true
        Task {
            let start = ContinuousClock.now
            let profiles = await ColorProfiles.shared.installed()
            debugLog("Timing", "profiles.load ms=\(Int((ContinuousClock.now - start) / .milliseconds(1)))"
                + " count=\(profiles.count)")
            colorProfiles = profiles
        }
    }

    /// Gives a display a color profile, or its factory profile back when `profile` is nil.
    /// `colorProfile` changes before this returns and goes back to what macOS reports if the
    /// change fails; the task's value says whether it worked.
    @discardableResult
    func setColorProfile(_ profile: ColorProfile?, on id: CGDirectDisplayID) -> Task<Bool, Never> {
        guard let index = displays.firstIndex(where: { $0.id == id }), displays[index].colorProfile != nil else {
            return Task { false }
        }
        let display = displays[index]
        displays[index].colorProfile?.custom = profile
        settingProfile[id, default: 0] += 1
        return Task {
            let ok = await ColorProfiles.shared.set(profile, on: display)
            // A new profile reloads the display's gamma table: a display that is dimmed in software
            // is dimmed again, any other display is left alone.
            if display.brightnessBackend == .software,
               let value = await Brightness.shared.read(display, backend: .software), value < 1 {
                await Brightness.shared.applyDim(value, to: display)
            }
            var reported: DisplayColorProfile?
            if !ok { reported = await ColorProfiles.shared.current(of: id) ?? display.colorProfile }
            let left = (settingProfile[id] ?? 1) - 1
            settingProfile[id] = left > 0 ? left : nil
            // Unless another pick is still in flight.
            if let reported, left == 0, let index = displays.firstIndex(where: { $0.id == id }) {
                displays[index].colorProfile = reported
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
