import Foundation

/// Local, offline explanatory assistant based on the diagnostics engine. It separates
/// observed facts, hypotheses and recommendations, and always cites measurements with timestamps.
public enum LocalAssistant {
    public enum Question: String, CaseIterable, Identifiable, Sendable {
        case slowWiFi = "Pourquoi mon Wi-Fi est-il lent ?"
        case goodSpeedHighPing = "Pourquoi j’ai un bon débit mais un ping élevé ?"
        case speedVariesByHour = "Pourquoi mon débit change-t-il selon l’heure ?"
        case videoCallsDrop = "Pourquoi mes appels vidéo se coupent-ils ?"
        case packetLoss = "Pourquoi ai-je des pertes de paquets ?"
        case whoSaturates = "Quels appareils pourraient être responsables d’une saturation ?"
        case routerLimiting = "Est-ce que mon routeur est le facteur limitant ?"
        case priority = "Que dois-je améliorer en priorité ?"
        public var id: String { rawValue }

        var relevantCauses: [DiagnosticCause] {
            switch self {
            case .slowWiFi: return [.weakSignal, .interference, .saturatedRadio, .wanLimited, .localCongestion, .vpnProxy]
            case .goodSpeedHighPing: return [.bufferbloat, .weakSignal, .interference, .externalProblem, .vpnProxy]
            case .speedVariesByHour: return [.wanLimited, .interference, .saturatedRadio]
            case .videoCallsDrop: return [.bufferbloat, .intermittentDisconnects, .weakSignal, .interference]
            case .packetLoss: return [.weakSignal, .interference, .routerLimited, .externalProblem]
            case .whoSaturates: return [.saturatedRadio, .localCongestion]
            case .routerLimiting: return [.routerLimited, .wanLimited, .bufferbloat]
            case .priority: return DiagnosticCause.allCases
            }
        }

        /// Matches a free-text question to a known intent (keywords, accent-insensitive).
        public static func match(_ text: String) -> Question? {
            let t = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            let table: [(Question, [String])] = [
                (.goodSpeedHighPing, ["ping", "latence", "lag"]),
                (.videoCallsDrop, ["visio", "appel", "teams", "zoom", "facetime", "video"]),
                (.packetLoss, ["perte", "paquet", "loss"]),
                (.speedVariesByHour, ["heure", "soir", "moment", "varie"]),
                (.whoSaturates, ["appareil", "sature", "consomm", "qui"]),
                (.routerLimiting, ["routeur", "box", "limit"]),
                (.priority, ["priorit", "ameliorer", "quoi faire"]),
                (.slowWiFi, ["lent", "wifi", "wi-fi", "debit"]),
            ]
            return table.first { $0.1.contains { t.contains($0) } }?.0
        }
    }

    public struct Answer: Sendable {
        public var question: String
        public var facts: [String]
        public var hypotheses: [Hypothesis]
        public var recommendations: [Recommendation]
        public var caveats: [String]
        public var generatedAt: Date
    }

    public static func answer(_ q: Question, report: DiagnosticReport, extraFacts: [String] = []) -> Answer {
        let hs = report.hypotheses.filter { q.relevantCauses.contains($0.cause) && $0.cause != .insufficientData }
        var recs = hs.flatMap(\.recommendations)
        recs = OptimizationCenter.rank(recs)
        var caveats = report.dataGaps.map { "Donnée manquante : \($0)" }
        if hs.isEmpty { caveats.append("Aucune hypothèse ne ressort des mesures disponibles pour cette question. Lancez le diagnostic complet pour enrichir l’analyse.") }
        if q == .speedVariesByHour { caveats.append("Une variation horaire ne se démontre qu’avec des tests répartis dans la journée (History & Reports → Heures de la journée).") }
        return Answer(question: q.rawValue, facts: report.observedFacts + extraFacts, hypotheses: hs, recommendations: recs,
                      caveats: caveats, generatedAt: report.timestamp)
    }

    /// Structured, timestamped payload that may be sent to an optional AI provider — only with explicit consent,
    /// and after privacy redaction.
    public static func structuredContext(_ report: DiagnosticReport, redactor: PrivacyRedactor) -> [String: Any] {
        [
            "generated_at": ISO8601DateFormatter().string(from: report.timestamp),
            "observed_facts": report.observedFacts.map(redactor.redact),
            "data_gaps": report.dataGaps,
            "hypotheses": report.hypotheses.map { h in
                ["cause": h.cause.rawValue, "confidence": h.confidence.rawValue,
                 "supporting": h.supporting.map(redactor.redact), "contradicting": h.contradicting.map(redactor.redact)] as [String: Any]
            },
        ]
    }
}

public enum OptimizationMode: String, Codable, CaseIterable, Sendable {
    case analysisOnly = "Analyse seule"
    case guided = "Optimisation guidée"
    case assisted = "Actions assistées"

    public var explanation: String {
        switch self {
        case .analysisOnly: return "Aucune modification : NetScope analyse et explique."
        case .guided: return "NetScope explique chaque réglage et vous accompagne ; vous effectuez vous-même les modifications."
        case .assisted: return "Seuls les réglages pris en charge par une API routeur sécurisée peuvent être appliqués, après validation individuelle."
        }
    }
}

public enum OptimizationCenter {
    /// Ranks by expected effectiveness, then lowest risk, then reversibility.
    public static func rank(_ recs: [Recommendation]) -> [Recommendation] {
        var seen = Set<String>()
        return recs.filter { seen.insert($0.id).inserted }.sorted {
            if $0.expectedEffectiveness != $1.expectedEffectiveness { return $0.expectedEffectiveness > $1.expectedEffectiveness }
            if $0.risk != $1.risk { return $0.risk < $1.risk }
            return $0.reversible && !$1.reversible
        }
    }

    public struct Plan: Sendable {
        public var latency: [Recommendation]
        public var stability: [Recommendation]
        public var throughput: [Recommendation]
        public var other: [Recommendation]
    }

    /// Groups recommendations so latency optimization, stability and real throughput increases are never conflated.
    public static func plan(from report: DiagnosticReport) -> Plan {
        let all = rank(report.hypotheses.flatMap(\.recommendations))
        return Plan(latency: all.filter { $0.impact == .latency }, stability: all.filter { $0.impact == .stability },
                    throughput: all.filter { $0.impact == .throughput },
                    other: all.filter { ![.latency, .stability, .throughput].contains($0.impact) })
    }
}
