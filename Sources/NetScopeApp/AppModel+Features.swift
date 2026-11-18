#if os(macOS)
import SwiftUI
import NetScopeCore
import NetScopeSystem

// MARK: - Speedtest

extension AppModel {
    func startSpeedTest(_ mode: SpeedTestMode) {
        guard runningTest == nil else { return }
        testTask = Task { await runSpeedTest(mode) }
    }

    func cancelSpeedTest() {
        testTask?.cancel()
        runningTest?.phase = "Annulation…"
    }

    func runSpeedTest(_ mode: SpeedTestMode, forceReduced: Bool = false) async {
        lastTestError = nil
        runningTest = RunningTest(mode: mode, started: Date(), phase: "Préparation")
        defer { runningTest = nil }
        let vpn = connection?.vpnActive ?? false
        let proxy = connection?.proxy?.isActive ?? false
        let reduced = forceReduced || settings.reducedDataMode
        do {
            switch mode {
            case .lan:
                guard !settings.lanServer.isEmpty else { throw CommandError.invalidArgument("serveur LAN non configuré (Réglages)") }
                guard lanService.isAvailable else { throw CommandError.toolNotFound(.iperf3) }
                runningTest?.phase = "LAN : réception (serveur → Mac)"
                let down = try await lanService.run(server: settings.lanServer, reverse: true)
                runningTest?.phase = "LAN : envoi (Mac → serveur)"
                let up = try await lanService.run(server: settings.lanServer, reverse: false)
                var r = LANTestService.asSpeedTest(down: down, up: up, server: settings.lanServer, interface: connection?.primaryInterface?.bsdName)
                r.networkName = networkName
                persist(r)
            case .gaming:
                runningTest?.phase = "Latence au repos et pics (ICMP)"
                await measureLatencyFull()
                runningTest?.phase = "Latence sous charge (networkQuality)"
                var r = try await speedService.run(.preset(.gaming, reducedData: reduced), vpnActive: vpn, proxyActive: proxy, networkName: networkName)
                if let best = externalLatency.filter({ $0.received > 0 }).min(by: { ($0.medianMs ?? 1e9) < ($1.medianMs ?? 1e9) }) {
                    r.jitterMs = best.jitterMs; r.packetLossPercent = best.lossPercent
                }
                persist(r)
            case .videoCall, .streaming, .full:
                runningTest?.phase = "Latence et pertes (ICMP)"
                await measureLatencyFull()
                runningTest?.phase = "Débit et réactivité (networkQuality, séquentiel)"
                var r = try await speedService.run(.preset(mode, reducedData: reduced), vpnActive: vpn, proxyActive: proxy, networkName: networkName)
                if let e = externalLatency.first(where: { $0.received > 0 }) { r.packetLossPercent = e.lossPercent; r.jitterMs = r.jitterMs ?? e.jitterMs }
                if mode == .full {
                    runningTest?.phase = "DNS"
                    await testDNS()
                    r.dnsResolutionMs = Stats.median(dnsResults.filter(\.success).compactMap(\.durationMs))
                }
                persist(r)
                if mode == .streaming && !reduced {
                    runningTest?.phase = "Second passage (stabilité)"
                    let r2 = try await speedService.run(.preset(.quick, reducedData: false), vpnActive: vpn, proxyActive: proxy, networkName: networkName)
                    persist(r2)
                }
            case .quick, .bufferbloat:
                runningTest?.phase = "Débit et latence (networkQuality)"
                let r = try await speedService.run(.preset(mode, reducedData: reduced), vpnActive: vpn, proxyActive: proxy, networkName: networkName)
                persist(r)
            }
        } catch is CancellationError {
            lastTestError = "Test annulé."
        } catch let e as CommandError where e == .cancelled {
            lastTestError = "Test annulé."
        } catch {
            lastTestError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            var failed = SpeedTestResult(mode: mode, engine: mode == .lan ? .iperf3 : .networkQuality,
                                         interfaceName: connection?.primaryInterface?.bsdName, networkName: networkName,
                                         vpnActive: vpn, proxyActive: proxy, error: lastTestError)
            failed.missingFields = ["toutes"]
            try? store?.save(failed, kind: .speedTest, id: failed.id.uuidString, timestamp: failed.timestamp, network: networkName)
        }
    }

