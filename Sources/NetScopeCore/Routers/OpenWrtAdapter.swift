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
        id: "openwrt", name: "OpenWrt (ubus JSON-RPC)", vendors: ["OpenWrt"], status: .readOnly,
        documentation: "https://openwrt.org/docs/techref/ubus",
        notes: "Lecture seule : informations système, WAN, baux DHCP. Nécessite uhttpd-mod-ubus et un utilisateur rpcd. Non validé sur matériel réel dans cet environnement.",
        declaredCapabilities: [.systemInfo, .listClients, .wanStatus])

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
