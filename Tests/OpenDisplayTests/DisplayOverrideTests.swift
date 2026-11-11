import CoreGraphics
import Foundation
import Testing

// App/Display/Logic is compiled into this hostless bundle, so DisplayOverride is used directly.

private let vendor: UInt32 = 0x1e6d
private let product: UInt32 = 0x7826
private let overrides = "/Library/Displays/Contents/Resources/Overrides"
private let vendorDirectory = overrides + "/DisplayVendorID-1e6d"
private let file = vendorDirectory + "/DisplayProductID-7826"
private let temp = file + ".opendisplay-tmp"
private let preference = "/Library/Preferences/com.apple.windowserver"

@Suite struct OverrideFormatTests {
    @Test func entryIsTheTwelveBytesTheSpikeProved() {
        let entry = DisplayOverride.encodeEntry(pointWidth: 2560, pointHeight: 1080)
        #expect(entry == Data([0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x08, 0x70, 0x00, 0x00, 0x00, 0x01]))
    }

    @Test func mergeKeepsForeignKeysAndReplacesScaleResolutions() {
        let existing: [String: Any] = [
            "DisplayProductName": "Custom name",
            "target-default-ppmm": 10.07,
            "scale-resolutions": [DisplayOverride.encodeEntry(pointWidth: 1920, pointHeight: 810)],
        ]
        let sizes = [CGSize(width: 2560, height: 1080), CGSize(width: 1720, height: 720)]
        let merged = DisplayOverride.merge(sizes: sizes, into: existing, vendor: vendor, product: product)

        #expect(merged["target-default-ppmm"] as? Double == 10.07)
        #expect(merged["DisplayProductName"] as? String == "Custom name")
        #expect(merged["DisplayVendorID"] as? Int == 0x1e6d)
        #expect(merged["DisplayProductID"] as? Int == 0x7826)
        #expect(merged["scale-resolutions"] as? [Data] == [
            Data([0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x08, 0x70, 0x00, 0x00, 0x00, 0x01]),
            Data([0x00, 0x00, 0x0d, 0x70, 0x00, 0x00, 0x05, 0xa0, 0x00, 0x00, 0x00, 0x01]),
        ])
        #expect(DisplayOverride.hiDPISizes(in: merged) == sizes)
    }

    // Entries in a form this app does not write (here 16 bytes) are someone else's: never dropped.
    @Test func entriesInAnotherFormSurviveApplyAndRemove() {
        let foreign = Data([0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x08, 0x70, 0x00, 0x00, 0x00, 0x01, 0x00, 0x20, 0x00, 0x00])
        // Only this app's keys: without the foreign entry, a remove would delete the file.
        let existing: [String: Any] = [
            "DisplayVendorID": 0x1e6d,
            "DisplayProductID": 0x7826,
            "scale-resolutions": [foreign, DisplayOverride.encodeEntry(pointWidth: 1920, pointHeight: 810)],
        ]
        let merged = DisplayOverride.merge(
            sizes: [CGSize(width: 1720, height: 720)], into: existing, vendor: vendor, product: product)

        #expect(merged["scale-resolutions"] as? [Data] == [
            foreign,
            Data([0x00, 0x00, 0x0d, 0x70, 0x00, 0x00, 0x05, 0xa0, 0x00, 0x00, 0x00, 0x01]),
        ])
        #expect(DisplayOverride.removeScaleResolutions(from: existing)?["scale-resolutions"] as? [Data] == [foreign])

        // Without it: only this app's keys delete the file; a foreign key is kept in a rewrite.
        let own = DisplayOverride.merge(
            sizes: [CGSize(width: 1720, height: 720)], into: nil, vendor: vendor, product: product)
        let withForeignKey = own.merging(["target-default-ppmm": 10.07]) { $1 }
        #expect(DisplayOverride.removeScaleResolutions(from: own) == nil)
        #expect(DisplayOverride.removeScaleResolutions(from: withForeignKey)?["target-default-ppmm"] as? Double == 10.07)
    }

    // "No file" may be written or deleted; anything at the path that cannot be read as a
    // dictionary plist may not, and neither may a file that cannot be opened.
    @Test func onlyAMissingFileCountsAsMissing() throws {
        func kind(_ data: Data?, isMissing: Bool = false) -> String {
            switch DisplayOverride.file(from: data, isMissing: isMissing) {
            case .missing: "missing"
            case .unreadable: "unreadable"
            case .plist(let plist): "plist \(plist["DisplayProductName"] as? String ?? "")"
            }
        }
        let arrayRoot = try PropertyListSerialization.data(fromPropertyList: ["LG"], format: .xml, options: 0)
        let dictionary = try PropertyListSerialization.data(
            fromPropertyList: ["DisplayProductName": "LG"], format: .xml, options: 0)
        // Sizes in a form this app cannot decode at all: kept, so the file is not rewritten.
        let stringSizes = try PropertyListSerialization.data(
            fromPropertyList: ["DisplayProductName": "LG", "scale-resolutions": "2560x1080"], format: .xml, options: 0)

        #expect(kind(nil, isMissing: true) == "missing")
        #expect(kind(nil) == "unreadable")
        #expect(kind(Data([0xde, 0xad, 0xbe, 0xef])) == "unreadable")
        #expect(kind(arrayRoot) == "unreadable")
        #expect(kind(stringSizes) == "unreadable")
        #expect(kind(dictionary) == "plist LG")
    }
}

// The strings below run as root. Nothing here executes them: `sh -n` and `osacompile` only parse.
@Suite struct RootCommandTests {
    private let plist = Data((0...255).map { UInt8($0) })
    private var base64: String { plist.base64EncodedString() }

