import Testing

// The LG's reply to a brightness read (VCP 0x10), measured on 2026-11-10: current 90, max 100.
@Suite struct DDCPacketTests {
    @Test func setPacketIsChecksummedAndAReplyWithABadChecksumIsRejected() {
        #expect(DDCPacket.setVCP(0x10, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])

        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x5A, 0x9A]
        let parsed = DDCPacket.parseReply(reply, code: 0x10)
        #expect(parsed?.current == 90)
        #expect(parsed?.max == 100)

        // 0xF5 is what the request's seed would give: a reply checked with it must not pass.
        let corrupted = Array(reply.dropLast()) + [0xF5]
        #expect(DDCPacket.parseReply(corrupted, code: 0x10) == nil)
    }
}
