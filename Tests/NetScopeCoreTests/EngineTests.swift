import XCTest
@testable import NetScopeCore

private func wifiSnapshot(rssi: Int?, noise: Int?, channel: Int = 6, band: WiFiBand = .ghz2_4, tx: Double? = 144,
                          bssid: String = "aa:bb:cc:00:00:01", security: WiFiSecurity = .wpa2Personal) -> WiFiSnapshot {
    let m = Provenance.measured(method: "test")
    return WiFiSnapshot(interfaceName: "en0", poweredOn: true, ssid: Sourced("Maison", m), bssid: Sourced(bssid, m),
                        rssi: Sourced(rssi, m), noise: Sourced(noise, m), channel: Sourced(channel, m), band: Sourced(band, m),
                        channelWidthMHz: Sourced(20, m), txRateMbps: Sourced(tx, m), standard: Sourced(.ax, m),
                        security: Sourced(security, m))
}

private func connection(kind: InterfaceKind, gateway: String? = "192.168.1.254", vpn: Bool = false, ip: String = "192.168.1.23",
                        media: String? = nil) -> ConnectionSnapshot {
    let iface = NetworkInterfaceInfo(bsdName: kind == .wifi ? "en0" : "en5", kind: kind,
                                     ipv4: [IPv4Assignment(address: ip, netmask: "255.255.255.0")], isUp: true, isRunning: true, media: media)
    return ConnectionSnapshot(isConnected: true, primaryInterface: iface, interfaces: [iface], defaultGatewayIPv4: gateway,
                              defaultGatewayIPv6: nil, dns: DNSConfiguration(resolvers: [.init(index: 1, domain: nil, nameservers: ["192.168.1.254"], interface: "en0", isScoped: false)]),
                              vpnActive: vpn, vpnInterfaces: vpn ? ["utun4"] : [], proxy: nil)
}

private func lat(_ target: String, _ samples: [Double], sent: Int? = nil) -> LatencyStats {
    LatencyStats(target: target, sent: sent ?? samples.count, received: samples.count, samplesMs: samples, method: "test")
}

final class ProvenanceTests: XCTestCase {
    func testNilValueIsNeverReportedAsMeasured() {
        let s = Sourced<Int>(nil, .measured(method: "CoreWLAN"))
        XCTAssertEqual(s.provenance.category, .unavailable)
        XCTAssertFalse(s.isAvailable)
    }

    func testSNRComputedOnlyWithRealNoise() {
        XCTAssertEqual(wifiSnapshot(rssi: -60, noise: -92).snr.value, 32)
        XCTAssertEqual(wifiSnapshot(rssi: -60, noise: -92).snr.provenance.category, .computed)
        XCTAssertNil(wifiSnapshot(rssi: -60, noise: nil).snr.value)
        XCTAssertNil(wifiSnapshot(rssi: -60, noise: 0).snr.value, "noise of 0 dBm is not physical")
    }

    func testBandInferenceNeverGuesses6GHz() {
        XCTAssertEqual(WiFiBand.inferred(fromChannel: 11), .ghz2_4)
        XCTAssertEqual(WiFiBand.inferred(fromChannel: 36), .ghz5)
        XCTAssertEqual(WiFiBand.inferred(fromChannel: 229), .unknown)
    }
}

final class DiagnosticsTests: XCTestCase {
    func testWeakSignalOnWiFi() {
        let i = DiagnosticInput(connection: connection(kind: .wifi), wifi: wifiSnapshot(rssi: -78, noise: -90),
                                gatewayLatency: lat("gw", [4, 5, 30, 6], sent: 5))
        let r = DiagnosticsEngine.analyze(i)
        let h = r.hypotheses.first { $0.cause == .weakSignal }
        XCTAssertNotNil(h); XCTAssertEqual(h?.confidence, .high)
        XCTAssertTrue(h!.recommendations.contains { $0.id == "use-ethernet" })
    }

    func testEthernetConnectedNoRadioHypothesis() {
        let i = DiagnosticInput(connection: connection(kind: .ethernet, media: "autoselect (1000baseT <full-duplex>)"),
                                wifi: wifiSnapshot(rssi: -80, noise: -90), gatewayLatency: lat("gw", [0.5, 0.6, 0.5]))
        let r = DiagnosticsEngine.analyze(i)
        XCTAssertNil(r.hypotheses.first { $0.cause == .weakSignal }, "Wi-Fi rules must not fire on Ethernet")
        XCTAssertNil(r.hypotheses.first { $0.cause == .ethernetNegotiation })
    }

    func testEthernetNegotiatedAt100() {
        let i = DiagnosticInput(connection: connection(kind: .ethernet, media: "autoselect (100baseTX <half-duplex>)"))
        XCTAssertEqual(DiagnosticsEngine.analyze(i).hypotheses.first { $0.cause == .ethernetNegotiation }?.confidence, .high)
    }

    /// Scenario: aucun réseau.
    func testNoNetwork() {
        let c = ConnectionSnapshot(isConnected: false, primaryInterface: nil, interfaces: [], defaultGatewayIPv4: nil,
                                   defaultGatewayIPv6: nil, dns: nil, vpnActive: false, vpnInterfaces: [], proxy: nil)
        let r = DiagnosticsEngine.analyze(DiagnosticInput(connection: c))
        XCTAssertEqual(r.hypotheses.first?.cause, .localConfig)
        XCTAssertTrue(r.hypotheses.contains { $0.cause == .insufficientData })
    }

