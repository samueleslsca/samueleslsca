import Foundation

// MARK: - Interfaces, routes, DNS, proxy (NetworkInterfaceService)

public protocol NetworkInterfaceServicing: Sendable {
    func snapshot() async -> ConnectionSnapshot
}

public struct NetworkInterfaceService: NetworkInterfaceServicing {
    let runner: CommandRunning
    public init(runner: CommandRunning = ProcessCommandRunner.shared) { self.runner = runner }

    public func snapshot() async -> ConnectionSnapshot {
        async let portsOut = try? runner.run(.networksetup, ["-listallhardwareports"], timeout: 5).stdout
        async let ifOut = try? runner.run(.ifconfig, ["-a"], timeout: 5).stdout
        async let routesOut = try? runner.run(.netstat, ["-rn"], timeout: 5).stdout
        async let dnsOut = try? runner.run(.scutil, ["--dns"], timeout: 5).stdout
        async let proxyOut = try? runner.run(.scutil, ["--proxy"], timeout: 5).stdout
        let ports = HardwarePortsParser.parse(await portsOut ?? "")
        let ifaces = IfconfigParser.parse(await ifOut ?? "", hardwarePorts: ports)
        let routes = RouteTableParser.parse(await routesOut ?? "")
        let dns = await dnsOut.map(ScutilParser.parseDNS)
        let proxy = await proxyOut.map(ScutilParser.parseProxy)
        return Self.assemble(interfaces: ifaces, routes: routes, dns: dns, proxy: proxy)
    }

    /// Pure assembly logic (unit-tested).
    public static func assemble(interfaces: [NetworkInterfaceInfo], routes: [RouteEntry], dns: DNSConfiguration?,
                                proxy: ProxyStatus?, now: Date = Date()) -> ConnectionSnapshot {
        let gw4 = RouteTableParser.defaultGateway(routes, ipv6: false)
        let gw6 = RouteTableParser.defaultGateway(routes, ipv6: true)
        let byName = Dictionary(interfaces.map { ($0.bsdName, $0) }, uniquingKeysWith: { a, _ in a })
        let vpn = interfaces.filter { $0.kind == .vpn && $0.isUp && (!$0.ipv4.isEmpty || !$0.globalIPv6.isEmpty) }
        // Primary: interface carrying the default IPv4 route; if it is a tunnel, prefer the physical interface for display.
        var primary = gw4.flatMap { byName[$0.interface] } ?? gw6.flatMap { byName[$0.interface] }
        let vpnDefault = primary?.kind == .vpn
        if vpnDefault {
            primary = interfaces.first { ($0.kind == .wifi || $0.kind == .ethernet) && $0.isRunning && !$0.ipv4.isEmpty } ?? primary
        }
        let connected = primary != nil && (primary?.isRunning ?? false)
        let physicalGW = RouteTableParser.defaultGateway(routes, ipv6: false, preferredInterface: primary?.bsdName)
        let gwIP = (vpnDefault ? physicalGW?.gateway : gw4?.gateway).flatMap { IPv4.parse($0) != nil ? $0 : nil }
        return ConnectionSnapshot(timestamp: now, isConnected: connected, primaryInterface: primary, interfaces: interfaces,
                                  defaultGatewayIPv4: gwIP, defaultGatewayIPv6: gw6?.gateway, dns: dns,
                                  vpnActive: !vpn.isEmpty && (vpnDefault || routes.contains { $0.interface.hasPrefix("utun") && !$0.isIPv6 && $0.flags.contains("G") }),
                                  vpnInterfaces: vpn.map(\.bsdName), proxy: proxy)
    }
}

// MARK: - Latency (LatencyMonitoringService)

public protocol LatencyMeasuring: Sendable {
    func ping(_ host: String, count: Int, interval: Double, timeoutMs: Int) async throws -> LatencyStats
}

public struct LatencyMonitoringService: LatencyMeasuring {
    let runner: CommandRunning
    public init(runner: CommandRunning = ProcessCommandRunner.shared) { self.runner = runner }

