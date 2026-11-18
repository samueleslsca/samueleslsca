import Foundation

/// Pure-Swift SHA-1 and HMAC-SHA1, required by the Freebox OS login protocol
/// (password = HMAC-SHA1(app_token, challenge)). Implemented here so the core stays
/// dependency-free and testable on every platform; verified against RFC 2202 vectors.
/// SHA-1 is used only because the router protocol mandates it — never for NetScope's own security.
public enum SHA1 {
    public static func hash(_ message: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x67452301, h1: UInt32 = 0xEFCDAB89, h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476, h4: UInt32 = 0xC3D2E1F0
        var m = message
        let ml = UInt64(message.count) * 8
        m.append(0x80)
        while m.count % 64 != 56 { m.append(0) }
        for i in (0..<8).reversed() { m.append(UInt8((ml >> (UInt64(i) * 8)) & 0xff)) }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: m.count, by: 64) {
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(m[b]) << 24 | UInt32(m[b + 1]) << 16 | UInt32(m[b + 2]) << 8 | UInt32(m[b + 3])
            }
            for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = rotl(b, 30); b = a; a = t
            }
            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
        }
        return [h0, h1, h2, h3, h4].flatMap { v in (0..<4).reversed().map { UInt8((v >> (UInt32($0) * 8)) & 0xff) } }
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

    public static func hmac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var k = key.count > 64 ? hash(key) : key
        k += [UInt8](repeating: 0, count: 64 - k.count)
        let ipad = k.map { $0 ^ 0x36 }, opad = k.map { $0 ^ 0x5c }
        return hash(opad + hash(ipad + message))
    }

    public static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}
