#if os(macOS)
import SwiftUI
import AppKit
import OSLog
import NetScopeCore
import NetScopeSystem

let log = Logger(subsystem: "fr.netscope.pro", category: "app")

struct AppSettings: Codable, Equatable {
    var allowExternalIPLookup = false
    var reducedDataMode = false
    var privacyMode = false
    var notifyNewDevice = true
    var notifyGatewayChange = true
    var notifyDNSChange = true
    var notifyDisconnects = true
    var notifyPerformanceDrop = false
    var healthMonitorEnabled = false
    var healthIntervalSeconds: Double = 60
    var lowPowerMonitoring = false
    var scheduledTestsEnabled = false
    var scheduledIntervalHours: Double = 6
    var scheduledMaxPerDay = 4
    var aiAssistantEnabled = false
    var retentionDays = 90
    var latencyTargets = ["1.1.1.1", "9.9.9.9"]
    var gamingTargets: [String] = []
    var lanServer = ""
    var acknowledgedDataUsage = false
    var acknowledgedActiveProbe = false
}

struct TimedValue: Identifiable, Hashable {
    var id: Date { t }
    var t: Date
    var v: Double
}

struct RunningTest: Equatable {
    var mode: SpeedTestMode
    var started: Date
    var phase: String
    var live: [ThroughputSample] = []
}

@MainActor
final class AppModel: ObservableObject {
    // MARK: Services
    let runner = ProcessCommandRunner.shared
    lazy var interfaceService = NetworkInterfaceService(runner: runner)
    lazy var latencyService = LatencyMonitoringService(runner: runner)
    lazy var speedService = InternetSpeedTestService(runner: runner)
    lazy var lanService = LANTestService(runner: runner)
    lazy var traceService = TracerouteService(runner: runner)
    lazy var dnsService = DNSDiagnosticsService()
    lazy var neighborService = NeighborDiscoveryService(runner: runner)
    lazy var processTraffic = ProcessTrafficService(runner: runner)
    lazy var peripheralService = LocalPeripheralService(runner: runner)
    let wifiService = WiFiDiagnosticsService.shared
    let pathMonitor = PathMonitorService()
    let secrets = KeychainSecretStore()
    lazy var agentClient = AgentClient(secrets: secrets)
    lazy var aiClient = ClaudeAssistantClient(secrets: secrets)
    let facts = SystemFacts.read()
    private(set) var store: HistoryStore?

    // MARK: State
    @Published var storeError: String?
    @Published var connection: ConnectionSnapshot?
    @Published var pathStatus: PathStatus?
    @Published var wifi: WiFiSnapshot?
    @Published var rssiHistory: [TimedValue] = []
    @Published var neighbors: [WiFiNeighbor] = []
    @Published var neighborsScannedAt: Date?
    @Published var scanError: String?
    @Published var gatewayLatency: LatencyStats?
    @Published var externalLatency: [LatencyStats] = []
    @Published var dnsResults: [DNSQueryResult] = []
    @Published var speedTests: [SpeedTestResult] = []
    @Published var speedCaps: SpeedTestCapabilities?
    @Published var runningTest: RunningTest?
    @Published var lastTestError: String?
    @Published var inventory = DeviceInventory()
    @Published var discovering = false
    @Published var discoveryProgress: (Int, Int)?
    @Published var peripherals: [LocalPeripheral] = []
    @Published var events: [NetworkEvent] = []
    @Published var traffic: [ThroughputSample] = []
    @Published var sessionBytesIn: Double = 0
    @Published var sessionBytesOut: Double = 0
    @Published var oui = OUIDatabase()
    @Published var settings: AppSettings { didSet { saveSettings(); applyBackgroundTasks() } }
    @Published var diagnostic: DiagnosticReport?
    @Published var feasibility: [FeasibilityItem] = []
    @Published var publicIP: Sourced<String> = .unavailable("Vérification externe non autorisée (Réglages)")

    private var counterBaseline: [String: InterfaceCounters] = [:]
    private var lastCounters: [String: InterfaceCounters] = [:]
    private var loops: [Task<Void, Never>] = []
    private var healthTask: Task<Void, Never>?
    private var scheduleTask: Task<Void, Never>?
    var testTask: Task<Void, Never>?
    var baselines: [String: NetworkBaseline] = [:]
    let started = Date()

