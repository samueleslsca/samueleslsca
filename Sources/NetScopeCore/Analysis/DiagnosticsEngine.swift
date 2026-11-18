import Foundation

public enum RiskLevel: String, Codable, Comparable, Sendable {
    case none = "Aucun", low = "Faible", medium = "Modéré", high = "Élevé"
    private var rank: Int { switch self { case .none: return 0; case .low: return 1; case .medium: return 2; case .high: return 3 } }
    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rank < b.rank }
}

public enum ImpactKind: String, Codable, Sendable {
    case latency = "Latence", stability = "Stabilité", throughput = "Débit réel", security = "Sécurité", diagnosis = "Diagnostic"
}

public struct Recommendation: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var impact: ImpactKind
    public var expectedEffectiveness: Confidence
    public var risk: RiskLevel
    public var reversible: Bool
    public var cost: String
    /// True only when NetScope can perform it via a supported, confirmed API action.
    public var assistedActionAvailable: Bool

    public init(id: String, title: String, detail: String, impact: ImpactKind, expectedEffectiveness: Confidence,
                risk: RiskLevel, reversible: Bool, cost: String = "Gratuit", assistedActionAvailable: Bool = false) {
        self.id = id; self.title = title; self.detail = detail; self.impact = impact
        self.expectedEffectiveness = expectedEffectiveness; self.risk = risk; self.reversible = reversible
        self.cost = cost; self.assistedActionAvailable = assistedActionAvailable
    }
}

public enum DiagnosticCause: String, Codable, CaseIterable, Sendable {
    case weakSignal = "Signal Wi-Fi insuffisant"
    case interference = "Interférences possibles"
    case saturatedRadio = "Réseau radio saturé"
    case routerLimited = "Routeur ou point d’accès limitant"
    case wanLimited = "Débit WAN potentiellement limité"
    case dnsProblem = "Problème DNS"
    case bufferbloat = "Latence élevée sous charge"
    case vpnProxy = "VPN ou proxy perturbateur"
    case localCongestion = "Congestion locale"
    case intermittentDisconnects = "Déconnexions intermittentes"
    case externalProblem = "Problème extérieur au réseau local"
    case localConfig = "Configuration locale incomplète"
    case ethernetNegotiation = "Négociation Ethernet dégradée"
    case insufficientData = "Données insuffisantes"
}

public struct Hypothesis: Codable, Hashable, Identifiable, Sendable {
    public var id: String { cause.rawValue }
    public var cause: DiagnosticCause
    public var symptoms: [String]
    public var supporting: [String]
    public var contradicting: [String]
    public var confidence: Confidence
    public var nextChecks: [String]
    public var recommendations: [Recommendation]
}

/// Everything the engine may use. Each field is optional: rules only fire on data actually available.
public struct DiagnosticInput: Sendable {
    public var now: Date
    public var connection: ConnectionSnapshot?
    public var wifi: WiFiSnapshot?
    public var rssiHistory: [Double]
    public var bssidChanges24h: Int
    public var neighbors: [WiFiNeighbor]
    public var gatewayLatency: LatencyStats?
    public var gatewayLatencyUnderLoad: LatencyStats?
    public var externalLatency: [LatencyStats]
    public var dnsResults: [DNSQueryResult]
    public var speedTests: [SpeedTestResult]
    public var lanThroughputBps: Double?
    public var events24h: [NetworkEvent]
    public var traceroute: [TracerouteHop]
    public var wan: WANStatus?
    public var routerClients: [RouterClient]
    public var contractedDownBps: Double?
    public var contractedUpBps: Double?
    public var backgroundTrafficBps: Double?

    public init(now: Date = Date(), connection: ConnectionSnapshot? = nil, wifi: WiFiSnapshot? = nil,
                rssiHistory: [Double] = [], bssidChanges24h: Int = 0, neighbors: [WiFiNeighbor] = [],
                gatewayLatency: LatencyStats? = nil, gatewayLatencyUnderLoad: LatencyStats? = nil,
                externalLatency: [LatencyStats] = [], dnsResults: [DNSQueryResult] = [],
                speedTests: [SpeedTestResult] = [], lanThroughputBps: Double? = nil, events24h: [NetworkEvent] = [],
                traceroute: [TracerouteHop] = [], wan: WANStatus? = nil, routerClients: [RouterClient] = [],
                contractedDownBps: Double? = nil, contractedUpBps: Double? = nil, backgroundTrafficBps: Double? = nil) {
        self.now = now; self.connection = connection; self.wifi = wifi; self.rssiHistory = rssiHistory
        self.bssidChanges24h = bssidChanges24h; self.neighbors = neighbors; self.gatewayLatency = gatewayLatency
        self.gatewayLatencyUnderLoad = gatewayLatencyUnderLoad; self.externalLatency = externalLatency
        self.dnsResults = dnsResults; self.speedTests = speedTests; self.lanThroughputBps = lanThroughputBps
        self.events24h = events24h; self.traceroute = traceroute; self.wan = wan; self.routerClients = routerClients
        self.contractedDownBps = contractedDownBps; self.contractedUpBps = contractedUpBps
        self.backgroundTrafficBps = backgroundTrafficBps
    }

