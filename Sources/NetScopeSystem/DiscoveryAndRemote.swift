#if os(macOS)
import Foundation
import CryptoKit
import NetScopeCore

// MARK: - Bonjour / mDNS discovery

/// Passive Bonjour browsing for a fixed list of service types. Resolution uses mDNS queries only:
/// NetScope never opens a connection to the discovered services.
@MainActor
public final class BonjourDiscoveryService: NSObject {
    public static let serviceTypes = [
        "_airplay._tcp.", "_raop._tcp.", "_googlecast._tcp.", "_ipp._tcp.", "_ipps._tcp.", "_printer._tcp.",
        "_pdl-datastream._tcp.", "_scanner._tcp.", "_hap._tcp.", "_matter._tcp.", "_smb._tcp.", "_afpovertcp._tcp.",
        "_adisk._tcp.", "_ssh._tcp.", "_sftp-ssh._tcp.", "_workstation._tcp.", "_companion-link._tcp.",
        "_apple-mobdev2._tcp.", "_sonos._tcp.", "_spotify-connect._tcp.", "_fbx-api._tcp.", "_airport._tcp.",
        "_rtsp._tcp.", "_http._tcp.",
    ]

    private var browsers: [NetServiceBrowser] = []
    private var pending: [NetService] = []
    private var observations: [DeviceObservation] = []
    private var continuation: CheckedContinuation<[DeviceObservation], Never>?

    public override init() { super.init() }

    /// Browses for `seconds` and returns what was resolved.
    public func discover(seconds: Double = 6) async -> [DeviceObservation] {
        observations = []
        pending = []
        for t in Self.serviceTypes {
            let b = NetServiceBrowser()
            b.delegate = self
            b.searchForServices(ofType: t, inDomain: "local.")
            browsers.append(b)
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        browsers.forEach { $0.stop() }
        browsers.removeAll()
        pending.forEach { $0.stop() }
        pending.removeAll()
        return observations
    }

    fileprivate func record(_ s: NetService) {
        var v4: String?
        var v6: String?
        for data in s.addresses ?? [] {
            data.withUnsafeBytes { raw in
                guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let str = String(cString: host)
                    if sa.pointee.sa_family == sa_family_t(AF_INET) { v4 = str }
                    else if sa.pointee.sa_family == sa_family_t(AF_INET6), !str.hasPrefix("fe80") { v6 = str }
                }
            }
        }
        let host = s.hostName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
        let type = s.type.hasSuffix(".") ? String(s.type.dropLast()) : s.type
        observations.append(DeviceObservation(method: .bonjour, ip: v4, ipv6: v6, hostname: host ?? s.name, services: [type]))
    }
}

extension BonjourDiscoveryService: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            service.delegate = self
            self.pending.append(service)
            service.resolve(withTimeout: 4)
        }
    }
    nonisolated public func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in self.record(sender) }
    }
}

// MARK: - Remote measurement agent client (multi-point diagnostics)

public struct AgentPairing: Codable, Hashable, Identifiable, Sendable {
    public var id: String { host + ":\(port)" }
    public var name: String
    public var host: String
    public var port: Int
    /// SHA-256 of the agent's TLS certificate (DER), pinned at pairing time.
    public var certificateSHA256: String
    public var paired: Date
}

public enum AgentError: Error, LocalizedError {
    case invalidHost, pairingRejected(String), notPaired, http(Int), decoding, pinMismatch
    public var errorDescription: String? {
        switch self {
        case .invalidHost: return "Adresse d’agent invalide."
        case .pairingRejected(let m): return "Appairage refusé : \(m)"
        case .notPaired: return "Agent non appairé."
        case .http(let s): return "Réponse HTTP \(s) de l’agent."
        case .decoding: return "Réponse de l’agent illisible."
        case .pinMismatch: return "Le certificat de l’agent ne correspond pas à celui enregistré lors de l’appairage."
        }
    }
}

