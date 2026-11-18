import Foundation

public enum DeviceCategory: String, Codable, CaseIterable, Sendable {
    case computer, phone, tablet, tv, printer, console, iot, router, accessPoint, speaker, nas, camera, watch, unknown

    public var label: String {
        switch self {
        case .computer: return "Ordinateur"
        case .phone: return "Téléphone"
        case .tablet: return "Tablette"
        case .tv: return "TV / boîtier"
        case .printer: return "Imprimante"
        case .console: return "Console"
        case .iot: return "Objet connecté"
        case .router: return "Routeur / box"
        case .accessPoint: return "Point d’accès / répéteur"
        case .speaker: return "Enceinte"
        case .nas: return "Stockage réseau"
        case .camera: return "Caméra"
        case .watch: return "Montre"
        case .unknown: return "Inconnu"
        }
    }

    public var symbol: String {
        switch self {
        case .computer: return "desktopcomputer"
        case .phone: return "iphone"
        case .tablet: return "ipad"
        case .tv: return "appletv"
        case .printer: return "printer"
        case .console: return "gamecontroller"
        case .iot: return "sensor"
        case .router: return "wifi.router"
        case .accessPoint: return "antenna.radiowaves.left.and.right"
        case .speaker: return "hifispeaker"
        case .nas: return "externaldrive.connected.to.line.below"
        case .camera: return "web.camera"
        case .watch: return "applewatch"
        case .unknown: return "questionmark.circle"
        }
    }
}

public enum DiscoveryMethod: String, Codable, CaseIterable, Sendable {
    case arpCache = "Cache ARP"
    case ndpCache = "Cache voisins IPv6 (NDP)"
    case bonjour = "Bonjour / mDNS"
    case router = "API du routeur"
    case activeProbe = "Sondage actif autorisé"
    case selfDevice = "Ce Mac"
    case gateway = "Passerelle par défaut"
}

public enum TrustState: String, Codable, CaseIterable, Sendable {
    case unreviewed, known, toReview

    public var label: String {
        switch self {
        case .unreviewed: return "Non examiné"
        case .known: return "Appareil connu"
        case .toReview: return "À examiner"
        }
    }
}

/// What we currently observe about a device. "Not responding" never means "disconnected".
public enum ObservationState: String, Codable, Sendable {
    case activeNow = "Observé récemment"
    case reportedByRouter = "Déclaré actif par le routeur"
    case notRecentlySeen = "Non observé récemment"
    case reportedInactive = "Déclaré inactif par le routeur"
}

/// A single raw observation from one discovery source.
public struct DeviceObservation: Codable, Hashable, Sendable {
    public var method: DiscoveryMethod
    public var timestamp: Date
    public var ip: String?
    public var ipv6: String?
    public var mac: String?
    public var hostname: String?
    public var interface: String?
    public var services: [String]
    public var vendorHint: String?
    public var modelHint: String?
    public var routerActive: Bool?
    public var routerConnectionType: String?

    public init(method: DiscoveryMethod, timestamp: Date = Date(), ip: String? = nil, ipv6: String? = nil,
                mac: String? = nil, hostname: String? = nil, interface: String? = nil, services: [String] = [],
                vendorHint: String? = nil, modelHint: String? = nil, routerActive: Bool? = nil,
                routerConnectionType: String? = nil) {
        self.method = method; self.timestamp = timestamp; self.ip = ip; self.ipv6 = ipv6
        self.mac = mac.flatMap(MACAddress.normalize); self.hostname = hostname; self.interface = interface
        self.services = services; self.vendorHint = vendorHint; self.modelHint = modelHint
        self.routerActive = routerActive; self.routerConnectionType = routerConnectionType
    }
}

