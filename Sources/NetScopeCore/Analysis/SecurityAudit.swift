import Foundation

public enum CheckStatus: String, Codable, CaseIterable, Sendable {
    case verified = "Vérifié", suspect = "Suspect", notVerified = "Non vérifié", unavailable = "Indisponible"
}

public struct SecurityFinding: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var status: CheckStatus
    public var severity: RiskLevel
    public var detail: String
    public var recommendation: String?
}

public struct SecurityAuditInput: Sendable {
    public var currentWiFiSecurity: WiFiSecurity?
    public var routerWiFi: RouterWiFiReport?
    public var routerInfo: RouterInfo?
    public var devices: [NetworkDevice]
    public var events: [NetworkEvent]
    public var connection: ConnectionSnapshot?
    public var baselineDNS: [String]?

    public init(currentWiFiSecurity: WiFiSecurity? = nil, routerWiFi: RouterWiFiReport? = nil, routerInfo: RouterInfo? = nil,
                devices: [NetworkDevice] = [], events: [NetworkEvent] = [], connection: ConnectionSnapshot? = nil,
                baselineDNS: [String]? = nil) {
        self.currentWiFiSecurity = currentWiFiSecurity; self.routerWiFi = routerWiFi; self.routerInfo = routerInfo
        self.devices = devices; self.events = events; self.connection = connection; self.baselineDNS = baselineDNS
    }
}

public struct SecurityAuditResult: Codable, Hashable, Sendable {
    public var findings: [SecurityFinding]
    public var score: Double?
    public var methodology: String
}