    private func persist(_ r: SpeedTestResult) {
        speedTests.append(r)
        try? store?.save(r, kind: .speedTest, id: r.id.uuidString, timestamp: r.timestamp, network: r.networkName)
        record(NetworkEvent(kind: .speedtest, message: "\(r.mode.label) : ↓ \(r.downloadBps.map(Units.bitRate) ?? "—") ↑ \(r.uploadBps.map(Units.bitRate) ?? "—")"))
        if settings.notifyPerformanceDrop, let dl = r.downloadBps,
           let med = Stats.median(speedTests.dropLast().suffix(10).compactMap(\.downloadBps)), dl < med * 0.5 {
            NotificationsService.shared.notify(title: "Baisse de performance", body: "Débit \(Units.bitRate(dl)) contre une médiane récente de \(Units.bitRate(med)).")
        }
    }

    var latestTest: SpeedTestResult? { speedTests.filter(\.succeeded).max { $0.timestamp < $1.timestamp } }
}

// MARK: - Devices

extension AppModel {
    func passiveDiscovery() async {
        let obs = await neighborService.readCaches()
        merge(obs)
    }

    func discoverDevices() async {
        guard !discovering else { return }
        discovering = true
        defer { discovering = false }
        var obs = await neighborService.readCaches()
        obs += await BonjourDiscoveryService().discover(seconds: 6)
        obs += routerObservations()
        merge(obs)
        peripherals = await peripheralService.read()
    }

    func activeProbe() async {
        guard settings.acknowledgedActiveProbe, let iface = connection?.primaryInterface,
              let subnet = iface.ipv4.first?.subnet else { return }
        discovering = true
        defer { discovering = false; discoveryProgress = nil }
        do {
            let obs = try await neighborService.probe(subnet: subnet, localAssignments: iface.ipv4) { done, total in
                Task { @MainActor in self.discoveryProgress = (done, total) }
            }
            merge(obs)
        } catch { lastTestError = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
    }

    func routerObservations() -> [DeviceObservation] {
        router.clients.map {
            DeviceObservation(method: .router, timestamp: $0.lastSeen ?? Date(), ip: $0.ipv4, ipv6: $0.ipv6.first, mac: $0.mac,
                              hostname: $0.name, vendorHint: $0.vendor, modelHint: $0.hostType, routerActive: $0.active,
                              routerConnectionType: $0.link.rawValue)
        }
    }

    func merge(_ obs: [DeviceObservation]) {
        var all = obs
        if let me = connection?.primaryInterface, let ip = me.ipv4.first?.address {
            all.append(DeviceObservation(method: .selfDevice, ip: ip, mac: me.macAddress, hostname: Host.current().localizedName, services: ["_workstation._tcp"]))
        }
        let firstScan = inventory.devices.isEmpty
        let report = inventory.merge(all, gatewayIP: connection?.defaultGatewayIPv4, oui: oui)
        if !firstScan {
            for d in report.newDevices {
                record(NetworkEvent(kind: .newDevice, message: "Nouvel appareil observé : \(d.displayName) (\(d.ipv4 ?? d.mac ?? "?"))"))
                if settings.notifyNewDevice { NotificationsService.shared.notify(title: "Nouvel appareil", body: redact("\(d.displayName) — \(d.ipv4 ?? "")")) }
            }
        }
        saveInventory()
    }

    func importOUI(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        oui = OUIDatabase.parseIEEECSV(text)
    }
}

// MARK: - Router

extension AppModel {
    func detectRouter() async {
        router.detecting = true; router.error = nil
        defer { router.detecting = false }
        let transport = URLSessionTransport(timeout: 3)
        var hosts = ["mafreebox.freebox.fr"]
        if let gw = connection?.defaultGatewayIPv4 { hosts.insert(gw, at: 0) }
        var found: [RouterProbeResult] = []
        for h in hosts {
            if let p = await FreeboxAdapter.probe(host: h, transport: transport) { found.append(p); break }
        }
        if let gw = connection?.defaultGatewayIPv4, let p = await OpenWrtAdapter.probe(host: gw, transport: transport) { found.append(p) }
        router.probes = found
        if found.isEmpty { router.error = RouterError.notDetected.errorDescription }
    }

