import XCTest
@testable import NetScopeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private func sample(dl: Double, ul: Double = 40e6, idle: Double = 12, loaded: Double = 40, jitter: Double = 2, loss: Double = 0,
                    iface: String = "en0", target: String = "1.1.1.1", vpn: Bool = false, bg: Double = 0, rssi: Int? = -55) -> BoostSample {
    BoostSample(interface: iface, networkName: "Maison", target: target, vpnActive: vpn, downloadBps: dl, uploadBps: ul, idleLatencyMs: idle,
                loadedLatencyMs: loaded, jitterMs: jitter, lossPercent: loss, rssi: rssi, backgroundBps: bg)
}

private func wifi(rssi: Int, channel: Int = 6, band: WiFiBand = .ghz2_4, width: Int = 20, bssid: String = "aa:aa:aa:aa:aa:01", ssid: String = "Maison") -> WiFiSnapshot {
    let m = Provenance.measured(method: "test")
    return WiFiSnapshot(interfaceName: "en0", poweredOn: true, ssid: Sourced(ssid, m), bssid: Sourced(bssid, m), rssi: Sourced(rssi, m),
                        noise: Sourced(-92, m), channel: Sourced(channel, m), band: Sourced(band, m), channelWidthMHz: Sourced(width, m),
                        txRateMbps: Sourced(144, m), standard: Sourced(.ax, m), security: Sourced(.wpa2Personal, m))
}

final class BoostScoreABTests: XCTestCase {
    func testScoreWeightsAndExclusions() {
        XCTAssertEqual(MaxBoostScore.weights.map(\.1).reduce(0, +), 100)
        let s = MaxBoostScore.compute(samples: [sample(dl: 900e6), sample(dl: 880e6), sample(dl: 910e6)], referenceDownBps: 1e9, isWired: true)
        XCTAssertNotNil(s.total)
        XCTAssertNil(s.components.first { $0.criterion == "Fiabilité" }?.score, "missing data is excluded, never assumed good")
        XCTAssertTrue(s.note.contains("ne prouve pas"))
        XCTAssertNil(MaxBoostScore.compute(samples: [], referenceDownBps: nil, isWired: false).total)
    }

    func testULLGainWithAcceptableTradeoff() {
        let base = (0..<3).map { _ in sample(dl: 300e6, loaded: 180) }
        let cand = [sample(dl: 270e6, loaded: 25), sample(dl: 272e6, loaded: 28), sample(dl: 268e6, loaded: 24)]
        let r = PerformanceABTestingService.compare(baseline: base, candidate: cand, profile: .ultraLowLatency)
        XCTAssertEqual(r.verdict, .confirmedGain)
        XCTAssertEqual(r.state, .validated)
        XCTAssertTrue(r.improved.contains(.loadedLatency))
        XCTAssertTrue(r.tradeoffs.contains { $0.contains("Débit descendant") }, "throughput cost is shown, not hidden")
    }

    func testGuardViolationIsNotAGain() {
        let base = (0..<3).map { _ in sample(dl: 300e6, loaded: 180) }
        let cand = (0..<3).map { _ in sample(dl: 150e6, loaded: 20) }
        let r = PerformanceABTestingService.compare(baseline: base, candidate: cand, profile: .ultraLowLatency, tolerance: 0.15)
        XCTAssertEqual(r.verdict, .noGain)
        XCTAssertTrue(r.warnings.contains { $0.contains("tolérance") })
    }

    func testNoiseIsNotConfirmed() {
        let base = [sample(dl: 300e6), sample(dl: 260e6), sample(dl: 330e6)]
        let cand = [sample(dl: 310e6), sample(dl: 270e6), sample(dl: 320e6)]
        XCTAssertEqual(PerformanceABTestingService.compare(baseline: base, candidate: cand, profile: .maxSpeed).verdict, .noGain)
    }