    var isWired: Bool { connection?.primaryInterface?.kind == .ethernet }
    var isWiFi: Bool { connection?.primaryInterface?.kind == .wifi || (connection == nil && wifi?.rssi.value != nil) }
    var latestTest: SpeedTestResult? { speedTests.filter(\.succeeded).max { $0.timestamp < $1.timestamp } }
}

public struct DiagnosticReport: Codable, Hashable, Sendable {
    public var timestamp: Date
    public var hypotheses: [Hypothesis]
    public var observedFacts: [String]
    public var dataGaps: [String]
}

/// Rule-based correlation engine. Distinguishes observed facts, hypotheses and recommendations,
/// and never concludes to a precise ISP fault without evidence.
public enum DiagnosticsEngine {
    public static func analyze(_ i: DiagnosticInput) -> DiagnosticReport {
        var facts: [String] = []
        var gaps: [String] = []
        collectFacts(i, &facts, &gaps)

        var hs: [Hypothesis] = []
        let rules: [(DiagnosticInput) -> Hypothesis?] = [
            localConfig, weakSignal, interference, saturatedRadio, bufferbloat, wanLimited, routerLimited,
            dnsProblem, vpnProxy, localCongestion, intermittent, externalProblem, ethernetNegotiation,
        ]
        for r in rules { if let h = r(i) { hs.append(h) } }
        hs.sort { $0.confidence > $1.confidence }
        if hs.isEmpty || gaps.count >= 4 {
            hs.append(Hypothesis(cause: .insufficientData, symptoms: [],
                                 supporting: gaps, contradicting: [],
                                 confidence: gaps.count >= 4 ? .high : .medium,
                                 nextChecks: ["Lancer le diagnostic complet (étapes 1 à 6)", "Lancer au moins trois tests de débit à des moments différents"],
                                 recommendations: []))
        }
        return DiagnosticReport(timestamp: i.now, hypotheses: hs, observedFacts: facts, dataGaps: gaps)
    }

    static func collectFacts(_ i: DiagnosticInput, _ facts: inout [String], _ gaps: inout [String]) {
        if let c = i.connection {
            facts.append("Interface principale : \(c.primaryInterface.map { "\($0.bsdName) (\($0.kind.label))" } ?? "aucune")")
            if let g = c.defaultGatewayIPv4 { facts.append("Passerelle IPv4 : \(g)") }
            if c.vpnActive { facts.append("VPN actif : \(c.vpnInterfaces.joined(separator: ", "))") }
        } else { gaps.append("État de connexion inconnu") }
        if i.isWiFi {
            if let r = i.wifi?.rssi.value { facts.append("RSSI : \(r) dBm") } else { gaps.append("RSSI indisponible") }
            if let s = i.wifi?.snr.value { facts.append("SNR : \(s) dB") }
        }
        if let g = i.gatewayLatency, let m = g.medianMs {
            facts.append("Latence passerelle médiane : \(Units.ms(m)), pertes \(String(format: "%.1f", g.lossPercent)) %")
        } else { gaps.append("Latence vers la passerelle non mesurée") }
        if i.externalLatency.isEmpty { gaps.append("Latence Internet non mesurée") }
        for e in i.externalLatency {
            facts.append("Latence vers \(e.target) : \(Units.ms(e.medianMs)), pertes \(String(format: "%.1f", e.lossPercent)) %")
        }
        if let t = i.latestTest {
            facts.append("Dernier test : ↓ \(t.downloadBps.map(Units.bitRate) ?? "—") / ↑ \(t.uploadBps.map(Units.bitRate) ?? "—") (\(t.engine.rawValue))")
        } else { gaps.append("Aucun test de débit") }
        if i.dnsResults.isEmpty { gaps.append("DNS non testé") }
        if i.wan == nil { gaps.append("Données WAN du routeur indisponibles (aucune intégration routeur active)") }
    }

    // MARK: Rules

