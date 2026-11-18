import Foundation

/// One trial of the Bufferbloat & QoS Lab: latency probes collected while the link is idle,
/// during a download-only load and during an upload-only load.
public struct BufferbloatTrial: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var target: String
    public var idleMs: [Double]
    public var downloadLoadedMs: [Double]
    public var uploadLoadedMs: [Double]
    public var idleLossPercent: Double
    public var downloadLossPercent: Double
    public var uploadLossPercent: Double
    public var downloadBps: Double?
    public var uploadBps: Double?
    public var label: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), target: String, idleMs: [Double], downloadLoadedMs: [Double],
                uploadLoadedMs: [Double], idleLossPercent: Double = 0, downloadLossPercent: Double = 0,
                uploadLossPercent: Double = 0, downloadBps: Double? = nil, uploadBps: Double? = nil, label: String = "") {
        self.id = id; self.timestamp = timestamp; self.target = target; self.idleMs = idleMs
        self.downloadLoadedMs = downloadLoadedMs; self.uploadLoadedMs = uploadLoadedMs
        self.idleLossPercent = idleLossPercent; self.downloadLossPercent = downloadLossPercent
        self.uploadLossPercent = uploadLossPercent; self.downloadBps = downloadBps; self.uploadBps = uploadBps
        self.label = label
    }
}

public enum BloatGrade: String, Codable, Sendable, Comparable {
    case aPlus = "A+", a = "A", b = "B", c = "C", d = "D", f = "F"

    /// NetScope grading of added latency under load (ms). Inspired by commonly used bufferbloat scales;
    /// not a standard.
    public static func from(addedMs: Double) -> BloatGrade {
        switch addedMs {
        case ..<5: return .aPlus
        case ..<30: return .a
        case ..<60: return .b
        case ..<200: return .c
        case ..<400: return .d
        default: return .f
        }
    }
    private var rank: Int { ["A+": 0, "A": 1, "B": 2, "C": 3, "D": 4, "F": 5][rawValue] ?? 5 }
    public static func < (a: BloatGrade, b: BloatGrade) -> Bool { a.rank > b.rank } // worse grade is "smaller"
}

public struct DirectionAnalysis: Codable, Hashable, Sendable {
    public var addedMedianMs: Double?
    public var addedP95Ms: Double?
    public var grade: BloatGrade?
    public var trialSpreadMs: Double?
}

public struct BufferbloatReport: Codable, Hashable, Sendable {
    public var trials: Int
    public var idleMedianMs: Double?
    public var idleJitterMs: Double?
    public var download: DirectionAnalysis
    public var upload: DirectionAnalysis
    public var overallGrade: BloatGrade?
    public var verdict: String
    public var confidence: Confidence
    public var methodology: String
}

public enum BufferbloatAnalyzer {
    public static let methodology = """
    Latence mesurée par sondes ICMP (ping) vers une cible fixe : au repos, puis pendant une charge descendante seule \
    et une charge montante seule générées par networkQuality (modes -u / -d). La latence ajoutée est la différence \
    entre la médiane sous charge et la médiane au repos ; le P95 capture les pics. Le barème (A+ < 5 ms, A < 30, \
    B < 60, C < 200, D < 400, F au-delà) est propre à NetScope. Au moins 3 essais sont nécessaires pour une conclusion.
    """