    func testInsufficientAndIncomparable() {
        let base = [sample(dl: 100e6), sample(dl: 100e6)]
        XCTAssertEqual(PerformanceABTestingService.compare(baseline: base, candidate: base, profile: .maxSpeed).verdict, .insufficient)
        let b3 = (0..<3).map { _ in sample(dl: 100e6) }
        let eth = (0..<3).map { _ in sample(dl: 900e6, iface: "en5") }
        let r = PerformanceABTestingService.compare(baseline: b3, candidate: eth, profile: .maxSpeed)
        XCTAssertEqual(r.verdict, .insufficient, "different interfaces are not comparable")
        XCTAssertFalse(r.comparabilityIssues.isEmpty)
        let vpn = (0..<3).map { _ in sample(dl: 300e6, vpn: true) }
        XCTAssertEqual(PerformanceABTestingService.compare(baseline: b3, candidate: vpn, profile: .maxSpeed).verdict, .insufficient)
        let busy = (0..<3).map { _ in sample(dl: 300e6, bg: 50e6) }
        XCTAssertFalse(PerformanceABTestingService.compare(baseline: b3, candidate: busy, profile: .maxSpeed).warnings.isEmpty)
    }

    func testDegradation() {
        let base = (0..<3).map { _ in sample(dl: 500e6) }
        let cand = (0..<3).map { _ in sample(dl: 200e6) }
        XCTAssertEqual(PerformanceABTestingService.compare(baseline: base, candidate: cand, profile: .maxSpeed).verdict, .degraded)
    }
}

final class BoostEngineTests: XCTestCase {
    func testServiceOrderAndStackInspection() {
        let text = """
        An asterisk (*) denotes that a network service is disabled.
        (1) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)

        (2) USB 10/100/1000 LAN
        (Hardware Port: USB 10/100/1000 LAN, Device: en5)

        (*) Thunderbolt Bridge
        (Hardware Port: Thunderbolt Bridge, Device: bridge0)
        """
        let order = ServiceOrderParser.parse(text)
        XCTAssertEqual(order.map(\.device), ["en0", "en5", "bridge0"])
        XCTAssertFalse(order[2].enabled)
        let wifiIf = NetworkInterfaceInfo(bsdName: "en0", kind: .wifi, ipv4: [IPv4Assignment(address: "192.168.1.20", netmask: "255.255.255.0")], isUp: true, isRunning: true, mtu: 1500)
        let ethIf = NetworkInterfaceInfo(bsdName: "en5", kind: .ethernet, ipv4: [IPv4Assignment(address: "192.168.1.21", netmask: "255.255.255.0")], isUp: true, isRunning: true, mtu: 1400, media: "autoselect (1000baseT <full-duplex>)")
        let c = ConnectionSnapshot(isConnected: true, primaryInterface: wifiIf, interfaces: [wifiIf, ethIf], defaultGatewayIPv4: "192.168.1.254", defaultGatewayIPv6: nil,
                                   dns: DNSConfiguration(resolvers: [.init(index: 1, domain: nil, nameservers: ["192.168.1.254"], interface: "en0", isScoped: false)]),
                                   vpnActive: false, vpnInterfaces: [], proxy: nil)
        let bench = [DNSDiagnosticsService.BenchmarkRow(resolver: "1.1.1.1", label: "Cloudflare", medianMs: 12, p90Ms: 15, failures: 0, queries: 12)]
        let r = NetworkConfigurationInspector.inspect(connection: c, tcp: ["net.inet.tcp.sack": "0", "net.inet.tcp.autorcvbufmax": "4194304"],
                                                      serviceOrder: order, dnsBenchmark: bench, configuredDNSMedianMs: 60)
        XCTAssertTrue(r.candidates.contains { $0.id == "service-order" })
        XCTAssertEqual(r.findings.first { $0.id == "net.inet.tcp.sack" }?.status, .unusual)
        XCTAssertEqual(r.findings.first { $0.id == "net.inet.tcp.autorcvbufmax" }?.status, .normal)
        let dns = r.candidates.first { $0.id.hasPrefix("dns-") }
        XCTAssertNotNil(dns)
        XCTAssertTrue(dns!.detail.contains("pas le débit"))
        XCTAssertFalse(dns!.action.isAutomatable, "DNS is never changed by NetScope")
        XCTAssertTrue(r.candidates.allSatisfy { !$0.action.isAutomatable }, "stack inspection never proposes automated changes (TCP, MTU, IPv6…)")
        XCTAssertNil(NetworkConfigurationInspector.inspect(connection: c, tcp: [:], serviceOrder: [], dnsBenchmark: bench, configuredDNSMedianMs: 20)
                        .candidates.first { $0.id.hasPrefix("dns-") }, "no measured benefit → no DNS recommendation")
    }