public struct NetworkDevice: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var mac: String?
    public var ipv4: String?
    public var ipv6: [String]
    public var hostnames: [String]
    public var userLabel: String?
    public var category: DeviceCategory
    public var categoryConfidence: Confidence
    public var categoryEvidence: [String]
    public var vendor: String?
    public var vendorProvenance: Provenance?
    public var services: [String]
    public var interface: String?
    public var firstSeen: Date
    public var lastSeen: Date
    public var methods: [DiscoveryMethod]
    public var trust: TrustState
    public var isRandomizedMAC: Bool
    public var routerActive: Bool?
    public var routerConnectionType: String?
    public var appearances: [Date]

    public init(id: UUID = UUID(), mac: String?, ipv4: String?, ipv6: [String] = [], hostnames: [String] = [],
                userLabel: String? = nil, category: DeviceCategory = .unknown, categoryConfidence: Confidence = .none,
                categoryEvidence: [String] = [], vendor: String? = nil, vendorProvenance: Provenance? = nil,
                services: [String] = [], interface: String? = nil, firstSeen: Date, lastSeen: Date,
                methods: [DiscoveryMethod], trust: TrustState = .unreviewed, isRandomizedMAC: Bool = false,
                routerActive: Bool? = nil, routerConnectionType: String? = nil, appearances: [Date] = []) {
        self.id = id; self.mac = mac; self.ipv4 = ipv4; self.ipv6 = ipv6; self.hostnames = hostnames
        self.userLabel = userLabel; self.category = category; self.categoryConfidence = categoryConfidence
        self.categoryEvidence = categoryEvidence; self.vendor = vendor; self.vendorProvenance = vendorProvenance
        self.services = services; self.interface = interface; self.firstSeen = firstSeen; self.lastSeen = lastSeen
        self.methods = methods; self.trust = trust; self.isRandomizedMAC = isRandomizedMAC
        self.routerActive = routerActive; self.routerConnectionType = routerConnectionType; self.appearances = appearances
    }

    /// Display name: user label > best hostname > vendor-based neutral label > IP. Never an invented identity.
    public var displayName: String {
        if let l = userLabel, !l.isEmpty { return l }
        if let h = hostnames.first(where: { !$0.isEmpty }) { return h }
        if let v = vendor { return "Appareil \(v)" }
        return ipv4 ?? ipv6.first ?? mac ?? "Appareil non identifié"
    }

    public func observationState(now: Date = Date(), recentWindow: TimeInterval = 600) -> ObservationState {
        if let a = routerActive { return a ? .reportedByRouter : .reportedInactive }
        return now.timeIntervalSince(lastSeen) <= recentWindow ? .activeNow : .notRecentlySeen
    }
}

/// IEEE OUI registry lookup. NetScope does not ship a vendor database; the user may import the
/// public IEEE `oui.csv` (Registry,Assignment,Organization Name,Organization Address).
public struct OUIDatabase: Sendable {
    public private(set) var vendors: [String: String]
    public init(vendors: [String: String] = [:]) { self.vendors = vendors }

    public static func parseIEEECSV(_ text: String) -> OUIDatabase {
        var map: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline).dropFirst() {
            let cols = CSV.parseLine(String(raw))
            guard cols.count >= 3 else { continue }
            let key = cols[1].uppercased()
            guard key.count == 6 else { continue }
            map[key] = cols[2].trimmingCharacters(in: .whitespaces)
        }
        return OUIDatabase(vendors: map)
    }

    public func vendor(for mac: String) -> String? {
        guard !MACAddress.isLocallyAdministered(mac), let k = MACAddress.ouiKey(mac) else { return nil }
        return vendors[k]
    }

    public var isEmpty: Bool { vendors.isEmpty }
}

/// Heuristic classification from observable evidence only (Bonjour services, hostnames, router-reported type).
public enum DeviceClassifier {
    struct Rule { let category: DeviceCategory; let weight: Int; let reason: String }

