// list-modes: lists the display modes macOS offers, checks that a HiDPI mode exists, or
// switches a display to one for a few seconds and back.
//
// Build: swiftc -O tools/list-modes.swift -o build/spike/list-modes
// Usage: list-modes [--vendor 0x<hex> --model 0x<hex>] [--dump <file>]
//        list-modes --vendor 0x<hex> --model 0x<hex> --expect WxH@2x@Hz
//        list-modes --vendor 0x<hex> --model 0x<hex> --set WxH@2x@Hz --revert-after <seconds>
//
// Exit status: 0 on success, 1 on MISSING, "set FAILED" or "REVERT FAILED", 2 on an error.

import AppKit

/// kDisplayModeNativeFlag (IOKit/graphics/IOGraphicsTypes.h).
let nativeFlag: UInt32 = 0x0200_0000

/// A HiDPI mode asked for as "WxH@2x@Hz": its point size and refresh rate.
struct Target {
    let width: Int
    let height: Int
    let hz: Double

    init?(_ text: String) {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1] == "2x", let hz = Double(parts[2]) else { return nil }
        let size = parts[0].split(separator: "x", omittingEmptySubsequences: false)
        guard size.count == 2, let width = Int(size[0]), let height = Int(size[1]) else { return nil }
        self.width = width
        self.height = height
        self.hz = hz
    }
}

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String) -> Never {
    note(message)
    exit(2)
}

func usageError() -> Never {
    fail("""
        usage: list-modes [--vendor 0x<hex> --model 0x<hex>] [--dump <file>]
                          [--expect WxH@2x@Hz | --set WxH@2x@Hz --revert-after <seconds>]
        """)
}

/// A parsed option value, or the usage text when it could not be parsed.
func required<T>(_ value: T?) -> T {
    guard let value else { usageError() }
    return value
}

func hex(_ text: String) -> UInt32? {
    UInt32(text.hasPrefix("0x") ? String(text.dropFirst(2)) : text, radix: 16)
}

func yesNo(_ value: Bool) -> String {
    value ? "yes" : "no"
}

/// "100" for 100.0 and "59.94" for 59.939987.
func hzText(_ rate: Double) -> String {
    let text = String(format: "%.2f", rate)
    return text.hasSuffix(".00") ? String(text.dropLast(3)) : text
}

func describe(_ mode: CGDisplayMode) -> String {
    "\(mode.width)x\(mode.height) (\(mode.pixelWidth)x\(mode.pixelHeight) px) @ \(hzText(mode.refreshRate)) Hz"
}

func modes(of id: CGDirectDisplayID) -> [CGDisplayMode] {
    let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    return CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
}

func matches(_ mode: CGDisplayMode, _ target: Target) -> Bool {
    mode.width == target.width && mode.height == target.height
        && mode.pixelWidth == 2 * target.width && mode.pixelHeight == 2 * target.height
        && hzText(mode.refreshRate) == hzText(target.hz)
}

/// The target mode of a display; a usable one first when macOS lists it more than once.
func find(_ target: Target, on id: CGDirectDisplayID) -> CGDisplayMode? {
    let found = modes(of: id).filter { matches($0, target) }
    return found.first { $0.isUsableForDesktopGUI() } ?? found.first
}

func configure(_ id: CGDirectDisplayID, _ mode: CGDisplayMode, _ scope: CGConfigureOption) -> Bool {
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return false }
    guard CGConfigureDisplayWithDisplayMode(config, id, mode, nil) == .success else {
        CGCancelDisplayConfiguration(config)
        return false
    }
    return CGCompleteDisplayConfiguration(config, scope) == .success
}

/// Reads the display's mode back until `accept` says yes, for 2 seconds at most: nothing
/// promises that the new mode is readable the moment the configuration call returns.
func settles(_ id: CGDirectDisplayID, on accept: (CGDisplayMode) -> Bool) -> Bool {
    for _ in 0..<20 {
        if CGDisplayCopyDisplayMode(id).map(accept) == true { return true }
        usleep(100_000)
    }
    return false
}

// MARK: Arguments

var vendor: UInt32?
var model: UInt32?
var dumpPath: String?
var expected: Target?
var wanted: Target?
var revertAfter: UInt32?

var arguments = CommandLine.arguments.dropFirst()
while let flag = arguments.popFirst() {
    guard let value = arguments.popFirst() else { usageError() }
    switch flag {
    case "--vendor": vendor = required(hex(value))
    case "--model": model = required(hex(value))
    case "--dump": dumpPath = value
    case "--expect": expected = required(Target(value))
    case "--set": wanted = required(Target(value))
    case "--revert-after": revertAfter = required(UInt32(value))
    default: usageError()
    }
}
guard (vendor == nil) == (model == nil), expected == nil || wanted == nil else { usageError() }

