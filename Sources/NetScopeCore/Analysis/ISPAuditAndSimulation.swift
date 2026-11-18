import Foundation

// MARK: - ISP Performance Audit

public enum AccessType: String, Codable, CaseIterable, Sendable {
    case fiber = "Fibre (FTTH)", cable = "Câble", xdsl = "xDSL", mobile = "4G/5G", satellite = "Satellite", other = "Autre"
}

public struct ISPProfile: Codable, Hashable, Sendable {
    public var provider: String
    public var plan: String
    public var accessType: AccessType
    /// Commercial "up to" figures (bits/s).
    public var advertisedDownBps: Double?
    public var advertisedUpBps: Double?
    /// Contractual minimums, if any (bits/s).
    public var guaranteedDownBps: Double?
    public var guaranteedUpBps: Double?
    public var notes: String

    public init(provider: String = "", plan: String = "", accessType: AccessType = .fiber, advertisedDownBps: Double? = nil,
                advertisedUpBps: Double? = nil, guaranteedDownBps: Double? = nil, guaranteedUpBps: Double? = nil, notes: String = "") {
        self.provider = provider; self.plan = plan; self.accessType = accessType; self.advertisedDownBps = advertisedDownBps
        self.advertisedUpBps = advertisedUpBps; self.guaranteedDownBps = guaranteedDownBps
        self.guaranteedUpBps = guaranteedUpBps; self.notes = notes
    }
}

public struct ISPAuditResult: Codable, Hashable, Sendable {
    public var totalTests: Int
    public var ethernetTests: Int
    public var medianDownBps: Double?
    public var medianUpBps: Double?
    public var ethernetMedianDownBps: Double?
    public var ethernetMedianUpBps: Double?
    public var ratioToAdvertised: Double?
    public var testsBelowGuaranteed: Int?
    public var byHour: [Int: Double]
    public var peakVsOffPeak: Double?
    public var findings: [String]
    public var remainingChecks: [String]
    public var disclaimer: String
}

public enum ISPAuditor {
    public static func audit(profile: ISPProfile, tests: [SpeedTestResult], ethernetInterfaces: Set<String>,
                             outages: [Outage], calendar: Calendar = .current) -> ISPAuditResult {
        let ok = tests.filter { $0.succeeded && $0.engine == .networkQuality }
        let eth = ok.filter { t in t.interfaceName.map(ethernetInterfaces.contains) ?? false }
        let dl = ok.compactMap(\.downloadBps), ul = ok.compactMap(\.uploadBps)
        let edl = eth.compactMap(\.downloadBps), eul = eth.compactMap(\.uploadBps)
        let ref = Stats.median(edl.isEmpty ? dl : edl)
        let ratio = (ref != nil && (profile.advertisedDownBps ?? 0) > 0) ? ref! / profile.advertisedDownBps! : nil
        let below: Int? = profile.guaranteedDownBps.map { g in (eth.isEmpty ? ok : eth).compactMap(\.downloadBps).filter { $0 < g }.count }

        var hours: [Int: [Double]] = [:]
        for t in ok { if let d = t.downloadBps { hours[calendar.component(.hour, from: t.timestamp), default: []].append(d) } }
        let byHour = hours.compactMapValues { Stats.median($0) }
        let peak = (20...23).flatMap { hours[$0] ?? [] }
        let off = [Array(5...11), Array(13...17)].flatMap { $0 }.flatMap { hours[$0] ?? [] }
        let peakRatio: Double? = (peak.count >= 2 && off.count >= 2) ? (Stats.median(peak)! / Stats.median(off)!) : nil

        var findings: [String] = []
        if let r = ratio { findings.append(String(format: "Débit descendant médian%@ : %.0f %% du débit commercial annoncé (%@).", edl.isEmpty ? "" : " en Ethernet", r * 100, Units.bitRate(profile.advertisedDownBps!))) }
        if let b = below, b > 0 { findings.append("\(b) test(s) sous le débit minimum garanti déclaré.") }
        if let p = peakRatio, p < 0.7 { findings.append(String(format: "Aux heures de pointe (20h–23h), le débit médian tombe à %.0f %% du débit hors pointe : saturation possible du réseau de collecte (à confirmer en Ethernet).", p * 100)) }
        let longOutages = outages.filter { ($0.duration ?? 0) >= 60 && $0.kind == .internet }
        if !longOutages.isEmpty { findings.append("\(longOutages.count) coupure(s) Internet d’au moins une minute avec passerelle joignable.") }

        var remaining: [String] = []
        if eth.count < 3 { remaining.append("Réaliser au moins 3 tests en Ethernet branché directement sur la box (actuellement \(eth.count)).") }
        if ok.count < 10 { remaining.append("Atteindre au moins 10 tests répartis sur plusieurs jours (actuellement \(ok.count)).") }
        if peak.count < 2 { remaining.append("Tester aux heures de pointe (20h–23h).") }
        if off.count < 2 { remaining.append("Tester en heures creuses (matin ou après-midi).") }
        if tests.contains(where: \.vpnActive) { remaining.append("Exclure les tests réalisés avec un VPN actif.") }
        if profile.advertisedDownBps == nil { remaining.append("Renseigner le débit commercial de l’offre.") }

        return ISPAuditResult(totalTests: ok.count, ethernetTests: eth.count, medianDownBps: Stats.median(dl), medianUpBps: Stats.median(ul),
                              ethernetMedianDownBps: Stats.median(edl), ethernetMedianUpBps: Stats.median(eul), ratioToAdvertised: ratio,
                              testsBelowGuaranteed: below, byHour: byHour, peakVsOffPeak: peakRatio, findings: findings, remainingChecks: remaining,
                              disclaimer: "Les débits commerciaux sont des maximums théoriques (« jusqu’à »), distincts d’éventuelles garanties contractuelles. Les mesures dépendent du serveur de test (Apple networkQuality), de l’équipement et du réseau local : elles documentent des performances observées, sans constituer à elles seules la preuve d’une défaillance de l’opérateur.")
    }
}