    static func localConfig(_ i: DiagnosticInput) -> Hypothesis? {
        guard let c = i.connection else { return nil }
        var sup: [String] = []
        if !c.isConnected { sup.append("Aucune interface réseau active") }
        if c.isConnected && c.defaultGatewayIPv4 == nil && c.defaultGatewayIPv6 == nil { sup.append("Aucune passerelle par défaut") }
        if let ip = c.primaryInterface?.ipv4.first?.address, let v = IPv4.parse(ip), IPv4.isLinkLocal(v) {
            sup.append("Adresse auto-attribuée \(ip) (169.254.x.x) : le DHCP n’a pas répondu")
        }
        if c.isConnected && (c.dns?.primaryNameservers.isEmpty ?? true) { sup.append("Aucun serveur DNS configuré") }
        guard !sup.isEmpty else { return nil }
        return Hypothesis(cause: .localConfig, symptoms: ["Connectivité absente ou partielle"], supporting: sup, contradicting: [],
                          confidence: .high,
                          nextChecks: ["Vérifier le câble ou la connexion Wi-Fi", "Renouveler le bail DHCP dans Réglages Système → Réseau"],
                          recommendations: [Recommendation(id: "renew-dhcp", title: "Renouveler le bail DHCP",
                                                           detail: "Réglages Système → Réseau → interface → Détails → TCP/IP → Renouveler le bail DHCP.",
                                                           impact: .stability, expectedEffectiveness: .medium, risk: .low, reversible: true)])
    }

    static func weakSignal(_ i: DiagnosticInput) -> Hypothesis? {
        guard i.isWiFi, let rssi = i.wifi?.rssi.value else { return nil }
        let snr = i.wifi?.snr.value
        let weak = rssi < Thresholds.rssiGood || (snr.map { $0 < Thresholds.snrGood } ?? false)
        guard weak else { return nil }
        var sup = ["RSSI \(rssi) dBm (seuil « bon » : \(Thresholds.rssiGood) dBm)"]
        var con: [String] = []
        if let s = snr {
            if s < Thresholds.snrGood { sup.append("SNR \(s) dB (seuil « bon » : \(Thresholds.snrGood) dB)") }
            else { con.append("SNR correct (\(s) dB)") }
        }
        if let tx = i.wifi?.txRateMbps.value { sup.append(String(format: "Débit de liaison négocié %.0f Mbit/s", tx)) }
        if let g = i.gatewayLatency, g.lossPercent >= Thresholds.lossConcerning { sup.append(String(format: "Pertes vers la passerelle %.1f %%", g.lossPercent)) }
        else if let g = i.gatewayLatency { con.append(String(format: "Aucune perte significative vers la passerelle (%.1f %%)", g.lossPercent)) }
        let conf: Confidence = rssi < Thresholds.rssiFair ? .high : (con.isEmpty ? .medium : .low)
        var recs = [
            Recommendation(id: "move-closer", title: "Rapprocher le Mac du point d’accès ou dégager l’obstacle",
                           detail: "Mesurez à nouveau à 2–3 emplacements (Wi-Fi Heatmap) pour objectiver le gain.",
                           impact: .throughput, expectedEffectiveness: .high, risk: .none, reversible: true),
            Recommendation(id: "router-placement", title: "Placer le routeur en hauteur, au centre, hors meuble",
                           detail: "Éviter les placards, l’arrière d’une TV, les murs porteurs et les aquariums.",
                           impact: .throughput, expectedEffectiveness: .medium, risk: .none, reversible: true),
            Recommendation(id: "use-ethernet", title: "Tester en Ethernet pour comparaison",
                           detail: "Un test filaire permet de séparer la limite radio de la limite WAN.",
                           impact: .diagnosis, expectedEffectiveness: .high, risk: .none, reversible: true, cost: "Câble RJ45"),
        ]
        if rssi < Thresholds.rssiFair {
            recs.append(Recommendation(id: "add-ap", title: "Envisager un point d’accès filaire ou un système mesh",
                                       detail: "Si plusieurs pièces sont sous −75 dBm, un point d’accès raccordé en Ethernet est plus efficace qu’un répéteur.",
                                       impact: .throughput, expectedEffectiveness: .medium, risk: .low, reversible: true, cost: "Matériel (≈ 50–300 €)"))
        }
        return Hypothesis(cause: .weakSignal, symptoms: ["Signal radio faible au poste de travail"], supporting: sup, contradicting: con,
                          confidence: conf, nextChecks: ["Comparer avec une mesure à 1–2 m du routeur", "Comparer avec un test Ethernet"],
                          recommendations: recs)
    }

    static func overlapping(_ a: Int, _ b: Int, band: WiFiBand) -> Bool {
        band == .ghz2_4 ? abs(a - b) < 5 : a == b
    }