/// Defensive audit. Reports inconsistencies without concluding to an intrusion.
public enum SecurityAuditor {
    public static func audit(_ i: SecurityAuditInput) -> SecurityAuditResult {
        var f: [SecurityFinding] = []

        // Current Wi-Fi protection
        if let s = i.currentWiFiSecurity, s != .unknown {
            if s.isOpen {
                f.append(.init(id: "wifi-open", title: "Réseau Wi-Fi actuel sans chiffrement", status: .suspect, severity: .high,
                               detail: "Le réseau auquel ce Mac est connecté est ouvert : le trafic non chiffré est lisible par les appareils proches.",
                               recommendation: "Activer WPA3 (ou WPA2/WPA3) sur la box ; sur un réseau public, utiliser un VPN de confiance."))
            } else if s.isObsolete {
                f.append(.init(id: "wifi-obsolete", title: "Protection Wi-Fi obsolète (\(s.rawValue))", status: .suspect, severity: .high,
                               detail: "WEP et WPA (TKIP) sont cassés ou dépréciés.", recommendation: "Passer en WPA2-AES ou WPA3 dans l’interface de la box."))
            } else {
                f.append(.init(id: "wifi-protected", title: "Protection Wi-Fi du réseau actuel : \(s.rawValue)", status: .verified, severity: .none,
                               detail: "Mesuré via CoreWLAN sur ce Mac.",
                               recommendation: s == .wpa2Personal ? "WPA3 (ou mode transition WPA2/WPA3) renforce la protection contre les attaques par dictionnaire hors ligne." : nil))
            }
        } else {
            f.append(.init(id: "wifi-protected", title: "Protection Wi-Fi du réseau actuel", status: .unavailable, severity: .none,
                           detail: "Non connecté en Wi-Fi ou information non exposée.", recommendation: nil))
        }

        // Router Wi-Fi configuration
        if let w = i.routerWiFi {
            for n in w.networks where n.enabled != false {
                let enc = (n.encryption ?? "").lowercased()
                if enc.contains("wep") || enc == "none" || enc.isEmpty || (enc.contains("wpa") && !enc.contains("wpa2") && !enc.contains("wpa3") && !enc.contains("ccmp")) {
                    f.append(.init(id: "router-enc-\(n.ssid ?? "?")", title: "Chiffrement faible sur « \(n.ssid ?? "?") »", status: .suspect, severity: .high,
                                   detail: "Chiffrement rapporté par le routeur : \(n.encryption ?? "aucun").", recommendation: "Choisir WPA2-AES ou WPA3."))
                }
                if n.wpsEnabled == true {
                    f.append(.init(id: "router-wps-\(n.ssid ?? "?")", title: "WPS activé sur « \(n.ssid ?? "?") »", status: .suspect, severity: .medium,
                                   detail: "Le WPS (surtout par code PIN) a un historique de vulnérabilités.", recommendation: "Désactiver le WPS si vous ne l’utilisez pas."))
                }
            }
            if !f.contains(where: { $0.id.hasPrefix("router-enc") }) {
                f.append(.init(id: "router-enc", title: "Chiffrement des réseaux de la box", status: .verified, severity: .none,
                               detail: "Aucun chiffrement faible rapporté par le routeur.", recommendation: nil))
            }
            if w.networks.allSatisfy({ $0.wpsEnabled == nil }) {
                f.append(.init(id: "router-wps", title: "État du WPS", status: .unavailable, severity: .none,
                               detail: "L’API du routeur n’expose pas l’état du WPS.", recommendation: "Vérifier dans l’interface de la box."))
            }
            switch w.guestNetworkEnabled {
            case .some(true): f.append(.init(id: "guest", title: "Réseau invité configuré", status: .verified, severity: .none,
                                             detail: "Rapporté par le routeur. L’isolation effective des invités n’est pas testée.", recommendation: nil))
            case .some(false): f.append(.init(id: "guest", title: "Pas de réseau invité", status: .verified, severity: .low,
                                              detail: "Les visiteurs et objets connectés partagent le réseau principal.",
                                              recommendation: "Créer un réseau invité pour les visiteurs et objets connectés peu fiables."))
            case .none: f.append(.init(id: "guest", title: "Réseau invité", status: .unavailable, severity: .none,
                                       detail: "Information non fournie par le routeur.", recommendation: nil))
            }
        } else {
            f.append(.init(id: "router-config", title: "Configuration Wi-Fi de la box", status: .unavailable, severity: .none,
                           detail: "Aucune intégration routeur active.", recommendation: "Connecter un adaptateur routeur compatible dans Router Control."))
        }

        // Firmware
        if let fw = i.routerInfo?.firmware {
            f.append(.init(id: "firmware", title: "Firmware rapporté : \(fw)", status: .notVerified, severity: .none,
                           detail: "NetScope n’intègre pas de base de vulnérabilités : la version n’est pas comparée aux bulletins publics.",
                           recommendation: "Vérifier que les mises à jour automatiques de la box sont actives."))
        } else {
            f.append(.init(id: "firmware", title: "Version du firmware", status: .unavailable, severity: .none, detail: "Non fournie.", recommendation: nil))
        }

        // Devices
        let unknown = i.devices.filter { $0.trust == .unreviewed }
        let toReview = i.devices.filter { $0.trust == .toReview }
        if i.devices.isEmpty {
            f.append(.init(id: "devices", title: "Inventaire des appareils", status: .notVerified, severity: .none,
                           detail: "Aucune découverte effectuée.", recommendation: "Lancer la découverte dans Connected Devices."))
        } else if !toReview.isEmpty || !unknown.isEmpty {
            f.append(.init(id: "devices", title: "\(unknown.count) appareil(s) non examiné(s), \(toReview.count) à examiner",
                           status: toReview.isEmpty ? .notVerified : .suspect, severity: toReview.isEmpty ? .low : .medium,
                           detail: "Un appareil non reconnu n’est pas forcément malveillant (adresse MAC privée, objet oublié…).",
                           recommendation: "Identifier chaque appareil et le marquer « connu » ; changer la clé Wi-Fi en cas de doute."))
        } else {
            f.append(.init(id: "devices", title: "Tous les appareils observés sont marqués connus", status: .verified, severity: .none,
                           detail: "\(i.devices.count) appareil(s).", recommendation: nil))
        }

        // Gateway / DNS changes
        let gwChanges = i.events.filter { $0.kind == .gatewayChanged }
        let dnsChanges = i.events.filter { $0.kind == .dnsChanged }
        f.append(.init(id: "gateway-changes", title: gwChanges.isEmpty ? "Aucun changement inattendu de passerelle" : "\(gwChanges.count) changement(s) de passerelle",
                       status: gwChanges.isEmpty ? .verified : .suspect, severity: gwChanges.isEmpty ? .none : .medium,
                       detail: gwChanges.last?.message ?? "Sur la période enregistrée.",
                       recommendation: gwChanges.isEmpty ? nil : "Vérifier si la box a été remplacée ou redémarrée. Un changement d’adresse MAC de la passerelle sans raison est inhabituel."))
        f.append(.init(id: "dns-changes", title: dnsChanges.isEmpty ? "Aucun changement de DNS détecté" : "\(dnsChanges.count) changement(s) de DNS",
                       status: dnsChanges.isEmpty ? .verified : .suspect, severity: dnsChanges.isEmpty ? .none : .low,
                       detail: dnsChanges.last?.message ?? "Sur la période enregistrée.",
                       recommendation: dnsChanges.isEmpty ? nil : "Un changement de DNS est normal en changeant de réseau ou de VPN ; sinon, vérifier la configuration DHCP de la box."))

        // IPv6 leak while VPN active (heuristic)
        if let c = i.connection, c.vpnActive {
            let physicalGlobalV6 = c.interfaces.filter { ($0.kind == .wifi || $0.kind == .ethernet) && !$0.globalIPv6.isEmpty }
            if !physicalGlobalV6.isEmpty, c.defaultGatewayIPv6 != nil {
                f.append(.init(id: "ipv6-leak", title: "Fuite IPv6 possible hors du VPN", status: .suspect, severity: .medium,
                               detail: "Une adresse IPv6 globale et une route IPv6 par défaut existent sur l’interface physique alors qu’un VPN est actif. Le trafic IPv6 pourrait ne pas passer par le tunnel.",
                               recommendation: "Vérifier que le VPN gère l’IPv6 (ou le bloque)."))
            } else {
                f.append(.init(id: "ipv6-leak", title: "Pas d’indice de fuite IPv6", status: .verified, severity: .none,
                               detail: "Aucune route IPv6 hors tunnel détectée.", recommendation: nil))
            }
        }

        let scored = f.filter { $0.status == .verified || $0.status == .suspect }
        let score: Double? = scored.isEmpty ? nil : Double(scored.filter { $0.status == .verified }.count) / Double(scored.count) * 100
        return SecurityAuditResult(findings: f, score: score,
                                   methodology: "Score = part des contrôles « vérifiés » parmi les contrôles conclusifs (vérifiés ou suspects). Les contrôles « non vérifiés » et « indisponibles » sont exclus du calcul et listés séparément.")
    }
}