    func testContentionNeedsEvidence() {
        func rate(_ p: String, _ bps: Double) -> ProcessTrafficService.ProcessRate { .init(process: p, pid: 42, inBps: bps, outBps: 0) }
        let two = [[rate("Dropbox", 80e6)], [rate("Dropbox", 80e6)]]
        let r2 = BandwidthContentionAnalyzer.analyze(processSamples: two, intervalSeconds: 5, interfaceSamples: [], capacityBps: 100e6, routerClients: [])
        XCTAssertFalse(r2.processes.contains { $0.likelyContributor }, "fewer than 3 samples: nobody is blamed")
        let many = (0..<6).map { _ in [rate("Dropbox", 80e6), rate("Safari", 1e6)] }
        let iface = (0..<6).map { ThroughputSample(timestamp: Date(timeIntervalSince1970: Double($0)), inBps: 82e6, outBps: 1e6) }
        let r = BandwidthContentionAnalyzer.analyze(processSamples: many, intervalSeconds: 5, interfaceSamples: iface, capacityBps: 100e6, routerClients: [])
        XCTAssertEqual(r.processes.first?.name, "Dropbox")
        XCTAssertTrue(r.processes.first!.likelyContributor)
        XCTAssertFalse(r.processes.first { $0.name == "Safari" }!.likelyContributor)
        let quit = BandwidthContentionAnalyzer.candidates(r, quittableNames: ["Dropbox"])
        XCTAssertEqual(quit.first?.action, .quitApplication(pid: 42, name: "Dropbox"))
        XCTAssertEqual(quit.first?.safety, .reversible)
        let guided = BandwidthContentionAnalyzer.candidates(r, quittableNames: [])
        XCTAssertFalse(guided.first!.action.isAutomatable, "background processes are never killed")
    }

    func testWiFiBooster() {
        let neighbors = [WiFiNeighbor(ssid: "Maison", bssid: "aa:aa:aa:aa:aa:02", rssi: -60, noise: nil, channel: 36, band: .ghz5, channelWidthMHz: 80, security: .wpa2Personal)]
            + (0..<5).map { WiFiNeighbor(ssid: "V\($0)", bssid: "bb:00:00:00:00:0\($0)", rssi: -55, noise: nil, channel: 6, band: .ghz2_4, channelWidthMHz: 20, security: nil) }
        let r = WiFiOptimizationEngine.recommend(WiFiBoostInput(wifi: wifi(rssi: -72, width: 40), isWired: false, neighbors: neighbors,
                                                                 wifiDownMedianBps: 40e6, ethernetDownMedianBps: 900e6))
        let ids = Set(r.candidates.map(\.id))
        XCTAssertTrue(ids.isSuperset(of: ["wifi-position", "wifi-band", "wifi-ap", "wifi-channel", "wifi-width", "use-ethernet"]), "\(ids)")
        XCTAssertTrue(r.candidates.allSatisfy { !$0.action.isAutomatable }, "radio changes are guided only")
        XCTAssertTrue(r.notes.contains { $0.contains("MLO") })
        XCTAssertTrue(WiFiOptimizationEngine.recommend(WiFiBoostInput(wifi: wifi(rssi: -80), isWired: true)).candidates.isEmpty)
    }

