import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RouterCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let systemInfo = RouterCapabilities(rawValue: 1 << 0)
    public static let listClients = RouterCapabilities(rawValue: 1 << 1)
    public static let clientHistory = RouterCapabilities(rawValue: 1 << 2)
    public static let wanStatus = RouterCapabilities(rawValue: 1 << 3)
    public static let wanTraffic = RouterCapabilities(rawValue: 1 << 4)
    public static let wifiConfig = RouterCapabilities(rawValue: 1 << 5)
    public static let blockDevice = RouterCapabilities(rawValue: 1 << 6)
    public static let scheduleRestriction = RouterCapabilities(rawValue: 1 << 7)
    public static let guestNetwork = RouterCapabilities(rawValue: 1 << 8)
    public static let configBackup = RouterCapabilities(rawValue: 1 << 9)
    public static let perClientTraffic = RouterCapabilities(rawValue: 1 << 10)
    public static let qos = RouterCapabilities(rawValue: 1 << 11)

    public static let all: [(RouterCapabilities, String)] = [
        (.systemInfo, "Informations système"), (.listClients, "Clients connectés"),
        (.clientHistory, "Clients précédemment connectés"), (.wanStatus, "État WAN"),
        (.wanTraffic, "Trafic WAN"), (.wifiConfig, "Paramètres Wi-Fi"),
        (.blockDevice, "Blocage d’appareil"), (.scheduleRestriction, "Restrictions planifiées"),
        (.guestNetwork, "Réseau invité"), (.configBackup, "Sauvegarde de configuration"),
        (.perClientTraffic, "Trafic par client"), (.qos, "QoS / SQM"),
    ]
}

public enum AdapterStatus: String, Codable, Sendable {
    case implemented = "Implémenté"
    case readOnly = "Lecture seule"
    case notImplemented = "Non implémenté"
}

public struct RouterAdapterDescriptor: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var vendors: [String]
    public var status: AdapterStatus
    public var documentation: String
    public var notes: String
    public var declaredCapabilities: RouterCapabilities
}

public struct RouterInfo: Codable, Hashable, Sendable {
    public var adapterID: String
    public var name: String?
    public var model: String?
    public var firmware: String?
    public var uptimeSeconds: Double?
    public var serial: String?
    public var apiVersion: String?
}

public enum RouterLinkType: String, Codable, Sendable { case wifi = "Wi-Fi", ethernet = "Ethernet", unknown = "Inconnu" }

public struct RouterClient: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var mac: String?
    public var ipv4: String?
    public var ipv6: [String]
    public var name: String?
    public var hostType: String?
    public var vendor: String?
    public var active: Bool?
    public var lastSeen: Date?
    public var link: RouterLinkType
    public var rxBytesPerSecond: Double?
    public var txBytesPerSecond: Double?
    public var wifiSignalDbm: Int?
    public var wifiBand: String?
}

public struct WANStatus: Codable, Hashable, Sendable {
    public var state: String?
    public var media: String?
    public var type: String?
    public var ipv4: String?
    public var ipv6: String?
    /// Instantaneous rate reported by the router, converted to bits/s.
    public var currentDownBps: Double?
    public var currentUpBps: Double?
    /// Sync/available bandwidth reported by the router (bits/s).
    public var syncDownBps: Double?
    public var syncUpBps: Double?
    public var totalBytesDown: Double?
    public var totalBytesUp: Double?
}

public struct RouterWiFiNetwork: Codable, Hashable, Sendable {
    public var ssid: String?
    public var band: String?
    public var channel: Int?
    public var channelWidthMHz: Int?
    public var encryption: String?
    public var enabled: Bool?
    public var hidden: Bool?
    public var wpsEnabled: Bool?
    public var isGuest: Bool
}

public struct RouterWiFiReport: Codable, Hashable, Sendable {
    public var networks: [RouterWiFiNetwork]
    public var guestNetworkEnabled: Bool?
    public var macFilterMode: String?
}

public struct AccessRule: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var mac: String
    public var blocked: Bool
    public var comment: String?
    public var scope: String
}

/// Audit trail entry for every administrative action (requirement §18.14).
public struct AdminAuditEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var adapterID: String
    public var action: String
    public var target: String
    public var outcome: String
    public var verified: Bool

    public init(id: UUID = UUID(), timestamp: Date = Date(), adapterID: String, action: String, target: String,
                outcome: String, verified: Bool) {
        self.id = id; self.timestamp = timestamp; self.adapterID = adapterID; self.action = action
        self.target = target; self.outcome = outcome; self.verified = verified
    }
}

public enum RouterError: Error, LocalizedError, Equatable {
    case notDetected
    case notAuthenticated
    case authorizationPending
    case authorizationDenied
    case authorizationTimeout
    case insufficientPermission(String)
    case unsupported(String)
    case api(code: String, message: String)
    case http(Int)
    case transport(String)
    case decoding(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notDetected: return "Aucun routeur compatible détecté sur la passerelle."
        case .notAuthenticated: return "Session routeur non authentifiée."
        case .authorizationPending: return "Autorisation en attente : validez la demande sur l’écran de la box."
        case .authorizationDenied: return "L’autorisation a été refusée sur la box."
        case .authorizationTimeout: return "La demande d’autorisation a expiré."
        case .insufficientPermission(let p): return "Droits insuffisants : la permission « \(p) » doit être accordée à NetScope dans l’interface de la box."
        case .unsupported(let f): return "Fonction non prise en charge par ce routeur ou cet adaptateur : \(f)"
        case .api(let c, let m): return "Erreur de l’API routeur (\(c)) : \(m)"
        case .http(let s): return "Réponse HTTP inattendue du routeur : \(s)"
        case .transport(let m): return "Routeur injoignable : \(m)"
        case .decoding(let m): return "Réponse du routeur illisible : \(m)"
        case .verificationFailed(let m): return "L’action n’a pas pu être vérifiée : \(m)"
        }
    }
}

