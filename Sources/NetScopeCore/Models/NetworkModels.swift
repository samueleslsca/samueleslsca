import Foundation

// MARK: - Interfaces & connection

public enum InterfaceKind: String, Codable, CaseIterable, Sendable {
    case wifi, ethernet, vpn, cellular, loopback, bridge, other

    public var label: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .ethernet: return "Ethernet"
        case .vpn: return "VPN / tunnel"
        case .cellular: return "Cellulaire"
        case .loopback: return "Boucle locale"
        case .bridge: return "Pont"
        case .other: return "Autre"
        }
    }
}

public struct NetworkInterfaceInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String { bsdName }
    public var bsdName: String
    public var displayName: String?
    public var kind: InterfaceKind
    public var macAddress: String?
    public var ipv4: [IPv4Assignment]
    public var ipv6: [String]
    public var isUp: Bool
    public var isRunning: Bool
    public var mtu: Int?
    /// Negotiated media, e.g. "1000baseT <full-duplex>" (Ethernet).
    public var media: String?

    public init(bsdName: String, displayName: String? = nil, kind: InterfaceKind, macAddress: String? = nil,
                ipv4: [IPv4Assignment] = [], ipv6: [String] = [], isUp: Bool = false, isRunning: Bool = false,
                mtu: Int? = nil, media: String? = nil) {
        self.bsdName = bsdName
        self.displayName = displayName
        self.kind = kind
        self.macAddress = macAddress
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.isUp = isUp
        self.isRunning = isRunning
        self.mtu = mtu
        self.media = media
    }

    /// Global (non link-local) IPv6 addresses.
    public var globalIPv6: [String] {
        ipv6.filter { !$0.lowercased().hasPrefix("fe80") && $0 != "::1" }
    }
}

public struct RouteEntry: Codable, Hashable, Sendable {
    public var destination: String
    public var gateway: String
    public var flags: String
    public var interface: String
    public var isIPv6: Bool

    public init(destination: String, gateway: String, flags: String, interface: String, isIPv6: Bool) {
        self.destination = destination
        self.gateway = gateway
        self.flags = flags
        self.interface = interface
        self.isIPv6 = isIPv6
    }

    public var isDefault: Bool { destination == "default" || destination == "0.0.0.0/0" || destination == "::/0" }
}

public struct DNSConfiguration: Codable, Hashable, Sendable {
    public struct Resolver: Codable, Hashable, Sendable {
        public var index: Int
        public var domain: String?
        public var nameservers: [String]
        public var interface: String?
        public var isScoped: Bool
        public init(index: Int, domain: String?, nameservers: [String], interface: String?, isScoped: Bool) {
            self.index = index; self.domain = domain; self.nameservers = nameservers
            self.interface = interface; self.isScoped = isScoped
        }
    }
    public var resolvers: [Resolver]
    public init(resolvers: [Resolver]) { self.resolvers = resolvers }

    /// Nameservers used for unqualified/general queries (resolvers without a dedicated domain).
    public var primaryNameservers: [String] {
        var seen = Set<String>()
        return resolvers.filter { $0.domain == nil && !$0.isScoped }
            .flatMap(\.nameservers)
            .filter { seen.insert($0).inserted }
    }
}

public enum ProxyKind: String, Codable, Sendable { case http, https, socks, pac, autoDiscovery }

public struct ProxyStatus: Codable, Hashable, Sendable {
    public var enabled: [ProxyKind]
    public init(enabled: [ProxyKind]) { self.enabled = enabled }
    public var isActive: Bool { !enabled.isEmpty }
}

/// A snapshot of the Mac's current connectivity.
public struct ConnectionSnapshot: Codable, Hashable, Sendable {
    public var timestamp: Date
    public var isConnected: Bool
    public var primaryInterface: NetworkInterfaceInfo?
    public var interfaces: [NetworkInterfaceInfo]
    public var defaultGatewayIPv4: String?
    public var defaultGatewayIPv6: String?
    public var dns: DNSConfiguration?
    public var vpnActive: Bool
    public var vpnInterfaces: [String]
    public var proxy: ProxyStatus?
    /// Public IP — only populated when the user explicitly allowed an external lookup.
    public var publicIP: Sourced<String>