    static func interference(_ i: DiagnosticInput) -> Hypothesis? {
        guard i.isWiFi, let ch = i.wifi?.channel.value, !i.neighbors.isEmpty else { return nil }
        let band = i.wifi?.band.value ?? WiFiBand.inferred(fromChannel: ch)
        let myBSSID = i.wifi?.bssid.value
        let strongCoChannel = i.neighbors.filter {
            $0.bssid != myBSSID && $0.band == band && overlapping($0.channel, ch, band: band) && $0.rssi > -80
        }
        guard strongCoChannel.count >= (band == .ghz2_4 ? 4 : 3) else { return nil }
        var sup = ["\(strongCoChannel.count) réseau(x) voisin(s) audible(s) (> −80 dBm) sur des canaux qui chevauchent le canal \(ch)"]
        var con: [String] = []
        if let n = i.wifi?.noise.value, n > -85 { sup.append("Bruit élevé : \(n) dBm") }
        else if let n = i.wifi?.noise.value { con.append("Plancher de bruit bas (\(n) dBm)") }
        if let snr = i.wifi?.snr.value, snr >= Thresholds.snrExcellent { con.append("SNR excellent (\(snr) dB)") }
        let conf: Confidence = con.isEmpty ? .medium : .low
        var recs: [Recommendation] = []
        if let best = ChannelAdvisor.recommend(band: band, neighbors: i.neighbors, excludingBSSID: myBSSID, current: ch) , best.channel != ch {
            recs.append(Recommendation(id: "change-channel", title: "Essayer le canal \(best.channel) sur la box",
                                       detail: best.rationale + " Le changement de canal se fait dans l’interface de la box ; mesurez avant/après.",
                                       impact: .stability, expectedEffectiveness: .medium, risk: .low, reversible: true))
        }
        if band == .ghz2_4 {
            recs.append(Recommendation(id: "use-5ghz", title: "Privilégier le 5 GHz (ou 6 GHz) si le signal le permet",
                                       detail: "La bande 2,4 GHz n’offre que 3 canaux sans chevauchement (1, 6, 11) et est très encombrée en habitat dense.",
                                       impact: .throughput, expectedEffectiveness: .medium, risk: .low, reversible: true))
        }
        return Hypothesis(cause: .interference, symptoms: ["Canal partagé avec de nombreux réseaux voisins"], supporting: sup, contradicting: con,
                          confidence: conf, nextChecks: ["Répéter le scan à différentes heures", "Mesurer la gigue vers la passerelle"],
                          recommendations: recs)
    }

    static func saturatedRadio(_ i: DiagnosticInput) -> Hypothesis? {
        let wifiClients = i.routerClients.filter { $0.link == .wifi && $0.active == true }
        let heavy = wifiClients.filter { (($0.rxBytesPerSecond ?? 0) + ($0.txBytesPerSecond ?? 0)) * 8 > 20e6 }
        guard wifiClients.count >= 15 || !heavy.isEmpty else { return nil }
        var sup = ["\(wifiClients.count) client(s) Wi-Fi actifs déclarés par le routeur"]
        if !heavy.isEmpty { sup.append("\(heavy.count) client(s) dépassant 20 Mbit/s : " + heavy.prefix(3).compactMap(\.name).joined(separator: ", ")) }
        return Hypothesis(cause: .saturatedRadio, symptoms: ["Temps d’antenne partagé entre de nombreux clients"], supporting: sup, contradicting: [],
                          confidence: heavy.isEmpty ? .low : .medium,
                          nextChecks: ["Identifier les transferts en cours (Traffic Monitor, données routeur)", "Refaire un test quand le réseau est calme"],
                          recommendations: [Recommendation(id: "move-heavy-wired", title: "Raccorder en Ethernet les appareils fixes gourmands",
                                                           detail: "TV, consoles et ordinateurs fixes libèrent du temps d’antenne pour les appareils mobiles.",
                                                           impact: .throughput, expectedEffectiveness: .medium, risk: .none, reversible: true)])
    }