    func connectFreebox(host: String) async {
        let fb = FreeboxAdapter(host: host, secrets: secrets)
        router.freebox = fb; router.openwrt = nil; router.adapterID = "freebox"; router.error = nil
        do {
            let hasToken = await fb.hasAppToken
            if !hasToken {
                router.status = "Demande d’autorisation envoyée : validez « NetScope Pro » sur l’écran de la Freebox (flèche droite / Oui)."
                let req = try await fb.requestAuthorization(deviceName: Host.current().localizedName ?? "Mac")
                var status = FreeboxAdapter.AuthorizationStatus.pending
                for _ in 0..<60 where status == .pending || status == .unknown {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    status = try await fb.authorizationStatus(req)
                }
                switch status {
                case .granted: router.status = "Autorisation accordée."
                case .denied: throw RouterError.authorizationDenied
                case .timeout, .pending, .unknown: throw RouterError.authorizationTimeout
                }
            }
            try await fb.openSession()
            await refreshRouter()
        } catch {
            router.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func connectOpenWrt(host: String, user: String, password: String) async {
        let ow = OpenWrtAdapter(host: host, secrets: secrets)
        router.openwrt = ow; router.freebox = nil; router.adapterID = "openwrt"; router.error = nil
        do { try await ow.login(user: user, password: password.isEmpty ? nil : password); await refreshRouter() }
        catch { router.error = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
    }

    var activeAdapter: (any RouterAdapter)? {
        if let f = router.freebox { return f }
        if let o = router.openwrt { return o }
        return nil
    }

    func refreshRouter() async {
        guard let a = activeAdapter else { return }
        router.capabilities = await a.capabilities
        do {
            router.info = try await a.fetchInfo()
            router.clients = (try? await a.fetchClients()) ?? []
            router.wan = try? await a.fetchWAN()
            router.wifi = try? await a.fetchWiFi()
            if router.capabilities.contains(.blockDevice) { router.rules = (try? await a.listAccessRules()) ?? [] }
            router.lastRefresh = Date()
            merge(routerObservations())
        } catch { router.error = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
    }

    /// Executes a block/unblock via the official API after the UI collected explicit confirmation.
    func setBlocked(mac: String, name: String, blocked: Bool) async -> String {
        guard let a = activeAdapter, router.capabilities.contains(.blockDevice) else {
            return RouterError.unsupported("blocage").errorDescription ?? ""
        }
        let id = router.adapterID ?? "?"
        do {
            let rule = try await a.setBlocked(mac: mac, blocked: blocked, comment: "NetScope — \(name)")
            let entry = AdminAuditEntry(adapterID: id, action: blocked ? "Blocage (filtre MAC Wi-Fi)" : "Déblocage", target: "\(name) \(mac)",
                                        outcome: "Succès, vérifié par relecture des règles", verified: true)
            audit(entry)
            router.rules = (try? await a.listAccessRules()) ?? router.rules
            if blocked, router.wifi?.macFilterMode != "blacklist" {
                return "Règle créée et vérifiée. Attention : le filtrage MAC de la box est en mode « \(router.wifi?.macFilterMode ?? "inconnu") » ; la règle ne prend effet qu’en mode liste noire."
            }
            _ = rule
            return blocked ? "Appareil bloqué (Wi-Fi) et vérifié." : "Appareil débloqué et vérifié."
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            audit(AdminAuditEntry(adapterID: id, action: blocked ? "Blocage" : "Déblocage", target: "\(name) \(mac)", outcome: "Échec : \(msg)", verified: false))
            return msg
        }
    }

    func audit(_ e: AdminAuditEntry) {
        auditLog.insert(e, at: 0)
        try? store?.save(e, kind: .auditLog, id: e.id.uuidString, timestamp: e.timestamp)
        record(NetworkEvent(kind: .routerAction, message: "\(e.action) — \(e.target) : \(e.outcome)"))
    }
}

// MARK: - Health monitor, bufferbloat, gaming, multi-point

extension AppModel {
    func loadLabs() {
        guard let store else { return }
        healthSamples = (try? store.load(HealthSample.self, kind: .healthSample, from: Date().addingTimeInterval(-30 * 86400)).items) ?? []
        bufferbloatTrials = (try? store.load(BufferbloatTrial.self, kind: .bufferbloatReport).items) ?? []
        heatmapProjects = (try? store.load(HeatmapProject.self, kind: .heatmapProject).items) ?? []
        if let p = try? store.loadOne(ISPProfile.self, kind: .ispProfile, id: "isp") { ispProfile = p }
        if let a = try? store.loadOne([AgentPairing].self, kind: .multipointRun, id: "agents") { agents = a }
        auditLog = ((try? store.load(AdminAuditEntry.self, kind: .auditLog).items) ?? []).reversed()
        var det = OutageDetector(threshold: 2)
        for s in healthSamples { _ = det.ingest(s) }
        healthDetector = det
    }

    func healthCheck() async {
        let gw = connection?.defaultGatewayIPv4
        async let g: LatencyStats? = gw == nil ? nil : (try? await latencyService.ping(gw!, count: 3, interval: 0.3))
        var inet: [LatencyStats] = []
        for t in settings.latencyTargets.prefix(2) { if let r = try? await latencyService.ping(t, count: 3, interval: 0.3) { inet.append(r) } }
        let resolver = connection?.dns?.primaryNameservers.first { IPv4.parse($0) != nil }
        let dns: DNSQueryResult? = resolver == nil ? nil : await DNSClient().resolve(HealthMonitorConfig.default.dnsProbeName, resolver: resolver!)
        let gwStats = await g
        let reachable = inet.contains { $0.received > 0 }
        let s = HealthSample(interface: connection?.primaryInterface?.bsdName, networkName: networkName,
                             gatewayReachable: gwStats.map { $0.received > 0 }, gatewayRTTms: gwStats?.medianMs,
                             internetReachable: reachable, internetRTTms: Stats.median(inet.compactMap(\.medianMs)),
                             internetLossPercent: inet.isEmpty ? nil : Stats.mean(inet.map(\.lossPercent)),
                             dnsOK: dns?.success, dnsMs: dns?.durationMs)
        healthSamples.append(s)
        try? store?.save(s, kind: .healthSample, id: s.id.uuidString, timestamp: s.timestamp, network: networkName)
        switch healthDetector.ingest(s) {
        case .started(let o):
            record(NetworkEvent(timestamp: o.start, kind: .outageStart, message: o.kind.rawValue))
            if settings.notifyDisconnects { NotificationsService.shared.notify(title: "Coupure détectée", body: o.kind.rawValue) }
        case .ended(let o):
            record(NetworkEvent(kind: .outageEnd, message: "Fin de coupure (\(Int(o.duration ?? 0)) s)"))
        case .none: break
        }
        if s.dnsOK == false { record(NetworkEvent(kind: .dnsFailure, message: "Échec de résolution via \(resolver ?? "?")")) }
    }

    /// One Bufferbloat Lab trial: idle probes, then probes during download-only and upload-only loads.
    func runBufferbloatTrial(target: String, label: String) async throws -> BufferbloatTrial {
        var caps = speedCaps
        if caps == nil { caps = await speedService.capabilities() }
        guard let caps else { throw CommandError.toolNotFound(.networkQuality) }
        guard caps.available else { throw CommandError.toolNotFound(.networkQuality) }
        runningTest = RunningTest(mode: .bufferbloat, started: Date(), phase: "Latence au repos")
        defer { runningTest = nil }
        let idle = try await latencyService.ping(target, count: 25, interval: 0.2)
        func loaded(_ opts: SpeedTestOptions, phase: String) async throws -> (LatencyStats, SpeedTestResult?) {
            runningTest?.phase = phase
            let box = StopFlag()
            let latency = latencyService
            async let samples = latency.pingContinuously(target, chunk: 5, interval: 0.2) { box.isSet }
            let result = try? await speedService.run(opts, vpnActive: connection?.vpnActive ?? false,
                                                     proxyActive: connection?.proxy?.isActive ?? false, networkName: networkName)
            box.set()
            let s = await samples
            return (LatencyStats(target: target, sent: max(s.count, 1), received: s.count, samplesMs: s, method: "ICMP pendant charge"), result)
        }
        let reduced = settings.reducedDataMode ? 10 : nil
        let (dl, dlRes) = try await loaded(SpeedTestOptions(mode: .bufferbloat, downloadOnly: true, maxRuntimeSeconds: reduced), phase: "Charge descendante")
        let (ul, ulRes) = try await loaded(SpeedTestOptions(mode: .bufferbloat, uploadOnly: true, maxRuntimeSeconds: reduced), phase: "Charge montante")
        let trial = BufferbloatTrial(target: target, idleMs: idle.samplesMs, downloadLoadedMs: dl.samplesMs, uploadLoadedMs: ul.samplesMs,
                                     idleLossPercent: idle.lossPercent, downloadLossPercent: dl.lossPercent, uploadLossPercent: ul.lossPercent,
                                     downloadBps: dlRes?.downloadBps, uploadBps: ulRes?.uploadBps, label: label)
        bufferbloatTrials.append(trial)
        try? store?.save(trial, kind: .bufferbloatReport, id: trial.id.uuidString, timestamp: trial.timestamp, network: networkName)
        return trial
    }

    func saveAgents() { try? store?.save(agents, kind: .multipointRun, id: "agents") }
    func saveISP() { try? store?.save(ispProfile, kind: .ispProfile, id: "isp") }
    func saveHeatmap(_ p: HeatmapProject) {
        if let i = heatmapProjects.firstIndex(where: { $0.id == p.id }) { heatmapProjects[i] = p } else { heatmapProjects.append(p) }
        try? store?.save(p, kind: .heatmapProject, id: p.id.uuidString, timestamp: p.created)
    }

    var ethernetInterfaceNames: Set<String> {
        Set((connection?.interfaces ?? []).filter { $0.kind == .ethernet }.map(\.bsdName))
    }

    var outagesAll: [Outage] {
        var o = healthDetector.outages
        if let c = healthDetector.current { o.append(c) }
        return o
    }
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

// MARK: - Diagnostics wizard

struct WizardStep: Identifiable, Equatable {
    var id: Int
    var title: String
    var state: State = .pending
    var summary: String = ""
    enum State: Equatable { case pending, running, done, skipped, failed }
}

extension AppModel {
    static func wizardSteps() -> [WizardStep] {
        ["Diagnostic local", "Diagnostic Wi-Fi", "Diagnostic passerelle", "Diagnostic Internet", "Diagnostic DNS",
         "Speedtest complet", "Local contre WAN", "Analyse finale"].enumerated().map { WizardStep(id: $0.offset + 1, title: $0.element) }
    }

    func runDiagnostics(includeSpeedTest: Bool, compareResolvers: Bool, update: @escaping (WizardStep) -> Void) async {
        var steps = Self.wizardSteps()
        func set(_ i: Int, _ st: WizardStep.State, _ s: String) { steps[i].state = st; steps[i].summary = s; update(steps[i]) }

        set(0, .running, "")
        await refreshConnection()
        let c = connection
        set(0, .done, c.map { "\($0.primaryInterface?.bsdName ?? "aucune interface") — passerelle \($0.defaultGatewayIPv4 ?? "absente")\($0.vpnActive ? " — VPN actif" : "")\(($0.proxy?.isActive ?? false) ? " — proxy" : "")" } ?? "Indisponible")

        set(1, .running, "")
        refreshWiFi()
        if c?.primaryInterface?.kind == .wifi, let w = wifi {
            set(1, .done, "RSSI \(w.rssi.value.map { "\($0) dBm" } ?? "—"), SNR \(w.snr.value.map { "\($0) dB" } ?? "—"), canal \(w.channel.value.map(String.init) ?? "—") (\(w.band.value?.rawValue ?? "—"))")
        } else { set(1, .skipped, "Pas de liaison Wi-Fi active") }

        set(2, .running, "")
        if let gw = c?.defaultGatewayIPv4, let g = try? await latencyService.ping(gw, count: 20, interval: 0.2) {
            gatewayLatency = g
            set(2, .done, "Médiane \(Units.ms(g.medianMs)), gigue \(Units.ms(g.jitterMs)), pertes \(String(format: "%.1f", g.lossPercent)) %")
        } else { set(2, .failed, "Passerelle non mesurable") }

        set(3, .running, "")
        await measureLatencyFull()
        var trace: [TracerouteHop] = []
        if let target = settings.latencyTargets.first, externalLatency.contains(where: { $0.lossPercent > 1 || ($0.medianMs ?? 0) > 80 }) {
            trace = (try? await traceService.trace(target)) ?? []
        }
        set(3, .done, externalLatency.map { "\($0.target) \(Units.ms($0.medianMs)) / \(String(format: "%.0f", $0.lossPercent)) %" }.joined(separator: " · ") + (trace.isEmpty ? "" : " · tracé \(trace.count) sauts"))

        set(4, .running, "")
        await testDNS()
        if compareResolvers {
            let bench = await dnsService.benchmark(resolvers: DNSDiagnosticsService.publicResolvers, names: ["apple.com", "wikipedia.org"], rounds: 2)
            set(4, .done, "Configurés : \(dnsResults.filter(\.success).count)/\(dnsResults.count) OK · meilleur public : \(bench.first.map { "\($0.label) \(Units.ms($0.medianMs))" } ?? "—")")
        } else {
            set(4, .done, "\(dnsResults.filter(\.success).count)/\(dnsResults.count) requêtes réussies, médiane \(Units.ms(Stats.median(dnsResults.compactMap(\.durationMs))))")
        }

        if includeSpeedTest {
            set(5, .running, "")
            await runSpeedTest(.full)
            set(5, latestTest == nil ? .failed : .done, latestTest.map { "↓ \($0.downloadBps.map(Units.bitRate) ?? "—") ↑ \($0.uploadBps.map(Units.bitRate) ?? "—")" } ?? (lastTestError ?? "Échec"))
        } else { set(5, .skipped, "Non demandé (consomme des données)") }

        set(6, .running, "")
        let eth = speedTests.filter { $0.succeeded && ethernetInterfaceNames.contains($0.interfaceName ?? "") }
        let lan = speedTests.filter { $0.mode == .lan && $0.succeeded }.last
        var parts: [String] = []
        if let e = Stats.median(eth.compactMap(\.downloadBps)) { parts.append("Ethernet médian \(Units.bitRate(e))") } else { parts.append("aucun test Ethernet") }
        if let tx = wifi?.txRateMbps.value { parts.append(String(format: "liaison Wi-Fi %.0f Mbit/s", tx)) }
        if let l = lan?.downloadBps { parts.append("LAN \(Units.bitRate(l))") } else { parts.append("aucun serveur LAN") }
        set(6, .done, parts.joined(separator: " · "))

        set(7, .running, "")
        let report = DiagnosticsEngine.analyze(diagnosticInput(traceroute: trace))
        diagnostic = report
        try? store?.save(report, kind: .diagnosticReport, timestamp: report.timestamp, network: networkName)
        set(7, .done, "\(report.hypotheses.count) hypothèse(s)")
    }

    func diagnosticInput(traceroute: [TracerouteHop] = []) -> DiagnosticInput {
        let dayAgo = Date().addingTimeInterval(-86400)
        let ev = events.filter { $0.timestamp >= dayAgo }
        let lan = speedTests.filter { $0.mode == .lan && $0.succeeded }.last?.downloadBps
        return DiagnosticInput(connection: connection, wifi: wifi, rssiHistory: rssiHistory.map(\.v),
                               bssidChanges24h: ev.filter { $0.kind == .bssidChanged }.count, neighbors: neighbors,
                               gatewayLatency: gatewayLatency, externalLatency: externalLatency, dnsResults: dnsResults,
                               speedTests: speedTests.filter { $0.timestamp >= Date().addingTimeInterval(-7 * 86400) },
                               lanThroughputBps: lan, events24h: ev, traceroute: traceroute, wan: router.wan, routerClients: router.clients,
                               contractedDownBps: ispProfile.advertisedDownBps, contractedUpBps: ispProfile.advertisedUpBps,
                               backgroundTrafficBps: backgroundTrafficBps())
    }

    var qualityScore: QualityScore {
        let sec = SecurityAuditor.audit(securityInput).score
        return QualityScorer.compute(ScoringInput(wifi: wifi, isWired: isWired, rssiHistory: rssiHistory.suffix(200).map(\.v),
                                                  latestSpeedTest: latestTest, contractedDownBps: ispProfile.advertisedDownBps,
                                                  gatewayLatency: gatewayLatency, internetLatency: externalLatency.first,
                                                  dnsResults: dnsResults,
                                                  disconnectsLast24h: Date().timeIntervalSince(started) > 86400 || !events.isEmpty
                                                    ? events.filter { $0.kind == .connectivityLost && $0.timestamp > Date().addingTimeInterval(-86400) }.count : nil,
                                                  securityScore: sec))
    }

    var securityInput: SecurityAuditInput {
        SecurityAuditInput(currentWiFiSecurity: wifi?.security.value, routerWiFi: router.wifi, routerInfo: router.info,
                           devices: inventory.devices, events: events, connection: connection)
    }
}
#endif
