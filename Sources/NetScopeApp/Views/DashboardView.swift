#if os(macOS)
import SwiftUI
import AppKit
import Charts
import NetScopeCore

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: SidebarItem?
    @State private var showMethod = false

    var body: some View {
        let score = model.qualityScore
        Page("Dashboard", subtitle: "Vue d’ensemble de votre connexion — valeurs réelles, avec leur source et leur date") {
            if let e = model.storeError { ErrorBanner(message: e) }
            if model.connection?.vpnActive == true {
                ErrorBanner(message: "VPN actif : les mesures de débit et de latence passent par le tunnel et peuvent différer de votre accès réel.")
            }
            HStack(alignment: .top, spacing: 16) {
                qualityCard(score)
                connectionCard
            }
            HStack(alignment: .top, spacing: 16) {
                wifiCard
                internetCard
            }
            HStack(alignment: .top, spacing: 16) {
                devicesCard
                timelineCard
            }
        }
        .sheet(isPresented: $showMethod) { MethodologySheet(score: score) }
    }

    func qualityCard(_ s: QualityScore) -> some View {
        Card("Qualité globale", symbol: "gauge.with.dots.needle.67percent",
             trailing: AnyView(Button("Méthode") { showMethod = true }.buttonStyle(.link))) {
            HStack(spacing: 20) {
                ScoreRing(score: s.global)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(s.subScores) { sub in
                        HStack {
                            Text(sub.dimension.rawValue).font(.callout)
                            Spacer()
                            Text(sub.score.map { "\(Int($0))" } ?? "—").monospacedDigit().foregroundStyle(sub.score == nil ? .tertiary : .primary)
                        }
                        .help(sub.inputs.joined(separator: " · "))
                    }
                    ConfidenceLabel(confidence: s.confidence)
                }
            }
        }
    }

    var connectionCard: some View {
        Card("Connexion actuelle", symbol: "network") {
            let c = model.connection
            let m = Provenance.measured(method: "ifconfig / netstat / scutil")
            KeyValueRow(label: "État", value: c.map { $0.isConnected ? "Connecté" : "Déconnecté" })
            KeyValueRow(label: "Type", value: c?.primaryInterface?.kind.label, provenance: c == nil ? nil : m)
            KeyValueRow(label: "Interface", value: c?.primaryInterface.map { "\($0.bsdName)\($0.displayName.map { " — " + $0 } ?? "")" })
            KeyValueRow(label: "IPv4 locale", value: c?.primaryInterface?.ipv4.first?.address, provenance: c == nil ? nil : m)
            KeyValueRow(label: "IPv6", value: c?.primaryInterface?.globalIPv6.first)
            KeyValueRow(label: "Passerelle", value: c?.defaultGatewayIPv4, provenance: c == nil ? nil : m)
            KeyValueRow(label: "DNS", value: c?.dns?.primaryNameservers.prefix(3).joined(separator: ", "))
            KeyValueRow(label: "VPN", value: c.map { $0.vpnActive ? "Actif (\($0.vpnInterfaces.joined(separator: ", ")))" : "Non détecté" })
            MetricRow(label: "IP publique", sourced: model.publicIP) { $0 }
            KeyValueRow(label: "Routeur", value: model.router.info?.model ?? model.router.probes.first?.model,
                        provenance: model.router.info != nil ? .router(adapter: model.router.adapterID ?? "") : nil)
            if let c { Text("Mis à jour \(c.timestamp.relative)").font(.caption2).foregroundStyle(.tertiary) }
        }
    }

    var wifiCard: some View {
        Card("Qualité du Wi-Fi", symbol: "wifi", trailing: AnyView(Button("Analyser") { selection = .wifi }.buttonStyle(.link))) {
            if model.isWired {
                Text("Connexion filaire active : la radio du Mac n’est pas utilisée pour le trafic principal.").font(.callout).foregroundStyle(.secondary)
            }
            if let w = model.wifi {
                MetricRow(label: "SSID", sourced: w.ssid) { $0 }
                MetricRow(label: "RSSI", sourced: w.rssi) { "\($0) dBm · \(RadioQuality.fromRSSI($0).rawValue)" }
                MetricRow(label: "Bruit", sourced: w.noise) { "\($0) dBm" }
                MetricRow(label: "SNR", sourced: w.snr) { "\($0) dB · \(RadioQuality.fromSNR($0).rawValue)" }
                MetricRow(label: "Bande / canal", sourced: w.channel) { "\(w.band.value?.rawValue ?? "?") · canal \($0)" }
                MetricRow(label: "Largeur", sourced: w.channelWidthMHz) { "\($0) MHz" }
                MetricRow(label: "Débit de liaison", sourced: w.txRateMbps) { String(format: "%.0f Mbit/s", $0) }
                MetricRow(label: "Norme", sourced: w.standard) { $0.rawValue }
                if model.rssiHistory.count > 2 {
                    Chart(model.rssiHistory.suffix(200)) { LineMark(x: .value("Heure", $0.t), y: .value("RSSI", $0.v)).interpolationMethod(.monotone) }
                        .chartYAxisLabel("dBm").frame(height: 70)
                }
            } else {
                EmptyStateView(title: "Wi-Fi indisponible", symbol: "wifi.slash", message: "Aucune interface Wi-Fi active n’a été trouvée.")
            }
        }
    }

    var internetCard: some View {
        Card("Performance Internet", symbol: "speedometer", trailing: AnyView(
            Button(model.runningTest == nil ? "Quick Test" : "Test en cours…") { model.startSpeedTest(.quick) }
                .disabled(model.runningTest != nil || !model.settings.acknowledgedDataUsage)
                .help(model.settings.acknowledgedDataUsage ? "" : "Ouvrez Speedtest pour accepter la consommation de données")
                .prominentGlassButton())) {
            if let t = model.latestTest {
                HStack(spacing: 24) {
                    BigNumber(title: "Descendant", value: t.downloadBps.map { String(format: "%.0f", $0 / 1e6) } ?? "—", unit: "Mbit/s")
                    BigNumber(title: "Montant", value: t.uploadBps.map { String(format: "%.0f", $0 / 1e6) } ?? "—", unit: "Mbit/s", tint: .purple)
                    BigNumber(title: "Latence", value: t.idleLatencyMs.map { String(format: "%.0f", $0) } ?? "—", unit: "ms", tint: .teal)
                }
                KeyValueRow(label: "Latence sous charge", value: t.worstLoadedLatencyMs.map { Units.ms($0) })
                KeyValueRow(label: "Gigue", value: t.jitterMs.map { Units.ms($0) })
                KeyValueRow(label: "Pertes", value: t.packetLossPercent.map { String(format: "%.1f %%", $0) })
                KeyValueRow(label: "Réactivité", value: t.responsivenessRPM.map { String(format: "%.0f RPM", $0) })
                Text("\(t.engine.rawValue) · \(t.interfaceName ?? "?") · \(t.timestamp.shortDateTime)").font(.caption2).foregroundStyle(.tertiary)
            } else {
                EmptyStateView(title: "Aucun test", symbol: "speedometer", message: "Lancez un test depuis l’onglet Speedtest. Aucun chiffre n’est affiché tant qu’aucune mesure n’a été faite.")
            }
            if let g = model.gatewayLatency {
                KeyValueRow(label: "Latence passerelle", value: "\(Units.ms(g.medianMs)) · pertes \(String(format: "%.0f", g.lossPercent)) %",
                            provenance: .measured(method: g.method))
            }
        }
    }

    var devicesCard: some View {
        Card("Appareils", symbol: "laptopcomputer.and.iphone", trailing: AnyView(Button("Voir") { selection = .devices }.buttonStyle(.link))) {
            let devs = model.inventory.devices
            let recent = devs.filter { $0.observationState() == .activeNow || $0.observationState() == .reportedByRouter }
            KeyValueRow(label: "Observés par ce Mac", value: "\(devs.filter { $0.methods.contains { $0 != .router } }.count)")
            KeyValueRow(label: "Déclarés connectés par la box", value: model.router.clients.isEmpty ? nil : "\(model.router.clients.filter { $0.active == true }.count)",
                        provenance: model.router.clients.isEmpty ? .unavailable(reason: "Aucune intégration routeur") : .router(adapter: model.router.adapterID ?? ""))
            KeyValueRow(label: "Vus récemment", value: "\(recent.count)")
            KeyValueRow(label: "Connus / à examiner / non examinés",
                        value: "\(devs.filter { $0.trust == .known }.count) / \(devs.filter { $0.trust == .toReview }.count) / \(devs.filter { $0.trust == .unreviewed }.count)")
            Text("Les appareils observés ne représentent pas forcément tous les appareils connectés.").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    var timelineCard: some View {
        Card("Chronologie récente", symbol: "clock.arrow.circlepath") {
            if model.events.isEmpty { Text("Aucun événement enregistré.").foregroundStyle(.secondary) }
            ForEach(model.events.prefix(7)) { e in
                HStack(alignment: .top) {
                    Text(e.timestamp.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                    Text(model.redact(e.message)).font(.callout).lineLimit(2)
                }
            }
        }
    }
}

struct MethodologySheet: View {
    var score: QualityScore
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Méthodologie du score").font(.title2.bold())
            Text(score.methodology).font(.callout)
            List(score.subScores) { s in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(s.dimension.rawValue).bold(); Spacer(); Text(s.score.map { "\(Int($0))/100" } ?? "Non évalué"); ConfidenceLabel(confidence: s.confidence) }
                    Text(s.methodology).font(.caption).foregroundStyle(.secondary)
                    if !s.inputs.isEmpty { Text("Entrées : " + s.inputs.joined(separator: " · ")).font(.caption) }
                }
            }
            HStack { Spacer(); Button("Fermer") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20).frame(width: 620, height: 520)
    }
}

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusDot(color: (model.pathStatus?.satisfied ?? false) ? .green : .red)
                Text((model.pathStatus?.satisfied ?? false) ? "Connecté" : "Hors ligne").font(.headline)
                Spacer()
                if let s = model.qualityScore.global { Text("\(Int(s))/100").font(.headline.monospacedDigit()).foregroundStyle(ScoreRing.color(s)) }
            }
            Divider()
            KeyValueRow(label: "Interface", value: model.connection?.primaryInterface.map { "\($0.kind.label) \($0.bsdName)" })
            KeyValueRow(label: "IP", value: model.connection?.primaryInterface?.ipv4.first?.address)
            if let w = model.wifi, !model.isWired {
                KeyValueRow(label: "Réseau", value: w.ssid.value)
                KeyValueRow(label: "Signal", value: w.rssi.value.map { "\($0) dBm" })
            }
            KeyValueRow(label: "Passerelle", value: model.gatewayLatency.map { Units.ms($0.medianMs) })
            if let t = model.latestTest {
                KeyValueRow(label: "Dernier test", value: "↓ \(t.downloadBps.map(Units.bitRate) ?? "—") ↑ \(t.uploadBps.map(Units.bitRate) ?? "—")")
            }
            if let r = model.runningTest { Label(r.phase, systemImage: "hourglass").font(.caption) }
            Divider()
            HStack {
                Button("Quick Test") { model.startSpeedTest(.quick) }
                    .disabled(model.runningTest != nil || !model.settings.acknowledgedDataUsage)
                Spacer()
                Button("Ouvrir NetScope") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            }
        }
        .padding(14).frame(width: 300)
    }
}
#endif
