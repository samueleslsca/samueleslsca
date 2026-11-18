import Foundation

/// Parsers for macOS command-line tool output. They are tolerant: unknown lines are ignored,
/// column positions are discovered from headers when possible, and nothing is invented.
public enum PingParser {
    public struct Result: Sendable, Equatable {
        public var target: String?
        public var transmitted: Int
        public var received: Int
        public var samplesMs: [Double]
        public var timeouts: [Int]
    }

    public static func parse(_ text: String) -> Result? {
        var target: String?
        var samples: [Double] = []
        var timeouts: [Int] = []
        var transmitted: Int?
        var received: Int?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("PING "), target == nil {
                target = line.dropFirst(5).split(separator: " ").first.map(String.init)
            } else if let r = line.range(of: "time=") {
                let rest = line[r.upperBound...]
                let num = rest.prefix { $0.isNumber || $0 == "." }
                if let v = Double(num) { samples.append(v) }
            } else if line.hasPrefix("Request timeout for icmp_seq") {
                if let n = Int(line.split(separator: " ").last ?? "") { timeouts.append(n) }
            } else if line.contains("packets transmitted") {
                // macOS: "5 packets transmitted, 4 packets received, 20.0% packet loss"
                // Linux: "5 packets transmitted, 4 received, 20% packet loss, time 4005ms"
                let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                for p in parts {
                    let first = p.split(separator: " ").first.flatMap { Int($0) }
                    if p.contains("transmitted") { transmitted = first }
                    else if p.contains("received") { received = first }
                }
            }
        }
        guard let tx = transmitted, let rx = received else {
            // No summary line (e.g. killed by timeout): fall back to the samples we saw.
            if samples.isEmpty && timeouts.isEmpty { return nil }
            return Result(target: target, transmitted: samples.count + timeouts.count, received: samples.count,
                          samplesMs: samples, timeouts: timeouts)
        }
        return Result(target: target, transmitted: tx, received: rx, samplesMs: samples, timeouts: timeouts)
    }
}

public enum RouteTableParser {
    /// Parses `netstat -rn` (macOS or BSD). Column positions are taken from each section header.
    public static func parse(_ text: String) -> [RouteEntry] {
        var entries: [RouteEntry] = []
        var isIPv6 = false
        var header: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "Internet:" { isIPv6 = false; header = []; continue }
            if trimmed == "Internet6:" { isIPv6 = true; header = []; continue }
            let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if tokens.first == "Destination" { header = tokens; continue }
            guard !header.isEmpty, tokens.count >= 3 else { continue }
            let gi = header.firstIndex(of: "Gateway") ?? 1
            let fi = header.firstIndex(of: "Flags") ?? 2
            let ni = header.firstIndex(of: "Netif") ?? header.firstIndex(of: "Iface") ?? min(3, tokens.count - 1)
            guard tokens.count > max(gi, fi) else { continue }
            let iface = ni < tokens.count ? tokens[ni] : ""
            entries.append(RouteEntry(destination: tokens[0], gateway: tokens[gi], flags: tokens[fi],
                                      interface: iface, isIPv6: isIPv6))
        }
        return entries
    }

    /// Picks the default route, preferring entries whose interface matches `preferredInterface`.
    /// Scoped duplicates (flag "I") are ignored when an unscoped default exists.
    public static func defaultGateway(_ routes: [RouteEntry], ipv6: Bool, preferredInterface: String? = nil) -> RouteEntry? {
        let defaults = routes.filter { $0.isDefault && $0.isIPv6 == ipv6 && $0.flags.contains("G") }
        // A scoped default (flag "I") is the right answer when the caller asks for a specific interface.
        if let p = preferredInterface, let m = defaults.first(where: { $0.interface == p }) { return m }
        let unscoped = defaults.filter { !$0.flags.contains("I") }
        return (unscoped.isEmpty ? defaults : unscoped).first
    }
}