    static let serviceRules: [String: Rule] = [
        "_ipp._tcp": Rule(category: .printer, weight: 3, reason: "Annonce le service d’impression IPP"),
        "_ipps._tcp": Rule(category: .printer, weight: 3, reason: "Annonce le service d’impression IPPS"),
        "_printer._tcp": Rule(category: .printer, weight: 3, reason: "Annonce le service LPD"),
        "_pdl-datastream._tcp": Rule(category: .printer, weight: 3, reason: "Annonce un flux d’impression"),
        "_scanner._tcp": Rule(category: .printer, weight: 2, reason: "Annonce un service de numérisation"),
        "_googlecast._tcp": Rule(category: .tv, weight: 2, reason: "Annonce Google Cast"),
        "_airplay._tcp": Rule(category: .tv, weight: 1, reason: "Annonce AirPlay (TV, enceinte ou Mac)"),
        "_raop._tcp": Rule(category: .speaker, weight: 1, reason: "Annonce AirPlay audio (RAOP)"),
        "_spotify-connect._tcp": Rule(category: .speaker, weight: 1, reason: "Annonce Spotify Connect"),
        "_sonos._tcp": Rule(category: .speaker, weight: 3, reason: "Annonce le service Sonos"),
        "_hap._tcp": Rule(category: .iot, weight: 3, reason: "Accessoire HomeKit (HAP)"),
        "_hap._udp": Rule(category: .iot, weight: 3, reason: "Accessoire HomeKit (HAP/Thread)"),
        "_matter._tcp": Rule(category: .iot, weight: 3, reason: "Appareil Matter"),
        "_matterc._udp": Rule(category: .iot, weight: 3, reason: "Appareil Matter (mise en service)"),
        "_smb._tcp": Rule(category: .computer, weight: 1, reason: "Partage de fichiers SMB"),
        "_afpovertcp._tcp": Rule(category: .nas, weight: 2, reason: "Partage AFP"),
        "_adisk._tcp": Rule(category: .nas, weight: 2, reason: "Disque Time Machine réseau"),
        "_ssh._tcp": Rule(category: .computer, weight: 1, reason: "Service SSH annoncé"),
        "_sftp-ssh._tcp": Rule(category: .computer, weight: 1, reason: "Service SFTP annoncé"),
        "_workstation._tcp": Rule(category: .computer, weight: 2, reason: "Annonce de poste de travail"),
        "_companion-link._tcp": Rule(category: .phone, weight: 1, reason: "Appareil Apple (Companion Link)"),
        "_apple-mobdev2._tcp": Rule(category: .phone, weight: 2, reason: "Appareil mobile Apple"),
        "_fbx-api._tcp": Rule(category: .router, weight: 4, reason: "API Freebox annoncée"),
        "_airport._tcp": Rule(category: .accessPoint, weight: 3, reason: "Borne AirPort"),
        "_rtsp._tcp": Rule(category: .camera, weight: 1, reason: "Flux vidéo RTSP annoncé"),
    ]

    static let hostnameRules: [(String, DeviceCategory, String)] = [
        ("iphone", .phone, "Le nom d’hôte contient « iPhone »"),
        ("android", .phone, "Le nom d’hôte contient « android »"),
        ("galaxy", .phone, "Le nom d’hôte contient « Galaxy »"),
        ("pixel", .phone, "Le nom d’hôte contient « Pixel »"),
        ("ipad", .tablet, "Le nom d’hôte contient « iPad »"),
        ("macbook", .computer, "Le nom d’hôte contient « MacBook »"),
        ("imac", .computer, "Le nom d’hôte contient « iMac »"),
        ("mac-mini", .computer, "Le nom d’hôte contient « Mac mini »"),
        ("macmini", .computer, "Le nom d’hôte contient « Mac mini »"),
        ("desktop-", .computer, "Nom d’hôte Windows par défaut (DESKTOP-)"),
        ("laptop-", .computer, "Nom d’hôte Windows par défaut (LAPTOP-)"),
        ("appletv", .tv, "Le nom d’hôte contient « Apple TV »"),
        ("apple-tv", .tv, "Le nom d’hôte contient « Apple TV »"),
        ("chromecast", .tv, "Le nom d’hôte contient « Chromecast »"),
        ("playstation", .console, "Le nom d’hôte contient « PlayStation »"),
        ("ps4", .console, "Le nom d’hôte contient « PS4 »"),
        ("ps5", .console, "Le nom d’hôte contient « PS5 »"),
        ("xbox", .console, "Le nom d’hôte contient « Xbox »"),
        ("nintendo", .console, "Le nom d’hôte contient « Nintendo »"),
        ("switch", .console, "Le nom d’hôte contient « Switch »"),
        ("watch", .watch, "Le nom d’hôte contient « Watch »"),
        ("printer", .printer, "Le nom d’hôte contient « printer »"),
        ("epson", .printer, "Le nom d’hôte contient « Epson »"),
        ("brother", .printer, "Le nom d’hôte contient « Brother »"),
        ("hp", .unknown, ""),
        ("synology", .nas, "Le nom d’hôte contient « Synology »"),
        ("diskstation", .nas, "Le nom d’hôte contient « DiskStation »"),
        ("qnap", .nas, "Le nom d’hôte contient « QNAP »"),
        ("freebox", .router, "Le nom d’hôte contient « Freebox »"),
        ("livebox", .router, "Le nom d’hôte contient « Livebox »"),
        ("fritz", .router, "Le nom d’hôte contient « FRITZ »"),
        ("repeater", .accessPoint, "Le nom d’hôte contient « repeater »"),
        ("sonos", .speaker, "Le nom d’hôte contient « Sonos »"),
        ("homepod", .speaker, "Le nom d’hôte contient « HomePod »"),
        ("echo", .speaker, "Le nom d’hôte contient « Echo »"),
        ("camera", .camera, "Le nom d’hôte contient « camera »"),
        ("cam-", .camera, "Le nom d’hôte contient « cam- »"),
    ]