// MARK: - Multi-point segment localization

public enum MeasurementPointKind: String, Codable, CaseIterable, Sendable {
    case mac = "Mac principal", agent = "Agent NetScope", iperfServer = "Serveur iperf3", router = "Routeur", internet = "Serveur Internet"
}

public struct SegmentMeasurements: Sendable {
    public var macWiFiInternetDownBps: Double?
    public var macWiredInternetDownBps: Double?
    public var agentWiredInternetDownBps: Double?
    public var lanThroughputBps: Double?
    public var macGatewayLatency: LatencyStats?
    public var agentGatewayLatency: LatencyStats?
    public var macInternetLatency: LatencyStats?
    public var agentInternetLatency: LatencyStats?
    public var routerSyncDownBps: Double?

    public init(macWiFiInternetDownBps: Double? = nil, macWiredInternetDownBps: Double? = nil, agentWiredInternetDownBps: Double? = nil,
                lanThroughputBps: Double? = nil, macGatewayLatency: LatencyStats? = nil, agentGatewayLatency: LatencyStats? = nil,
                macInternetLatency: LatencyStats? = nil, agentInternetLatency: LatencyStats? = nil, routerSyncDownBps: Double? = nil) {
        self.macWiFiInternetDownBps = macWiFiInternetDownBps; self.macWiredInternetDownBps = macWiredInternetDownBps
        self.agentWiredInternetDownBps = agentWiredInternetDownBps; self.lanThroughputBps = lanThroughputBps
        self.macGatewayLatency = macGatewayLatency; self.agentGatewayLatency = agentGatewayLatency
        self.macInternetLatency = macInternetLatency; self.agentInternetLatency = agentInternetLatency; self.routerSyncDownBps = routerSyncDownBps
    }
}

public struct SegmentVerdict: Codable, Hashable, Identifiable, Sendable {
    public var id: String { segment }
    public var segment: String
    public var suspected: Bool
    public var confidence: Confidence
    public var evidence: [String]
}

