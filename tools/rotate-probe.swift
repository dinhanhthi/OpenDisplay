// rotate-probe: finds out whether the ARZOPA can be rotated through the private MonitorPanel
// framework. It turns the display by 90 degrees for 5 seconds and back.
//
// Build: swiftc -O tools/rotate-probe.swift -o build/spike/rotate-probe
// Usage: rotate-probe --inspect   looks the API up and changes nothing on any display
//        rotate-probe             LIVE: rotates the ARZOPA, waits 5 seconds, restores it
//
// The only private API is MonitorPanel, loaded at runtime: MPDisplayMgr, its displays, the
// MPDisplay of the ARZOPA and -[MPDisplay setOrientation:]. No SkyLight or CoreGraphics
// private rotation function is called.
//
// Exit status: 0 on success and on a "not rotated" result, 1 on "RESTORE FAILED" or a failed
// --inspect, 2 on an error (usage, the ARZOPA is absent, the lookup failed).

import CoreGraphics
import Foundation

let arzopaVendor: UInt32 = 7908  // 0x1ee4
let arzopaModel: UInt32 = 8544  // 0x2160
let frameworkPath = "/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel"

/// The C shape of -[MPDisplay setOrientation:], used only after the type-encoding check.
typealias SetOrientation = @convention(c) (AnyObject, Selector, Int32) -> Void

/// Writes a line to stdout at once: nothing may sit in a buffer if the private call crashes.
func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String) -> Never {
    note(message)
    exit(2)
}

func yesNo(_ value: Bool) -> String {
    value ? "yes" : "no"
}

/// The ARZOPA's display id, matched by vendor and model and looked up again on every call:
/// nothing promises that the id survives a rotation.
func arzopaID() -> CGDirectDisplayID? {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
    return ids.prefix(Int(count)).first {
        CGDisplayVendorNumber($0) == arzopaVendor && CGDisplayModelNumber($0) == arzopaModel
    }
}

/// The ARZOPA's rotation in degrees from the public API, nil while it is not online.
func rotation() -> Int? {
    arzopaID().map { Int(CGDisplayRotation($0).rounded()) }
}

func degreesText(_ degrees: Int?) -> String {
    degrees.map(String.init) ?? "absent"
}

/// MonitorPanel's display manager; stderr says how it was created.
func makeManager() -> NSObject? {
    guard dlopen(frameworkPath, RTLD_NOW) != nil else {
        note("cannot load \(frameworkPath)")
        return nil
    }
    guard let type = NSClassFromString("MPDisplayMgr") as? NSObject.Type else {
        note("class MPDisplayMgr not found")
        return nil
    }
    for name in ["shared", "sharedMgr"] {
        let selector = NSSelectorFromString(name)
        guard type.responds(to: selector),
            let manager = type.perform(selector)?.takeUnretainedValue() as? NSObject
        else { continue }
        note("manager: +[MPDisplayMgr \(name)]")
        return manager
    }
    note("manager: [[MPDisplayMgr alloc] init]")
    return type.init()
}

func mpDisplays(of manager: NSObject) -> [NSObject] {
    guard manager.responds(to: NSSelectorFromString("displays")) else {
        note("MPDisplayMgr has no displays")
        return []
    }
    return manager.value(forKey: "displays") as? [NSObject] ?? []
}

/// The MPDisplay whose displayID (a signed int in MonitorPanel) is the given display id.
func mpDisplay(_ id: CGDirectDisplayID, of manager: NSObject) -> NSObject? {
    mpDisplays(of: manager).first {
        $0.responds(to: NSSelectorFromString("displayID"))
            && ($0.value(forKey: "displayID") as? NSNumber)?.uint32Value == id
    }
}

/// The instance method setOrientation: of the display's class, nil if it has none.
func orientationSetter(of display: NSObject) -> Method? {
    class_getInstanceMethod(type(of: display), NSSelectorFromString("setOrientation:"))
}

