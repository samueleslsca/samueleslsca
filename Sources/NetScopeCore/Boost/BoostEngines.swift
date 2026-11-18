import Foundation

// MARK: - Network configuration inspector (read-only)

public enum StackStatus: String, Codable, Sendable { case normal = "Normal", unusual = "Inhabituel", info = "Information", unavailable = "Indisponible" }

public struct StackFinding: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var value: String
    public var status: StackStatus
    public var note: String
}

public struct ServiceOrderEntry: Codable, Hashable, Sendable {
    public var position: Int
    public var name: String
    public var device: String?
    public var enabled: Bool
}

public enum ServiceOrderParser {
    /// Parses `networksetup -listnetworkserviceorder`.
    public static func parse(_ text: String) -> [ServiceOrderEntry] {
        var out: [ServiceOrderEntry] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("("), let close = line.firstIndex(of: ")"), !line.hasPrefix("(Hardware") {
                let inner = line[line.index(after: line.startIndex)..<close]
                let name = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                if let n = Int(inner) { out.append(ServiceOrderEntry(position: n, name: name, device: nil, enabled: true)) }
                else if inner == "*" { out.append(ServiceOrderEntry(position: out.count + 1, name: name, device: nil, enabled: false)) }
            } else if line.hasPrefix("(Hardware Port:"), let r = line.range(of: "Device: "), !out.isEmpty {
                let dev = line[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
                out[out.count - 1].device = dev.isEmpty ? nil : dev
            }
        }
        return out
    }
}

public enum NetworkConfigurationInspector {
    /// TCP parameters observed (never modified). macOS defaults are adequate for nearly every connection.
    public static let tcpKeys = ["net.inet.tcp.sack", "net.inet.tcp.mssdflt", "net.inet.tcp.win_scale_factor",
                                 "net.inet.tcp.autorcvbufmax", "net.inet.tcp.autosndbufmax", "net.inet.tcp.delayed_ack",
                                 "net.inet.tcp.ecn_initiate_out", "net.inet.tcp.ecn_negotiate_in"]

