import CoreGraphics

/// One display mode, as a value. `index` is its position in the display's mode array.
struct ModeInfo: Sendable, Equatable {
    var pointSize: CGSize
    var pixelSize: CGSize
    var refreshRate: Double
    var isHiDPI: Bool
    var index: Int

    /// The rate used for grouping and matching: 59.94 counts as 60.
    var roundedRate: Int { Int(refreshRate.rounded()) }
}

/// One row of the Resolution menu: a point size, as HiDPI or not.
struct ResolutionRow: Sendable, Hashable {
    var pointSize: CGSize
    var isHiDPI: Bool
}

/// Turns a display's modes into the rows of the Resolution and Refresh rate menus. Pure: nothing
/// here reads a display.
enum ModeGrouping {
    /// One row per point size and HiDPI flag: HiDPI rows first, then wider first, then taller first.
    static func resolutions(from modes: [ModeInfo]) -> [ResolutionRow] {
        var rows: [ResolutionRow] = []
        for mode in modes {
            let row = ResolutionRow(pointSize: mode.pointSize, isHiDPI: mode.isHiDPI)
            if !rows.contains(row) { rows.append(row) }
        }
        return rows.sorted { a, b in
            if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
            return (a.pointSize.width, a.pointSize.height) > (b.pointSize.width, b.pointSize.height)
        }
    }

    /// The distinct rounded refresh rates of `row`, highest first.
    static func refreshRates(for row: ResolutionRow, in modes: [ModeInfo]) -> [Int] {
        Set(self.modes(of: row, in: modes).map(\.roundedRate)).sorted(by: >)
    }

    /// The mode of `row` at `preferredRate`, or else at the highest rate not above it, or else at
    /// the row's lowest rate. `nil` when the row has no mode.
    static func bestMode(for row: ResolutionRow, preferredRate: Double, in modes: [ModeInfo]) -> ModeInfo? {
        let rates = refreshRates(for: row, in: modes)
        let preferred = Int(preferredRate.rounded())
        guard let rate = rates.first(where: { $0 <= preferred }) ?? rates.last else { return nil }
        // Repeated size and rate combinations: the first one in the display's list.
        return self.modes(of: row, in: modes).first { $0.roundedRate == rate }
    }

    private static func modes(of row: ResolutionRow, in modes: [ModeInfo]) -> [ModeInfo] {
        modes.filter { $0.pointSize == row.pointSize && $0.isHiDPI == row.isHiDPI }
    }
}
