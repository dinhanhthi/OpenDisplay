import CoreGraphics
import Foundation
import Observation

/// The HiDPI sizes in one display model's override file: reads them, and applies or removes them
/// through the system's password dialog (`/usr/bin/osascript`). File reads and the dialog run off
/// the main actor; the app never sees the password.
@MainActor
@Observable
final class OverrideInstaller {
    /// How `apply(sizes:)` or `remove()` ended. `.cancelled` (the user pressed Cancel) is shown as nothing.
    enum Outcome: Sendable, Equatable {
        case done
        case cancelled
        case failed(String)
    }

    /// Where a size stands. Derived from the override file and the live mode list, never stored.
    enum SizeState: Sendable, Equatable {
        /// Not in the override file.
        case off
        /// In the file and in the live mode list.
        case active
        /// In the file, not in the mode list: "Restart your Mac to activate".
        case restartToActivate
        /// In the file, not in the mode list: "Reconnect the display to activate".
        case reconnectToActivate
    }

    /// One read of the override file and of what `DisplayOverride.needsRestart` takes.
    struct Snapshot: Sendable {
        var declaredSizes: [CGSize]
        /// Something is at the override path, but not a plist this app can read.
        var isUnreadable: Bool
        var prefModified: Date?
        var bootTime: Date
        var prefIsOn: Bool

        var needsRestart: Bool {
            DisplayOverride.needsRestart(prefModified: prefModified, bootTime: bootTime, prefIsOn: prefIsOn)
        }
    }

    /// Thrown instead of building a command on an override file this app cannot read.
    private struct UnreadableFile: LocalizedError {
        var errorDescription: String? { OverrideInstaller.unreadableMessage }
    }

    /// Shown when the override file is there but cannot be read: the app never writes or deletes it.
    nonisolated static let unreadableMessage =
        "This display already has a configuration file that OpenDisplay cannot read. It was left unchanged."

    /// The WindowServer preference file that `DisplayOverride.installCommand` writes.
    private nonisolated static let preferencePath = "/Library/Preferences/com.apple.windowserver.plist"

    let vendor: UInt32
    let model: UInt32
    /// The display's name, for the password dialog.
    let name: String

    /// The HiDPI point sizes the override file declares, in the file's order; nil until the first `reload()`.
    private(set) var declaredSizes: [CGSize]?
    /// True while the sizes need a restart of the Mac, not only a replug of the display.
    private(set) var needsRestart = false
    /// True when the override file is there but cannot be read: `apply(sizes:)` and `remove()` fail.
    private(set) var isUnreadable = false

    /// Reads nothing: call `reload()` once afterwards.
    init(vendor: UInt32, model: UInt32, name: String) {
        self.vendor = vendor
        self.model = model
        self.name = name
    }

    /// Reads the override file and the preference again.
    func reload() async {
        let snapshot = await Self.read(vendor: vendor, model: model)
        declaredSizes = snapshot.declaredSizes
        needsRestart = snapshot.needsRestart
        isUnreadable = snapshot.isUnreadable
        let declared = snapshot.declaredSizes.map { "\(Int($0.width))x\(Int($0.height))" }.joined(separator: ",")
        debugLog("Override", "state id=\(String(vendor, radix: 16)):\(String(model, radix: 16))"
            + " declared=\(declared.isEmpty ? "none" : declared) prefOn=\(snapshot.prefIsOn)"
            + " needsRestart=\(snapshot.needsRestart) unreadable=\(snapshot.isUnreadable)")
    }

    /// The state of `size`, given the display's live `modes`.
    func state(of size: CGSize, in modes: [ModeInfo]) -> SizeState {
        guard declaredSizes?.contains(size) == true else { return .off }
        if modes.contains(where: { $0.isHiDPI && $0.pointSize == size }) { return .active }
        return needsRestart ? .restartToActivate : .reconnectToActivate
    }