    public static func read(runner: CommandRunning) async -> (tcp: [String: String], order: [ServiceOrderEntry]) {
        var tcp: [String: String] = [:]
        for k in tcpKeys {
            if let r = try? await runner.run(.sysctl, ["-n", k], timeout: 3), r.exitCode == 0 {
                tcp[k] = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let order = (try? await runner.run(.networksetup, ["-listnetworkserviceorder"], timeout: 5)).map { ServiceOrderParser.parse($0.stdout) } ?? []
        return (tcp, order)
    }

    public static func inspect(connection c: ConnectionSnapshot?, tcp: [String: String], serviceOrder: [ServiceOrderEntry],
                               dnsBenchmark: [DNSDiagnosticsService.BenchmarkRow], configuredDNSMedianMs: Double?) -> (findings: [StackFinding], candidates: [BoostCandidate]) {
        var f: [StackFinding] = []
        var cands: [BoostCandidate] = []
        guard let c else {
            return ([StackFinding(id: "conn", title: "Connexion", value: "Inconnue", status: .unavailable, note: "Snapshot réseau indisponible")], [])
        }
        let p = c.primaryInterface
        f.append(StackFinding(id: "iface", title: "Interface active", value: p.map { "\($0.bsdName) (\($0.kind.label))" } ?? "aucune",
                              status: p == nil ? .unusual : .normal, note: "Interface portant la route par défaut."))
        if let p, let mtu = p.mtu, p.kind == .wifi || p.kind == .ethernet {
            f.append(StackFinding(id: "mtu", title: "MTU", value: "\(mtu)", status: mtu < 1500 ? .unusual : (mtu > 1500 ? .info : .normal),
                                  note: mtu < 1500 ? "MTU inférieure à 1500 sur une interface physique : vérifiez qu’elle n’a pas été modifiée manuellement. NetScope ne la modifie pas." :
                                    (mtu > 1500 ? "Trames jumbo : utile uniquement si tout le réseau local les prend en charge." : "Valeur standard Ethernet/Wi-Fi.")))
        }
        let v4 = p?.ipv4.first?.address
        f.append(StackFinding(id: "ipv4", title: "IPv4", value: v4 ?? "aucune", status: v4 == nil ? .unusual : .normal, note: "Adresse de l’interface active."))
        let v6 = p?.globalIPv6.first
        f.append(StackFinding(id: "ipv6", title: "IPv6", value: v6 ?? "pas d’adresse globale", status: v6 == nil ? .info : .normal,
                              note: "NetScope ne recommande jamais de désactiver IPv6 : ce n’est pas un levier de performance fiable."))
        f.append(StackFinding(id: "dns", title: "DNS", value: c.dns?.primaryNameservers.joined(separator: ", ") ?? "aucun",
                              status: (c.dns?.primaryNameservers.isEmpty ?? true) ? .unusual : .normal, note: "Résolveurs généraux (scutil --dns)."))
        f.append(StackFinding(id: "vpn", title: "VPN", value: c.vpnActive ? c.vpnInterfaces.joined(separator: ", ") : "non détecté", status: c.vpnActive ? .info : .normal,
                              note: c.vpnActive ? "Tout le trafic mesuré passe par le tunnel." : ""))
        f.append(StackFinding(id: "proxy", title: "Proxy", value: (c.proxy?.isActive ?? false) ? c.proxy!.enabled.map(\.rawValue).joined(separator: ", ") : "aucun",
                              status: (c.proxy?.isActive ?? false) ? .info : .normal, note: ""))
        if let p, p.kind == .ethernet {
            let speed = InterfaceClassifier.ethernetSpeedMbps(media: p.media)
            let half = InterfaceClassifier.isHalfDuplex(media: p.media)
            f.append(StackFinding(id: "eth", title: "Négociation Ethernet", value: p.media ?? "inconnue",
                                  status: (speed.map { $0 < 1000 } ?? false) || half ? .unusual : .normal, note: "Vitesse et duplex négociés par le lien."))
            if (speed.map { $0 < 1000 } ?? false) || half {
                cands.append(BoostCandidate(id: "eth-cable", title: "Remplacer le câble ou l’adaptateur Ethernet",
                                            detail: "Le lien est négocié à \(speed.map { "\($0) Mbit/s" } ?? "?")\(half ? " en half-duplex" : ""). Un câble de catégorie 5e ou mieux et un autre port permettent souvent de retrouver 1 Gbit/s.",
                                            evidence: ["Média : \(p.media ?? "?")"], category: .physical, targets: [.download, .upload], expectedGain: .high,
                                            risk: .none, reversible: true, safety: .readOnly, action: .guided(steps: ["Remplacer le câble (Cat 5e/6).", "Essayer un autre port de la box.", "Relancer « Vérifier »."]),
                                            status: .guided))
            }
        }
        // Service order: Wi-Fi ranked before a connected Ethernet service.
        let devKinds = Dictionary(c.interfaces.map { ($0.bsdName, $0) }, uniquingKeysWith: { a, _ in a })
        if let wifiIdx = serviceOrder.firstIndex(where: { $0.enabled && devKinds[$0.device ?? ""]?.kind == .wifi }),
           let ethIdx = serviceOrder.firstIndex(where: { e in e.enabled && devKinds[e.device ?? ""].map { $0.kind == .ethernet && $0.isRunning && !$0.ipv4.isEmpty } == true }),
           wifiIdx < ethIdx {
            f.append(StackFinding(id: "order", title: "Ordre des services", value: serviceOrder.filter(\.enabled).map(\.name).joined(separator: " > "), status: .unusual,
                                  note: "Le Wi-Fi est prioritaire sur un Ethernet connecté."))
            cands.append(BoostCandidate(id: "service-order", title: "Placer l’Ethernet avant le Wi-Fi dans l’ordre des services",
                                        detail: "macOS utilise le premier service actif de la liste. Réglages Système → Réseau → « … » → Définir l’ordre des services.",
                                        evidence: ["Ordre actuel : " + serviceOrder.filter(\.enabled).map(\.name).joined(separator: " > ")],
                                        category: .stack, targets: [.download, .upload, .idleLatency, .jitter], expectedGain: .high, risk: .low, reversible: true,
                                        safety: .readOnly, action: .guided(steps: ["Réglages Système → Réseau", "Menu « … » → Définir l’ordre des services", "Glisser l’Ethernet en premier", "Relancer « Vérifier »"]),
                                        status: .guided))
        } else if !serviceOrder.isEmpty {
            f.append(StackFinding(id: "order", title: "Ordre des services", value: serviceOrder.filter(\.enabled).map(\.name).joined(separator: " > "), status: .normal, note: ""))
        }
        // TCP (observation only).
        if tcp.isEmpty {
            f.append(StackFinding(id: "tcp", title: "Paramètres TCP", value: "non lus", status: .unavailable, note: "sysctl indisponible."))
        }
        for k in tcpKeys {
            guard let v = tcp[k] else { continue }
            var status = StackStatus.normal
            var note = "Observation uniquement : NetScope ne modifie pas les paramètres noyau."
            if k == "net.inet.tcp.sack", v != "1" { status = .unusual; note = "SACK désactivé : réglage inhabituel, probablement modifié par un utilitaire tiers. Un redémarrage rétablit les valeurs par défaut si elles n’ont pas été rendues persistantes." }
            if (k == "net.inet.tcp.autorcvbufmax" || k == "net.inet.tcp.autosndbufmax"), let n = Int(v), n < 1_048_576 {
                status = .unusual; note = "Tampon automatique maximal faible : peut limiter le débit sur les liens rapides et lointains. Valeur probablement modifiée manuellement."
            }
            f.append(StackFinding(id: k, title: k, value: v, status: status, note: note))
        }
        // DNS: only when a specific benefit is measured.
        if let configured = configuredDNSMedianMs, let best = dnsBenchmark.first(where: { $0.failures == 0 && $0.medianMs != nil }),
           let bm = best.medianMs, configured - bm >= 20, bm <= configured * 0.7 {
            cands.append(BoostCandidate(id: "dns-\(best.resolver)", title: "Envisager le résolveur \(best.label) (\(best.resolver))",
                                        detail: "Résolution médiane \(Units.ms(bm)) contre \(Units.ms(configured)) pour vos DNS actuels, sans échec, sur un benchmark reproductible. Cela accélère l’ouverture des connexions, pas le débit de téléchargement. NetScope ne modifie pas vos DNS : à changer vous-même (réversible) dans Réglages Système → Réseau → Détails → DNS.",
                                        evidence: ["Benchmark : \(best.queries) requêtes, médiane \(Units.ms(bm)), P90 \(Units.ms(best.p90Ms))"],
                                        category: .dns, targets: [], expectedGain: .medium, risk: .low, reversible: true, safety: .readOnly,
                                        action: .guided(steps: ["Noter vos DNS actuels : \(c.dns?.primaryNameservers.joined(separator: ", ") ?? "—")", "Réglages Système → Réseau → interface → Détails → DNS", "Ajouter \(best.resolver)", "Pour revenir en arrière : remettre les valeurs notées"]),
                                        tradeoffs: ["Le résolveur public voit vos requêtes DNS (politique de confidentialité à vérifier)."], status: .guided))
        }
        if c.vpnActive {
            cands.append(BoostCandidate(id: "vpn-test", title: "Mesurer sans VPN pour comparaison", detail: "Désactivez temporairement le VPN vous-même, puis lancez « Vérifier ». NetScope ne touche jamais au VPN.",
                                        evidence: ["Tunnel : \(c.vpnInterfaces.joined(separator: ", "))"], category: .stack, targets: [.download, .idleLatency], expectedGain: .medium,
                                        risk: .medium, reversible: true, safety: .readOnly, action: .guided(steps: ["Désactiver le VPN (si votre usage le permet)", "Vérifier", "Réactiver le VPN"]),
                                        tradeoffs: ["Sans VPN, votre trafic n’est plus protégé par le tunnel."], status: .guided))
        }
        return (f, cands)
    }
}

// MARK: - Bandwidth intelligence

public struct Contender: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var pid: Int?
    public var meanBps: Double
    public var peakBps: Double
    public var presence: Double
    public var share: Double
    public var volumeBytes: Double
    public var likelyContributor: Bool
    public var confidence: Confidence
    public var evidence: String
}

public struct ContentionReport: Codable, Hashable, Sendable {
    public var processes: [Contender]
    public var devices: [Contender]
    public var interfaceMeanBps: Double?
    public var saturationRatio: Double?
    public var samples: Int
    public var notes: [String]
}

public enum BandwidthContentionAnalyzer {
    /// - Parameters:
    ///   - processSamples: successive per-process rate samples (from nettop deltas), oldest first.
    ///   - intervalSeconds: spacing between samples.
    ///   - capacityBps: measured link capacity (latest download), used to judge saturation.
    public static func analyze(processSamples: [[ProcessTrafficService.ProcessRate]], intervalSeconds: Double,
                               interfaceSamples: [ThroughputSample], capacityBps: Double?, routerClients: [RouterClient]) -> ContentionReport {
        var notes: [String] = []
        let n = processSamples.count
        let ifaceMean = Stats.mean(interfaceSamples.map { $0.inBps + $0.outBps })
        let saturation = (ifaceMean != nil && (capacityBps ?? 0) > 0) ? ifaceMean! / capacityBps! : nil
        var byProc: [String: (name: String, pid: Int?, rates: [Double])] = [:]
        for sample in processSamples {
            for r in sample { byProc[r.id, default: (r.process, r.pid, [])].rates.append(r.inBps + r.outBps) }
        }
        let totalAll = byProc.values.flatMap(\.rates).reduce(0, +)
        var procs: [Contender] = byProc.map { id, v in
            let mean = v.rates.reduce(0, +) / Double(max(n, 1))
            let active = v.rates.filter { $0 > 1e6 }.count
            let presence = Double(active) / Double(max(n, 1))
            let share = totalAll > 0 ? v.rates.reduce(0, +) / totalAll : 0
            let enough = n >= 3
            let saturating = saturation.map { $0 >= 0.25 } ?? (mean > 10e6)
            let likely = enough && share >= 0.3 && presence >= 0.6 && saturating
            let conf: Confidence = !enough ? .none : (likely && (saturation ?? 0) >= 0.5 ? .high : (likely ? .medium : .low))
            return Contender(id: id, name: v.name, pid: v.pid, meanBps: mean, peakBps: v.rates.max() ?? 0, presence: presence, share: share,
                             volumeBytes: mean / 8 * intervalSeconds * Double(n), likelyContributor: likely, confidence: conf,
                             evidence: String(format: "%.0f %% du trafic par processus, actif sur %.0f %% des relevés", share * 100, presence * 100))
        }
        procs.sort { $0.meanBps > $1.meanBps }
        if n < 3 { notes.append("Moins de 3 relevés : aucune application n’est désignée comme responsable.") }
        if let s = saturation { notes.append(String(format: "Trafic moyen de l’interface : %.0f %% de la capacité mesurée.", s * 100)) }

        let reported = routerClients.filter { ($0.rxBytesPerSecond ?? 0) + ($0.txBytesPerSecond ?? 0) > 0 }
        let totalDev = reported.reduce(0) { $0 + (($1.rxBytesPerSecond ?? 0) + ($1.txBytesPerSecond ?? 0)) * 8 }
        let devices: [Contender] = reported.map { cl in
            let bps = ((cl.rxBytesPerSecond ?? 0) + (cl.txBytesPerSecond ?? 0)) * 8
            let share = totalDev > 0 ? bps / totalDev : 0
            let likely = share >= 0.5 && (capacityBps.map { bps >= $0 * 0.3 } ?? false)
            return Contender(id: cl.id, name: cl.name ?? cl.mac ?? cl.id, pid: nil, meanBps: bps, peakBps: bps, presence: 1, share: share, volumeBytes: 0,
                             likelyContributor: likely, confidence: likely ? .low : .none,
                             evidence: "Débit instantané rapporté par le routeur (un seul relevé : confiance limitée)")
        }.sorted { $0.meanBps > $1.meanBps }
        if routerClients.isEmpty { notes.append("Sans API routeur, la consommation des autres appareils est inconnue.") }
        return ContentionReport(processes: procs, devices: devices, interfaceMeanBps: ifaceMean, saturationRatio: saturation, samples: n, notes: notes)
    }

