import CoreGraphics
import Testing

// The LG: native panel 3440x1440; the spike measured 3010x1260 as its largest accepted HiDPI size.
@Suite struct HiDPIPresetsTests {
    @Test func ultrawidePanelIsOffered2560x1080WithinNativeAndCeiling() {
        let target = CGSize(width: 2560, height: 1080)
        let uncapped = HiDPIPresets.presets(nativeWidth: 3440, nativeHeight: 1440, ceiling: nil)
        let capped = HiDPIPresets.presets(
            nativeWidth: 3440, nativeHeight: 1440, ceiling: CGSize(width: 3010, height: 1260))

        #expect(uncapped.contains(target))
        #expect(capped.contains(target))
        #expect((uncapped + capped).allSatisfy { $0.width < 3440 && $0.height < 1440 })

        // The ceiling removes something, and leaves nothing above it.
        #expect(uncapped.contains { $0.width > 3010 || $0.height > 1260 })
        #expect(capped.allSatisfy { $0.width <= 3010 && $0.height <= 1260 })
    }
}
