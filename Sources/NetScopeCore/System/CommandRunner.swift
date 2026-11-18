import Foundation

/// System tools NetScope Pro is allowed to execute. Each tool has a fixed absolute path and
/// an argument validator: commands are never built from shell strings and never run through a shell.
public enum SystemTool: String, CaseIterable, Codable, Sendable {
    case networkQuality, ping, ping6, traceroute, netstat, arp, ndp, scutil, networksetup
    case ifconfig, route, ipconfig, nettop, systemProfiler, swVers, sysctl, iperf3, airport

    /// Candidate absolute paths (first existing one wins). iperf3 is not part of macOS: it is only used
    /// when the user installed it (e.g. via Homebrew) — NetScope never downloads binaries.
    public var candidatePaths: [String] {
        switch self {
        case .networkQuality: return ["/usr/bin/networkQuality"]
        case .ping: return ["/sbin/ping", "/bin/ping", "/usr/bin/ping"]
        case .ping6: return ["/sbin/ping6"]
        case .traceroute: return ["/usr/sbin/traceroute", "/usr/bin/traceroute"]
        case .netstat: return ["/usr/sbin/netstat", "/bin/netstat", "/usr/bin/netstat"]
        case .arp: return ["/usr/sbin/arp"]
        case .ndp: return ["/usr/sbin/ndp"]
        case .scutil: return ["/usr/sbin/scutil"]
        case .networksetup: return ["/usr/sbin/networksetup"]
        case .ifconfig: return ["/sbin/ifconfig"]
        case .route: return ["/sbin/route"]
        case .ipconfig: return ["/usr/sbin/ipconfig"]
        case .nettop: return ["/usr/bin/nettop"]
        case .systemProfiler: return ["/usr/sbin/system_profiler"]
        case .swVers: return ["/usr/bin/sw_vers"]
        case .sysctl: return ["/usr/sbin/sysctl", "/sbin/sysctl"]
        case .iperf3: return ["/opt/homebrew/bin/iperf3", "/usr/local/bin/iperf3", "/usr/bin/iperf3"]
        case .airport: return ["/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport"]
        }
    }

    /// Tools that only read state. NetScope never invokes a tool that changes system configuration.
    public var isReadOnly: Bool { true }
}

public struct CommandResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var durationSeconds: Double
    public var timedOut: Bool
}

public enum CommandError: Error, LocalizedError, Equatable, Sendable {
    case toolNotFound(SystemTool)
    case invalidArgument(String)
    case timedOut(SystemTool, seconds: Double)
    case cancelled
    case launchFailed(String)
    case nonZeroExit(SystemTool, code: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound(let t): return "Outil système introuvable : \(t.rawValue)"
        case .invalidArgument(let a): return "Argument refusé par la validation : \(a)"
        case .timedOut(let t, let s): return "\(t.rawValue) a dépassé le délai de \(Int(s)) s"
        case .cancelled: return "Opération annulée"
        case .launchFailed(let m): return "Impossible de lancer la commande : \(m)"
        case .nonZeroExit(let t, let c, let e):
            return "\(t.rawValue) a échoué (code \(c))" + (e.isEmpty ? "" : " : \(e.prefix(200))")
        }
    }
}

/// Abstraction so services can be unit-tested with recorded outputs.
public protocol CommandRunning: Sendable {
    func run(_ tool: SystemTool, _ arguments: [String], timeout: Double) async throws -> CommandResult
    func isAvailable(_ tool: SystemTool) -> Bool
}

public enum ArgumentValidator {
    /// Hostname or IP literal: letters, digits, '-', '.', ':' (IPv6), max 253 chars, no leading '-'
    /// (prevents option injection such as "-f").
    public static func isValidHost(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 253, !s.hasPrefix("-"), !s.hasPrefix(".") else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.:%")
        return s.allSatisfy { allowed.contains($0) }
    }

    public static func isValidInterfaceName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 15, let first = s.first, first.isLetter else { return false }
        return s.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Validates a full argument vector against the allowed flags of a tool.
    /// Every argument must be either a known flag, or a value accepted by the validator of the preceding flag,
    /// or (for tools taking a trailing host) a valid host.
    public static func validate(_ tool: SystemTool, _ args: [String]) throws {
        let rule = rules[tool] ?? Rule(flags: [:], trailingHost: false, freeValues: [])
        var i = 0
        while i < args.count {
            let a = args[i]
            if let kind = rule.flags[a] {
                switch kind {
                case .none: i += 1
                case .value(let check):
                    guard i + 1 < args.count, check(args[i + 1]) else { throw CommandError.invalidArgument("\(a) \(i + 1 < args.count ? args[i + 1] : "<manquant>")") }
                    i += 2
                }
                continue
            }
            if rule.freeValues.contains(a) { i += 1; continue }
            if rule.trailingHost, i == args.count - 1, isValidHost(a) { i += 1; continue }
            throw CommandError.invalidArgument(a)
        }
    }

