import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Minimal DNS wire-format encoder/decoder (RFC 1035) — enough to time A/AAAA queries against
/// a chosen resolver without touching the system configuration.
public enum DNSMessage {
    public enum RecordType: UInt16, Sendable { case a = 1, cname = 5, aaaa = 28 }

    public static func query(id: UInt16, name: String, type: RecordType, recursionDesired: Bool = true) throws -> [UInt8] {
        var b: [UInt8] = []
        b += [UInt8(id >> 8), UInt8(id & 0xff)]
        b += [recursionDesired ? 0x01 : 0x00, 0x00]   // flags
        b += [0, 1, 0, 0, 0, 0, 0, 0]                 // QD=1, AN=0, NS=0, AR=0
        b += try encodeName(name)
        b += [UInt8(type.rawValue >> 8), UInt8(type.rawValue & 0xff), 0, 1] // QTYPE, QCLASS=IN
        return b
    }

    public static func encodeName(_ name: String) throws -> [UInt8] {
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        guard !trimmed.isEmpty, trimmed.utf8.count <= 253 else { throw DNSError.invalidName(name) }
        var out: [UInt8] = []
        for label in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            let bytes = Array(label.utf8)
            guard (1...63).contains(bytes.count),
                  bytes.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x2d || $0 == 0x5f })
            else { throw DNSError.invalidName(name) }
            out.append(UInt8(bytes.count)); out += bytes
        }
        out.append(0)
        return out
    }

    public struct Response: Sendable, Equatable {
        public var id: UInt16
        public var rcode: Int
        public var truncated: Bool
        public var answers: [String]
    }

    public static func parse(_ d: [UInt8]) throws -> Response {
        guard d.count >= 12 else { throw DNSError.malformed }
        let id = UInt16(d[0]) << 8 | UInt16(d[1])
        guard d[2] & 0x80 != 0 else { throw DNSError.malformed } // QR bit must be set
        let tc = d[2] & 0x02 != 0
        let rcode = Int(d[3] & 0x0f)
        let qd = Int(UInt16(d[4]) << 8 | UInt16(d[5]))
        let an = Int(UInt16(d[6]) << 8 | UInt16(d[7]))
        var i = 12
        for _ in 0..<qd { i = try skipName(d, i); i += 4 }
        var answers: [String] = []
        for _ in 0..<an {
            i = try skipName(d, i)
            guard i + 10 <= d.count else { throw DNSError.malformed }
            let type = UInt16(d[i]) << 8 | UInt16(d[i + 1])
            let rdlen = Int(UInt16(d[i + 8]) << 8 | UInt16(d[i + 9]))
            i += 10
            guard i + rdlen <= d.count else { throw DNSError.malformed }
            if type == RecordType.a.rawValue, rdlen == 4 {
                answers.append(d[i..<i + 4].map(String.init).joined(separator: "."))
            } else if type == RecordType.aaaa.rawValue, rdlen == 16 {
                answers.append(stride(from: i, to: i + 16, by: 2).map { String(format: "%x", UInt16(d[$0]) << 8 | UInt16(d[$0 + 1])) }.joined(separator: ":"))
            }
            i += rdlen
        }
        return Response(id: id, rcode: rcode, truncated: tc, answers: answers)
    }

    static func skipName(_ d: [UInt8], _ start: Int) throws -> Int {
        var i = start
        var guardCount = 0
        while true {
            guard i < d.count, guardCount < 128 else { throw DNSError.malformed }
            guardCount += 1
            let len = d[i]
            if len == 0 { return i + 1 }
            if len & 0xc0 == 0xc0 { return i + 2 } // compression pointer ends the name in-place
            i += Int(len) + 1
        }
    }

    public static func rcodeLabel(_ r: Int) -> String {
        switch r {
        case 0: return "NOERROR"; case 1: return "FORMERR"; case 2: return "SERVFAIL"
        case 3: return "NXDOMAIN"; case 4: return "NOTIMP"; case 5: return "REFUSED"
        default: return "RCODE \(r)"
        }
    }
}

public enum DNSError: Error, LocalizedError, Equatable {
    case invalidName(String), invalidResolver(String), socket(String), timeout, malformed, idMismatch
    public var errorDescription: String? {
        switch self {
        case .invalidName(let n): return "Nom de domaine invalide : \(n)"
        case .invalidResolver(let r): return "Adresse de résolveur invalide : \(r)"
        case .socket(let m): return "Erreur réseau : \(m)"
        case .timeout: return "Délai dépassé (pas de réponse du résolveur)"
        case .malformed: return "Réponse DNS mal formée"
        case .idMismatch: return "Réponse DNS inattendue (identifiant différent)"
        }
    }
}

/// UDP DNS client over POSIX sockets (IPv4 resolvers). Blocking calls are run off the cooperative pool.
public struct DNSClient: Sendable {
    public init() {}

    public func resolve(_ name: String, type: DNSMessage.RecordType = .a, resolver: String,
                        timeout: Double = 2.0) async -> DNSQueryResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: self.resolveBlocking(name, type: type, resolver: resolver, timeout: timeout))
            }
        }
    }

    public func resolveBlocking(_ name: String, type: DNSMessage.RecordType, resolver: String, timeout: Double) -> DNSQueryResult {
        let start = Date()
        func fail(_ e: Error) -> DNSQueryResult {
            DNSQueryResult(resolver: resolver, name: name, success: false, responseCode: nil, durationMs: nil,
                           answers: [], error: (e as? LocalizedError)?.errorDescription ?? "\(e)", timestamp: start)
        }
        guard IPv4.parse(resolver) != nil else { return fail(DNSError.invalidResolver(resolver)) }
        let id = UInt16.random(in: 0...UInt16.max)
        let packet: [UInt8]
        do { packet = try DNSMessage.query(id: id, name: name, type: type) } catch { return fail(error) }

        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        #endif
        guard fd >= 0 else { return fail(DNSError.socket(String(cString: strerror(errno)))) }
        defer { close(fd) }

        var tv = timeval()
        tv.tv_sec = Int(timeout)
        tv.tv_usec = .init((timeout - Double(Int(timeout))) * 1_000_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(53).bigEndian
        inet_pton(AF_INET, resolver, &addr.sin_addr)
        let t0 = DispatchTime.now()
        let sent = packet.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { return fail(DNSError.socket(String(cString: strerror(errno)))) }

        var buffer = [UInt8](repeating: 0, count: 1500)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 { return fail(errno == EAGAIN || errno == EWOULDBLOCK ? DNSError.timeout : DNSError.socket(String(cString: strerror(errno)))) }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            do {
                let r = try DNSMessage.parse(Array(buffer[0..<n]))
                if r.id != id {
                    // Stale/foreign packet: keep waiting within the timeout.
                    if ms > timeout * 1000 { return fail(DNSError.timeout) }
                    continue
                }
                return DNSQueryResult(resolver: resolver, name: name, success: r.rcode == 0, responseCode: r.rcode,
                                      durationMs: ms, answers: r.answers,
                                      error: r.rcode == 0 ? nil : DNSMessage.rcodeLabel(r.rcode), timestamp: start)
            } catch { return fail(error) }
        }
    }
}