    static func bufferbloat(_ i: DiagnosticInput) -> Hypothesis? {
        let tests = i.speedTests.filter { $0.idleLatencyMs != nil && $0.worstLoadedLatencyMs != nil }
        guard !tests.isEmpty else { return nil }
        let added = tests.compactMap { t in t.worstLoadedLatencyMs.flatMap { l in t.idleLatencyMs.map { max(0, l - $0) } } }
        guard let med = Stats.median(added), med >= Thresholds.bloatMild else { return nil }
        var sup = ["Latence ajoutée sous charge médiane : \(Units.ms(med)) sur \(added.count) test(s)"]
        if let g = i.gatewayLatencyUnderLoad?.medianMs, let gi = i.gatewayLatency?.medianMs, g - gi > 30 {
            sup.append("La latence vers la passerelle augmente aussi sous charge (\(Units.ms(gi)) → \(Units.ms(g))) : file d’attente locale (routeur ou Wi-Fi)")
        }
        let conf: Confidence = added.count >= 3 ? (med >= Thresholds.bloatModerate ? .high : .medium) : .low
        return Hypothesis(cause: .bufferbloat, symptoms: ["Le ping augmente fortement pendant les transferts"], supporting: sup,
                          contradicting: added.count < 3 ? ["Moins de 3 tests : résultat à confirmer"] : [],
                          confidence: conf,
                          nextChecks: ["Lancer le Bufferbloat & QoS Lab (3 essais minimum)", "Comparer Wi-Fi et Ethernet pour localiser la file d’attente"],
                          recommendations: [
                            Recommendation(id: "enable-sqm", title: "Activer la QoS/SQM (fq_codel, CAKE) si la box la propose",
                                           detail: "Régler la limite légèrement sous le débit réel (≈ 90–95 %). À valider par une mesure comparative avant/après.",
                                           impact: .latency, expectedEffectiveness: .high, risk: .low, reversible: true),
                            Recommendation(id: "limit-heavy-transfers", title: "Planifier les gros transferts (sauvegardes cloud, mises à jour)",
                                           detail: "Les envois massifs saturent le lien montant et dégradent la visio et les jeux.",
                                           impact: .latency, expectedEffectiveness: .medium, risk: .none, reversible: true),
                          ])
    }

    static func wanLimited(_ i: DiagnosticInput) -> Hypothesis? {
        guard let t = i.latestTest, let dl = t.downloadBps else { return nil }
        var sup: [String] = []
        var con: [String] = []
        var conf: Confidence = .none
        if let sync = i.wan?.syncDownBps, sync > 0 {
            if dl >= sync * Thresholds.wanSaturationRatio {
                sup.append("Débit mesuré \(Units.bitRate(dl)) ≥ \(Int(Thresholds.wanSaturationRatio * 100)) % du débit de synchronisation WAN (\(Units.bitRate(sync)), fourni par le routeur)")
                conf = .high
            } else { con.append("Débit mesuré nettement inférieur à la synchronisation WAN (\(Units.bitRate(sync)))") }
        }
        if let c = i.contractedDownBps, c > 0 {
            if dl < c * Thresholds.underperformRatio {
                sup.append("Débit mesuré \(Units.bitRate(dl)) < 50 % de l’offre déclarée (\(Units.bitRate(c)))")
                if conf == .none { conf = .low }
            } else if dl >= c * 0.8 { con.append("Le débit atteint au moins 80 % de l’offre déclarée") }
        }
        if let lan = i.lanThroughputBps, lan > dl * 2 { sup.append("Le débit LAN (\(Units.bitRate(lan))) dépasse largement le débit Internet : le réseau local n’est pas le facteur limitant") ; if conf < .medium { conf = .medium } }
        if i.isWiFi, let tx = i.wifi?.txRateMbps.value, tx * 1e6 * 0.6 < dl * 1.1 { con.append(String(format: "Le débit de liaison Wi-Fi (%.0f Mbit/s) peut à lui seul limiter le résultat", tx)) ; conf = min(conf, .low) }
        guard !sup.isEmpty, conf > .none else { return nil }
        return Hypothesis(cause: .wanLimited, symptoms: ["Le débit plafonne au niveau de l’accès Internet"], supporting: sup, contradicting: con,
                          confidence: conf,
                          nextChecks: ["Tester en Ethernet directement sur la box", "Répéter aux heures creuses (matin) et de pointe (20h–23h)", "Remplir l’ISP Performance Audit"],
                          recommendations: [Recommendation(id: "isp-report", title: "Documenter avec le rapport opérateur",
                                                           detail: "Des tests Ethernet répétés et horodatés constituent un dossier exploitable auprès de l’opérateur. NetScope ne conclut pas à une panne opérateur sans ces preuves.",
                                                           impact: .diagnosis, expectedEffectiveness: .medium, risk: .none, reversible: true)])
    }

