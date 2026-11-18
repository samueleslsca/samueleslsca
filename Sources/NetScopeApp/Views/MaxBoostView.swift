#if os(macOS)
import SwiftUI
import Charts
import NetScopeCore

struct MaxBoostView: View {
    @EnvironmentObject var model: AppModel
    @State private var profile: BoostProfile = .smartAuto
    @State private var compareDNS = false
    @State private var sensitiveTarget: BoostCandidate?
    @State private var showHistory = false

    var session: BoostSession? { model.boostSession }
    var running: Bool { model.boostTask != nil }

    var body: some View {
        Page("MAX BOOST", subtitle: "Optimisation mesurée de votre connexion : rien n’est modifié sans votre autorisation, et aucun gain n’est annoncé sans mesure comparative") {
            if !model.settings.acknowledgedDataUsage {
                ErrorBanner(message: "MAX BOOST réalise plusieurs tests de débit. Acceptez d’abord la consommation de données dans l’onglet Speedtest.")
            }
            heroCard
            if running || session != nil { flowCard }
            if let s = session {
                scoreCard(s)
                if s.phase >= .recommendations { candidatesCard(s) }
                if !s.evaluations.isEmpty || !s.final.isEmpty { resultsCard(s) }
                if !s.changes.isEmpty { changesCard(s) }
                insightsCards(s)
            }
            historyCard
            safetyCard
        }
        .sheet(item: $sensitiveTarget) { c in SensitiveAuthorizationSheet(candidate: c) }
        .onAppear { model.loadBoostHistory() }
    }

    // MARK: Hero

    var heroCard: some View {
        Card("Profil d’optimisation", symbol: "bolt.circle") {
            HStack(spacing: 10) {
                ForEach(BoostProfile.allCases) { p in
                    Button { profile = p } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(p.label, systemImage: p.symbol).font(.callout.bold())
                            Text(p.goal).font(.caption).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading)
                        }
                        .padding(10).frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                        .background(profile == p ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(profile == p ? Color.accentColor : Color.secondary.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(profile == p ? .isSelected : [])
                }
            }
            HStack(alignment: .center, spacing: 24) {
                Button {
                    model.startBoost(profile: profile, compareDNS: compareDNS)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "bolt.fill").font(.system(size: 34, weight: .bold))
                        Text("BOOST MY INTERNET").font(.headline.weight(.heavy))
                    }
                    .frame(width: 210, height: 120)
                }
                .disabled(running || model.runningTest != nil || !model.settings.acknowledgedDataUsage)
                .prominentGlassButton()
                .keyboardShortcut("b", modifiers: [.command, .shift])
                VStack(alignment: .leading, spacing: 6) {
                    Stepper("Mesures par état : \(model.boostOptions.runs)", value: $model.boostOptions.runs, in: 2...6)
                        .help("Au moins 3 mesures sont nécessaires pour confirmer un gain.")
                    Toggle("Restaurer automatiquement si le gain n’est pas confirmé", isOn: $model.boostOptions.autoRollbackIfNoGain)
                    Toggle("Auto-tuning SQM (teste 95 / 90 / 85 % du débit mesuré)", isOn: $model.boostOptions.autoTuneSQM)
                    HStack {
                        Text("Perte de débit tolérée : \(Int(model.boostOptions.tolerance * 100)) %")
                        Slider(value: $model.boostOptions.tolerance, in: 0.05...0.30, step: 0.05).frame(width: 140)
                    }
                    Toggle("Comparer avec des résolveurs DNS publics (requêtes vers Cloudflare, Quad9, Google, OpenDNS)", isOn: $compareDNS)
                    if model.boostOptions.runs < 3 { Text("Avec moins de 3 mesures, aucun gain ne pourra être confirmé.").font(.caption).foregroundStyle(.orange) }
                }
                .font(.callout)
            }
        }
    }

    // MARK: Flow

    static let steps: [BoostPhase] = [.analysis, .recommendations, .authorization, .optimization, .verification, .report]

    var flowCard: some View {
        let phase = model.boostProgress?.0 ?? session?.phase ?? .idle
        return Card("Parcours", symbol: "point.forward.to.point.capsulepath", trailing: running ? AnyView(Button("Annuler") { model.cancelBoost() }.glassButton()) : nil) {
            HStack(spacing: 0) {
                ForEach(Self.steps, id: \.self) { st in
                    let done = st < phase || (st == phase && !running)
                    let current = st == phase && running
                    VStack(spacing: 4) {
                        ZStack {
                            Circle().fill(done ? Color.green : (current ? Color.accentColor : Color.secondary.opacity(0.25))).frame(width: 26, height: 26)
                            if current { ProgressView().controlSize(.small).tint(.white) }
                            else { Image(systemName: done ? "checkmark" : "circle").font(.caption2.bold()).foregroundStyle(.white) }
                        }
                        Text(st.label).font(.caption2).foregroundStyle(current ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    if st != Self.steps.last { Rectangle().fill(done ? Color.green : Color.secondary.opacity(0.25)).frame(height: 2).frame(maxWidth: 40) }
                }
            }
            if running, let msg = model.boostProgress?.1 {
                HStack {
                    StatusPill(status: .analyzing)
                    Text(msg).font(.callout)
                    Spacer()
                    if let t = model.traffic.last {
                        Text("Interface : ↓ \(Units.bitRate(t.inBps)) ↑ \(Units.bitRate(t.outBps))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .help("Débit réel de l’interface (compteurs système) pendant la mesure en cours.")
                    }
                }
                if model.traffic.count > 2 {
                    Chart(model.traffic.suffix(60)) { s in
                        AreaMark(x: .value("t", s.timestamp), y: .value("Mbit/s", s.inBps / 1e6)).foregroundStyle(.blue.opacity(0.3))
                        LineMark(x: .value("t", s.timestamp), y: .value("Mbit/s", s.outBps / 1e6)).foregroundStyle(.purple)
                    }.chartYAxisLabel("Mbit/s").frame(height: 90)
                }
            }
            if let s = session, !s.log.isEmpty {
                DisclosureGroup("Journal (\(s.log.count))") { ForEach(s.log, id: \.self) { Text(model.redact($0)).font(.caption.monospaced()) } }
            }
        }
    }

    // MARK: Score

    func scoreCard(_ s: BoostSession) -> some View {
        Card("Score MAX BOOST", symbol: "gauge.with.dots.needle.67percent") {
            HStack(spacing: 28) {
                VStack { Text("BEFORE BOOST").font(.caption.bold()).foregroundStyle(.secondary); ScoreRing(score: s.scoreBefore?.total, size: 100) }
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                VStack { Text("AFTER BOOST").font(.caption.bold()).foregroundStyle(.secondary); ScoreRing(score: s.scoreAfter?.total, size: 100) }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(s.scoreBefore?.components ?? []) { c in
                        let after = s.scoreAfter?.components.first { $0.criterion == c.criterion }
                        HStack {
                            Text("\(c.criterion) (\(Int(c.weight)))").font(.caption)
                            Spacer()
                            Text("\(c.score.map { "\(Int($0))" } ?? "—") → \(after?.score.map { "\(Int($0))" } ?? "—")").font(.caption.monospacedDigit())
                        }
                        .help("\(c.input) — \(c.rule)")
                    }
                }
                .frame(maxWidth: 320)
            }
            if let n = s.scoreBefore?.note { Text(n).font(.caption2).foregroundStyle(.tertiary) }
        }
    }

    // MARK: Candidates & authorization

    func candidatesCard(_ s: BoostSession) -> some View {
        let automatable = s.candidates.filter { $0.action.isAutomatable }
        let authorizedCount = automatable.filter { model.boostAuthorized.contains($0.id) }.count
        let sqm = automatable.contains { model.boostAuthorized.contains($0.id) && Self.isSQM($0.action) }
        return Card("Optimisations candidates (\(s.candidates.count))", symbol: "list.bullet.rectangle.portrait") {
            if s.candidates.isEmpty { Text(s.notes.first ?? "Aucune optimisation identifiée.").foregroundStyle(.secondary) }
            ForEach(s.candidates) { c in CandidateRow(candidate: c, evaluation: s.evaluations[c.id], onSensitive: { sensitiveTarget = c }) }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(authorizedCount) action(s) automatisée(s) autorisée(s)").font(.callout.bold())
                    Text("Plan de mesure : " + model.boostDataEstimate(automatedChanges: authorizedCount, sqmTuning: sqm && model.boostOptions.autoTuneSQM)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("J’ai effectué les actions guidées — Vérifier") { model.verifyBoostGuided() }
                    .disabled(running || s.baseline.isEmpty).glassButton()
                Button("Appliquer les optimisations autorisées") { model.runAuthorizedOptimizations() }
                    .disabled(running || authorizedCount == 0 || s.phase >= .report).prominentGlassButton()
            }
        }
    }

    static func isSQM(_ a: BoostAction) -> Bool {
        if case .routerSQM = a { return true }
        return false
    }

    // MARK: Results

    func resultsCard(_ s: BoostSession) -> some View {
        let after = s.final
        let ab = after.isEmpty ? nil : PerformanceABTestingService.compare(baseline: s.baseline, candidate: after, profile: s.profile, tolerance: model.boostOptions.tolerance)
        return Card("BEFORE BOOST / AFTER BOOST", symbol: "arrow.left.arrow.right.square",
                    trailing: AnyView(Button("Rapport PDF") { ReportExporter.save(s.report().redacted(model.redactor), suggestedName: "netscope-maxboost") }.glassButton())) {
            if let ab {
                HStack { VerdictPill(verdict: ab.verdict); Text(ab.summary).font(.callout) }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { Text("Métrique").bold(); Text("Avant (médiane, IQR)").bold(); Text("Après (médiane, IQR)").bold(); Text("Écart").bold(); Text("Verdict").bold() }
                    ForEach(ab.deltas) { d in
                        GridRow {
                            Text(d.metric.label)
                            Text(cell(d.baselineMedian, d.baselineIQR, d.metric)).monospacedDigit()
                            Text(cell(d.candidateMedian, d.candidateIQR, d.metric)).monospacedDigit()
                            Text(d.relativeChange.map { String(format: "%+.0f %%", $0 * 100) } ?? "—").monospacedDigit()
                            Text(d.outcome.rawValue).foregroundStyle(d.outcome == .improved ? .green : (d.outcome == .degraded ? .red : .secondary))
                        }.font(.callout)
                    }
                }
                if let b = ab.stabilityBaselineCV, let a = ab.stabilityCandidateCV {
                    Text(String(format: "Stabilité du débit (coefficient de variation) : %.0f %% → %.0f %%", b * 100, a * 100)).font(.caption)
                }
                ForEach(ab.comparabilityIssues + ab.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                comparisonChart(s.baseline, after)
            } else {
                Text("Aucune mesure finale distincte de la référence (aucune modification conservée ni vérification guidée).").foregroundStyle(.secondary)
            }
            ForEach(s.candidates.filter { s.evaluations[$0.id] != nil }) { c in
                if let e = s.evaluations[c.id] {
                    HStack(alignment: .top) { StatusPill(status: c.status); VStack(alignment: .leading) { Text(c.title).bold(); Text(e.summary).font(.caption).foregroundStyle(.secondary) } }
                }
            }
            if let t = model.boostOrchestrator?.tuning {
                DisclosureGroup("Auto-tuning SQM — essais") {
                    Text(t.rationale).font(.callout)
                    if let w = t.warning { Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    ForEach(t.perTrial, id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            }
        }
    }

    func cell(_ m: Double?, _ iqr: [Double], _ metric: BoostMetric) -> String {
        guard let m else { return "—" }
        let range = iqr.count == 2 ? " [\(metric.format(iqr[0])) – \(metric.format(iqr[1]))]" : ""
        return metric.format(m) + range
    }

    struct Bar: Identifiable { var id: String { metric + state }; var metric: String; var state: String; var value: Double }

    func comparisonChart(_ before: [BoostSample], _ after: [BoostSample]) -> some View {
        func med(_ x: [BoostSample], _ m: BoostMetric) -> Double? { Stats.median(x.compactMap { $0.value(m) }) }
        var thr: [Bar] = [], lat: [Bar] = []
        for (state, set) in [("Avant", before), ("Après", after)] {
            if let v = med(set, .download) { thr.append(Bar(metric: "↓", state: state, value: v / 1e6)) }
            if let v = med(set, .upload) { thr.append(Bar(metric: "↑", state: state, value: v / 1e6)) }
            if let v = med(set, .idleLatency) { lat.append(Bar(metric: "Repos", state: state, value: v)) }
            if let v = med(set, .loadedLatency) { lat.append(Bar(metric: "Sous charge", state: state, value: v)) }
            if let v = med(set, .jitter) { lat.append(Bar(metric: "Gigue", state: state, value: v)) }
        }
        return HStack {
            Chart(thr) { BarMark(x: .value("Sens", $0.metric), y: .value("Mbit/s", $0.value)).foregroundStyle(by: .value("État", $0.state)).position(by: .value("État", $0.state)) }
                .chartYAxisLabel("Mbit/s").frame(height: 160)
            Chart(lat) { BarMark(x: .value("Mesure", $0.metric), y: .value("ms", $0.value)).foregroundStyle(by: .value("État", $0.state)).position(by: .value("État", $0.state)) }
                .chartYAxisLabel("ms").frame(height: 160)
        }
    }

    // MARK: Changes & restore

    func changesCard(_ s: BoostSession) -> some View {
        Card("Modifications appliquées et restauration", symbol: "arrow.uturn.backward.circle") {
            ForEach(s.changes) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: icon(r.status)).foregroundStyle(color(r.status))
                        Text(BoostSession.describe(r.action)).bold()
                        Spacer()
                        Text(r.status.rawValue).font(.caption).foregroundStyle(color(r.status))
                        if r.restorable { Button("Restaurer l’état précédent") { model.rollbackBoostChange(r.id) }.glassButton() }
                    }
                    Text("\(r.appliedAt.shortDateTime) · \(r.detail)").font(.caption).foregroundStyle(.secondary)
                    if case .routerSQM(let prev)? = r.before { Text("Sauvegarde : \(prev.summary)").font(.caption2).foregroundStyle(.tertiary) }
                    if r.status == .needsManualRecovery || r.status == .rollbackFailed {
                        StatusPill(status: .restoreNeeded)
                        Text(r.recoveryProcedure).font(.callout).padding(8).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Divider()
            }
        }
    }

    func icon(_ s: ChangeStatus) -> String {
        switch s { case .applied: return "checkmark.circle.fill"; case .rolledBack: return "arrow.uturn.backward.circle.fill"; case .failed: return "xmark.circle"; default: return "exclamationmark.octagon.fill" }
    }
    func color(_ s: ChangeStatus) -> Color {
        switch s { case .applied: return .green; case .rolledBack: return .blue; case .failed: return .secondary; default: return .red }
    }

    // MARK: Insights

    @ViewBuilder func insightsCards(_ s: BoostSession) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Card("Bandwidth Intelligence", symbol: "chart.bar.doc.horizontal") {
                if let r = model.boostContention {
                    if r.processes.isEmpty { Text("Aucun trafic par processus mesuré pendant l’analyse.").foregroundStyle(.secondary) }
                    ForEach(r.processes.prefix(6)) { p in
                        HStack {
                            Image(systemName: p.likelyContributor ? "exclamationmark.triangle.fill" : "app").foregroundStyle(p.likelyContributor ? .orange : .secondary)
                            Text(p.name).lineLimit(1)
                            Spacer()
                            Text("\(Units.bitRate(p.meanBps)) · \(Int(p.share * 100)) % · \(Units.bytes(p.volumeBytes))").font(.caption.monospacedDigit())
                        }
                        .help(p.evidence)
                    }
                    if !r.devices.isEmpty {
                        Text("Appareils (routeur)").font(.caption.bold())
                        ForEach(r.devices.prefix(5)) { d in KeyValueRow(label: model.redact(d.name), value: "\(Units.bitRate(d.meanBps)) · \(Int(d.share * 100)) %", provenance: .router(adapter: model.router.adapterID ?? "")) }
                    }
                    ForEach(r.notes, id: \.self) { Text($0).font(.caption2).foregroundStyle(.tertiary) }
                } else { Text("Disponible après l’analyse.").foregroundStyle(.secondary) }
            }
            Card("Pile réseau macOS (lecture seule)", symbol: "cpu") {
                let f = model.boostOrchestrator?.findings ?? []
                if f.isEmpty { Text("Disponible après l’analyse.").foregroundStyle(.secondary) }
                ForEach(f) { x in
                    HStack(alignment: .top) {
                        Circle().fill(x.status == .unusual ? Color.orange : (x.status == .normal ? .green : .secondary)).frame(width: 7, height: 7).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack { Text(x.title).font(.caption.bold()); Spacer(); Text(model.redact(x.value)).font(.caption.monospaced()).lineLimit(1) }
                            if !x.note.isEmpty { Text(x.note).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
                Text("NetScope ne modifie jamais les paramètres TCP, la MTU, IPv6, le pare-feu ni les protections système.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        if let notes = model.boostOrchestrator?.wifiNotes, !notes.isEmpty {
            Card("Wi-Fi Performance Booster — observations", symbol: "wifi") { ForEach(notes, id: \.self) { Text("• " + $0).font(.callout) } }
        }
    }

    // MARK: History & safety

    var historyCard: some View {
        Card("Historique des sessions", symbol: "clock.arrow.circlepath") {
            if model.boostHistory.isEmpty { Text("Aucune session enregistrée.").foregroundStyle(.secondary) }
            ForEach(model.boostHistory.prefix(8)) { h in
                HStack {
                    Image(systemName: h.profile.symbol)
                    Text("\(h.started.shortDateTime) · \(h.profile.label)")
                    Spacer()
                    Text("\(h.scoreBefore?.total.map { "\(Int($0))" } ?? "—") → \(h.scoreAfter?.total.map { "\(Int($0))" } ?? "—")").monospacedDigit()
                    Text("\(h.confirmedCandidates.count) gain(s) confirmé(s)").font(.caption).foregroundStyle(.secondary)
                    Button("Ouvrir") { model.boostSession = h }.buttonStyle(.link)
                }.font(.callout)
            }
        }
    }

    var safetyCard: some View {
        Card("Boost Safety System", symbol: "shield.lefthalf.filled") {
            ForEach(SafetyLevel.allCases, id: \.self) { l in
                HStack(alignment: .top) {
                    Text(l.label).font(.callout.bold()).frame(width: 260, alignment: .leading)
                    Text(l == .readOnly ? "Mesures, diagnostics et analyses. Exécuté automatiquement." :
                         (l == .reversible ? "Réglage explicitement approuvé (ex. demander à une application de quitter). Sauvegarde et restauration quand c’est possible." :
                          "Toute action pouvant couper Internet ou affecter d’autres appareils (ex. SQM sur le routeur) : confirmation spécifique, sauvegarde, vérification, retour arrière proposé."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Interdits : déconnexion forcée, brouillage, désauthentification Wi-Fi, usurpation ARP, modification silencieuse du réseau ou du routeur.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Rows & pills

struct StatusPill: View {
    var status: BoostStatus
    var body: some View {
        let (c, s): (Color, String) = {
            switch status {
            case .analyzing: return (.blue, "magnifyingglass")
            case .available: return (.teal, "sparkles")
            case .authorizationNeeded: return (.orange, "hand.raised")
            case .applied: return (.indigo, "checkmark")
            case .gainConfirmed: return (.green, "checkmark.seal.fill")
            case .noGain: return (.gray, "equal.circle")
            case .restoreNeeded: return (.red, "exclamationmark.octagon.fill")
            case .restored: return (.blue, "arrow.uturn.backward")
            case .guided: return (.purple, "person.fill")
            case .failed: return (.red, "xmark.circle")
            case .skipped: return (.secondary, "minus.circle")
            }
        }()
        Label(status.rawValue, systemImage: s).font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3)
            .background(c.opacity(0.15), in: Capsule()).foregroundStyle(c)
    }
}

struct VerdictPill: View {
    var verdict: ABVerdict
    var body: some View {
        let c: Color = verdict == .confirmedGain ? .green : (verdict == .degraded ? .red : .secondary)
        Text(verdict.rawValue).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3).background(c.opacity(0.15), in: Capsule()).foregroundStyle(c)
    }
}

struct CandidateRow: View {
    @EnvironmentObject var model: AppModel
    var candidate: BoostCandidate
    var evaluation: ABResult?
    var onSensitive: () -> Void

    var body: some View {
        let c = candidate
        let authorized = model.boostAuthorized.contains(c.id)
        let editable = (model.boostSession?.phase ?? .report) < .report && model.boostTask == nil
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                Text(c.detail).font(.callout)
                ForEach(c.evidence.filter { !$0.isEmpty }, id: \.self) { Label(model.redact($0), systemImage: "chart.bar").font(.caption) }
                if case .guided(let steps) = c.action {
                    ForEach(steps.indices, id: \.self) { i in Text("\(i + 1). \(steps[i])").font(.caption) }
                }
                if !c.affected.isEmpty { Label("Concerné : " + c.affected.joined(separator: " ; "), systemImage: "person.2").font(.caption) }
                ForEach(c.tradeoffs, id: \.self) { Label("Compromis : " + $0, systemImage: "scalemass").font(.caption).foregroundStyle(.orange) }
                Text("Cible : \(c.targets.map(\.label).joined(separator: ", ")) · gain probable \(c.expectedGain.label.lowercased()) · risque \(c.risk.rawValue.lowercased()) · \(c.reversible ? "réversible" : "non réversible") · \(c.safety.label)")
                    .font(.caption2).foregroundStyle(.tertiary)
                if let e = evaluation { Text(e.summary).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.leading, 4)
        } label: {
            HStack {
                Image(systemName: c.action.isAutomatable ? "gearshape.2" : "hand.point.up.left").foregroundStyle(.secondary)
                Text(c.title).font(.callout.bold()).lineLimit(2)
                Text(c.category.rawValue).font(.caption2).padding(.horizontal, 5).background(.quaternary, in: Capsule())
                Spacer()
                StatusPill(status: authorized && c.status == .authorizationNeeded ? .available : c.status)
                if c.action.isAutomatable && editable {
                    if c.safety == .sensitive {
                        Button(authorized ? "Retirer l’autorisation" : "Autoriser…") {
                            if authorized { model.boostAuthorized.remove(c.id) } else { onSensitive() }
                        }.glassButton()
                    } else {
                        Toggle("Autoriser", isOn: Binding(get: { authorized }, set: { on in if on { model.boostAuthorized.insert(c.id) } else { model.boostAuthorized.remove(c.id) } }))
                            .toggleStyle(.checkbox)
                    }
                }
            }
        }
    }
}

/// Level 3 authorization: exact change, affected devices, backup, recovery procedure, explicit confirmation.
struct SensitiveAuthorizationSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var candidate: BoostCandidate
    @State private var understood = false
    @State private var recoveryRead = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Action sensible — Niveau 3", systemImage: "exclamationmark.shield.fill").font(.title2.bold()).foregroundStyle(.orange)
            Text(candidate.title).font(.headline)
            Card("Changement exact", symbol: "doc.text.magnifyingglass") {
                Text(candidate.detail).font(.callout)
                if case .routerSQM(let s) = candidate.action {
                    KeyValueRow(label: "Section", value: "sqm.\(s.section) (interface \(s.interface))")
                    KeyValueRow(label: "Proposition initiale", value: s.summary)
                    if model.boostOptions.autoTuneSQM {
                        Text("Auto-tuning activé : 3 réglages (95 / 90 / 85 % du débit mesuré) seront essayés successivement, puis seul le meilleur compromis validé sera conservé — sinon l’état d’origine sera restauré.").font(.caption)
                    }
                }
            }
            Card("Appareils concernés", symbol: "person.3") { ForEach(candidate.affected, id: \.self) { Text("• " + $0).font(.callout) } }
            Card("Sauvegarde et retour arrière", symbol: "arrow.uturn.backward") {
                Text("La configuration SQM actuelle est relue et sauvegardée avant toute modification. Chaque application passe par « uci apply » avec retour arrière automatique du routeur : NetScope ne confirme qu’après avoir vérifié que le routeur répond encore. Un bouton de restauration reste disponible ensuite.")
                    .font(.callout)
                DisclosureGroup("Procédure de récupération si le routeur devient inaccessible") {
                    Text(RecoveryProcedures.text(for: candidate.action)).font(.caption).textSelection(.enabled)
                }
            }
            Toggle("J’ai lu la procédure de récupération", isOn: $recoveryRead)
            Toggle("Je comprends que cette action peut interrompre brièvement Internet pour tous les appareils du réseau et j’autorise NetScope à l’appliquer", isOn: $understood)
            HStack {
                Button("Annuler") { dismiss() }
                Spacer()
                Button("Autoriser cette action") { model.boostAuthorized.insert(candidate.id); dismiss() }
                    .disabled(!(understood && recoveryRead)).prominentGlassButton()
            }
        }
        .padding(20).frame(width: 620)
    }
}
#endif