    init() {
        if let d = UserDefaults.standard.data(forKey: "settings"), let s = try? JSONDecoder().decode(AppSettings.self, from: d) {
            settings = s
        } else { settings = AppSettings() }
        do {
            let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("NetScopePro", isDirectory: true)
            store = try HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
            if let aside = store?.recoveredFromCorruption {
                storeError = "L’historique était corrompu : il a été mis de côté (\(aside.lastPathComponent)) et un nouvel historique a été créé."
            }
        } catch {
            storeError = "Historique indisponible : \(error.localizedDescription). L’application fonctionne sans enregistrement."
        }
        loadPersisted()
        feasibility = FeasibilityAuditor.toolMatrix(runner: runner)
    }

    // MARK: Lifecycle

    func start() {
        guard loops.isEmpty else { return }
        pathMonitor.start { [weak self] status in
            guard let self else { return }
            let wasSatisfied = self.pathStatus?.satisfied
            self.pathStatus = status
            if let was = wasSatisfied, was != status.satisfied {
                self.record(NetworkEvent(kind: status.satisfied ? .connectivityRestored : .connectivityLost,
                                         message: status.satisfied ? "Connectivité rétablie (\(status.interfaceTypes.joined(separator: ", ")))" : "Plus de chemin réseau disponible"))
                if !status.satisfied, self.settings.notifyDisconnects {
                    NotificationsService.shared.notify(title: "Connexion perdue", body: "Aucun chemin réseau disponible.")
                }
            }
            Task { await self.refreshConnection() }
        }
        wifiService.startMonitoring { [weak self] kind, iface in
            guard let self else { return }
            self.record(NetworkEvent(kind: kind, message: "\(kind.label) sur \(iface)"))
            self.refreshWiFi()
        }
        // Cadences: Wi-Fi 3 s (CoreWLAN, cheap), counters 1 s (sysctl, cheap), connection 30 s (+ on path change),
        // gateway latency 60 s (3 ICMP packets), passive ARP 5 min. No heavy test runs in the background.
        loops.append(Task { [weak self] in while !Task.isCancelled { self?.refreshWiFi(); try? await Task.sleep(nanoseconds: 3_000_000_000) } })
        loops.append(Task { [weak self] in while !Task.isCancelled { self?.sampleCounters(); try? await Task.sleep(nanoseconds: 1_000_000_000) } })
        loops.append(Task { [weak self] in while !Task.isCancelled { await self?.refreshConnection(); try? await Task.sleep(nanoseconds: 30_000_000_000) } })
        loops.append(Task { [weak self] in while !Task.isCancelled { await self?.measureGateway(); try? await Task.sleep(nanoseconds: 60_000_000_000) } })
        loops.append(Task { [weak self] in while !Task.isCancelled { try? await Task.sleep(nanoseconds: 300_000_000_000); await self?.passiveDiscovery() } })
        Task { speedCaps = await speedService.capabilities() }
        Task { _ = await NotificationsService.shared.requestAuthorization() }
        applyBackgroundTasks()
        purgeOldData()
    }

    func stop() {
        loops.forEach { $0.cancel() }; loops.removeAll()
        healthTask?.cancel(); scheduleTask?.cancel(); testTask?.cancel()
        pathMonitor.stop(); wifiService.stopMonitoring()
    }

    // MARK: Connection & Wi-Fi

    func refreshConnection() async {
        let snap = await interfaceService.snapshot()
        var s = snap
        s.publicIP = publicIP
        let previous = connection
        connection = s
        if let p = previous, p.primaryInterface?.bsdName != s.primaryInterface?.bsdName {
            record(NetworkEvent(kind: .interfaceChanged, message: "Interface principale : \(p.primaryInterface?.bsdName ?? "aucune") → \(s.primaryInterface?.bsdName ?? "aucune")"))
        }
        if let p = previous, p.vpnActive != s.vpnActive {
            record(NetworkEvent(kind: .vpnStateChanged, message: s.vpnActive ? "VPN activé (\(s.vpnInterfaces.joined(separator: ", ")))" : "VPN désactivé"))
        }
        updateBaseline()
        if settings.allowExternalIPLookup, publicIP.value == nil || Date().timeIntervalSince(publicIP.timestamp) > 3600 {
            await lookupPublicIP()
        }
    }

    func refreshWiFi() {
        guard let w = wifiService.snapshot() else { wifi = nil; return }
        if let old = wifi, let ob = old.bssid.value, let nb = w.bssid.value, ob != nb {
            record(NetworkEvent(kind: .bssidChanged, message: "Point d’accès : \(ob) → \(nb)"))
        }
        wifi = w
        if let r = w.rssi.value {
            rssiHistory.append(TimedValue(t: w.timestamp, v: Double(r)))
            if rssiHistory.count > 1200 { rssiHistory.removeFirst(rssiHistory.count - 1200) }
        }
    }