    public static func candidates(_ r: ContentionReport, quittableNames: Set<String>) -> [BoostCandidate] {
        r.processes.filter(\.likelyContributor).prefix(3).map { p in
            let canQuit = p.pid != nil && quittableNames.contains(p.name)
            return BoostCandidate(id: "contention-\(p.name)", title: "Mettre en pause ou quitter « \(p.name) »",
                                  detail: "Ce processus consomme une part importante du trafic pendant l’analyse. Mettez en pause son transfert (synchronisation, téléchargement) ou quittez l’application, puis vérifiez.",
                                  evidence: [p.evidence, "Moyenne \(Units.bitRate(p.meanBps)), pic \(Units.bitRate(p.peakBps))"], category: .bandwidth,
                                  targets: [.download, .upload, .loadedLatency], expectedGain: p.confidence, risk: .low, reversible: true,
                                  safety: .reversible,
                                  action: canQuit ? .quitApplication(pid: p.pid!, name: p.name) : .guided(steps: ["Mettre en pause le transfert dans « \(p.name) »", "Relancer « Vérifier »"]),
                                  affected: ["Ce Mac : l’application \(p.name)"],
                                  tradeoffs: ["Les transferts en cours de cette application peuvent être interrompus."], status: canQuit ? .available : .guided)
        }
    }
}

// MARK: - Wi-Fi Performance Booster

public struct WiFiBoostInput: Sendable {
    public var wifi: WiFiSnapshot?
    public var isWired: Bool
    public var neighbors: [WiFiNeighbor]
    public var rssiHistory: [Double]
    public var txRateHistory: [Double]
    public var bssidChanges24h: Int
    public var disconnects24h: Int
    public var wifiDownMedianBps: Double?
    public var ethernetDownMedianBps: Double?
    public var routerName: String?