    // The preference goes off only when no override file is left; its file only when it is empty.
    private let preferenceOff = """
        if [ -z "$(/usr/bin/find '\(overrides)' -type f)" ]; then \
        /usr/bin/defaults delete \(preference) DisplayResolutionEnabled; \
        if [ "$(/usr/bin/plutil -convert json -o - \(preference).plist)" = "{}" ]; then \
        /bin/rm -f \(preference).plist; fi; fi
        """

    // Written beside the file, then moved over it: the file is replaced whole or not at all.
    // An empty temp file (the decode got no input) or a folder at the path stops it before the move.
    private var write: String {
        "/bin/mkdir -p '\(vendorDirectory)' && { /usr/bin/printf '%s' '\(base64)' | /usr/bin/base64 -D > '\(temp)'"
            + " && [ -s '\(temp)' ] && /usr/sbin/chown root:wheel '\(temp)' && /bin/chmod 644 '\(temp)'"
            + " && [ ! -d '\(file)' ] && /bin/mv -f '\(temp)' '\(file)'"
            + " || { /bin/rm -f '\(temp)'; false; }; }"
    }

    /// Exit status of `tool`, with its output discarded.
    private func status(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// The `/Library` paths in `command`, once the payload (base64 may hold "/") is taken out.
    private func libraryPaths(in command: String) -> Set<String> {
        let template = command.replacingOccurrences(of: "'\(base64)'", with: "''")
        return Set(template.matches(of: #//Library[A-Za-z0-9./_-]*/#).map { String($0.output) })
    }

    @Test func commandsAreTheFixedTemplateAroundHexAndBase64() throws {
        let install = DisplayOverride.installCommand(vendor: vendor, product: product, plistData: plist)
        let delete = DisplayOverride.removeCommand(vendor: vendor, product: product)
        let rewrite = DisplayOverride.removeCommand(vendor: vendor, product: product, rewrittenPlistData: plist)

        // Equal to the template: no metacharacter can come from the inputs.
        #expect(install == "\(write) && /usr/bin/defaults write \(preference) DisplayResolutionEnabled -bool YES")
        #expect(delete == "/bin/rm -f '\(file)' && { /bin/rmdir '\(vendorDirectory)'; \(preferenceOff); true; }")
        #expect(rewrite == "\(write) && { \(preferenceOff); true; }")

        // The payload is base64 inside single quotes, and decodes to the plist.
        #expect(base64.wholeMatch(of: #/[A-Za-z0-9+/=]+/#) != nil)
        #expect(Data(base64Encoded: base64) == plist)
        #expect(install.components(separatedBy: "'\(base64)'").count == 2)
        #expect(rewrite.components(separatedBy: "'\(base64)'").count == 2)

        // Only the display's override path (and its parents) and the one preference path.
        #expect(libraryPaths(in: install) == [vendorDirectory, file, temp, preference])
        #expect(libraryPaths(in: delete) == [vendorDirectory, file, overrides, preference, preference + ".plist"])
        #expect(libraryPaths(in: rewrite) == [vendorDirectory, file, temp, overrides, preference, preference + ".plist"])

        // The preference is deleted once, between the "no override file left" test and its "fi".
        for remove in [delete, rewrite] {
            let condition = try #require(remove.range(of: "if [ -z \"$(/usr/bin/find '\(overrides)' -type f)\" ]; then "))
            let deletion = try #require(remove.range(of: "/usr/bin/defaults delete"))
            let end = try #require(remove.range(of: "fi; fi; true; }", options: .backwards))
            #expect(condition.upperBound <= deletion.lowerBound && deletion.upperBound <= end.lowerBound)
            #expect(remove.components(separatedBy: "/usr/bin/defaults").count == 2)
            #expect(!remove[..<condition.lowerBound].contains(preference))
            #expect(!remove.contains("rm -r"))
        }

        // Syntax only.
        for command in [install, delete, rewrite] {
            #expect(try status("/bin/sh", ["-n", "-c", command]) == 0)
        }
    }

    @Test func untrustedDisplayNameStaysInsideThePromptLiteral() throws {
        let command = DisplayOverride.removeCommand(vendor: vendor, product: product, rewrittenPlistData: plist)
        let name = #"LG" & (do shell script "id") & "\"#
        let source = DisplayOverride.osascriptSource(command: command, displayName: name)

        let escapedCommand = command.replacingOccurrences(of: "\"", with: "\\\"")
        let prompt = #"OpenDisplay wants to change the display configuration for LG\" & (do shell script \"id\") & \"\\."#
        #expect(source == "do shell script \"\(escapedCommand)\" with prompt \"\(prompt)\" with administrator privileges")

        // Read as AppleScript reads it: two string literals, and nothing of the name outside them.
        var literals: [String] = []
        var outside = ""
        var current: String?
        var escaped = false
        for character in source {
            guard let text = current else {
                if character == "\"" { current = "" } else { outside.append(character) }
                continue
            }
            if escaped {
                current = text + String(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                literals.append(text)
                current = nil
            } else {
                current = text + String(character)
            }
        }
        #expect(current == nil)
        #expect(outside == "do shell script  with prompt  with administrator privileges")
        #expect(literals == [command, "OpenDisplay wants to change the display configuration for \(name)."])

        // Syntax only: osacompile compiles the script and runs nothing.
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).scpt")
        defer { try? FileManager.default.removeItem(at: script) }
        #expect(try status("/usr/bin/osacompile", ["-o", script.path, "-e", source]) == 0)
    }
}