    public func ping(_ host: String, count: Int = 10, interval: Double = 0.2, timeoutMs: Int = 1000) async throws -> LatencyStats {
        guard ArgumentValidator.isValidHost(host) else { throw CommandError.invalidArgument(host) }
        let isV6 = host.contains(":")
        let tool: SystemTool = isV6 && runner.isAvailable(.ping6) ? .ping6 : .ping
        var args = ["-n", "-c", "\(count)", "-i", String(format: "%.1f", max(0.2, interval))]
        if tool == .ping { args += ["-W", "\(timeoutMs)"] }
        args.append(host)
        let budget = Double(count) * max(interval, 0.2) + Double(timeoutMs) / 1000 + 5
        let r = try await runner.run(tool, args, timeout: budget)
        // ping exits 2 when no reply was received: still a valid (100 % loss) measurement.
        guard let p = PingParser.parse(r.stdout) else {
            if r.exitCode != 0 { throw CommandError.nonZeroExit(tool, code: r.exitCode, stderr: r.stderr) }
            throw CommandError.launchFailed("sortie ping illisible")
        }
        return LatencyStats(target: host, sent: p.transmitted, received: p.received, samplesMs: p.samplesMs,
                            method: "ICMP echo (\(tool.rawValue)), \(count) paquets")
    }

    /// Splits a long ping into rolling chunks so callers (e.g. Bufferbloat Lab) can sample while a load runs.
    public func pingContinuously(_ host: String, chunk: Int = 5, interval: Double = 0.2,
                                 until shouldStop: @escaping @Sendable () -> Bool) async -> [Double] {
        var all: [Double] = []
        while !shouldStop(), !Task.isCancelled {
            if let s = try? await ping(host, count: chunk, interval: interval) { all += s.samplesMs } else { break }
        }
        return all
    }
}

// MARK: - Speedtest (InternetSpeedTestService)

public struct SpeedTestCapabilities: Sendable, Equatable {
    public var available: Bool
    public var flags: Set<String>
    public var supportsJSON: Bool { flags.contains("-c") }
    public var supportsSequential: Bool { flags.contains("-s") }
    public var supportsInterfaceBinding: Bool { flags.contains("-I") }
    public var supportsMaxRuntime: Bool { flags.contains("-M") }
    public var supportsResponsivenessOnly: Bool { flags.contains("-r") }
}

public struct SpeedTestOptions: Sendable {
    public var mode: SpeedTestMode
    public var sequential: Bool
    public var interface: String?
    public var downloadOnly: Bool
    public var uploadOnly: Bool
    /// Reduced data mode: caps runtime when supported.
    public var maxRuntimeSeconds: Int?

    public init(mode: SpeedTestMode, sequential: Bool = false, interface: String? = nil, downloadOnly: Bool = false,
                uploadOnly: Bool = false, maxRuntimeSeconds: Int? = nil) {
        self.mode = mode; self.sequential = sequential; self.interface = interface; self.downloadOnly = downloadOnly
        self.uploadOnly = uploadOnly; self.maxRuntimeSeconds = maxRuntimeSeconds
    }

    public static func preset(_ mode: SpeedTestMode, reducedData: Bool) -> SpeedTestOptions {
        switch mode {
        case .quick: return SpeedTestOptions(mode: mode, maxRuntimeSeconds: reducedData ? 8 : 12)
        case .full, .videoCall, .streaming: return SpeedTestOptions(mode: mode, sequential: true, maxRuntimeSeconds: reducedData ? 12 : nil)
        case .gaming: return SpeedTestOptions(mode: mode, maxRuntimeSeconds: reducedData ? 8 : nil)
        case .bufferbloat: return SpeedTestOptions(mode: mode, sequential: true, maxRuntimeSeconds: reducedData ? 10 : nil)
        case .lan: return SpeedTestOptions(mode: mode)
        }
    }
}

public struct InternetSpeedTestService: Sendable {
    let runner: CommandRunning
    public init(runner: CommandRunning = ProcessCommandRunner.shared) { self.runner = runner }

    public func capabilities() async -> SpeedTestCapabilities {
        guard runner.isAvailable(.networkQuality) else { return SpeedTestCapabilities(available: false, flags: []) }
        let r = try? await runner.run(.networkQuality, ["-h"], timeout: 5)
        let text = (r?.stdout ?? "") + "\n" + (r?.stderr ?? "")
        var flags = NetworkQualityHelpParser.supportedFlags(text)
        if flags.isEmpty { flags = ["-c"] } // macOS 12 prints minimal help; -c exists since networkQuality's introduction
        return SpeedTestCapabilities(available: true, flags: flags)
    }