    public init(wifi: WiFiSnapshot?, isWired: Bool, neighbors: [WiFiNeighbor] = [], rssiHistory: [Double] = [], txRateHistory: [Double] = [],
                bssidChanges24h: Int = 0, disconnects24h: Int = 0, wifiDownMedianBps: Double? = nil, ethernetDownMedianBps: Double? = nil, routerName: String? = nil) {
        self.wifi = wifi; self.isWired = isWired; self.neighbors = neighbors; self.rssiHistory = rssiHistory; self.txRateHistory = txRateHistory
        self.bssidChanges24h = bssidChanges24h; self.disconnects24h = disconnects24h; self.wifiDownMedianBps = wifiDownMedianBps
        self.ethernetDownMedianBps = ethernetDownMedianBps; self.routerName = routerName
    }
}

public enum WiFiOptimizationEngine {
    public static func recommend(_ i: WiFiBoostInput) -> (candidates: [BoostCandidate], notes: [String]) {
        var c: [BoostCandidate] = []
        var notes = ["MLO (Wi-Fi 7) : indisponible, non exposé par CoreWLAN."]
        guard !i.isWired, let w = i.wifi, let rssi = w.rssi.value else {
            if i.isWired { notes.append("Connexion Ethernet active : le Wi-Fi Booster ne s’applique pas au trafic de ce Mac.") }
            return (c, notes)
        }
        let routerUI = i.routerName.map { "l’interface de \($0)" } ?? "l’interface d’administration de votre box"
        if rssi < Thresholds.rssiGood {
            c.append(BoostCandidate(id: "wifi-position", title: "Rapprocher le Mac du point d’accès ou dégager l’obstacle",
                                    detail: "Le signal mesuré est de \(rssi) dBm (seuil « bon » : \(Thresholds.rssiGood) dBm). Chaque mur porteur ou meuble métallique coûte plusieurs dB.",
                                    evidence: ["RSSI \(rssi) dBm"] + (w.snr.value.map { ["SNR \($0) dB"] } ?? []), category: .wifi,
                                    targets: [.download, .upload, .jitter, .loss], expectedGain: rssi < Thresholds.rssiFair ? .high : .medium, risk: .none, reversible: true,
                                    safety: .readOnly, action: .guided(steps: ["Déplacer le Mac (ou la box) de quelques mètres, à découvert", "Relancer « Vérifier »"]), status: .guided))
        }
        let ssid = w.ssid.value
        let band = w.band.value ?? .unknown
        if let ssid {
            let same = i.neighbors.filter { $0.ssid == ssid && $0.bssid != w.bssid.value }
            if band == .ghz2_4, let fast = same.filter({ $0.band != .ghz2_4 && $0.rssi > -70 }).max(by: { $0.rssi < $1.rssi }) {
                c.append(BoostCandidate(id: "wifi-band", title: "Passer en \(fast.band.rawValue)",
                                        detail: "Votre réseau est aussi diffusé en \(fast.band.rawValue) avec un signal de \(fast.rssi) dBm ici. La bande 2,4 GHz est plus lente et plus encombrée.",
                                        evidence: ["Actuel : 2,4 GHz, canal \(w.channel.value.map(String.init) ?? "?")", "\(fast.band.rawValue) visible : \(fast.rssi) dBm, canal \(fast.channel)"],
                                        category: .wifi, targets: [.download, .upload, .jitter], expectedGain: .medium, risk: .low, reversible: true, safety: .readOnly,
                                        action: .guided(steps: ["Si la box propose des SSID séparés par bande, rejoindre celui en \(fast.band.rawValue)", "Sinon, activer l’orientation de bande (band steering) dans \(routerUI)", "Relancer « Vérifier »"]),
                                        status: .guided))
            }
            if let better = same.filter({ $0.band == band || $0.band != .ghz2_4 }).max(by: { $0.rssi < $1.rssi }), better.rssi >= rssi + 8 {
                c.append(BoostCandidate(id: "wifi-ap", title: "Se reconnecter au point d’accès le plus proche",
                                        detail: "Un autre point d’accès de votre réseau est reçu à \(better.rssi) dBm contre \(rssi) dBm pour l’actuel : macOS n’a pas encore basculé.",
                                        evidence: ["Point d’accès actuel : \(rssi) dBm", "Autre point d’accès : \(better.rssi) dBm (canal \(better.channel))"], category: .wifi,
                                        targets: [.download, .jitter, .loss], expectedGain: .medium, risk: .low, reversible: true, safety: .readOnly,
                                        action: .guided(steps: ["Désactiver puis réactiver le Wi-Fi du Mac (barre de menus)", "Relancer « Vérifier »"]), status: .guided))
            }
        }
        if let ch = w.channel.value, band != .unknown, !i.neighbors.isEmpty,
           let adv = ChannelAdvisor.recommend(band: band, neighbors: i.neighbors, excludingBSSID: w.bssid.value, current: ch), adv.channel != ch {
            let cur = adv.loadByChannel[ch] ?? ChannelAdvisor.load(channel: ch, band: band, neighbors: i.neighbors, excludingBSSID: w.bssid.value)
            let best = adv.loadByChannel[adv.channel] ?? 0
            if cur > 0, best < cur * 0.5 {
                c.append(BoostCandidate(id: "wifi-channel", title: "Changer le canal de la box : \(ch) → \(adv.channel)",
                                        detail: adv.rationale, evidence: [String(format: "Charge estimée du canal suggéré : %.0f %% de l’actuel", best / cur * 100)],
                                        category: .wifi, targets: [.jitter, .loss, .download], expectedGain: .medium, risk: .low, reversible: true, safety: .readOnly,
                                        action: .guided(steps: ["Noter le canal actuel (\(ch)) et la largeur actuelle", "Dans \(routerUI) : Wi-Fi → canal \(adv.channel), largeur \(adv.recommendedWidthMHz) MHz", "Tous les appareils Wi-Fi seront brièvement déconnectés", "Relancer « Vérifier » ; remettre le canal \(ch) si aucun gain"]),
                                        affected: ["Tous les appareils Wi-Fi (reconnexion de quelques secondes)"], status: .guided))
            }
        }
        if let width = w.channelWidthMHz.value {
            let dense = i.neighbors.filter { $0.band == band && $0.rssi > -80 }.count
            if band == .ghz2_4 && width > 20 {
                c.append(BoostCandidate(id: "wifi-width", title: "Réduire la largeur de canal à 20 MHz (2,4 GHz)", detail: "40 MHz en 2,4 GHz chevauche la majorité des canaux et augmente les interférences.",
                                        evidence: ["Largeur actuelle \(width) MHz"], category: .wifi, targets: [.jitter, .loss], expectedGain: .low, risk: .low, reversible: true,
                                        safety: .readOnly, action: .guided(steps: ["Dans \(routerUI) : largeur 2,4 GHz = 20 MHz", "Vérifier"]), affected: ["Appareils en 2,4 GHz"], status: .guided))
            } else if width >= 160 && dense >= 6 {
                c.append(BoostCandidate(id: "wifi-width", title: "Essayer 80 MHz au lieu de \(width) MHz", detail: "Environnement dense (\(dense) réseaux audibles) : un canal plus étroit est souvent plus stable, au prix d’un débit théorique moindre.",
                                        evidence: ["Largeur actuelle \(width) MHz", "\(dense) réseaux voisins > −80 dBm"], category: .wifi, targets: [.jitter, .loss],
                                        expectedGain: .low, risk: .low, reversible: true, safety: .readOnly,
                                        action: .guided(steps: ["Dans \(routerUI) : largeur 80 MHz", "Vérifier ; revenir à \(width) MHz si le débit chute sans gain de stabilité"]),
                                        tradeoffs: ["Débit maximal théorique réduit"], status: .guided))
            }
        }
        if i.txRateHistory.count >= 10, let first = Stats.median(Array(i.txRateHistory.prefix(5))), let last = Stats.median(Array(i.txRateHistory.suffix(5))), last < first * 0.7 {
            notes.append(String(format: "Le débit de liaison a baissé de %.0f à %.0f Mbit/s pendant l’observation.", first, last))
        }
        if let wd = i.wifiDownMedianBps, let ed = i.ethernetDownMedianBps, wd < ed * 0.6 {
            c.append(BoostCandidate(id: "use-ethernet", title: "Utiliser une liaison Ethernet", detail: "Vos mesures en Ethernet atteignent \(Units.bitRate(ed)) contre \(Units.bitRate(wd)) en Wi-Fi.",
                                    evidence: ["Médiane Wi-Fi \(Units.bitRate(wd))", "Médiane Ethernet \(Units.bitRate(ed))"], category: .physical,
                                    targets: [.download, .upload, .idleLatency, .jitter, .loss], expectedGain: .high, risk: .none, reversible: true, safety: .readOnly,
                                    action: .guided(steps: ["Brancher le Mac à la box (adaptateur USB-C si nécessaire)", "Vérifier"]), status: .guided))
        } else if i.ethernetDownMedianBps == nil, let tx = w.txRateMbps.value, let wd = i.wifiDownMedianBps, wd > tx * 1e6 * 0.5 {
            c.append(BoostCandidate(id: "use-ethernet", title: "Tester en Ethernet", detail: "Le débit mesuré atteint plus de la moitié du débit de liaison Wi-Fi (\(Int(tx)) Mbit/s) : la radio peut être le facteur limitant.",
                                    evidence: ["Débit mesuré \(Units.bitRate(wd))", "Liaison \(Int(tx)) Mbit/s"], category: .physical, targets: [.download, .upload],
                                    expectedGain: .medium, risk: .none, reversible: true, safety: .readOnly, action: .guided(steps: ["Brancher en Ethernet", "Vérifier"]), status: .guided))
        }
        if i.disconnects24h >= 3 || i.bssidChanges24h >= 10 {
            c.append(BoostCandidate(id: "wifi-stability", title: "Stabiliser la couverture (position des répéteurs / nœuds mesh)",
                                    detail: "\(i.disconnects24h) déconnexion(s) et \(i.bssidChanges24h) bascule(s) de point d’accès sur 24 h.",
                                    evidence: ["Chronologie des événements"], category: .wifi, targets: [.loss, .jitter], expectedGain: .medium, risk: .low, reversible: true,
                                    safety: .readOnly, action: .guided(steps: ["Rapprocher les nœuds mesh (signal entre nœuds > −65 dBm)", "Cartographier avec Wi-Fi Heatmap"]), status: .guided))
        }
        return (c, notes)
    }
}

// MARK: - Bufferbloat auto-tuning (selection logic)

public struct TuningTrial: Codable, Hashable, Sendable {
    public var settings: SQMSettings
    public var samples: [BoostSample]
}

public struct TuningDecision: Codable, Hashable, Sendable {
    public var chosen: SQMSettings?
    public var rationale: String
    public var warning: String?
    public var perTrial: [String]
}

public enum BufferbloatTuningService {
    /// Prudent shaper rates (fractions of the measured *unshaped* throughput), per sqm-scripts guidance (85–95 %).
    public static let fractions = [0.95, 0.90, 0.85]

