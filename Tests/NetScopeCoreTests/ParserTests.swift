import XCTest
@testable import NetScopeCore

func fixture(_ name: String) throws -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        ?? Bundle.module.url(forResource: (name as NSString).deletingPathExtension, withExtension: (name as NSString).pathExtension, subdirectory: "Fixtures")
    else { throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing \(name)"]) }
    return try String(contentsOf: url, encoding: .utf8)
}

final class ParserTests: XCTestCase {
    func testNetworkQualityFullJSON() throws {
        let r = try NetworkQualityParser.parse(try fixture("networkquality_macos14.json"), mode: .full, sequential: false)
        XCTAssertEqual(r.downloadBps, 412_345_678)
        XCTAssertEqual(r.uploadBps, 51_234_567)
        XCTAssertEqual(r.idleLatencyMs!, 18.517, accuracy: 0.001)
        XCTAssertEqual(r.downloadLoadedLatencyMs, 120)
        XCTAssertEqual(r.uploadLoadedLatencyMs, 230)
        XCTAssertEqual(r.worstLoadedLatencyMs, 230)
        XCTAssertEqual(r.responsivenessRPM!, 433.8, accuracy: 0.01)
        XCTAssertEqual(r.interfaceName, "en0")
        XCTAssertEqual(r.server, "mad-edge-1.example.net")
        XCTAssertEqual(r.tlsHandshakeMs!, 29.75, accuracy: 0.01)
        XCTAssertEqual(r.downloadFlows, 12)
        XCTAssertNotNil(r.jitterMs)
        XCTAssertTrue(r.missingFields.isEmpty, "\(r.missingFields)")
        XCTAssertNil(r.packetLossPercent, "networkQuality does not report loss: must stay nil, never invented")
    }

    /// Scenario: JSON incomplet (older macOS, warnings before JSON).
    func testNetworkQualityIncompleteJSON() throws {
        let r = try NetworkQualityParser.parse(try fixture("networkquality_macos12_minimal.txt"), mode: .quick, sequential: false)
        XCTAssertEqual(r.downloadBps, 95_000_000)
        XCTAssertNil(r.idleLatencyMs)
        XCTAssertNil(r.downloadLoadedLatencyMs)
        XCTAssertTrue(r.missingFields.contains("base_rtt"))
        XCTAssertTrue(r.succeeded)
    }