    func testSelfAssignedAddress() {
        let r = DiagnosticsEngine.analyze(DiagnosticInput(connection: connection(kind: .wifi, gateway: nil, ip: "169.254.3.4")))
        XCTAssertTrue(r.hypotheses.first { $0.cause == .localConfig }!.supporting.contains { $0.contains("169.254") })
    }

    /// Scenario: Internet inaccessible mais réseau local présent.
    func testInternetDownLocalUp() {
        let i = DiagnosticInput(connection: connection(kind: .wifi), wifi: wifiSnapshot(rssi: -55, noise: -95),
                                gatewayLatency: lat("gw", [2, 3, 2, 3]),
                                externalLatency: [lat("1.1.1.1", [], sent: 10), lat("9.9.9.9", [], sent: 10)])
        let h = DiagnosticsEngine.analyze(i).hypotheses.first { $0.cause == .externalProblem }
        XCTAssertNotNil(h)
        XCTAssertEqual(h?.confidence, .medium, "never high: no proof of a precise ISP fault")
        XCTAssertTrue(h!.recommendations.first!.detail.contains("sans preuve"))
    }

    /// Scenario: DNS inaccessible.
    func testDNSUnreachable() {
        let dns = (0..<6).map { _ in DNSQueryResult(resolver: "192.168.1.254", name: "apple.com", success: false, responseCode: nil, durationMs: nil, answers: [], error: "timeout") }
        let i = DiagnosticInput(connection: connection(kind: .wifi), externalLatency: [lat("1.1.1.1", [12, 13, 12])], dnsResults: dns)
        let h = DiagnosticsEngine.analyze(i).hypotheses.first { $0.cause == .dnsProblem }
        XCTAssertEqual(h?.confidence, .high)
        XCTAssertTrue(h!.supporting.contains { $0.contains("sans réponse") })
        XCTAssertTrue(h!.recommendations.first!.detail.contains("ne modifie jamais"))
    }

    func testBufferbloatNeedsThreeTests() {
        let t = SpeedTestResult(mode: .full, engine: .networkQuality, downloadBps: 300e6, idleLatencyMs: 15, downloadLoadedLatencyMs: 140)
        let one = DiagnosticsEngine.analyze(DiagnosticInput(speedTests: [t])).hypotheses.first { $0.cause == .bufferbloat }
        XCTAssertEqual(one?.confidence, .low)
        let three = DiagnosticsEngine.analyze(DiagnosticInput(speedTests: [t, t, t])).hypotheses.first { $0.cause == .bufferbloat }
        XCTAssertEqual(three?.confidence, .high)
    }

    func testWANLimitedWithRouterSync() {
        let t = SpeedTestResult(mode: .full, engine: .networkQuality, downloadBps: 95e6)
        var wan = WANStatus(); wan.syncDownBps = 100e6
        let i = DiagnosticInput(connection: connection(kind: .ethernet), speedTests: [t], wan: wan)
        XCTAssertEqual(DiagnosticsEngine.analyze(i).hypotheses.first { $0.cause == .wanLimited }?.confidence, .high)
    }

    /// Scenario: VPN actif.
    func testVPNHypothesis() {
        let a = SpeedTestResult(mode: .quick, engine: .networkQuality, downloadBps: 50e6, vpnActive: true)
        let b = SpeedTestResult(mode: .quick, engine: .networkQuality, downloadBps: 300e6, vpnActive: false)
        let h = DiagnosticsEngine.analyze(DiagnosticInput(connection: connection(kind: .wifi, vpn: true), speedTests: [a, b])).hypotheses.first { $0.cause == .vpnProxy }
        XCTAssertEqual(h?.confidence, .medium)
    }

    func testInterferenceAndChannelAdvice() {
        let neighbors = (0..<6).map { WiFiNeighbor(ssid: "N\($0)", bssid: "00:00:00:00:00:0\($0)", rssi: -60, noise: nil, channel: 6, band: .ghz2_4, channelWidthMHz: 20, security: .wpa2Personal) }
            + [WiFiNeighbor(ssid: "far", bssid: "00:00:00:00:01:00", rssi: -85, noise: nil, channel: 11, band: .ghz2_4, channelWidthMHz: 20, security: nil)]
        let i = DiagnosticInput(connection: connection(kind: .wifi), wifi: wifiSnapshot(rssi: -55, noise: -80), neighbors: neighbors)
        let h = DiagnosticsEngine.analyze(i).hypotheses.first { $0.cause == .interference }
        XCTAssertNotNil(h)
        XCTAssertTrue(h!.recommendations.contains { $0.title.contains("canal 1") })
        let adv = ChannelAdvisor.recommend(band: .ghz5, neighbors: [], excludingBSSID: nil, current: 36)!
        XCTAssertEqual(adv.recommendedWidthMHz, 80, "never blindly 160 MHz")
        XCTAssertEqual(ChannelAdvisor.recommend(band: .ghz2_4, neighbors: [], excludingBSSID: nil, current: 6)!.recommendedWidthMHz, 20)
    }