    public static func candidates(base: SQMSettings, measuredDownBps: Double, measuredUpBps: Double) -> [SQMSettings] {
        fractions.map { f in
            var s = base
            s.enabled = true
            s.downloadKbps = max(1000, Int(measuredDownBps * f / 1000))
            s.uploadKbps = max(500, Int(measuredUpBps * f / 1000))
            if s.qdisc.isEmpty { s.qdisc = "cake" }
            if s.script.isEmpty { s.script = "piece_of_cake.qos" }
            return s
        }
    }

    static func added(_ s: [BoostSample]) -> [Double] {
        s.compactMap { x in x.loadedLatencyMs.flatMap { l in x.idleLatencyMs.map { max(0, l - $0) } } }
    }

    /// Keeps the setting with the lowest added latency whose download loss stays within `tolerance`, and only if the
    /// latency improvement over the baseline is confirmed. Never optimises ping at any throughput cost silently.
    public static func select(trials: [TuningTrial], baseline: [BoostSample], tolerance: Double = 0.15) -> TuningDecision {
        let baseDL = Stats.median(baseline.compactMap(\.downloadBps)) ?? 0
        let baseAdded = added(baseline)
        var lines: [String] = []
        var eligible: [(TuningTrial, Double)] = []
        var bestAny: (TuningTrial, Double, Double)?
        for t in trials {
            let a = Stats.median(added(t.samples)) ?? .infinity
            let dl = Stats.median(t.samples.compactMap(\.downloadBps)) ?? 0
            let loss = baseDL > 0 ? (baseDL - dl) / baseDL : 0
            let cmp = CampaignComparison.compare(metric: "lat", before: baseAdded, after: added(t.samples), lowerIsBetter: true, minimumSamples: min(2, max(1, t.samples.count)))
            lines.append(String(format: "↓ %d / ↑ %d kbit/s : latence ajoutée %@, débit %@ (%+.0f %%) — %@", t.settings.downloadKbps, t.settings.uploadKbps,
                                Units.ms(a.isFinite ? a : nil), Units.bitRate(dl), -loss * 100, cmp.outcome.rawValue))
            if cmp.outcome == .improved {
                if bestAny == nil || a < bestAny!.1 { bestAny = (t, a, loss) }
                if loss <= tolerance { eligible.append((t, a)) }
            }
        }
        if let best = eligible.min(by: { $0.1 < $1.1 }) {
            return TuningDecision(chosen: best.0.settings, rationale: "Meilleure latence sous charge mesurée avec une perte de débit dans la tolérance de \(Int(tolerance * 100)) %.",
                                  warning: nil, perTrial: lines)
        }
        if let b = bestAny {
            return TuningDecision(chosen: nil, rationale: "Aucun réglage n’améliore la latence sans dépasser la tolérance de perte de débit.",
                                  warning: String(format: "Le réglage ↓ %d kbit/s réduit la latence ajoutée à %@ mais coûte %.0f %% de débit : à décider par vous.", b.0.settings.downloadKbps, Units.ms(b.1), b.2 * 100),
                                  perTrial: lines)
        }
        return TuningDecision(chosen: nil, rationale: "Aucune amélioration confirmée de la latence sous charge : SQM n’apporte pas de gain démontré sur ce réseau.", warning: nil, perTrial: lines)
    }
}

// MARK: - Router QoS optimizer

public struct RouterTuningState: Codable, Hashable, Sendable {
    public var adapterID: String?
    public var routerName: String?
    /// nil = SQM not readable (adapter without SQM support or sqm-scripts absent).
    public var sqm: [SQMSettings]?
    public var sqmUnavailableReason: String?
    public var canWriteSQM: Bool
    public var wifiClientNames: [String]
    public var allClientCount: Int