    /// Router-reported types (Freebox `host_type`, OpenWrt hints, …) mapped to categories.
    static let routerTypeRules: [String: DeviceCategory] = [
        "workstation": .computer, "laptop": .computer, "smartphone": .phone, "tablet": .tablet,
        "printer": .printer, "television": .tv, "multimedia_device": .tv, "vg_console": .console,
        "freebox_player": .tv, "freebox_hd": .tv, "freebox_mini": .tv, "freebox_delta": .router,
        "freebox_wifi": .accessPoint, "repeater": .accessPoint, "networking_device": .router,
        "nas": .nas, "ip_camera": .camera, "car": .iot, "other": .unknown, "ip_phone": .phone,
    ]

    public static func classify(hostnames: [String], services: [String], routerType: String?, isGateway: Bool)
        -> (DeviceCategory, Confidence, [String]) {
        var scores: [DeviceCategory: Int] = [:]
        var evidence: [String] = []
        if isGateway { scores[.router, default: 0] += 5; evidence.append("Adresse de la passerelle par défaut") }
        if let rt = routerType?.lowercased(), let cat = routerTypeRules[rt], cat != .unknown {
            scores[cat, default: 0] += 4; evidence.append("Type déclaré par le routeur : \(rt)")
        }
        for s in services {
            if let r = serviceRules[s] { scores[r.category, default: 0] += r.weight; evidence.append(r.reason) }
        }
        for h in hostnames {
            let lower = h.lowercased()
            for (needle, cat, reason) in hostnameRules where cat != .unknown && lower.contains(needle) {
                scores[cat, default: 0] += 2; evidence.append(reason)
            }
        }
        guard let (best, score) = scores.max(by: { $0.value < $1.value }), score > 0 else {
            return (.unknown, .none, ["Données insuffisantes pour identifier le type d’appareil"])
        }
        // Competing categories with similar scores lower the confidence.
        let runnerUp = scores.filter { $0.key != best }.map(\.value).max() ?? 0
        let confidence: Confidence
        if score >= 4 && score - runnerUp >= 2 { confidence = .high }
        else if score >= 2 && score > runnerUp { confidence = .medium }
        else { confidence = .low }
        return (best, confidence, Array(NSOrderedSet(array: evidence)) as? [String] ?? evidence)
    }
}

/// Merges observations from all discovery sources into a deduplicated inventory.
///
/// Identity key priority: MAC address (unless randomized and changing), then IPv4.
/// A randomized MAC is still a stable key on a given network for modern OSes (per-SSID private address),
/// but we flag it so the UI can explain that the same physical device may appear twice over time.
public struct DeviceInventory: Codable, Sendable {
    public private(set) var devices: [NetworkDevice]
    public init(devices: [NetworkDevice] = []) { self.devices = devices }

    public struct MergeReport: Sendable {
        public var newDevices: [NetworkDevice]
        public var updated: Int
    }

    @discardableResult
    public mutating func merge(_ observations: [DeviceObservation], gatewayIP: String?, oui: OUIDatabase,
                               now: Date = Date()) -> MergeReport {
        var newOnes: [NetworkDevice] = []
        var updated = 0
        for obs in observations {
            if let idx = matchIndex(for: obs) {
                apply(obs, to: &devices[idx], gatewayIP: gatewayIP, oui: oui)
                updated += 1
            } else {
                guard obs.mac != nil || obs.ip != nil || obs.ipv6 != nil else { continue }
                var d = NetworkDevice(mac: obs.mac, ipv4: obs.ip, firstSeen: obs.timestamp, lastSeen: obs.timestamp,
                                      methods: [])
                apply(obs, to: &d, gatewayIP: gatewayIP, oui: oui)
                devices.append(d)
                newOnes.append(d)
            }
        }
        return MergeReport(newDevices: newOnes, updated: updated)
    }

