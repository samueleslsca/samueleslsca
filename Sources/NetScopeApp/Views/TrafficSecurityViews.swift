#if os(macOS)
import SwiftUI
import Charts
import NetScopeCore

struct TrafficMonitorView: View {
    @EnvironmentObject var model: AppModel
    @State private var processes: [ProcessTrafficService.ProcessRate] = []
    @State private var previous: [ProcessTrafficSample] = []
    @State private var previousAt = Date()
    @State private var sampler: Task<Void, Never>?
    @State private var processError: String?

    var body: some View {
        Page("Traffic Monitor", subtitle: "Trafic de ce Mac mesuré sur l’interface active — et trafic réseau lorsque le routeur le fournit") {
            HStack(spacing: 16) {
                let last = model.traffic.last
                Card("Instantané", symbol: "arrow.up.arrow.down") {
                    HStack(spacing: 28) {
                        BigNumber(title: "Entrant", value: last.map { String(format: "%.1f", $0.inBps / 1e6) } ?? "—", unit: "Mbit/s")
                        BigNumber(title: "Sortant", value: last.map { String(format: "%.1f", $0.outBps / 1e6) } ?? "—", unit: "Mbit/s", tint: .purple)
                    }
                    Text("Interface \(model.connection?.primaryInterface?.bsdName ?? "?") · compteurs 64 bits (sysctl)").font(.caption2).foregroundStyle(.tertiary)
                }
                Card("Session", symbol: "sum") {
                    HStack(spacing: 28) {
                        BigNumber(title: "Reçu", value: Units.bytes(model.sessionBytesIn))
                        BigNumber(title: "Envoyé", value: Units.bytes(model.sessionBytesOut), tint: .purple)
                    }
                    let peak = model.traffic.map { $0.inBps + $0.outBps }.max()
                    Text("Pic des 10 dernières minutes : \(peak.map(Units.bitRate) ?? "—") · depuis \(model.started.relative)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Card("Courbe de débit (10 min)", symbol: "chart.xyaxis.line") {
                if model.traffic.count < 2 { Text("Collecte en cours…").foregroundStyle(.secondary) }
                else {
                    Chart(model.traffic) { s in
                        AreaMark(x: .value("t", s.timestamp), y: .value("Mbit/s", s.inBps / 1e6), series: .value("Sens", "Entrant")).foregroundStyle(.blue.opacity(0.35))
                        LineMark(x: .value("t", s.timestamp), y: .value("Mbit/s", s.outBps / 1e6), series: .value("Sens", "Sortant")).foregroundStyle(.purple)
                    }
                    .chartYAxisLabel("Mbit/s").frame(height: 200)
                }
                if let bg = model.backgroundTrafficBps(), bg > 5e6 {
                    ErrorBanner(message: "Transferts importants en cours (\(Units.bitRate(bg))) : une mesure de débit lancée maintenant serait faussée.")
                }
            }
            Card("Par processus (nettop)", symbol: "list.number", trailing: AnyView(Text("toutes les 5 s pendant l’affichage").font(.caption).foregroundStyle(.secondary))) {
                if let e = processError { ErrorBanner(message: e) }
                if processes.isEmpty { Text("Premier échantillon en cours… (deux relevés sont nécessaires pour calculer un débit).").foregroundStyle(.secondary) }
                ForEach(processes.prefix(12)) { p in
                    HStack {
                        Text(p.process).lineLimit(1)
                        if let pid = p.pid { Text("PID \(pid)").font(.caption).foregroundStyle(.tertiary) }
                        Spacer()
                        Text("↓ \(Units.bitRate(p.inBps))  ↑ \(Units.bitRate(p.outBps))").monospacedDigit().font(.callout)
                    }
                }
                Text("Différence entre deux relevés des compteurs cumulés par processus fournis par nettop. Un processus absent d’un des relevés n’est pas comptabilisé.").font(.caption2).foregroundStyle(.tertiary)
            }
            Card("Trafic réseau (routeur)", symbol: "wifi.router") {
                if let w = model.router.wan {
                    KeyValueRow(label: "WAN instantané ↓ / ↑", value: "\(w.currentDownBps.map(Units.bitRate) ?? "—") / \(w.currentUpBps.map(Units.bitRate) ?? "—")", provenance: .router(adapter: model.router.adapterID ?? ""))
                    KeyValueRow(label: "Volume WAN cumulé ↓ / ↑", value: "\(w.totalBytesDown.map(Units.bytes) ?? "—") / \(w.totalBytesUp.map(Units.bytes) ?? "—")", provenance: .router(adapter: model.router.adapterID ?? ""))
                    let top = model.router.clients.filter { ($0.rxBytesPerSecond ?? 0) + ($0.txBytesPerSecond ?? 0) > 0 }
                        .sorted { ($0.rxBytesPerSecond ?? 0) + ($0.txBytesPerSecond ?? 0) > ($1.rxBytesPerSecond ?? 0) + ($1.txBytesPerSecond ?? 0) }
                    ForEach(top.prefix(8)) { c in
                        KeyValueRow(label: model.redact(c.name ?? c.mac ?? "?"), value: "↓ \(Units.bitRate((c.txBytesPerSecond ?? 0) * 8)) ↑ \(Units.bitRate((c.rxBytesPerSecond ?? 0) * 8))",
                                    provenance: .router(adapter: model.router.adapterID ?? ""))
                    }
                } else {
                    Text("Sans API routeur, NetScope ne peut pas connaître le trafic des autres appareils : il n’observe que ce Mac.").foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { startSampler() }
        .onDisappear { sampler?.cancel() }
    }

    func startSampler() {
        guard model.processTraffic.isAvailable else { processError = "nettop indisponible sur ce système."; return }
        sampler = Task {
            while !Task.isCancelled {
                do {
                    let cur = try await model.processTraffic.sample()
                    let now = Date()
                    if !previous.isEmpty { processes = ProcessTrafficService.rates(previous: previous, current: cur, seconds: now.timeIntervalSince(previousAt)) }
                    previous = cur; previousAt = now; processError = nil
                } catch { processError = (error as? LocalizedError)?.errorDescription }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
}

struct SecurityCenterView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let result = SecuritySnapshot.compute(model)
        Page("Security Center", subtitle: "Audit défensif : chaque contrôle est « vérifié », « suspect », « non vérifié » ou « indisponible » — sans conclusion automatique d’intrusion") {
            HStack(alignment: .top, spacing: 16) {
                Card("Score de sécurité", symbol: "lock.shield") {
                    HStack(spacing: 20) {
                        ScoreRing(score: result.score, size: 100)
                        VStack(alignment: .leading) {
                            ForEach(CheckStatus.allCases, id: \.self) { s in
                                HStack { CheckStatusBadge(status: s); Spacer(); Text("\(result.findings.filter { $0.status == s }.count)").monospacedDigit() }
                            }
                        }
                    }
                    Text(result.methodology).font(.caption).foregroundStyle(.secondary)
                }
                Card("Alertes", symbol: "bell.badge") {
                    Toggle("Nouvel appareil", isOn: $model.settings.notifyNewDevice)
                    Toggle("Changement de passerelle", isOn: $model.settings.notifyGatewayChange)
                    Toggle("Variation des DNS", isOn: $model.settings.notifyDNSChange)
                    Toggle("Déconnexions", isOn: $model.settings.notifyDisconnects)
                    Toggle("Baisse de performance", isOn: $model.settings.notifyPerformanceDrop)
                }.frame(width: 300)
            }
            Card("Contrôles", symbol: "checklist") {
                ForEach(result.findings) { f in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { CheckStatusBadge(status: f.status); Text(model.redact(f.title)).bold(); Spacer(); if f.severity != RiskLevel.none { Text("Gravité : \(f.severity.rawValue)").font(.caption).foregroundStyle(.secondary) } }
                        Text(model.redact(f.detail)).font(.callout).foregroundStyle(.secondary)
                        if let r = f.recommendation { Label(r, systemImage: "arrow.turn.down.right").font(.callout) }
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
            Card("Historique des alertes", symbol: "clock") {
                let alerts = model.events.filter { [.newDevice, .gatewayChanged, .dnsChanged, .connectivityLost, .outageStart, .routerAction].contains($0.kind) }
                if alerts.isEmpty { Text("Aucune alerte.").foregroundStyle(.secondary) }
                ForEach(alerts.prefix(30)) { e in Text("\(e.timestamp.shortDateTime) — \(e.kind.label) : \(model.redact(e.message))").font(.callout) }
            }
            Card("Confidentialité", symbol: "hand.raised") {
                Text("NetScope ne capture aucun paquet, ne lit aucun contenu échangé et ne collecte aucun mot de passe. Les vérifications de vulnérabilités publiques ne sont pas effectuées : la version de firmware est seulement rapportée.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

enum SecuritySnapshot {
    @MainActor static func compute(_ m: AppModel) -> SecurityAuditResult { SecurityAuditor.audit(m.securityInput) }
}

// MARK: - Diagnostics & Optimization

struct HypothesisView: View {
    var hypothesis: Hypothesis
    @EnvironmentObject var model: AppModel
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(hypothesis.symptoms, id: \.self) { Text("Symptôme : " + $0).font(.callout) }
                ForEach(hypothesis.supporting, id: \.self) { Label(model.redact($0), systemImage: "plus.circle").font(.callout).foregroundStyle(.primary) }
                ForEach(hypothesis.contradicting, id: \.self) { Label(model.redact($0), systemImage: "minus.circle").font(.callout).foregroundStyle(.secondary) }
                ForEach(hypothesis.nextChecks, id: \.self) { Label("À vérifier : " + $0, systemImage: "magnifyingglass").font(.callout) }
                ForEach(hypothesis.recommendations) { RecommendationRow(rec: $0) }
            }.padding(.leading, 4)
        } label: {
            HStack { Text(hypothesis.cause.rawValue).font(.headline); Spacer(); ConfidenceLabel(confidence: hypothesis.confidence) }
        }
    }
}

struct RecommendationRow: View {
    var rec: Recommendation
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(rec.title, systemImage: "wrench.and.screwdriver").font(.callout.bold())
            Text(rec.detail).font(.caption).foregroundStyle(.secondary)
            Text("Effet : \(rec.impact.rawValue) · efficacité \(rec.expectedEffectiveness.label.lowercased()) · risque \(rec.risk.rawValue.lowercased()) · \(rec.reversible ? "réversible" : "non réversible") · \(rec.cost)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @State private var steps = AppModel.wizardSteps()
    @State private var running = false
    @State private var includeSpeed = false
    @State private var compareResolvers = false
    @State private var advanced = false
    @State private var question: LocalAssistant.Question = .slowWiFi
    @State private var freeText = ""
    @State private var mode: OptimizationMode = .analysisOnly
    @State private var aiAnswer: String?
    @State private var aiRunning = false
    @State private var confirmAI = false

    var body: some View {
        Page("Diagnostics & Optimization", subtitle: "Assistant pas à pas : il explique pourquoi la connexion est lente ou instable, à partir de vos mesures") {
            Card("Diagnostic guidé", symbol: "stethoscope") {
                HStack {
                    Toggle("Inclure un speedtest complet (consomme des données)", isOn: $includeSpeed).disabled(!model.settings.acknowledgedDataUsage)
                    Toggle("Comparer avec des résolveurs DNS publics", isOn: $compareResolvers)
                    Spacer()
                    Toggle("Mode avancé", isOn: $advanced).toggleStyle(.switch)
                }
                ForEach(steps) { s in
                    HStack(alignment: .top) {
                        Image(systemName: icon(s.state)).foregroundStyle(color(s.state)).frame(width: 20)
                        VStack(alignment: .leading) {
                            Text("Étape \(s.id) — \(s.title)").font(.callout.bold())
                            if !s.summary.isEmpty, advanced || s.state == .failed { Text(model.redact(s.summary)).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if s.state == .running { ProgressView().controlSize(.small) }
                    }
                }
                Button(running ? "Diagnostic en cours…" : "Lancer le diagnostic") {
                    running = true; steps = AppModel.wizardSteps()
                    Task {
                        await model.runDiagnostics(includeSpeedTest: includeSpeed, compareResolvers: compareResolvers) { step in
                            if let i = steps.firstIndex(where: { $0.id == step.id }) { steps[i] = step }
                        }
                        running = false
                    }
                }.disabled(running).prominentGlassButton()
            }
            if let d = model.diagnostic {
                Card("Analyse finale", symbol: "list.clipboard", trailing: AnyView(Button("Exporter PDF") { exportPDF(d) }.glassButton())) {
                    Text("Faits observés").font(.subheadline.bold())
                    ForEach(d.observedFacts, id: \.self) { Text("• " + model.redact($0)).font(.callout) }
                    if !d.dataGaps.isEmpty {
                        Text("Données manquantes").font(.subheadline.bold())
                        ForEach(d.dataGaps, id: \.self) { Text("• " + $0).font(.callout).foregroundStyle(.secondary) }
                    }
                    Text("Hypothèses (par confiance)").font(.subheadline.bold())
                    ForEach(d.hypotheses) { HypothesisView(hypothesis: $0) }
                }
                optimizationCard(d)
            }
            assistantCard
        }
    }

    func optimizationCard(_ d: DiagnosticReport) -> some View {
        let plan = OptimizationCenter.plan(from: d)
        return Card("Optimization Center", symbol: "dial.medium") {
            Picker("Mode", selection: $mode) { ForEach(OptimizationMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            Text(mode.explanation).font(.caption).foregroundStyle(.secondary)
            if mode == .assisted {
                Text("Aucun réglage d’optimisation n’est actuellement modifiable via une API routeur validée (canal, QoS, DNS). NetScope ne modifie jamais automatiquement le routeur, les DNS, le pare-feu, le VPN ou la connexion active.")
                    .font(.callout).foregroundStyle(.orange)
            }
            group("Latence", plan.latency); group("Stabilité", plan.stability); group("Débit réel", plan.throughput); group("Diagnostic et autres", plan.other)
            Text("Avant/après : relancez les mêmes tests (même mode, même interface, même heure) au moins 3 fois ; History & Reports compare les campagnes en signalant la variabilité.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder func group(_ title: String, _ recs: [Recommendation]) -> some View {
        if !recs.isEmpty {
            Text(title).font(.subheadline.bold())
            ForEach(recs) { RecommendationRow(rec: $0) }
        }
    }

    var assistantCard: some View {
        Card("Assistant de diagnostic", symbol: "bubble.left.and.text.bubble.right") {
            Picker("Question", selection: $question) { ForEach(LocalAssistant.Question.allCases) { Text($0.rawValue).tag($0) } }
            HStack {
                TextField("…ou posez votre question", text: $freeText).textFieldStyle(.roundedBorder)
                    .onSubmit { if let q = LocalAssistant.Question.match(freeText) { question = q } }
            }
            let report = model.diagnostic ?? DiagnosticsEngine.analyze(model.diagnosticInput())
            let answer = LocalAssistant.answer(question, report: report)
            Text("Réponse locale (moteur de règles, hors ligne)").font(.subheadline.bold())
            if !answer.facts.isEmpty { Text("Faits : " + answer.facts.prefix(5).map(model.redact).joined(separator: " · ")).font(.caption) }
            ForEach(answer.hypotheses) { HypothesisView(hypothesis: $0) }
            ForEach(answer.caveats, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            Divider()
            if model.settings.aiAssistantEnabled {
                Button(aiRunning ? "Analyse en cours…" : "Demander une analyse IA (envoi à Anthropic)…") { confirmAI = true }
                    .disabled(aiRunning || !model.aiClient.isConfigured).glassButton()
                if !model.aiClient.isConfigured { Text("Ajoutez votre clé API dans Réglages.").font(.caption).foregroundStyle(.secondary) }
                if let a = aiAnswer { Text(a).font(.callout).textSelection(.enabled) }
            } else {
                Text("L’assistant IA optionnel est désactivé (Réglages). Le diagnostic local fonctionne sans lui.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Envoyer un résumé à l’API Anthropic ?", isPresented: $confirmAI) {
            Button("Envoyer (données masquées)") {
                aiRunning = true
                let report = model.diagnostic ?? DiagnosticsEngine.analyze(model.diagnosticInput())
                let ctx = LocalAssistant.structuredContext(report, redactor: PrivacyRedactor(enabled: true, ssids: [model.wifi?.ssid.value].compactMap { $0 }))
                let q = freeText.isEmpty ? question.rawValue : freeText
                Task {
                    do { aiAnswer = try await model.aiClient.ask(question: q, context: ctx) }
                    catch { aiAnswer = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
                    aiRunning = false
                }
            }
        } message: {
            Text("Seuls les faits, hypothèses et données manquantes du diagnostic sont envoyés, après masquage des adresses IP, MAC et du SSID. Rien n’est envoyé sans cette confirmation.")
        }
    }

    func icon(_ s: WizardStep.State) -> String {
        switch s { case .pending: return "circle"; case .running: return "circle.dotted"; case .done: return "checkmark.circle.fill"; case .skipped: return "minus.circle"; case .failed: return "xmark.circle.fill" }
    }
    func color(_ s: WizardStep.State) -> Color {
        switch s { case .done: return .green; case .failed: return .red; case .running: return .accentColor; default: return .secondary }
    }

    func exportPDF(_ d: DiagnosticReport) {
        let rep = ReportBuilder.diagnostic(d, tests: Array(model.speedTests.suffix(20)), network: model.networkName).redacted(model.redactor)
        ReportExporter.save(rep, suggestedName: "netscope-diagnostic")
    }
}
#endif
