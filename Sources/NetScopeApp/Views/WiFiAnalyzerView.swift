#if os(macOS)
import SwiftUI
import Charts
import NetScopeCore

struct WiFiAnalyzerView: View {
    @EnvironmentObject var model: AppModel
    @State private var band: WiFiBand = .ghz5

    var body: some View {
        Page("Wi-Fi Analyzer", subtitle: "Liaison radio mesurée par CoreWLAN, réseaux voisins et recommandations") {
            if model.wifiService.locationState != .authorized {
                Card("Autorisation de localisation", symbol: "location") {
                    Text("Depuis macOS 14.4, Apple ne communique le nom du réseau (SSID), le BSSID et les SSID voisins qu’aux apps autorisées à utiliser la localisation. NetScope n’utilise pas votre position ; sans cette autorisation, ces champs restent « Indisponible ».")
                        .font(.callout)
                    Button("Demander l’autorisation") { model.wifiService.requestLocationAuthorization() }.glassButton()
                }
            }
            HStack(alignment: .top, spacing: 16) { linkCard; nextGenCard }
            signalCard
            neighborsCard
            recommendationsCard
        }
    }

    var linkCard: some View {
        Card("Liaison actuelle", symbol: "wifi") {
            if let w = model.wifi {
                MetricRow(label: "SSID", sourced: w.ssid) { $0 }
                MetricRow(label: "BSSID", sourced: w.bssid) { $0 }
                MetricRow(label: "RSSI", sourced: w.rssi) { "\($0) dBm (\(RadioQuality.fromRSSI($0).rawValue))" }
                MetricRow(label: "Bruit", sourced: w.noise) { "\($0) dBm" }
                MetricRow(label: "SNR", sourced: w.snr) { "\($0) dB (\(RadioQuality.fromSNR($0).rawValue))" }
                MetricRow(label: "Canal", sourced: w.channel) { "\($0)" }
                MetricRow(label: "Bande", sourced: w.band) { $0.rawValue }
                MetricRow(label: "Largeur de canal", sourced: w.channelWidthMHz) { "\($0) MHz" }
                MetricRow(label: "Débit de liaison négocié", sourced: w.txRateMbps) { String(format: "%.0f Mbit/s", $0) }
                MetricRow(label: "Sécurité", sourced: w.security) { $0.rawValue }
                MetricRow(label: "Code pays", sourced: w.countryCode) { $0 }
            } else {
                EmptyStateView(title: "Indisponible", symbol: "wifi.slash", message: "Aucune interface Wi-Fi active.")
            }
        }
    }

