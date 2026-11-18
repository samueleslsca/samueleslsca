#if os(macOS)
import SwiftUI
import Charts
import NetScopeCore
import NetScopeSystem

// MARK: - Bufferbloat & QoS Lab (P0)

struct BufferbloatLabView: View {
    @EnvironmentObject var model: AppModel
    @State private var target = "1.1.1.1"
    @State private var trialsToRun = 3
    @State private var label = "avant"
    @State private var running = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        let campaign = model.bufferbloatTrials.filter { $0.label == label }
        let report = BufferbloatAnalyzer.analyze(campaign)
        Page("Bufferbloat & QoS Lab", subtitle: "Latence au repos, sous charge descendante et sous charge montante — plusieurs essais, comparaison avant/après") {
            if !model.settings.acknowledgedDataUsage { ErrorBanner(message: "Acceptez d’abord la consommation de données dans Speedtest.") }
            Card("Campagne", symbol: "flask") {
                HStack {
                    TextField("Cible ICMP", text: $target).textFieldStyle(.roundedBorder).frame(width: 160)
                    Stepper("Essais : \(trialsToRun)", value: $trialsToRun, in: 1...10)
                    Picker("Étiquette", selection: $label) { Text("Avant modification").tag("avant"); Text("Après modification").tag("après") }.frame(width: 240)
                    Spacer()
                    if running { Button("Annuler") { task?.cancel(); model.cancelSpeedTest() }.glassButton() }
                    else {
                        Button("Lancer") { run() }.disabled(!model.settings.acknowledgedDataUsage || !ArgumentValidator.isValidHost(target)).prominentGlassButton()
                    }
                }
                if let r = model.runningTest, r.mode == .bufferbloat { Label(r.phase, systemImage: "hourglass").font(.callout) }
                if let e = error { ErrorBanner(message: e) }
                Text("La cible est sondée par ping toutes les 200 ms pendant que networkQuality sature un seul sens à la fois. Choisir la passerelle (\(model.connection?.defaultGatewayIPv4 ?? "—")) isole la file d’attente du Wi-Fi/LAN ; une cible Internet inclut celle de l’accès WAN.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                Card("Résultat « \(label) »", symbol: "hourglass") {
                    HStack(spacing: 24) {
                        BigNumber(title: "Note globale", value: report.overallGrade?.rawValue ?? "—", tint: gradeColor(report.overallGrade))
                        BigNumber(title: "Repos", value: report.idleMedianMs.map { String(format: "%.0f", $0) } ?? "—", unit: "ms", tint: .teal)
                        BigNumber(title: "+ charge ↓", value: report.download.addedMedianMs.map { String(format: "%.0f", $0) } ?? "—", unit: "ms", tint: gradeColor(report.download.grade))
                        BigNumber(title: "+ charge ↑", value: report.upload.addedMedianMs.map { String(format: "%.0f", $0) } ?? "—", unit: "ms", tint: gradeColor(report.upload.grade))
                    }
                    Text(report.verdict).font(.callout)
                    KeyValueRow(label: "Essais", value: "\(report.trials)")
                    KeyValueRow(label: "P95 ajouté ↓ / ↑", value: "\(Units.ms(report.download.addedP95Ms)) / \(Units.ms(report.upload.addedP95Ms))")
                    KeyValueRow(label: "Écart entre essais ↓ / ↑", value: "\(Units.ms(report.download.trialSpreadMs)) / \(Units.ms(report.upload.trialSpreadMs))")
                    ConfidenceLabel(confidence: report.confidence)
                }
                Card("QoS / SQM", symbol: "slider.horizontal.below.square.filled.and.square") {
                    if model.router.capabilities.contains(.qos) {
                        Text("Le routeur expose des réglages QoS via son API.")
                    } else {
                        Text("Aucun adaptateur actif n’expose la QoS/SQM. Si votre box le propose (fq_codel, CAKE, « QoS intelligente »), activez-la dans son interface, en limitant à 90–95 % du débit mesuré, puis relancez une campagne « après ».")
                            .font(.callout)
                    }
                }.frame(width: 320)
            }
            if let last = campaign.last {
                Card("Dernier essai — distribution", symbol: "chart.dots.scatter") {
                    Chart {
                        ForEach(last.idleMs.indices, id: \.self) { i in PointMark(x: .value("Phase", "Repos"), y: .value("ms", last.idleMs[i])).foregroundStyle(.teal).opacity(0.4) }
                        ForEach(last.downloadLoadedMs.indices, id: \.self) { i in PointMark(x: .value("Phase", "Charge ↓"), y: .value("ms", last.downloadLoadedMs[i])).foregroundStyle(.blue).opacity(0.4) }
                        ForEach(last.uploadLoadedMs.indices, id: \.self) { i in PointMark(x: .value("Phase", "Charge ↑"), y: .value("ms", last.uploadLoadedMs[i])).foregroundStyle(.purple).opacity(0.4) }
                    }.chartYAxisLabel("ms").frame(height: 200)
                }
            }
            comparisonCard
            Card("Méthode", symbol: "info.circle") { Text(BufferbloatAnalyzer.methodology).font(.caption).foregroundStyle(.secondary) }
        }
    }

    var comparisonCard: some View {
        let before = model.bufferbloatTrials.filter { $0.label == "avant" }
        let after = model.bufferbloatTrials.filter { $0.label == "après" }
        func added(_ ts: [BufferbloatTrial], _ kp: KeyPath<BufferbloatTrial, [Double]>) -> [Double] {
            ts.compactMap { t in Stats.median(t[keyPath: kp]).flatMap { l in Stats.median(t.idleMs).map { max(0, l - $0) } } }
        }
        let comps = [
            CampaignComparison.compare(metric: "Latence ajoutée ↓", before: added(before, \.downloadLoadedMs), after: added(after, \.downloadLoadedMs), lowerIsBetter: true),
            CampaignComparison.compare(metric: "Latence ajoutée ↑", before: added(before, \.uploadLoadedMs), after: added(after, \.uploadLoadedMs), lowerIsBetter: true),
            CampaignComparison.compare(metric: "Débit ↓ sous test", before: before.compactMap(\.downloadBps), after: after.compactMap(\.downloadBps), lowerIsBetter: false),
        ]
        return Card("Rapport de réactivité avant / après", symbol: "arrow.left.arrow.right") {
            ForEach(comps, id: \.metric) { c in
                HStack { Text(c.metric).bold(); Spacer(); Text(c.outcome.rawValue).foregroundStyle(c.outcome == .improved ? .green : (c.outcome == .degraded ? .red : .secondary)) }
                Text(c.explanation).font(.caption).foregroundStyle(.secondary)
            }
            Text("Une correction du bufferbloat n’est annoncée que si la comparaison montre une amélioration mesurée sur au moins 3 essais de chaque côté.").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    func run() {
        running = true; error = nil
        task = Task {
            for _ in 0..<trialsToRun {
                if Task.isCancelled { break }
                do { _ = try await model.runBufferbloatTrial(target: target, label: label) }
                catch { self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"; break }
            }
            running = false
        }
    }

    func gradeColor(_ g: BloatGrade?) -> Color {
        switch g { case .aPlus, .a: return .green; case .b: return .yellow; case .c: return .orange; case .d, .f: return .red; case .none: return .secondary }
    }
}

// MARK: - Internet Health Monitor (P0)

struct HealthMonitorView: View {
    @EnvironmentObject var model: AppModel
    @State private var days = 1

    var body: some View {
        let to = Date(), from = to.addingTimeInterval(-Double(days) * 86400)
        let baseline = model.healthSamples.filter { $0.timestamp < from && $0.timestamp >= from.addingTimeInterval(-7 * 86400) }
        let report = HealthAnalyzer.report(samples: model.healthSamples, from: from, to: to, baseline: baseline)
        Page("Internet Health Monitor", subtitle: "Vérifications légères périodiques (ping passerelle, 2 cibles, 1 requête DNS) — jamais de test de débit en continu") {
            Card("Surveillance", symbol: "waveform.path.ecg") {
                Toggle("Activer la surveillance longue durée", isOn: $model.settings.healthMonitorEnabled)
                Stepper("Intervalle : \(Int(model.settings.healthIntervalSeconds)) s", value: $model.settings.healthIntervalSeconds, in: 15...900, step: 15)
                Toggle("Mode basse consommation (une vérification toutes les 5 min)", isOn: $model.settings.lowPowerMonitoring)
                Text("Chaque vérification transfère moins de 2 Ko. La surveillance s’arrête quand l’application est quittée.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Période", selection: $days) { Text("24 h").tag(1); Text("7 jours").tag(7); Text("30 jours").tag(30) }.pickerStyle(.segmented).frame(width: 300)
            HStack(spacing: 16) {
                Card("Disponibilité", symbol: "checkmark.circle") {
                    BigNumber(title: "Sur la période", value: report.availabilityPercent.map { String(format: "%.2f", $0) } ?? "—", unit: "%")
                    KeyValueRow(label: "Vérifications", value: "\(report.samples)")
                    KeyValueRow(label: "Coupures", value: "\(report.outages.count) · \(Int(report.totalDowntime / 60)) min au total")
                }
                Card("Latence et pertes", symbol: "timer") {
                    KeyValueRow(label: "Internet médiane / P95", value: "\(Units.ms(report.internetLatencyMedianMs)) / \(Units.ms(report.internetLatencyP95Ms))")
                    KeyValueRow(label: "Passerelle médiane", value: Units.ms(report.gatewayLatencyMedianMs))
                    KeyValueRow(label: "Pertes moyennes", value: report.meanLossPercent.map { String(format: "%.2f %%", $0) })
                    KeyValueRow(label: "Échecs DNS", value: "\(report.dnsFailures)")
                    KeyValueRow(label: "Changements d’interface", value: "\(report.interfaceChanges)")
                }
            }
            let samples = model.healthSamples.filter { $0.timestamp >= from }
            if !samples.isEmpty {
                Card("Chronologie", symbol: "chart.xyaxis.line") {
                    Chart {
                        ForEach(samples) { s in
                            if let r = s.internetRTTms { LineMark(x: .value("t", s.timestamp), y: .value("ms", r)).foregroundStyle(.blue) }
                            if !s.internetReachable { RuleMark(x: .value("t", s.timestamp)).foregroundStyle(.red.opacity(0.5)) }
                        }
                    }.chartYAxisLabel("ms").frame(height: 180)
                    Text("Traits rouges : vérification sans réponse Internet.").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Card("Tendances", symbol: "chart.line.uptrend.xyaxis") {
                if report.trends.isEmpty { Text("Aucune tendance anormale détectée (au moins 20 mesures de référence nécessaires).").foregroundStyle(.secondary) }
                ForEach(report.trends, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.callout) }
            }
            Card("Connection Timeline — coupures et changements", symbol: "clock.arrow.circlepath") {
                ForEach(report.outages.reversed()) { o in
                    Text("\(o.start.shortDateTime) → \(o.end?.shortDateTime ?? "en cours") · \(o.duration.map { "\(Int($0)) s" } ?? "—") · \(o.kind.rawValue)").font(.callout)
                }
                ForEach(model.events.filter { [.interfaceChanged, .ssidChanged, .vpnStateChanged, .connectivityLost, .connectivityRestored].contains($0.kind) }.prefix(20)) { e in
                    Text("\(e.timestamp.shortDateTime) · \(model.redact(e.message))").font(.caption).foregroundStyle(.secondary)
                }
                Button("Rapport (PDF)") {
                    let r = Report(title: "NetScope Pro — Santé de la connexion", subtitle: "\(from.shortDateTime) → \(to.shortDateTime)", sections: [
                        .init(heading: "Synthèse", bullets: [
                            "Disponibilité : \(report.availabilityPercent.map { String(format: "%.2f %%", $0) } ?? "—")",
                            "Coupures : \(report.outages.count), durée totale \(Int(report.totalDowntime / 60)) min",
                            "Latence Internet médiane : \(Units.ms(report.internetLatencyMedianMs))", "Échecs DNS : \(report.dnsFailures)"] + report.trends),
                        .init(heading: "Coupures", tables: [Report.Table(header: ["Début", "Fin", "Type"], rows: report.outages.map { [$0.start.shortDateTime, $0.end?.shortDateTime ?? "en cours", $0.kind.rawValue] })]),
                        .init(heading: "Limites", bullets: ["Une vérification toutes les \(Int(model.settings.healthIntervalSeconds)) s : une coupure plus courte peut passer inaperçue.", "Une coupure n’est déclarée qu’après 2 échecs consécutifs."]),
                    ])
                    ReportExporter.save(r.redacted(model.redactor), suggestedName: "netscope-sante")
                }.glassButton()
            }
        }
    }
}

// MARK: - Multi-point diagnostics (P0)

struct MultipointView: View {
    @EnvironmentObject var model: AppModel
    @State private var host = ""
    @State private var port = 8765
    @State private var code = ""
    @State private var name = "Raspberry Pi"
    @State private var pairing = false
    @State private var message: String?
    @State private var verdicts: [SegmentVerdict] = []
    @State private var running = false
    @State private var lines: [String] = []

    var body: some View {
        Page("Multi-point Network Diagnostics", subtitle: "Comparer les mesures du Mac avec celles d’un agent filaire et d’un serveur LAN pour localiser le segment responsable") {
            Card("Agents appairés", symbol: "point.3.filled.connected.trianglepath.dotted") {
                if model.agents.isEmpty { Text("Aucun agent. Lancez Agent/netscope_agent.py sur une machine de votre réseau (idéalement en Ethernet), puis appairez-la avec le code affiché.").foregroundStyle(.secondary) }
                ForEach(model.agents) { a in
                    HStack {
                        Image(systemName: "cpu")
                        VStack(alignment: .leading) {
                            Text(a.name).bold()
                            Text("\(model.redact(a.host)):\(a.port) · certificat \(a.certificateSHA256.prefix(16))… · appairé \(a.paired.relative)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Oublier", role: .destructive) { model.agents.removeAll { $0.id == a.id }; model.saveAgents() }.buttonStyle(.link)
                    }
                }
                DisclosureGroup("Appairer un agent") {
                    HStack {
                        TextField("Nom", text: $name).frame(width: 140)
                        TextField("Adresse IP", text: $host).frame(width: 160)
                        TextField("Port", value: $port, format: .number).frame(width: 70)
                        TextField("Code d’appairage", text: $code).frame(width: 120)
                        Button(pairing ? "Appairage…" : "Appairer") { pair() }.disabled(pairing || host.isEmpty || code.count < 6).glassButton()
                    }.textFieldStyle(.roundedBorder)
                    Text("Connexion HTTPS chiffrée. Le certificat de l’agent est épinglé : comparez son empreinte à celle affichée par l’agent.").font(.caption).foregroundStyle(.secondary)
                }
                if let m = message { Text(m).font(.callout) }
            }
            Card("Campagne de mesures", symbol: "play.circle") {
                Button(running ? "Mesures en cours…" : "Lancer la comparaison") { Task { await campaign() } }.disabled(running || model.agents.isEmpty).prominentGlassButton()
                ForEach(lines, id: \.self) { Text(model.redact($0)).font(.caption.monospaced()) }
            }
            Card("Localisation du segment", symbol: "scope") {
                if verdicts.isEmpty { Text("Les conclusions apparaissent après une campagne. Plus il y a de points de mesure, plus la localisation est fiable.").foregroundStyle(.secondary) }
                ForEach(verdicts) { v in
                    VStack(alignment: .leading) {
                        HStack { Image(systemName: v.suspected ? "exclamationmark.triangle.fill" : "checkmark.circle").foregroundStyle(v.suspected ? .orange : .green)
                            Text(v.segment).bold(); Spacer(); ConfidenceLabel(confidence: v.confidence) }
                        ForEach(v.evidence, id: \.self) { Text("• " + $0).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    func pair() {
        pairing = true; message = nil
        Task {
            do {
                let p = try await model.agentClient.pair(host: host, port: port, code: code, name: name)
                model.agents.append(p); model.saveAgents()
                message = "Agent appairé. Empreinte du certificat : \(p.certificateSHA256) — vérifiez qu’elle correspond à celle affichée par l’agent."
                code = ""
            } catch { message = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            pairing = false
        }
    }

    func campaign() async {
        guard let agent = model.agents.first else { return }
        running = true; lines = []
        defer { running = false }
        let target = model.settings.latencyTargets.first ?? "1.1.1.1"
        var m = SegmentMeasurements()
        if let gw = model.connection?.defaultGatewayIPv4 {
            m.macGatewayLatency = try? await model.latencyService.ping(gw, count: 20, interval: 0.2)
            lines.append("Mac → passerelle : \(Units.ms(m.macGatewayLatency?.medianMs)), pertes \(m.macGatewayLatency.map { String(format: "%.0f %%", $0.lossPercent) } ?? "—")")
            do {
                m.agentGatewayLatency = try await model.agentClient.ping(agent, target: gw)
                lines.append("Agent → passerelle : \(Units.ms(m.agentGatewayLatency?.medianMs)), pertes \(m.agentGatewayLatency.map { String(format: "%.0f %%", $0.lossPercent) } ?? "—")")
            } catch { lines.append("Agent → passerelle : \((error as? LocalizedError)?.errorDescription ?? "\(error)")") }
        }
        m.macInternetLatency = try? await model.latencyService.ping(target, count: 20, interval: 0.2)
        lines.append("Mac → \(target) : \(Units.ms(m.macInternetLatency?.medianMs))")
        m.agentInternetLatency = try? await model.agentClient.ping(agent, target: target)
        lines.append("Agent → \(target) : \(Units.ms(m.agentInternetLatency?.medianMs))")
        if model.lanService.isAvailable {
            if let info = try? await model.agentClient.info(agent), (info["iperf3"] as? Bool) == true {
                _ = try? await model.agentClient.startIperfServer(agent)
                try? await Task.sleep(nanoseconds: 800_000_000)
                if let r = try? await model.lanService.run(server: agent.host, reverse: true, seconds: 6) {
                    m.lanThroughputBps = r.receivedBps
                    lines.append("Débit LAN agent → Mac (iperf3) : \(r.receivedBps.map(Units.bitRate) ?? r.error ?? "—")")
                }
            } else { lines.append("iperf3 absent sur l’agent : débit LAN non mesuré") }
        } else { lines.append("iperf3 absent sur ce Mac : débit LAN non mesuré") }
        let kinds = Dictionary((model.connection?.interfaces ?? []).map { ($0.bsdName, $0.kind) }, uniquingKeysWith: { a, _ in a })
        let recent = model.speedTests.filter { $0.succeeded && $0.timestamp > Date().addingTimeInterval(-7 * 86400) && $0.mode != .lan }
        m.macWiFiInternetDownBps = Stats.median(recent.filter { kinds[$0.interfaceName ?? ""] == .wifi }.compactMap(\.downloadBps))
        m.macWiredInternetDownBps = Stats.median(recent.filter { kinds[$0.interfaceName ?? ""] == .ethernet }.compactMap(\.downloadBps))
        m.routerSyncDownBps = model.router.wan?.syncDownBps
        verdicts = SegmentLocalizer.localize(m)
    }
}


// MARK: - ISP Performance Audit (P1)

struct ISPAuditView: View {
    @EnvironmentObject var model: AppModel
    @State private var down = ""
    @State private var up = ""
    @State private var gDown = ""
    @State private var gUp = ""

    var body: some View {
        let audit = ISPAuditor.audit(profile: model.ispProfile, tests: model.speedTests, ethernetInterfaces: model.ethernetInterfaceNames, outages: model.outagesAll)
        Page("ISP Performance Audit", subtitle: "Comparer les performances observées à votre abonnement et constituer un dossier factuel") {
            Card("Abonnement", symbol: "doc.text") {
                Form {
                    TextField("Opérateur", text: $model.ispProfile.provider)
                    TextField("Offre", text: $model.ispProfile.plan)
                    Picker("Type d’accès", selection: $model.ispProfile.accessType) { ForEach(AccessType.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    HStack { TextField("Débit commercial ↓ (Mbit/s)", text: $down); TextField("↑ (Mbit/s)", text: $up) }
                    HStack { TextField("Débit garanti ↓ (Mbit/s, si contractuel)", text: $gDown); TextField("↑", text: $gUp) }
                    Button("Enregistrer") {
                        model.ispProfile.advertisedDownBps = Double(down.replacingOccurrences(of: ",", with: ".")).map { $0 * 1e6 }
                        model.ispProfile.advertisedUpBps = Double(up.replacingOccurrences(of: ",", with: ".")).map { $0 * 1e6 }
                        model.ispProfile.guaranteedDownBps = Double(gDown.replacingOccurrences(of: ",", with: ".")).map { $0 * 1e6 }
                        model.ispProfile.guaranteedUpBps = Double(gUp.replacingOccurrences(of: ",", with: ".")).map { $0 * 1e6 }
                        model.saveISP()
                    }.glassButton()
                }
                .onAppear {
                    down = model.ispProfile.advertisedDownBps.map { String(format: "%.0f", $0 / 1e6) } ?? ""
                    up = model.ispProfile.advertisedUpBps.map { String(format: "%.0f", $0 / 1e6) } ?? ""
                    gDown = model.ispProfile.guaranteedDownBps.map { String(format: "%.0f", $0 / 1e6) } ?? ""
                    gUp = model.ispProfile.guaranteedUpBps.map { String(format: "%.0f", $0 / 1e6) } ?? ""
                }
            }
            Card("Résultats", symbol: "chart.bar") {
                KeyValueRow(label: "Tests valides / dont Ethernet", value: "\(audit.totalTests) / \(audit.ethernetTests)")
                KeyValueRow(label: "Médiane ↓ (Ethernet)", value: (audit.ethernetMedianDownBps ?? audit.medianDownBps).map(Units.bitRate))
                KeyValueRow(label: "Part du débit commercial", value: audit.ratioToAdvertised.map { String(format: "%.0f %%", $0 * 100) }, provenance: audit.ratioToAdvertised == nil ? nil : .computed(formula: "médiane mesurée / débit annoncé"))
                KeyValueRow(label: "Heures de pointe / hors pointe", value: audit.peakVsOffPeak.map { String(format: "%.0f %%", $0 * 100) })
                ForEach(audit.findings, id: \.self) { Label($0, systemImage: "info.circle").font(.callout) }
                let hours = audit.byHour.map { HourBucket(hour: $0.key, value: $0.value) }.sorted { $0.hour < $1.hour }
                if !hours.isEmpty {
                    Chart(hours) { BarMark(x: .value("Heure", $0.hour), y: .value("Mbit/s", $0.value / 1e6)) }.chartXScale(domain: 0...23).frame(height: 140)
                }
            }
            Card("Vérifications restantes", symbol: "checklist.unchecked") {
                if audit.remainingChecks.isEmpty { Label("Dossier complet", systemImage: "checkmark.seal") }
                ForEach(audit.remainingChecks, id: \.self) { Label($0, systemImage: "circle").font(.callout) }
                Text(audit.disclaimer).font(.caption).foregroundStyle(.secondary)
                Button("Générer le rapport pour mon opérateur (PDF)") {
                    let health = HealthAnalyzer.report(samples: model.healthSamples, from: Date().addingTimeInterval(-30 * 86400), to: Date())
                    let r = ReportBuilder.ispReport(profile: model.ispProfile, audit: audit, tests: model.speedTests.filter(\.succeeded).suffix(60).map { $0 }, health: model.healthSamples.isEmpty ? nil : health)
                    ReportExporter.save(r.redacted(model.redactor), suggestedName: "rapport-operateur")
                }.prominentGlassButton()
            }
        }
    }
}

// MARK: - Gaming Network Lab (P1)

struct GamingLabView: View {
    @EnvironmentObject var model: AppModel
    @State private var newTarget = ""
    @State private var results: [LatencyStats] = []
    @State private var trace: [TracerouteHop] = []
    @State private var running = false

    var body: some View {
        let loaded = model.latestTest.flatMap { t in t.worstLoadedLatencyMs.flatMap { l in t.idleLatencyMs.map { max(0, l - $0) } } }
        let assessment = GamingAnalyzer.assess(results, loadedAddedMs: loaded)
        let nat = NATAnalyzer.assess(localIP: model.connection?.primaryInterface?.ipv4.first?.address, gatewayIP: model.connection?.defaultGatewayIPv4,
                                     routerWANIP: model.router.wan?.ipv4, publicIP: model.publicIP.value, traceroute: trace)
        Page("Gaming Network Lab", subtitle: "Latence, pics, pertes et contraintes NAT — vers des destinations que vous choisissez") {
            Card("Destinations", symbol: "target") {
                HStack {
                    TextField("Hôte ou IP (ex. serveur de jeu documenté)", text: $newTarget).textFieldStyle(.roundedBorder)
                    Button("Ajouter") { if ArgumentValidator.isValidHost(newTarget) { model.settings.gamingTargets.append(newTarget); newTarget = "" } }.glassButton()
                }
                ForEach(model.settings.gamingTargets, id: \.self) { t in
                    HStack { Text(t); Spacer(); Button("Retirer") { model.settings.gamingTargets.removeAll { $0 == t } }.buttonStyle(.link) }
                }
                if model.settings.gamingTargets.isEmpty { Text("Sans destination personnalisée, les cibles de latence générales sont utilisées (\(model.settings.latencyTargets.joined(separator: ", "))).").font(.caption).foregroundStyle(.secondary) }
                Button(running ? "Mesure (100 paquets par cible)…" : "Lancer l’analyse") { Task { await run() } }.disabled(running).prominentGlassButton()
            }
            HStack(alignment: .top, spacing: 16) {
                Card("Aptitude", symbol: "gamecontroller") {
                    KeyValueRow(label: "Jeux compétitifs (FPS, combat)", value: assessment.competitive.rawValue)
                    KeyValueRow(label: "Jeux occasionnels / coopératifs", value: assessment.casual.rawValue)
                    KeyValueRow(label: "Latence ajoutée sous charge", value: assessment.loadedLatencyAddedMs.map { Units.ms($0) }, provenance: loaded == nil ? .unavailable(reason: "Aucun test de débit avec latence sous charge") : .measured(method: "networkQuality"))
                    ForEach(assessment.risks, id: \.self) { Label($0, systemImage: "exclamationmark.circle").font(.callout) }
                }
                Card("NAT", symbol: "arrow.triangle.branch") {
                    KeyValueRow(label: "CGNAT", value: nat.cgnat.rawValue)
                    ForEach(nat.cgnatEvidence, id: \.self) { Text("• " + model.redact($0)).font(.caption) }
                    KeyValueRow(label: "Double NAT", value: nat.doubleNAT.rawValue)
                    ForEach(nat.doubleNATEvidence, id: \.self) { Text("• " + model.redact($0)).font(.caption) }
                    ForEach(nat.implications, id: \.self) { Text($0).font(.callout) }
                    ForEach(nat.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if !assessment.targets.isEmpty {
                Card("Détail par destination", symbol: "list.bullet") {
                    ForEach(assessment.targets, id: \.target) { t in
                        KeyValueRow(label: t.target, value: "médiane \(Units.ms(t.medianMs)) · P99 \(Units.ms(t.p99Ms)) · gigue \(Units.ms(t.jitterMs)) · pertes \(String(format: "%.1f", t.lossPercent)) % · \(t.spikes) pic(s)",
                                    provenance: .measured(method: t.method))
                    }
                    if let r = results.first, r.samplesMs.count > 2 {
                        Chart(r.samplesMs.indices, id: \.self) { i in LineMark(x: .value("#", i), y: .value("ms", r.samplesMs[i])) }.chartYAxisLabel("ms").frame(height: 140)
                    }
                }
            }
            Card("Conseils consoles et ordinateurs", symbol: "lightbulb") {
                Text("• Branchez la console en Ethernet si possible.\n• Évitez les téléchargements (mises à jour, cloud) pendant les parties, ou activez la QoS/SQM.\n• Le type de NAT affiché par la console se consulte dans ses paramètres réseau ; NetScope ne le devine pas.\n• NetScope ne modifie jamais les redirections de ports et n’active pas l’UPnP.")
                    .font(.callout)
            }
        }
    }

    func run() async {
        running = true
        defer { running = false }
        let targets = model.settings.gamingTargets.isEmpty ? model.settings.latencyTargets : model.settings.gamingTargets
        var out: [LatencyStats] = []
        for t in targets {
            if let r = try? await model.latencyService.ping(t, count: 100, interval: 0.2) { out.append(r) }
            else { out.append(LatencyStats(target: t, sent: 100, received: 0, samplesMs: [], method: "ICMP (échec)")) }
        }
        results = out
        trace = (try? await model.traceService.trace(targets.first ?? "1.1.1.1", maxHops: 8)) ?? []
    }
}
#endif