    func testNetworkQualityErrors() {
        XCTAssertThrowsError(try NetworkQualityParser.parse("not json", mode: .quick, sequential: false)) {
            XCTAssertEqual($0 as? NetworkQualityParseError, .notJSON)
        }
        XCTAssertThrowsError(try NetworkQualityParser.parse(#"{"error_code": -1009}"#, mode: .quick, sequential: false))
        XCTAssertThrowsError(try NetworkQualityParser.parse(#"{"interface_name":"en0"}"#, mode: .quick, sequential: false)) {
            XCTAssertEqual($0 as? NetworkQualityParseError, .emptyResult)
        }
    }

    func testNetworkQualityHelpFlags() {
        let help = """
        USAGE: networkQuality [-C <configuration_url>] [-c] [-d] [-I <interface>] [-s] [-u] [-v]
            -C: override Configuration URL or path
            -c: Produce computer-readable output
            -d: Do not run a download test (implies -s)
            -I: Bind test to interface
            -s: Run tests sequentially instead of parallel upload/download
            -u: Do not run an upload test (implies -s)
        """
        let f = NetworkQualityHelpParser.supportedFlags(help)
        XCTAssertEqual(f, ["-C", "-c", "-d", "-I", "-s", "-u"])
        let caps = SpeedTestCapabilities(available: true, flags: f)
        let svc = InternetSpeedTestService(runner: RecordedCommandRunner())
        XCTAssertEqual(svc.arguments(SpeedTestOptions(mode: .bufferbloat, downloadOnly: true, maxRuntimeSeconds: 10), caps: caps), ["-c", "-s", "-u"],
                       "-M must not be passed when unsupported")
    }

    func testPing() throws {
        let p = try XCTUnwrap(PingParser.parse(try fixture("ping_macos.txt")))
        XCTAssertEqual(p.transmitted, 4); XCTAssertEqual(p.received, 3)
        XCTAssertEqual(p.samplesMs, [3.456, 2.1, 4.0]); XCTAssertEqual(p.timeouts, [1])
        let s = LatencyStats(target: "gw", sent: p.transmitted, received: p.received, samplesMs: p.samplesMs, method: "t")
        XCTAssertEqual(s.lossPercent, 25)
        XCTAssertEqual(s.medianMs, 3.456)
        XCTAssertEqual(s.jitterMs!, (1.356 + 1.9) / 2, accuracy: 1e-9)
    }

    func testPingLinuxAndUnreachable() {
        let linux = "PING 10.0.0.1 (10.0.0.1) 56(84) bytes of data.\n64 bytes from 10.0.0.1: icmp_seq=1 ttl=64 time=0.5 ms\n\n--- 10.0.0.1 ping statistics ---\n2 packets transmitted, 1 received, 50% packet loss, time 1001ms\n"
        XCTAssertEqual(PingParser.parse(linux)?.received, 1)
        // Scenario: appareil non joignable → 100 % loss, still a measurement.
        let none = "PING 192.168.1.99 (192.168.1.99): 56 data bytes\nRequest timeout for icmp_seq 0\n\n--- 192.168.1.99 ping statistics ---\n1 packets transmitted, 0 packets received, 100.0% packet loss\n"
        let p = PingParser.parse(none)!
        XCTAssertEqual(LatencyStats(target: "x", sent: p.transmitted, received: p.received, samplesMs: p.samplesMs, method: "").lossPercent, 100)
        XCTAssertNil(PingParser.parse("ping: cannot resolve foo: Unknown host"))
    }

    func testRoutesAndVPN() throws {
        let routes = RouteTableParser.parse(try fixture("netstat_rn_macos.txt"))
        let gw = RouteTableParser.defaultGateway(routes, ipv6: false)
        XCTAssertEqual(gw?.gateway, "192.168.1.254"); XCTAssertEqual(gw?.interface, "en0")
        XCTAssertEqual(RouteTableParser.defaultGateway(routes, ipv6: true)?.interface, "en0", "scoped utun default must be ignored")

        // Scenario: VPN actif (old netstat format with Refs/Use columns, default via utun).
        let vpnRoutes = RouteTableParser.parse(try fixture("netstat_rn_vpn_default.txt"))
        XCTAssertEqual(RouteTableParser.defaultGateway(vpnRoutes, ipv6: false)?.interface, "utun4")
        let ifaces = IfconfigParser.parse(try fixture("ifconfig_macos.txt"), hardwarePorts: HardwarePortsParser.parse(try fixture("hardwareports.txt")))
        let snap = NetworkInterfaceService.assemble(interfaces: ifaces, routes: vpnRoutes, dns: nil, proxy: nil)
        XCTAssertTrue(snap.vpnActive)
        XCTAssertEqual(snap.vpnInterfaces, ["utun4"])
        XCTAssertEqual(snap.primaryInterface?.bsdName, "en0", "physical interface shown as primary")
        XCTAssertEqual(snap.defaultGatewayIPv4, "192.168.1.254")
    }

    func testIfconfigAndHardwarePorts() throws {
        let ports = HardwarePortsParser.parse(try fixture("hardwareports.txt"))
        XCTAssertEqual(ports["en0"], "Wi-Fi"); XCTAssertEqual(ports["en5"], "USB 10/100/1000 LAN")
        let ifs = IfconfigParser.parse(try fixture("ifconfig_macos.txt"), hardwarePorts: ports)
        let en0 = try XCTUnwrap(ifs.first { $0.bsdName == "en0" })
        XCTAssertEqual(en0.kind, .wifi)
        XCTAssertEqual(en0.ipv4.first?.address, "192.168.1.23")
        XCTAssertEqual(en0.ipv4.first?.netmask, "255.255.255.0")
        XCTAssertEqual(en0.ipv4.first?.subnet?.description, "192.168.1.0/24")
        XCTAssertEqual(en0.globalIPv6, ["2001:db8::23"])
        XCTAssertEqual(en0.macAddress, "3c:22:fb:aa:bb:cc")
        let en5 = try XCTUnwrap(ifs.first { $0.bsdName == "en5" })
        XCTAssertEqual(en5.kind, .ethernet); XCTAssertFalse(en5.isRunning)
        XCTAssertEqual(InterfaceClassifier.ethernetSpeedMbps(media: en5.media), 100)
        XCTAssertEqual(ifs.first { $0.bsdName == "utun4" }?.kind, .vpn)
        XCTAssertEqual(ifs.first { $0.bsdName == "lo0" }?.kind, .loopback)
    }

    func testScutil() throws {
        let dns = ScutilParser.parseDNS(try fixture("scutil_dns.txt"))
        XCTAssertEqual(dns.primaryNameservers, ["192.168.1.254", "fe80::1%en0"])
        XCTAssertEqual(dns.resolvers.first?.interface, "en0")
        XCTAssertEqual(dns.resolvers.filter(\.isScoped).count, 1)
        let proxy = ScutilParser.parseProxy(try fixture("scutil_proxy.txt"))
        XCTAssertEqual(proxy.enabled, [.https]); XCTAssertTrue(proxy.isActive)
    }

    func testNeighbors() throws {
        let arp = NeighborParser.parseARP(try fixture("arp_macos.txt"))
        XCTAssertEqual(arp.count, 6)
        XCTAssertTrue(arp.first { $0.ip == "192.168.1.20" }!.isIncomplete)
        XCTAssertEqual(arp.first { $0.ip == "192.168.1.254" }?.mac, "00:24:d4:0a:0b:0c")
        XCTAssertNil(arp.first { $0.ip == "192.168.1.255" }?.mac, "broadcast MAC rejected")
        let ndp = NeighborParser.parseNDP(try fixture("ndp_macos.txt"))
        XCTAssertEqual(ndp.count, 3)
        XCTAssertEqual(ndp[0].ip, "fe80::1")
        XCTAssertTrue(ndp[2].isIncomplete)
    }

    func testTracerouteIperfNettop() throws {
        let hops = TracerouteParser.parse(try fixture("traceroute_macos.txt"))
        XCTAssertEqual(hops.count, 6)
        XCTAssertTrue(hops[1].isPrivate); XCTAssertTrue(hops[2].isCGNAT)
        XCTAssertEqual(hops[3].timeouts, 2)
        XCTAssertEqual(hops[4].addresses, ["203.0.113.9", "203.0.113.10"])
        XCTAssertEqual(hops[4].rttsMs, [12.5, 13.1])

        let ip = IPerf3Parser.parse(try fixture("iperf3_client.json"))
        XCTAssertEqual(ip.receivedBps, 890_000_000); XCTAssertTrue(ip.reverse); XCTAssertEqual(ip.retransmits, 12)
        XCTAssertEqual(IPerf3Parser.parse(#"{"error":"unable to connect to server: Connection refused"}"#).error?.contains("refused"), true)

        let nt = NettopParser.parse(try fixture("nettop_macos.txt"))
        XCTAssertEqual(nt.count, 4)
        XCTAssertEqual(nt.first { $0.pid == 4567 }?.process, "Safari Networking")
        XCTAssertEqual(nt.first { $0.pid == 4567 }?.bytesIn, 98_765_432)
    }

    func testAddressUtilities() {
        XCTAssertEqual(IPv4.parse("192.168.1.1"), 0xC0A8_0101)
        XCTAssertNil(IPv4.parse("256.1.1.1")); XCTAssertNil(IPv4.parse("1.2.3")); XCTAssertNil(IPv4.parse("01.2.3.-4"))
        XCTAssertEqual(IPv4.parseMask("0xffffff00"), 24); XCTAssertEqual(IPv4.parseMask("255.255.252.0"), 22)
        XCTAssertNil(IPv4.parseMask("255.0.255.0"))
        XCTAssertTrue(IPv4.isCGNAT(IPv4.parse("100.72.1.1")!)); XCTAssertTrue(IPv4.isPrivate(IPv4.parse("172.20.0.1")!))
        XCTAssertFalse(IPv4.isPublic(IPv4.parse("10.0.0.1")!)); XCTAssertTrue(IPv4.isPublic(IPv4.parse("203.0.113.5")!))
        let s = IPv4Subnet(cidr: "192.168.1.77/24")!
        XCTAssertEqual(s.description, "192.168.1.0/24"); XCTAssertEqual(s.hosts().count, 254)
        XCTAssertTrue(s.contains("192.168.1.254")); XCTAssertFalse(s.contains("192.168.2.1"))
        XCTAssertEqual(MACAddress.normalize("0:24:D4:a:b:c"), "00:24:d4:0a:0b:0c")
        XCTAssertEqual(MACAddress.normalize("0024.d40a.0b0c"), "00:24:d4:0a:0b:0c")
        XCTAssertNil(MACAddress.normalize("zz:zz:zz:zz:zz:zz"))
        // Scenario: adresse MAC randomisée
        XCTAssertTrue(MACAddress.isLocallyAdministered("7a:1b:2c:3d:4e:5f"))
        XCTAssertFalse(MACAddress.isLocallyAdministered("3c:22:fb:12:34:56"))
        XCTAssertEqual(MACAddress.redact("3c:22:fb:12:34:56"), "3c:22:fb:••:••:••")
        XCTAssertEqual(MACAddress.ouiKey("3c:22:fb:12:34:56"), "3C22FB")
    }

    func testStats() {
        XCTAssertEqual(Stats.percentile([1, 2, 3, 4], 50), 2.5)
        XCTAssertEqual(Stats.percentile([5], 95), 5)
        XCTAssertNil(Stats.median([]))
        XCTAssertEqual(Stats.spikes([10, 11, 10, 60, 10]), [3])
        XCTAssertEqual(Stats.slope(x: [0, 1, 2], y: [1, 3, 5])!, 2, accuracy: 1e-9)
        XCTAssertEqual(Units.bitRate(412_345_678), "412.3 Mbit/s")
        XCTAssertEqual(Units.bitRate(1_500_000_000), "1.50 Gbit/s")
        XCTAssertEqual(Units.bytes(1_500_000), "1.50 Mo")
    }
}