    enum FlagKind { case none, value((String) -> Bool) }
    struct Rule { var flags: [String: FlagKind]; var trailingHost: Bool; var freeValues: Set<String> }

    static func int(_ range: ClosedRange<Int>) -> (String) -> Bool { { Int($0).map(range.contains) ?? false } }
    static func double(_ range: ClosedRange<Double>) -> (String) -> Bool { { Double($0).map(range.contains) ?? false } }
    static let host: (String) -> Bool = isValidHost
    static let iface: (String) -> Bool = isValidInterfaceName

    static let rules: [SystemTool: Rule] = [
        .networkQuality: Rule(flags: ["-c": .none, "-s": .none, "-u": .none, "-d": .none, "-v": .none, "-h": .none,
                                      "-p": .none, "-I": .value(iface), "-r": .value(host), "-M": .value(int(5...120)),
                                      "-f": .value({ ["h1", "h2", "h3", "L4S", "noL4S"].contains($0) })],
                              trailingHost: false, freeValues: []),
        .ping: Rule(flags: ["-c": .value(int(1...1000)), "-i": .value(double(0.1...60)), "-W": .value(int(1...60000)),
                            "-t": .value(int(1...600)), "-s": .value(int(0...1472)), "-n": .none, "-q": .none,
                            "-S": .value(host), "-b": .value(iface), "-w": .value(int(1...600))],
                    trailingHost: true, freeValues: []),
        .ping6: Rule(flags: ["-c": .value(int(1...1000)), "-i": .value(double(0.1...60)), "-n": .none, "-q": .none],
                     trailingHost: true, freeValues: []),
        .traceroute: Rule(flags: ["-n": .none, "-m": .value(int(1...64)), "-q": .value(int(1...5)),
                                  "-w": .value(int(1...10)), "-I": .none],
                          trailingHost: true, freeValues: []),
        .netstat: Rule(flags: ["-r": .none, "-n": .none, "-f": .value({ ["inet", "inet6"].contains($0) }),
                               "-i": .none, "-b": .none, "-I": .value(iface)], trailingHost: false, freeValues: []),
        .arp: Rule(flags: ["-a": .none, "-n": .none], trailingHost: false, freeValues: []),
        .ndp: Rule(flags: ["-a": .none, "-n": .none], trailingHost: false, freeValues: []),
        .scutil: Rule(flags: ["--dns": .none, "--proxy": .none, "--nc": .none, "--nwi": .none],
                      trailingHost: false, freeValues: ["list"]),
        .networksetup: Rule(flags: ["-listallhardwareports": .none, "-listnetworkserviceorder": .none,
                                    "-getairportnetwork": .value(iface), "-getinfo": .value({ !$0.hasPrefix("-") && $0.count < 64 })],
                            trailingHost: false, freeValues: []),
        .ifconfig: Rule(flags: ["-a": .none, "-l": .none, "-v": .none], trailingHost: false,
                        freeValues: []),
        .route: Rule(flags: ["-n": .none, "get": .value(host)], trailingHost: false, freeValues: []),
        .ipconfig: Rule(flags: ["getpacket": .value(iface), "getifaddr": .value(iface), "getsummary": .value(iface)],
                        trailingHost: false, freeValues: []),
        .nettop: Rule(flags: ["-P": .none, "-x": .none, "-L": .value(int(1...5)), "-n": .none,
                              "-J": .value({ $0 == "bytes_in,bytes_out" })],
                      trailingHost: false, freeValues: []),
        .systemProfiler: Rule(flags: ["-json": .none, "-detailLevel": .value({ ["mini", "basic", "full"].contains($0) })],
                              trailingHost: false,
                              freeValues: ["SPHardwareDataType", "SPNetworkDataType", "SPAirPortDataType", "SPUSBDataType",
                                           "SPThunderboltDataType", "SPBluetoothDataType", "SPEthernetDataType", "SPSoftwareDataType"]),
        .swVers: Rule(flags: ["-productVersion": .none, "-buildVersion": .none], trailingHost: false, freeValues: []),
        .sysctl: Rule(flags: ["-n": .none], trailingHost: false,
                      freeValues: ["machdep.cpu.brand_string", "hw.optional.arm64", "hw.model", "kern.osproductversion",
                                   "net.inet.tcp.sack", "net.inet.tcp.mssdflt", "net.inet.tcp.win_scale_factor", "net.inet.tcp.autorcvbufmax",
                                   "net.inet.tcp.autosndbufmax", "net.inet.tcp.delayed_ack", "net.inet.tcp.ecn_initiate_out", "net.inet.tcp.ecn_negotiate_in"]),
        .iperf3: Rule(flags: ["-c": .value(host), "-p": .value(int(1...65535)), "-t": .value(int(1...60)), "-J": .none,
                              "-R": .none, "-P": .value(int(1...8)), "--version": .none, "--connect-timeout": .value(int(100...30000))],
                      trailingHost: false, freeValues: []),
        .airport: Rule(flags: ["-I": .none], trailingHost: false, freeValues: []),
    ]
}