    func testIntermittentDisconnects() {
        let ev = (0..<4).map { NetworkEvent(kind: .connectivityLost, message: "drop \($0)") }
        XCTAssertNotNil(DiagnosticsEngine.analyze(DiagnosticInput(events24h: ev)).hypotheses.first { $0.cause == .intermittentDisconnects })
    }

    func testAssistantAndOptimization() {
        let i = DiagnosticInput(connection: connection(kind: .wifi), wifi: wifiSnapshot(rssi: -78, noise: -90),
                                speedTests: Array(repeating: SpeedTestResult(mode: .full, engine: .networkQuality, downloadBps: 100e6, idleLatencyMs: 10, downloadLoadedLatencyMs: 150), count: 3))
        let r = DiagnosticsEngine.analyze(i)
        XCTAssertEqual(LocalAssistant.Question.match("Pourquoi mon ping est élevé ?"), .goodSpeedHighPing)
        XCTAssertEqual(LocalAssistant.Question.match("mes appels Teams coupent"), .videoCallsDrop)
        let a = LocalAssistant.answer(.goodSpeedHighPing, report: r)
        XCTAssertTrue(a.hypotheses.contains { $0.cause == .bufferbloat })
        XCTAssertFalse(a.facts.isEmpty)
        let plan = OptimizationCenter.plan(from: r)
        XCTAssertTrue(plan.latency.contains { $0.id == "enable-sqm" })
        XCTAssertTrue(plan.throughput.contains { $0.id == "move-closer" })
        let ctx = LocalAssistant.structuredContext(r, redactor: PrivacyRedactor(enabled: true))
        XCTAssertFalse("\(ctx)".contains("192.168.1.254"), "redacted before any optional AI transmission")
    }
}

final class ScoringTests: XCTestCase {
    func testMissingDimensionsAreExcludedNotAssumedGood() {
        let s = QualityScorer.compute(ScoringInput(wifi: wifiSnapshot(rssi: -50, noise: -95)))
        XCTAssertEqual(s.global!, 100, accuracy: 0.01)
        XCTAssertEqual(s.confidence, .low, "only radio measured")
        XCTAssertNil(s.subScores.first { $0.dimension == .internet }?.score)
        XCTAssertNil(QualityScorer.compute(ScoringInput()).global)
    }

    func testFullScore() {
        let t = SpeedTestResult(timestamp: Date(), mode: .full, engine: .networkQuality, downloadBps: 900e6, uploadBps: 500e6, idleLatencyMs: 10, downloadLoadedLatencyMs: 20)
        let dns = (0..<5).map { _ in DNSQueryResult(resolver: "1.1.1.1", name: "a", success: true, responseCode: 0, durationMs: 15, answers: [], error: nil) }
        let s = QualityScorer.compute(ScoringInput(isWired: true, latestSpeedTest: t, contractedDownBps: 1e9, gatewayLatency: lat("gw", [0.5, 0.6]),
                                                   internetLatency: lat("1.1.1.1", [9, 10, 9]), dnsResults: dns, disconnectsLast24h: 0, securityScore: 100))
        XCTAssertGreaterThan(s.global!, 90)
        XCTAssertEqual(s.confidence, .high)
        XCTAssertEqual(s.subScores.count, 6)
    }
}

final class BufferbloatTests: XCTestCase {
    func testGradesAndVerdict() {
        let t = (0..<3).map { _ in BufferbloatTrial(target: "1.1.1.1", idleMs: [10, 11, 10, 12], downloadLoadedMs: [40, 45, 50], uploadLoadedMs: [200, 220, 240]) }
        let r = BufferbloatAnalyzer.analyze(t)
        XCTAssertEqual(r.download.grade, .b)
        XCTAssertEqual(r.upload.grade, .d)
        XCTAssertEqual(r.overallGrade, .d)
        XCTAssertEqual(r.confidence, .high)
        XCTAssertTrue(r.verdict.contains("montante"))
        XCTAssertTrue(BloatGrade.f < BloatGrade.aPlus)
    }

    func testComparisonRequiresEvidence() {
        XCTAssertEqual(CampaignComparison.compare(metric: "lat", before: [100, 110], after: [20, 25], lowerIsBetter: true).outcome, .insufficientData)
        XCTAssertEqual(CampaignComparison.compare(metric: "lat", before: [100, 110, 105, 120], after: [20, 25, 22, 24], lowerIsBetter: true).outcome, .improved)
        XCTAssertEqual(CampaignComparison.compare(metric: "dl", before: [100, 200, 150], after: [120, 190, 160], lowerIsBetter: false).outcome, .noSignificantChange)
        XCTAssertEqual(CampaignComparison.compare(metric: "dl", before: [300, 310, 305], after: [100, 110, 105], lowerIsBetter: false).outcome, .degraded)
    }
}

final class HealthTests: XCTestCase {
    func sample(_ t: Double, gw: Bool?, inet: Bool, dns: Bool? = true, iface: String = "en0") -> HealthSample {
        HealthSample(timestamp: Date(timeIntervalSince1970: t), interface: iface, gatewayReachable: gw, gatewayRTTms: gw == true ? 2 : nil,
                     internetReachable: inet, internetRTTms: inet ? 20 : nil, internetLossPercent: inet ? 0 : 100, dnsOK: dns, dnsMs: 10)
    }

