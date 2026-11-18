#if os(macOS)
import SwiftUI
import NetScopeCore
import NetScopeSystem

/// Real data sources for MAX BOOST (read-only). Every method reads; nothing here modifies the system.
final class AppBoostEnvironment: BoostEnvironment, @unchecked Sendable {
    weak var model: AppModel?
    let compareDNS: Bool
    let target: String
    let reduced: Bool

    init(model: AppModel, compareDNS: Bool) {
        self.model = model
        self.compareDNS = compareDNS
        self.target = model.settings.latencyTargets.first ?? "1.1.1.1"
        self.reduced = model.settings.reducedDataMode
    }

    /// One comparable run: ICMP probe (20 packets at 200 ms) then networkQuality with fixed options.
    func measureOnce() async throws -> BoostSample {
        guard let m = model else { throw CancellationError() }
        let (latency, speed, vpn, proxy, name, rssi, bg) = await MainActor.run {
            (m.latencyService, m.speedService, m.connection?.vpnActive ?? false, m.connection?.proxy?.isActive ?? false,
             m.networkName, m.isWired ? nil : m.wifi?.rssi.value, m.backgroundTrafficBps())
        }
        let ping = try? await latency.ping(target, count: 20, interval: 0.2)
        try Task.checkCancellation()
        let result = try await speed.run(SpeedTestOptions(mode: .quick, maxRuntimeSeconds: reduced ? 10 : nil),
                                         vpnActive: vpn, proxyActive: proxy, networkName: name)
        await MainActor.run { m.recordBoostMeasurement(result) }
        return BoostSample.from(result, ping: ping, rssi: rssi, background: bg)
    }

    func diagnosticReport() async -> DiagnosticReport {
        guard let m = model else { return DiagnosticReport(timestamp: Date(), hypotheses: [], observedFacts: [], dataGaps: []) }
        await m.measureGateway()
        return await MainActor.run { DiagnosticsEngine.analyze(m.diagnosticInput()) }
    }

    func wifiInput() async -> WiFiBoostInput {
        guard let m = model else { return WiFiBoostInput(wifi: nil, isWired: false) }
        return await MainActor.run {
            let kinds = Dictionary((m.connection?.interfaces ?? []).map { ($0.bsdName, $0.kind) }, uniquingKeysWith: { a, _ in a })
            let recent = m.speedTests.filter { $0.succeeded && $0.timestamp > Date().addingTimeInterval(-14 * 86400) && $0.mode != .lan }
            let dayAgo = Date().addingTimeInterval(-86400)
            return WiFiBoostInput(wifi: m.wifi, isWired: m.isWired, neighbors: m.neighbors, rssiHistory: m.rssiHistory.map(\.v),
                                  txRateHistory: m.txRateHistory, bssidChanges24h: m.events.filter { $0.kind == .bssidChanged && $0.timestamp > dayAgo }.count,
                                  disconnects24h: m.events.filter { $0.kind == .connectivityLost && $0.timestamp > dayAgo }.count,
                                  wifiDownMedianBps: Stats.median(recent.filter { kinds[$0.interfaceName ?? ""] == .wifi }.compactMap(\.downloadBps)),
                                  ethernetDownMedianBps: Stats.median(recent.filter { kinds[$0.interfaceName ?? ""] == .ethernet }.compactMap(\.downloadBps)),
                                  routerName: m.router.info?.model)
        }
    }

