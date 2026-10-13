import Foundation

enum ProgressChartScale {
    /// Keep small changes readable without magnifying a constant reading.
    /// Include every displayed series so the mean is never clipped by the zoom.
    static func weightDomain(values: [Double]) -> ClosedRange<Double> {
        let valid = values.filter { $0.isFinite && $0 > 0 }
        guard let minimum = valid.min(), let maximum = valid.max() else { return 0...1 }
        let span = max(maximum - minimum, 1)
        let center = minimum + (maximum - minimum) / 2
        let halfSpan = span / 2 + max(span * 0.15, 0.15)
        let lower = max(0, floor((center - halfSpan) * 10) / 10)
        let upper = ceil((center + halfSpan) * 10) / 10
        return lower...upper
    }
}