    public func arguments(_ o: SpeedTestOptions, caps: SpeedTestCapabilities) -> [String] {
        var a = ["-c"]
        if (o.sequential || o.downloadOnly || o.uploadOnly), caps.supportsSequential { a.append("-s") }
        if o.downloadOnly, caps.flags.contains("-u") { a.append("-u") }
        if o.uploadOnly, caps.flags.contains("-d") { a.append("-d") }
        if let i = o.interface, caps.supportsInterfaceBinding, ArgumentValidator.isValidInterfaceName(i) { a += ["-I", i] }
        if let m = o.maxRuntimeSeconds, caps.supportsMaxRuntime { a += ["-M", "\(m)"] }
        return a
    }

    public func run(_ o: SpeedTestOptions, vpnActive: Bool, proxyActive: Bool, networkName: String?) async throws -> SpeedTestResult {
        let caps = await capabilities()
        guard caps.available else { throw CommandError.toolNotFound(.networkQuality) }
        let args = arguments(o, caps: caps)
        let r = try await runner.run(.networkQuality, args, timeout: Double(o.maxRuntimeSeconds ?? 60) + 60)
        var result = try NetworkQualityParser.parse(r.stdout, mode: o.mode, sequential: args.contains("-s"),
                                                    vpnActive: vpnActive, proxyActive: proxyActive)
        result.networkName = networkName
        return result
    }
}

// MARK: - LAN test (iperf3, user-controlled server)

public struct LANTestService: Sendable {
    let runner: CommandRunning
    public init(runner: CommandRunning = ProcessCommandRunner.shared) { self.runner = runner }
    public var isAvailable: Bool { runner.isAvailable(.iperf3) }

    public func run(server: String, port: Int = 5201, seconds: Int = 8, reverse: Bool, streams: Int = 4) async throws -> IPerf3Parser.Result {
        guard ArgumentValidator.isValidHost(server) else { throw CommandError.invalidArgument(server) }
        var args = ["-c", server, "-p", "\(port)", "-t", "\(seconds)", "-P", "\(min(max(streams, 1), 8))", "-J", "--connect-timeout", "3000"]
        if reverse { args.append("-R") }
        let r = try await runner.run(.iperf3, args, timeout: Double(seconds) + 15)
        return IPerf3Parser.parse(r.stdout)
    }

    public static func asSpeedTest(down: IPerf3Parser.Result?, up: IPerf3Parser.Result?, server: String, interface: String?) -> SpeedTestResult {
        SpeedTestResult(mode: .lan, engine: .iperf3, server: server, interfaceName: interface,
                        downloadBps: down?.receivedBps, uploadBps: up?.receivedBps,
                        error: [down?.error, up?.error].compactMap { $0 }.first)
    }
}

// MARK: - Traceroute

public struct TracerouteService: Sendable {
    let runner: CommandRunning
    public init(runner: CommandRunning = ProcessCommandRunner.shared) { self.runner = runner }
    public func trace(_ host: String, maxHops: Int = 20) async throws -> [TracerouteHop] {
        let r = try await runner.run(.traceroute, ["-n", "-m", "\(maxHops)", "-q", "2", "-w", "2", host], timeout: Double(maxHops) * 4 + 10)
        return TracerouteParser.parse(r.stdout)
    }
}

// MARK: - DNS diagnostics

public struct DNSDiagnosticsService: Sendable {
    let client: DNSClient
    public init(client: DNSClient = DNSClient()) { self.client = client }

    /// Tests the configured resolvers (IPv4 only) with a few common names.
    public func testConfigured(_ resolvers: [String], names: [String] = ["apple.com", "wikipedia.org", "example.com"]) async -> [DNSQueryResult] {
        var out: [DNSQueryResult] = []
        for r in resolvers where IPv4.parse(r) != nil {
            for n in names { out.append(await client.resolve(n, resolver: r)) }
        }
        return out
    }

    public struct BenchmarkRow: Codable, Hashable, Sendable {
        public var resolver: String
        public var label: String
        public var medianMs: Double?
        public var p90Ms: Double?
        public var failures: Int
        public var queries: Int
    }

    public static let publicResolvers: [(String, String)] = [
        ("1.1.1.1", "Cloudflare"), ("9.9.9.9", "Quad9"), ("8.8.8.8", "Google"), ("208.67.222.222", "OpenDNS"),
    ]