    public init(timestamp: Date = Date(), isConnected: Bool, primaryInterface: NetworkInterfaceInfo?,
                interfaces: [NetworkInterfaceInfo], defaultGatewayIPv4: String?, defaultGatewayIPv6: String?,
                dns: DNSConfiguration?, vpnActive: Bool, vpnInterfaces: [String], proxy: ProxyStatus?,
                publicIP: Sourced<String> = .unavailable("Vérification externe non autorisée")) {
        self.timestamp = timestamp
        self.isConnected = isConnected
        self.primaryInterface = primaryInterface
        self.interfaces = interfaces
        self.defaultGatewayIPv4 = defaultGatewayIPv4
        self.defaultGatewayIPv6 = defaultGatewayIPv6
        self.dns = dns
        self.vpnActive = vpnActive
        self.vpnInterfaces = vpnInterfaces
        self.proxy = proxy
        self.publicIP = publicIP
    }
}

// MARK: - Wi-Fi

public enum WiFiBand: String, Codable, CaseIterable, Sendable {
    case ghz2_4 = "2.4 GHz", ghz5 = "5 GHz", ghz6 = "6 GHz", unknown = "Inconnue"

    /// Band inferred from channel number when the API does not expose it.
    /// Channels 1–14 are 2.4 GHz; 6 GHz channels overlap numerically with 5 GHz so we never infer 6 GHz.
    public static func inferred(fromChannel channel: Int) -> WiFiBand {
        if (1...14).contains(channel) { return .ghz2_4 }
        if (32...177).contains(channel) { return .ghz5 }
        return .unknown
    }
}

public enum WiFiStandard: String, Codable, CaseIterable, Sendable {
    case a = "802.11a", b = "802.11b", g = "802.11g"
    case n = "Wi-Fi 4 (802.11n)", ac = "Wi-Fi 5 (802.11ac)", ax = "Wi-Fi 6/6E (802.11ax)", be = "Wi-Fi 7 (802.11be)"
    case unknown = "Inconnue"
}

public enum WiFiSecurity: String, Codable, CaseIterable, Sendable {
    case open = "Ouvert", wep = "WEP", wpaPersonal = "WPA Personnel", wpa2Personal = "WPA2 Personnel"
    case wpa3Personal = "WPA3 Personnel", wpa2wpa3Transition = "WPA2/WPA3 transition"
    case wpaEnterprise = "WPA Entreprise", wpa2Enterprise = "WPA2 Entreprise", wpa3Enterprise = "WPA3 Entreprise"
    case owe = "OWE (Enhanced Open)", unknown = "Inconnue"

    public var isObsolete: Bool { self == .wep || self == .wpaPersonal || self == .wpaEnterprise }
    public var isOpen: Bool { self == .open }
}

public struct WiFiSnapshot: Codable, Hashable, Sendable {
    public var timestamp: Date
    public var interfaceName: String
    public var poweredOn: Bool
    public var ssid: Sourced<String>
    public var bssid: Sourced<String>
    public var rssi: Sourced<Int>
    public var noise: Sourced<Int>
    public var channel: Sourced<Int>
    public var band: Sourced<WiFiBand>
    public var channelWidthMHz: Sourced<Int>
    public var txRateMbps: Sourced<Double>
    public var standard: Sourced<WiFiStandard>
    public var security: Sourced<WiFiSecurity>
    public var countryCode: Sourced<String>

    public init(timestamp: Date = Date(), interfaceName: String, poweredOn: Bool,
                ssid: Sourced<String>, bssid: Sourced<String>, rssi: Sourced<Int>, noise: Sourced<Int>,
                channel: Sourced<Int>, band: Sourced<WiFiBand>, channelWidthMHz: Sourced<Int>,
                txRateMbps: Sourced<Double>, standard: Sourced<WiFiStandard>, security: Sourced<WiFiSecurity>,
                countryCode: Sourced<String> = .unavailable("Non exposé")) {
        self.timestamp = timestamp; self.interfaceName = interfaceName; self.poweredOn = poweredOn
        self.ssid = ssid; self.bssid = bssid; self.rssi = rssi; self.noise = noise
        self.channel = channel; self.band = band; self.channelWidthMHz = channelWidthMHz
        self.txRateMbps = txRateMbps; self.standard = standard; self.security = security
        self.countryCode = countryCode
    }

    /// SNR = RSSI − noise (both in dBm). Only computed when both values were measured.
    public var snr: Sourced<Int> {
        guard let r = rssi.value, let n = noise.value else {
            return .unavailable("RSSI ou bruit indisponible")
        }
        // A noise floor at 0 dBm or above is not physical: treat as unavailable.
        guard n < 0 else { return .unavailable("Valeur de bruit invalide (\(n) dBm)") }
        return Sourced(r - n, .computed(formula: "SNR = RSSI − bruit"), at: timestamp)
    }
}

