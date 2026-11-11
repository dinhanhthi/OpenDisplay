import CoreGraphics
import Foundation

/// Which display is the main one, and how a display is turned. An actor: the changes run off the
/// main actor and one at a time.
actor Arrangement {
    static let shared = Arrangement()

    /// The displays that are online, mirrored ones included.
    static func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// "vendorHex:modelHex" of a display id, the same form as `DisplayInfo.hexID`.
    static func hexID(of id: CGDirectDisplayID) -> String {
        "\(String(CGDisplayVendorNumber(id), radix: 16)):\(String(CGDisplayModelNumber(id), radix: 16))"
    }

    /// A display's rotation in degrees: 0, 90, 180 or 270.
    static func rotation(of id: CGDirectDisplayID) -> Int {
        Int(CGDisplayRotation(id).rounded())
    }

    // MARK: Main display

    /// Makes a display the main one, for good. True when it is the main display in the end (also
    /// when it already was, and then nothing is changed).
    func setMain(_ id: CGDirectDisplayID) async -> Bool {
        let ok = await moveToOrigin(id)
        debugLog("Arrangement", "setMain id=\(Self.hexID(of: id)) ok=\(ok)")
        return ok
    }

    /// The main display is the one at (0,0): every display moves by the same amount, so the
    /// arrangement keeps its shape and the way back gives the origins of before.
    private func moveToOrigin(_ id: CGDirectDisplayID) async -> Bool {
        let online = Self.onlineDisplays()
        guard online.contains(id) else { return false }
        if CGDisplayIsMain(id) != 0 { return true }
        let origin = CGDisplayBounds(id).origin
        // A display that mirrors another has no place of its own, and setting its origin would
        // take it out of the mirror set.
        let moved = online.filter { $0 == id || CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        for display in moved {
            let from = CGDisplayBounds(display).origin
            let x = Int32(from.x - origin.x), y = Int32(from.y - origin.y)
            guard CGConfigureDisplayOrigin(config, display, x, y) == .success else {
                CGCancelDisplayConfiguration(config)
                return false
            }
        }
        // The configuration is no longer valid once this returns, so a failure here has nothing to cancel.
        guard CGCompleteDisplayConfiguration(config, .permanently) == .success else { return false }

        // Nothing promises that the new main display is readable the moment the call returns.
        for _ in 0..<20 {
            if CGDisplayIsMain(id) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    // MARK: Rotation

    /// The displays of `ids` that MonitorPanel can turn; none when the framework cannot be used.
    /// Reads only.
    func rotatable(_ ids: [CGDirectDisplayID]) -> Set<CGDirectDisplayID> {
        Set(ids.filter { ODRotationAvailable($0) })
    }

    /// Turns a display to 0, 90, 180 or 270 degrees. True when the display reads that rotation
    /// within 5 seconds.
    func setRotation(_ degrees: Int, on id: CGDirectDisplayID) async -> Bool {
        let ok = await turn(id, to: degrees)
        debugLog("Arrangement", "setRotation id=\(Self.hexID(of: id)) degrees=\(degrees) ok=\(ok)")
        return ok
    }

    private func turn(_ id: CGDirectDisplayID, to degrees: Int) async -> Bool {
        guard [0, 90, 180, 270].contains(degrees), ODRotationSet(id, Int32(degrees)) else { return false }
        // The call returns nothing, and nothing promises that the display has turned when it returns.
        for _ in 0..<20 {
            if Self.rotation(of: id) == degrees { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }
}
