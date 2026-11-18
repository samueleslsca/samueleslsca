import Foundation

// MARK: - MAX BOOST score

public struct BoostScoreComponent: Codable, Hashable, Identifiable, Sendable {
    public var id: String { criterion }
    public var criterion: String
    public var weight: Double
    public var score: Double?
    public var input: String
    public var rule: String
}

public struct BoostScore: Codable, Hashable, Sendable {
    public var total: Double?
    public var confidence: Confidence
    public var components: [BoostScoreComponent]
    public var note: String
}

/// 0–100 optimisation score with visible weights. Missing criteria are excluded, never assumed good.
public enum MaxBoostScore {
    public static let weights: [(String, Double)] = [
        ("Débit / référence", 25), ("Latence au repos", 15), ("Latence sous charge", 20),
        ("Stabilité", 15), ("Pertes", 10), ("Qualité radio", 10), ("Fiabilité", 5),
    ]

    public static func compute(samples: [BoostSample], referenceDownBps: Double?, isWired: Bool,
                               snr: Int? = nil, disconnects24h: Int? = nil) -> BoostScore {
        func w(_ name: String) -> Double { weights.first { $0.0 == name }?.1 ?? 0 }
        var c: [BoostScoreComponent] = []
        let dl = samples.compactMap(\.downloadBps)

        if let med = Stats.median(dl) {
            if let ref = referenceDownBps, ref > 0 {
                c.append(.init(criterion: "Débit / référence", weight: w("Débit / référence"),
                               score: Thresholds.score(med / ref, [(0.1, 0), (0.3, 35), (0.5, 60), (0.8, 90), (0.95, 100)]),
                               input: "\(Units.bitRate(med)) pour une référence de \(Units.bitRate(ref))",
                               rule: "Rapport médiane/référence : 10 %→0, 50 %→60, 80 %→90, 95 %→100. Référence = offre déclarée ou meilleure mesure Ethernet."))
            } else {
                c.append(.init(criterion: "Débit / référence", weight: w("Débit / référence"),
                               score: Thresholds.score(med / 1e6, [(1, 0), (10, 40), (50, 70), (200, 90), (500, 100)]),
                               input: Units.bitRate(med),
                               rule: "Sans référence : échelle absolue 1→0, 10→40, 50→70, 200→90, 500 Mbit/s→100."))
            }
        } else { c.append(.init(criterion: "Débit / référence", weight: w("Débit / référence"), score: nil, input: "—", rule: "Aucune mesure de débit.")) }

        if let idle = Stats.median(samples.compactMap(\.idleLatencyMs)) {
            c.append(.init(criterion: "Latence au repos", weight: w("Latence au repos"),
                           score: Thresholds.score(idle, [(5, 100), (15, 90), (30, 75), (60, 45), (150, 10), (300, 0)]),
                           input: Units.ms(idle), rule: "Médiane ICMP : 5→100, 15→90, 30→75, 60→45, 150→10, 300 ms→0."))
        } else { c.append(.init(criterion: "Latence au repos", weight: w("Latence au repos"), score: nil, input: "—", rule: "Non mesurée.")) }

        let added = samples.compactMap { s in s.loadedLatencyMs.flatMap { l in s.idleLatencyMs.map { max(0, l - $0) } } }
        if let a = Stats.median(added) {
            c.append(.init(criterion: "Latence sous charge", weight: w("Latence sous charge"),
                           score: Thresholds.score(a, [(5, 100), (30, 80), (60, 60), (200, 25), (400, 0)]),
                           input: "+\(Units.ms(a)) sous charge", rule: "Latence ajoutée (barème bufferbloat) : 5→100, 30→80, 60→60, 200→25, 400 ms→0."))
        } else { c.append(.init(criterion: "Latence sous charge", weight: w("Latence sous charge"), score: nil, input: "—", rule: "Non mesurée.")) }

        let jit = Stats.median(samples.compactMap(\.jitterMs))
        let cv = Stats.coefficientOfVariation(dl)
        if jit != nil || cv != nil {
            var parts: [Double] = []
            var inputs: [String] = []
            if let j = jit { parts.append(Thresholds.score(j, [(1, 100), (5, 85), (15, 60), (40, 20), (100, 0)])); inputs.append("gigue \(Units.ms(j))") }
            if let v = cv, dl.count >= 2 { parts.append(Thresholds.score(v, [(0.02, 100), (0.1, 80), (0.25, 50), (0.5, 10)])); inputs.append(String(format: "variation du débit %.0f %%", v * 100)) }
            c.append(.init(criterion: "Stabilité", weight: w("Stabilité"), score: parts.reduce(0, +) / Double(parts.count),
                           input: inputs.joined(separator: ", "), rule: "Moyenne : gigue (1→100, 15→60, 100 ms→0) et coefficient de variation du débit entre essais (2 %→100, 25 %→50)."))
        } else { c.append(.init(criterion: "Stabilité", weight: w("Stabilité"), score: nil, input: "—", rule: "Non mesurée.")) }

        if let loss = Stats.mean(samples.compactMap(\.lossPercent)) {
            c.append(.init(criterion: "Pertes", weight: w("Pertes"), score: Thresholds.score(loss, [(0, 100), (0.5, 85), (1, 70), (5, 20), (10, 0)]),
                           input: String(format: "%.2f %%", loss), rule: "Pertes ICMP moyennes : 0→100, 1→70, 5→20, 10 %→0."))
        } else { c.append(.init(criterion: "Pertes", weight: w("Pertes"), score: nil, input: "—", rule: "Non mesurées.")) }

        if isWired {
            c.append(.init(criterion: "Qualité radio", weight: w("Qualité radio"), score: 100, input: "Ethernet", rule: "Connexion filaire : sans objet."))
        } else if let r = Stats.median(samples.compactMap { $0.rssi.map(Double.init) }) {
            var s = Thresholds.score(r, [(-85, 0), (-75, 40), (-67, 70), (-60, 90), (-50, 100)])
            var input = String(format: "RSSI %.0f dBm", r)
            if let snr { s = (s + Thresholds.score(Double(snr), [(5, 0), (15, 40), (25, 70), (40, 100)])) / 2; input += ", SNR \(snr) dB" }
            c.append(.init(criterion: "Qualité radio", weight: w("Qualité radio"), score: s, input: input, rule: "RSSI (−85→0, −67→70, −50→100), moyenné avec le SNR si disponible."))
        } else { c.append(.init(criterion: "Qualité radio", weight: w("Qualité radio"), score: nil, input: "—", rule: "Non mesurée.")) }

        if let d = disconnects24h {
            c.append(.init(criterion: "Fiabilité", weight: w("Fiabilité"), score: Thresholds.score(Double(d), [(0, 100), (1, 75), (3, 40), (10, 0)]),
                           input: "\(d) déconnexion(s) sur 24 h", rule: "0→100, 1→75, 3→40, 10→0."))
        } else { c.append(.init(criterion: "Fiabilité", weight: w("Fiabilité"), score: nil, input: "—", rule: "Historique de déconnexions insuffisant.")) }

        let avail = c.filter { $0.score != nil }
        let tw = avail.reduce(0) { $0 + $1.weight }
        let total = tw > 0 ? avail.reduce(0) { $0 + ($1.score ?? 0) * $1.weight } / tw : nil
        let conf: Confidence = total == nil ? .none : (tw >= 85 && samples.count >= 3 ? .high : (tw >= 60 ? .medium : .low))
        return BoostScore(total: total, confidence: conf, components: c,
                          note: "Pondérations : débit 25, latence au repos 15, latence sous charge 20, stabilité 15, pertes 10, radio 10, fiabilité 5. Un score de 100 ne prouve pas qu’aucune amélioration n’est possible : il signifie seulement que les critères mesurés atteignent les seuils du barème.")
    }
}

