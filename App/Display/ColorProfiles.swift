// The ColorSync constants are C globals, which Swift 6 takes for shared mutable state.
@preconcurrency import ColorSync
import CoreGraphics
import Foundation

/// An installed color profile.
struct ColorProfile: Hashable, Sendable {
    /// The profile's description. Two profiles can have the same one: `url` tells them apart.
    var name: String
    var url: URL
}

/// The color profile of a display: the custom one when one is set, else the factory one.
struct DisplayColorProfile: Equatable, Sendable {
    /// The name of the display's factory profile.
    var factoryName: String
    /// The profile set in place of the factory one; nil when none is set.
    var custom: ColorProfile?

    /// The name of the profile in use.
    var name: String { custom?.name ?? factoryName }
}

/// Lists the installed color profiles, and reads and sets the profile of a display, through
/// ColorSync. An actor: everything runs off the main actor and one call at a time.
actor ColorProfiles {
    static let shared = ColorProfiles()

    /// The row that gives a display its factory profile back.
    static let factoryTitle = "Factory default"

    /// The installed display-class RGB profiles, sorted by name. Reads only.
    func installed() -> [ColorProfile] {
        var profiles: [ColorProfile] = []
        // `ColorSyncIterateInstalledProfiles` gives only the system's own profiles the first time
        // a process calls it; with this option the call waits for the whole list.
        let options = [Self.key(kColorSyncWaitForCacheReply): true] as CFDictionary
        withUnsafeMutablePointer(to: &profiles) { profiles in
            ColorSyncIterateInstalledProfilesWithOptions({ info, profiles in
                guard let info = info as? [String: Any], let profiles,
                      info[ColorProfiles.key(kColorSyncProfileClass)] as? String
                          == ColorProfiles.key(kColorSyncSigDisplayClass),
                      info[ColorProfiles.key(kColorSyncProfileColorSpace)] as? String
                          == ColorProfiles.key(kColorSyncSigRgbData),
                      let url = info[ColorProfiles.key(kColorSyncProfileURL)] as? URL
                else { return true }
                let name = info[ColorProfiles.key(kColorSyncProfileDescription)] as? String
                profiles.assumingMemoryBound(to: [ColorProfile].self).pointee.append(
                    ColorProfile(name: name ?? ColorProfiles.fileName(of: url), url: url))
                return true
            }, nil, profiles, options, nil)
        }
        return profiles.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.url.path < $1.url.path : order == .orderedAscending
        }
    }

    /// The profile a display uses; nil when ColorSync does not know the display. Reads only.
    func current(of id: CGDirectDisplayID) -> DisplayColorProfile? {
        let defaultKey = Self.key(kColorSyncDeviceDefaultProfileID)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let info = ColorSyncDeviceCopyDeviceInfo(
                  kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid)?.takeRetainedValue() as? [String: Any],
              let factory = info[Self.key(kColorSyncFactoryProfiles)] as? [String: Any],
              // A display with one factory profile may not name its default.
              let defaultID = factory[defaultKey] as? String ?? factory.keys.first(where: { $0 != defaultKey })
        else { return nil }
        let factoryURL = (factory[defaultID] as? [String: Any])?[Self.key(kColorSyncDeviceProfileURL)] as? URL
        // A custom profile is stored under the id of the factory profile it stands in for; a
        // `kCFNull` there is no custom profile.
        let customURL = (info[Self.key(kColorSyncCustomProfiles)] as? [String: Any])?[defaultID] as? URL
        return DisplayColorProfile(
            factoryName: factoryURL.map(Self.name)
                ?? info[Self.key(kColorSyncDeviceDescription)] as? String ?? Self.factoryTitle,
            custom: customURL.map { ColorProfile(name: Self.name(of: $0), url: $0) })
    }

    /// Gives a display a custom profile, or its factory profile back when `profile` is nil. True
    /// when ColorSync took the change.
    func set(_ profile: ColorProfile?, on display: DisplayInfo) -> Bool {
        var ok = false
        if let uuid = CGDisplayCreateUUIDFromDisplayID(display.id)?.takeRetainedValue() {
            // `NSNull` is `kCFNull`: in place of a file it takes the custom profile away.
            let value: Any = profile?.url ?? NSNull()
            ok = ColorSyncDeviceSetCustomProfiles(
                kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid,
                [Self.key(kColorSyncDeviceDefaultProfileID): value] as CFDictionary)
        }
        debugLog("ColorProfile", "set id=\(display.hexID) profile=\(profile?.name ?? Self.factoryTitle) ok=\(ok)")
        return ok
    }

    /// The description of the profile in a file, or the file's name when it has none.
    private static func name(of url: URL) -> String {
        if let profile = ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue(),
           let name = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?,
           !name.isEmpty {
            return name
        }
        return fileName(of: url)
    }

    private static func fileName(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// A ColorSync constant as a dictionary key or value.
    private static func key(_ constant: Unmanaged<CFString>) -> String {
        constant.takeUnretainedValue() as String
    }
}
