import CoreGraphics
import Foundation

/// The display override plist that adds HiDPI sizes to a display, and the root commands that
/// install or remove it. Pure functions: nothing here reads a file or runs a command.
/// Encoding and preference as measured in tools/hidpi-spike-state.md ("## Results").
enum DisplayOverride {
    private static let overrides = "/Library/Displays/Contents/Resources/Overrides"
    private static let preference = "/Library/Preferences/com.apple.windowserver"
    private static let preferenceKey = "DisplayResolutionEnabled"
    private static let sizesKey = "scale-resolutions"
    private static let ownKeys: Set = ["DisplayVendorID", "DisplayProductID", "DisplayProductName", sizesKey]

    // MARK: Plist

    /// One `scale-resolutions` entry: big-endian backing width and height (2 x the point size), then 1.
    static func encodeEntry(pointWidth: Int, pointHeight: Int) -> Data {
        var entry = Data()
        for value in [UInt32(clamping: pointWidth &* 2), UInt32(clamping: pointHeight &* 2), 1] {
            withUnsafeBytes(of: value.bigEndian) { entry.append(contentsOf: $0) }
        }
        return entry
    }

    /// What the override file holds.
    enum File {
        /// There is no file: it may be created.
        case missing
        /// Something is at the path that this app cannot read as a dictionary plist with an array
        /// of `scale-resolutions` (or none): it is someone else's, left as it is.
        case unreadable
        case plist([String: Any])
    }

    /// `isMissing` is true only when nothing is at the path; `data` is the content, nil when it
    /// could not be read. Content that cannot be read never counts as missing.
    static func file(from data: Data?, isMissing: Bool) -> File {
        if isMissing { return .missing }
        guard let data,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist[sizesKey] == nil || plist[sizesKey] is [Any]
        else { return .unreadable }
        return .plist(plist)
    }