public enum SegmentLocalizer {
    public static func localize(_ m: SegmentMeasurements) -> [SegmentVerdict] {
        var v: [SegmentVerdict] = []
        // Mac Wi-Fi link
        if let wifi = m.macWiFiInternetDownBps, let wired = m.macWiredInternetDownBps ?? m.agentWiredInternetDownBps {
            let sus = wifi < wired * 0.6
            v.append(SegmentVerdict(segment: "Liaison Wi-Fi du Mac", suspected: sus, confidence: .medium,
                                    evidence: ["Internet en Wi-Fi \(Units.bitRate(wifi)) contre \(Units.bitRate(wired)) en filaire"]))
        }
        if let mg = m.macGatewayLatency, let ag = m.agentGatewayLatency, let a = mg.medianMs, let b = ag.medianMs {
            let sus = a > b + 10 || mg.lossPercent > ag.lossPercent + 1
            v.append(SegmentVerdict(segment: "Accès radio local (Mac ↔ box)", suspected: sus, confidence: .medium,
                                    evidence: ["Latence passerelle Mac \(Units.ms(a)) / agent \(Units.ms(b))",
                                               String(format: "Pertes Mac %.1f %% / agent %.1f %%", mg.lossPercent, ag.lossPercent)]))
        }
        // LAN / router
        if let lan = m.lanThroughputBps {
            let sus = lan < 200e6
            v.append(SegmentVerdict(segment: "Réseau local / routeur (LAN)", suspected: sus, confidence: .medium,
                                    evidence: ["Débit LAN mesuré par iperf3 : \(Units.bitRate(lan))"]))
        }
        // WAN
        let bestInternet = [m.macWiredInternetDownBps, m.agentWiredInternetDownBps, m.macWiFiInternetDownBps].compactMap { $0 }.max()
        if let sync = m.routerSyncDownBps, let best = bestInternet {
            v.append(SegmentVerdict(segment: "Accès WAN (box ↔ opérateur)", suspected: best >= sync * Thresholds.wanSaturationRatio,
                                    confidence: .medium,
                                    evidence: ["Meilleur débit Internet \(Units.bitRate(best)) pour une synchronisation de \(Units.bitRate(sync)) (routeur)"]))
        }
        // Beyond
        if let ai = m.agentInternetLatency, let ag = m.agentGatewayLatency, ag.lossPercent < 1, ai.lossPercent >= 2 {
            v.append(SegmentVerdict(segment: "Au-delà de la box (opérateur ou Internet)", suspected: true, confidence: .low,
                                    evidence: [String(format: "Agent filaire : passerelle sans perte, %.1f %% de pertes vers Internet", ai.lossPercent)]))
        }
        return v
    }
}

// MARK: - Network Digital Twin (simulation)

public struct SimulationResult: Codable, Hashable, Identifiable, Sendable {
    public var id: String { scenario }
    public var scenario: String
    public var predicted: [String: String]
    public var assumptions: [String]
    public let disclaimer: String = "Simulation : estimation fondée sur un modèle simplifié, ce n’est pas une mesure réelle."
}

public enum NetworkSimulator {
    /// Log-distance path-loss model: RSSI(d) = RSSI(d0) − 10·n·log10(d/d0) − Σ walls.
    public static func predictedRSSI(referenceRSSIat1m: Double = -35, distanceMeters: Double, pathLossExponent: Double = 3.0,
                                     wallsLossDB: Double = 0) -> Double {
        referenceRSSIat1m - 10 * pathLossExponent * log10(max(distanceMeters, 1)) - wallsLossDB
    }

    /// Very rough achievable TCP throughput (Mbit/s) from SNR for a 2-stream 80 MHz client — planning only.
    public static func estimatedThroughputMbps(snr: Double, widthMHz: Int = 80) -> Double {
        let table: [(Double, Double)] = [(5, 15), (10, 60), (15, 140), (20, 250), (25, 380), (30, 520), (35, 650), (40, 750)]
        let base = Thresholds.score(snr, table.map { ($0.0, $0.1) })
        return base * Double(widthMHz) / 80
    }

