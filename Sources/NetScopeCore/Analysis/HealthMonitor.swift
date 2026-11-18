import Foundation

/// One lightweight periodic check of the Internet Health Monitor (no throughput test).
public struct HealthSample: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var interface: String?
    public var networkName: String?
    public var gatewayReachable: Bool?
    public var gatewayRTTms: Double?
    public var internetReachable: Bool
    public var internetRTTms: Double?
    public var internetLossPercent: Double?
    public var dnsOK: Bool?
    public var dnsMs: Double?

    public init(id: UUID = UUID(), timestamp: Date = Date(), interface: String?, networkName: String? = nil,
                gatewayReachable: Bool?, gatewayRTTms: Double?, internetReachable: Bool, internetRTTms: Double?,
                internetLossPercent: Double?, dnsOK: Bool?, dnsMs: Double?) {
        self.id = id; self.timestamp = timestamp; self.interface = interface; self.networkName = networkName
        self.gatewayReachable = gatewayReachable; self.gatewayRTTms = gatewayRTTms; self.internetReachable = internetReachable
        self.internetRTTms = internetRTTms; self.internetLossPercent = internetLossPercent; self.dnsOK = dnsOK; self.dnsMs = dnsMs
    }
}

public enum OutageKind: String, Codable, Sendable {
    case local = "Coupure locale (passerelle injoignable)"
    case internet = "Coupure Internet (passerelle joignable)"
    case dnsOnly = "Défaillance DNS"
    case unknown = "Coupure (origine indéterminée)"
}

public struct Outage: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var start: Date
    public var end: Date?
    public var kind: OutageKind
    public var interface: String?
    public var duration: TimeInterval? { end.map { $0.timeIntervalSince(start) } }
}

public struct HealthMonitorConfig: Codable, Hashable, Sendable {
    public var intervalSeconds: Double
    public var lowPowerIntervalSeconds: Double
    public var consecutiveFailuresForOutage: Int
    public var targets: [String]
    public var dnsProbeName: String

    public static let `default` = HealthMonitorConfig(intervalSeconds: 60, lowPowerIntervalSeconds: 300,
                                                      consecutiveFailuresForOutage: 2,
                                                      targets: ["1.1.1.1", "9.9.9.9"], dnsProbeName: "apple.com")
}

/// Outage state machine. Feed samples in chronological order.
public struct OutageDetector: Codable, Sendable {
    public private(set) var outages: [Outage] = []
    public private(set) var current: Outage?
    private var failureStreak: [HealthSample] = []
    private var dnsFailureStreak: [HealthSample] = []
    public let threshold: Int

    public init(threshold: Int = 2) { self.threshold = max(1, threshold) }

    public enum Transition: Equatable, Sendable { case none, started(Outage), ended(Outage) }

    public mutating func ingest(_ s: HealthSample) -> Transition {
        if s.internetReachable && s.dnsOK != false {
            failureStreak.removeAll(); dnsFailureStreak.removeAll()
            if var o = current {
                o.end = s.timestamp
                outages.append(o); current = nil
                return .ended(o)
            }
            return .none
        }
        if !s.internetReachable {
            failureStreak.append(s)
            if current == nil, failureStreak.count >= threshold, let first = failureStreak.first {
                let kind: OutageKind
                let gw = failureStreak.compactMap(\.gatewayReachable)
                if gw.isEmpty { kind = .unknown } else if gw.allSatisfy({ !$0 }) { kind = .local } else { kind = .internet }
                let o = Outage(id: UUID(), start: first.timestamp, end: nil, kind: kind, interface: s.interface)
                current = o
                return .started(o)
            }
        } else if s.dnsOK == false {
            dnsFailureStreak.append(s)
            if current == nil, dnsFailureStreak.count >= threshold, let first = dnsFailureStreak.first {
                let o = Outage(id: UUID(), start: first.timestamp, end: nil, kind: .dnsOnly, interface: s.interface)
                current = o
                return .started(o)
            }
        }
        return .none
    }
}

public struct HealthReport: Codable, Hashable, Sendable {
    public var periodStart: Date
    public var periodEnd: Date
    public var samples: Int
    public var availabilityPercent: Double?
    public var outages: [Outage]
    public var totalDowntime: TimeInterval
    public var internetLatencyMedianMs: Double?
    public var internetLatencyP95Ms: Double?
    public var gatewayLatencyMedianMs: Double?
    public var meanLossPercent: Double?
    public var dnsFailures: Int
    public var interfaceChanges: Int
    public var trends: [String]
    public var hourlyMedianLatency: [Int: Double]
}