func encoding(of method: Method) -> String {
    method_getTypeEncoding(method).map { String(cString: $0) } ?? "none"
}

/// True when the method takes self, _cmd and one 32-bit integer ("i" or "I").
func takesInt32(_ method: Method) -> Bool {
    guard method_getNumberOfArguments(method) == 3,
        let type = method_copyArgumentType(method, 2)
    else { return false }
    defer { free(type) }
    return ["i", "I"].contains(String(cString: type))
}

/// Calls setOrientation: with degrees. False, and no call, without a 32-bit integer argument.
func turn(_ display: NSObject, to degrees: Int) -> Bool {
    guard let method = orientationSetter(of: display), takesInt32(method) else { return false }
    let call = unsafeBitCast(method_getImplementation(method), to: SetOrientation.self)
    call(display, NSSelectorFromString("setOrientation:"), Int32(degrees))
    return true
}

/// What MonitorPanel itself says about rotating this display (read-only, for stderr).
func canChangeOrientation(_ display: NSObject) -> String {
    guard display.responds(to: NSSelectorFromString("canChangeOrientation")) else { return "unknown" }
    return (display.value(forKey: "canChangeOrientation") as? Bool).map(yesNo) ?? "unknown"
}

// MARK: Arguments (anything but no argument or exactly "--inspect" stops here)

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.isEmpty || arguments == ["--inspect"] else {
    fail("usage: rotate-probe [--inspect]")
}

// MARK: --inspect (changes nothing on any display)

if arguments == ["--inspect"] {
    let manager = makeManager()
    let id = arzopaID()
    let display = manager.flatMap { manager in id.flatMap { mpDisplay($0, of: manager) } }
    let setter = display.flatMap(orientationSetter).map(encoding)
    if let display { note("canChangeOrientation=\(canChangeOrientation(display))") }
    say([
        "inspect: manager=\(yesNo(manager != nil))",
        "displays=\(manager.map(mpDisplays)?.count ?? 0)",
        "arzopa=\(id == nil ? "absent" : yesNo(display != nil))",
        "setOrientation=\(setter ?? "none")",
    ].joined(separator: " "))
    exit(manager != nil && (id == nil || setter != nil) ? 0 : 1)
}

// MARK: Live run

guard let id = arzopaID() else {
    fail("the ARZOPA (vendor 7908, model 8544) is not connected: nothing was done")
}
let original = Int(CGDisplayRotation(id).rounded())
say("original=\(original)")

guard let manager = makeManager(), let display = mpDisplay(id, of: manager),
    let setter = orientationSetter(of: display)
else {
    fail("MonitorPanel lookup failed (see rotate-probe --inspect): nothing was done")
}
note("canChangeOrientation=\(canChangeOrientation(display))")
say("setOrientation=\(encoding(of: setter))")
guard takesInt32(setter) else {
    say("not rotated: unexpected signature \(encoding(of: setter))")
    exit(0)
}

// From here to the restore check the tool must not die with the display turned.
for name in [SIGINT, SIGTERM, SIGHUP] { signal(name, SIG_IGN) }

let target = (original + 90) % 360
_ = turn(display, to: target)
sleep(5)
let during = rotation()

// Restore after any attempt, also when the display did not seem to turn (it may turn late).
// The MPDisplay is looked up again, with the first one as the fallback; one retry.
var after = during
for attempt in 0..<2 where attempt == 0 || after != original {
    _ = turn(arzopaID().flatMap { mpDisplay($0, of: manager) } ?? display, to: original)
    sleep(2)
    for _ in 0..<20 {
        after = rotation()
        if after == original { break }
        usleep(250_000)
    }
}

say("rotation: \(original) -> \(degreesText(during)) -> \(degreesText(after))")
if during != target {
    say("not rotated: CGDisplayRotation read \(degreesText(during)), not \(target), "
        + "5 seconds after setOrientation:\(target)")
}
guard after == original else {
    say("RESTORE FAILED original=\(original)")
    exit(1)
}
exit(0)
