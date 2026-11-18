import Foundation

public enum SpeedTestMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case quick, full, gaming, videoCall, streaming, lan, bufferbloat
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .quick: return "Quick Test"
        case .full: return "Full Test"
        case .gaming: return "Gaming Test"
        case .videoCall: return "Video Call Test"
        case .streaming: return "Streaming Test"
        case .lan: return "LAN Test (iperf3)"
        case .bufferbloat: return "Bufferbloat Lab"
        }
    }
}

public enum SpeedTestEngine: String, Codable, Sendable {
    case networkQuality = "Apple networkQuality"
    case iperf3 = "iperf3 (serveur LAN contrôlé)"
    case agent = "Agent NetScope distant"
}

/// Result of one throughput/latency measurement campaign. All values are optional: only what the
/// engine actually reported is filled in, and `missingFields` records what was absent.
public struct SpeedTestResult: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var mode: SpeedTestMode
    public var engine: SpeedTestEngine
    public var server: String?
    public var interfaceName: String?
    public var networkName: String?
    public var downloadBps: Double?
    public var uploadBps: Double?
    public var idleLatencyMs: Double?
    public var downloadLoadedLatencyMs: Double?
    public var uploadLoadedLatencyMs: Double?
    public var jitterMs: Double?
    public var packetLossPercent: Double?
    public var responsivenessRPM: Double?
    public var downloadResponsivenessRPM: Double?
    public var uploadResponsivenessRPM: Double?
    public var tcpHandshakeMs: Double?
    public var tlsHandshakeMs: Double?
    public var httpResponseMs: Double?
    public var dnsResolutionMs: Double?
    public var downloadFlows: Int?
    public var uploadFlows: Int?
    public var bytesTransferred: Double?
    public var sequential: Bool
    public var vpnActive: Bool
    public var proxyActive: Bool
    public var osVersion: String?
    public var missingFields: [String]
    public var error: String?
    public var rawJSON: String?

    public init(id: UUID = UUID(), timestamp: Date = Date(), mode: SpeedTestMode, engine: SpeedTestEngine,
                server: String? = nil, interfaceName: String? = nil, networkName: String? = nil,
                downloadBps: Double? = nil, uploadBps: Double? = nil, idleLatencyMs: Double? = nil,
                downloadLoadedLatencyMs: Double? = nil, uploadLoadedLatencyMs: Double? = nil,
                jitterMs: Double? = nil, packetLossPercent: Double? = nil, responsivenessRPM: Double? = nil,
                downloadResponsivenessRPM: Double? = nil, uploadResponsivenessRPM: Double? = nil,
                tcpHandshakeMs: Double? = nil, tlsHandshakeMs: Double? = nil, httpResponseMs: Double? = nil,
                dnsResolutionMs: Double? = nil, downloadFlows: Int? = nil, uploadFlows: Int? = nil,
                bytesTransferred: Double? = nil, sequential: Bool = false, vpnActive: Bool = false,
                proxyActive: Bool = false, osVersion: String? = nil, missingFields: [String] = [],
                error: String? = nil, rawJSON: String? = nil) {
        self.id = id; self.timestamp = timestamp; self.mode = mode; self.engine = engine; self.server = server
        self.interfaceName = interfaceName; self.networkName = networkName; self.downloadBps = downloadBps
        self.uploadBps = uploadBps; self.idleLatencyMs = idleLatencyMs
        self.downloadLoadedLatencyMs = downloadLoadedLatencyMs; self.uploadLoadedLatencyMs = uploadLoadedLatencyMs
        self.jitterMs = jitterMs; self.packetLossPercent = packetLossPercent; self.responsivenessRPM = responsivenessRPM
        self.downloadResponsivenessRPM = downloadResponsivenessRPM; self.uploadResponsivenessRPM = uploadResponsivenessRPM
        self.tcpHandshakeMs = tcpHandshakeMs; self.tlsHandshakeMs = tlsHandshakeMs; self.httpResponseMs = httpResponseMs
        self.dnsResolutionMs = dnsResolutionMs; self.downloadFlows = downloadFlows; self.uploadFlows = uploadFlows
        self.bytesTransferred = bytesTransferred; self.sequential = sequential; self.vpnActive = vpnActive
        self.proxyActive = proxyActive; self.osVersion = osVersion; self.missingFields = missingFields
        self.error = error; self.rawJSON = rawJSON
    }

    /// Loaded latency (worst of download/upload directions) — used for bufferbloat assessment.
    public var worstLoadedLatencyMs: Double? {
        [downloadLoadedLatencyMs, uploadLoadedLatencyMs].compactMap { $0 }.max()
    }

    public var succeeded: Bool { error == nil && (downloadBps != nil || uploadBps != nil || responsivenessRPM != nil) }
}

public enum NetworkQualityParseError: Error, LocalizedError, Equatable {
    case notJSON
    case reportedError(String)
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .notJSON: return "La sortie de networkQuality n’est pas un JSON valide."
        case .reportedError(let e): return "networkQuality a signalé une erreur : \(e)"
        case .emptyResult: return "networkQuality n’a renvoyé aucune métrique exploitable."
        }
    }
}

/// Adapter for `networkQuality -c` JSON. Field names have changed across macOS releases
/// (12 → 13 → 14/15), so every key is optional and several aliases are accepted.
public enum NetworkQualityParser {
    static let latencyArrayKeysDownload = ["lud_foreign_dl_h2_req_resp", "lud_foreign_dl_h3_req_resp",
                                           "lud_self_dl_h2_req_resp", "lud_self_dl_h3_req_resp",
                                           "lud_foreign_h2_req_resp", "lud_foreign_h3_req_resp"]
    static let latencyArrayKeysUpload = ["lud_foreign_ul_h2_req_resp", "lud_foreign_ul_h3_req_resp",
                                         "lud_self_ul_h2_req_resp", "lud_self_ul_h3_req_resp"]