    var isWired: Bool { connection?.primaryInterface?.kind == .ethernet }
    var networkName: String? { wifi?.ssid.value ?? connection?.primaryInterface.map { "\($0.kind.label) \($0.bsdName)" } }

    func scanNeighbors() {
        if let last = neighborsScannedAt, Date().timeIntervalSince(last) < 30 {
            scanError = "Patientez 30 s entre deux scans (un scan actif perturbe brièvement la liaison)."
            return
        }
        do {
            neighbors = try wifiService.scanNeighbors()
            neighborsScannedAt = Date(); scanError = nil
        } catch { scanError = "Scan impossible : \(error.localizedDescription)" }
    }

    private func lookupPublicIP() async {
        // Only with explicit consent (Réglages → Vérification de l’IP publique). Cloudflare trace endpoint.
        guard let url = URL(string: "https://1.1.1.1/cdn-cgi/trace") else { return }
        do {
            let (d, _) = try await URLSession.shared.data(from: url)
            let ip = String(decoding: d, as: UTF8.self).split(separator: "\n").first { $0.hasPrefix("ip=") }.map { String($0.dropFirst(3)) }
            publicIP = Sourced(ip, .measured(method: "Requête externe (Cloudflare /cdn-cgi/trace)"))
        } catch { publicIP = .unavailable("Échec de la vérification externe : \(error.localizedDescription)") }
    }

    // MARK: Latency

    func measureGateway() async {
        guard let gw = connection?.defaultGatewayIPv4 else { gatewayLatency = nil; return }
        gatewayLatency = try? await latencyService.ping(gw, count: 3, interval: 0.3)
    }

    func measureLatencyFull() async {
        if let gw = connection?.defaultGatewayIPv4 { gatewayLatency = try? await latencyService.ping(gw, count: 20, interval: 0.2) }
        var results: [LatencyStats] = []
        for t in settings.latencyTargets where ArgumentValidator.isValidHost(t) {
            if let r = try? await latencyService.ping(t, count: 20, interval: 0.2) { results.append(r) }
            else { results.append(LatencyStats(target: t, sent: 20, received: 0, samplesMs: [], method: "ICMP (échec)")) }
        }
        externalLatency = results
    }

    func testDNS() async {
        let resolvers = connection?.dns?.primaryNameservers.filter { IPv4.parse($0) != nil } ?? []
        dnsResults = await dnsService.testConfigured(resolvers)
    }

    // MARK: Traffic counters

    private func sampleCounters() {
        let all = InterfaceCountersReader.read()
        guard let iface = connection?.primaryInterface?.bsdName ?? all.first(where: { $0.interface.hasPrefix("en") })?.interface,
              let cur = all.first(where: { $0.interface == iface }) else { return }
        if let prev = lastCounters[iface], let s = ThroughputCalculator.rate(prev, cur) {
            traffic.append(s)
            if traffic.count > 600 { traffic.removeFirst(traffic.count - 600) }
            sessionBytesIn += s.inBps / 8 * cur.timestamp.timeIntervalSince(prev.timestamp)
            sessionBytesOut += s.outBps / 8 * cur.timestamp.timeIntervalSince(prev.timestamp)
            if runningTest != nil { runningTest?.live.append(s) }
        }
        lastCounters[iface] = cur
    }

    /// Mean interface throughput over the last `seconds` — used to warn that large transfers may bias a test.
    func backgroundTrafficBps(seconds: Double = 10) -> Double? {
        let cutoff = Date().addingTimeInterval(-seconds)
        let recent = traffic.filter { $0.timestamp >= cutoff }
        guard !recent.isEmpty else { return nil }
        return recent.map { $0.inBps + $0.outBps }.reduce(0, +) / Double(recent.count)
    }

    // MARK: Events, persistence, privacy

    func record(_ e: NetworkEvent) {
        events.insert(e, at: 0)
        if events.count > 500 { events.removeLast(events.count - 500) }
        try? store?.save(e, kind: .event, id: e.id.uuidString, timestamp: e.timestamp, network: networkName)
    }

    func redact(_ s: String) -> String {
        PrivacyRedactor(enabled: settings.privacyMode, ssids: [wifi?.ssid.value].compactMap { $0 }).redact(s)
    }

    var redactor: PrivacyRedactor { PrivacyRedactor(enabled: settings.privacyMode, ssids: [wifi?.ssid.value].compactMap { $0 }) }

