import CoreGraphics
import Testing

// The LG lists 2560x1080 twice: as LoDPI (2560x1080 px) and as HiDPI (5120x2160 px).
@Suite struct ModeGroupingTests {
    @Test func hiDPIRowPicksTheHiDPIModeAtTheCurrentRate() {
        let points = CGSize(width: 2560, height: 1080)
        let pixels = CGSize(width: 5120, height: 2160)
        // The LoDPI duplicates come first, so a match on point size and rate alone would take one of them.
        let modes = [
            ModeInfo(pointSize: points, pixelSize: points, refreshRate: 60, isHiDPI: false, index: 0),
            ModeInfo(pointSize: points, pixelSize: points, refreshRate: 100, isHiDPI: false, index: 1),
            ModeInfo(pointSize: points, pixelSize: pixels, refreshRate: 60, isHiDPI: true, index: 2),
            ModeInfo(pointSize: points, pixelSize: pixels, refreshRate: 100, isHiDPI: true, index: 3),
        ]

        let rows = ModeGrouping.resolutions(from: modes)
        #expect(rows.map(\.isHiDPI) == [true, false])

        let picked = rows.first.flatMap { ModeGrouping.bestMode(for: $0, preferredRate: 100, in: modes) }
        #expect(picked == modes[3])
    }
}
