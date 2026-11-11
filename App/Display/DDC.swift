import CoreGraphics
import Foundation
import IOKit

/// DDC/CI to the external monitors over I2C: reads and sets VCP values such as brightness and
/// volume. The AV services never leave this actor, and a gate lets one exchange with a monitor
/// run at a time.
actor DDC {
    static let shared = DDC()

    /// The VCP codes the app uses.
    static let brightness: UInt8 = 0x10
    static let volume: UInt8 = 0x62

    /// The I2C chip and data address of DDC/CI, as measured on the LG.
    private static let chip: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51
    /// The wait between a request and its reply, and after a set packet.
    private static let pause = Duration.milliseconds(50)

    private struct Target: Hashable {
        var display: CGDirectDisplayID
        var code: UInt8
    }

    private var services: [CGDirectDisplayID: CFTypeRef] = [:]
    private var supported: [CGDirectDisplayID: Set<UInt8>] = [:]
    /// The latest value not yet sent, and the targets that have a send loop running.
    private var pending: [Target: UInt16] = [:]
    private var sending: Set<Target> = []
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    // MARK: Refresh

    /// Finds the DDC service of each display again and reads once which controls it answers.
    /// Returns the supported VCP codes of every display that has a service.
    func refresh(_ displays: [DisplayInfo]) async -> [CGDirectDisplayID: Set<UInt8>] {
        let matched = match(displays)
        services = Dictionary(uniqueKeysWithValues: matched.map { ($0.display.id, $0.service) })
        var result: [CGDirectDisplayID: Set<UInt8>] = [:]
        for (display, _) in matched {
            var codes: Set<UInt8> = []
            for code in [Self.brightness, Self.volume] {
                if await read(code, display: display.id) != nil { codes.insert(code) }
            }
            result[display.id] = codes
            debugLog("DDC", "ddc.match id=\(display.hexID) display=\(display.id)"
                + " brightness=\(codes.contains(Self.brightness)) volume=\(codes.contains(Self.volume))")
        }
        supported = result
        return result
    }

    /// Whether the display answered a read of `code` at the last refresh.
    func supports(_ code: UInt8, display: CGDirectDisplayID) -> Bool {
        supported[display]?.contains(code) ?? false
    }

    /// The external AV services, each with the one display whose CoreGraphics vendor, model and
    /// serial equal its EDID's. None when a private function is missing.
    private func match(_ displays: [DisplayInfo]) -> [(display: DisplayInfo, service: CFTypeRef)] {
        guard let create = PrivateAPI.IOAVServiceCreateWithService, let copyEDID = PrivateAPI.IOAVServiceCopyEDID,
              PrivateAPI.IOAVServiceReadI2C != nil, PrivateAPI.IOAVServiceWriteI2C != nil
        else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator)
                == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [(display: DisplayInfo, service: CFTypeRef)] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            var edidRef: Unmanaged<CFData>?
            guard location == "External", let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue(),
                  copyEDID(service, &edidRef) == KERN_SUCCESS, let edid = edidRef?.takeRetainedValue() as Data?,
                  edid.count >= 16
            else { continue }
            // Vendor is big endian; product and serial are little endian.
            let vendor = UInt32(edid[8]) << 8 | UInt32(edid[9])
            let product = UInt32(edid[11]) << 8 | UInt32(edid[10])
            let serial = UInt32(edid[15]) << 24 | UInt32(edid[14]) << 16 | UInt32(edid[13]) << 8 | UInt32(edid[12])
            let same = displays.filter { $0.vendor == vendor && $0.model == product && $0.serial == serial }
            // Two displays with one EDID cannot be told apart: no DDC for them.
            if same.count == 1 { found.append((same[0], service)) }
        }
        // Nor can a display that two services claim.
        return found.filter { one in found.count { $0.display.id == one.display.id } == 1 }
    }

    // MARK: Read

    /// The current and maximum value of a VCP code; nil when the display has no DDC service or
    /// gives no valid reply in 3 attempts.
    func read(_ code: UInt8, display: CGDirectDisplayID) async -> (current: UInt16, max: UInt16)? {
        guard services[display] != nil else { return nil }
        let start = ContinuousClock.now
        defer { debugLog("Timing", "ddc.read ms=\(Int((ContinuousClock.now - start) / .milliseconds(1)))") }
        for _ in 0..<3 {
            if let value = await attempt(code, display: display) { return value }
        }
        return nil
    }

    /// One request and its reply.
    private func attempt(_ code: UInt8, display: CGDirectDisplayID) async -> (current: UInt16, max: UInt16)? {
        await enter()
        defer { leave() }
        guard let service = services[display], let writeI2C = PrivateAPI.IOAVServiceWriteI2C,
              let readI2C = PrivateAPI.IOAVServiceReadI2C
        else { return nil }
        let packet = DDCPacket.getVCP(code)
        let sent = writeI2C(service, Self.chip, Self.dataAddress, packet, UInt32(packet.count)) == KERN_SUCCESS
        try? await Task.sleep(for: Self.pause)
        var reply = [UInt8](repeating: 0, count: 12)
        guard sent else { return nil }
        let received = readI2C(service, Self.chip, Self.dataAddress, &reply, UInt32(reply.count)) == KERN_SUCCESS
        // DDC/CI wants a gap between a reply and the next request: the gate stays closed meanwhile.
        try? await Task.sleep(for: Self.pause)
        return received ? DDCPacket.parseReply(reply, code: code) : nil
    }

    // MARK: Write

    /// Sets a VCP code. Returns at once: only the latest value per display and code is sent, at
    /// most one packet every 50 ms.
    func write(_ code: UInt8, value: UInt16, display: CGDirectDisplayID) {
        let target = Target(display: display, code: code)
        pending[target] = value
        guard sending.insert(target).inserted else { return }
        Task {
            // A value that arrives while one is being sent is picked up by the next turn.
            while let value = pending.removeValue(forKey: target) {
                await send(value, to: target)
            }
            sending.remove(target)
        }
    }

    /// One set packet, then the 50 ms the monitor needs before its next packet.
    private func send(_ value: UInt16, to target: Target) async {
        await enter()
        defer { leave() }
        guard let service = services[target.display], let writeI2C = PrivateAPI.IOAVServiceWriteI2C else { return }
        let packet = DDCPacket.setVCP(target.code, value: value)
        _ = writeI2C(service, Self.chip, Self.dataAddress, packet, UInt32(packet.count))
        debugLog("Timing", "slider.write code=\(String(target.code, radix: 16)) value=\(value)")
        try? await Task.sleep(for: Self.pause)
    }

    // MARK: Gate

    /// Waits for the exchange in progress to end. Needed because an actor method that sleeps lets
    /// other calls in: without it a second request could go out before the first reply is read.
    private func enter() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the gate to the next waiting exchange, if any.
    private func leave() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}
