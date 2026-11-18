import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Freebox OS adapter, based on the official public SDK documentation (dev.freebox.fr/sdk/os).
///
/// Authentication flow:
///  1. `GET /api_version` discovers the API base and version.
///  2. `POST login/authorize/` registers NetScope; the user must confirm physically on the Freebox display.
///  3. The returned `app_token` is stored in the Keychain (never logged).
///  4. Each session: `GET login/` → challenge; password = HMAC-SHA1(app_token, challenge); `POST login/session/`.
///
/// Blocking uses the Wi-Fi MAC filter (`wifi/mac_filter/`). It only affects Wi-Fi association,
/// requires the "settings" permission, and is only effective when the filter mode is "blacklist".
public actor FreeboxAdapter: RouterAdapter {
    public static let descriptor = RouterAdapterDescriptor(
        id: "freebox", name: "Freebox (Free)", vendors: ["Free", "Freebox"], status: .implemented,
        documentation: "https://dev.freebox.fr/sdk/os/",
        notes: "Implémenté d’après la documentation officielle du SDK Freebox OS. Non validé sur un matériel réel dans cet environnement de développement. Le blocage passe par le filtrage MAC Wi-Fi (sans effet sur l’Ethernet).",
        declaredCapabilities: [.systemInfo, .listClients, .clientHistory, .wanStatus, .wanTraffic, .wifiConfig, .blockDevice, .guestNetwork])

    public static let appID = "fr.netscope.pro"
    public static let appName = "NetScope Pro"
    public static let appVersion = "1.0"
    static let tokenKey = "router.freebox.app_token"

    let transport: HTTPTransport
    let secrets: SecretStore
    let host: String
    private(set) var apiBase: String?
    private var sessionToken: String?
    private var permissions: [String: Bool] = [:]

    public init(host: String = "mafreebox.freebox.fr", transport: HTTPTransport = URLSessionTransport(),
                secrets: SecretStore) {
        self.host = host; self.transport = transport; self.secrets = secrets
    }

    public var isAuthenticated: Bool { sessionToken != nil }
    public var hasAppToken: Bool { secrets.read(Self.tokenKey) != nil }
    public var grantedPermissions: [String: Bool] { permissions }

    public var capabilities: RouterCapabilities {
        guard sessionToken != nil else { return [] }
        var c: RouterCapabilities = [.systemInfo, .listClients, .clientHistory, .wanStatus, .wanTraffic, .wifiConfig, .guestNetwork]
        if permissions["settings"] == true { c.insert(.blockDevice) }
        return c
    }

    // MARK: Discovery

    public static func probe(host: String, transport: HTTPTransport) async -> RouterProbeResult? {
        guard ArgumentValidator.isValidHost(host), let url = URL(string: "http://\(host)/api_version") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 3
        guard let (data, status) = try? await transport.send(req), status == 200,
              let o = try? JSONHelpers.object(data), o["api_base_url"] != nil else { return nil }
        let version = o["api_version"] as? String
        return RouterProbeResult(adapterID: descriptor.id, baseURL: "http://\(host)",
                                 model: (o["box_model_name"] as? String) ?? (o["box_model"] as? String) ?? (o["device_name"] as? String),
                                 apiVersion: version, evidence: "Réponse valide de /api_version")
    }

    func discover() async throws -> String {
        if let b = apiBase { return b }
        guard let url = URL(string: "http://\(host)/api_version") else { throw RouterError.notDetected }
        let (data, status) = try await transport.send(URLRequest(url: url))
        guard status == 200 else { throw RouterError.notDetected }
        let o = try JSONHelpers.object(data)
        guard let base = o["api_base_url"] as? String, let v = o["api_version"] as? String,
              let major = v.split(separator: ".").first else { throw RouterError.notDetected }
        let b = "http://\(host)\(base)v\(major)/"
        apiBase = b
        return b
    }

    // MARK: Authorization

    public struct AuthorizationRequest: Sendable { public var trackID: Int }

    /// Starts app registration. The user must accept on the Freebox front panel.
    public func requestAuthorization(deviceName: String) async throws -> AuthorizationRequest {
        let body: [String: Any] = ["app_id": Self.appID, "app_name": Self.appName,
                                   "app_version": Self.appVersion, "device_name": deviceName]
        let r = try await call("login/authorize/", method: "POST", body: body, authenticated: false)
        guard let res = r as? [String: Any], let token = res["app_token"] as? String,
              let track = JSONHelpers.int(res["track_id"]) else { throw RouterError.decoding("app_token manquant") }
        try secrets.write(Self.tokenKey, value: token)
        return AuthorizationRequest(trackID: track)
    }

    public enum AuthorizationStatus: String, Sendable { case unknown, pending, timeout, granted, denied }

    public func authorizationStatus(_ req: AuthorizationRequest) async throws -> AuthorizationStatus {
        let r = try await call("login/authorize/\(req.trackID)", authenticated: false)
        let s = (r as? [String: Any])?["status"] as? String ?? "unknown"
        return AuthorizationStatus(rawValue: s) ?? .unknown
    }

    public func openSession() async throws {
        guard let token = secrets.read(Self.tokenKey) else { throw RouterError.notAuthenticated }
        let login = try await call("login/", authenticated: false)
        guard let challenge = (login as? [String: Any])?["challenge"] as? String else { throw RouterError.decoding("challenge manquant") }
        let password = SHA1.hex(SHA1.hmac(key: Array(token.utf8), message: Array(challenge.utf8)))
        let r = try await call("login/session/", method: "POST", body: ["app_id": Self.appID, "password": password],
                               authenticated: false)
        guard let res = r as? [String: Any], let st = res["session_token"] as? String else {
            throw RouterError.decoding("session_token manquant")
        }
        sessionToken = st
        permissions = (res["permissions"] as? [String: Any])?.compactMapValues { JSONHelpers.bool($0) } ?? [:]
    }

    public func logout() async {
        _ = try? await call("login/logout/", method: "POST", body: [:])
        sessionToken = nil
    }

    public func forgetAuthorization() async throws {
        await logout()
        try secrets.delete(Self.tokenKey)
    }

    // MARK: Read

    public func fetchInfo() async throws -> RouterInfo {
        let r = try await call("system/") as? [String: Any] ?? [:]
        let model = (r["model_info"] as? [String: Any])?["pretty_name"] as? String ?? r["board_name"] as? String
        return RouterInfo(adapterID: Self.descriptor.id, name: "Freebox", model: model,
                          firmware: r["firmware_version"] as? String,
                          uptimeSeconds: JSONHelpers.double(r["uptime_val"]),
                          serial: r["serial"] as? String, apiVersion: apiBase)
    }

    public func fetchClients() async throws -> [RouterClient] {
        let r = try await call("lan/browser/pub/") as? [[String: Any]] ?? []
        return r.map(Self.parseHost)
    }

    static func parseHost(_ h: [String: Any]) -> RouterClient {
        let l2 = h["l2ident"] as? [String: Any]
        let mac = (l2?["type"] as? String == "mac_address") ? (l2?["id"] as? String).flatMap(MACAddress.normalize) : nil
        let l3 = h["l3connectivities"] as? [[String: Any]] ?? []
        let v4 = l3.filter { $0["af"] as? String == "ipv4" }
        let ipv4 = (v4.first { JSONHelpers.bool($0["active"]) == true } ?? v4.first)?["addr"] as? String
        let ipv6 = l3.filter { $0["af"] as? String == "ipv6" }.compactMap { $0["addr"] as? String }
        let ap = h["access_point"] as? [String: Any]
        let ctype = ap?["connectivity_type"] as? String
        let link: RouterLinkType = ctype == "wifi" ? .wifi : (ctype == "ethernet" ? .ethernet : .unknown)
        let wifiInfo = ap?["wifi_information"] as? [String: Any]
        let last = JSONHelpers.double(h["last_activity"]).map { Date(timeIntervalSince1970: $0) }
        return RouterClient(id: h["id"] as? String ?? mac ?? UUID().uuidString, mac: mac, ipv4: ipv4, ipv6: ipv6,
                            name: h["primary_name"] as? String, hostType: h["host_type"] as? String,
                            vendor: (h["vendor_name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                            active: JSONHelpers.bool(h["active"]), lastSeen: last, link: link,
                            rxBytesPerSecond: JSONHelpers.double(ap?["rx_rate"]),
                            txBytesPerSecond: JSONHelpers.double(ap?["tx_rate"]),
                            wifiSignalDbm: JSONHelpers.int(wifiInfo?["signal"]),
                            wifiBand: wifiInfo?["band"] as? String)
    }

    public func fetchWAN() async throws -> WANStatus {
        let r = try await call("connection/") as? [String: Any] ?? [:]
        // Per SDK: rate_* are bytes/s, bandwidth_* are bits/s.
        return WANStatus(state: r["state"] as? String, media: r["media"] as? String, type: r["type"] as? String,
                         ipv4: r["ipv4"] as? String, ipv6: r["ipv6"] as? String,
                         currentDownBps: JSONHelpers.double(r["rate_down"]).map { $0 * 8 },
                         currentUpBps: JSONHelpers.double(r["rate_up"]).map { $0 * 8 },
                         syncDownBps: JSONHelpers.double(r["bandwidth_down"]),
                         syncUpBps: JSONHelpers.double(r["bandwidth_up"]),
                         totalBytesDown: JSONHelpers.double(r["bytes_down"]),
                         totalBytesUp: JSONHelpers.double(r["bytes_up"]))
    }

    public func fetchWiFi() async throws -> RouterWiFiReport {
        let config = try await call("wifi/config/") as? [String: Any] ?? [:]
        let aps = (try? await call("wifi/ap/") as? [[String: Any]]) ?? []
        let bss = (try? await call("wifi/bss/") as? [[String: Any]]) ?? []
        var apByID: [Int: [String: Any]] = [:]
        for ap in aps { if let id = JSONHelpers.int(ap["id"]) { apByID[id] = ap } }
        let nets: [RouterWiFiNetwork] = bss.map { b in
            let c = b["config"] as? [String: Any] ?? [:]
            let ap = JSONHelpers.int(b["phy_id"]).flatMap { apByID[$0] }
            let apc = ap?["config"] as? [String: Any]
            let width = (apc?["channel_width"] as? String).flatMap { Int($0) }
            return RouterWiFiNetwork(ssid: c["ssid"] as? String, band: apc?["band"] as? String,
                                     channel: JSONHelpers.int(apc?["primary_channel"]), channelWidthMHz: width,
                                     encryption: c["encryption"] as? String, enabled: JSONHelpers.bool(c["enabled"]),
                                     hidden: JSONHelpers.bool(c["hide_ssid"]),
                                     wpsEnabled: JSONHelpers.bool(c["wps_enabled"]), isGuest: false)
        }
        let guest = (try? await call("wifi/custom_key/") as? [[String: Any]]).map { !$0.isEmpty }
        return RouterWiFiReport(networks: nets, guestNetworkEnabled: guest,
                                macFilterMode: config["mac_filter_state"] as? String)
    }

    // MARK: Access control

    public func listAccessRules() async throws -> [AccessRule] {
        let r = try await call("wifi/mac_filter/") as? [[String: Any]] ?? []
        return r.compactMap { f in
            guard let mac = (f["mac"] as? String).flatMap(MACAddress.normalize) else { return nil }
            return AccessRule(id: "\(f["id"] ?? mac)", mac: mac, blocked: f["type"] as? String == "blacklist",
                              comment: f["comment"] as? String, scope: "Filtrage MAC Wi-Fi")
        }
    }

    public func setBlocked(mac rawMac: String, blocked: Bool, comment: String) async throws -> AccessRule? {
        guard permissions["settings"] == true else { throw RouterError.insufficientPermission("Modification des réglages de la Freebox") }
        guard let mac = MACAddress.normalize(rawMac) else { throw RouterError.unsupported("adresse MAC invalide") }
        let existing = try await listAccessRules().filter { $0.mac == mac }
        if blocked {
            if existing.contains(where: \.blocked) { return existing.first(where: \.blocked) }
            _ = try await call("wifi/mac_filter/", method: "POST",
                               body: ["mac": mac.uppercased(), "type": "blacklist", "comment": String(comment.prefix(60))])
        } else {
            for rule in existing where rule.blocked {
                _ = try await call("wifi/mac_filter/\(rule.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rule.id)", method: "DELETE")
            }
        }
        // Verify by re-reading the rules.
        let after = try await listAccessRules().first { $0.mac == mac && $0.blocked }
        if blocked && after == nil { throw RouterError.verificationFailed("la règle n’apparaît pas dans le filtre MAC") }
        if !blocked && after != nil { throw RouterError.verificationFailed("la règle de blocage est toujours présente") }
        return after
    }

    /// The MAC filter only takes effect in "blacklist" mode. Changing it is a global setting → separate confirmation.
    public func setMacFilterMode(_ mode: String) async throws {
        guard ["disabled", "blacklist", "whitelist"].contains(mode) else { throw RouterError.unsupported("mode \(mode)") }
        guard mode != "whitelist" else {
            // Whitelist mode would disconnect every device not listed: deliberately not offered.
            throw RouterError.unsupported("mode liste blanche (risque de déconnecter tous les appareils)")
        }
        guard permissions["settings"] == true else { throw RouterError.insufficientPermission("Modification des réglages de la Freebox") }
        _ = try await call("wifi/config/", method: "PUT", body: ["mac_filter_state": mode])
    }

    // MARK: HTTP

    private var retriedLogin = false

    @discardableResult
    func call(_ path: String, method: String = "GET", body: [String: Any]? = nil, authenticated: Bool = true) async throws -> Any? {
        let base = try await discover()
        guard let url = URL(string: base + path) else { throw RouterError.transport("URL invalide") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            if sessionToken == nil { try await openSession() }
            req.setValue(sessionToken, forHTTPHeaderField: "X-Fbx-App-Auth")
        }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, status) = try await transport.send(req)
        let o = (try? JSONHelpers.object(data)) ?? [:]
        if JSONHelpers.bool(o["success"]) == true {
            retriedLogin = false
            return o["result"]
        }
        let code = o["error_code"] as? String ?? "http_\(status)"
        if authenticated, code == "auth_required" || code == "invalid_session", !retriedLogin {
            retriedLogin = true
            sessionToken = nil
            return try await call(path, method: method, body: body, authenticated: true)
        }
        retriedLogin = false
        if code == "insufficient_rights" { throw RouterError.insufficientPermission(o["missing_right"] as? String ?? "settings") }
        if code == "pending" { throw RouterError.authorizationPending }
        if o.isEmpty && status != 200 { throw RouterError.http(status) }
        throw RouterError.api(code: code, message: o["msg"] as? String ?? "")
    }
}