public struct NeighborEntry: Codable, Hashable, Sendable {
    public var ip: String
    public var mac: String?
    public var interface: String?
    public var isIPv6: Bool
    public var isPermanent: Bool
    public var isIncomplete: Bool
}

public enum NeighborParser {
    /// `arp -an` on macOS: `? (192.168.1.254) at 0:24:d4:aa:bb:cc on en0 ifscope [ethernet]`
    /// Linux: `? (10.0.0.1) at 52:54:00:12:34:56 [ether] on eth0`
    public static func parseARP(_ text: String) -> [NeighborEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            guard let o = line.firstIndex(of: "("), let c = line.firstIndex(of: ")"), o < c else { return nil }
            let ip = String(line[line.index(after: o)..<c])
            guard IPv4.parse(ip) != nil else { return nil }
            let tokens = line[c...].split(separator: " ").map(String.init)
            var mac: String?
            var iface: String?
            if let at = tokens.firstIndex(of: "at"), at + 1 < tokens.count { mac = MACAddress.normalize(tokens[at + 1]) }
            if let on = tokens.firstIndex(of: "on"), on + 1 < tokens.count { iface = tokens[on + 1] }
            return NeighborEntry(ip: ip, mac: mac, interface: iface, isIPv6: false,
                                 isPermanent: line.contains("permanent"), isIncomplete: line.contains("incomplete"))
        }
    }

    /// `ndp -an`: `fe80::1%en0   0:24:d4:aa:bb:cc   en0 23h59m58s S  R`
    public static func parseNDP(_ text: String) -> [NeighborEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let t = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard t.count >= 3, t[0].contains(":"), t[0] != "Neighbor" else { return nil }
            let ip = t[0].split(separator: "%").first.map(String.init) ?? t[0]
            let mac = MACAddress.normalize(t[1])
            return NeighborEntry(ip: ip, mac: mac, interface: t[2], isIPv6: true,
                                 isPermanent: t.contains("permanent"), isIncomplete: t[1] == "(incomplete)")
        }
    }
}

public enum ScutilParser {
    /// Parses `scutil --dns`. Only the first section (non-scoped) contributes non-scoped resolvers.
    public static func parseDNS(_ text: String) -> DNSConfiguration {
        var resolvers: [DNSConfiguration.Resolver] = []
        var scoped = false
        var current: DNSConfiguration.Resolver?
        func flush() { if let c = current { resolvers.append(c) }; current = nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("DNS configuration") { flush(); scoped = line.contains("scoped"); continue }
            if line.hasPrefix("resolver #") {
                flush()
                let idx = Int(line.dropFirst("resolver #".count)) ?? resolvers.count + 1
                current = .init(index: idx, domain: nil, nameservers: [], interface: nil, isScoped: scoped)
                continue
            }
            guard current != nil, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("nameserver[") { current?.nameservers.append(value) }
            else if key == "domain" { current?.domain = value }
            else if key == "if_index" {
                // "6 (en0)"
                if let o = value.firstIndex(of: "("), let c = value.firstIndex(of: ")") {
                    current?.interface = String(value[value.index(after: o)..<c])
                }
            }
        }
        flush()
        return DNSConfiguration(resolvers: resolvers)
    }

    /// Parses `scutil --proxy`.
    public static func parseProxy(_ text: String) -> ProxyStatus {
        var d: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { d[parts[0]] = parts[1] }
        }
        var kinds: [ProxyKind] = []
        if d["HTTPEnable"] == "1" { kinds.append(.http) }
        if d["HTTPSEnable"] == "1" { kinds.append(.https) }
        if d["SOCKSEnable"] == "1" { kinds.append(.socks) }
        if d["ProxyAutoConfigEnable"] == "1" { kinds.append(.pac) }
        if d["ProxyAutoDiscoveryEnable"] == "1" { kinds.append(.autoDiscovery) }
        return ProxyStatus(enabled: kinds)
    }
}