    public init(adapterID: String? = nil, routerName: String? = nil, sqm: [SQMSettings]? = nil, sqmUnavailableReason: String? = nil,
                canWriteSQM: Bool = false, wifiClientNames: [String] = [], allClientCount: Int = 0) {
        self.adapterID = adapterID; self.routerName = routerName; self.sqm = sqm; self.sqmUnavailableReason = sqmUnavailableReason
        self.canWriteSQM = canWriteSQM; self.wifiClientNames = wifiClientNames; self.allClientCount = allClientCount
    }
}

public enum RouterQoSOptimizer {
    public static func candidates(state: RouterTuningState, baseline: [BoostSample], profile: BoostProfile) -> [BoostCandidate] {
        let addedLat = Stats.median(BufferbloatTuningService.added(baseline))
        let bloat = (addedLat ?? 0) >= Thresholds.bloatMild
        let dl = Stats.median(baseline.compactMap(\.downloadBps)), ul = Stats.median(baseline.compactMap(\.uploadBps))
        var out: [BoostCandidate] = []
        let affected = ["Tous les appareils du réseau (\(state.allClientCount) déclarés par le routeur) : le débit Internet total sera plafonné"]
        if let sqm = state.sqm, let first = sqm.first, state.canWriteSQM, let dl, let ul, bloat || profile == .ultraLowLatency {
            let proposal = BufferbloatTuningService.candidates(base: first, measuredDownBps: dl, measuredUpBps: ul)[1] // 90 %
            out.append(BoostCandidate(id: "router-sqm", title: first.enabled ? "Ajuster SQM (CAKE) sur le routeur" : "Activer SQM (CAKE) sur le routeur",
                                      detail: "Avant : \(first.summary). Après : \(proposal.summary). Appliqué via rpcd avec retour arrière automatique du routeur si la confirmation n’arrive pas. Le réglage fin (95/90/85 %) est testé par l’auto-tuning.",
                                      evidence: [addedLat.map { "Latence ajoutée sous charge mesurée : \(Units.ms($0))" } ?? "Latence sous charge non mesurée",
                                                 "Débit de référence ↓ \(Units.bitRate(dl)) / ↑ \(Units.bitRate(ul))"],
                                      category: .latency, targets: [.loadedLatency, .jitter], expectedGain: bloat ? .high : .low, risk: .medium, reversible: true,
                                      safety: .sensitive, action: .routerSQM(proposal), affected: affected,
                                      tradeoffs: ["Débit maximal réduit d’environ 5 à 15 % (plafond volontaire sous le débit réel)"]))
        } else if bloat {
            let reason = state.sqmUnavailableReason ?? "Aucune intégration routeur ne permet de régler la QoS/SQM."
            out.append(BoostCandidate(id: "router-qos-guided", title: "Activer la QoS / SQM de la box (si elle la propose)",
                                      detail: "\(reason) Si votre box propose une QoS « intelligente », fq_codel ou CAKE, activez-la avec une limite de 90 à 95 % du débit mesuré (\(dl.map(Units.bitRate) ?? "—") / \(ul.map(Units.bitRate) ?? "—")).",
                                      evidence: [addedLat.map { "Latence ajoutée sous charge : \(Units.ms($0))" } ?? ""], category: .latency,
                                      targets: [.loadedLatency, .jitter], expectedGain: .medium, risk: .low, reversible: true, safety: .readOnly,
                                      action: .guided(steps: ["Ouvrir l’interface de la box", "Activer la QoS/SQM avec 90–95 % du débit mesuré", "Relancer « Vérifier »"]),
                                      affected: affected, tradeoffs: ["Légère baisse du débit maximal"], status: .guided))
        }
        if profile == .streaming || profile == .ultraLowLatency {
            out.append(BoostCandidate(id: "router-priority-guided", title: "Prioriser ce Mac dans la QoS de la box (si disponible)",
                                      detail: "Aucun adaptateur implémenté n’expose une priorisation par appareil via une API officielle : réglage à faire dans l’interface de la box si elle le propose.",
                                      evidence: [], category: .router, targets: [.jitter, .loadedLatency], expectedGain: .low, risk: .low, reversible: true,
                                      safety: .readOnly, action: .guided(steps: ["Interface de la box → QoS / priorité des appareils", "Vérifier"]),
                                      affected: ["Les autres appareils peuvent être ralentis pendant les transferts de ce Mac"], status: .guided))
        }
        return out
    }
}

// MARK: - Candidate evaluator

public enum BoostCandidateEvaluator {
    static func gainWeight(_ c: Confidence) -> Double { switch c { case .high: return 3; case .medium: return 2; case .low: return 1; case .none: return 0.3 } }
    static func riskPenalty(_ r: RiskLevel) -> Double { switch r { case .none: return 0; case .low: return 0.2; case .medium: return 0.6; case .high: return 1.2 } }