    static func routerLimited(_ i: DiagnosticInput) -> Hypothesis? {
        var sup: [String] = []
        if i.isWired, let g = i.gatewayLatency?.medianMs, g > Thresholds.gatewayLatencyHighWired * 2 {
            sup.append("Latence passerelle élevée en filaire : \(Units.ms(g))")
        }
        if let lan = i.lanThroughputBps, i.isWired, lan < 300e6 {
            sup.append("Débit LAN filaire mesuré par iperf3 limité à \(Units.bitRate(lan))")
        }
        if let g = i.gatewayLatency, i.isWired, g.lossPercent >= Thresholds.lossConcerning {
            sup.append(String(format: "Pertes vers la passerelle en filaire : %.1f %%", g.lossPercent))
        }
        guard !sup.isEmpty else { return nil }
        return Hypothesis(cause: .routerLimited, symptoms: ["Le routeur répond lentement même sans liaison radio"], supporting: sup,
                          contradicting: [], confidence: sup.count >= 2 ? .medium : .low,
                          nextChecks: ["Redémarrer le routeur puis refaire la mesure", "Vérifier la charge du routeur (nombre de clients, transferts)"],
                          recommendations: [Recommendation(id: "router-firmware", title: "Vérifier la version du firmware du routeur",
                                                           detail: "Mettre à jour via l’interface officielle de la box.", impact: .stability,
                                                           expectedEffectiveness: .low, risk: .low, reversible: false)])
    }

    static func dnsProblem(_ i: DiagnosticInput) -> Hypothesis? {
        guard i.dnsResults.count >= 3 else { return nil }
        let ok = i.dnsResults.filter(\.success)
        let failRate = 1 - Double(ok.count) / Double(i.dnsResults.count)
        let med = Stats.median(ok.compactMap(\.durationMs))
        var sup: [String] = []
        if failRate >= Thresholds.dnsFailureRate { sup.append(String(format: "%.0f %% de requêtes DNS en échec", failRate * 100)) }
        if let m = med, m >= Thresholds.dnsSlow { sup.append("Temps de réponse médian \(Units.ms(m))") }
        guard !sup.isEmpty else { return nil }
        let byResolver = Dictionary(grouping: i.dnsResults, by: \.resolver)
        let failing = byResolver.filter { $0.value.allSatisfy { !$0.success } }.map(\.key)
        if !failing.isEmpty { sup.append("Résolveur(s) sans réponse : \(failing.joined(separator: ", "))") }
        let externalOK = i.externalLatency.contains { $0.received > 0 }
        return Hypothesis(cause: .dnsProblem, symptoms: ["Ouverture lente des sites, erreurs de résolution"], supporting: sup,
                          contradicting: externalOK ? [] : ["La connectivité Internet elle-même semble dégradée"],
                          confidence: failRate >= 0.2 || (med ?? 0) >= Thresholds.dnsVerySlow ? .high : .medium,
                          nextChecks: ["Lancer le DNS Benchmark (comparaison contrôlée, sur demande)"],
                          recommendations: [Recommendation(id: "dns-change", title: "Évaluer un autre résolveur DNS",
                                                           detail: "NetScope ne modifie jamais vos DNS. Si le benchmark montre un gain net et répétable, modifiez-les vous-même dans Réglages Système → Réseau → DNS (réversible).",
                                                           impact: .latency, expectedEffectiveness: .medium, risk: .low, reversible: true)])
    }

    static func vpnProxy(_ i: DiagnosticInput) -> Hypothesis? {
        guard let c = i.connection, c.vpnActive || (c.proxy?.isActive ?? false) else { return nil }
        var sup: [String] = []
        if c.vpnActive { sup.append("Tunnel actif : \(c.vpnInterfaces.joined(separator: ", "))") }
        if let p = c.proxy, p.isActive { sup.append("Proxy configuré : \(p.enabled.map(\.rawValue).joined(separator: ", "))") }
        let withVPN = i.speedTests.filter { $0.vpnActive && $0.downloadBps != nil }.compactMap(\.downloadBps)
        let without = i.speedTests.filter { !$0.vpnActive && $0.downloadBps != nil }.compactMap(\.downloadBps)
        var conf: Confidence = .low
        var con: [String] = []
        if let a = Stats.median(withVPN), let b = Stats.median(without) {
            if a < b * 0.7 { sup.append("Débit médian avec VPN \(Units.bitRate(a)) contre \(Units.bitRate(b)) sans"); conf = .medium }
            else { con.append("Débit comparable avec et sans VPN") }
        }
        return Hypothesis(cause: .vpnProxy, symptoms: ["Les mesures transitent par un tunnel ou un proxy"], supporting: sup, contradicting: con,
                          confidence: conf, nextChecks: ["Comparer un test avec et sans VPN (en le désactivant vous-même)"],
                          recommendations: [Recommendation(id: "vpn-server", title: "Choisir un serveur VPN plus proche ou un autre protocole",
                                                           detail: "WireGuard est généralement plus léger qu’OpenVPN. NetScope ne modifie pas la configuration VPN.",
                                                           impact: .throughput, expectedEffectiveness: .medium, risk: .low, reversible: true)])
    }