// MARK: - A/B testing

public struct MetricDelta: Codable, Hashable, Identifiable, Sendable {
    public var id: String { metric.rawValue }
    public var metric: BoostMetric
    public var baselineMedian: Double?
    public var candidateMedian: Double?
    public var relativeChange: Double?
    public var baselineIQR: [Double]
    public var candidateIQR: [Double]
    public var outcome: CampaignComparison.Outcome
    public var explanation: String
}

public enum ABState: String, Codable, Sendable { case baseline = "Baseline", candidate = "Candidate", validated = "Validated" }

public enum ABVerdict: String, Codable, Sendable {
    case confirmedGain = "Gain confirmé"
    case noGain = "Gain non confirmé"
    case degraded = "Dégradation mesurée"
    case insufficient = "Mesures insuffisantes ou non comparables"
}

public struct ABResult: Codable, Hashable, Sendable {
    public var deltas: [MetricDelta]
    public var baselineCount: Int
    public var candidateCount: Int
    public var comparabilityIssues: [String]
    public var warnings: [String]
    public var stabilityBaselineCV: Double?
    public var stabilityCandidateCV: Double?
    public var verdict: ABVerdict
    public var state: ABState
    public var improved: [BoostMetric]
    public var degraded: [BoostMetric]
    public var tradeoffs: [String]
    public var summary: String
}