    func testBufferbloatTuningSelection() {
        let base = SQMSettings(section: "eth1", interface: "wan", enabled: false, downloadKbps: 0, uploadKbps: 0)
        let cands = BufferbloatTuningService.candidates(base: base, measuredDownBps: 100e6, measuredUpBps: 20e6)
        XCTAssertEqual(cands.map(\.downloadKbps), [95000, 90000, 85000])
        XCTAssertTrue(cands.allSatisfy { $0.enabled && $0.qdisc == "cake" })
        let baseline = (0..<3).map { _ in sample(dl: 100e6, loaded: 150) }
        let trials = [TuningTrial(settings: cands[0], samples: [sample(dl: 94e6, loaded: 60), sample(dl: 93e6, loaded: 62)]),
                      TuningTrial(settings: cands[1], samples: [sample(dl: 89e6, loaded: 22), sample(dl: 88e6, loaded: 20)]),
                      TuningTrial(settings: cands[2], samples: [sample(dl: 86e6, loaded: 18), sample(dl: 86e6, loaded: 19)])]
        let d = BufferbloatTuningService.select(trials: trials, baseline: baseline, tolerance: 0.15)
        XCTAssertEqual(d.chosen?.downloadKbps, 85000)
        let strict = BufferbloatTuningService.select(trials: trials, baseline: baseline, tolerance: 0.07)
        XCTAssertEqual(strict.chosen?.downloadKbps, 95000)
        let costly = BufferbloatTuningService.select(trials: [TuningTrial(settings: cands[2], samples: [sample(dl: 50e6, loaded: 15), sample(dl: 50e6, loaded: 15)])],
                                                     baseline: baseline, tolerance: 0.15)
        XCTAssertNil(costly.chosen, "never trades a large throughput loss silently")
        XCTAssertNotNil(costly.warning)
        let useless = BufferbloatTuningService.select(trials: [TuningTrial(settings: cands[0], samples: [sample(dl: 95e6, loaded: 150), sample(dl: 95e6, loaded: 148)])],
                                                      baseline: baseline)
        XCTAssertNil(useless.chosen)
    }

    func testRouterOptimizerAndRanking() {
        let bloated = (0..<3).map { _ in sample(dl: 200e6, loaded: 200) }
        let sqm = SQMSettings(section: "eth1", interface: "wan", enabled: false, downloadKbps: 0, uploadKbps: 0)
        let writable = RouterQoSOptimizer.candidates(state: RouterTuningState(adapterID: "openwrt", sqm: [sqm], canWriteSQM: true, allClientCount: 8), baseline: bloated, profile: .ultraLowLatency)
        let c = writable.first { $0.id == "router-sqm" }
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.safety, .sensitive)
        XCTAssertTrue(c!.affected.first!.contains("Tous les appareils"))
        let readOnly = RouterQoSOptimizer.candidates(state: RouterTuningState(adapterID: "freebox", sqmUnavailableReason: "Pas d’API QoS documentée."), baseline: bloated, profile: .maxSpeed)
        XCTAssertNil(readOnly.first { $0.action.isAutomatable }, "no automated QoS without an official API")
        XCTAssertNotNil(readOnly.first { $0.id == "router-qos-guided" })

        let fast = BoostCandidate(id: "a", title: "a", detail: "", evidence: [], category: .wifi, targets: [.download], expectedGain: .high, risk: .none, reversible: true, safety: .readOnly, action: .guided(steps: []))
        let lat = BoostCandidate(id: "b", title: "b", detail: "", evidence: [], category: .latency, targets: [.loadedLatency], expectedGain: .high, risk: .none, reversible: true, safety: .readOnly, action: .guided(steps: []))
        XCTAssertEqual(BoostCandidateEvaluator.rank([fast, lat], profile: .maxSpeed).first?.id, "a")
        XCTAssertEqual(BoostCandidateEvaluator.rank([fast, lat], profile: .ultraLowLatency).first?.id, "b")
    }
}

// MARK: - Rollback & orchestration