/// Runs allowlisted tools with `Process` (no shell), enforcing a timeout and supporting task cancellation.
public final class ProcessCommandRunner: CommandRunning, @unchecked Sendable {
    public static let shared = ProcessCommandRunner()
    private let fileManager = FileManager.default

    public init() {}

    public func path(for tool: SystemTool) -> String? {
        tool.candidatePaths.first { fileManager.isExecutableFile(atPath: $0) }
    }

    public func isAvailable(_ tool: SystemTool) -> Bool { path(for: tool) != nil }

    public func run(_ tool: SystemTool, _ arguments: [String], timeout: Double) async throws -> CommandResult {
        try ArgumentValidator.validate(tool, arguments)
        guard let path = path(for: tool) else { throw CommandError.toolNotFound(tool) }
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        // Minimal, predictable environment; C locale so parsers see stable output.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "LANG": "C"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let start = Date()
        let box = OutputBox()
        out.fileHandleForReading.readabilityHandler = { h in box.appendOut(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { h in box.appendErr(h.availableData) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CommandResult, Error>) in
                let once = ResumeOnce(cont)
                process.terminationHandler = { p in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    box.appendOut(out.fileHandleForReading.readDataToEndOfFile())
                    box.appendErr(err.fileHandleForReading.readDataToEndOfFile())
                    let timedOut = box.timedOut
                    let r = CommandResult(exitCode: p.terminationStatus, stdout: box.stdout, stderr: box.stderr,
                                          durationSeconds: Date().timeIntervalSince(start), timedOut: timedOut)
                    if box.cancelled { once.resume(throwing: CommandError.cancelled) }
                    else if timedOut { once.resume(throwing: CommandError.timedOut(tool, seconds: timeout)) }
                    else { once.resume(returning: r) }
                }
                do { try process.run() } catch {
                    once.resume(throwing: CommandError.launchFailed(error.localizedDescription)); return
                }
                box.process = process
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { box.timedOut = true; process.terminate() }
                }
            }
        } onCancel: {
            box.cancelled = true
            if let p = box.process, p.isRunning { p.terminate() }
        }
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var outData = Data(), errData = Data()
        var process: Process?
        var timedOut = false
        var cancelled = false
        func appendOut(_ d: Data) { lock.lock(); outData.append(d); lock.unlock() }
        func appendErr(_ d: Data) { lock.lock(); errData.append(d); lock.unlock() }
        var stdout: String { lock.lock(); defer { lock.unlock() }; return String(decoding: outData, as: UTF8.self) }
        var stderr: String { lock.lock(); defer { lock.unlock() }; return String(decoding: errData, as: UTF8.self) }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private var cont: CheckedContinuation<CommandResult, Error>?
        private let lock = NSLock()
        init(_ c: CheckedContinuation<CommandResult, Error>) { cont = c }
        func resume(returning r: CommandResult) { take()?.resume(returning: r) }
        func resume(throwing e: Error) { take()?.resume(throwing: e) }
        private func take() -> CheckedContinuation<CommandResult, Error>? {
            lock.lock(); defer { lock.unlock() }
            let c = cont; cont = nil; return c
        }
    }
}

/// Test double replaying canned outputs.
public final class RecordedCommandRunner: CommandRunning, @unchecked Sendable {
    public var outputs: [String: CommandResult]
    public var available: Set<SystemTool>
    public private(set) var invocations: [(SystemTool, [String])] = []

    public init(outputs: [String: CommandResult] = [:], available: Set<SystemTool> = Set(SystemTool.allCases)) {
        self.outputs = outputs; self.available = available
    }

    public static func key(_ tool: SystemTool, _ args: [String]) -> String { ([tool.rawValue] + args).joined(separator: " ") }

    public func stub(_ tool: SystemTool, _ args: [String], stdout: String, exit: Int32 = 0) {
        outputs[Self.key(tool, args)] = CommandResult(exitCode: exit, stdout: stdout, stderr: "", durationSeconds: 0.01, timedOut: false)
    }

    public func isAvailable(_ tool: SystemTool) -> Bool { available.contains(tool) }

    public func run(_ tool: SystemTool, _ arguments: [String], timeout: Double) async throws -> CommandResult {
        try ArgumentValidator.validate(tool, arguments)
        invocations.append((tool, arguments))
        guard available.contains(tool) else { throw CommandError.toolNotFound(tool) }
        guard let r = outputs[Self.key(tool, arguments)] else { throw CommandError.launchFailed("aucune sortie enregistrée pour \(Self.key(tool, arguments))") }
        return r
    }
}