    static func localCongestion(_ i: DiagnosticInput) -> Hypothesis? {
        guard let bg = i.backgroundTrafficBps, bg > 10e6 else { return nil }
        return Hypothesis(cause: .localCongestion, symptoms: ["Trafic important sur le Mac pendant la mesure"],
                          supporting: ["Trafic de fond mesuré sur l’interface : \(Units.bitRate(bg))"], contradicting: [],
                          confidence: .medium, nextChecks: ["Identifier les processus dans Traffic Monitor", "Refaire le test une fois les transferts terminés"],
                          recommendations: [Recommendation(id: "pause-sync", title: "Mettre en pause synchronisations et téléchargements",
                                                           detail: "iCloud, Dropbox, mises à jour et sauvegardes faussent les mesures de débit.",
                                                           impact: .throughput, expectedEffectiveness: .medium, risk: .none, reversible: true)])
    }

    static func intermittent(_ i: DiagnosticInput) -> Hypothesis? {
        let drops = i.events24h.filter { $0.kind == .connectivityLost || $0.kind == .outageStart }.count
        guard drops >= Thresholds.disconnectsPerDayConcerning || i.bssidChanges24h >= 10 else { return nil }
        var sup: [String] = []
        if drops > 0 { sup.append("\(drops) perte(s) de connectivité sur 24 h") }
        if i.bssidChanges24h > 0 { sup.append("\(i.bssidChanges24h) changement(s) de point d’accès (BSSID) sur 24 h") }
        if !i.isWired, let sd = Stats.standardDeviation(i.rssiHistory), sd > Thresholds.rssiStdDevUnstable {
            sup.append(String(format: "Signal très variable (σ = %.1f dB)", sd))
        }
        var recs = [Recommendation(id: "monitor", title: "Activer l’Internet Health Monitor sur plusieurs jours",
                                   detail: "La chronologie distingue coupures locales (passerelle injoignable) et coupures Internet.",
                                   impact: .diagnosis, expectedEffectiveness: .high, risk: .none, reversible: true)]
        if i.bssidChanges24h >= 10 {
            recs.append(Recommendation(id: "mesh-roaming", title: "Vérifier le placement des répéteurs / nœuds mesh",
                                       detail: "Des bascules fréquentes entre points d’accès indiquent des zones de recouvrement mal équilibrées.",
                                       impact: .stability, expectedEffectiveness: .medium, risk: .low, reversible: true))
        }
        return Hypothesis(cause: .intermittentDisconnects, symptoms: ["Coupures ou bascules répétées"], supporting: sup, contradicting: [],
                          confidence: drops >= 5 ? .high : .medium,
                          nextChecks: ["Corréler les coupures avec l’heure et l’interface (Connection Timeline)"], recommendations: recs)
    }

    static func externalProblem(_ i: DiagnosticInput) -> Hypothesis? {
        guard let g = i.gatewayLatency, g.received > 0, !i.externalLatency.isEmpty else { return nil }
        let gwHealthy = g.lossPercent < Thresholds.lossConcerning && (g.medianMs ?? 0) < Thresholds.gatewayLatencyHighWiFi
        let extBad = i.externalLatency.filter { $0.lossPercent >= Thresholds.lossConcerning || ($0.medianMs ?? 0) > Thresholds.internetLatencyHigh }
        guard gwHealthy, !extBad.isEmpty else { return nil }
        var sup = ["Passerelle saine (\(Units.ms(g.medianMs)), \(String(format: "%.1f", g.lossPercent)) % de pertes)"]
        sup += extBad.map { "Dégradation vers \($0.target) : \(Units.ms($0.medianMs)), \(String(format: "%.1f", $0.lossPercent)) % de pertes" }
        var con: [String] = []
        let allBad = extBad.count == i.externalLatency.count
        if !allBad { con.append("Certaines destinations Internet restent saines : le problème peut être propre à une destination") }
        if let firstLossy = i.traceroute.first(where: { $0.timeouts > 0 && !$0.isPrivate }) {
            sup.append("Le tracé de route montre des pertes à partir du saut \(firstLossy.hop)")
            con.append("Un routeur intermédiaire peut ignorer l’ICMP sans dégrader le trafic réel : à interpréter avec prudence")
        }
        return Hypothesis(cause: .externalProblem, symptoms: ["Le réseau local est sain mais Internet est dégradé"], supporting: sup,
                          contradicting: con, confidence: allBad && i.externalLatency.count >= 2 ? .medium : .low,
                          nextChecks: ["Répéter la mesure dans 15 minutes", "Tester en Ethernet sur la box", "Consulter l’état du réseau de l’opérateur"],
                          recommendations: [Recommendation(id: "isp-evidence", title: "Constituer un dossier horodaté",
                                                           detail: "Ces symptômes sont compatibles avec un problème en dehors du réseau local, sans preuve d’une panne précise de l’opérateur.",
                                                           impact: .diagnosis, expectedEffectiveness: .medium, risk: .none, reversible: true)])
    }