final class MockExecutor: BoostChangeExecutor, @unchecked Sendable {
    var current: SQMSettings
    var reachable = true
    var failSnapshot = false, failApply = false, failRestore = false
    var applied: [BoostAction] = []
    let lock = NSLock()
    init(current: SQMSettings) { self.current = current }
    func snapshot(before action: BoostAction) async throws -> BoostAction? {
        if failSnapshot { throw BoostExecutionError.notFound("x") }
        if case .routerSQM = action { return .routerSQM(locked { current }) }
        return nil
    }
    func apply(_ action: BoostAction) async throws {
        if failApply { throw RouterError.insufficientPermission("uci sqm") }
        locked { applied.append(action); if case .routerSQM(let s) = action { current = s } }
    }
    func isReachable(after action: BoostAction) async -> Bool { reachable }
    func confirm(_ action: BoostAction) async throws {}
    func restore(_ snapshot: BoostAction) async throws {
        if failRestore { throw RouterError.transport("timeout") }
        if case .routerSQM(let s) = snapshot { locked { current = s } }
    }
    func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
}

final class RollbackTests: XCTestCase {
    let original = SQMSettings(section: "eth1", interface: "wan", enabled: false, downloadKbps: 0, uploadKbps: 0)
    let proposal = SQMSettings(section: "eth1", interface: "wan", enabled: true, downloadKbps: 90000, uploadKbps: 18000)

    func testApplyAndRestore() async {
        let ex = MockExecutor(current: original)
        let m = NetworkRollbackManager()
        let r = await m.perform(.routerSQM(proposal), candidateID: "router-sqm", executor: ex)
        XCTAssertEqual(r.status, .applied)
        XCTAssertEqual(ex.current, proposal)
        XCTAssertEqual(r.before, .routerSQM(original))
        let back = await m.rollback(r.id, executor: ex)
        XCTAssertEqual(back?.status, .rolledBack)
        XCTAssertEqual(ex.current, original, "previous state restored exactly")
    }

    func testNoBackupNoChange() async {
        let ex = MockExecutor(current: original); ex.failSnapshot = true
        let r = await NetworkRollbackManager().perform(.routerSQM(proposal), candidateID: "x", executor: ex)
        XCTAssertEqual(r.status, .failed)
        XCTAssertTrue(ex.applied.isEmpty, "never applies without a backup of the previous state")
    }

    func testUnreachableNeedsManualRecovery() async {
        let ex = MockExecutor(current: original); ex.reachable = false
        let r = await NetworkRollbackManager().perform(.routerSQM(proposal), candidateID: "x", executor: ex)
        XCTAssertEqual(r.status, .needsManualRecovery)
        XCTAssertTrue(r.recoveryProcedure.contains("ne peut pas restaurer à distance"))
        XCTAssertTrue(r.recoveryProcedure.contains("uci set sqm.eth1.enabled='0'"))
    }

    func testRollbackFailureAndNonRestorable() async {
        let ex = MockExecutor(current: original)
        let m = NetworkRollbackManager()
        let r = await m.perform(.routerSQM(proposal), candidateID: "x", executor: ex)
        ex.failRestore = true
        let back = await m.rollback(r.id, executor: ex)
        XCTAssertEqual(back?.status, .rollbackFailed)
        let q = await m.perform(.quitApplication(pid: 1, name: "Dropbox"), candidateID: "q", executor: ex)
        XCTAssertEqual(q.status, .applied)
        XCTAssertFalse(q.restorable)
        XCTAssertTrue(q.recoveryProcedure.contains("Relancez"))
        let g = await m.perform(.guided(steps: ["x"]), candidateID: "g", executor: ex)
        XCTAssertEqual(g.status, .failed, "guided actions are never executed")
    }
}