    func testOutageClassification() {
        var d = OutageDetector(threshold: 2)
        XCTAssertEqual(d.ingest(sample(0, gw: true, inet: true)), .none)
        XCTAssertEqual(d.ingest(sample(60, gw: true, inet: false)), .none, "single failure is not an outage")
        guard case .started(let o) = d.ingest(sample(120, gw: true, inet: false)) else { return XCTFail() }
        XCTAssertEqual(o.kind, .internet); XCTAssertEqual(o.start, Date(timeIntervalSince1970: 60))
        guard case .ended(let e) = d.ingest(sample(180, gw: true, inet: true)) else { return XCTFail() }
        XCTAssertEqual(e.duration, 120)

        var l = OutageDetector(threshold: 1)
        guard case .started(let lo) = l.ingest(sample(0, gw: false, inet: false)) else { return XCTFail() }
        XCTAssertEqual(lo.kind, .local)
        var dn = OutageDetector(threshold: 2)
        _ = dn.ingest(sample(0, gw: true, inet: true, dns: false))
        guard case .started(let x) = dn.ingest(sample(60, gw: true, inet: true, dns: false)) else { return XCTFail() }
        XCTAssertEqual(x.kind, .dnsOnly)
    }

    func testReport() {
        var s = (0..<60).map { sample(Double($0) * 60, gw: true, inet: true) }
        s[10] = sample(600, gw: true, inet: false); s[11] = sample(660, gw: true, inet: false)
        s[30] = sample(1800, gw: true, inet: true, iface: "en5")
        let r = HealthAnalyzer.report(samples: s, from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 3600))
        XCTAssertEqual(r.outages.count, 1)
        XCTAssertEqual(r.totalDowntime, 120)
        XCTAssertEqual(r.availabilityPercent!, 100 * (1 - 120.0 / 3600), accuracy: 0.001)
        XCTAssertEqual(r.interfaceChanges, 2)
    }

    /// Scenario: changement de route / passerelle / DNS.
    func testBaselineChanges() {
        let b = NetworkBaseline(networkKey: "Maison", gatewayIP: "192.168.1.254", gatewayMAC: "00:24:d4:0a:0b:0c", dnsServers: ["192.168.1.254"], knownBSSIDs: [], updated: Date())
        var c = b; c.gatewayMAC = "00:11:22:33:44:55"; c.dnsServers = ["1.1.1.1"]
        let ev = ChangeDetector.diff(baseline: b, current: c)
        XCTAssertEqual(ev.map(\.kind), [.gatewayChanged, .dnsChanged])
        XCTAssertTrue(ev[0].message.contains("à vérifier"), "suspicion, never a conclusion")
        var other = c; other.networkKey = "Bureau"
        XCTAssertTrue(ChangeDetector.diff(baseline: b, current: other).isEmpty, "different network: no alert")
    }
}

final class DeviceInventoryTests: XCTestCase {
    /// Scenario: appareil détecté plusieurs fois (ARP + Bonjour + routeur).
    func testDeduplicationAcrossSources() {
        var inv = DeviceInventory()
        let r1 = inv.merge([DeviceObservation(method: .arpCache, ip: "192.168.1.10", mac: "3C:22:FB:12:34:56")], gatewayIP: "192.168.1.254", oui: OUIDatabase())
        XCTAssertEqual(r1.newDevices.count, 1)
        let r2 = inv.merge([DeviceObservation(method: .bonjour, ip: "192.168.1.10", hostname: "MacBook-Pro.local", services: ["_ssh._tcp", "_workstation._tcp"]),
                            DeviceObservation(method: .router, ip: "192.168.1.10", mac: "3c:22:fb:12:34:56", hostname: "MacBook-Pro", vendorHint: "Apple, Inc.", modelHint: "workstation", routerActive: true)],
                           gatewayIP: "192.168.1.254", oui: OUIDatabase())
        XCTAssertEqual(r2.newDevices.count, 0)
        XCTAssertEqual(inv.devices.count, 1)
        let d = inv.devices[0]
        XCTAssertEqual(Set(d.methods), [.arpCache, .bonjour, .router])
        XCTAssertEqual(d.category, .computer); XCTAssertEqual(d.categoryConfidence, .high)
        XCTAssertEqual(d.vendor, "Apple, Inc."); XCTAssertEqual(d.vendorProvenance?.category, .router)
        XCTAssertEqual(d.observationState(), .reportedByRouter)
    }