public enum HealthAnalyzer {
    public static func report(samples: [HealthSample], from: Date, to: Date, baseline: [HealthSample] = [],
                              threshold: Int = 2, calendar: Calendar = .current) -> HealthReport {
        let s = samples.filter { $0.timestamp >= from && $0.timestamp <= to }.sorted { $0.timestamp < $1.timestamp }
        var det = OutageDetector(threshold: threshold)
        for x in s { _ = det.ingest(x) }
        var outs = det.outages
        if var c = det.current { c.end = nil; outs.append(c) }
        let downtime = outs.reduce(0.0) { $0 + (($1.end ?? to).timeIntervalSince($1.start)) }
        let span = to.timeIntervalSince(from)
        let avail = s.isEmpty || span <= 0 ? nil : max(0, min(100, (1 - downtime / span) * 100))
        let inet = s.compactMap(\.internetRTTms)
        var ifaceChanges = 0
        for i in 1..<max(1, s.count) where s[i].interface != s[i - 1].interface { ifaceChanges += 1 }
        var hourly: [Int: [Double]] = [:]
        for x in s { if let r = x.internetRTTms { hourly[calendar.component(.hour, from: x.timestamp), default: []].append(r) } }
        var trends: [String] = []
        if let cur = Stats.median(inet), let base = Stats.median(baseline.compactMap(\.internetRTTms)), baseline.count >= 20, base > 0 {
            let change = (cur - base) / base
            if change > 0.5 { trends.append(String(format: "Latence Internet médiane en hausse de %.0f %% par rapport à la période de référence (%@ → %@).", change * 100, Units.ms(base), Units.ms(cur))) }
            if change < -0.3 { trends.append(String(format: "Latence Internet médiane en baisse de %.0f %%.", -change * 100)) }
        }
        if let (worstHour, v) = hourly.mapValues({ Stats.median($0) ?? 0 }).max(by: { $0.value < $1.value }),
           let overall = Stats.median(inet), v > overall * 1.5, (hourly[worstHour]?.count ?? 0) >= 5 {
            trends.append("Latence plus élevée vers \(worstHour) h (médiane \(Units.ms(v)) contre \(Units.ms(overall)) sur la période) : congestion possible aux heures de pointe.")
        }
        return HealthReport(periodStart: from, periodEnd: to, samples: s.count, availabilityPercent: avail, outages: outs,
                            totalDowntime: downtime, internetLatencyMedianMs: Stats.median(inet),
                            internetLatencyP95Ms: Stats.percentile(inet, 95),
                            gatewayLatencyMedianMs: Stats.median(s.compactMap(\.gatewayRTTms)),
                            meanLossPercent: Stats.mean(s.compactMap(\.internetLossPercent)),
                            dnsFailures: s.filter { $0.dnsOK == false }.count, interfaceChanges: ifaceChanges,
                            trends: trends, hourlyMedianLatency: hourly.compactMapValues { Stats.median($0) })
    }
}

/// Tracks per-network baselines (gateway IP/MAC, DNS servers) and reports changes.
public struct NetworkBaseline: Codable, Hashable, Sendable {
    public var networkKey: String
    public var gatewayIP: String?
    public var gatewayMAC: String?
    public var dnsServers: [String]
    public var knownBSSIDs: [String]
    public var updated: Date
}

public enum ChangeDetector {
    public static func diff(baseline: NetworkBaseline?, current: NetworkBaseline) -> [NetworkEvent] {
        guard let b = baseline, b.networkKey == current.networkKey else { return [] }
        var ev: [NetworkEvent] = []
        if let o = b.gatewayIP, let n = current.gatewayIP, o != n {
            ev.append(NetworkEvent(timestamp: current.updated, kind: .gatewayChanged, message: "Passerelle modifiée : \(o) → \(n)",
                                   details: ["old": o, "new": n]))
        }
        if let o = b.gatewayMAC, let n = current.gatewayMAC, o != n, b.gatewayIP == current.gatewayIP {
            ev.append(NetworkEvent(timestamp: current.updated, kind: .gatewayChanged,
                                   message: "L’adresse MAC de la passerelle a changé (\(o) → \(n)) pour la même IP. Cela peut être un remplacement de box, ou plus rarement une usurpation ARP : à vérifier.",
                                   details: ["oldMAC": o, "newMAC": n]))
        }
        if Set(b.dnsServers) != Set(current.dnsServers), !current.dnsServers.isEmpty {
            ev.append(NetworkEvent(timestamp: current.updated, kind: .dnsChanged,
                                   message: "Serveurs DNS modifiés : \(b.dnsServers.joined(separator: ", ")) → \(current.dnsServers.joined(separator: ", "))"))
        }
        return ev
    }
}