// MARK: Displays (matched by vendor and model: a display id can change after a replug)

var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var count: UInt32 = 0
guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else {
    fail("cannot list the displays")
}
let displays = ids.prefix(Int(count)).filter {
    vendor == nil || (CGDisplayVendorNumber($0) == vendor && CGDisplayModelNumber($0) == model)
}
if displays.isEmpty { note("no display matches") }

// MARK: --dump

if let dumpPath {
    let lines = displays.flatMap { modes(of: $0) }.map {
        "\($0.width)x\($0.height) \($0.pixelWidth)x\($0.pixelHeight) \(hzText($0.refreshRate)) "
            + ($0.pixelWidth > $0.width ? "HiDPI" : "LoDPI")
    }
    do {
        try lines.sorted().map { $0 + "\n" }.joined()
            .write(toFile: dumpPath, atomically: true, encoding: .utf8)
    } catch {
        fail("cannot write \(dumpPath)")
    }
}

// MARK: --expect

if let expected {
    guard let mode = displays.lazy.compactMap({ find(expected, on: $0) }).first else {
        print("MISSING")
        exit(1)
    }
    print("FOUND \(describe(mode)) HiDPI usable=\(yesNo(mode.isUsableForDesktopGUI()))")
    exit(0)
}

// MARK: --set

if let wanted {
    guard let seconds = revertAfter else { usageError() }
    guard displays.count == 1, let id = displays.first else {
        fail("--set needs exactly one display, \(displays.count) match: use --vendor and --model")
    }
    guard let previous = CGDisplayCopyDisplayMode(id) else { fail("cannot read the current mode") }
    guard let mode = find(wanted, on: id) else {
        print("set FAILED the display does not offer this mode")
        exit(1)
    }
    let isPrevious = { (now: CGDisplayMode) in now.ioDisplayModeID == previous.ioDisplayModeID }

    // App scope first: macOS drops it when this process ends, so the mode reverts even if the
    // tool dies. Session scope is the one retry.
    var scope: CGConfigureOption?
    for option in [CGConfigureOption.forAppOnly, .forSession] where scope == nil {
        if configure(id, mode, option), settles(id, on: { matches($0, wanted) }) { scope = option }
    }
    if let scope {
        print("set OK scope=\(scope == .forAppOnly ? "app" : "session")")
        sleep(seconds)
    } else {
        print("set FAILED read=\(CGDisplayCopyDisplayMode(id).map(describe) ?? "no mode")")
    }

    // Restore after any attempt: always after a set that worked, and after a failed one when
    // it left the display in another mode (then at session scope, the last one tried).
    if scope != nil || CGDisplayCopyDisplayMode(id).map(isPrevious) != true {
        _ = configure(id, previous, scope ?? .forSession)
        guard settles(id, on: isPrevious) else {
            print("REVERT FAILED previous=\(previous.width)x\(previous.height)@\(hzText(previous.refreshRate))")
            exit(1)
        }
        print("reverted OK")
    }
    exit(scope == nil ? 1 : 0)
}

// MARK: List

for id in displays {
    let all = modes(of: id)
    let current = CGDisplayCopyDisplayMode(id)?.ioDisplayModeID
    let nativeSizes = Set(all.filter { $0.ioFlags & nativeFlag != 0 }.map { "\($0.pixelWidth)x\($0.pixelHeight)" })
    let largestLoDPI = all.filter { $0.pixelWidth == $0.width }
        .max { ($0.width * $0.height, $0.width) < ($1.width * $1.height, $1.width) }
    let screen = NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
    }
    print([
        "display id=\(id)",
        "vendor=0x\(String(CGDisplayVendorNumber(id), radix: 16))",
        "model=0x\(String(CGDisplayModelNumber(id), radix: 16))",
        "builtin=\(yesNo(CGDisplayIsBuiltin(id) != 0))",
        "main=\(yesNo(CGDisplayIsMain(id) != 0))",
        "rotation=\(Int(CGDisplayRotation(id).rounded()))",
        "native=\(nativeSizes.count > 1 ? "ambiguous" : nativeSizes.first ?? "none")",
        "largest-lodpi=\(largestLoDPI.map { "\($0.width)x\($0.height)" } ?? "none")",
        "name=\(screen?.localizedName ?? "unknown")",
    ].joined(separator: " "))
    for mode in all {
        var fields = [describe(mode)]
        if mode.pixelWidth > mode.width { fields.append("HiDPI") }
        if mode.ioFlags & nativeFlag != 0 { fields.append("native") }
        fields.append(mode.isUsableForDesktopGUI() ? "usable" : "unusable")
        if mode.ioDisplayModeID == current { fields.append("(current)") }
        print("  " + fields.joined(separator: " "))
    }
}
