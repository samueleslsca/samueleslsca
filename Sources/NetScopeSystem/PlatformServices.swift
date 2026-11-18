#if os(macOS)
import Foundation
import Network
import Security
import UserNotifications
import Darwin
import NetScopeCore

// MARK: - Path monitoring (Network.framework)

public struct PathStatus: Sendable, Equatable {
    public var satisfied: Bool
    public var interfaceTypes: [String]
    public var interfaceNames: [String]
    public var isExpensive: Bool
    public var isConstrained: Bool
    public var supportsIPv4: Bool
    public var supportsIPv6: Bool
    public var supportsDNS: Bool
}

/// Wraps NWPathMonitor; delivers updates on the main queue. No polling.
public final class PathMonitorService: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "fr.netscope.pathmonitor")
    public init() {}

    public func start(_ onChange: @escaping (PathStatus) -> Void) {
        monitor.pathUpdateHandler = { path in
            var types: [String] = []
            if path.usesInterfaceType(.wifi) { types.append("Wi-Fi") }
            if path.usesInterfaceType(.wiredEthernet) { types.append("Ethernet") }
            if path.usesInterfaceType(.cellular) { types.append("Cellulaire") }
            if path.usesInterfaceType(.other) { types.append("Autre") }
            let s = PathStatus(satisfied: path.status == .satisfied, interfaceTypes: types,
                               interfaceNames: path.availableInterfaces.map(\.name), isExpensive: path.isExpensive,
                               isConstrained: path.isConstrained, supportsIPv4: path.supportsIPv4,
                               supportsIPv6: path.supportsIPv6, supportsDNS: path.supportsDNS)
            DispatchQueue.main.async { onChange(s) }
        }
        monitor.start(queue: queue)
    }

    public func stop() { monitor.cancel() }
}

// MARK: - 64-bit interface counters (sysctl NET_RT_IFLIST2)

/// Reads per-interface byte counters with 64-bit precision (getifaddrs exposes 32-bit counters on macOS).
public enum InterfaceCountersReader {
    public static func read(now: Date = Date()) -> [InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, u_int(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, u_int(mib.count), &buf, &len, nil, 0) == 0 else { return [] }
        var out: [InterfaceCounters] = []
        var offset = 0
        buf.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let msglen = Int(hdr.ifm_msglen)
                guard msglen > 0 else { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                    let m2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(m2.ifm_index), &nameBuf) != nil {
                        out.append(InterfaceCounters(timestamp: now, interface: String(cString: nameBuf),
                                                     bytesIn: m2.ifm_data.ifi_ibytes, bytesOut: m2.ifm_data.ifi_obytes))
                    }
                }
                offset += msglen
            }
        }
        return out
    }
}

// MARK: - Keychain

/// Generic-password Keychain storage for router tokens, agent tokens and the optional AI key.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    let service: String
    public init(service: String = "fr.netscope.pro") { self.service = service }

    private func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    public func read(_ key: String) -> String? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let d = item as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public func write(_ key: String, value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(base(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let s = SecItemAdd(add as CFDictionary, nil)
            guard s == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(s)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public func delete(_ key: String) throws {
        let s = SecItemDelete(base(key) as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(s)) }
    }
}

// MARK: - Notifications

public final class NotificationsService: @unchecked Sendable {
    public static let shared = NotificationsService()
    /// UNUserNotificationCenter requires a bundled app; when run as a bare executable we no-op.
    private var center: UNUserNotificationCenter? { Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current() }

    public func requestAuthorization() async -> Bool {
        guard let c = center else { return false }
        return (try? await c.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func notify(title: String, body: String, id: String = UUID().uuidString) {
        guard let c = center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        c.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

// MARK: - Local peripherals (Local Device Monitor)

public struct LocalPeripheralService: Sendable {
    let runner: CommandRunning
    public init(runner: CommandRunning = ProcessCommandRunner.shared) { self.runner = runner }

    public func read() async -> [LocalPeripheral] {
        var all: [LocalPeripheral] = []
        for (type, bus) in [("SPUSBDataType", "USB"), ("SPThunderboltDataType", "Thunderbolt"),
                            ("SPBluetoothDataType", "Bluetooth"), ("SPEthernetDataType", "Ethernet")] {
            if let r = try? await runner.run(.systemProfiler, ["-json", "-detailLevel", "mini", type], timeout: 20) {
                all += SystemProfilerParser.parse(r.stdout, bus: bus)
            }
        }
        return all
    }
}

// MARK: - System facts (Phase 0 at runtime)

public struct SystemFacts: Sendable {
    public var osVersion: String
    public var cpu: String
    public var appleSilicon: Bool
    public var model: String
    public var liquidGlassAvailable: Bool

    public static func read() -> SystemFacts {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        func sysctlString(_ name: String) -> String {
            var size = 0
            sysctlbyname(name, nil, &size, nil, 0)
            guard size > 0 else { return "" }
            var b = [CChar](repeating: 0, count: size)
            sysctlbyname(name, &b, &size, nil, 0)
            return String(cString: b)
        }
        var arm: Int32 = 0
        var sz = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &arm, &sz, nil, 0)
        return SystemFacts(osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                           cpu: sysctlString("machdep.cpu.brand_string"), appleSilicon: arm == 1,
                           model: sysctlString("hw.model"), liquidGlassAvailable: v.majorVersion >= 26)
    }
}
#endif
