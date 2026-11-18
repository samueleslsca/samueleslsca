import Foundation

/// IPv4 address assigned to an interface.
public struct IPv4Assignment: Codable, Hashable, Sendable {
    public var address: String
    public var netmask: String?
    public var broadcast: String?

    public init(address: String, netmask: String? = nil, broadcast: String? = nil) {
        self.address = address; self.netmask = netmask; self.broadcast = broadcast
    }

    public var subnet: IPv4Subnet? {
        guard let a = IPv4.parse(address), let m = netmask.flatMap(IPv4.parseMask) else { return nil }
        return IPv4Subnet(network: a & IPv4.mask(prefix: m), prefixLength: m)
    }
}

/// Pure IPv4 arithmetic helpers (no dependency on Network.framework so they are testable everywhere).
public enum IPv4 {
    public static func parse(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCIIDigit), let o = UInt32(p), o <= 255 else { return nil }
            v = (v << 8) | o
        }
        return v
    }

    public static func format(_ v: UInt32) -> String {
        "\(v >> 24 & 0xff).\(v >> 16 & 0xff).\(v >> 8 & 0xff).\(v & 0xff)"
    }

    public static func mask(prefix: Int) -> UInt32 {
        prefix <= 0 ? 0 : (prefix >= 32 ? 0xffff_ffff : ~UInt32(0) << UInt32(32 - prefix))
    }

    /// Accepts dotted ("255.255.255.0") or hex ("0xffffff00", as printed by ifconfig) masks; returns prefix length.
    public static func parseMask(_ s: String) -> Int? {
        let value: UInt32?
        if s.lowercased().hasPrefix("0x") {
            value = UInt32(s.dropFirst(2), radix: 16)
        } else {
            value = parse(s)
        }
        guard let m = value else { return nil }
        let prefix = m.nonzeroBitCount
        // Must be contiguous.
        guard mask(prefix: prefix) == m else { return nil }
        return prefix
    }

    public static func isPrivate(_ v: UInt32) -> Bool {
        (v & 0xff00_0000) == 0x0a00_0000        // 10/8
            || (v & 0xfff0_0000) == 0xac10_0000  // 172.16/12
            || (v & 0xffff_0000) == 0xc0a8_0000  // 192.168/16
    }

    public static func isCGNAT(_ v: UInt32) -> Bool { (v & 0xffc0_0000) == 0x6440_0000 } // 100.64/10
    public static func isLinkLocal(_ v: UInt32) -> Bool { (v & 0xffff_0000) == 0xa9fe_0000 } // 169.254/16
    public static func isLoopback(_ v: UInt32) -> Bool { (v & 0xff00_0000) == 0x7f00_0000 }

    public static func isPublic(_ v: UInt32) -> Bool {
        !(isPrivate(v) || isCGNAT(v) || isLinkLocal(v) || isLoopback(v) || v == 0 || (v >> 28) >= 0xe)
    }
}

public struct IPv4Subnet: Codable, Hashable, Sendable, CustomStringConvertible {
    public var network: UInt32
    public var prefixLength: Int

    public init(network: UInt32, prefixLength: Int) {
        self.network = network & IPv4.mask(prefix: prefixLength)
        self.prefixLength = prefixLength
    }

    public init?(cidr: String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let a = IPv4.parse(String(parts[0])), let p = Int(parts[1]), (0...32).contains(p) else { return nil }
        self.init(network: a, prefixLength: p)
    }

    public var description: String { "\(IPv4.format(network))/\(prefixLength)" }
    public var hostCount: Int { prefixLength >= 31 ? (1 << (32 - prefixLength)) : (1 << (32 - prefixLength)) - 2 }

    public func contains(_ address: String) -> Bool {
        guard let a = IPv4.parse(address) else { return false }
        return a & IPv4.mask(prefix: prefixLength) == network
    }

    /// Usable host addresses (excludes network and broadcast for prefixes < 31).
    public func hosts() -> [String] {
        let size = UInt32(1) << UInt32(32 - prefixLength)
        if prefixLength >= 31 { return (0..<size).map { IPv4.format(network + $0) } }
        return (1..<(size - 1)).map { IPv4.format(network + $0) }
    }
}

/// MAC address helpers.
public enum MACAddress {
    /// Normalizes "a:b:c:d:e:f", "0A-0B-…", "0a0b.0c0d.0e0f" to "0a:0b:0c:0d:0e:0f"; returns nil if invalid.
    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        var octets: [String]
        if trimmed.contains(":") || trimmed.contains("-") {
            octets = trimmed.split(whereSeparator: { $0 == ":" || $0 == "-" }).map(String.init)
            guard octets.count == 6 else { return nil }
            octets = octets.map { $0.count == 1 ? "0" + $0 : $0 }
        } else {
            let hex = trimmed.replacingOccurrences(of: ".", with: "")
            guard hex.count == 12 else { return nil }
            octets = stride(from: 0, to: 12, by: 2).map { i in
                let s = hex.index(hex.startIndex, offsetBy: i)
                return String(hex[s..<hex.index(s, offsetBy: 2)])
            }
        }
        guard octets.allSatisfy({ $0.count == 2 && UInt8($0, radix: 16) != nil }) else { return nil }
        let joined = octets.joined(separator: ":")
        if joined == "ff:ff:ff:ff:ff:ff" || joined == "00:00:00:00:00:00" { return nil }
        return joined
    }

    /// Locally-administered bit set → typically a private/randomized address (iOS, Android, macOS, Windows).
    public static func isLocallyAdministered(_ mac: String) -> Bool {
        guard let n = normalize(mac), let first = UInt8(n.prefix(2), radix: 16) else { return false }
        return first & 0x02 != 0
    }

    public static func isMulticast(_ mac: String) -> Bool {
        guard let n = normalize(mac), let first = UInt8(n.prefix(2), radix: 16) else { return false }
        return first & 0x01 != 0
    }

    /// First three octets as uppercase hex without separators ("A4B1C2"), as used by the IEEE registry.
    public static func ouiKey(_ mac: String) -> String? {
        guard let n = normalize(mac) else { return nil }
        return n.prefix(8).replacingOccurrences(of: ":", with: "").uppercased()
    }

    /// Masks a MAC address for privacy mode: keeps OUI, hides device part.
    public static func redact(_ mac: String) -> String {
        guard let n = normalize(mac) else { return "••:••:••:••:••:••" }
        return String(n.prefix(8)) + ":••:••:••"
    }
}

extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