public enum IfconfigParser {
    public static func parse(_ text: String, hardwarePorts: [String: String] = [:]) -> [NetworkInterfaceInfo] {
        var result: [NetworkInterfaceInfo] = []
        var cur: NetworkInterfaceInfo?
        func flush() { if let c = cur { result.append(c) }; cur = nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if let first = line.first, !first.isWhitespace, let colon = line.firstIndex(of: ":") {
                flush()
                let name = String(line[..<colon])
                let flags = line.range(of: "<").flatMap { o in line.range(of: ">").map { String(line[o.upperBound..<$0.lowerBound]) } } ?? ""
                let flagSet = Set(flags.split(separator: ",").map(String.init))
                var mtu: Int?
                if let r = line.range(of: "mtu ") { mtu = Int(line[r.upperBound...].prefix { $0.isNumber }) }
                let port = hardwarePorts[name]
                cur = NetworkInterfaceInfo(bsdName: name, displayName: port,
                                           kind: InterfaceClassifier.kind(bsdName: name, hardwarePort: port),
                                           isUp: flagSet.contains("UP"), isRunning: flagSet.contains("RUNNING"), mtu: mtu)
                continue
            }
            guard cur != nil else { continue }
            let t = line.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
            guard let key = t.first else { continue }
            switch key {
            case "ether" where t.count > 1:
                cur?.macAddress = MACAddress.normalize(t[1])
            case "inet" where t.count > 1:
                var a = IPv4Assignment(address: t[1])
                if let i = t.firstIndex(of: "netmask"), i + 1 < t.count, let p = IPv4.parseMask(t[i + 1]) {
                    a.netmask = IPv4.format(IPv4.mask(prefix: p))
                }
                if let i = t.firstIndex(of: "broadcast"), i + 1 < t.count { a.broadcast = t[i + 1] }
                cur?.ipv4.append(a)
            case "inet6" where t.count > 1:
                cur?.ipv6.append(t[1].split(separator: "%").first.map(String.init) ?? t[1])
            case "media:":
                cur?.media = t.dropFirst().joined(separator: " ")
            case "status:" where t.count > 1:
                if t[1] == "inactive" { cur?.isRunning = false }
            default: break
            }
        }
        flush()
        return result
    }
}

public enum InterfaceClassifier {
    public static func kind(bsdName: String, hardwarePort: String?) -> InterfaceKind {
        if let p = hardwarePort?.lowercased() {
            if p.contains("wi-fi") || p.contains("airport") || p.contains("wlan") { return .wifi }
            if p.contains("bridge") { return .bridge }
            if p.contains("ethernet") || p.contains("lan") || p.contains("thunderbolt") || p.contains("usb") { return .ethernet }
            if p.contains("iphone") || p.contains("cellular") { return .cellular }
        }
        let n = bsdName.lowercased()
        if n.hasPrefix("lo") { return .loopback }
        if n.hasPrefix("utun") || n.hasPrefix("ipsec") || n.hasPrefix("ppp") || n.hasPrefix("tun") || n.hasPrefix("tap")
            || n.hasPrefix("wg") || n.hasPrefix("gif") { return .vpn }
        if n.hasPrefix("bridge") { return .bridge }
        if n.hasPrefix("pdp_ip") { return .cellular }
        if n.hasPrefix("eth") || n.hasPrefix("enp") || n.hasPrefix("eno") { return .ethernet }
        if n.hasPrefix("wl") { return .wifi }
        return .other
    }

    /// Negotiated Ethernet speed in Mbit/s from an ifconfig media string, e.g. "autoselect (1000baseT <full-duplex>)".
    public static func ethernetSpeedMbps(media: String?) -> Int? {
        guard let m = media else { return nil }
        let patterns: [(String, Int)] = [("10Gbase", 10_000), ("5000base", 5_000), ("2500base", 2_500),
                                         ("1000base", 1_000), ("100base", 100), ("10base", 10)]
        return patterns.first { m.contains($0.0) }?.1
    }

    public static func isHalfDuplex(media: String?) -> Bool { media?.contains("half-duplex") ?? false }
}

