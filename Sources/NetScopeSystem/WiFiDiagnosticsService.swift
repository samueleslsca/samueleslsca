#if os(macOS)
import Foundation
import CoreWLAN
import CoreLocation
import NetScopeCore

/// Wi-Fi measurements through CoreWLAN (public framework).
///
/// Since macOS 14.4, SSID/BSSID (and SSIDs in scan results) are only returned when the app holds
/// Location Services authorization. Without it they are reported as "Indisponible" with that reason.
/// Enum values are mapped from their raw values so the code builds against every supported SDK.
public final class WiFiDiagnosticsService: NSObject, @unchecked Sendable {
    public static let shared = WiFiDiagnosticsService()
    private let client = CWWiFiClient.shared()
    private let location = CLLocationManager()
    private var eventHandler: ((NetworkEventKind, String) -> Void)?

    public override init() { super.init() }

    // MARK: Location authorization (required for SSID/BSSID)

    public enum LocationState: String, Sendable { case authorized, denied, notDetermined, restricted }

    public var locationState: LocationState {
        // CLAuthorizationStatus raw values: 0 notDetermined, 1 restricted, 2 denied, 3 always, 4 whenInUse.
        switch location.authorizationStatus.rawValue {
        case 3, 4: return .authorized
        case 2: return .denied
        case 1: return .restricted
        default: return .notDetermined
        }
    }

    public func requestLocationAuthorization() {
        location.requestWhenInUseAuthorization()
    }

    private var identityReason: String {
        switch locationState {
        case .authorized: return "Non renvoyé par CoreWLAN"
        case .denied: return "Autorisation de localisation refusée (requise par macOS pour lire le SSID/BSSID)"
        case .restricted: return "Localisation restreinte par une politique système"
        case .notDetermined: return "Autorisation de localisation non accordée (requise par macOS 14.4+ pour le SSID/BSSID)"
        }
    }

    // MARK: Snapshot

    public var interfaceNames: [String] { client.interfaces()?.compactMap { $0.interfaceName } ?? [] }

    public func snapshot(interfaceName: String? = nil) -> WiFiSnapshot? {
        let iface = interfaceName.flatMap { client.interface(withName: $0) } ?? client.interface()
        guard let iface else { return nil }
        let now = Date()
        let m = Provenance.measured(method: "CoreWLAN")
        let name = iface.interfaceName ?? "?"
        guard iface.powerOn() else {
            let off = "Wi-Fi désactivé"
            return WiFiSnapshot(timestamp: now, interfaceName: name, poweredOn: false, ssid: .unavailable(off), bssid: .unavailable(off),
                                rssi: .unavailable(off), noise: .unavailable(off), channel: .unavailable(off), band: .unavailable(off),
                                channelWidthMHz: .unavailable(off), txRateMbps: .unavailable(off), standard: .unavailable(off),
                                security: .unavailable(off))
        }
        let rssi = iface.rssiValue()
        let noise = iface.noiseMeasurement()
        let associated = rssi != 0
        let ch = iface.wlanChannel()
        let tx = iface.transmitRate()
        let reason = identityReason
        let ssid = iface.ssid()
        let bssid = iface.bssid()
        let notAssoc = "Non associé à un réseau"
        return WiFiSnapshot(
            timestamp: now, interfaceName: name, poweredOn: true,
            ssid: ssid.map { Sourced($0, m, at: now) } ?? .unavailable(associated ? reason : notAssoc, at: now),
            bssid: bssid.flatMap(MACAddress.normalize).map { Sourced($0, m, at: now) } ?? .unavailable(associated ? reason : notAssoc, at: now),
            rssi: associated ? Sourced(rssi, m, at: now) : .unavailable(notAssoc, at: now),
            noise: associated && noise != 0 ? Sourced(noise, m, at: now) : .unavailable("Bruit non exposé par l’interface", at: now),
            channel: ch.map { Sourced($0.channelNumber, m, at: now) } ?? .unavailable(notAssoc, at: now),
            band: ch.map { Sourced(Self.band($0.channelBand.rawValue, channel: $0.channelNumber), m, at: now) } ?? .unavailable(notAssoc, at: now),
            channelWidthMHz: ch.flatMap { Self.width($0.channelWidth.rawValue) }.map { Sourced($0, m, at: now) } ?? .unavailable("Largeur non exposée", at: now),
            txRateMbps: associated && tx > 0 ? Sourced(tx, m, at: now) : .unavailable("Débit de liaison non exposé", at: now),
            standard: associated ? Sourced(Self.standard(iface.activePHYMode().rawValue), m, at: now) : .unavailable(notAssoc, at: now),
            security: associated ? Sourced(Self.security(iface.security().rawValue), m, at: now) : .unavailable(notAssoc, at: now),
            countryCode: iface.countryCode().map { Sourced($0, m, at: now) } ?? .unavailable("Code pays non exposé", at: now))
    }

