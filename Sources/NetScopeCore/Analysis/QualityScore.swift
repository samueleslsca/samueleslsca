import Foundation

public struct SubScore: Codable, Hashable, Identifiable, Sendable {
    public enum Dimension: String, Codable, CaseIterable, Sendable {
        case radio = "Qualité radio", internet = "Performance Internet", stability = "Stabilité"
        case latency = "Latence", dns = "DNS", security = "Sécurité et configuration"
    }
    public var id: String { dimension.rawValue }
    public var dimension: Dimension
    public var score: Double?
    public var confidence: Confidence
    public var inputs: [String]
    public var methodology: String
}

public struct QualityScore: Codable, Hashable, Sendable {
    public var global: Double?
    public var confidence: Confidence
    public var subScores: [SubScore]
    public var methodology: String
    public var timestamp: Date
}

public struct ScoringInput: Sendable {
    public var wifi: WiFiSnapshot?
    public var isWired: Bool
    public var rssiHistory: [Double]
    public var latestSpeedTest: SpeedTestResult?
    public var contractedDownBps: Double?
    public var gatewayLatency: LatencyStats?
    public var internetLatency: LatencyStats?
    public var dnsResults: [DNSQueryResult]
    public var disconnectsLast24h: Int?
    public var securityScore: Double?
    public var now: Date

    public init(wifi: WiFiSnapshot? = nil, isWired: Bool = false, rssiHistory: [Double] = [],
                latestSpeedTest: SpeedTestResult? = nil, contractedDownBps: Double? = nil,
                gatewayLatency: LatencyStats? = nil, internetLatency: LatencyStats? = nil,
                dnsResults: [DNSQueryResult] = [], disconnectsLast24h: Int? = nil, securityScore: Double? = nil,
                now: Date = Date()) {
        self.wifi = wifi; self.isWired = isWired; self.rssiHistory = rssiHistory; self.latestSpeedTest = latestSpeedTest
        self.contractedDownBps = contractedDownBps; self.gatewayLatency = gatewayLatency
        self.internetLatency = internetLatency; self.dnsResults = dnsResults
        self.disconnectsLast24h = disconnectsLast24h; self.securityScore = securityScore; self.now = now
    }
}

/// Explainable global quality indicator. Each dimension is scored only from real inputs;
/// a missing dimension is excluded (never assumed good) and lowers the global confidence.
public enum QualityScorer {
    static let weights: [SubScore.Dimension: Double] = [
        .radio: 0.2, .internet: 0.25, .stability: 0.15, .latency: 0.2, .dns: 0.1, .security: 0.1,
    ]