public enum HardwarePortsParser {
    /// `networksetup -listallhardwareports` → [bsdName: hardware port name]
    public static func parse(_ text: String) -> [String: String] {
        var map: [String: String] = [:]
        var port: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Hardware Port:") { port = line.dropFirst("Hardware Port:".count).trimmingCharacters(in: .whitespaces) }
            else if line.hasPrefix("Device:"), let p = port {
                map[line.dropFirst("Device:".count).trimmingCharacters(in: .whitespaces)] = p
                port = nil
            }
        }
        return map
    }
}

public struct TracerouteHop: Codable, Hashable, Sendable {
    public var hop: Int
    public var addresses: [String]
    public var rttsMs: [Double]
    public var timeouts: Int

    public var isPrivate: Bool { addresses.contains { IPv4.parse($0).map(IPv4.isPrivate) ?? false } }
    public var isCGNAT: Bool { addresses.contains { IPv4.parse($0).map(IPv4.isCGNAT) ?? false } }
}

public enum TracerouteParser {
    public static func parse(_ text: String) -> [TracerouteHop] {
        var hops: [TracerouteHop] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let t = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let n = t.first.flatMap(Int.init) else { continue }
            var addrs: [String] = [], rtts: [Double] = [], timeouts = 0
            var i = 1
            while i < t.count {
                let tok = t[i]
                if tok == "*" { timeouts += 1 }
                else if i + 1 < t.count, t[i + 1] == "ms", let v = Double(tok) { rtts.append(v); i += 1 }
                else if IPv4.parse(tok) != nil || tok.contains(":") { if !addrs.contains(tok) { addrs.append(tok) } }
                i += 1
            }
            hops.append(TracerouteHop(hop: n, addresses: addrs, rttsMs: rtts, timeouts: timeouts))
        }
        return hops
    }
}

public enum NetworkQualityHelpParser {
    /// Extracts supported single-letter flags from `networkQuality -h` (format varies across macOS versions).
    public static func supportedFlags(_ help: String) -> Set<String> {
        var flags = Set<String>()
        for raw in help.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("-"), line.count >= 2 else { continue }
            let flag = String(line.prefix(2))
            if flag.last?.isLetter == true { flags.insert(flag) }
        }
        return flags
    }
}

public struct ProcessTrafficSample: Codable, Hashable, Sendable {
    public var process: String
    public var pid: Int?
    public var bytesIn: UInt64
    public var bytesOut: UInt64
}

public enum NettopParser {
    /// Parses `nettop -P -x -L 1 -J bytes_in,bytes_out` CSV output. The process column is the one
    /// formatted "name.pid"; byte columns are located by header.
    public static func parse(_ text: String) -> [ProcessTrafficSample] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let headerLine = lines.first(where: { $0.contains("bytes_in") }) else { return [] }
        let header = headerLine.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let inIdx = header.firstIndex(of: "bytes_in"), let outIdx = header.firstIndex(of: "bytes_out") else { return [] }
        var result: [ProcessTrafficSample] = []
        for line in lines where line != headerLine {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count > max(inIdx, outIdx),
                  let bi = UInt64(cols[inIdx]), let bo = UInt64(cols[outIdx]) else { continue }
            guard let nameCol = cols.first(where: { c in
                guard let dot = c.lastIndex(of: "."), dot != c.startIndex else { return false }
                // Skip timestamps such as "10:00:00.123456": the process name contains letters.
                guard c[..<dot].contains(where: \.isLetter), !c.contains(":") || c[..<dot].contains(" ") else { return false }
                return !c[c.index(after: dot)...].isEmpty && c[c.index(after: dot)...].allSatisfy(\.isNumber)
            }) else { continue }
            let dot = nameCol.lastIndex(of: ".")!
            result.append(ProcessTrafficSample(process: String(nameCol[..<dot]),
                                               pid: Int(nameCol[nameCol.index(after: dot)...]),
                                               bytesIn: bi, bytesOut: bo))
        }
        return result
    }
}