    /// Makes `sizes` the display's HiDPI sizes (no size: the same as `remove()`), then reloads.
    /// Fails with `unreadableMessage`, before any password dialog, when the file cannot be read.
    func apply(sizes: [CGSize]) async -> Outcome {
        let outcome = await Self.run(sizes: sizes, vendor: vendor, model: model, name: name)
        if outcome == .done { await reload() }
        return outcome
    }

    /// Removes the display's HiDPI sizes, then reloads. The override file is deleted, or rewritten
    /// without the sizes when it holds keys or entries of someone else.
    func remove() async -> Outcome {
        await apply(sizes: [])
    }

    // MARK: Off the main actor

    @concurrent
    nonisolated static func read(vendor: UInt32, model: UInt32) async -> Snapshot {
        var declared: [CGSize] = []
        var isUnreadable = false
        switch overrideFile(vendor: vendor, model: model) {
        case .missing: break
        case .unreadable: isUnreadable = true
        case .plist(let plist): declared = DisplayOverride.hiDPISizes(in: plist)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: preferencePath)
        // Without a boot time, any date of the preference counts as "after the boot".
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        let booted = sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0
        return Snapshot(
            declaredSizes: declared,
            isUnreadable: isUnreadable,
            prefModified: attributes?[.modificationDate] as? Date,
            bootTime: booted
                ? Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
                : .distantPast,
            // Read from the file itself, as its date is: no preferences cache in between.
            prefIsOn: plist(atPath: preferencePath)?["DisplayResolutionEnabled"] as? Bool == true)
    }

    /// The one argument of `/usr/bin/osascript -e` that leaves the display with `sizes` (none:
    /// without any), built on the override file as it is now. Plists travel as XML.
    /// Throws when the file is there but cannot be read: it is never deleted or overwritten.
    nonisolated static func scriptSource(
        sizes: [CGSize], vendor: UInt32, model: UInt32, name: String
    ) throws -> String {
        let existing: [String: Any]?
        switch overrideFile(vendor: vendor, model: model) {
        case .missing: existing = nil
        case .unreadable: throw UnreadableFile()
        case .plist(let plist): existing = plist
        }
        func xml(_ plist: [String: Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        }
        let command: String
        if sizes.isEmpty {
            // nil: the file holds only what this app writes (or is missing), so it is deleted.
            let rewritten = try existing.flatMap(DisplayOverride.removeScaleResolutions).map(xml)
            command = DisplayOverride.removeCommand(vendor: vendor, product: model, rewrittenPlistData: rewritten)
        } else {
            let merged = DisplayOverride.merge(sizes: sizes, into: existing, vendor: vendor, product: model)
            command = DisplayOverride.installCommand(vendor: vendor, product: model, plistData: try xml(merged))
        }
        return DisplayOverride.osascriptSource(command: command, displayName: name)
    }

    /// Runs the script; returns when the password dialog and the root command are over.
    @concurrent
    private nonisolated static func run(sizes: [CGSize], vendor: UInt32, model: UInt32, name: String) async -> Outcome {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do {
            process.arguments = ["-e", try scriptSource(sizes: sizes, vendor: vendor, model: model, name: name)]
            try process.run()
        } catch {
            return .failed(error.localizedDescription)
        }
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return .done }

        // osascript writes "<range>: execution error: <message> (<number>)"; -128 is Cancel.
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("(-128)") { return .cancelled }
        return .failed(text.range(of: "execution error: ").map { String(text[$0.upperBound...]) } ?? text)
    }

    /// The display's override file. It is missing only when `lstat` says that nothing is at the
    /// path (ENOENT, ENOTDIR): no permission, a dangling link or a folder there is unreadable.
    private nonisolated static func overrideFile(vendor: UInt32, model: UInt32) -> DisplayOverride.File {
        let path = DisplayOverride.path(vendor: vendor, product: model)
        var info = stat()
        let failed = lstat(path, &info) != 0
        // Read at once: nothing may run between `lstat` and this.
        let code = errno
        let isMissing = failed && (code == ENOENT || code == ENOTDIR)
        return DisplayOverride.file(
            from: isMissing ? nil : FileManager.default.contents(atPath: path), isMissing: isMissing)
    }

    private nonisolated static func plist(atPath path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