    /// Four nettop samples 5 s apart (≈ 15 s) — real per-process counters.
    func contention() async -> ContentionReport {
        guard let m = model else { return ContentionReport(processes: [], devices: [], interfaceMeanBps: nil, saturationRatio: nil, samples: 0, notes: []) }
        let svc = await MainActor.run { m.processTraffic }
        var previous: [ProcessTrafficSample] = []
        var prevAt = Date()
        var samples: [[ProcessTrafficService.ProcessRate]] = []
        let start = Date()
        if svc.isAvailable {
            for i in 0..<4 {
                if Task.isCancelled { break }
                if let cur = try? await svc.sample() {
                    let now = Date()
                    if i > 0 { samples.append(ProcessTrafficService.rates(previous: previous, current: cur, seconds: now.timeIntervalSince(prevAt))) }
                    previous = cur; prevAt = now
                }
                if i < 3 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
            }
        }
        return await MainActor.run {
            let iface = m.traffic.filter { $0.timestamp >= start }
            var r = BandwidthContentionAnalyzer.analyze(processSamples: samples, intervalSeconds: 5, interfaceSamples: iface,
                                                        capacityBps: m.latestTest?.downloadBps, routerClients: m.router.clients)
            if !svc.isAvailable { r.notes.append("nettop indisponible : consommation par application non mesurée.") }
            m.boostContention = r
            return r
        }
    }

    func stackInspection() async -> (findings: [StackFinding], candidates: [BoostCandidate]) {
        guard let m = model else { return ([], []) }
        let (runner, dnsService) = await MainActor.run { (m.runner, m.dnsService) }
        let (tcp, order) = await NetworkConfigurationInspector.read(runner: runner)
        await m.testDNS()
        var bench: [DNSDiagnosticsService.BenchmarkRow] = []
        if compareDNS {
            bench = await dnsService.benchmark(resolvers: DNSDiagnosticsService.publicResolvers, names: ["apple.com", "wikipedia.org", "example.com"], rounds: 3)
        }
        return await MainActor.run {
            let configured = Stats.median(m.dnsResults.filter(\.success).compactMap(\.durationMs))
            m.boostDNSBenchmark = bench
            return NetworkConfigurationInspector.inspect(connection: m.connection, tcp: tcp, serviceOrder: order, dnsBenchmark: bench, configuredDNSMedianMs: configured)
        }
    }

    func routerState() async -> RouterTuningState {
        guard let m = model else { return RouterTuningState() }
        let (ow, fb, name, clients) = await MainActor.run { (m.router.openwrt, m.router.freebox, m.router.info?.model, m.router.clients) }
        let wifiNames = clients.filter { $0.link == .wifi && $0.active == true }.compactMap(\.name)
        if let ow {
            do {
                let sqm = try await ow.readSQM()
                let write = await ow.canWriteSQM()
                return RouterTuningState(adapterID: "openwrt", routerName: name, sqm: sqm,
                                         sqmUnavailableReason: write ? nil : "L’utilisateur rpcd n’a pas le droit d’écriture uci sur « sqm ».",
                                         canWriteSQM: write && !sqm.isEmpty, wifiClientNames: wifiNames, allClientCount: clients.count)
            } catch {
                return RouterTuningState(adapterID: "openwrt", routerName: name, sqmUnavailableReason: (error as? LocalizedError)?.errorDescription,
                                         wifiClientNames: wifiNames, allClientCount: clients.count)
            }
        }
        if fb != nil {
            return RouterTuningState(adapterID: "freebox", routerName: name,
                                     sqmUnavailableReason: "L’API Freebox intégrée à NetScope n’expose pas de réglage QoS/SQM.",
                                     wifiClientNames: wifiNames, allClientCount: clients.count)
        }
        return RouterTuningState(sqmUnavailableReason: "Aucun routeur compatible connecté (Router Control).")
    }

    func quittableApplications() async -> Set<String> { await AppQuitService().quittableNames() }

    func referenceDownBps() async -> Double? {
        guard let m = model else { return nil }
        return await MainActor.run {
            m.ispProfile.advertisedDownBps
                ?? m.speedTests.filter { $0.succeeded && m.ethernetInterfaceNames.contains($0.interfaceName ?? "") }.compactMap(\.downloadBps).max()
        }
    }

    func isWired() async -> Bool { await MainActor.run { model?.isWired ?? false } }
}

extension AppModel {
    var boostHistoryService: BoostHistoryService { BoostHistoryService(store: store) }

    func recordBoostMeasurement(_ r: SpeedTestResult) {
        speedTests.append(r)
        try? store?.save(r, kind: .speedTest, id: r.id.uuidString, timestamp: r.timestamp, network: r.networkName)
    }