    public static func wallsCrossed(_ walls: [Wall], from a: Point2D, to b: Point2D) -> [Wall] {
        func ccw(_ p: Point2D, _ q: Point2D, _ r: Point2D) -> Bool { (r.y - p.y) * (q.x - p.x) > (q.y - p.y) * (r.x - p.x) }
        return walls.filter { w in ccw(a, w.a, w.b) != ccw(b, w.a, w.b) && ccw(a, b, w.a) != ccw(a, b, w.b) }
    }

    public static func wifiToEthernet(currentWiFiDownBps: Double?, wanReferenceBps: Double?, ethernetLinkMbps: Int = 1000) -> SimulationResult {
        let ceiling = Double(ethernetLinkMbps) * 1e6 * 0.94
        let predicted = wanReferenceBps.map { min($0, ceiling) }
        var p: [String: String] = ["Plafond Ethernet utile": Units.bitRate(ceiling)]
        if let x = predicted { p["Débit attendu"] = "≈ " + Units.bitRate(x) }
        if let w = currentWiFiDownBps, let x = predicted { p["Gain estimé"] = String(format: "× %.1f", x / max(w, 1)) }
        return SimulationResult(scenario: "Passage du Wi-Fi à l’Ethernet", predicted: p,
                                assumptions: ["Le débit attendu est borné par la meilleure mesure Internet de référence (WAN) et par 94 % du lien Ethernet.",
                                              "Aucune congestion locale supplémentaire."])
    }

    public static func addAccessPoint(project: HeatmapProject, apPosition: Point2D, client: Point2D, noiseDBm: Double = -92) -> SimulationResult {
        let walls = wallsCrossed(project.walls, from: apPosition, to: client)
        let loss = walls.reduce(0) { $0 + $1.material.attenuationDB }
        let rssi = predictedRSSI(distanceMeters: apPosition.distance(to: client), wallsLossDB: loss)
        let snr = rssi - noiseDBm
        return SimulationResult(scenario: "Ajout d’un point d’accès",
                                predicted: ["RSSI estimé au poste": String(format: "%.0f dBm", rssi),
                                            "SNR estimé": String(format: "%.0f dB", snr),
                                            "Débit radio estimé": String(format: "≈ %.0f Mbit/s", estimatedThroughputMbps(snr: snr))],
                                assumptions: ["Modèle log-distance, exposant 3,0, −35 dBm à 1 m.",
                                              "\(walls.count) mur(s) traversé(s), atténuation totale \(Int(loss)) dB (valeurs indicatives 5 GHz).",
                                              String(format: "Plancher de bruit supposé %.0f dBm.", noiseDBm)])
    }

    public static func reduceCongestion(currentDownBps: Double?, backgroundBps: Double, linkCapacityBps: Double?) -> SimulationResult {
        var p: [String: String] = ["Trafic de fond retiré": Units.bitRate(backgroundBps)]
        if let c = currentDownBps { p["Débit attendu"] = "≈ " + Units.bitRate(min((linkCapacityBps ?? .infinity), c + backgroundBps)) }
        return SimulationResult(scenario: "Réduction de la congestion", predicted: p,
                                assumptions: ["Le trafic de fond libéré est entièrement récupéré par le test (hypothèse optimiste)."])
    }

    public static func enableSQM(idleMs: Double?, loadedMs: Double?) -> SimulationResult {
        var p: [String: String] = [:]
        if let i = idleMs, let l = loadedMs {
            p["Latence sous charge actuelle"] = Units.ms(l)
            p["Latence sous charge visée"] = "≈ " + Units.ms(i + 5) + " à " + Units.ms(i + 15)
            p["Coût en débit"] = "≈ 5–10 % (limiteur sous le débit réel)"
        }
        return SimulationResult(scenario: "Activation QoS/SQM compatible", predicted: p,
                                assumptions: ["Ordres de grandeur typiques de fq_codel/CAKE correctement réglés ; à valider par le Bufferbloat Lab."])
    }
}