    public static func analyze(_ trials: [BufferbloatTrial]) -> BufferbloatReport {
        let idleAll = trials.flatMap(\.idleMs)
        let idleMed = Stats.median(idleAll)
        func direction(_ kp: KeyPath<BufferbloatTrial, [Double]>) -> DirectionAnalysis {
            let perTrial: [Double] = trials.compactMap { t in
                guard let l = Stats.median(t[keyPath: kp]), let i = Stats.median(t.idleMs) else { return nil }
                return max(0, l - i)
            }
            let p95s: [Double] = trials.compactMap { t in
                guard let l = Stats.percentile(t[keyPath: kp], 95), let i = Stats.median(t.idleMs) else { return nil }
                return max(0, l - i)
            }
            let med = Stats.median(perTrial)
            let spread = perTrial.count >= 2 ? (perTrial.max()! - perTrial.min()!) : nil
            return DirectionAnalysis(addedMedianMs: med, addedP95Ms: Stats.median(p95s), grade: med.map(BloatGrade.from), trialSpreadMs: spread)
        }
        let dl = direction(\.downloadLoadedMs)
        let ul = direction(\.uploadLoadedMs)
        let overall = [dl.grade, ul.grade].compactMap { $0 }.min()
        let worstAdded = [dl.addedMedianMs, ul.addedMedianMs].compactMap { $0 }.max()
        let conf: Confidence = trials.count >= 3 ? .high : (trials.count == 2 ? .medium : (trials.isEmpty ? .none : .low))
        var verdict: String
        if let w = worstAdded {
            if w < Thresholds.bloatMild { verdict = "Pas de symptôme significatif de bufferbloat : la latence reste stable sous charge." }
            else if w < Thresholds.bloatModerate { verdict = "Symptômes légers compatibles avec du bufferbloat." }
            else if w < Thresholds.bloatSevere { verdict = "Symptômes nets compatibles avec du bufferbloat : appels vidéo et jeux peuvent être affectés pendant les transferts." }
            else { verdict = "Symptômes sévères compatibles avec du bufferbloat." }
            if let u = ul.addedMedianMs, let d = dl.addedMedianMs, u > d * 2, u >= Thresholds.bloatMild {
                verdict += " La file d’attente montante est la plus affectée (fréquent sur les liens asymétriques)."
            }
            if trials.count < 3 { verdict += " Moins de 3 essais : à confirmer." }
        } else { verdict = "Mesures insuffisantes pour évaluer la latence sous charge." }
        return BufferbloatReport(trials: trials.count, idleMedianMs: idleMed, idleJitterMs: Stats.meanAbsoluteConsecutiveDifference(idleAll),
                                 download: dl, upload: ul, overallGrade: overall, verdict: verdict, confidence: conf,
                                 methodology: methodology)
    }
}

/// Before/after comparison with explicit variability. Never announces an improvement without enough evidence.
public enum CampaignComparison {
    public enum Outcome: String, Codable, Sendable {
        case improved = "Amélioration mesurée"
        case degraded = "Dégradation mesurée"
        case noSignificantChange = "Pas de différence significative"
        case insufficientData = "Données insuffisantes"
    }

    public struct Result: Codable, Hashable, Sendable {
        public var metric: String
        public var beforeMedian: Double?
        public var afterMedian: Double?
        public var relativeChange: Double?
        public var outcome: Outcome
        public var explanation: String
    }

    /// - Parameters:
    ///   - lowerIsBetter: true for latency, false for throughput.
    ///   - minimumRelative: minimum relative change considered meaningful (default 10 %).
    public static func compare(metric: String, before: [Double], after: [Double], lowerIsBetter: Bool,
                               minimumRelative: Double = 0.10, minimumSamples: Int = 3) -> Result {
        guard before.count >= minimumSamples, after.count >= minimumSamples,
              let mb = Stats.median(before), let ma = Stats.median(after) else {
            return Result(metric: metric, beforeMedian: Stats.median(before), afterMedian: Stats.median(after), relativeChange: nil,
                          outcome: .insufficientData,
                          explanation: "Au moins \(minimumSamples) mesures avant et après sont nécessaires (actuellement \(before.count) / \(after.count)).")
        }
        let rel = mb == 0 ? 0 : (ma - mb) / abs(mb)
        // Overlap test on interquartile ranges: if IQRs overlap, the change is within normal variability.
        let qb = (Stats.percentile(before, 25)!, Stats.percentile(before, 75)!)
        let qa = (Stats.percentile(after, 25)!, Stats.percentile(after, 75)!)
        let overlap = qa.0 <= qb.1 && qb.0 <= qa.1
        let better = lowerIsBetter ? ma < mb : ma > mb
        if abs(rel) < minimumRelative || overlap {
            return Result(metric: metric, beforeMedian: mb, afterMedian: ma, relativeChange: rel, outcome: .noSignificantChange,
                          explanation: overlap ? "Les intervalles interquartiles se recouvrent : l’écart reste dans la variabilité normale des tests."
                                               : String(format: "Écart de %.0f %%, inférieur au seuil de %.0f %%.", rel * 100, minimumRelative * 100))
        }
        return Result(metric: metric, beforeMedian: mb, afterMedian: ma, relativeChange: rel, outcome: better ? .improved : .degraded,
                      explanation: String(format: "Médiane %@ de %.0f %% sans recouvrement des intervalles interquartiles (%d mesures avant, %d après).",
                                          rel >= 0 ? "en hausse" : "en baisse", abs(rel) * 100, before.count, after.count))
    }
}