/// Simulated network whose measurements depend on the executor's SQM state.
final class MockEnv: BoostEnvironment, @unchecked Sendable {
    let ex: MockExecutor
    var calls = 0
    var sqmHelps = true
    init(ex: MockExecutor) { self.ex = ex }
    func measureOnce() async throws -> BoostSample {
        calls += 1
        let s = ex.current
        let jitter = Double(calls % 3)
        if s.enabled && sqmHelps {
            let factor = Double(s.downloadKbps) / 100_000
            return sample(dl: 100e6 * factor - jitter * 1e5, loaded: 15 + (factor - 0.85) * 100 + jitter, rssi: nil)
        }
        return sample(dl: 100e6 - jitter * 1e5, loaded: 160 + jitter, rssi: nil)
    }
    func diagnosticReport() async -> DiagnosticReport { DiagnosticReport(timestamp: Date(), hypotheses: [], observedFacts: [], dataGaps: []) }
    func wifiInput() async -> WiFiBoostInput { WiFiBoostInput(wifi: nil, isWired: true) }
    func contention() async -> ContentionReport { ContentionReport(processes: [], devices: [], interfaceMeanBps: nil, saturationRatio: nil, samples: 0, notes: []) }
    func stackInspection() async -> (findings: [StackFinding], candidates: [BoostCandidate]) { ([], []) }
    func routerState() async -> RouterTuningState { RouterTuningState(adapterID: "openwrt", sqm: [ex.current], canWriteSQM: true, allClientCount: 5) }
    func quittableApplications() async -> Set<String> { [] }
    func referenceDownBps() async -> Double? { 100e6 }
    func isWired() async -> Bool { true }
}

final class OrchestratorTests: XCTestCase {
    let original = SQMSettings(section: "eth1", interface: "wan", enabled: false, downloadKbps: 0, uploadKbps: 0)

    func testNothingAppliedWithoutAuthorization() async {
        let ex = MockExecutor(current: original)
        let o = MaxBoostOrchestrator(env: MockEnv(ex: ex))
        var s = await o.analyze(profile: .ultraLowLatency, options: BoostOptions()) { _, _ in }
        XCTAssertEqual(s.phase, .recommendations)
        XCTAssertEqual(s.candidates.first { $0.id == "router-sqm" }?.status, .authorizationNeeded)
        s = await o.optimize(s, authorized: [], executor: ex, options: BoostOptions()) { _, _ in }
        XCTAssertTrue(ex.applied.isEmpty)
        XCTAssertEqual(ex.current, original)
        XCTAssertEqual(s.candidates.first { $0.id == "router-sqm" }?.status, .skipped)
    }

    func testAuthorizedSQMAutoTuningKeepsValidatedSetting() async {
        let ex = MockExecutor(current: original)
        let o = MaxBoostOrchestrator(env: MockEnv(ex: ex))
        var s = await o.analyze(profile: .ultraLowLatency, options: BoostOptions()) { _, _ in }
        s = await o.optimize(s, authorized: ["router-sqm"], executor: ex, options: BoostOptions()) { _, _ in }
        s = await o.finish(s)
        XCTAssertEqual(s.candidates.first { $0.id == "router-sqm" }?.status, .gainConfirmed)
        XCTAssertTrue(ex.current.enabled)
        // 85 % costs just over 15 % of throughput in this simulation → the 90 % setting is the best validated compromise.
        XCTAssertTrue((89_000...90_000).contains(ex.current.downloadKbps), "\(ex.current.downloadKbps)")
        XCTAssertEqual(s.evaluations["router-sqm"]?.verdict, .confirmedGain)
        XCTAssertNotNil(s.scoreAfter)
        XCTAssertEqual(s.phase, .report)
        let md = s.report().markdown()
        XCTAssertTrue(md.contains("BEFORE BOOST / AFTER BOOST"))
        XCTAssertTrue(md.contains("Latence sous charge"))
    }

    func testNoGainRestoresOriginal() async {
        let ex = MockExecutor(current: original)
        let env = MockEnv(ex: ex); env.sqmHelps = false
        let o = MaxBoostOrchestrator(env: env)
        var s = await o.analyze(profile: .ultraLowLatency, options: BoostOptions()) { _, _ in }
        s = await o.optimize(s, authorized: ["router-sqm"], executor: ex, options: BoostOptions()) { _, _ in }
        XCTAssertEqual(s.candidates.first { $0.id == "router-sqm" }?.status, .noGain)
        XCTAssertEqual(ex.current, original, "configuration restored when no gain is demonstrated")
        XCTAssertTrue(s.changes.contains { $0.status == .rolledBack })
    }

