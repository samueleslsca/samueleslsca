#if os(macOS)
import SwiftUI
import Charts
import NetScopeCore

struct SpeedtestView: View {
    @EnvironmentObject var model: AppModel
    @State private var mode: SpeedTestMode = .quick

    static let modeHelp: [SpeedTestMode: String] = [
        .quick: "Mesure courte : débits descendant/montant simultanés et réactivité.",
        .full: "Débits séquentiels, latence au repos et sous charge, gigue, pertes (ICMP), DNS.",
        .gaming: "Latence, pics, pertes vers vos cibles, puis latence sous charge.",
        .videoCall: "Montant, descendant, gigue et pertes pertinents pour la visio.",
        .streaming: "Capacité et stabilité sur deux passages, estimation prudente des qualités vidéo.",
        .lan: "Débit local vers votre serveur iperf3 (Réglages). Ce n’est pas un test Internet.",
    ]

    var body: some View {
        Page("Speedtest Pro", subtitle: "Mesures avec l’outil natif Apple networkQuality (serveurs Apple) — résultats horodatés avec leur méthode") {
            if !model.settings.acknowledgedDataUsage { dataWarning }
            if let caps = model.speedCaps, !caps.available {
                ErrorBanner(message: "networkQuality est introuvable sur ce Mac (macOS 12 ou ultérieur requis). Le test Internet est indisponible ; le test LAN iperf3 reste possible.")
            }
            Card("Mode de test", symbol: "slider.horizontal.3") {
                Picker("Mode", selection: $mode) {
                    ForEach([SpeedTestMode.quick, .full, .gaming, .videoCall, .streaming, .lan]) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(Self.modeHelp[mode] ?? "").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Toggle("Mode consommation réduite", isOn: $model.settings.reducedDataMode)
                        .help(model.speedCaps?.supportsMaxRuntime == true ? "Limite la durée du test (option -M)" : "Votre version de networkQuality ne permet pas de limiter la durée ; le mode réduit évite seulement les passages supplémentaires.")
                    Spacer()
                    if model.runningTest != nil {
                        Button("Annuler", role: .cancel) { model.cancelSpeedTest() }.glassButton()
                    } else {
                        Button("Démarrer") { model.startSpeedTest(mode) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!model.settings.acknowledgedDataUsage || (mode != .lan && model.speedCaps?.available == false))
                            .prominentGlassButton()
                    }
                }
                if let bg = model.backgroundTrafficBps(), bg > 5e6, model.runningTest == nil {
                    ErrorBanner(message: "Trafic important en cours sur cette interface (\(Units.bitRate(bg))) : il peut fausser la mesure.")
                }
                if model.connection?.vpnActive == true || model.connection?.proxy?.isActive == true {
                    ErrorBanner(message: "VPN ou proxy détecté : la mesure reflète le chemin via le tunnel/proxy.")
                }
                if let e = model.lastTestError { ErrorBanner(message: e) }
            }
            HStack(alignment: .top, spacing: 16) {
                gauge
                liveChart
            }
            if let t = model.latestTest { ResultDetail(result: t) }
            if mode == .streaming, let t = model.latestTest { StreamingEstimate(result: t, history: model.speedTests) }
            Card("Méthode et limites", symbol: "info.circle") {
                Text("Les débits sont exprimés en bits par seconde (Mbit/s, Gbit/s) ; les volumes en octets (Mo, Go). networkQuality mesure vers l’infrastructure Apple : un autre serveur peut donner un résultat différent et les résultats de serveurs différents ne sont pas interchangeables. Un test unique ne permet pas de conclusion définitive. La courbe en direct est le débit réellement mesuré sur l’interface pendant le test (compteurs système), pas une valeur interne de l’outil.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    var dataWarning: some View {
        Card("Consommation de données", symbol: "exclamationmark.triangle") {
            Text("Un test de débit transfère un volume important (souvent plusieurs centaines de Mo sur une connexion rapide). Sur un forfait mobile ou un partage de connexion, privilégiez le mode réduit.")
                .font(.callout)
            Button("J’ai compris, autoriser les tests") { model.settings.acknowledgedDataUsage = true }.prominentGlassButton()
        }
    }

    var gauge: some View {
        Card("Débit", symbol: "gauge.with.needle") {
            let live = model.runningTest?.live.last
            let value = live.map { max($0.inBps, $0.outBps) } ?? model.latestTest?.downloadBps
            VStack(spacing: 6) {
                Gauge(value: min((value ?? 0) / 1e6, 1000), in: 0...1000) {
                    Text("Mbit/s")
                } currentValueLabel: {
                    Text(value.map { String(format: "%.0f", $0 / 1e6) } ?? "—").monospacedDigit()
                }
                .gaugeStyle(.accessoryCircular)
                .scaleEffect(2.2).frame(height: 150)
                Text(model.runningTest?.phase ?? (model.latestTest == nil ? "Aucune mesure" : "Dernier résultat (descendant)"))
                    .font(.callout).foregroundStyle(.secondary)
                if let r = model.runningTest {
                    ProgressView().progressViewStyle(.linear)
                    Text("Démarré \(r.started.relative)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 320)
    }

    var liveChart: some View {
        Card("Débit mesuré sur l’interface", symbol: "waveform") {
            let data = model.runningTest?.live ?? Array(model.traffic.suffix(60))
            if data.count < 2 {
                Text("Le graphique s’affiche pendant le test.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Chart {
                    ForEach(data) { s in
                        LineMark(x: .value("t", s.timestamp), y: .value("Mbit/s", s.inBps / 1e6), series: .value("Sens", "Entrant")).foregroundStyle(.blue)
                        LineMark(x: .value("t", s.timestamp), y: .value("Mbit/s", s.outBps / 1e6), series: .value("Sens", "Sortant")).foregroundStyle(.purple)
                    }
                }
                .chartYAxisLabel("Mbit/s").frame(height: 180)
                Text("Source : compteurs d’octets de l’interface (sysctl), échantillonnés chaque seconde.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

struct ResultDetail: View {
    var result: SpeedTestResult
    @EnvironmentObject var model: AppModel
    var body: some View {
        Card("Dernier résultat — \(result.mode.label)", symbol: "checkmark.circle") {
            HStack(spacing: 28) {
                BigNumber(title: "Descendant", value: result.downloadBps.map { String(format: "%.1f", $0 / 1e6) } ?? "—", unit: "Mbit/s")
                BigNumber(title: "Montant", value: result.uploadBps.map { String(format: "%.1f", $0 / 1e6) } ?? "—", unit: "Mbit/s", tint: .purple)
                BigNumber(title: "Latence repos", value: result.idleLatencyMs.map { String(format: "%.0f", $0) } ?? "—", unit: "ms", tint: .teal)
                BigNumber(title: "Sous charge", value: result.worstLoadedLatencyMs.map { String(format: "%.0f", $0) } ?? "—", unit: "ms", tint: .orange)
                BigNumber(title: "Réactivité", value: result.responsivenessRPM.map { String(format: "%.0f", $0) } ?? "—", unit: "RPM", tint: .green)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow { KeyValueRow(label: "Latence sous charge ↓", value: result.downloadLoadedLatencyMs.map { Units.ms($0) }); KeyValueRow(label: "Latence sous charge ↑", value: result.uploadLoadedLatencyMs.map { Units.ms($0) }) }
                GridRow { KeyValueRow(label: "Gigue", value: result.jitterMs.map { Units.ms($0) }); KeyValueRow(label: "Pertes (ICMP)", value: result.packetLossPercent.map { String(format: "%.1f %%", $0) }) }
                GridRow { KeyValueRow(label: "Connexion TCP", value: result.tcpHandshakeMs.map { Units.ms($0) }); KeyValueRow(label: "Négociation TLS", value: result.tlsHandshakeMs.map { Units.ms($0) }) }
                GridRow { KeyValueRow(label: "Réponse HTTP", value: result.httpResponseMs.map { Units.ms($0) }); KeyValueRow(label: "Résolution DNS", value: result.dnsResolutionMs.map { Units.ms($0) }) }
                GridRow { KeyValueRow(label: "Flux ↓ / ↑", value: "\(result.downloadFlows.map(String.init) ?? "—") / \(result.uploadFlows.map(String.init) ?? "—")"); KeyValueRow(label: "Volume transféré", value: result.bytesTransferred.map { Units.bytes($0) }) }
            }
            Text("Méthode : \(result.engine.rawValue)\(result.sequential ? ", séquentiel" : ", simultané") · Serveur : \(result.server ?? "non communiqué") · Interface : \(result.interfaceName ?? "?") · \(result.timestamp.shortDateTime)\(result.vpnActive ? " · VPN actif" : "")")
                .font(.caption).foregroundStyle(.secondary)
            if !result.missingFields.isEmpty {
                Text("Champs non fournis par cette version de networkQuality : \(result.missingFields.joined(separator: ", "))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Prudent video-quality estimate: requires the *minimum* of recent runs to exceed 1.5× the typical bitrate.
struct StreamingEstimate: View {
    var result: SpeedTestResult
    var history: [SpeedTestResult]
    static let tiers: [(String, Double)] = [("SD (480p)", 3e6), ("HD (720p)", 5e6), ("Full HD (1080p)", 8e6), ("4K UHD", 25e6)]

    var body: some View {
        let recent = history.filter { $0.succeeded && $0.timestamp > Date().addingTimeInterval(-3600) }.compactMap(\.downloadBps)
        let floor = recent.min() ?? result.downloadBps ?? 0
        Card("Compatibilité streaming (estimation)", symbol: "play.tv") {
            ForEach(Self.tiers.indices, id: \.self) { i in
                let name = Self.tiers[i].0, rate = Self.tiers[i].1
                HStack {
                    Image(systemName: floor >= rate * 1.5 ? "checkmark.circle.fill" : (floor >= rate ? "exclamationmark.circle" : "xmark.circle"))
                        .foregroundStyle(floor >= rate * 1.5 ? .green : (floor >= rate ? .orange : .red))
                    Text(name); Spacer()
                    Text(floor >= rate * 1.5 ? "Confortable" : (floor >= rate ? "Juste" : "Insuffisant")).foregroundStyle(.secondary)
                }
            }
            Text("Estimé à partir du plus faible de \(max(recent.count, 1)) test(s) de la dernière heure, avec une marge de 1,5× sur les débits typiques des services (variables selon le service et le codec).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif
