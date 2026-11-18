import Foundation

// MARK: - Change records & rollback

public enum ChangeStatus: String, Codable, Sendable {
    case applied = "Appliquée"
    case rolledBack = "Restaurée"
    case rollbackFailed = "Restauration échouée"
    case needsManualRecovery = "Récupération manuelle nécessaire"
    case failed = "Échec de l’application"
}

public struct ChangeRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var candidateID: String
    public var action: BoostAction
    /// State captured before the change (same action kind with previous values). nil = not automatically restorable.
    public var before: BoostAction?
    public var appliedAt: Date
    public var status: ChangeStatus
    public var detail: String
    public var recoveryProcedure: String

    public var restorable: Bool { before != nil && status == .applied }
}

/// Executes the (few) modifications MAX BOOST supports. Implemented by the app; mocked in tests.
public protocol BoostChangeExecutor: Sendable {
    func snapshot(before action: BoostAction) async throws -> BoostAction?
    func apply(_ action: BoostAction) async throws
    /// Called right after `apply`: is the device/router still reachable?
    func isReachable(after action: BoostAction) async -> Bool
    /// Finalizes a change that the device would otherwise revert automatically (OpenWrt rpcd confirm).
    func confirm(_ action: BoostAction) async throws
    func restore(_ snapshot: BoostAction) async throws
}

public enum RecoveryProcedures {
    public static func text(for action: BoostAction) -> String {
        switch action {
        case .guided: return "Modification faite par vous : appliquez l’inverse des étapes indiquées."
        case .quitApplication(_, let name): return "Relancez « \(name) » depuis le Dock, le Finder ou le Launchpad."
        case .routerSQM(let s):
            return """
            Si le routeur ne répond plus après la modification : attendez au moins 60 secondes — rpcd annule automatiquement une \
            configuration appliquée mais non confirmée. NetScope ne peut pas restaurer à distance un routeur devenu inaccessible.
            Si l’accès ne revient pas : branchez-vous en Ethernet au routeur, puis dans LuCI → Réseau → SQM QoS, décochez « Activer » \
            pour \(s.interface) ; ou en SSH : uci set sqm.\(s.section).enabled='0' && uci commit sqm && /etc/init.d/sqm restart.
            En dernier recours : mode failsafe d’OpenWrt (voir la documentation de votre modèle).
            """
        }
    }
}

/// Applies changes with backup → apply → reachability check → confirm, and restores them on demand.
public actor NetworkRollbackManager {
    public private(set) var records: [ChangeRecord] = []
    public init(records: [ChangeRecord] = []) { self.records = records }

    public func perform(_ action: BoostAction, candidateID: String, executor: BoostChangeExecutor) async -> ChangeRecord {
        let procedure = RecoveryProcedures.text(for: action)
        var record = ChangeRecord(id: UUID(), candidateID: candidateID, action: action, before: nil, appliedAt: Date(),
                                  status: .failed, detail: "", recoveryProcedure: procedure)
        guard action.isAutomatable else {
            record.detail = "Action guidée : rien n’est exécuté par NetScope."
            records.append(record); return record
        }
        do { record.before = try await executor.snapshot(before: action) } catch {
            record.detail = "Sauvegarde de l’état précédent impossible (\(Self.describe(error))) : modification non appliquée."
            records.append(record); return record
        }
        do { try await executor.apply(action) } catch {
            record.detail = "Application refusée ou échouée : \(Self.describe(error))."
            records.append(record); return record
        }
        guard await executor.isReachable(after: action) else {
            record.status = .needsManualRecovery
            record.detail = "Le périphérique ne répond plus après la modification."
            records.append(record); return record
        }
        do { try await executor.confirm(action) } catch {
            record.status = .needsManualRecovery
            record.detail = "Confirmation impossible (\(Self.describe(error))) : le routeur devrait annuler automatiquement la modification."
            records.append(record); return record
        }
        record.status = .applied
        record.detail = "Appliquée et confirmée."
        records.append(record)
        return record
    }

    @discardableResult
    public func rollback(_ id: UUID, executor: BoostChangeExecutor) async -> ChangeRecord? {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return nil }
        guard let before = records[i].before, records[i].status == .applied else {
            if records[i].before == nil { records[i].detail += " Restauration automatique impossible : suivez la procédure." }
            return records[i]
        }
        do {
            try await executor.restore(before)
            if await executor.isReachable(after: before) { try? await executor.confirm(before) }
            records[i].status = .rolledBack
            records[i].detail = "État précédent restauré."
        } catch {
            records[i].status = .rollbackFailed
            records[i].detail = "Restauration échouée : \(Self.describe(error)). Procédure manuelle ci-dessous."
        }
        return records[i]
    }

    static func describe(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? "\(e)" }
}

// MARK: - History

public struct BoostHistoryService: Sendable {
    let store: HistoryStore?
    public init(store: HistoryStore?) { self.store = store }

    public func save(_ s: BoostSession) {
        try? store?.save(s, kind: .boostSession, id: s.id.uuidString, timestamp: s.started, network: s.baseline.first?.networkName)
    }

    public func all() -> [BoostSession] {
        ((try? store?.load(BoostSession.self, kind: .boostSession).items) ?? []).sorted { $0.started > $1.started }
    }
}

// MARK: - Environment & baseline

/// Everything MAX BOOST reads. Implemented by the app with the real services, mocked in tests.
public protocol BoostEnvironment: Sendable {
    func measureOnce() async throws -> BoostSample
    func diagnosticReport() async -> DiagnosticReport
    func wifiInput() async -> WiFiBoostInput
    func contention() async -> ContentionReport
    func stackInspection() async -> (findings: [StackFinding], candidates: [BoostCandidate])
    func routerState() async -> RouterTuningState
    func quittableApplications() async -> Set<String>
    func referenceDownBps() async -> Double?
    func isWired() async -> Bool
}

public enum BoostBaselineService {
    /// Runs `runs` comparable measurements. Stops on cancellation; a failed run is skipped and reported.
    public static func measure(runs: Int, env: BoostEnvironment, progress: @Sendable (String) -> Void) async -> (samples: [BoostSample], errors: [String]) {
        var out: [BoostSample] = []
        var errors: [String] = []
        for i in 0..<runs {
            if Task.isCancelled { break }
            progress("Mesure \(i + 1)/\(runs)")
            do { out.append(try await env.measureOnce()) } catch { errors.append("Mesure \(i + 1) : \((error as? LocalizedError)?.errorDescription ?? "\(error)")") }
        }
        return (out, errors)
    }
}

// MARK: - Orchestrator

public struct BoostOptions: Sendable {
    public var runs: Int
    public var tuningRuns: Int
    public var autoRollbackIfNoGain: Bool
    public var autoTuneSQM: Bool
    public var tolerance: Double
    public init(runs: Int = 3, tuningRuns: Int = 2, autoRollbackIfNoGain: Bool = true, autoTuneSQM: Bool = true, tolerance: Double = 0.15) {
        self.runs = runs; self.tuningRuns = tuningRuns; self.autoRollbackIfNoGain = autoRollbackIfNoGain
        self.autoTuneSQM = autoTuneSQM; self.tolerance = tolerance
    }
}

/// Drives: Analyse → Recommandations → Autorisations → Optimisations → Vérification → Rapport.
/// Never applies anything that was not explicitly authorized in `optimize(…)`.
public final class MaxBoostOrchestrator: @unchecked Sendable {
    public let env: BoostEnvironment
    public let rollback: NetworkRollbackManager
    public private(set) var findings: [StackFinding] = []
    public private(set) var contention: ContentionReport?
    public private(set) var wifiNotes: [String] = []
    public private(set) var tuning: TuningDecision?

    public init(env: BoostEnvironment, rollback: NetworkRollbackManager = NetworkRollbackManager()) {
        self.env = env; self.rollback = rollback
    }

    public func analyze(profile: BoostProfile, options: BoostOptions, progress: @escaping @Sendable (BoostPhase, String) -> Void) async -> BoostSession {
        var s = BoostSession(profile: profile)
        s.phase = .analysis
        progress(.analysis, "Mesure des performances actuelles")
        let base = await BoostBaselineService.measure(runs: options.runs, env: env) { progress(.analysis, $0) }
        s.baseline = base.samples
        s.log += base.errors
        let wired = await env.isWired()
        let ref = await env.referenceDownBps()
        let wifiIn = await env.wifiInput()
        s.scoreBefore = MaxBoostScore.compute(samples: s.baseline, referenceDownBps: ref, isWired: wired, snr: wifiIn.wifi?.snr.value,
                                              disconnects24h: wifiIn.disconnects24h)
        progress(.analysis, "Diagnostic des limitations")
        let report = await env.diagnosticReport()
        progress(.analysis, "Analyse Wi-Fi")
        let wifi = WiFiOptimizationEngine.recommend(wifiIn)
        wifiNotes = wifi.notes
        progress(.analysis, "Applications consommatrices")
        let cont = await env.contention()
        contention = cont
        let quittable = await env.quittableApplications()
        progress(.analysis, "Capacités de la box")
        let router = await env.routerState()
        progress(.analysis, "Configuration réseau et DNS")
        let stack = await env.stackInspection()
        findings = stack.findings

        var all = stack.candidates + wifi.candidates + BandwidthContentionAnalyzer.candidates(cont, quittableNames: quittable)
            + RouterQoSOptimizer.candidates(state: router, baseline: s.baseline, profile: profile) + BoostCandidateEvaluator.fromDiagnostics(report)
        if s.baseline.isEmpty { s.notes.append("Aucune mesure de référence réussie : les gains ne pourront pas être vérifiés.") }
        let weakest = Self.weakestMetrics(s.scoreBefore)
        all = BoostCandidateEvaluator.rank(all, profile: profile, weakest: weakest)
        s.candidates = all.map { c in var x = c; x.status = c.action.isAutomatable ? .authorizationNeeded : .guided; return x }
        if s.candidates.isEmpty { s.notes.append("Aucune optimisation pertinente n’a été identifiée à partir des mesures : la connexion semble déjà exploitée au mieux de ce que NetScope peut vérifier.") }
        s.notes += wifi.notes + cont.notes
        s.phase = .recommendations
        progress(.recommendations, "\(s.candidates.count) optimisation(s) candidate(s)")
        return s
    }

    static func weakestMetrics(_ score: BoostScore?) -> [BoostMetric] {
        guard let comps = score?.components.filter({ $0.score != nil }).sorted(by: { $0.score! < $1.score! }).prefix(2) else { return [] }
        return comps.flatMap { c -> [BoostMetric] in
            switch c.criterion {
            case "Débit / référence": return [.download, .upload]
            case "Latence au repos": return [.idleLatency]
            case "Latence sous charge": return [.loadedLatency]
            case "Stabilité": return [.jitter]
            case "Pertes": return [.loss]
            default: return []
            }
        }
    }

    /// Applies ONLY the authorized automatable candidates, one at a time, each followed by an A/B verification.
    public func optimize(_ session: BoostSession, authorized: Set<String>, executor: BoostChangeExecutor, options: BoostOptions,
                         progress: @escaping @Sendable (BoostPhase, String) -> Void) async -> BoostSession {
        var s = session
        s.phase = .optimization
        var reference = s.baseline
        for idx in s.candidates.indices {
            let c = s.candidates[idx]
            guard c.action.isAutomatable else { continue }
            guard authorized.contains(c.id) else { s.candidates[idx].status = .skipped; continue }
            if Task.isCancelled { break }
            if case .routerSQM = c.action, options.autoTuneSQM, let dl = Stats.median(s.baseline.compactMap(\.downloadBps)),
               let ul = Stats.median(s.baseline.compactMap(\.uploadBps)) {
                let (status, eval, newRef) = await tuneSQM(c, baseline: reference, dl: dl, ul: ul, executor: executor, options: options, session: &s, progress: progress)
                s.candidates[idx].status = status
                if let eval { s.evaluations[c.id] = eval }
                if let newRef { reference = newRef }
                continue
            }
            progress(.optimization, "Application : \(c.title)")
            let record = await rollback.perform(c.action, candidateID: c.id, executor: executor)
            s.changes.append(record)
            guard record.status == .applied else {
                s.candidates[idx].status = record.status == .needsManualRecovery ? .restoreNeeded : .failed
                s.log.append("\(c.title) : \(record.detail)")
                continue
            }
            s.candidates[idx].status = .applied
            s.phase = .verification
            let m = await BoostBaselineService.measure(runs: options.runs, env: env) { progress(.verification, "\(c.title) — \($0)") }
            s.log += m.errors
            let ab = PerformanceABTestingService.compare(baseline: reference, candidate: m.samples, profile: s.profile, tolerance: options.tolerance)
            s.evaluations[c.id] = ab
            if ab.verdict == .confirmedGain {
                s.candidates[idx].status = .gainConfirmed
                reference = m.samples
            } else if options.autoRollbackIfNoGain, record.before != nil {
                progress(.verification, "Aucun gain démontré : restauration de « \(c.title) »")
                let r = await rollback.rollback(record.id, executor: executor)
                Self.replace(&s.changes, with: r)
                s.candidates[idx].status = r?.status == .rolledBack ? .noGain : .restoreNeeded
            } else {
                s.candidates[idx].status = record.before == nil ? .noGain : .restoreNeeded
            }
        }
        s.final = reference == s.baseline ? [] : reference
        return s
    }

    private func tuneSQM(_ c: BoostCandidate, baseline: [BoostSample], dl: Double, ul: Double, executor: BoostChangeExecutor, options: BoostOptions,
                         session s: inout BoostSession, progress: @escaping @Sendable (BoostPhase, String) -> Void) async -> (BoostStatus, ABResult?, [BoostSample]?) {
        guard case .routerSQM(let base) = c.action else { return (.failed, nil, nil) }
        var trials: [TuningTrial] = []
        var original: ChangeRecord?
        for settings in BufferbloatTuningService.candidates(base: base, measuredDownBps: dl, measuredUpBps: ul) {
            if Task.isCancelled { break }
            progress(.optimization, "Auto-tuning SQM : ↓ \(settings.downloadKbps) / ↑ \(settings.uploadKbps) kbit/s")
            let rec = await rollback.perform(.routerSQM(settings), candidateID: c.id, executor: executor)
            s.changes.append(rec)
            if original == nil { original = rec }
            guard rec.status == .applied else {
                s.log.append("SQM : \(rec.detail)")
                return (rec.status == .needsManualRecovery ? .restoreNeeded : .failed, nil, nil)
            }
            let m = await BoostBaselineService.measure(runs: options.tuningRuns, env: env) { progress(.verification, "SQM \(settings.downloadKbps) kbit/s — \($0)") }
            trials.append(TuningTrial(settings: settings, samples: m.samples))
        }
        let decision = BufferbloatTuningService.select(trials: trials, baseline: baseline, tolerance: options.tolerance)
        tuning = decision
        s.log += decision.perTrial
        if let w = decision.warning { s.notes.append(w) }
        guard let orig = original else { return (.failed, nil, nil) }
        if let chosen = decision.chosen {
            progress(.verification, "Validation du réglage retenu")
            let rec = await rollback.perform(.routerSQM(chosen), candidateID: c.id, executor: executor)
            s.changes.append(rec)
            if rec.status == .applied {
                let m = await BoostBaselineService.measure(runs: options.runs, env: env) { progress(.verification, "Validation — \($0)") }
                let ab = PerformanceABTestingService.compare(baseline: baseline, candidate: m.samples, profile: s.profile, tolerance: options.tolerance)
                if ab.verdict == .confirmedGain { return (.gainConfirmed, ab, m.samples) }
                if options.autoRollbackIfNoGain {
                    let r = await rollback.rollback(orig.id, executor: executor)
                    Self.replace(&s.changes, with: r)
                    return (r?.status == .rolledBack ? .noGain : .restoreNeeded, ab, nil)
                }
                return (.restoreNeeded, ab, nil)
            }
            return (.restoreNeeded, nil, nil)
        }
        // No validated compromise: restore the original configuration (it was part of the authorized tuning plan).
        let r = await rollback.rollback(orig.id, executor: executor)
        Self.replace(&s.changes, with: r)
        return (r?.status == .rolledBack ? .noGain : .restoreNeeded, nil, nil)
    }

    /// Re-measures after guided actions performed by the user and compares with the baseline.
    public func verifyGuided(_ session: BoostSession, options: BoostOptions, progress: @escaping @Sendable (BoostPhase, String) -> Void) async -> BoostSession {
        var s = session
        s.phase = .verification
        let m = await BoostBaselineService.measure(runs: options.runs, env: env) { progress(.verification, $0) }
        s.log += m.errors
        let ab = PerformanceABTestingService.compare(baseline: s.baseline, candidate: m.samples, profile: s.profile, tolerance: options.tolerance)
        s.evaluations["guided-\(Int(Date().timeIntervalSince1970))"] = ab
        s.final = m.samples
        return s
    }