    func testRandomizedMACAndNoInventedIdentity() {
        var inv = DeviceInventory()
        let oui = OUIDatabase.parseIEEECSV("Registry,Assignment,Organization Name,Organization Address\nMA-L,7A1B2C,\"Should Not Match\",x\nMA-L,0024D4,\"FREEBOX SAS\",\"8 rue, Paris\"\n")
        inv.merge([DeviceObservation(method: .arpCache, ip: "192.168.1.31", mac: "7a:1b:2c:3d:4e:5f"),
                   DeviceObservation(method: .arpCache, ip: "192.168.1.254", mac: "00:24:d4:0a:0b:0c")], gatewayIP: "192.168.1.254", oui: oui)
        let phone = inv.devices.first { $0.ipv4 == "192.168.1.31" }!
        XCTAssertTrue(phone.isRandomizedMAC)
        XCTAssertNil(phone.vendor, "randomized MAC: no vendor lookup")
        XCTAssertEqual(phone.category, .unknown); XCTAssertEqual(phone.categoryConfidence, .none)
        XCTAssertEqual(phone.displayName, "192.168.1.31")
        let gw = inv.devices.first { $0.ipv4 == "192.168.1.254" }!
        XCTAssertEqual(gw.category, .router)
        XCTAssertEqual(gw.vendor, "FREEBOX SAS"); XCTAssertEqual(gw.vendorProvenance?.category, .estimated)
    }

    /// Scenario: appareil non joignable ≠ déconnecté.
    func testNotRespondingIsNotDisconnected() {
        let old = Date(timeIntervalSinceNow: -7200)
        var inv = DeviceInventory()
        inv.merge([DeviceObservation(method: .arpCache, timestamp: old, ip: "192.168.1.40", mac: "00:11:22:33:44:55")], gatewayIP: nil, oui: OUIDatabase())
        XCTAssertEqual(inv.devices[0].observationState(), .notRecentlySeen)
        XCTAssertNotEqual(inv.devices[0].observationState().rawValue.lowercased(), "déconnecté")
    }

    func testLabelsTrustSearch() {
        var inv = DeviceInventory()
        inv.merge([DeviceObservation(method: .arpCache, ip: "192.168.1.50", mac: "00:11:22:33:44:66")], gatewayIP: nil, oui: OUIDatabase())
        let id = inv.devices[0].id
        inv.setLabel("Imprimante bureau", for: id); inv.setTrust(.known, for: id)
        XCTAssertEqual(inv.search("imprimante").count, 1)
        XCTAssertTrue(inv.unknownDevices.isEmpty)
        inv.setLabel("  ", for: id); XCTAssertNil(inv.devices[0].userLabel)
    }

    func testSameIPDifferentMACIsAnotherDevice() {
        var inv = DeviceInventory()
        inv.merge([DeviceObservation(method: .arpCache, ip: "192.168.1.60", mac: "00:11:22:33:44:01")], gatewayIP: nil, oui: OUIDatabase())
        inv.merge([DeviceObservation(method: .arpCache, ip: "192.168.1.60", mac: "00:11:22:33:44:02")], gatewayIP: nil, oui: OUIDatabase())
        XCTAssertEqual(inv.devices.count, 2)
    }

    func testActiveProbeValidation() throws {
        let local = [IPv4Assignment(address: "192.168.1.23", netmask: "255.255.255.0")]
        XCTAssertNoThrow(try NeighborDiscoveryService.validateProbe(subnet: IPv4Subnet(cidr: "192.168.1.0/24")!, localAssignments: local))
        XCTAssertThrowsError(try NeighborDiscoveryService.validateProbe(subnet: IPv4Subnet(cidr: "8.8.8.0/24")!, localAssignments: local))
        XCTAssertThrowsError(try NeighborDiscoveryService.validateProbe(subnet: IPv4Subnet(cidr: "10.0.0.0/16")!, localAssignments: local))
        XCTAssertThrowsError(try NeighborDiscoveryService.validateProbe(subnet: IPv4Subnet(cidr: "192.168.2.0/24")!, localAssignments: local))
    }
}

final class SecurityNATTests: XCTestCase {
    func testSecurityStatuses() {
        let w = RouterWiFiReport(networks: [RouterWiFiNetwork(ssid: "Box", band: "5G", channel: 36, channelWidthMHz: 80, encryption: "wpa2_psk_ccmp", enabled: true, hidden: false, wpsEnabled: true, isGuest: false)],
                                 guestNetworkEnabled: nil, macFilterMode: "disabled")
        let r = SecurityAuditor.audit(SecurityAuditInput(currentWiFiSecurity: .wep, routerWiFi: w, routerInfo: RouterInfo(adapterID: "freebox", firmware: "4.8.1")))
        XCTAssertEqual(r.findings.first { $0.id == "wifi-obsolete" }?.status, .suspect)
        XCTAssertTrue(r.findings.contains { $0.id.hasPrefix("router-wps") && $0.status == .suspect })
        XCTAssertEqual(r.findings.first { $0.id == "firmware" }?.status, .notVerified, "no CVE database: never claims verified")
        XCTAssertEqual(r.findings.first { $0.id == "guest" }?.status, .unavailable)
        XCTAssertNotNil(r.score)
    }

    func testIPv6LeakHeuristic() {
        var c = connection(kind: .wifi, vpn: true)
        c.interfaces[0].ipv6 = ["2001:db8::23"]; c.defaultGatewayIPv6 = "fe80::1"
        let r = SecurityAuditor.audit(SecurityAuditInput(connection: c))
        XCTAssertEqual(r.findings.first { $0.id == "ipv6-leak" }?.status, .suspect)
    }

