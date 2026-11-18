import Foundation

public struct NATAssessment: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case verified = "Vérifié", suspected = "Suspecté", notDetected = "Non détecté", unknown = "Indéterminé"
    }
    public var cgnat: Status
    public var cgnatEvidence: [String]
    public var doubleNAT: Status
    public var doubleNATEvidence: [String]
    public var implications: [String]
    public var limitations: [String]
}

/// NAT analysis from local data only. It never claims to know a console's NAT type.
public enum NATAnalyzer {
    public static func assess(localIP: String?, gatewayIP: String?, routerWANIP: String?, publicIP: String?,
                              traceroute: [TracerouteHop]) -> NATAssessment {
        var cg: NATAssessment.Status = .unknown, cgEv: [String] = []
        var dn: NATAssessment.Status = .unknown, dnEv: [String] = []

        if let wan = routerWANIP, let v = IPv4.parse(wan) {
            if IPv4.isCGNAT(v) { cg = .verified; cgEv.append("Adresse WAN de la box \(wan) dans 100.64.0.0/10 (plage CGNAT, RFC 6598) — fournie par le routeur") }
            else if IPv4.isPrivate(v) { dn = .verified; dnEv.append("Adresse WAN de la box \(wan) privée (RFC 1918) : un autre équipement NAT se trouve en amont") }
            else if let pub = publicIP, pub != wan { cg = .suspected; cgEv.append("L’IP publique vue de l’extérieur (\(pub)) diffère de l’IP WAN de la box (\(wan))") }
            else if IPv4.isPublic(v) { cg = .notDetected; cgEv.append("Adresse WAN publique \(wan) fournie par le routeur"); if dn == .unknown { dn = .notDetected } }
        }
        // Traceroute: hops after the gateway still in private/CGNAT ranges.
        let afterGateway = traceroute.filter { hop in !hop.addresses.contains(gatewayIP ?? "") }.prefix(3)
        if afterGateway.contains(where: \.isCGNAT), cg == .unknown {
            cg = .suspected; cgEv.append("Un saut proche dans 100.64.0.0/10 apparaît sur le tracé de route")
        }
        if let second = traceroute.first(where: { $0.hop == 2 }), second.isPrivate, dn == .unknown {
            dn = .suspected; dnEv.append("Le 2e saut (\(second.addresses.joined(separator: ", "))) est une adresse privée : routeur supplémentaire probable")
        }
        var impl: [String] = []
        if cg == .verified || cg == .suspected {
            impl.append("Avec un CGNAT, les redirections de ports et l’UPnP de la box ne rendent pas l’appareil joignable depuis Internet ; l’hébergement de parties et certains modes P2P peuvent être limités.")
            impl.append("Option : demander une IPv4 publique (ou full-stack) à l’opérateur, ou utiliser l’IPv6 si le jeu la prend en charge.")
        }
        if dn == .verified || dn == .suspected {
            impl.append("Un double NAT complique la connectivité entrante : passer la box en mode bridge ou placer le second routeur en mode point d’accès.")
        }
        return NATAssessment(cgnat: cg, cgnatEvidence: cgEv, doubleNAT: dn, doubleNATEvidence: dnEv, implications: impl,
                             limitations: ["Le type de NAT affiché par une console (Ouvert/Modéré/Strict, Type 1/2/3) dépend de tests réalisés par la console elle-même : NetScope ne le connaît pas.",
                                           "NetScope ne modifie jamais les redirections de ports et n’active pas l’UPnP."])
    }
}

public struct GamingAssessment: Codable, Hashable, Sendable {
    public struct TargetResult: Codable, Hashable, Sendable {
        public var target: String
        public var method: String
        public var medianMs: Double?
        public var p99Ms: Double?
        public var jitterMs: Double?
        public var lossPercent: Double
        public var spikes: Int
        public var samples: Int
    }
    public enum Suitability: String, Codable, Sendable {
        case excellent = "Excellent", good = "Bon", playable = "Jouable", degraded = "Dégradé", poor = "Mauvais", unknown = "Indéterminé"
    }
    public var targets: [TargetResult]
    public var loadedLatencyAddedMs: Double?
    public var competitive: Suitability
    public var casual: Suitability
    public var risks: [String]
}

public enum GamingAnalyzer {
    public static func assess(_ stats: [LatencyStats], loadedAddedMs: Double?) -> GamingAssessment {
        let tr = stats.map { s in
            GamingAssessment.TargetResult(target: s.target, method: s.method, medianMs: s.medianMs,
                                          p99Ms: Stats.percentile(s.samplesMs, 99), jitterMs: s.jitterMs,
                                          lossPercent: s.lossPercent, spikes: Stats.spikes(s.samplesMs).count, samples: s.sent)
        }
        guard let best = tr.filter({ $0.medianMs != nil }).min(by: { $0.medianMs! < $1.medianMs! }), let med = best.medianMs else {
            return GamingAssessment(targets: tr, loadedLatencyAddedMs: loadedAddedMs, competitive: .unknown, casual: .unknown,
                                    risks: ["Aucune destination n’a répondu"])
        }
        let jit = best.jitterMs ?? 0, loss = best.lossPercent
        func grade(_ latLimits: [Double], _ jitLimits: [Double], _ lossLimits: [Double]) -> GamingAssessment.Suitability {
            func idx(_ v: Double, _ l: [Double]) -> Int { l.firstIndex { v < $0 } ?? l.count }
            let worst = max(idx(med, latLimits), idx(jit, jitLimits), idx(loss, lossLimits))
            return [.excellent, .good, .playable, .degraded, .poor][min(worst, 4)]
        }
        let comp = grade([20, 40, 60, 100], [3, 8, 15, 30], [0.1, 0.5, 1, 3])
        let casual = grade([50, 80, 120, 200], [10, 20, 40, 80], [0.5, 1, 3, 8])
        var risks: [String] = []
        if best.spikes > 0 { risks.append("\(best.spikes) pic(s) de latence détecté(s) (> 2× la médiane et +20 ms)") }
        if loss >= 1 { risks.append(String(format: "Pertes de paquets %.1f %% : téléportations et désynchronisation possibles", loss)) }
        if let l = loadedAddedMs, l >= Thresholds.bloatMild { risks.append("La latence augmente de \(Units.ms(l)) quand le réseau est chargé : un téléchargement simultané dégradera la partie") }
        if risks.isEmpty { risks.append("Aucun risque significatif détecté sur la période mesurée") }
        return GamingAssessment(targets: tr, loadedLatencyAddedMs: loadedAddedMs, competitive: comp, casual: casual, risks: risks)
    }
}
