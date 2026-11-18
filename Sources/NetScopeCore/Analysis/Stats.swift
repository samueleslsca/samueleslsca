import Foundation

/// Small, dependency-free statistics helpers used by every analysis engine.
public enum Stats {
    public static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    /// Linear-interpolated percentile (same definition as NumPy's default).
    public static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        if s.count == 1 { return s[0] }
        let rank = min(max(p, 0), 100) / 100 * Double(s.count - 1)
        let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
        return s[lo] + (s[hi] - s[lo]) * (rank - Double(lo))
    }

    public static func median(_ xs: [Double]) -> Double? { percentile(xs, 50) }

    public static func standardDeviation(_ xs: [Double]) -> Double? {
        guard xs.count >= 2, let m = mean(xs) else { return nil }
        let v = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count - 1)
        return v.squareRoot()
    }

    /// Coefficient of variation (σ/μ). Useful to express throughput variability across runs.
    public static func coefficientOfVariation(_ xs: [Double]) -> Double? {
        guard let m = mean(xs), m != 0, let sd = standardDeviation(xs) else { return nil }
        return sd / m
    }

    public static func meanAbsoluteConsecutiveDifference(_ xs: [Double]) -> Double? {
        guard xs.count >= 2 else { return nil }
        var total = 0.0
        for i in 1..<xs.count { total += abs(xs[i] - xs[i - 1]) }
        return total / Double(xs.count - 1)
    }

    /// Samples exceeding `factor × median` and at least `minimumDeltaMs` above it.
    public static func spikes(_ xs: [Double], factor: Double = 2.0, minimumDeltaMs: Double = 20) -> [Int] {
        guard let med = median(xs) else { return [] }
        return xs.indices.filter { xs[$0] > med * factor && xs[$0] - med >= minimumDeltaMs }
    }

    /// Ordinary least-squares slope (units of y per unit of x).
    public static func slope(x: [Double], y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 2, let mx = mean(x), let my = mean(y) else { return nil }
        var num = 0.0, den = 0.0
        for i in x.indices { num += (x[i] - mx) * (y[i] - my); den += (x[i] - mx) * (x[i] - mx) }
        return den == 0 ? nil : num / den
    }
}

/// Formatting helpers that keep the bits vs bytes distinction explicit.
public enum Units {
    /// Formats a bit rate (bits per second) as Mbps or Gbps.
    public static func bitRate(_ bps: Double) -> String {
        if bps >= 1_000_000_000 { return String(format: "%.2f Gbit/s", bps / 1_000_000_000) }
        if bps >= 1_000_000 { return String(format: "%.1f Mbit/s", bps / 1_000_000) }
        if bps >= 1_000 { return String(format: "%.0f kbit/s", bps / 1_000) }
        return String(format: "%.0f bit/s", bps)
    }

    /// Formats a byte count (octets). Decimal (SI) prefixes, matching macOS Finder.
    public static func bytes(_ b: Double) -> String {
        let units = ["o", "Ko", "Mo", "Go", "To"]
        var v = b, i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        return i == 0 ? String(format: "%.0f %@", v, units[i]) : String(format: "%.2f %@", v, units[i])
    }

    public static func byteRate(_ bytesPerSecond: Double) -> String { bytes(bytesPerSecond) + "/s" }

    public static func ms(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v < 10 ? String(format: "%.1f ms", v) : String(format: "%.0f ms", v)
    }
}