    func testNAT() throws {
        let hops = TracerouteParser.parse(try fixture("traceroute_macos.txt"))
        let a = NATAnalyzer.assess(localIP: "192.168.1.23", gatewayIP: "192.168.1.254", routerWANIP: nil, publicIP: nil, traceroute: hops)
        XCTAssertEqual(a.doubleNAT, .suspected); XCTAssertEqual(a.cgnat, .suspected)
        let b = NATAnalyzer.assess(localIP: nil, gatewayIP: nil, routerWANIP: "100.70.1.2", publicIP: nil, traceroute: [])
        XCTAssertEqual(b.cgnat, .verified)
        XCTAssertTrue(b.limitations.contains { $0.contains("console") })
        XCTAssertEqual(NATAnalyzer.assess(localIP: nil, gatewayIP: nil, routerWANIP: "203.0.113.4", publicIP: "203.0.113.4", traceroute: []).cgnat, .notDetected)
    }

    func testGaming() {
        let g = GamingAnalyzer.assess([lat("srv", [15, 16, 15, 17, 80, 16, 15])], loadedAddedMs: 90)
        XCTAssertEqual(g.targets[0].spikes, 1)
        XCTAssertTrue(g.risks.contains { $0.contains("chargé") })
        XCTAssertEqual(GamingAnalyzer.assess([lat("x", [], sent: 5)], loadedAddedMs: nil).competitive, .unknown)
    }
}

final class HeatmapISPTests: XCTestCase {
    func testInterpolationNeverExtrapolates() {
        var p = HeatmapProject(name: "T", widthMeters: 10, heightMeters: 4)
        p.samples = [HeatmapSample(position: Point2D(x: 1, y: 1), rssi: -50, noise: -90, channel: 36, band: .ghz5, bssid: nil, txRateMbps: 800, gatewayLatencyMs: 2, routerPlacement: "A"),
                     HeatmapSample(position: Point2D(x: 3, y: 1), rssi: -70, noise: -90, channel: 36, band: .ghz5, bssid: nil, txRateMbps: 200, gatewayLatencyMs: 4, routerPlacement: "A")]
        let g = HeatmapEngine.interpolate(p, metric: .rssi, placement: "A", cellMeters: 1, maxRadius: 2)
        XCTAssertNotNil(g.value(col: 1, row: 1))
        XCTAssertNil(g.value(col: 9, row: 3), "far from any sample → unmeasured")
        let mid = g.value(col: 2, row: 1)!
        XCTAssertTrue(mid < -50 && mid > -70)
        XCTAssertLessThan(g.measuredFraction, 1)
        p.samples.append(HeatmapSample(position: Point2D(x: 8, y: 3), rssi: -82, noise: -90, channel: 36, band: .ghz5, bssid: nil, txRateMbps: 30, gatewayLatencyMs: 20, routerPlacement: "A"))
        p.routerPositions["A"] = Point2D(x: 0, y: 0)
        let sug = HeatmapEngine.suggestAccessPoints(p, placement: "A", max: 1)
        XCTAssertEqual(sug.count, 1); XCTAssertGreaterThan(sug[0].x, 4)
        XCTAssertEqual(HeatmapProject.pixelsPerMeter(p1: Point2D(x: 0, y: 0), p2: Point2D(x: 300, y: 400), meters: 5), 100)
    }

    func testSimulationIsLabeled() {
        let p = HeatmapProject(name: "T", widthMeters: 10, heightMeters: 10, walls: [Wall(a: Point2D(x: 5, y: 0), b: Point2D(x: 5, y: 10), material: .concrete)])
        let s = NetworkSimulator.addAccessPoint(project: p, apPosition: Point2D(x: 1, y: 5), client: Point2D(x: 9, y: 5))
        XCTAssertTrue(s.disclaimer.contains("pas une mesure réelle"))
        XCTAssertTrue(s.assumptions.contains { $0.contains("1 mur") })
        XCTAssertEqual(NetworkSimulator.predictedRSSI(distanceMeters: 10), -65, accuracy: 0.01)
    }

    func testISPAudit() {
        let cal = Calendar(identifier: .gregorian)
        func t(_ hour: Int, _ dl: Double, iface: String) -> SpeedTestResult {
            var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 10; c.hour = hour
            return SpeedTestResult(timestamp: cal.date(from: c)!, mode: .full, engine: .networkQuality, interfaceName: iface, downloadBps: dl, uploadBps: 100e6)
        }
        let tests = [t(9, 900e6, iface: "en5"), t(10, 880e6, iface: "en5"), t(21, 400e6, iface: "en5"), t(22, 380e6, iface: "en5"), t(14, 300e6, iface: "en0")]
        let a = ISPAuditor.audit(profile: ISPProfile(provider: "Op", plan: "Fibre 1G", advertisedDownBps: 1e9, guaranteedDownBps: 500e6),
                                 tests: tests, ethernetInterfaces: ["en5"], outages: [], calendar: cal)
        XCTAssertEqual(a.ethernetTests, 4)
        XCTAssertEqual(a.testsBelowGuaranteed, 2)
        XCTAssertLessThan(a.peakVsOffPeak!, 0.7)
        XCTAssertTrue(a.findings.contains { $0.contains("heures de pointe") })
        XCTAssertTrue(a.remainingChecks.contains { $0.contains("10 tests") })
        XCTAssertTrue(a.disclaimer.contains("sans constituer"))
    }