// MARK: - Transport & secrets

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init(timeout: Double = 8) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        session = URLSession(configuration: cfg)
    }

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            #if canImport(FoundationNetworking)
            return try await withCheckedThrowingContinuation { cont in
                session.dataTask(with: request) { d, r, e in
                    if let e { cont.resume(throwing: RouterError.transport(e.localizedDescription)); return }
                    cont.resume(returning: (d ?? Data(), (r as? HTTPURLResponse)?.statusCode ?? 0))
                }.resume()
            }
            #else
            let (d, r) = try await session.data(for: request)
            return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
            #endif
        } catch let e as RouterError { throw e } catch { throw RouterError.transport(error.localizedDescription) }
    }
}

/// Secrets (router tokens/passwords). macOS implementation uses the Keychain; never logged.
public protocol SecretStore: Sendable {
    func read(_ key: String) -> String?
    func write(_ key: String, value: String) throws
    func delete(_ key: String) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var items: [String: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func read(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return items[key] }
    public func write(_ key: String, value: String) throws { lock.lock(); items[key] = value; lock.unlock() }
    public func delete(_ key: String) throws { lock.lock(); items[key] = nil; lock.unlock() }
}

// MARK: - Adapter protocol

public struct RouterProbeResult: Codable, Hashable, Sendable {
    public var adapterID: String
    public var baseURL: String
    public var model: String?
    public var apiVersion: String?
    public var evidence: String
}

public protocol RouterAdapter: AnyObject, Sendable {
    static var descriptor: RouterAdapterDescriptor { get }
    /// Capabilities effectively available for the current session (may be narrower than declared,
    /// e.g. missing "settings" permission on a Freebox).
    var capabilities: RouterCapabilities { get async }
    var isAuthenticated: Bool { get async }

    func fetchInfo() async throws -> RouterInfo
    func fetchClients() async throws -> [RouterClient]
    func fetchWAN() async throws -> WANStatus
    func fetchWiFi() async throws -> RouterWiFiReport
    func listAccessRules() async throws -> [AccessRule]
    /// Blocks or unblocks a device through the official API, then re-reads the rules to verify.
    func setBlocked(mac: String, blocked: Bool, comment: String) async throws -> AccessRule?
}

public extension RouterAdapter {
    func listAccessRules() async throws -> [AccessRule] { throw RouterError.unsupported("règles d’accès") }
    func setBlocked(mac: String, blocked: Bool, comment: String) async throws -> AccessRule? {
        throw RouterError.unsupported("blocage d’appareil")
    }
    func fetchWiFi() async throws -> RouterWiFiReport { throw RouterError.unsupported("configuration Wi-Fi") }
}

/// Catalogue of supported / planned adapters. Only adapters backed by an official, documented API are implemented.
public enum RouterRegistry {
    public static let descriptors: [RouterAdapterDescriptor] = [
        FreeboxAdapter.descriptor,
        OpenWrtAdapter.descriptor,
        RouterAdapterDescriptor(id: "livebox", name: "Orange Livebox", vendors: ["Orange", "Sagemcom", "Arcadyan"],
            status: .notImplemented, documentation: "Aucune API publique documentée par Orange",
            notes: "Les interfaces locales des Livebox ne sont pas documentées officiellement ; aucune hypothèse n’est faite.",
            declaredCapabilities: []),
        RouterAdapterDescriptor(id: "sfr", name: "Box SFR", vendors: ["SFR"], status: .notImplemented,
            documentation: "Aucune API publique documentée par SFR",
            notes: "Non implémenté faute de documentation officielle.", declaredCapabilities: []),
        RouterAdapterDescriptor(id: "bbox", name: "Bouygues Bbox", vendors: ["Bouygues Telecom"], status: .notImplemented,
            documentation: "API Bbox (api.bbox.fr) publiée par Bouygues Telecom",
            notes: "API documentée existante : adaptateur prévu, non encore développé ni validé.", declaredCapabilities: []),
        RouterAdapterDescriptor(id: "fritzbox", name: "AVM FRITZ!Box", vendors: ["AVM"], status: .notImplemented,
            documentation: "TR-064 (documentation AVM)",
            notes: "Interface TR-064 documentée : adaptateur prévu, non encore développé ni validé.", declaredCapabilities: []),
        RouterAdapterDescriptor(id: "unifi", name: "Ubiquiti UniFi", vendors: ["Ubiquiti"], status: .notImplemented,
            documentation: "UniFi Network Integration API (clé API locale)",
            notes: "API officielle disponible sur les consoles récentes : adaptateur prévu, non encore développé ni validé.",
            declaredCapabilities: []),
        RouterAdapterDescriptor(id: "asus", name: "ASUS", vendors: ["ASUS"], status: .notImplemented,
            documentation: "Aucune API publique documentée",
            notes: "Non implémenté faute de documentation officielle.", declaredCapabilities: []),
        RouterAdapterDescriptor(id: "tplink", name: "TP-Link", vendors: ["TP-Link"], status: .notImplemented,
            documentation: "Aucune API locale publique documentée (hors Omada)",
            notes: "Non implémenté faute de documentation officielle.", declaredCapabilities: []),
    ]

    public static func descriptor(id: String) -> RouterAdapterDescriptor? { descriptors.first { $0.id == id } }
}

enum JSONHelpers {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RouterError.decoding("JSON attendu")
        }
        return o
    }
    static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
    static func int(_ v: Any?) -> Int? { double(v).map { Int($0) } }
    static func bool(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.intValue != 0 }
        return nil
    }
}