    /// Reproducible benchmark: same names, same order, 3 rounds, round-robin across resolvers to spread
    /// time effects. Never changes the system DNS configuration.
    public func benchmark(resolvers: [(String, String)], names: [String], rounds: Int = 3) async -> [BenchmarkRow] {
        var results: [String: [DNSQueryResult]] = [:]
        for _ in 0..<rounds {
            for n in names { for (ip, _) in resolvers { results[ip, default: []].append(await client.resolve(n, resolver: ip)) } }
        }
        return resolvers.map { ip, label in
            let r = results[ip] ?? []
            let t = r.filter(\.success).compactMap(\.durationMs)
            return BenchmarkRow(resolver: ip, label: label, medianMs: Stats.median(t), p90Ms: Stats.percentile(t, 90),
                                failures: r.filter { !$0.success }.count, queries: r.count)
        }.sorted { ($0.medianMs ?? .infinity) < ($1.medianMs ?? .infinity) }
    }
}

// MARK: - Neighbor discovery (ARP/NDP) and authorized active probe

public struct NeighborDiscoveryService: Sendable {
    let runner: CommandRunning
    public init(runner: CommandRunning = ProcessCommandRunner.shared) { self.runner = runner }

    public func readCaches() async -> [DeviceObservation] {
        let now = Date()
        var obs: [DeviceObservation] = []
        if let a = try? await runner.run(.arp, ["-a", "-n"], timeout: 5).stdout {
            obs += NeighborParser.parseARP(a).filter { !$0.isIncomplete && $0.mac != nil && !MACAddress.isMulticast($0.mac!) }
                .map { DeviceObservation(method: .arpCache, timestamp: now, ip: $0.ip, mac: $0.mac, interface: $0.interface) }
        }
        if runner.isAvailable(.ndp), let n = try? await runner.run(.ndp, ["-a", "-n"], timeout: 5).stdout {
            obs += NeighborParser.parseNDP(n).filter { !$0.isIncomplete && $0.mac != nil }
                .map { DeviceObservation(method: .ndpCache, timestamp: now, ipv6: $0.ip, mac: $0.mac, interface: $0.interface) }
        }
        return obs
    }

    public enum ProbeError: Error, LocalizedError, Equatable {
        case notPrivate(String), tooLarge(Int), notLocal(String)
        public var errorDescription: String? {
            switch self {
            case .notPrivate(let s): return "Le sous-réseau \(s) n’est pas un réseau privé : sondage refusé."
            case .tooLarge(let n): return "Sous-réseau trop grand (\(n) hôtes) : limite fixée à 1022 hôtes (/22)."
            case .notLocal(let s): return "Le sous-réseau \(s) n’est pas celui de l’interface active : sondage refusé."
            }
        }
    }

    /// Validates that an active probe is allowed: private range, directly attached, at most /22.
    public static func validateProbe(subnet: IPv4Subnet, localAssignments: [IPv4Assignment]) throws {
        guard IPv4.isPrivate(subnet.network) else { throw ProbeError.notPrivate(subnet.description) }
        guard subnet.prefixLength >= 22 else { throw ProbeError.tooLarge(subnet.hostCount) }
        guard localAssignments.contains(where: { $0.subnet == subnet }) else { throw ProbeError.notLocal(subnet.description) }
    }

    /// Light, rate-limited ICMP sweep (one echo per host, ≤ 16 in flight) to populate the ARP cache,
    /// then re-reads the caches. Only called after explicit user consent.
    public func probe(subnet: IPv4Subnet, localAssignments: [IPv4Assignment], concurrency: Int = 16,
                      progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [DeviceObservation] {
        try Self.validateProbe(subnet: subnet, localAssignments: localAssignments)
        let hosts = subnet.hosts()
        let latency = LatencyMonitoringService(runner: runner)
        var done = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            var it = hosts.makeIterator()
            for _ in 0..<min(concurrency, hosts.count) {
                if let h = it.next() { group.addTask { _ = try? await latency.ping(h, count: 1, interval: 0.2, timeoutMs: 400) } }
            }
            while try await group.next() != nil {
                done += 1; progress?(done, hosts.count)
                try Task.checkCancellation()
                if let h = it.next() { group.addTask { _ = try? await latency.ping(h, count: 1, interval: 0.2, timeoutMs: 400) } }
            }
        }
        return await readCaches().map { var o = $0; if o.method == .arpCache { o.method = .activeProbe }; return o }
    }
}

// MARK: - Per-process traffic (nettop)

public struct ProcessTrafficService: Sendable {
    let runner: CommandRunning
    public init(runner: CommandRunning = ProcessCommandRunner.shared) { self.runner = runner }
    public var isAvailable: Bool { runner.isAvailable(.nettop) }