    static func ethernetNegotiation(_ i: DiagnosticInput) -> Hypothesis? {
        guard i.isWired, let media = i.connection?.primaryInterface?.media else { return nil }
        let speed = InterfaceClassifier.ethernetSpeedMbps(media: media)
        let half = InterfaceClassifier.isHalfDuplex(media: media)
        guard half || (speed.map { $0 <= 100 } ?? false) else { return nil }
        var sup = ["Média négocié : \(media)"]
        if half { sup.append("Liaison en half-duplex") }
        if let s = speed, s <= 100 { sup.append("Vitesse négociée \(s) Mbit/s") }
        return Hypothesis(cause: .ethernetNegotiation, symptoms: ["Le lien filaire est négocié en dessous du gigabit"], supporting: sup,
                          contradicting: [], confidence: .high,
                          nextChecks: ["Essayer un autre câble (catégorie 5e minimum) et un autre port"],
                          recommendations: [Recommendation(id: "replace-cable", title: "Remplacer le câble ou l’adaptateur Ethernet",
                                                           detail: "Une paire défectueuse limite souvent le lien à 100 Mbit/s.",
                                                           impact: .throughput, expectedEffectiveness: .high, risk: .none, reversible: true, cost: "Câble ≈ 5–15 €")])
    }
}

/// Channel recommendation from observed neighbors. Never blindly recommends the widest channel.
public enum ChannelAdvisor {
    public struct Advice: Codable, Hashable, Sendable {
        public var band: WiFiBand
        public var channel: Int
        public var recommendedWidthMHz: Int
        public var rationale: String
        public var loadByChannel: [Int: Double]
    }

    /// Load metric: sum over neighbors of linear power (mW) for overlapping channels.
    public static func load(channel: Int, band: WiFiBand, neighbors: [WiFiNeighbor], excludingBSSID: String?) -> Double {
        neighbors.filter { $0.band == band && $0.bssid != excludingBSSID && DiagnosticsEngine.overlapping($0.channel, channel, band: band) }
            .reduce(0) { $0 + pow(10, Double($1.rssi) / 10) }
    }

    public static func recommend(band: WiFiBand, neighbors: [WiFiNeighbor], excludingBSSID: String?, current: Int?) -> Advice? {
        let candidates: [Int]
        switch band {
        case .ghz2_4: candidates = [1, 6, 11]
        case .ghz5: candidates = [36, 40, 44, 48, 149, 153, 157, 161]   // non-DFS in most regulatory domains
        case .ghz6: candidates = [1, 5, 21, 37, 53, 69, 85, 101]
        case .unknown: return nil
        }
        var loads: [Int: Double] = [:]
        for c in candidates { loads[c] = load(channel: c, band: band, neighbors: neighbors, excludingBSSID: excludingBSSID) }
        guard let best = loads.min(by: { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }) else { return nil }
        let sameBand = neighbors.filter { $0.band == band && $0.rssi > -80 }.count
        let width: Int
        switch band {
        case .ghz2_4: width = 20
        case .ghz5: width = sameBand >= 8 ? 40 : 80
        case .ghz6: width = sameBand >= 6 ? 80 : 160
        case .unknown: width = 20
        }
        var why = "Canal le moins chargé parmi \(candidates.map(String.init).joined(separator: "/")) d’après \(neighbors.filter { $0.band == band }.count) réseau(x) observé(s)."
        if let c = current, let cl = loads[c] ?? Optional(load(channel: c, band: band, neighbors: neighbors, excludingBSSID: excludingBSSID)),
           cl > 0, best.value > 0 {
            why += String(format: " Charge estimée %.0f %% de celle du canal actuel.", best.value / cl * 100)
        }
        why += " Largeur suggérée \(width) MHz : " + (band == .ghz2_4 ? "40 MHz est déconseillé en 2,4 GHz." : (sameBand >= 6 ? "environnement dense, une largeur réduite améliore la stabilité." : "environnement peu dense."))
        if band == .ghz5 { why += " Les canaux DFS (52–144) peuvent être moins encombrés mais sont sujets à des changements forcés en cas de détection radar." }
        return Advice(band: band, channel: best.key, recommendedWidthMHz: width, rationale: why, loadByChannel: loads)
    }
}