public struct WiFiNeighbor: Codable, Hashable, Identifiable, Sendable {
    public var id: String { (bssid ?? "?") + "-\(channel)-\(ssid ?? "")" }
    public var ssid: String?
    public var bssid: String?
    public var rssi: Int
    public var noise: Int?
    public var channel: Int
    public var band: WiFiBand
    public var channelWidthMHz: Int?
    public var security: WiFiSecurity?

    public init(ssid: String?, bssid: String?, rssi: Int, noise: Int?, channel: Int, band: WiFiBand,
                channelWidthMHz: Int?, security: WiFiSecurity?) {
        self.ssid = ssid; self.bssid = bssid; self.rssi = rssi; self.noise = noise
        self.channel = channel; self.band = band; self.channelWidthMHz = channelWidthMHz; self.security = security
    }
}

// MARK: - Latency

public struct LatencyStats: Codable, Hashable, Sendable {
    public var target: String
    public var sent: Int
    public var received: Int
    public var samplesMs: [Double]
    public var method: String
    public var timestamp: Date

    public init(target: String, sent: Int, received: Int, samplesMs: [Double], method: String, timestamp: Date = Date()) {
        self.target = target; self.sent = sent; self.received = received
        self.samplesMs = samplesMs; self.method = method; self.timestamp = timestamp
    }

    public var lossPercent: Double {
        guard sent > 0 else { return 0 }
        return max(0, Double(sent - received)) / Double(sent) * 100
    }
    public var minMs: Double? { samplesMs.min() }
    public var maxMs: Double? { samplesMs.max() }
    public var avgMs: Double? { Stats.mean(samplesMs) }
    public var medianMs: Double? { Stats.percentile(samplesMs, 50) }
    public var p95Ms: Double? { Stats.percentile(samplesMs, 95) }
    /// Jitter as mean absolute difference between consecutive samples (RFC 3550-style, unsmoothed).
    public var jitterMs: Double? { Stats.meanAbsoluteConsecutiveDifference(samplesMs) }
}

// MARK: - DNS

public struct DNSQueryResult: Codable, Hashable, Sendable {
    public var resolver: String
    public var name: String
    public var success: Bool
    public var responseCode: Int?
    public var durationMs: Double?
    public var answers: [String]
    public var error: String?
    public var timestamp: Date

    public init(resolver: String, name: String, success: Bool, responseCode: Int?, durationMs: Double?,
                answers: [String], error: String?, timestamp: Date = Date()) {
        self.resolver = resolver; self.name = name; self.success = success; self.responseCode = responseCode
        self.durationMs = durationMs; self.answers = answers; self.error = error; self.timestamp = timestamp
    }
}

// MARK: - Events

public enum NetworkEventKind: String, Codable, CaseIterable, Sendable {
    case connectivityLost, connectivityRestored, interfaceChanged, ssidChanged, bssidChanged
    case gatewayChanged, dnsChanged, vpnStateChanged, newDevice, outageStart, outageEnd
    case dnsFailure, highLoss, highLatency, routerAction, speedtest, alert

    public var label: String {
        switch self {
        case .connectivityLost: return "Connectivité perdue"
        case .connectivityRestored: return "Connectivité rétablie"
        case .interfaceChanged: return "Changement d’interface"
        case .ssidChanged: return "Changement de SSID"
        case .bssidChanged: return "Changement de point d’accès"
        case .gatewayChanged: return "Changement de passerelle"
        case .dnsChanged: return "Changement DNS"
        case .vpnStateChanged: return "État VPN modifié"
        case .newDevice: return "Nouvel appareil"
        case .outageStart: return "Début de coupure"
        case .outageEnd: return "Fin de coupure"
        case .dnsFailure: return "Échec DNS"
        case .highLoss: return "Pertes élevées"
        case .highLatency: return "Latence élevée"
        case .routerAction: return "Action routeur"
        case .speedtest: return "Test de débit"
        case .alert: return "Alerte"
        }
    }
}

public struct NetworkEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var kind: NetworkEventKind
    public var message: String
    public var details: [String: String]

    public init(id: UUID = UUID(), timestamp: Date = Date(), kind: NetworkEventKind, message: String,
                details: [String: String] = [:]) {
        self.id = id; self.timestamp = timestamp; self.kind = kind; self.message = message; self.details = details
    }
}