/// Compares two sets of comparable measurements and decides whether a change produced a real gain.
public enum PerformanceABTestingService {
    public static func compare(baseline: [BoostSample], candidate: [BoostSample], profile: BoostProfile,
                               tolerance: Double = 0.15, minimumSamples: Int = 3, maxGap: TimeInterval = 3 * 3600) -> ABResult {
        var issues: [String] = []
        var warnings: [String] = []
        let all = baseline + candidate
        if Set(all.compactMap(\.interface)).count > 1 { issues.append("Interfaces différentes entre les mesures (\(Set(all.compactMap(\.interface)).sorted().joined(separator: ", ")))") }
        if Set(all.map(\.target)).count > 1 { issues.append("Cibles de latence différentes") }
        if Set(all.map(\.vpnActive)).count > 1 { issues.append("État VPN différent entre les mesures") }
        if Set(all.compactMap(\.networkName)).count > 1 { issues.append("Réseaux différents") }
        if let b = baseline.map(\.timestamp).min(), let c = candidate.map(\.timestamp).max(), c.timeIntervalSince(b) > maxGap {
            warnings.append("Plus de \(Int(maxGap / 3600)) h entre les mesures : la charge du réseau peut avoir changé")
        }
        let refDL = Stats.median(baseline.compactMap(\.downloadBps)) ?? 0
        let busy = all.filter { ($0.backgroundBps ?? 0) > max(5e6, refDL * 0.1) }
        if !busy.isEmpty { warnings.append("\(busy.count) mesure(s) réalisée(s) pendant un trafic de fond important") }

        var deltas: [MetricDelta] = []
        for m in BoostMetric.allCases {
            let b = baseline.compactMap { $0.value(m) }, c = candidate.compactMap { $0.value(m) }
            guard !b.isEmpty || !c.isEmpty else { continue }
            let r = CampaignComparison.compare(metric: m.label, before: b, after: c, lowerIsBetter: m.lowerIsBetter, minimumSamples: minimumSamples)
            func iqr(_ x: [Double]) -> [Double] { [Stats.percentile(x, 25), Stats.percentile(x, 75)].compactMap { $0 } }
            deltas.append(MetricDelta(metric: m, baselineMedian: r.beforeMedian, candidateMedian: r.afterMedian, relativeChange: r.relativeChange,
                                      baselineIQR: iqr(b), candidateIQR: iqr(c), outcome: r.outcome, explanation: r.explanation))
        }
        let improved = deltas.filter { $0.outcome == .improved }.map(\.metric)
        let degraded = deltas.filter { $0.outcome == .degraded }.map(\.metric)
        let primary = Set(profile.primaryMetrics)
        let pImproved = improved.filter(primary.contains)
        let pDegraded = degraded.filter(primary.contains)
        var tradeoffs: [String] = []
        var guardViolation = false
        for d in deltas where profile.guardMetrics.contains(d.metric) && d.outcome == .degraded {
            let rel = abs(d.relativeChange ?? 0)
            tradeoffs.append(String(format: "%@ : %@ (%.0f %%)", d.metric.label, d.metric.lowerIsBetter ? "en hausse" : "en baisse", rel * 100))
            if rel > tolerance { guardViolation = true }
        }
        if profile == .smartAuto {
            for d in deltas where d.outcome == .degraded { tradeoffs.append("\(d.metric.label) dégradé(e)") }
        }

        let verdict: ABVerdict
        if baseline.count < minimumSamples || candidate.count < minimumSamples || !issues.isEmpty {
            verdict = .insufficient
        } else if !pImproved.isEmpty && pDegraded.isEmpty && !guardViolation {
            verdict = .confirmedGain
        } else if !pDegraded.isEmpty && pImproved.isEmpty {
            verdict = .degraded
        } else {
            verdict = .noGain
        }
        if guardViolation { warnings.append("Le compromis dépasse la tolérance de \(Int(tolerance * 100)) % sur une métrique protégée par le profil") }

        let summary: String
        switch verdict {
        case .confirmedGain: summary = "Amélioration mesurée sur : " + pImproved.map(\.label).joined(separator: ", ") + (tradeoffs.isEmpty ? "." : ". Compromis : " + tradeoffs.joined(separator: " ; ") + ".")
        case .degraded: summary = "Dégradation mesurée sur : " + pDegraded.map(\.label).joined(separator: ", ") + "."
        case .noGain: summary = "Aucun gain distinguable de la variabilité des mesures pour les objectifs du profil."
        case .insufficient: summary = "Comparaison impossible à conclure : " + (issues.isEmpty ? "au moins \(minimumSamples) mesures sont nécessaires de chaque côté." : issues.joined(separator: " ; "))
        }
        return ABResult(deltas: deltas, baselineCount: baseline.count, candidateCount: candidate.count, comparabilityIssues: issues,
                        warnings: warnings, stabilityBaselineCV: Stats.coefficientOfVariation(baseline.compactMap(\.downloadBps)),
                        stabilityCandidateCV: Stats.coefficientOfVariation(candidate.compactMap(\.downloadBps)), verdict: verdict,
                        state: verdict == .confirmedGain ? .validated : .candidate, improved: improved, degraded: degraded,
                        tradeoffs: tradeoffs, summary: summary)
    }
}
