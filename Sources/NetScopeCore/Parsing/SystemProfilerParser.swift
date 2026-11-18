import Foundation

/// A peripheral physically attached to the Mac (USB, Thunderbolt, Bluetooth, Ethernet adapter).
/// Distinct from Wi-Fi/LAN clients: this is the "Local Device Monitor".
public struct LocalPeripheral: Codable, Hashable, Identifiable, Sendable {
    public var id: String { bus + "/" + name + "/" + (detail["serial_num"] ?? detail["device_address"] ?? "") }
    public var bus: String
    public var name: String
    public var connected: Bool?
    public var detail: [String: String]
}

/// Parses `system_profiler -json <DataType>` output. The JSON tree differs per data type and per macOS
/// version, so we walk it generically and keep any dictionary with a `_name`.
public enum SystemProfilerParser {
    public static let interestingKeys: Set<String> = [
        "manufacturer", "vendor_id", "product_id", "serial_num", "device_speed", "bcd_device",
        "device_address", "device_minorType", "device_batteryLevelMain", "device_connected",
        "vendor_name_key", "device_name_key", "mode_key", "link_speed", "spethernet_BSD_Device_Name",
        "spethernet_vendor-id", "spethernet_device-id", "receptacle_status_key", "current_speed_key",
    ]

    public static func parse(_ json: String, bus: String) -> [LocalPeripheral] {
        guard let data = json.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var out: [LocalPeripheral] = []
        func props(_ d: [String: Any]) -> [String: String] {
            var detail: [String: String] = [:]
            for (k, v) in d where interestingKeys.contains(k) { detail[k] = "\(v)" }
            return detail
        }
        func walk(_ node: Any, connectedHint: Bool?, depth: Int) {
            guard depth < 12 else { return }
            if let arr = node as? [Any] { arr.forEach { walk($0, connectedHint: connectedHint, depth: depth + 1) }; return }
            guard let dict = node as? [String: Any] else { return }
            if let name = dict["_name"] as? String, !isContainer(name, dict) {
                out.append(LocalPeripheral(bus: bus, name: name, connected: connectedHint, detail: props(dict)))
            }
            // Bluetooth device entries are { "<device name>": { device_… properties } }.
            if connectedHint != nil {
                for (k, v) in dict {
                    if let p = v as? [String: Any], p["_name"] == nil, p.keys.contains(where: { $0.hasPrefix("device_") }) {
                        out.append(LocalPeripheral(bus: bus, name: k, connected: connectedHint, detail: props(p)))
                    }
                }
            }
            for (k, v) in dict {
                if k == "device_connected" { walk(v, connectedHint: true, depth: depth + 1) }
                else if k == "device_not_connected" { walk(v, connectedHint: false, depth: depth + 1) }
                else if v is [Any] { walk(v, connectedHint: connectedHint, depth: depth + 1) }
            }
        }
        walk(root, connectedHint: nil, depth: 0)
        return out
    }

    /// Bus/controller containers are not peripherals.
    static func isContainer(_ name: String, _ dict: [String: Any]) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("usb3") || lower.hasPrefix("usb31bus") || lower.hasSuffix("bus") || lower.contains("host controller") { return true }
        if lower == "bluetooth" || lower.hasPrefix("thunderboltbus") { return true }
        return dict["_items"] != nil && dict["manufacturer"] == nil && dict["vendor_id"] == nil
    }
}