    public static func targets(for impact: ImpactKind) -> [BoostMetric] {
        switch impact {
        case .latency: return [.loadedLatency, .idleLatency, .jitter]
        case .throughput: return [.download, .upload]
        case .stability: return [.jitter, .loss]
        case .security, .diagnosis: return []
        }
    }

    /// Guided candidates derived from the diagnostics engine recommendations (no duplicates with engine ids).
    public static func fromDiagnostics(_ report: DiagnosticReport) -> [BoostCandidate] {
        report.hypotheses.filter { $0.cause != .insufficientData }.flatMap { h in
            h.recommendations.filter { $0.impact != .diagnosis && $0.impact != .security }.map { r in
                BoostCandidate(id: "diag-\(r.id)", title: r.title, detail: r.detail, evidence: h.supporting, category: .stack,
                               targets: targets(for: r.impact), expectedGain: min(r.expectedEffectiveness, h.confidence), risk: r.risk,
                               reversible: r.reversible, safety: .readOnly, action: .guided(steps: [r.detail, "Relancer « Vérifier »"]), status: .guided)
            }
        }
    }

    public static func rank(_ all: [BoostCandidate], profile: BoostProfile, weakest: [BoostMetric] = []) -> [BoostCandidate] {
        var seen = Set<String>()
        // Engine candidates take precedence over overlapping generic diagnostics ones.
        let overlap: [String: String] = ["diag-move-closer": "wifi-position", "diag-use-ethernet": "use-ethernet", "diag-change-channel": "wifi-channel",
                                         "diag-enable-sqm": "router-sqm", "diag-replace-cable": "eth-cable", "diag-dns-change": "dns", "diag-use-5ghz": "wifi-band"]
        let ids = Set(all.map(\.id))
        let filtered = all.filter { c in
            if let o = overlap[c.id], ids.contains(o) || ids.contains(where: { $0.hasPrefix(o) }) || (o == "router-sqm" && ids.contains("router-qos-guided")) { return false }
            return seen.insert(c.id).inserted
        }
        return filtered.map { c in
            var x = c
            let rel: Double
            if profile == .smartAuto {
                rel = 0.7 + (c.targets.contains(where: weakest.contains) ? 0.3 : 0)
            } else if c.targets.contains(where: profile.primaryMetrics.contains) { rel = 1 }
            else if c.targets.contains(where: profile.guardMetrics.contains) { rel = 0.4 }
            else { rel = 0.2 }
            x.priority = gainWeight(c.expectedGain) * rel - riskPenalty(c.risk) + (c.action.isAutomatable ? 0.1 : 0)
            return x
        }.sorted { $0.priority > $1.priority }
    }
}