    func testHistoryPersistence() async throws {
        let ex = MockExecutor(current: original)
        let o = MaxBoostOrchestrator(env: MockEnv(ex: ex))
        var s = await o.analyze(profile: .smartAuto, options: BoostOptions(runs: 3)) { _, _ in }
        s = await o.finish(s)
        let store = try HistoryStore(url: nil)
        let h = BoostHistoryService(store: store)
        h.save(s)
        XCTAssertEqual(h.all().first?.id, s.id)
        XCTAssertEqual(h.all().first?.baseline.count, 3)
    }
}

// MARK: - OpenWrt integration (simulated rpcd with apply/confirm/rollback semantics)

final class FakeRpcd: HTTPTransport, @unchecked Sendable {
    var active: [String: [String: String]] = ["eth1": [".type": "queue", "enabled": "0", "interface": "wan", "download": "0", "upload": "0", "qdisc": "cake", "script": "piece_of_cake.qos"]]
    var staged: [String: [String: String]] = [:]
    var pendingRollback: [String: [String: String]]?
    var canWrite = true
    var reachable = true
    let lock = NSLock()

    func send(_ r: URLRequest) async throws -> (Data, Int) { try handle(r) }

    private func handle(_ r: URLRequest) throws -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        guard reachable else { throw RouterError.transport("timeout") }
        let o = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
        let p = o["params"] as! [Any]
        let obj = "\(p[1]).\(p[2])"
        let args = p[3] as? [String: Any] ?? [:]
        func ok(_ v: Any? = nil) -> (Data, Int) {
            let res: [Any] = v.map { [0, $0] } ?? [0]
            return (try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": res]), 200)
        }
        func code(_ c: Int) -> (Data, Int) { (try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": [c]]), 200) }
        switch obj {
        case "session.login": return ok(["ubus_rpc_session": "sid"])
        case "session.access": return ok(["access": canWrite])
        case "system.board": return ok(["hostname": "OpenWrt", "model": "Test"])
        case "uci.get":
            guard args["config"] as? String == "sqm" else { return code(4) }
            return ok(["values": active])
        case "uci.set":
            guard canWrite else { return code(6) }
            let sec = args["section"] as! String
            var v = active[sec] ?? [:]
            for (k, x) in args["values"] as! [String: String] { v[k] = x }
            staged[sec] = v
            return ok()
        case "uci.apply":
            guard args["rollback"] as? Bool == true else { return code(2) }
            pendingRollback = active
            for (k, v) in staged { active[k] = v }
            staged = [:]
            return ok()
        case "uci.confirm":
            pendingRollback = nil
            return ok()
        default: return code(4)
        }
    }

    /// What rpcd does when the timeout expires without confirmation.
    func expireRollbackTimer() { lock.lock(); if let p = pendingRollback { active = p; pendingRollback = nil }; lock.unlock() }
}

final class OpenWrtSQMIntegrationTests: XCTestCase {
    func makeAdapter(_ rpcd: FakeRpcd) async throws -> OpenWrtAdapter {
        let a = OpenWrtAdapter(host: "192.168.1.1", transport: rpcd, secrets: InMemorySecretStore())
        try await a.login(user: "netscope", password: "pw")
        return a
    }

    func testApplyConfirmAndRestoreThroughRpcd() async throws {
        let rpcd = FakeRpcd()
        let a = try await makeAdapter(rpcd)
        let sqm = try await a.readSQM()
        XCTAssertEqual(sqm.first?.section, "eth1"); XCTAssertEqual(sqm.first?.enabled, false)
        let canWrite = await a.canWriteSQM()
        XCTAssertTrue(canWrite)
        let ex = StandardBoostExecutor(sqm: a, apps: nil)
        let m = NetworkRollbackManager()
        var target = sqm[0]; target.enabled = true; target.downloadKbps = 90000; target.uploadKbps = 18000
        let rec = await m.perform(.routerSQM(target), candidateID: "router-sqm", executor: ex)
        XCTAssertEqual(rec.status, .applied)
        XCTAssertEqual(rpcd.active["eth1"]?["enabled"], "1")
        XCTAssertEqual(rpcd.active["eth1"]?["download"], "90000")
        XCTAssertNil(rpcd.pendingRollback, "change confirmed after the reachability check")
        let back = await m.rollback(rec.id, executor: ex)
        XCTAssertEqual(back?.status, .rolledBack)
        XCTAssertEqual(rpcd.active["eth1"]?["enabled"], "0", "original configuration restored")
        XCTAssertEqual(rpcd.active["eth1"]?["download"], "0")
    }

    func testUnreachableRouterRevertsByItself() async throws {
        let rpcd = FakeRpcd()
        let a = try await makeAdapter(rpcd)
        var target = try await a.readSQM()[0]; target.enabled = true; target.downloadKbps = 90000; target.uploadKbps = 18000

        // A transport that drops right after the apply call.
        final class Dropper: HTTPTransport, @unchecked Sendable {
            let inner: FakeRpcd; var applied = false
            init(_ i: FakeRpcd) { inner = i }
            func send(_ r: URLRequest) async throws -> (Data, Int) {
                if applied { throw RouterError.transport("timeout") }
                let body = String(decoding: r.httpBody ?? Data(), as: UTF8.self)
                let res = try await inner.send(r)
                if body.contains("\"apply\"") { applied = true }
                return res
            }
        }
        let b = OpenWrtAdapter(host: "192.168.1.1", transport: Dropper(rpcd), secrets: InMemorySecretStore())
        try await b.login(user: "netscope", password: "pw")
        let rec = await NetworkRollbackManager().perform(.routerSQM(target), candidateID: "router-sqm", executor: StandardBoostExecutor(sqm: b, apps: nil))
        XCTAssertEqual(rec.status, .needsManualRecovery)
        XCTAssertNotNil(rpcd.pendingRollback, "not confirmed")
        rpcd.expireRollbackTimer()
        XCTAssertEqual(rpcd.active["eth1"]?["enabled"], "0", "rpcd reverted the unconfirmed change")
        _ = a
    }

    func testPermissionDeniedLeavesRouterUntouched() async throws {
        let rpcd = FakeRpcd(); rpcd.canWrite = false
        let a = try await makeAdapter(rpcd)
        let canWrite = await a.canWriteSQM()
        XCTAssertFalse(canWrite)
        var target = try await a.readSQM()[0]; target.enabled = true; target.downloadKbps = 90000; target.uploadKbps = 18000
        let rec = await NetworkRollbackManager().perform(.routerSQM(target), candidateID: "x", executor: StandardBoostExecutor(sqm: a, apps: nil))
        XCTAssertEqual(rec.status, .failed)
        XCTAssertEqual(rpcd.active["eth1"]?["enabled"], "0")
    }

    func testInputValidation() async throws {
        let a = try await makeAdapter(FakeRpcd())
        let bad = [SQMSettings(section: "eth1; reboot", interface: "wan", enabled: true, downloadKbps: 90000, uploadKbps: 18000),
                   SQMSettings(section: "eth1", interface: "wan", enabled: true, downloadKbps: 5, uploadKbps: 18000),
                   SQMSettings(section: "eth1", interface: "wan", enabled: true, downloadKbps: 90000, uploadKbps: 18000, qdisc: "pfifo", script: "x.qos")]
        for s in bad {
            do { try await a.stageSQM(s); XCTFail("accepted \(s)") } catch {}
        }
    }

    func testMissingSQMPackage() async throws {
        final class NoSQM: HTTPTransport, @unchecked Sendable {
            let inner = FakeRpcd()
            func send(_ r: URLRequest) async throws -> (Data, Int) {
                if String(decoding: r.httpBody ?? Data(), as: UTF8.self).contains("\"sqm\"") {
                    return (Data(#"{"jsonrpc":"2.0","id":1,"result":[4]}"#.utf8), 200)
                }
                return try await inner.send(r)
            }
        }
        let a = OpenWrtAdapter(host: "192.168.1.1", transport: NoSQM(), secrets: InMemorySecretStore())
        try await a.login(user: "u", password: "p")
        do { _ = try await a.readSQM(); XCTFail() }
        catch { XCTAssertEqual(error as? RouterError, .unsupported("sqm-scripts non installé (aucune configuration « sqm »)")) }
    }
}