    var nextGenCard: some View {
        Card("Capacités Wi-Fi 6/6E/7", symbol: "sparkles") {
            if let w = model.wifi {
                MetricRow(label: "Norme active", sourced: w.standard) { $0.rawValue }
                KeyValueRow(label: "Bande 6 GHz", value: w.band.value == .ghz6 ? "En cours d’utilisation" : (w.band.value == nil ? nil : "Non utilisée actuellement"))
                KeyValueRow(label: "MLO (Multi-Link Operation)", value: nil, provenance: .unavailable(reason: "Non exposé par CoreWLAN ni par l’adaptateur routeur actif"))
                KeyValueRow(label: "OFDMA / temps d’occupation radio", value: nil, provenance: .unavailable(reason: "Non exposé par les API publiques macOS"))
                if let tx = w.txRateMbps.value, let dl = model.latestTest?.downloadBps, model.latestTest?.interfaceName == w.interfaceName {
                    KeyValueRow(label: "Théorique vs mesuré", value: String(format: "liaison %.0f Mbit/s · Internet mesuré %.0f Mbit/s (%.0f %%)", tx, dl / 1e6, dl / 1e6 / tx * 100),
                                provenance: .computed(formula: "débit mesuré / débit de liaison"))
                    Text("Le débit de liaison est une capacité radio théorique ; le débit utile est typiquement 50 à 70 % de cette valeur dans de bonnes conditions.").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 400)
    }

    var signalCard: some View {
        Card("Évolution du signal", symbol: "chart.line.uptrend.xyaxis") {
            if model.rssiHistory.count < 3 {
                Text("Collecte en cours (une mesure toutes les 3 s).").foregroundStyle(.secondary)
            } else {
                Chart(model.rssiHistory.suffix(400)) { p in
                    LineMark(x: .value("Heure", p.t), y: .value("RSSI", p.v)).interpolationMethod(.monotone)
                    RuleMark(y: .value("Seuil bon", Thresholds.rssiGood)).foregroundStyle(.green.opacity(0.4)).lineStyle(StrokeStyle(dash: [4]))
                    RuleMark(y: .value("Seuil faible", Thresholds.rssiFair)).foregroundStyle(.red.opacity(0.4)).lineStyle(StrokeStyle(dash: [4]))
                }
                .chartYScale(domain: -95 ... -25).chartYAxisLabel("dBm").frame(height: 180)
                let vals = model.rssiHistory.suffix(400).map(\.v)
                Text(String(format: "Min %.0f · Max %.0f · σ %.1f dB · %d mesures", vals.min() ?? 0, vals.max() ?? 0, Stats.standardDeviation(vals) ?? 0, vals.count))
                    .font(.caption).foregroundStyle(.secondary)
                let changes = model.events.filter { $0.kind == .bssidChanged || $0.kind == .ssidChanged }.prefix(5)
                ForEach(Array(changes)) { e in Text("\(e.timestamp.shortDateTime) — \(model.redact(e.message))").font(.caption) }
            }
        }
    }

    var neighborsCard: some View {
        Card("Réseaux voisins et canaux", symbol: "antenna.radiowaves.left.and.right",
             trailing: AnyView(Button("Scanner") { model.scanNeighbors() }.glassButton())) {
            if let e = model.scanError { ErrorBanner(message: e) }
            if model.neighbors.isEmpty {
                Text("Lancez un scan (CoreWLAN). Un scan actif interrompt brièvement la liaison : il n’est jamais déclenché automatiquement.").foregroundStyle(.secondary)
            } else {
                Picker("Bande", selection: $band) {
                    Text("2,4 GHz").tag(WiFiBand.ghz2_4); Text("5 GHz").tag(WiFiBand.ghz5); Text("6 GHz").tag(WiFiBand.ghz6)
                }.pickerStyle(.segmented).frame(width: 320)
                channelChart
                Table(model.neighbors.filter { $0.band == band }) {
                    TableColumn("SSID") { Text(model.redact($0.ssid ?? "Masqué")) }
                    TableColumn("Canal") { Text("\($0.channel)") }.width(60)
                    TableColumn("Largeur") { Text($0.channelWidthMHz.map { "\($0) MHz" } ?? "—") }.width(70)
                    TableColumn("RSSI") { Text("\($0.rssi) dBm").monospacedDigit() }.width(80)
                    TableColumn("Sécurité") { n in
                        Text(n.security?.rawValue ?? "—").foregroundStyle((n.security?.isObsolete ?? false) || (n.security?.isOpen ?? false) ? .orange : .primary)
                    }
                }
                .frame(minHeight: 180)
                if let t = model.neighborsScannedAt { Text("Scan \(t.relative) · \(model.neighbors.count) réseaux").font(.caption2).foregroundStyle(.tertiary) }
            }
        }
    }

    var channelChart: some View {
        let ns = model.neighbors.filter { $0.band == band && $0.channel > 0 }
        let myBSSID = model.wifi?.bssid.value
        return Chart(ns) { n in
            let half = Double(n.channelWidthMHz ?? 20) / 10   // channel numbers are 5 MHz apart
            RectangleMark(xStart: .value("début", Double(n.channel) - half), xEnd: .value("fin", Double(n.channel) + half),
                          yStart: .value("plancher", -100), yEnd: .value("RSSI", n.rssi))
                .foregroundStyle(n.bssid == myBSSID ? Color.accentColor.opacity(0.6) : Color.gray.opacity(0.25))
        }
        .chartYScale(domain: -100 ... -20).chartXAxisLabel("Canal").chartYAxisLabel("dBm").frame(height: 160)
    }

    var recommendationsCard: some View {
        Card("Recommandations radio", symbol: "lightbulb") {
            let report = DiagnosticsEngine.analyze(model.diagnosticInput())
            let radio = report.hypotheses.filter { [.weakSignal, .interference, .saturatedRadio, .intermittentDisconnects].contains($0.cause) }
            if let ch = model.wifi?.channel.value, let b = model.wifi?.band.value, !model.neighbors.isEmpty,
               let adv = ChannelAdvisor.recommend(band: b, neighbors: model.neighbors, excludingBSSID: model.wifi?.bssid.value, current: ch) {
                Label(adv.channel == ch ? "Le canal actuel (\(ch)) est déjà le moins chargé observé." : "Canal suggéré : \(adv.channel) (actuel \(ch)), largeur \(adv.recommendedWidthMHz) MHz", systemImage: "dot.radiowaves.left.and.right")
                Text(adv.rationale).font(.caption).foregroundStyle(.secondary)
            }
            if radio.isEmpty {
                Text("Aucun problème radio ne ressort des mesures actuelles.").foregroundStyle(.secondary)
            }
            ForEach(radio) { h in HypothesisView(hypothesis: h) }
            if !model.isWired {
                Text("Comparaison Wi-Fi / Ethernet : lancez un test en Wi-Fi puis en Ethernet ; History & Reports compare les deux.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