    public func sample() async throws -> [ProcessTrafficSample] {
        let r = try await runner.run(.nettop, ["-P", "-x", "-L", "1", "-J", "bytes_in,bytes_out"], timeout: 10)
        return NettopParser.parse(r.stdout)
    }

    /// Rates between two cumulative samples. Processes absent from either sample are skipped
    /// (we cannot prove their traffic).
    public static func rates(previous: [ProcessTrafficSample], current: [ProcessTrafficSample], seconds: Double) -> [(process: String, pid: Int?, inBps: Double, outBps: Double)] {
        guard seconds > 0 else { return [] }
        let prev = Dictionary(previous.map { ("\($0.process).\($0.pid ?? -1)", $0) }, uniquingKeysWith: { a, _ in a })
        return current.compactMap { c in
            guard let p = prev["\(c.process).\(c.pid ?? -1)"], c.bytesIn >= p.bytesIn, c.bytesOut >= p.bytesOut else { return nil }
            return (c.process, c.pid, Double(c.bytesIn - p.bytesIn) * 8 / seconds, Double(c.bytesOut - p.bytesOut) * 8 / seconds)
        }.sorted { $0.inBps + $0.outBps > $1.inBps + $1.outBps }
    }
}

// MARK: - Interface counters → throughput (TrafficMonitoringService core)

public struct InterfaceCounters: Codable, Hashable, Sendable {
    public var timestamp: Date
    public var interface: String
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public init(timestamp: Date, interface: String, bytesIn: UInt64, bytesOut: UInt64) {
        self.timestamp = timestamp; self.interface = interface; self.bytesIn = bytesIn; self.bytesOut = bytesOut
    }
}

public struct ThroughputSample: Codable, Hashable, Identifiable, Sendable {
    public var id: Date { timestamp }
    public var timestamp: Date
    public var inBps: Double
    public var outBps: Double
}

public enum ThroughputCalculator {
    /// Rate between two counter readings. Handles 32-bit wrap (counter decreased but previous value fits in 32 bits)
    /// and resets (interface restarted) by returning nil.
    public static func rate(_ a: InterfaceCounters, _ b: InterfaceCounters) -> ThroughputSample? {
        let dt = b.timestamp.timeIntervalSince(a.timestamp)
        guard dt > 0, a.interface == b.interface else { return nil }
        func delta(_ x: UInt64, _ y: UInt64) -> UInt64? {
            if y >= x { return y - x }
            if x <= UInt64(UInt32.max) { return (UInt64(UInt32.max) - x) + y + 1 }
            return nil
        }
        guard let di = delta(a.bytesIn, b.bytesIn), let dout = delta(a.bytesOut, b.bytesOut) else { return nil }
        return ThroughputSample(timestamp: b.timestamp, inBps: Double(di) * 8 / dt, outBps: Double(dout) * 8 / dt)
    }
}

// MARK: - Feasibility matrix (Phase 0 at runtime)

public struct FeasibilityItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String { feature }
    public var feature: String
    public var source: String
    public var status: CheckStatus
    public var note: String
}

public enum FeasibilityAuditor {
    public static func toolMatrix(runner: CommandRunning) -> [FeasibilityItem] {
        let rows: [(String, SystemTool, String)] = [
            ("Test de débit Internet", .networkQuality, "macOS 12+"),
            ("Latence ICMP", .ping, "Sans privilège"),
            ("Tracé de route", .traceroute, ""),
            ("Table de routage", .netstat, ""),
            ("Cache ARP", .arp, ""),
            ("Voisins IPv6", .ndp, ""),
            ("Configuration DNS/proxy", .scutil, ""),
            ("Ports matériels", .networksetup, "Lecture seule"),
            ("Interfaces", .ifconfig, ""),
            ("Trafic par processus", .nettop, "Compteurs cumulés par processus"),
            ("Profil matériel (USB, Thunderbolt, Bluetooth)", .systemProfiler, ""),
            ("Test LAN", .iperf3, "Installé par l’utilisateur (ex. brew install iperf3) — optionnel"),
        ]
        return rows.map { f, t, n in
            FeasibilityItem(feature: f, source: t.rawValue, status: runner.isAvailable(t) ? .verified : .unavailable,
                            note: runner.isAvailable(t) ? n : "Outil absent" + (n.isEmpty ? "" : " — \(n)"))
        }
    }
}