    func testSegmentLocalizer() {
        let v = SegmentLocalizer.localize(SegmentMeasurements(macWiFiInternetDownBps: 120e6, agentWiredInternetDownBps: 900e6, lanThroughputBps: 940e6, routerSyncDownBps: 1e9))
        XCTAssertEqual(v.first { $0.segment.contains("Wi-Fi") }?.suspected, true)
        XCTAssertEqual(v.first { $0.segment.contains("LAN") }?.suspected, false)
        XCTAssertEqual(v.first { $0.segment.contains("WAN") }?.suspected, true)
    }
}

final class ReportingStorageTests: XCTestCase {
    func testPrivacyRedaction() {
        let r = PrivacyRedactor(enabled: true, ssids: ["MaBox-1234"])
        let s = r.redact("SSID MaBox-1234 via 192.168.1.254 (00:24:d4:0a:0b:0c) et 2001:db8::23")
        XCTAssertFalse(s.contains("192.168")); XCTAssertFalse(s.contains("MaBox")); XCTAssertFalse(s.contains("00:24:d4"))
        XCTAssertFalse(s.contains("2001:db8"))
        XCTAssertEqual(PrivacyRedactor(enabled: false).redact("1.2.3.4"), "1.2.3.4")
    }

    func testCSVEscapingAndFormulaInjection() {
        XCTAssertEqual(CSV.escape("a,b"), "\"a,b\"")
        XCTAssertEqual(CSV.escape("=HYPERLINK(\"x\")"), "\"'=HYPERLINK(\"\"x\"\")\"")
        XCTAssertEqual(CSV.escape("-12.5"), "-12.5")
        XCTAssertEqual(CSV.parseLine("a,\"b,c\",\"d\"\"e\""), ["a", "b,c", "d\"e"])
        let csv = CSVExport.speedTests([SpeedTestResult(mode: .quick, engine: .networkQuality, downloadBps: 1e8)])
        XCTAssertTrue(csv.hasPrefix("timestamp,mode"))
        XCTAssertTrue(csv.contains("100000000"))
    }

    func testReportRenderers() throws {
        let d = DiagnosticsEngine.analyze(DiagnosticInput(connection: connection(kind: .wifi), wifi: wifiSnapshot(rssi: -80, noise: -90)))
        let rep = ReportBuilder.diagnostic(d, tests: [], network: "Maison").redacted(PrivacyRedactor(enabled: true, ssids: ["Maison"]))
        let html = rep.html(); let md = rep.markdown()
        XCTAssertTrue(html.contains("<h2>Méthode et limites</h2>"))
        XCTAssertFalse(html.contains("192.168.1.254"))
        XCTAssertTrue(md.contains("## Hypothèse : Signal Wi-Fi insuffisant"))
        XCTAssertNoThrow(try rep.json())
        XCTAssertFalse(Report(title: "<script>", subtitle: "", sections: []).html().contains("<script>"))
    }

    /// Scenario: historique vide puis corrompu.
    func testHistoryStoreLifecycleAndCorruption() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nsp-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("history.sqlite")
        do {
            let store = try HistoryStore(url: url)
            XCTAssertEqual(try store.load(SpeedTestResult.self, kind: .speedTest).items.count, 0)
            let t = SpeedTestResult(timestamp: Date(timeIntervalSince1970: 1000), mode: .quick, engine: .networkQuality, downloadBps: 1e8)
            try store.save(t, kind: .speedTest, id: t.id.uuidString, timestamp: t.timestamp, network: "Maison")
            try store.save(t, kind: .speedTest, id: UUID().uuidString, timestamp: Date(timeIntervalSince1970: 5000), network: "Bureau")
            XCTAssertEqual(try store.load(SpeedTestResult.self, kind: .speedTest).items.count, 2)
            XCTAssertEqual(try store.load(SpeedTestResult.self, kind: .speedTest, network: "Maison").items.first?.downloadBps, 1e8)
            XCTAssertEqual(try store.load(SpeedTestResult.self, kind: .speedTest, from: Date(timeIntervalSince1970: 2000)).items.count, 1)
            // Undecodable row is skipped, not fatal.
            try store.save(["garbage": 1], kind: .speedTest, timestamp: Date(timeIntervalSince1970: 3000))
            let res = try store.load(SpeedTestResult.self, kind: .speedTest)
            XCTAssertEqual(res.items.count, 2); XCTAssertEqual(res.skipped, 1)
            XCTAssertEqual(try store.purge(kind: .speedTest, olderThan: Date(timeIntervalSince1970: 4000)), 2)
            try store.eraseAll()
            XCTAssertEqual(try store.count(kind: .speedTest), 0)
        }
        // Corrupt the file.
        try FileManager.default.removeItem(at: url)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        try Data(repeating: 0x42, count: 8192).write(to: url)
        let recovered = try HistoryStore(url: url)
        XCTAssertNotNil(recovered.recoveredFromCorruption)
        XCTAssertEqual(try recovered.count(kind: .speedTest), 0)
        try? FileManager.default.removeItem(at: dir)
    }
}