    /// Phase 1 (Level 1, read-only): measure, diagnose, build and rank candidates.
    func startBoost(profile: BoostProfile, compareDNS: Bool) {
        guard boostTask == nil, runningTest == nil else { return }
        let env = AppBoostEnvironment(model: self, compareDNS: compareDNS)
        let orch = MaxBoostOrchestrator(env: env)
        boostOrchestrator = orch
        boostError = nil
        boostLive = []
        boostTask = Task {
            let s = await orch.analyze(profile: profile, options: boostOptions) { phase, msg in
                Task { @MainActor in self.boostProgress = (phase, msg) }
            }
            self.boostSession = s
            self.boostAuthorized = []
            self.boostHistoryService.save(s)
            self.boostTask = nil
        }
    }

    /// Phases 3–5: apply ONLY what the user authorized (each change verified by A/B, rolled back if no gain when allowed).
    func runAuthorizedOptimizations() {
        guard let orch = boostOrchestrator, let s = boostSession, boostTask == nil else { return }
        let executor = StandardBoostExecutor(sqm: router.openwrt, apps: AppQuitService())
        let ids = boostAuthorized
        boostTask = Task {
            var out = await orch.optimize(s, authorized: ids, executor: executor, options: boostOptions) { phase, msg in
                Task { @MainActor in self.boostProgress = (phase, msg) }
            }
            out = await orch.finish(out)
            self.boostSession = out
            self.boostHistoryService.save(out)
            for c in out.changes {
                self.audit(AdminAuditEntry(adapterID: c.candidateID.hasPrefix("router") ? (self.router.adapterID ?? "routeur") : "mac",
                                           action: "MAX BOOST — \(BoostSession.describe(c.action))", target: c.candidateID,
                                           outcome: "\(c.status.rawValue) : \(c.detail)", verified: c.status == .applied || c.status == .rolledBack))
            }
            self.boostTask = nil
        }
    }

    /// Re-measures after guided actions done by the user.
    func verifyBoostGuided() {
        guard let orch = boostOrchestrator, let s = boostSession, boostTask == nil else { return }
        boostTask = Task {
            var out = await orch.verifyGuided(s, options: boostOptions) { phase, msg in
                Task { @MainActor in self.boostProgress = (phase, msg) }
            }
            out = await orch.finish(out)
            self.boostSession = out
            self.boostHistoryService.save(out)
            self.boostTask = nil
        }
    }

    func cancelBoost() {
        boostTask?.cancel()
        boostTask = nil
        cancelSpeedTest()
    }

    func rollbackBoostChange(_ id: UUID) {
        guard let orch = boostOrchestrator, var s = boostSession else { return }
        let executor = StandardBoostExecutor(sqm: router.openwrt, apps: AppQuitService())
        Task {
            let r = await orch.rollback.rollback(id, executor: executor)
            if let r, let i = s.changes.firstIndex(where: { $0.id == r.id }) {
                s.changes[i] = r
                if let ci = s.candidates.firstIndex(where: { $0.id == r.candidateID }), r.status == .rolledBack { s.candidates[ci].status = .restored }
            }
            self.boostSession = s
            self.boostHistoryService.save(s)
            if let r { self.audit(AdminAuditEntry(adapterID: "maxboost", action: "Restauration MAX BOOST", target: r.candidateID, outcome: r.detail, verified: r.status == .rolledBack)) }
        }
    }

    func loadBoostHistory() { boostHistory = boostHistoryService.all() }

    /// Estimated data volume of a plan, from the last measured networkQuality transfer size.
    func boostDataEstimate(automatedChanges: Int, sqmTuning: Bool) -> String {
        let perRun = speedTests.compactMap(\.bytesTransferred).last
        let runs = boostOptions.runs * (1 + automatedChanges) + (sqmTuning ? 3 * boostOptions.tuningRuns + boostOptions.runs : 0)
        guard let perRun else { return "\(runs) mesure(s) de débit (volume inconnu tant qu’aucun test n’a été fait)" }
        return "\(runs) mesure(s) ≈ \(Units.bytes(perRun * Double(runs)))"
    }
}
#endif
