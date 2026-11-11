import CoreGraphics
import Foundation

/// Reads and sets display modes with CoreGraphics. Both functions run off the main actor; a
/// `CGDisplayMode` never leaves them, only values do.
enum Modes {
    /// What one read of a display's modes gives.
    struct Loaded: Sendable {
        /// The modes the menus may offer.
        var modes: [ModeInfo]
        /// The mode the display is in; it may not be one of `modes`.
        var current: ModeInfo?
        /// The panel's pixel size.
        var nativePixelSize: CGSize?
    }

    /// kDisplayModeNativeFlag (IOKit/graphics/IOGraphicsTypes.h).
    private static let nativeFlag: UInt32 = 0x0200_0000

    /// Every mode of a display, with the HiDPI and LoDPI forms of a size.
    private static func allModes(of id: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
    }

    private static func info(_ mode: CGDisplayMode, index: Int) -> ModeInfo {
        ModeInfo(
            pointSize: CGSize(width: mode.width, height: mode.height),
            pixelSize: CGSize(width: mode.pixelWidth, height: mode.pixelHeight),
            refreshRate: mode.refreshRate,
            isHiDPI: mode.pixelWidth > mode.width,
            index: index)
    }

    /// The HiDPI point sizes the display's override file declares; none when there is no file.
    private static func declaredSizes(vendor: UInt32, model: UInt32) -> [CGSize] {
        let url = URL(fileURLWithPath: DisplayOverride.path(vendor: vendor, product: model))
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [] }
        return DisplayOverride.hiDPISizes(in: plist)
    }

    /// Reads the modes of a display. A mode is kept when macOS calls it usable for the desktop, or
    /// when it is a HiDPI size the override file declares (macOS may not mark those as usable).
    @concurrent
    static func load(_ id: CGDirectDisplayID, vendor: UInt32, model: UInt32) async -> Loaded {
        let all = allModes(of: id)
        let declared = declaredSizes(vendor: vendor, model: model)
        let modes = all.enumerated().compactMap { index, mode -> ModeInfo? in
            let info = info(mode, index: index)
            let keep = mode.isUsableForDesktopGUI() || (info.isHiDPI && declared.contains(info.pointSize))
            return keep ? info : nil
        }

        let currentID = CGDisplayCopyDisplayMode(id)?.ioDisplayModeID
        let current = all.firstIndex { $0.ioDisplayModeID == currentID }.map { info(all[$0], index: $0) }

        // The pixel size the native-flagged modes share, or else the largest LoDPI mode.
        let flagged = Set(all.filter { $0.ioFlags & nativeFlag != 0 }.map { info($0, index: 0).pixelSize })
        let largestLoDPI = all.filter { $0.pixelWidth == $0.width }
            .max { ($0.width * $0.height, $0.width) < ($1.width * $1.height, $1.width) }
        let native = flagged.count == 1 ? flagged.first : largestLoDPI.map { info($0, index: 0).pixelSize }

        return Loaded(modes: modes, current: current, nativePixelSize: native)
    }

    /// Switches a display to `mode`, for good. False when the display no longer has that mode at
    /// `mode.index`, when the configuration fails, or when the display is not in the mode 2 seconds later.
    @concurrent
    static func set(_ mode: ModeInfo, on id: CGDirectDisplayID) async -> Bool {
        let all = allModes(of: id)
        guard all.indices.contains(mode.index), info(all[mode.index], index: mode.index) == mode else {
            return false
        }
        let targetID = all[mode.index].ioDisplayModeID

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, id, all[mode.index], nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        guard CGCompleteDisplayConfiguration(config, .permanently) == .success else { return false }

        // Nothing promises that the new mode is readable the moment the call returns.
        for _ in 0..<20 {
            if CGDisplayCopyDisplayMode(id)?.ioDisplayModeID == targetID { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
