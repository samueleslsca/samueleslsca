import XCTest
@testable import NetScopeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Mock HTTP transport: routes "METHOD path" → (status, body).
final class MockTransport: HTTPTransport, @unchecked Sendable {
    var routes: [String: (Int, String)] = [:]
    var log: [(String, String, [String: String], Data?)] = []
    let lock = NSLock()
    var failAll: String?

    func on(_ method: String, _ path: String, _ status: Int = 200, _ body: String) { routes["\(method) \(path)"] = (status, body) }

    func send(_ r: URLRequest) async throws -> (Data, Int) {
        return try handle(r)
    }

    private func handle(_ r: URLRequest) throws -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        let path = r.url!.path + (r.url!.path.hasSuffix("/") || r.url!.absoluteString.hasSuffix("/") ? "" : "")
        let key = "\(r.httpMethod ?? "GET") \(r.url!.absoluteString.hasSuffix("/") && !path.hasSuffix("/") ? path + "/" : path)"
        log.append((r.httpMethod ?? "GET", key, r.allHTTPHeaderFields ?? [:], r.httpBody))
        if let f = failAll { throw RouterError.transport(f) }
        guard let (s, b) = routes[key] else { return (Data(#"{"success":false,"error_code":"not_found","msg":"no route"}"#.utf8), 404) }
        return (Data(b.utf8), s)
    }
}

final class FreeboxTests: XCTestCase {
    func makeBox(settings: Bool = true) throws -> (FreeboxAdapter, MockTransport, InMemorySecretStore) {
        let t = MockTransport()
        t.on("GET", "/api_version", 200, try fixture("freebox_api_version.json"))
        t.on("GET", "/api/v10/login/", 200, #"{"success":true,"result":{"logged_in":false,"challenge":"VzhbtpR4r8CLaJle2QgJBEkyd8JPb0zL"}}"#)
        t.on("POST", "/api/v10/login/session/", 200, #"{"success":true,"result":{"session_token":"SESSION-1","challenge":"x","permissions":{"settings":\#(settings),"contacts":false}}}"#)
        t.on("GET", "/api/v10/lan/browser/pub/", 200, try fixture("freebox_lan_hosts.json"))
        t.on("GET", "/api/v10/connection/", 200, #"{"success":true,"result":{"state":"up","media":"ftth","type":"ethernet","ipv4":"203.0.113.7","rate_down":1250000,"rate_up":125000,"bandwidth_down":8000000000,"bandwidth_up":700000000,"bytes_down":10,"bytes_up":5}}"#)
        t.on("GET", "/api/v10/system/", 200, #"{"success":true,"result":{"firmware_version":"4.8.1","uptime_val":86400,"board_name":"fbxgw7r","model_info":{"pretty_name":"Freebox v7 (r1)"}}}"#)
        t.on("GET", "/api/v10/wifi/mac_filter/", 200, #"{"success":true,"result":[]}"#)
        let s = InMemorySecretStore()
        try s.write(FreeboxAdapter.tokenKey, value: "dyNYgfK0Ya6FWGqq83sBHa7TwzWo+pg4fDFUJHShcjVYzTfaRrZzm93p7OTAfH/0")
        return (FreeboxAdapter(transport: t, secrets: s), t, s)
    }

    func testProbe() async throws {
        let t = MockTransport(); t.on("GET", "/api_version", 200, try fixture("freebox_api_version.json"))
        let p = await FreeboxAdapter.probe(host: "mafreebox.freebox.fr", transport: t)
        XCTAssertEqual(p?.model, "Freebox v7 (r1)"); XCTAssertEqual(p?.apiVersion, "10.2")
        let bad = await FreeboxAdapter.probe(host: "-bad", transport: t)
        XCTAssertNil(bad)
        // Scenario: routeur inconnu → probe returns nil.
        let unknown = await FreeboxAdapter.probe(host: "192.168.1.1", transport: MockTransport())
        XCTAssertNil(unknown)
    }

    func testSessionUsesHMACAndReadsData() async throws {
        let (box, t, _) = try makeBox()
        let clients = try await box.fetchClients()
        XCTAssertEqual(clients.count, 2)
        XCTAssertEqual(clients[0].mac, "3c:22:fb:12:34:56"); XCTAssertEqual(clients[0].ipv4, "192.168.1.10")
        XCTAssertEqual(clients[0].link, .wifi); XCTAssertEqual(clients[0].wifiSignalDbm, -58)
        XCTAssertNil(clients[1].vendor, "empty vendor string is not a vendor")
        XCTAssertEqual(clients[1].active, false)
        let login = t.log.first { $0.1 == "POST /api/v10/login/session/" }!
        let body = try JSONSerialization.jsonObject(with: login.3!) as! [String: String]
        let expected = SHA1.hex(SHA1.hmac(key: Array("dyNYgfK0Ya6FWGqq83sBHa7TwzWo+pg4fDFUJHShcjVYzTfaRrZzm93p7OTAfH/0".utf8), message: Array("VzhbtpR4r8CLaJle2QgJBEkyd8JPb0zL".utf8)))
        XCTAssertEqual(body["password"], expected)
        XCTAssertEqual(t.log.last?.2["X-Fbx-App-Auth"], "SESSION-1")

        let wan = try await box.fetchWAN()
        XCTAssertEqual(wan.currentDownBps, 10_000_000, "rate_down is bytes/s → converted to bits/s")
        XCTAssertEqual(wan.syncDownBps, 8e9)
        let info = try await box.fetchInfo()
        XCTAssertEqual(info.firmware, "4.8.1"); XCTAssertEqual(info.model, "Freebox v7 (r1)")
        let caps = await box.capabilities
        XCTAssertTrue(caps.contains(.blockDevice))
    }

    /// Scenario: blocage routeur non disponible (permission « settings » absente).
    func testBlockRequiresSettingsPermission() async throws {
        let (box, _, _) = try makeBox(settings: false)
        _ = try await box.fetchClients()
        let caps = await box.capabilities
        XCTAssertFalse(caps.contains(.blockDevice), "Bloquer must stay disabled without a real mechanism")
        do { _ = try await box.setBlocked(mac: "3c:22:fb:12:34:56", blocked: true, comment: "x"); XCTFail() }
        catch { guard case RouterError.insufficientPermission = error else { return XCTFail("\(error)") } }
    }

    /// Scenario: échec d’une action administrative (verification after write fails).
    func testBlockVerificationFailure() async throws {
        let (box, t, _) = try makeBox()
        t.on("POST", "/api/v10/wifi/mac_filter/", 200, #"{"success":true,"result":{"id":"3C:22:FB:12:34:56-blacklist"}}"#)
        _ = try await box.fetchClients()
        do { _ = try await box.setBlocked(mac: "3c:22:fb:12:34:56", blocked: true, comment: "test"); XCTFail() }
        catch { XCTAssertEqual(error as? RouterError, .verificationFailed("la règle n’apparaît pas dans le filtre MAC")) }
    }

    func testBlockSuccessVerified() async throws {
        let (box, t, _) = try makeBox()
        t.on("POST", "/api/v10/wifi/mac_filter/", 200, #"{"success":true,"result":{}}"#)
        _ = try await box.fetchClients()
        // After POST, the list contains the rule.
        t.on("GET", "/api/v10/wifi/mac_filter/", 200, #"{"success":true,"result":[{"id":"3C:22:FB:12:34:56-blacklist","mac":"3C:22:FB:12:34:56","type":"blacklist","comment":"NetScope"}]}"#)
        let rule = try await box.setBlocked(mac: "3C:22:FB:12:34:56", blocked: true, comment: "NetScope")
        XCTAssertEqual(rule?.mac, "3c:22:fb:12:34:56"); XCTAssertTrue(rule!.blocked)
        XCTAssertThrowsError(try { throw RouterError.unsupported("x") }())
        do { try await box.setMacFilterMode("whitelist"); XCTFail() } catch {}
    }

    /// Scenario: erreur d’authentification.
    func testAuthErrors() async throws {
        let t = MockTransport()
        t.on("GET", "/api_version", 200, try fixture("freebox_api_version.json"))
        let box = FreeboxAdapter(transport: t, secrets: InMemorySecretStore())
        do { _ = try await box.fetchClients(); XCTFail() } catch { XCTAssertEqual(error as? RouterError, .notAuthenticated) }

        let (box2, t2, _) = try makeBox()
        t2.on("POST", "/api/v10/login/session/", 403, #"{"success":false,"error_code":"invalid_token","msg":"The app token you are trying to use is invalid or has been revoked"}"#)
        do { _ = try await box2.fetchClients(); XCTFail() }
        catch { guard case RouterError.api(let code, _) = error else { return XCTFail("\(error)") }; XCTAssertEqual(code, "invalid_token") }
    }

    /// Scenario: API routeur indisponible.
    func testRouterUnreachable() async throws {
        let (box, t, _) = try makeBox()
        t.failAll = "The request timed out."
        do { _ = try await box.fetchInfo(); XCTFail() } catch { guard case RouterError.transport = error else { return XCTFail("\(error)") } }
    }

    func testAuthorizationFlow() async throws {
        let t = MockTransport()
        t.on("GET", "/api_version", 200, try fixture("freebox_api_version.json"))
        t.on("POST", "/api/v10/login/authorize/", 200, #"{"success":true,"result":{"app_token":"NEWTOKEN","track_id":42}}"#)
        t.on("GET", "/api/v10/login/authorize/42", 200, #"{"success":true,"result":{"status":"pending","challenge":"c"}}"#)
        let s = InMemorySecretStore()
        let box = FreeboxAdapter(transport: t, secrets: s)
        let req = try await box.requestAuthorization(deviceName: "Mac")
        XCTAssertEqual(req.trackID, 42)
        XCTAssertEqual(s.read(FreeboxAdapter.tokenKey), "NEWTOKEN", "token goes to the secret store")
        let st = try await box.authorizationStatus(req)
        XCTAssertEqual(st, .pending)
    }
}

final class OpenWrtTests: XCTestCase {
    func testReadOnlyFlow() async throws {
        let t = MockTransport()
        let s = InMemorySecretStore()
        let ow = OpenWrtAdapter(host: "192.168.1.1", transport: t, secrets: s)
        // Single endpoint: we answer based on the last request body.
        final class Router: HTTPTransport, @unchecked Sendable {
            func send(_ r: URLRequest) async throws -> (Data, Int) {
                let o = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
                let p = o["params"] as? [Any] ?? []
                let obj = p.count > 2 ? "\(p[1]).\(p[2])" : "list"
                let result: String
                switch obj {
                case "session.login": result = #"[0,{"ubus_rpc_session":"abc123"}]"#
                case "system.board": result = #"[0,{"hostname":"OpenWrt","model":"GL.iNet GL-MT6000","release":{"distribution":"OpenWrt","version":"23.05.3","revision":"r23809"}}]"#
                case "system.info": result = #"[0,{"uptime":3600}]"#
                case "luci-rpc.getDHCPLeases": result = #"[0,{"dhcp_leases":[{"hostname":"nas","ipaddr":"192.168.1.5","macaddr":"00:11:32:aa:bb:cc","expires":3000}]}]"#
                case "network.interface.wan.status": result = #"[6]"#
                default: result = #"[4]"#
                }
                return (Data(#"{"jsonrpc":"2.0","id":1,"result":\#(result)}"#.utf8), 200)
            }
        }
        _ = t
        let ow2 = OpenWrtAdapter(host: "192.168.1.1", transport: Router(), secrets: s)
        try await ow2.login(user: "netscope", password: "pw")
        XCTAssertEqual(s.read("router.openwrt.netscope"), "pw")
        let info = try await ow2.fetchInfo()
        XCTAssertEqual(info.model, "GL.iNet GL-MT6000"); XCTAssertEqual(info.firmware, "OpenWrt 23.05.3 r23809")
        let clients = try await ow2.fetchClients()
        XCTAssertEqual(clients.first?.mac, "00:11:32:aa:bb:cc")
        do { _ = try await ow2.fetchWAN(); XCTFail() } catch { guard case RouterError.insufficientPermission = error else { return XCTFail() } }
        do { _ = try await ow2.setBlocked(mac: "00:11:32:aa:bb:cc", blocked: true, comment: ""); XCTFail() }
        catch { guard case RouterError.unsupported = error else { return XCTFail() } }
        let caps = await ow.capabilities
        XCTAssertTrue(caps.isEmpty)
    }

    func testRegistryHonesty() {
        let implemented = RouterRegistry.descriptors.filter { $0.status != .notImplemented }.map(\.id)
        XCTAssertEqual(Set(implemented), ["freebox", "openwrt"])
        for d in RouterRegistry.descriptors where d.status == .notImplemented {
            XCTAssertTrue(d.declaredCapabilities.isEmpty, "\(d.id) must not advertise capabilities")
        }
    }
}