    private func matchIndex(for o: DeviceObservation) -> Int? {
        if let mac = o.mac, let i = devices.firstIndex(where: { $0.mac == mac }) { return i }
        // Only fall back to IP when the observation has no MAC, or the device record has none (avoids merging
        // two different devices that reused the same DHCP lease).
        if let ip = o.ip, let i = devices.firstIndex(where: { $0.ipv4 == ip && ($0.mac == nil || o.mac == nil) }) { return i }
        if let v6 = o.ipv6, let i = devices.firstIndex(where: { $0.ipv6.contains(v6) }) { return i }
        if let h = o.hostname?.lowercased(), o.mac == nil, o.ip == nil,
           let i = devices.firstIndex(where: { $0.hostnames.map { $0.lowercased() }.contains(h) }) { return i }
        return nil
    }

    private func apply(_ o: DeviceObservation, to d: inout NetworkDevice, gatewayIP: String?, oui: OUIDatabase) {
        if d.mac == nil, let m = o.mac { d.mac = m }
        if let ip = o.ip {
            // An IP change for the same MAC is legitimate (new DHCP lease).
            d.ipv4 = ip
        }
        if let v6 = o.ipv6, !d.ipv6.contains(v6) { d.ipv6.append(v6) }
        if let h = o.hostname?.trimmingCharacters(in: .whitespaces), !h.isEmpty, !d.hostnames.contains(h) {
            d.hostnames.append(h)
        }
        for s in o.services where !d.services.contains(s) { d.services.append(s) }
        if !d.methods.contains(o.method) { d.methods.append(o.method) }
        if let iface = o.interface { d.interface = iface }
        if o.timestamp > d.lastSeen {
            // Record a new "appearance" when the device had not been seen for 30 minutes.
            if o.timestamp.timeIntervalSince(d.lastSeen) > 1800 { d.appearances.append(o.timestamp) }
            d.lastSeen = o.timestamp
        }
        if d.appearances.isEmpty { d.appearances.append(d.firstSeen) }
        if let a = o.routerActive { d.routerActive = a }
        if let t = o.routerConnectionType { d.routerConnectionType = t }
        if let m = d.mac { d.isRandomizedMAC = MACAddress.isLocallyAdministered(m) }

        // Vendor: router-provided name wins (it is "fourni par le routeur"), else imported IEEE OUI.
        if let v = o.vendorHint, !v.isEmpty {
            d.vendor = v; d.vendorProvenance = .router(adapter: o.method.rawValue)
        } else if d.vendor == nil, let m = d.mac, let v = oui.vendor(for: m) {
            d.vendor = v; d.vendorProvenance = .estimated(model: "Préfixe OUI IEEE (fabricant de la carte réseau)")
        }
        let isGW = gatewayIP != nil && d.ipv4 == gatewayIP
        let (cat, conf, ev) = DeviceClassifier.classify(hostnames: d.hostnames, services: d.services,
                                                        routerType: o.modelHint, isGateway: isGW)
        if conf >= d.categoryConfidence || d.category == .unknown {
            d.category = cat; d.categoryConfidence = conf; d.categoryEvidence = ev
        }
    }

    public mutating func setLabel(_ label: String?, for id: UUID) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[i].userLabel = label?.trimmingCharacters(in: .whitespaces).isEmpty == true ? nil : label
    }

    public mutating func setTrust(_ t: TrustState, for id: UUID) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[i].trust = t
    }

    public mutating func setCategory(_ c: DeviceCategory, for id: UUID) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[i].category = c; devices[i].categoryConfidence = .high
        devices[i].categoryEvidence = ["Catégorie définie manuellement par l’utilisateur"]
    }

    public mutating func remove(_ id: UUID) { devices.removeAll { $0.id == id } }

    public var unknownDevices: [NetworkDevice] { devices.filter { $0.trust != .known } }

    public func search(_ query: String) -> [NetworkDevice] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return devices }
        return devices.filter { d in
            [d.displayName, d.ipv4 ?? "", d.mac ?? "", d.vendor ?? "", d.category.label]
                .contains { $0.lowercased().contains(q) } || d.hostnames.contains { $0.lowercased().contains(q) }
        }
    }
}
