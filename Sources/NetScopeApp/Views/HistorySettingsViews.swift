#if os(macOS)
import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers
import NetScopeCore
import NetScopeSystem

struct HourBucket: Identifiable {
    var id: Int { hour }
    var hour: Int
    var value: Double
}

enum ReportExporter {
    /// Saves a report as PDF (default), HTML, Markdown or JSON depending on the chosen extension.
    @MainActor static func save(_ report: Report, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf, .html, .json, UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = suggestedName + ".pdf"
        panel.allowsOtherFileTypes = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch url.pathExtension.lowercased() {
        case "json": try? report.json().write(to: url)
        case "html": try? report.html().write(to: url, atomically: true, encoding: .utf8)
        case "md": try? report.markdown().write(to: url, atomically: true, encoding: .utf8)
        default: writePDF(html: report.html(), to: url)
        }
    }

    @MainActor static func saveText(_ text: String, name: String, type: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Paginated A4 PDF through the system print pipeline (no third-party renderer).
    @MainActor static func writePDF(html: String, to url: URL) {
        guard let data = html.data(using: .utf8),
              let attr = NSAttributedString(html: data, options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) else { return }
        let info = NSPrintInfo(dictionary: [.jobDisposition: NSPrintInfo.JobDisposition.save, .jobSavingURL: url])
        info.paperSize = NSSize(width: 595, height: 842)
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.textStorage?.setAttributedString(attr)
        tv.sizeToFit()
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            lm.ensureLayout(for: tc)
            tv.frame.size.height = lm.usedRect(for: tc).height + 20
        }
        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.run()
    }
}

struct HistoryReportsView: View {
    @EnvironmentObject var model: AppModel
    @State private var range = 7
    @State private var customFrom = Date().addingTimeInterval(-14 * 86400)
    @State private var customTo = Date()
    @State private var split = Date().addingTimeInterval(-3 * 86400)
    @State private var networkFilter = "Tous"

    var from: Date { range == 0 ? customFrom : Date().addingTimeInterval(-Double(range) * 86400) }
    var to: Date { range == 0 ? customTo : Date() }

    var tests: [SpeedTestResult] {
        model.speedTests.filter { $0.timestamp >= from && $0.timestamp <= to && $0.succeeded && $0.mode != .lan }
            .filter { networkFilter == "Tous" || $0.networkName == networkFilter }
            .sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        Page("History & Reports", subtitle: "Historique local des mesures (consultable hors ligne), comparaisons et exports") {
            HStack {
                Picker("Période", selection: $range) {
                    Text("24 h").tag(1); Text("7 jours").tag(7); Text("30 jours").tag(30); Text("90 jours").tag(90); Text("Personnalisée").tag(0)
                }.pickerStyle(.segmented).frame(width: 440)
                if range == 0 {
                    DatePicker("Du", selection: $customFrom, displayedComponents: .date).labelsHidden()
                    DatePicker("au", selection: $customTo, displayedComponents: .date).labelsHidden()
                }
                Picker("Réseau", selection: $networkFilter) {
                    Text("Tous").tag("Tous")
                    ForEach(Array(Set(model.speedTests.compactMap(\.networkName))).sorted(), id: \.self) { Text(model.redact($0)).tag($0) }
                }.frame(width: 220)
            }
            if tests.isEmpty {
                EmptyStateView(title: "Aucune mesure sur la période", symbol: "chart.xyaxis.line", message: "Les tests de débit réalisés apparaîtront ici.")
            } else {
                Card("Débits", symbol: "arrow.up.arrow.down") {
                    Chart(tests) { t in
                        if let d = t.downloadBps { PointMark(x: .value("Date", t.timestamp), y: .value("Mbit/s", d / 1e6)).foregroundStyle(by: .value("Sens", "Descendant")) }
                        if let u = t.uploadBps { PointMark(x: .value("Date", t.timestamp), y: .value("Mbit/s", u / 1e6)).foregroundStyle(by: .value("Sens", "Montant")) }
                    }.chartYAxisLabel("Mbit/s").frame(height: 200)
                }
                Card("Latence", symbol: "timer") {
                    Chart(tests) { t in
                        if let i = t.idleLatencyMs { LineMark(x: .value("Date", t.timestamp), y: .value("ms", i), series: .value("Type", "Repos")).foregroundStyle(by: .value("Type", "Repos")) }
                        if let l = t.worstLoadedLatencyMs { LineMark(x: .value("Date", t.timestamp), y: .value("ms", l), series: .value("Type", "Sous charge")).foregroundStyle(by: .value("Type", "Sous charge")) }
                    }.chartYAxisLabel("ms").frame(height: 180)
                }
                comparisons
            }
            exportsCard
        }
    }