    /// The point size of a `scale-resolutions` entry in the form `encodeEntry` writes; nil for any other form.
    private static func size(ofEntry entry: Any) -> CGSize? {
        guard let data = entry as? Data, data.count == 12 else { return nil }
        let words = (0..<3).map { word in
            data.dropFirst(word * 4).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        guard words[2] == 1, words[0] % 2 == 0, words[1] % 2 == 0 else { return nil }
        return CGSize(width: CGFloat(words[0] / 2), height: CGFloat(words[1] / 2))
    }

    /// The `scale-resolutions` entries of `plist` in another form: someone else's, kept as they are.
    private static func foreignEntries(in plist: [String: Any]) -> [Any] {
        (plist[sizesKey] as? [Any] ?? []).filter { size(ofEntry: $0) == nil }
    }

    /// The HiDPI point sizes `plist` declares. Entries in another form are skipped.
    static func hiDPISizes(in plist: [String: Any]) -> [CGSize] {
        (plist[sizesKey] as? [Any] ?? []).compactMap(size(ofEntry:))
    }

    /// `existing` with its `scale-resolutions` entries in this app's form replaced by `sizes`.
    /// Entries in another form are kept, in their order, before them. Every other key is kept,
    /// and no name is added: the sizes need no other key.
    static func merge(
        sizes: [CGSize], into existing: [String: Any]?, vendor: UInt32, product: UInt32
    ) -> [String: Any] {
        var plist = existing ?? [:]
        plist["DisplayVendorID"] = Int(vendor)
        plist["DisplayProductID"] = Int(product)
        plist[sizesKey] = foreignEntries(in: plist)
            + sizes.map { encodeEntry(pointWidth: Int($0.width), pointHeight: Int($0.height)) }
        return plist
    }

    /// `nil` when `existing` holds only what this app writes (delete the file); otherwise
    /// `existing` with nothing left in `scale-resolutions` but the entries in another form
    /// (rewrite the file, keeping those and the foreign keys).
    static func removeScaleResolutions(from existing: [String: Any]) -> [String: Any]? {
        let foreign = foreignEntries(in: existing)
        guard !foreign.isEmpty || !ownKeys.isSuperset(of: existing.keys) else { return nil }
        var plist = existing
        plist[sizesKey] = foreign.isEmpty ? nil : foreign
        return plist
    }

    /// WindowServer reads the preference at startup: a restart is needed while it is off, or when
    /// it was written after the last boot (or its date is unknown).
    static func needsRestart(prefModified: Date?, bootTime: Date, prefIsOn: Bool) -> Bool {
        guard prefIsOn, let prefModified else { return true }
        return prefModified > bootTime
    }

    // MARK: Root commands

    private static func vendorDirectory(_ vendor: UInt32) -> String {
        "\(overrides)/DisplayVendorID-\(String(vendor, radix: 16))"
    }

    /// Where macOS reads the override of a display model (unpadded lowercase hex).
    static func path(vendor: UInt32, product: UInt32) -> String {
        "\(vendorDirectory(vendor))/DisplayProductID-\(String(product, radix: 16))"
    }

    /// Replaces the override file by `plistData` in one step: the data is written to a temp file
    /// beside it, which is then moved over it. When a step fails, the temp file is removed, the
    /// command fails and the old file is as it was. The inputs reach the shell as hex digits and
    /// base64 only, both inside single quotes.
    /// An empty temp file fails too (the pipe's status is `base64`'s, which is 0 on no input), and
    /// so does a folder at the path (`mv` would move the temp file into it).
    private static func writeCommand(vendor: UInt32, product: UInt32, plistData: Data) -> String {
        let file = path(vendor: vendor, product: product)
        let temp = "\(file).opendisplay-tmp"
        return "/bin/mkdir -p '\(vendorDirectory(vendor))'"
            + " && { /usr/bin/printf '%s' '\(plistData.base64EncodedString())' | /usr/bin/base64 -D > '\(temp)'"
            + " && [ -s '\(temp)' ] && /usr/sbin/chown root:wheel '\(temp)' && /bin/chmod 644 '\(temp)'"
            + " && [ ! -d '\(file)' ] && /bin/mv -f '\(temp)' '\(file)'"
            + " || { /bin/rm -f '\(temp)'; false; }; }"
    }

    /// Turns the preference off only when no override file is left (another display may need it),
    /// and removes its file only when no key is left in it.
    private static let preferenceOff =
        "if [ -z \"$(/usr/bin/find '\(overrides)' -type f)\" ]; then"
        + " /usr/bin/defaults delete \(preference) \(preferenceKey);"
        + " if [ \"$(/usr/bin/plutil -convert json -o - \(preference).plist)\" = \"{}\" ]; then"
        + " /bin/rm -f \(preference).plist; fi; fi"

    /// The command, run as root, that installs the override and turns the preference on.
    static func installCommand(vendor: UInt32, product: UInt32, plistData: Data) -> String {
        writeCommand(vendor: vendor, product: product, plistData: plistData)
            + " && /usr/bin/defaults write \(preference) \(preferenceKey) -bool YES"
    }

    /// The command, run as root, that removes a display's HiDPI sizes: it deletes the override
    /// file, or installs `rewrittenPlistData` in its place when the file holds foreign keys or entries.
    /// Only that step can fail the command; the steps in the braces that end in `true` cannot.
    static func removeCommand(vendor: UInt32, product: UInt32, rewrittenPlistData: Data? = nil) -> String {
        guard let rewrittenPlistData else {
            return "/bin/rm -f '\(path(vendor: vendor, product: product))'"
                + " && { /bin/rmdir '\(vendorDirectory(vendor))'; \(preferenceOff); true; }"
        }
        return writeCommand(vendor: vendor, product: product, plistData: rewrittenPlistData)
            + " && { \(preferenceOff); true; }"
    }

    // MARK: AppleScript

    /// `text` as an AppleScript string literal.
    private static func appleScriptLiteral(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// The AppleScript that runs `command` as root through the system's password dialog.
    /// `displayName` is untrusted (EDID or an override file): control characters and line breaks
    /// are stripped and it is cut to 64 characters before it is escaped.
    static func osascriptSource(command: String, displayName: String) -> String {
        let scalars = displayName.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        }
        let name = String(String.UnicodeScalarView(scalars.prefix(64)))
        let prompt = "OpenDisplay wants to change the display configuration for \(name)."
        return "do shell script \(appleScriptLiteral(command)) with prompt \(appleScriptLiteral(prompt))"
            + " with administrator privileges"
    }
}