    public func finish(_ session: BoostSession) async -> BoostSession {
        var s = session
        let wired = await env.isWired()
        let ref = await env.referenceDownBps()
        let w = await env.wifiInput()
        if !s.final.isEmpty {
            s.scoreAfter = MaxBoostScore.compute(samples: s.final, referenceDownBps: ref, isWired: wired, snr: w.wifi?.snr.value, disconnects24h: w.disconnects24h)
        }
        s.changes = await rollback.records.filter { r in s.changes.contains { $0.id == r.id } }
        s.finished = Date()
        s.phase = .report
        return s
    }

    static func replace(_ list: inout [ChangeRecord], with r: ChangeRecord?) {
        guard let r, let i = list.firstIndex(where: { $0.id == r.id }) else { return }
        list[i] = r
    }
}

public extension BoostSession {
    var confirmedCandidates: [BoostCandidate] { candidates.filter { $0.status == .gainConfirmed } }
    var pendingRestores: [ChangeRecord] { changes.filter { $0.status == .needsManualRecovery || $0.status == .rollbackFailed } }

    /// "BEFORE BOOST / AFTER BOOST" report.
    func report() -> Report {
        var sections: [Report.Section] = []
        sections.append(.init(heading: "Profil", paragraphs: ["\(profile.label) — \(profile.goal)"]))
        let after = final
        let ab = after.isEmpty ? nil : PerformanceABTestingService.compare(baseline: baseline, candidate: after, profile: profile)
        sections.append(.init(heading: "BEFORE BOOST / AFTER BOOST",
                              paragraphs: [ab?.summary ?? "Aucune mesure finale distincte : pas de comparaison."],
                              tables: [Report.Table(header: ["Métrique", "Avant (médiane)", "Après (médiane)", "Écart", "Verdict"], rows: (ab?.deltas ?? []).map { d in
                                  [d.metric.label, d.baselineMedian.map(d.metric.format) ?? "—", d.candidateMedian.map(d.metric.format) ?? "—",
                                   d.relativeChange.map { String(format: "%+.0f %%", $0 * 100) } ?? "—", d.outcome.rawValue]
                              })]))
        sections.append(.init(heading: "Score MAX BOOST",
                              paragraphs: ["Avant : \(scoreBefore?.total.map { String(format: "%.0f/100", $0) } ?? "—") · Après : \(scoreAfter?.total.map { String(format: "%.0f/100", $0) } ?? "—")",
                                           scoreBefore?.note ?? ""]))
        sections.append(.init(heading: "Optimisations", tables: [Report.Table(header: ["Optimisation", "Niveau", "Statut", "Résultat"], rows: candidates.map { c in
            [c.title, c.safety.label, c.status.rawValue, evaluations[c.id]?.summary ?? ""]
        })]))
        if !changes.isEmpty {
            sections.append(.init(heading: "Modifications et restaurations", tables: [Report.Table(header: ["Date", "Changement", "Statut", "Détail"], rows: changes.map { r in
                [ReportFormat.dateTime(r.appliedAt), Self.describe(r.action), r.status.rawValue, r.detail]
            })]))
        }
        sections.append(.init(heading: "Compromis et limites restantes", bullets: notes + evaluations.values.flatMap(\.tradeoffs) + evaluations.values.flatMap(\.warnings)))
        sections.append(.init(heading: "Méthode", paragraphs: ["Chaque mesure combine Apple networkQuality (débit, latence sous charge) et un ping ICMP vers une cible fixe (latence, gigue, pertes), sur la même interface. Une optimisation n’est « confirmée » que si les médianes diffèrent d’au moins 10 % sans recouvrement des intervalles interquartiles, sur au moins 3 mesures par état (Baseline / Candidate / Validated)."]))
        return Report(title: "NetScope Pro — Rapport MAX BOOST", subtitle: profile.label, generatedAt: finished ?? Date(), sections: sections)
    }

    static func describe(_ a: BoostAction) -> String {
        switch a {
        case .guided: return "Action guidée"
        case .quitApplication(_, let n): return "Demande de fermeture de « \(n) »"
        case .routerSQM(let s): return s.summary
        }
    }
}
