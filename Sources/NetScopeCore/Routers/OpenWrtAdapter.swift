import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenWrt adapter (read-only) using the documented ubus JSON-RPC interface exposed by uhttpd/rpcd
/// (openwrt.org/docs/techref/ubus). Requires an rpcd user with read ACLs; credentials stay in the Keychain.
/// Blocking is intentionally not implemented: it would require writing firewall rules via UCI, which is
/// left to LuCI until a safe, reversible flow is validated on hardware.
public actor OpenWrtAdapter: RouterAdapter {
    public static let descriptor = RouterAdapterDescriptor(
        id: "openwrt", name: "OpenWrt (ubus JSON-RPC)", vendors: ["OpenWrt"], status: .implemented,
        documentation: "https://openwrt.org/docs/techref/ubus",
        notes: "Informations système, WAN, baux DHCP en lecture. Seule écriture : réglages SQM (sqm-scripts) via rpcd « uci apply » avec retour arrière automatique, uniquement depuis MAX BOOST après autorisation. Nécessite uhttpd-mod-ubus, un utilisateur rpcd (droit d’écriture uci sur « sqm » pour la QoS). Non validé sur matériel réel dans cet environnement.",
        declaredCapabilities: [.systemInfo, .listClients, .wanStatus, .qos])

    static let nullSession = "00000000000000000000000000000000"
    let transport: HTTPTransport
    let secrets: SecretStore
    let baseURL: String
    private var session: String?
    private var nextID = 1

    public init(host: String, transport: HTTPTransport = URLSessionTransport(), secrets: SecretStore) {
        self.baseURL = "http://\(host)/ubus"
        self.transport = transport
        self.secrets = secrets
    }

    public var isAuthenticated: Bool { session != nil }
    public var capabilities: RouterCapabilities { session == nil ? [] : [.systemInfo, .listClients, .wanStatus] }

    static func secretKey(_ user: String) -> String { "router.openwrt.\(user)" }

    public static func probe(host: String, transport: HTTPTransport) async -> RouterProbeResult? {
        guard ArgumentValidator.isValidHost(host), let url = URL(string: "http://\(host)/ubus") else { return nil }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 3
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "list", "params": []])
        guard let (data, _) = try? await transport.send(req), let o = try? JSONHelpers.object(data),
              o["jsonrpc"] as? String == "2.0" else { return nil }
        return RouterProbeResult(adapterID: descriptor.id, baseURL: "http://\(host)", model: nil, apiVersion: "ubus",
                                 evidence: "Le point /ubus répond en JSON-RPC 2.0")
    }

    public func login(user: String, password: String? = nil) async throws {
        let pw = password ?? secrets.read(Self.secretKey(user))
        guard let pw else { throw RouterError.notAuthenticated }
        let r = try await ubus(Self.nullSession, "session", "login", ["username": user, "password": pw])
        guard let sid = r["ubus_rpc_session"] as? String else { throw RouterError.notAuthenticated }
        session = sid
        if password != nil { try secrets.write(Self.secretKey(user), value: pw) }
    }

    public func fetchInfo() async throws -> RouterInfo {
        let sid = try requireSession()
        let board = try await ubus(sid, "system", "board", [:])
        let info = try? await ubus(sid, "system", "info", [:])
        let release = board["release"] as? [String: Any]
        return RouterInfo(adapterID: Self.descriptor.id, name: board["hostname"] as? String,
                          model: board["model"] as? String,
                          firmware: [release?["distribution"] as? String, release?["version"] as? String, release?["revision"] as? String]
                            .compactMap { $0 }.joined(separator: " "),
                          uptimeSeconds: JSONHelpers.double(info?["uptime"]), serial: nil, apiVersion: "ubus")
    }

    public func fetchClients() async throws -> [RouterClient] {
        let sid = try requireSession()
        let leases = try await ubus(sid, "luci-rpc", "getDHCPLeases", [:])
        let v4 = leases["dhcp_leases"] as? [[String: Any]] ?? []
        return v4.map { l in
            let mac = (l["macaddr"] as? String).flatMap(MACAddress.normalize)
            return RouterClient(id: mac ?? (l["ipaddr"] as? String ?? UUID().uuidString), mac: mac,
                                ipv4: l["ipaddr"] as? String, ipv6: [], name: l["hostname"] as? String,
                                hostType: nil, vendor: nil, active: nil, lastSeen: nil, link: .unknown,
                                rxBytesPerSecond: nil, txBytesPerSecond: nil, wifiSignalDbm: nil, wifiBand: nil)
        }
    }

    public func fetchWAN() async throws -> WANStatus {
        let sid = try requireSession()
        let s = try await ubus(sid, "network.interface.wan", "status", [:])
        let addr = (s["ipv4-address"] as? [[String: Any]])?.first?["address"] as? String
        let up = JSONHelpers.bool(s["up"])
        return WANStatus(state: up.map { $0 ? "up" : "down" }, media: s["device"] as? String, type: s["proto"] as? String,
                         ipv4: addr, ipv6: nil, currentDownBps: nil, currentUpBps: nil, syncDownBps: nil,
                         syncUpBps: nil, totalBytesDown: nil, totalBytesUp: nil)
    }

    // MARK: SQM (sqm-scripts) — the only write path, used by MAX BOOST after explicit authorization.

    public func readSQM() async throws -> [SQMSettings] {
        let sid = try requireSession()
        let r: [String: Any]
        do { r = try await ubus(sid, "uci", "get", ["config": "sqm"]) }
        catch RouterError.unsupported { throw RouterError.unsupported("sqm-scripts non installé (aucune configuration « sqm »)") }
        let values = r["values"] as? [String: Any] ?? [:]
        return values.compactMap { name, v in
            guard let o = v as? [String: Any], o[".type"] as? String == "queue" else { return nil }
            return SQMSettings(section: name, interface: o["interface"] as? String ?? "?", enabled: (o["enabled"] as? String) == "1",
                               downloadKbps: Int(o["download"] as? String ?? "") ?? 0, uploadKbps: Int(o["upload"] as? String ?? "") ?? 0,
                               qdisc: o["qdisc"] as? String ?? "cake", script: o["script"] as? String ?? "piece_of_cake.qos")
        }.sorted { $0.section < $1.section }
    }

    /// Checks the rpcd ACL for writing the "sqm" config without changing anything.
    public func canWriteSQM() async -> Bool {
        guard let sid = session else { return false }
        let r = try? await ubus(sid, "session", "access", ["scope": "uci", "object": "sqm", "function": "write"])
        return JSONHelpers.bool(r?["access"]) ?? false
    }

    /// Stages new values (uncommitted) in this session's uci delta.
    /// New proposals are restricted to known-good qdisc/scripts and sane rates; a restore writes back the exact previous
    /// values (charset-checked only), so an original disabled configuration with zero rates can always be restored.
    public func stageSQM(_ s: SQMSettings, restoring: Bool = false) async throws {
        guard (1...64).contains(s.section.count), s.section.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            throw RouterError.unsupported("nom de section SQM invalide")
        }
        let safe: (String) -> Bool = { v in v.count <= 40 && v.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) } }
        guard safe(s.qdisc), safe(s.script), (0...10_000_000).contains(s.downloadKbps), (0...10_000_000).contains(s.uploadKbps) else {
            throw RouterError.unsupported("valeurs SQM invalides")
        }
        if !restoring {
            guard !s.enabled || ((100...10_000_000).contains(s.downloadKbps) && (100...10_000_000).contains(s.uploadKbps)) else {
                throw RouterError.unsupported("débits SQM hors limites")
            }
            guard ["cake", "fq_codel"].contains(s.qdisc), ["piece_of_cake.qos", "layer_cake.qos", "simple.qos", "simplest.qos"].contains(s.script) else {
                throw RouterError.unsupported("file d’attente ou script SQM non autorisé")
            }
        }
        let sid = try requireSession()
        _ = try await ubus(sid, "uci", "set", ["config": "sqm", "section": s.section,
                                               "values": ["enabled": s.enabled ? "1" : "0", "download": "\(s.downloadKbps)", "upload": "\(s.uploadKbps)",
                                                          "qdisc": s.qdisc, "script": s.script]])
    }

    /// Commits and reloads staged changes; rpcd reverts them automatically unless `confirmApply()` is called within `timeout` seconds.
    public func applyWithRollback(timeout: Int = 60) async throws {
        let sid = try requireSession()
        _ = try await ubus(sid, "uci", "apply", ["rollback": true, "timeout": max(10, min(timeout, 300))])
    }

    public func confirmApply() async throws {
        let sid = try requireSession()
        _ = try await ubus(sid, "uci", "confirm", [:])
    }

    /// Reachability probe through a fresh HTTP request.
    public func isReachable() async -> Bool {
        guard let sid = session else { return false }
        return (try? await ubus(sid, "system", "board", [:])) != nil
    }

    private func requireSession() throws -> String {
        guard let s = session else { throw RouterError.notAuthenticated }
        return s
    }

    func ubus(_ sid: String, _ object: String, _ method: String, _ args: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: baseURL) else { throw RouterError.transport("URL invalide") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        nextID += 1
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": nextID, "method": "call", "params": [sid, object, method, args]])
        let (data, status) = try await transport.send(req)
        guard status == 200 else { throw RouterError.http(status) }
        let o = try JSONHelpers.object(data)
        if let e = o["error"] as? [String: Any] {
            throw RouterError.api(code: "\(e["code"] ?? "?")", message: e["message"] as? String ?? "")
        }
        guard let result = o["result"] as? [Any], let code = JSONHelpers.int(result.first) else {
            throw RouterError.decoding("résultat ubus manquant")
        }
        // ubus status codes: 0 OK, 6 permission denied, 4 not found.
        switch code {
        case 0: return result.count > 1 ? (result[1] as? [String: Any] ?? [:]) : [:]
        case 6: if sid != Self.nullSession { session = nil }; throw RouterError.insufficientPermission("ACL rpcd \(object).\(method)")
        case 4: throw RouterError.unsupported("\(object).\(method) absent (paquet luci-rpc requis ?)")
        default: throw RouterError.api(code: "ubus \(code)", message: "\(object).\(method)")
        }
    }
}