    public static func parse(_ text: String, mode: SpeedTestMode, sequential: Bool,
                             vpnActive: Bool = false, proxyActive: Bool = false,
                             now: Date = Date()) throws -> SpeedTestResult {
        // Some versions print warnings before the JSON object: start at the first '{'.
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { throw NetworkQualityParseError.notJSON }
        let jsonText = String(text[start...end])
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NetworkQualityParseError.notJSON
        }
        if let err = obj["error_code"] ?? obj["error"] {
            throw NetworkQualityParseError.reportedError("\(err)")
        }

        func num(_ keys: String...) -> Double? {
            for k in keys { if let v = obj[k] { if let d = v as? Double { return d }; if let i = v as? Int { return Double(i) }; if let n = v as? NSNumber { return n.doubleValue }; if let s = v as? String, let d = Double(s) { return d } } }
            return nil
        }
        func str(_ keys: String...) -> String? {
            for k in keys { if let s = obj[k] as? String, !s.isEmpty { return s } }
            return nil
        }
        func arr(_ keys: [String]) -> [Double] {
            for k in keys {
                if let a = obj[k] as? [Any] {
                    let v = a.compactMap { ($0 as? NSNumber)?.doubleValue ?? ($0 as? Double) }
                    if !v.isEmpty { return v }
                }
            }
            return []
        }

        var missing: [String] = []
        let dl = num("dl_throughput")
        let ul = num("ul_throughput")
        let rpm = num("responsiveness")
        if dl == nil && mode != .bufferbloat { missing.append("dl_throughput") }
        if ul == nil { missing.append("ul_throughput") }
        if rpm == nil { missing.append("responsiveness") }

        let idleRTTs = arr(["il_h2_req_resp", "il_h3_req_resp"])
        var idle = num("base_rtt")
        if idle == nil { idle = Stats.median(idleRTTs) }
        if idle == nil { missing.append("base_rtt") }

        let dlLoaded = Stats.median(arr(latencyArrayKeysDownload))
        let ulLoaded = Stats.median(arr(latencyArrayKeysUpload))
        if dlLoaded == nil { missing.append("latence sous charge (download)") }

        let tcp = Stats.median(arr(["il_tcp_handshake_443", "lud_foreign_tcp_handshake_443"]))
        let tls = Stats.median(arr(["il_tls_handshake", "lud_foreign_tls_handshake"]))
        let http = Stats.median(idleRTTs)

        // Jitter from idle request/response samples when available (mean consecutive difference).
        let jitter = Stats.meanAbsoluteConsecutiveDifference(idleRTTs)

        let bytes = [num("dl_bytes_transferred"), num("ul_bytes_transferred")].compactMap { $0 }

        let result = SpeedTestResult(
            timestamp: now, mode: mode, engine: .networkQuality,
            server: str("test_endpoint", "server"),
            interfaceName: str("interface_name"),
            downloadBps: dl, uploadBps: ul, idleLatencyMs: idle,
            downloadLoadedLatencyMs: dlLoaded, uploadLoadedLatencyMs: ulLoaded,
            jitterMs: jitter, packetLossPercent: nil,
            responsivenessRPM: rpm,
            downloadResponsivenessRPM: num("dl_responsiveness"),
            uploadResponsivenessRPM: num("ul_responsiveness"),
            tcpHandshakeMs: tcp, tlsHandshakeMs: tls, httpResponseMs: http,
            downloadFlows: num("dl_flows").map { Int($0) }, uploadFlows: num("ul_flows").map { Int($0) },
            bytesTransferred: bytes.isEmpty ? nil : bytes.reduce(0, +),
            sequential: sequential, vpnActive: vpnActive, proxyActive: proxyActive,
            osVersion: str("os_version"), missingFields: missing, rawJSON: jsonText)

        if dl == nil && ul == nil && rpm == nil && idle == nil { throw NetworkQualityParseError.emptyResult }
        return result
    }

    /// Responsiveness in RPM to a loaded round-trip time in ms (RPM = 60000 / RTT).
    public static func rpmToMs(_ rpm: Double) -> Double? { rpm > 0 ? 60_000 / rpm : nil }
}

public enum IPerf3Parser {
    public struct Result: Sendable, Equatable {
        public var remoteHost: String?
        public var sentBps: Double?
        public var receivedBps: Double?
        public var retransmits: Int?
        public var durationSeconds: Double?
        public var reverse: Bool
        public var error: String?
    }

    public static func parse(_ text: String) -> Result {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Result(reverse: false, error: "Sortie iperf3 non JSON")
        }
        if let e = obj["error"] as? String { return Result(reverse: false, error: e) }
        let start = obj["start"] as? [String: Any]
        let connected = (start?["connected"] as? [[String: Any]])?.first
        let testStart = start?["test_start"] as? [String: Any]
        let end = obj["end"] as? [String: Any]
        let sent = end?["sum_sent"] as? [String: Any]
        let recv = end?["sum_received"] as? [String: Any]
        func d(_ o: [String: Any]?, _ k: String) -> Double? { (o?[k] as? NSNumber)?.doubleValue }
        return Result(remoteHost: connected?["remote_host"] as? String,
                      sentBps: d(sent, "bits_per_second"), receivedBps: d(recv, "bits_per_second"),
                      retransmits: (sent?["retransmits"] as? NSNumber)?.intValue,
                      durationSeconds: d(sent, "seconds"),
                      reverse: ((testStart?["reverse"] as? NSNumber)?.intValue ?? 0) == 1, error: nil)
    }
}
