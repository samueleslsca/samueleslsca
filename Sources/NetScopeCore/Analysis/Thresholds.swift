import Foundation

/// Documented thresholds used across scoring and diagnostics. Centralized so the methodology
/// shown to the user and the logic stay in sync. Values follow common industry practice
/// (Wi-Fi survey guidelines, ITU-T G.114 for one-way delay, typical bufferbloat grading) and are
/// NetScope's own conventions where no standard exists — the UI says so.
public enum Thresholds {
    // Wi-Fi radio (dBm / dB)
    public static let rssiExcellent = -60, rssiGood = -67, rssiFair = -75
    public static let snrExcellent = 40, snrGood = 25, snrFair = 15

    // Latency (ms)
    public static let gatewayLatencyHighWiFi = 15.0, gatewayLatencyHighWired = 5.0
    public static let gatewayJitterHigh = 10.0
    public static let internetLatencyHigh = 80.0
    public static let jitterHigh = 30.0

    // Loss (%)
    public static let lossConcerning = 1.0, lossSevere = 5.0

    // DNS (ms / ratio)
    public static let dnsSlow = 100.0, dnsVerySlow = 300.0, dnsFailureRate = 0.05

    // Bufferbloat: added latency under load (ms)
    public static let bloatMild = 30.0, bloatModerate = 60.0, bloatSevere = 200.0

    // Throughput ratios
    public static let wanSaturationRatio = 0.85
    public static let underperformRatio = 0.5

    // Stability
    public static let disconnectsPerDayConcerning = 3
    public static let rssiStdDevUnstable = 6.0

    /// Piecewise-linear score in 0…100. `points` are (input, score) sorted by input.
    public static func score(_ x: Double, _ points: [(Double, Double)]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        for i in 1..<points.count where x <= points[i].0 {
            let (x0, y0) = points[i - 1], (x1, y1) = points[i]
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
        }
        return last.1
    }
}

public enum RadioQuality: String, Codable, Sendable {
    case excellent = "Excellent", good = "Bon", fair = "Moyen", poor = "Faible", unknown = "Inconnu"

    public static func fromRSSI(_ rssi: Int?) -> RadioQuality {
        guard let r = rssi else { return .unknown }
        if r >= Thresholds.rssiExcellent { return .excellent }
        if r >= Thresholds.rssiGood { return .good }
        if r >= Thresholds.rssiFair { return .fair }
        return .poor
    }

    public static func fromSNR(_ snr: Int?) -> RadioQuality {
        guard let s = snr else { return .unknown }
        if s >= Thresholds.snrExcellent { return .excellent }
        if s >= Thresholds.snrGood { return .good }
        if s >= Thresholds.snrFair { return .fair }
        return .poor
    }
}
