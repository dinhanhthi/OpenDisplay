/// DDC/CI packets for reading and setting a monitor's VCP values (brightness 0x10, volume 0x62).
/// Pure: nothing here talks to a display. Layout and checksums as measured on the LG on 2026-11-10.
enum DDCPacket {
    /// A "get VCP feature" request.
    static func getVCP(_ code: UInt8) -> [UInt8] {
        withChecksum([0x82, 0x01, code])
    }

    /// A "set VCP feature" request; the value is sent big endian.
    static func setVCP(_ code: UInt8, value: UInt16) -> [UInt8] {
        withChecksum([0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    /// The current and maximum value in a "get VCP feature" reply of at least 11 bytes; nil unless
    /// it is a successful reply for `code` with a valid checksum. Later bytes are ignored.
    static func parseReply(_ bytes: [UInt8], code: UInt8) -> (current: UInt16, max: UInt16)? {
        guard bytes.count >= 11, bytes[2] == 0x02, bytes[3] == 0x00, bytes[4] == code,
              bytes[10] == bytes[..<10].reduce(0x50, ^)
        else { return nil }
        return (
            current: UInt16(bytes[8]) << 8 | UInt16(bytes[9]),
            max: UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        )
    }

    /// A request ends with 0x6E ^ 0x51 ^ every byte before it (a reply is seeded with 0x50 instead).
    private static func withChecksum(_ bytes: [UInt8]) -> [UInt8] {
        bytes + [bytes.reduce(0x6E ^ 0x51, ^)]
    }
}