/// Talks to `Agent/netscope_agent.py` over HTTPS with certificate pinning and a bearer token obtained by
/// explicit pairing (one-time code shown on the agent's console).
public final class AgentClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    let secrets: SecretStore
    private var expectedPin: String?
    private(set) var observedPin: String?
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    public init(secrets: SecretStore) { self.secrets = secrets }

    static func tokenKey(_ p: AgentPairing) -> String { "agent.\(p.id)" }

    /// Pairing: TOFU — the fingerprint returned here must be compared by the user with the one printed by the agent.
    public func pair(host: String, port: Int, code: String, name: String) async throws -> AgentPairing {
        guard ArgumentValidator.isValidHost(host), (1...65535).contains(port) else { throw AgentError.invalidHost }
        expectedPin = nil
        let (data, status) = try await post(host: host, port: port, path: "/pair", body: ["code": code, "client": "NetScope Pro"], token: nil)
        guard status == 200, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let token = o["token"] as? String,
              let pin = observedPin else {
            throw AgentError.pairingRejected((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "code invalide")
        }
        let p = AgentPairing(name: name, host: host, port: port, certificateSHA256: pin, paired: Date())
        try secrets.write(Self.tokenKey(p), value: token)
        return p
    }

    public func ping(_ p: AgentPairing, target: String, count: Int = 20) async throws -> LatencyStats {
        let o = try await call(p, "/ping", ["target": target, "count": count])
        let samples = (o["samples_ms"] as? [NSNumber])?.map(\.doubleValue) ?? []
        return LatencyStats(target: target, sent: (o["sent"] as? NSNumber)?.intValue ?? count,
                            received: (o["received"] as? NSNumber)?.intValue ?? samples.count, samplesMs: samples,
                            method: "Agent \(p.name) — ICMP")
    }

    public func iperf(_ p: AgentPairing, server: String, reverse: Bool, seconds: Int = 8) async throws -> IPerf3Parser.Result {
        let o = try await call(p, "/iperf", ["server": server, "reverse": reverse, "seconds": seconds])
        guard let raw = o["raw"] as? String else { throw AgentError.decoding }
        return IPerf3Parser.parse(raw)
    }

    public func info(_ p: AgentPairing) async throws -> [String: Any] { try await call(p, "/info", [:]) }

    /// Asks the agent to start a one-shot `iperf3 -s -1` server (exits after one test) for the LAN measurement.
    @discardableResult
    public func startIperfServer(_ p: AgentPairing) async throws -> Bool {
        let o = try await call(p, "/iperf-server", [:])
        return (o["started"] as? Bool) ?? false
    }

    private func call(_ p: AgentPairing, _ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        guard let token = secrets.read(Self.tokenKey(p)) else { throw AgentError.notPaired }
        expectedPin = p.certificateSHA256
        let (data, status) = try await post(host: p.host, port: p.port, path: path, body: body, token: token)
        guard status == 200 else { throw AgentError.http(status) }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AgentError.decoding }
        return o
    }

    private func post(host: String, port: Int, path: String, body: [String: Any], token: String?) async throws -> (Data, Int) {
        let h = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "https://\(h):\(port)\(path)") else { throw AgentError.invalidHost }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, r) = try await session.data(for: req)
        return (d, (r as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Accepts the agent's self-signed certificate only if it matches the pinned fingerprint
    /// (or, during pairing, records it for the user to verify).
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let der = SecCertificateCopyData(leaf) as Data
        let pin = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        observedPin = pin
        if let expected = expectedPin, expected != pin {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

// MARK: - Optional AI assistant (opt-in, explicit consent per request)

/// Sends a redacted, structured diagnostic summary to the Claude Messages API — only when the user has
/// enabled the feature, stored their own API key in the Keychain and confirmed the request.
public struct ClaudeAssistantClient: Sendable {
    public static let keychainKey = "ai.anthropic.api_key"
    public static let model = "claude-opus-5-5"
    let secrets: SecretStore
    public init(secrets: SecretStore) { self.secrets = secrets }

    public var isConfigured: Bool { secrets.read(Self.keychainKey) != nil }

    public enum AIError: Error, LocalizedError {
        case noKey, http(Int, String), refused, decoding
        public var errorDescription: String? {
            switch self {
            case .noKey: return "Aucune clé API configurée."
            case .http(let s, let m): return "Erreur API (\(s)) : \(m)"
            case .refused: return "La requête a été refusée par le modèle."
            case .decoding: return "Réponse illisible."
            }
        }
    }

    public func ask(question: String, context: [String: Any]) async throws -> String {
        guard let key = secrets.read(Self.keychainKey) else { throw AIError.noKey }
        let ctxData = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
        let ctx = String(decoding: ctxData, as: UTF8.self)
        let system = """
        Tu es l’assistant de diagnostic réseau de NetScope Pro. Tu reçois des mesures structurées et horodatées \
        issues d’un Mac. Réponds en français. Sépare clairement : (1) faits observés, (2) hypothèses avec niveau de \
        confiance, (3) recommandations concrètes classées par efficacité et risque. N’invente aucune mesure ; \
        si une donnée manque, dis-le. Ne conclus jamais à une panne de l’opérateur sans preuve.
        """
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "system": system,
            "fallbacks": "default",
            "messages": [["role": "user", "content": "Mesures (JSON) :\n\(ctx)\n\nQuestion : \(question)"]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.decoding }
        guard status == 200 else {
            throw AIError.http(status, ((o["error"] as? [String: Any])?["message"] as? String) ?? "")
        }
        if o["stop_reason"] as? String == "refusal" { throw AIError.refused }
        let blocks = o["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.isEmpty else { throw AIError.decoding }
        return text
    }
}
#endif