    public static func compute(_ i: ScoringInput) -> QualityScore {
        var subs: [SubScore] = []

        // Radio
        if i.isWired {
            subs.append(SubScore(dimension: .radio, score: 100, confidence: .high,
                                 inputs: ["Connexion filaire active"],
                                 methodology: "Connexion Ethernet : la qualité radio du Mac n’intervient pas."))
        } else if let rssi = i.wifi?.rssi.value {
            let rs = Thresholds.score(Double(rssi), [(-85, 0), (-75, 40), (-67, 70), (-60, 90), (-50, 100)])
            var inputs = ["RSSI \(rssi) dBm"]
            var s = rs
            var conf: Confidence = .medium
            if let snr = i.wifi?.snr.value {
                let ss = Thresholds.score(Double(snr), [(5, 0), (15, 40), (25, 70), (40, 100)])
                s = (rs + ss) / 2; inputs.append("SNR \(snr) dB"); conf = .high
            }
            subs.append(SubScore(dimension: .radio, score: s, confidence: conf, inputs: inputs,
                                 methodology: "Moyenne des notes RSSI (−85→0, −75→40, −67→70, −60→90, −50→100) et SNR (5→0, 15→40, 25→70, 40→100) quand le bruit est disponible."))
        } else {
            subs.append(SubScore(dimension: .radio, score: nil, confidence: .none, inputs: [],
                                 methodology: "Mesure radio indisponible."))
        }

        // Internet performance
        if let t = i.latestSpeedTest, let dl = t.downloadBps {
            let ageH = i.now.timeIntervalSince(t.timestamp) / 3600
            var s: Double
            var inputs = ["Descendant \(Units.bitRate(dl))"]
            var method: String
            if let c = i.contractedDownBps, c > 0 {
                s = Thresholds.score(dl / c, [(0.1, 0), (0.3, 35), (0.5, 60), (0.8, 90), (0.95, 100)])
                inputs.append("Offre déclarée \(Units.bitRate(c))")
                method = "Rapport débit mesuré / débit de l’offre déclarée (10 %→0, 50 %→60, 80 %→90, 95 %→100)."
            } else {
                s = Thresholds.score(dl / 1e6, [(1, 0), (10, 40), (50, 70), (200, 90), (500, 100)])
                method = "Sans offre déclarée : échelle absolue (1→0, 10→40, 50→70, 200→90, 500 Mbit/s→100)."
            }
            if let ul = t.uploadBps {
                let us = Thresholds.score(ul / 1e6, [(0.5, 0), (5, 50), (20, 80), (100, 100)])
                s = s * 0.75 + us * 0.25; inputs.append("Montant \(Units.bitRate(ul))")
                method += " Montant pondéré à 25 %."
            }
            let conf: Confidence = ageH < 24 ? .medium : .low
            subs.append(SubScore(dimension: .internet, score: s, confidence: conf, inputs: inputs + ["Test du \(t.timestamp.formatted(date: .abbreviated, time: .shortened))"],
                                 methodology: method + " Un seul test : confiance au plus moyenne."))
        } else {
            subs.append(SubScore(dimension: .internet, score: nil, confidence: .none, inputs: [],
                                 methodology: "Aucun test de débit disponible."))
        }

        // Latency (idle + loaded)
        var latParts: [(Double, String)] = []
        if let g = i.gatewayLatency, let m = g.medianMs {
            let lim = i.isWired ? Thresholds.gatewayLatencyHighWired : Thresholds.gatewayLatencyHighWiFi
            latParts.append((Thresholds.score(m, [(1, 100), (lim, 70), (lim * 3, 30), (lim * 10, 0)]), "Passerelle \(Units.ms(m))"))
        }
        if let e = i.internetLatency, let m = e.medianMs {
            latParts.append((Thresholds.score(m, [(10, 100), (30, 85), (80, 55), (150, 25), (300, 0)]), "Internet \(Units.ms(m))"))
        }
        if let t = i.latestSpeedTest, let idle = t.idleLatencyMs, let loaded = t.worstLoadedLatencyMs {
            let added = max(0, loaded - idle)
            latParts.append((Thresholds.score(added, [(5, 100), (30, 80), (60, 60), (200, 25), (400, 0)]), "Latence ajoutée sous charge \(Units.ms(added))"))
        }
        if latParts.isEmpty {
            subs.append(SubScore(dimension: .latency, score: nil, confidence: .none, inputs: [], methodology: "Aucune mesure de latence."))
        } else {
            subs.append(SubScore(dimension: .latency, score: latParts.map(\.0).reduce(0, +) / Double(latParts.count),
                                 confidence: latParts.count >= 2 ? .high : .medium, inputs: latParts.map(\.1),
                                 methodology: "Moyenne des notes : latence passerelle, latence Internet et latence ajoutée sous charge (bufferbloat)."))
        }

        // Stability
        var stabParts: [(Double, String)] = []
        let allLoss = [i.gatewayLatency, i.internetLatency].compactMap { $0 }
        if !allLoss.isEmpty {
            let worst = allLoss.map(\.lossPercent).max() ?? 0
            stabParts.append((Thresholds.score(worst, [(0, 100), (1, 75), (5, 30), (20, 0)]), String(format: "Pertes %.1f %%", worst)))
            if let j = allLoss.compactMap(\.jitterMs).max() {
                stabParts.append((Thresholds.score(j, [(2, 100), (10, 80), (30, 45), (100, 0)]), "Gigue \(Units.ms(j))"))
            }
        }
        if let d = i.disconnectsLast24h {
            stabParts.append((Thresholds.score(Double(d), [(0, 100), (1, 80), (3, 45), (10, 0)]), "\(d) déconnexion(s) sur 24 h"))
        }
        if !i.isWired, let sd = Stats.standardDeviation(i.rssiHistory), i.rssiHistory.count >= 10 {
            stabParts.append((Thresholds.score(sd, [(1, 100), (3, 85), (6, 55), (12, 15)]), String(format: "Variabilité RSSI σ=%.1f dB", sd)))
        }
        if stabParts.isEmpty {
            subs.append(SubScore(dimension: .stability, score: nil, confidence: .none, inputs: [], methodology: "Données de stabilité insuffisantes."))
        } else {
            subs.append(SubScore(dimension: .stability, score: stabParts.map(\.0).reduce(0, +) / Double(stabParts.count),
                                 confidence: stabParts.count >= 3 ? .high : (stabParts.count == 2 ? .medium : .low),
                                 inputs: stabParts.map(\.1),
                                 methodology: "Moyenne des notes : pertes de paquets, gigue, déconnexions observées et variabilité du signal."))
        }

        // DNS
        if !i.dnsResults.isEmpty {
            let ok = i.dnsResults.filter(\.success)
            let failRate = 1 - Double(ok.count) / Double(i.dnsResults.count)
            let med = Stats.median(ok.compactMap(\.durationMs))
            var s = Thresholds.score(failRate, [(0, 100), (0.05, 60), (0.2, 10), (0.5, 0)])
            var inputs = [String(format: "Échecs %.0f %%", failRate * 100)]
            if let m = med {
                s = (s + Thresholds.score(m, [(10, 100), (50, 85), (100, 60), (300, 20), (1000, 0)])) / 2
                inputs.append("Médiane \(Units.ms(m))")
            }
            subs.append(SubScore(dimension: .dns, score: s, confidence: i.dnsResults.count >= 5 ? .high : .medium, inputs: inputs,
                                 methodology: "Taux d’échec et temps de réponse médian des requêtes DNS envoyées aux résolveurs configurés."))
        } else {
            subs.append(SubScore(dimension: .dns, score: nil, confidence: .none, inputs: [], methodology: "Aucun test DNS."))
        }

        // Security
        if let sec = i.securityScore {
            subs.append(SubScore(dimension: .security, score: sec, confidence: .medium, inputs: ["Audit Security Center"],
                                 methodology: "Proportion des contrôles vérifiés conformes dans le Security Center."))
        } else {
            subs.append(SubScore(dimension: .security, score: nil, confidence: .none, inputs: [], methodology: "Audit de sécurité non réalisé."))
        }

        let available = subs.filter { $0.score != nil }
        let totalWeight = available.reduce(0) { $0 + (weights[$1.dimension] ?? 0) }
        let global: Double? = totalWeight > 0
            ? available.reduce(0) { $0 + ($1.score ?? 0) * (weights[$1.dimension] ?? 0) } / totalWeight : nil
        let coverage = totalWeight
        let conf: Confidence
        if global == nil { conf = .none }
        else if coverage >= 0.8 && available.allSatisfy({ $0.confidence >= .medium }) { conf = .high }
        else if coverage >= 0.5 { conf = .medium }
        else { conf = .low }

        return QualityScore(global: global, confidence: conf, subScores: subs,
                            methodology: "Moyenne pondérée des sous-scores disponibles (radio 20 %, Internet 25 %, stabilité 15 %, latence 20 %, DNS 10 %, sécurité 10 %). Les dimensions sans mesure sont exclues et réduisent la confiance ; elles ne sont jamais supposées bonnes.",
                            timestamp: i.now)
    }
}