    /// Scans neighbors. Active scans briefly disturb the link: callers should throttle (≥ 30 s).
    public func scanNeighbors(interfaceName: String? = nil) throws -> [WiFiNeighbor] {
        let iface = interfaceName.flatMap { client.interface(withName: $0) } ?? client.interface()
        guard let iface else { return [] }
        let networks = try iface.scanForNetworks(withName: nil)
        return networks.map { n in
            let ch = n.wlanChannel
            return WiFiNeighbor(ssid: n.ssid, bssid: n.bssid.flatMap(MACAddress.normalize), rssi: n.rssiValue,
                                noise: n.noiseMeasurement == 0 ? nil : n.noiseMeasurement,
                                channel: ch?.channelNumber ?? 0,
                                band: ch.map { Self.band($0.channelBand.rawValue, channel: $0.channelNumber) } ?? .unknown,
                                channelWidthMHz: ch.flatMap { Self.width($0.channelWidth.rawValue) },
                                security: Self.neighborSecurity(n))
        }.sorted { $0.rssi > $1.rssi }
    }

    // MARK: Events (SSID/BSSID/link changes)

    public func startMonitoring(_ handler: @escaping (NetworkEventKind, String) -> Void) {
        eventHandler = handler
        client.delegate = self
        for e in [CWEventType.ssidDidChange, .bssidDidChange, .linkDidChange, .powerDidChange] {
            try? client.startMonitoringEvent(with: e)
        }
    }

    public func stopMonitoring() {
        try? client.stopMonitoringAllEvents()
        eventHandler = nil
    }

    // MARK: Raw-value mappings (CoreWLAN headers)

    /// CWChannelBand: 0 unknown, 1 2 GHz, 2 5 GHz, 3 6 GHz.
    static func band(_ raw: Int, channel: Int) -> WiFiBand {
        switch raw {
        case 1: return .ghz2_4
        case 2: return .ghz5
        case 3: return .ghz6
        default: return WiFiBand.inferred(fromChannel: channel)
        }
    }

    /// CWChannelWidth: 0 unknown, 1 20, 2 40, 3 80, 4 160 MHz.
    static func width(_ raw: Int) -> Int? { [1: 20, 2: 40, 3: 80, 4: 160][raw] }

    /// CWPHYMode: 1 a, 2 b, 3 g, 4 n, 5 ac, 6 ax, 7 be (newer SDKs).
    static func standard(_ raw: Int) -> WiFiStandard {
        switch raw {
        case 1: return .a
        case 2: return .b
        case 3: return .g
        case 4: return .n
        case 5: return .ac
        case 6: return .ax
        case 7: return .be
        default: return .unknown
        }
    }

    /// CWSecurity raw values.
    static func security(_ raw: Int) -> WiFiSecurity {
        switch raw {
        case 0: return .open
        case 1, 6: return .wep
        case 2, 3: return .wpaPersonal
        case 4, 5: return .wpa2Personal
        case 7, 8: return .wpaEnterprise
        case 9, 10: return .wpa2Enterprise
        case 11: return .wpa3Personal
        case 12: return .wpa3Enterprise
        case 13: return .wpa2wpa3Transition
        case 14, 15: return .owe
        default: return .unknown
        }
    }

    static func neighborSecurity(_ n: CWNetwork) -> WiFiSecurity? {
        let order: [(Int, WiFiSecurity)] = [(11, .wpa3Personal), (13, .wpa2wpa3Transition), (12, .wpa3Enterprise), (4, .wpa2Personal),
                                            (9, .wpa2Enterprise), (2, .wpaPersonal), (7, .wpaEnterprise), (14, .owe), (1, .wep), (0, .open)]
        for (raw, s) in order {
            if let sec = CWSecurity(rawValue: raw), n.supportsSecurity(sec) { return s }
        }
        return nil
    }
}

extension WiFiDiagnosticsService: CWEventDelegate {
    public func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { self.eventHandler?(.ssidChanged, interfaceName) }
    }
    public func bssidDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { self.eventHandler?(.bssidChanged, interfaceName) }
    }
    public func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { self.eventHandler?(.interfaceChanged, interfaceName) }
    }
    public func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        DispatchQueue.main.async { self.eventHandler?(.interfaceChanged, interfaceName) }
    }
}
#endif
