#if os(macOS)
import Foundation
import NetScopeCore
import NetScopeSystem

/// Headless smoke test: runs the read-only system tools on this Mac and reports what the parsers extracted.
/// Prints a feasibility matrix. Never changes any setting; runs no throughput test.
enum SelfTest {
    static func run() {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await body()
            sem.signal()
        }
        sem.wait()
    }

    static func line(_ ok: Bool, _ s: String) { print((ok ? "✅ " : "⚠️ ") + s) }

    static func body() async {
        let runner = ProcessCommandRunner.shared
        let f = SystemFacts.read()
        print("NetScope Pro — auto-test (lecture seule)")
        print("macOS \(f.osVersion) · \(f.cpu) · Apple Silicon : \(f.appleSilicon ? "oui" : "non") · \(f.model) · Liquid Glass : \(f.liquidGlassAvailable ? "oui" : "non (repli matériaux)")")
        print("\n— Outils système")
        for item in FeasibilityAuditor.toolMatrix(runner: runner) { line(item.status == .verified, "\(item.feature) [\(item.source)] \(item.note)") }

        print("\n— Connexion")
        let snap = await NetworkInterfaceService(runner: runner).snapshot()
        line(snap.primaryInterface != nil, "Interface principale : \(snap.primaryInterface.map { "\($0.bsdName) (\($0.kind.label))" } ?? "aucune")")
        line(snap.defaultGatewayIPv4 != nil, "Passerelle IPv4 : \(snap.defaultGatewayIPv4 ?? "—")")
        line(!(snap.dns?.primaryNameservers.isEmpty ?? true), "DNS : \(snap.dns?.primaryNameservers.joined(separator: ", ") ?? "—")")
        print("   VPN : \(snap.vpnActive ? snap.vpnInterfaces.joined(separator: ", ") : "non") · Proxy : \(snap.proxy?.isActive == true ? "oui" : "non")")
        print("   Interfaces : " + snap.interfaces.map { "\($0.bsdName)=\($0.kind.rawValue)" }.joined(separator: " "))

        print("\n— Wi-Fi (CoreWLAN)")
        if let w = WiFiDiagnosticsService.shared.snapshot() {
            print("   \(w.interfaceName) alimenté=\(w.poweredOn)")
            for (k, v) in [("SSID", w.ssid.value ?? w.ssid.provenance.detail), ("RSSI", w.rssi.value.map { "\($0) dBm" } ?? w.rssi.provenance.detail),
                           ("Bruit", w.noise.value.map { "\($0) dBm" } ?? w.noise.provenance.detail),
                           ("Canal", w.channel.value.map(String.init) ?? "—"), ("Bande", w.band.value?.rawValue ?? "—"),
                           ("Largeur", w.channelWidthMHz.value.map { "\($0) MHz" } ?? "—"), ("Norme", w.standard.value?.rawValue ?? "—"),
                           ("Sécurité", w.security.value?.rawValue ?? "—")] { print("   \(k) : \(v)") }
        } else { line(false, "Aucune interface Wi-Fi") }

        print("\n— Latence")
        if let gw = snap.defaultGatewayIPv4 {
            do {
                let s = try await LatencyMonitoringService(runner: runner).ping(gw, count: 5, interval: 0.2)
                line(s.received > 0, "Passerelle : médiane \(Units.ms(s.medianMs)), pertes \(s.lossPercent) %")
            } catch { line(false, "ping passerelle : \(error.localizedDescription)") }
        }
        if let s = try? await LatencyMonitoringService(runner: runner).ping("1.1.1.1", count: 5, interval: 0.2) {
            line(s.received > 0, "1.1.1.1 : médiane \(Units.ms(s.medianMs)), pertes \(s.lossPercent) %")
        }

        print("\n— DNS (requête directe au résolveur)")
        for r in snap.dns?.primaryNameservers.filter({ IPv4.parse($0) != nil }).prefix(2) ?? [] {
            let q = await DNSClient().resolve("apple.com", resolver: r)
            line(q.success, "\(r) : \(q.success ? Units.ms(q.durationMs) : (q.error ?? "échec"))")
        }

        print("\n— Voisins (ARP/NDP)")
        let obs = await NeighborDiscoveryService(runner: runner).readCaches()
        line(true, "\(obs.count) entrée(s) exploitable(s)")

        print("\n— networkQuality")
        let caps = await InternetSpeedTestService(runner: runner).capabilities()
        line(caps.available, "Options détectées : \(caps.flags.sorted().joined(separator: " "))")

        print("\n— nettop")
        if let p = try? await ProcessTrafficService(runner: runner).sample() { line(!p.isEmpty, "\(p.count) processus avec compteurs") }
        else { line(false, "nettop indisponible") }

        print("\n— Compteurs d’interface (sysctl 64 bits)")
        let c = InterfaceCountersReader.read()
        line(!c.isEmpty, c.prefix(4).map { "\($0.interface) in=\($0.bytesIn)" }.joined(separator: " "))
        print("\nAuto-test terminé : aucune configuration n’a été modifiée.")
    }
}
#endif
