import CoreGraphics

/// The HiDPI "looks like" sizes to offer for a display panel. Pure: nothing here reads a display.
enum HiDPIPresets {
    /// Fractions of the native size, in thousandths.
    private static let fractions = [900, 800, 750, 700, 625, 600, 500]

    /// Common sizes, offered when their aspect ratio is within 1.5 % of the panel's.
    private static let standardSizes: [(width: Int, height: Int)] = [
        (3840, 1600), (3440, 1440), (2560, 1080), (1920, 800),  // 21:9
        (3840, 2160), (3200, 1800), (2560, 1440), (1920, 1080), (1600, 900), (1280, 720),  // 16:9
        (2560, 1600), (1920, 1200), (1680, 1050), (1440, 900), (1280, 800),  // 16:10
    ]

    /// The largest HiDPI size a monitor model is known to accept. The LG's is a lower bound, measured
    /// in the Phase 1 spike (tools/hidpi-spike-state.md, `ceiling:`).
    static let knownCeilings: [(vendor: UInt32, model: UInt32, size: CGSize)] = [
        (0x1e6d, 0x7826, CGSize(width: 3010, height: 1260)),
    ]

    /// The known ceiling of a monitor model; nil for every model that was not measured.
    static func ceiling(vendor: UInt32, model: UInt32) -> CGSize? {
        knownCeilings.first { $0.vendor == vendor && $0.model == model }?.size
    }

    /// Point sizes smaller than the native size in both dimensions, and no wider and no taller
    /// than `ceiling` when there is one; sorted by width, without duplicates.
    static func presets(nativeWidth: Int, nativeHeight: Int, ceiling: CGSize?) -> [CGSize] {
        // Nearest even number of native x fraction.
        let scaled = fractions.map { fraction in
            (width: (nativeWidth * fraction + 1000) / 2000 * 2, height: (nativeHeight * fraction + 1000) / 2000 * 2)
        }
        // Cross-multiplied, so nothing is divided.
        let standard = standardSizes.filter { size in
            abs(size.width * nativeHeight - size.height * nativeWidth) * 1000 <= 15 * size.height * nativeWidth
        }
        let limit = ceiling ?? CGSize(width: nativeWidth, height: nativeHeight)
        let sizes = (scaled + standard)
            .filter { $0.width < nativeWidth && $0.height < nativeHeight }
            .map { CGSize(width: $0.width, height: $0.height) }
            .filter { $0.width <= limit.width && $0.height <= limit.height }
            .sorted { ($0.width, $0.height) < ($1.width, $1.height) }

        var presets: [CGSize] = []
        for size in sizes where presets.last != size {
            presets.append(size)
        }
        return presets
    }
}
