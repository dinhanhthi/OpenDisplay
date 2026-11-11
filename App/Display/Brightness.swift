import CoreGraphics
import Foundation
import Synchronization

/// How a display's brightness is read and set.
enum BrightnessBackend: String, Sendable {
    /// The monitor's own backlight, over DDC (VCP 0x10).
    case ddc
    /// The built-in panel, through DisplayServices.
    case native
    /// No backlight control: the picture is dimmed through the gamma table.
    case software
}

/// Reads and sets the brightness of a display, 0...1. Everything runs on this actor, off the main
/// actor. The store picks the latest slider value and calls `write` at most every 50 ms.
actor Brightness {
    static let shared = Brightness()

    /// True once this run dimmed a display in software. Read at quit, without waiting for the actor.
    private static let didDim = Atomic<Bool>(false)

    /// The maximum of VCP 0x10 per display, from its last read.
    private var ddcMax: [CGDirectDisplayID: UInt16] = [:]
    /// The displays this run dimmed in software, with their value.
    private var dimmed: [CGDirectDisplayID: Double] = [:]

    // MARK: Read

    /// Chooses the backend of a display and reads its brightness. A display dimmed in software gets
    /// its dimming applied again: a display change or a wake resets the gamma table.
    func load(_ display: DisplayInfo) async -> (backend: BrightnessBackend, value: Double?) {
        let backend: BrightnessBackend =
            if display.isBuiltIn, PrivateAPI.DisplayServicesSetBrightness != nil, native(display) != nil {
                .native
            } else if display.ddcBrightness {
                .ddc
            } else {
                .software
            }
        let value = await read(display, backend: backend)
        if backend == .software {
            if let value { applyDim(value, to: display) }
        } else {
            // A display with a backlight control keeps no software dim: this run's dim is undone
            // and the stored value removed, so a later failed DDC probe cannot dim it again.
            let wasDimmed = dimmed[display.id] != nil
            let wasStored = UserDefaults.standard.object(forKey: Self.key(display)) != nil
            if wasDimmed { applyDim(1, to: display) }
            if wasStored { UserDefaults.standard.removeObject(forKey: Self.key(display)) }
            if wasDimmed || wasStored { debugLog("Brightness", "software.cleared id=\(display.hexID)") }
        }
        return (backend, value)
    }

    /// A new read from the display itself; nil when it does not answer. For software dimming, the
    /// stored value (1.0 when none is stored).
    func read(_ display: DisplayInfo, backend: BrightnessBackend) async -> Double? {
        switch backend {
        case .native:
            return native(display)
        case .ddc:
            guard let reply = await DDC.shared.read(DDC.brightness, display: display.id), reply.max > 0
            else { return nil }
            ddcMax[display.id] = reply.max
            return min(Double(reply.current) / Double(reply.max), 1)
        case .software:
            let stored = UserDefaults.standard.object(forKey: Self.key(display)) as? Double ?? 1
            return min(max(stored, 0), 1)
        }
    }

    /// The built-in panel's brightness; nil when DisplayServices is missing, fails, or gives a
    /// value outside 0...1.
    private func native(_ display: DisplayInfo) -> Double? {
        guard let get = PrivateAPI.DisplayServicesGetBrightness else { return nil }
        var value: Float = -1
        let result = get(display.id, &value)
        guard result == 0, (0...1).contains(value) else {
            debugLog("Brightness", "native.failed id=\(display.hexID) result=\(result) value=\(value)")
            return nil
        }
        return Double(value)
    }

    // MARK: Write

    /// Sets the brightness. A DDC value goes through `DDC.write`, which returns before it is sent.
    func write(_ value: Double, to display: DisplayInfo, backend: BrightnessBackend) async {
        switch backend {
        case .native:
            _ = PrivateAPI.DisplayServicesSetBrightness?(display.id, Float(value))
        case .ddc:
            // The maximum comes from a read; the refresh makes one before a slider shows.
            guard let max = ddcMax[display.id] else { return }
            await DDC.shared.write(
                DDC.brightness, value: UInt16((value * Double(max)).rounded()), display: display.id)
        case .software:
            UserDefaults.standard.set(value, forKey: Self.key(display))
            applyDim(value, to: display)
        }
    }

    /// Dims a display through its gamma table: the maximum of each channel goes from 1.0 down to
    /// 0.15. At 1.0 no table is set: a display this run dimmed gets the ColorSync table back, any
    /// other display is left alone.
    func applyDim(_ value: Double, to display: DisplayInfo) {
        if value < 1 {
            dimmed[display.id] = value
            Self.didDim.store(true, ordering: .relaxed)
            Self.setGamma(value, on: display.id)
            debugLog("Brightness", "software.apply id=\(display.hexID) value=\(String(format: "%.3f", value))")
        } else if dimmed.removeValue(forKey: display.id) != nil {
            // This resets every display, so the ones still dimmed are dimmed again.
            CGDisplayRestoreColorSyncSettings()
            for (id, value) in dimmed { Self.setGamma(value, on: id) }
        }
    }

    /// At quit: gives every display its ColorSync table back, if this run dimmed one.
    nonisolated static func restoreAtQuit() {
        if didDim.load(ordering: .relaxed) { CGDisplayRestoreColorSyncSettings() }
    }

    private static func setGamma(_ value: Double, on id: CGDirectDisplayID) {
        let top = CGGammaValue(0.15 + 0.85 * value)
        CGSetDisplayTransferByFormula(id, 0, top, 1, 0, top, 1, 0, top, 1)
    }

    /// The `UserDefaults` key of a display's software dimming: "softwareBrightness.vendor:model:serial" (hex).
    private static func key(_ display: DisplayInfo) -> String {
        "softwareBrightness.\(display.hexID):\(String(display.serial, radix: 16))"
    }
}