    private func loadPersisted() {
        guard let store else { return }
        speedTests = (try? store.load(SpeedTestResult.self, kind: .speedTest, from: Date().addingTimeInterval(-365 * 86400)).items) ?? []
        events = ((try? store.load(NetworkEvent.self, kind: .event, from: Date().addingTimeInterval(-30 * 86400)).items) ?? []).reversed()
        if let inv = try? store.loadOne(DeviceInventory.self, kind: .deviceInventory, id: "inventory") { inventory = inv }
        if let b = try? store.loadOne([String: NetworkBaseline].self, kind: .networkProfile, id: "baselines") { baselines = b }
        loadLabs()
    }

    func saveInventory() { try? store?.save(inventory, kind: .deviceInventory, id: "inventory") }

    private func saveSettings() {
        if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "settings") }
    }

    private func purgeOldData() {
        guard let store else { return }
        let cutoff = Date().addingTimeInterval(-Double(settings.retentionDays) * 86400)
        for k in [RecordKind.event, .healthSample, .wifiSample] { _ = try? store.purge(kind: k, olderThan: cutoff) }
    }

    func eraseHistory() {
        try? store?.eraseAll()
        speedTests = []; events = []; healthSamples = []; inventory = DeviceInventory(); baselines = [:]
        bufferbloatTrials = []; heatmapProjects = []; auditLog = []
    }

    private func updateBaseline() {
        guard let c = connection, let key = networkName else { return }
        var mac: String?
        if let gw = c.defaultGatewayIPv4 { mac = inventory.devices.first { $0.ipv4 == gw }?.mac }
        let cur = NetworkBaseline(networkKey: key, gatewayIP: c.defaultGatewayIPv4, gatewayMAC: mac,
                                  dnsServers: c.dns?.primaryNameservers ?? [], knownBSSIDs: [wifi?.bssid.value].compactMap { $0 }, updated: Date())
        let changes = ChangeDetector.diff(baseline: baselines[key], current: cur)
        for e in changes {
            record(e)
            if e.kind == .gatewayChanged, settings.notifyGatewayChange { NotificationsService.shared.notify(title: "Passerelle modifiée", body: e.message) }
            if e.kind == .dnsChanged, settings.notifyDNSChange { NotificationsService.shared.notify(title: "DNS modifiés", body: e.message) }
        }
        if baselines[key] == nil || !changes.isEmpty || baselines[key]?.gatewayMAC == nil {
            baselines[key] = cur
            try? store?.save(baselines, kind: .networkProfile, id: "baselines")
        }
    }

    // MARK: Background features (opt-in)

    @Published var healthSamples: [HealthSample] = []
    @Published var healthDetector = OutageDetector(threshold: 2)
    @Published var bufferbloatTrials: [BufferbloatTrial] = []
    @Published var heatmapProjects: [HeatmapProject] = []
    @Published var ispProfile = ISPProfile()
    @Published var agents: [AgentPairing] = []
    @Published var auditLog: [AdminAuditEntry] = []
    @Published var router = RouterState()

    func applyBackgroundTasks() {
        healthTask?.cancel(); healthTask = nil
        if settings.healthMonitorEnabled {
            healthTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.healthCheck()
                    let interval = (self?.settings.lowPowerMonitoring ?? false) ? 300 : (self?.settings.healthIntervalSeconds ?? 60)
                    try? await Task.sleep(nanoseconds: UInt64(max(15, interval) * 1_000_000_000))
                }
            }
        }
        scheduleTask?.cancel(); scheduleTask = nil
        if settings.scheduledTestsEnabled, settings.acknowledgedDataUsage {
            scheduleTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 600_000_000_000)
                    await self?.maybeRunScheduledTest()
                }
            }
        }
    }

    private func maybeRunScheduledTest() async {
        guard runningTest == nil else { return }
        let scheduled = speedTests.filter { $0.mode == .quick && $0.networkName != nil }
        let today = scheduled.filter { Calendar.current.isDateInToday($0.timestamp) }.count
        let last = scheduled.map(\.timestamp).max() ?? .distantPast
        guard today < settings.scheduledMaxPerDay, Date().timeIntervalSince(last) >= settings.scheduledIntervalHours * 3600 else { return }
        if let bg = backgroundTrafficBps(), bg > 5e6 { return } // don't measure on top of an active transfer
        await runSpeedTest(.quick, forceReduced: true)
    }
}

struct RouterState {
    var probes: [RouterProbeResult] = []
    var detecting = false
    var adapterID: String?
    var freebox: FreeboxAdapter?
    var openwrt: OpenWrtAdapter?
    var info: RouterInfo?
    var clients: [RouterClient] = []
    var wan: WANStatus?
    var wifi: RouterWiFiReport?
    var rules: [AccessRule] = []
    var capabilities: RouterCapabilities = []
    var status: String?
    var error: String?
    var lastRefresh: Date?
}
#endif