    var comparisons: some View {
        Card("Comparaisons", symbol: "square.split.2x1") {
            let kinds = Dictionary((model.connection?.interfaces ?? []).map { ($0.bsdName, $0.kind) }, uniquingKeysWith: { a, _ in a })
            let wifi = tests.filter { kinds[$0.interfaceName ?? ""] == .wifi }.compactMap(\.downloadBps)
            let eth = tests.filter { kinds[$0.interfaceName ?? ""] == .ethernet }.compactMap(\.downloadBps)
            Text("Wi-Fi / Ethernet").font(.subheadline.bold())
            KeyValueRow(label: "Médiane descendante Wi-Fi (\(wifi.count) tests)", value: Stats.median(wifi).map(Units.bitRate))
            KeyValueRow(label: "Médiane descendante Ethernet (\(eth.count) tests)", value: Stats.median(eth).map(Units.bitRate))
            Text("Par réseau").font(.subheadline.bold())
            let grouped = Dictionary(grouping: tests, by: { $0.networkName ?? "?" })
            ForEach(grouped.keys.sorted(), id: \.self) { name in
                let ts = grouped[name] ?? []
                KeyValueRow(label: "\(model.redact(name)) (\(ts.count))", value: Stats.median(ts.compactMap(\.downloadBps)).map(Units.bitRate))
            }
            Text("Heures de la journée (médiane descendante)").font(.subheadline.bold())
            let byHour = Dictionary(grouping: tests, by: { Calendar.current.component(.hour, from: $0.timestamp) })
                .map { HourBucket(hour: $0.key, value: Stats.median($0.value.compactMap(\.downloadBps)) ?? 0) }.sorted { $0.hour < $1.hour }
            Chart(byHour) { BarMark(x: .value("Heure", $0.hour), y: .value("Mbit/s", $0.value / 1e6)) }
                .chartXScale(domain: 0...23).frame(height: 140)
            Divider()
            Text("Avant / après (campagnes)").font(.subheadline.bold())
            DatePicker("Séparation", selection: $split, in: from...to)
            let before = tests.filter { $0.timestamp < split }, after = tests.filter { $0.timestamp >= split }
            ForEach([
                CampaignComparison.compare(metric: "Débit descendant", before: before.compactMap(\.downloadBps), after: after.compactMap(\.downloadBps), lowerIsBetter: false),
                CampaignComparison.compare(metric: "Débit montant", before: before.compactMap(\.uploadBps), after: after.compactMap(\.uploadBps), lowerIsBetter: false),
                CampaignComparison.compare(metric: "Latence au repos", before: before.compactMap(\.idleLatencyMs), after: after.compactMap(\.idleLatencyMs), lowerIsBetter: true),
                CampaignComparison.compare(metric: "Latence sous charge", before: before.compactMap(\.worstLoadedLatencyMs), after: after.compactMap(\.worstLoadedLatencyMs), lowerIsBetter: true),
            ], id: \.metric) { c in
                VStack(alignment: .leading) {
                    HStack { Text(c.metric).bold(); Spacer(); Text(c.outcome.rawValue).foregroundStyle(c.outcome == .improved ? .green : (c.outcome == .degraded ? .red : .secondary)) }
                    Text(c.explanation).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    var exportsCard: some View {
        Card("Exports", symbol: "square.and.arrow.up") {
            HStack {
                Button("Mesures (CSV)") { ReportExporter.saveText(CSVExport.speedTests(tests), name: "netscope-mesures.csv", type: .commaSeparatedText) }.glassButton()
                Button("Mesures (JSON)") {
                    let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted; enc.dateEncodingStrategy = .iso8601
                    if let d = try? enc.encode(tests) { ReportExporter.saveText(String(decoding: d, as: UTF8.self), name: "netscope-mesures.json", type: .json) }
                }.glassButton()
                Button("Monitoring (CSV)") { ReportExporter.saveText(CSVExport.health(model.healthSamples), name: "netscope-monitoring.csv", type: .commaSeparatedText) }.glassButton()
                Button("Rapport de performance (PDF)") {
                    let d = model.diagnostic ?? DiagnosticsEngine.analyze(model.diagnosticInput())
                    ReportExporter.save(ReportBuilder.diagnostic(d, tests: tests, network: model.networkName).redacted(model.redactor), suggestedName: "netscope-rapport")
                }.prominentGlassButton()
            }
            Text("Le mode confidentialité (barre d’outils) masque IP, MAC et SSID dans les rapports. Le rapport pour l’opérateur se génère depuis ISP Performance Audit.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var apiKey = ""
    @State private var confirmErase = false

    var body: some View {
        TabView {
            Form {
                Section("Confidentialité") {
                    Toggle("Mode confidentialité (masquer IP, MAC, SSID)", isOn: $model.settings.privacyMode)
                    Toggle("Autoriser la vérification de l’IP publique (requête vers Cloudflare)", isOn: $model.settings.allowExternalIPLookup)
                    Text("NetScope fonctionne localement. Aucune télémétrie. Aucune donnée n’est envoyée sans votre accord.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Mesures") {
                    Toggle("Mode consommation réduite", isOn: $model.settings.reducedDataMode)
                    TextField("Cibles de latence (séparées par des virgules)", text: Binding(
                        get: { model.settings.latencyTargets.joined(separator: ", ") },
                        set: { model.settings.latencyTargets = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter(ArgumentValidator.isValidHost) }))
                    TextField("Serveur iperf3 LAN (votre machine)", text: $model.settings.lanServer)
                    Text(model.lanService.isAvailable ? "iperf3 détecté sur ce Mac." : "iperf3 non installé sur ce Mac (optionnel : brew install iperf3).").font(.caption).foregroundStyle(.secondary)
                }
                Section("Tests planifiés") {
                    Toggle("Activer les tests planifiés (Quick Test, mode réduit)", isOn: $model.settings.scheduledTestsEnabled).disabled(!model.settings.acknowledgedDataUsage)
                    Stepper("Intervalle : \(Int(model.settings.scheduledIntervalHours)) h", value: $model.settings.scheduledIntervalHours, in: 1...24)
                    Stepper("Maximum par jour : \(model.settings.scheduledMaxPerDay)", value: $model.settings.scheduledMaxPerDay, in: 1...12)
                }
                Section("Historique") {
                    Stepper("Conserver les événements et le monitoring : \(model.settings.retentionDays) jours", value: $model.settings.retentionDays, in: 7...365, step: 7)
                    Button("Importer la base fabricants IEEE (oui.csv)…") {
                        let p = NSOpenPanel(); p.allowedContentTypes = [.commaSeparatedText]
                        if p.runModal() == .OK, let u = p.url { model.importOUI(u) }
                    }
                    Text(model.oui.isEmpty ? "Aucune base importée." : "\(model.oui.vendors.count) préfixes chargés.").font(.caption)
                    Button("Effacer tout l’historique local…", role: .destructive) { confirmErase = true }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Général", systemImage: "gear") }

            Form {
                Section("Assistant IA optionnel") {
                    Toggle("Activer l’assistant IA (Anthropic Claude)", isOn: $model.settings.aiAssistantEnabled)
                    SecureField("Clé API (stockée dans le trousseau)", text: $apiKey)
                    HStack {
                        Button("Enregistrer la clé") { try? model.secrets.write(ClaudeAssistantClient.keychainKey, value: apiKey); apiKey = "" }.disabled(apiKey.isEmpty)
                        Button("Supprimer la clé", role: .destructive) { try? model.secrets.delete(ClaudeAssistantClient.keychainKey) }
                    }
                    Text("Chaque envoi demande une confirmation et transmet uniquement un résumé masqué du diagnostic. Le diagnostic local fonctionne sans IA.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Assistant", systemImage: "sparkles") }

            Form {
                Section("Système (audit au lancement, lecture seule)") {
                    LabeledContent("macOS", value: model.facts.osVersion)
                    LabeledContent("Processeur", value: model.facts.cpu.isEmpty ? (model.facts.appleSilicon ? "Apple Silicon" : "Intel") : model.facts.cpu)
                    LabeledContent("Modèle", value: model.facts.model)
                    LabeledContent("Liquid Glass natif", value: model.facts.liquidGlassAvailable ? "Disponible" : "Repli sur les matériaux système")
                    LabeledContent("Localisation (SSID/BSSID)", value: model.wifiService.locationState.rawValue)
                    LabeledContent("Interfaces Wi-Fi", value: model.wifiService.interfaceNames.joined(separator: ", "))
                }
                Section("Matrice de faisabilité") {
                    ForEach(model.feasibility) { f in
                        HStack { CheckStatusBadge(status: f.status); Text(f.feature); Spacer(); Text(f.note).font(.caption).foregroundStyle(.secondary) }
                    }
                    if let c = model.speedCaps { LabeledContent("Options networkQuality", value: c.flags.sorted().joined(separator: " ")) }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Environnement", systemImage: "cpu") }
        }
        .confirmationDialog("Effacer tout l’historique local ?", isPresented: $confirmErase) {
            Button("Effacer", role: .destructive) { model.eraseHistory() }
        } message: { Text("Mesures, événements, inventaire, projets heatmap et journal seront supprimés de ce Mac. Irréversible.") }
    }
}
#endif