final class SecurityPrimitivesTests: XCTestCase {
    func testCommandInjectionIsRejected() {
        XCTAssertThrowsError(try ArgumentValidator.validate(.ping, ["-c", "3", "8.8.8.8;rm -rf /"]))
        XCTAssertThrowsError(try ArgumentValidator.validate(.ping, ["-c", "3", "-f", "8.8.8.8"]))
        XCTAssertThrowsError(try ArgumentValidator.validate(.ping, ["-c", "99999", "8.8.8.8"]))
        XCTAssertThrowsError(try ArgumentValidator.validate(.traceroute, ["--", "host"]))
        XCTAssertThrowsError(try ArgumentValidator.validate(.networkQuality, ["-I", "en0; ls"]))
        XCTAssertNoThrow(try ArgumentValidator.validate(.ping, ["-n", "-c", "5", "-i", "0.2", "-W", "1000", "fe80::1%en0"]))
        XCTAssertNoThrow(try ArgumentValidator.validate(.networkQuality, ["-c", "-s", "-I", "en0"]))
        XCTAssertFalse(ArgumentValidator.isValidHost("-oProxyCommand"))
        XCTAssertFalse(ArgumentValidator.isValidHost("a b"))
    }

    func testRunnerRefusesBeforeExecution() async {
        let r = RecordedCommandRunner()
        do { _ = try await r.run(.ping, ["$(whoami)"], timeout: 1); XCTFail() } catch {}
        XCTAssertTrue(r.invocations.isEmpty, "validation happens before any process is spawned")
    }

    func testRealProcessRunnerTimeoutAndMissingTool() async throws {
        let runner = ProcessCommandRunner()
        if !runner.isAvailable(.iperf3) {
            do { _ = try await runner.run(.iperf3, ["--version"], timeout: 2); XCTFail() }
            catch { XCTAssertEqual(error as? CommandError, .toolNotFound(.iperf3)) }
        }
    }

    /// RFC 2202 HMAC-SHA1 test vectors (used by the Freebox login).
    func testHMACSHA1() {
        XCTAssertEqual(SHA1.hex(SHA1.hash(Array("abc".utf8))), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(SHA1.hex(SHA1.hmac(key: [UInt8](repeating: 0x0b, count: 20), message: Array("Hi There".utf8))),
                       "b617318655057264e28bc0b6fb378c8ef146be00")
        XCTAssertEqual(SHA1.hex(SHA1.hmac(key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8))),
                       "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79")
        XCTAssertEqual(SHA1.hex(SHA1.hmac(key: [UInt8](repeating: 0xaa, count: 80), message: Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8))),
                       "aa4ae5e15272d00e95705637ce8a3b55ed402112")
    }

    func testDNSWireFormat() throws {
        let q = try DNSMessage.query(id: 0x1234, name: "apple.com", type: .a)
        XCTAssertEqual(Array(q[0..<2]), [0x12, 0x34])
        var expected: [UInt8] = [5]
        expected += Array("apple".utf8); expected.append(3); expected += Array("com".utf8); expected += [0, 0, 1, 0, 1]
        XCTAssertEqual(Array(q[12...]), expected)
        XCTAssertThrowsError(try DNSMessage.encodeName("bad..name"))
        XCTAssertThrowsError(try DNSMessage.encodeName(String(repeating: "a", count: 64) + ".com"))
        // Response: header + question + one A answer using a compression pointer.
        var resp: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0]
        resp += Array(q[12...])
        resp += [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 17, 253, 144, 10]
        let r = try DNSMessage.parse(resp)
        XCTAssertEqual(r.id, 0x1234); XCTAssertEqual(r.rcode, 0); XCTAssertEqual(r.answers, ["17.253.144.10"])
        XCTAssertThrowsError(try DNSMessage.parse([0, 1, 0]))
        XCTAssertEqual(DNSMessage.rcodeLabel(3), "NXDOMAIN")
    }

    func testThroughputCounterWrap() {
        let a = InterfaceCounters(timestamp: Date(timeIntervalSince1970: 0), interface: "en0", bytesIn: UInt64(UInt32.max) - 999, bytesOut: 0)
        let b = InterfaceCounters(timestamp: Date(timeIntervalSince1970: 1), interface: "en0", bytesIn: 1000, bytesOut: 125)
        let s = ThroughputCalculator.rate(a, b)!
        XCTAssertEqual(s.inBps, 2000 * 8); XCTAssertEqual(s.outBps, 1000)
        XCTAssertNil(ThroughputCalculator.rate(b, InterfaceCounters(timestamp: Date(timeIntervalSince1970: 0.5), interface: "en0", bytesIn: 0, bytesOut: 0)))
        let rates = ProcessTrafficService.rates(previous: [ProcessTrafficSample(process: "a", pid: 1, bytesIn: 100, bytesOut: 0)],
                                                current: [ProcessTrafficSample(process: "a", pid: 1, bytesIn: 1100, bytesOut: 0),
                                                          ProcessTrafficSample(process: "new", pid: 2, bytesIn: 5000, bytesOut: 0)], seconds: 1)
        XCTAssertEqual(rates.count, 1, "a process absent from the previous sample cannot be attributed traffic")
        XCTAssertEqual(rates[0].inBps, 8000)
    }
}
