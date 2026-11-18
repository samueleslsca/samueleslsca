import Foundation

/// Data-reliability classification required for every value displayed by NetScope Pro.
///
/// Every number shown in a production view must carry one of these categories so the user
/// always knows whether a value was measured on this Mac, reported by the router, derived
/// from other values, estimated by a model, or simply not available.
public enum Provenance: Codable, Hashable, Sendable {
    /// Directly measured on this Mac (API call, system tool, packet timing…).
    case measured(method: String)
    /// Reported by the router/box through its official API.
    case router(adapter: String)
    /// Deterministically computed from other values (e.g. SNR = RSSI − noise).
    case computed(formula: String)
    /// Estimated by a heuristic or model — inherently uncertain.
    case estimated(model: String)
    /// Not available, with a human-readable reason.
    case unavailable(reason: String)

    public var category: Category {
        switch self {
        case .measured: return .measured
        case .router: return .router
        case .computed: return .computed
        case .estimated: return .estimated
        case .unavailable: return .unavailable
        }
    }

    public var detail: String {
        switch self {
        case .measured(let m): return m
        case .router(let a): return a
        case .computed(let f): return f
        case .estimated(let m): return m
        case .unavailable(let r): return r
        }
    }

    public enum Category: String, Codable, CaseIterable, Sendable {
        case measured, router, computed, estimated, unavailable

        public var label: String {
            switch self {
            case .measured: return "Mesuré"
            case .router: return "Fourni par le routeur"
            case .computed: return "Calculé"
            case .estimated: return "Estimé"
            case .unavailable: return "Non disponible"
            }
        }
    }
}

/// A value together with its provenance and timestamp.
public struct Sourced<Value>: Sendable where Value: Sendable {
    public var value: Value?
    public var provenance: Provenance
    public var timestamp: Date

    public init(_ value: Value?, _ provenance: Provenance, at timestamp: Date = Date()) {
        // A value with no data is always reported as unavailable — never as measured.
        if value == nil, provenance.category != .unavailable {
            self.provenance = .unavailable(reason: "Aucune valeur retournée (\(provenance.detail))")
        } else {
            self.provenance = provenance
        }
        self.value = value
        self.timestamp = timestamp
    }

    public static func unavailable(_ reason: String, at timestamp: Date = Date()) -> Sourced<Value> {
        Sourced(nil, .unavailable(reason: reason), at: timestamp)
    }

    public var isAvailable: Bool { value != nil }

    public func map<T>(_ transform: (Value) -> T) -> Sourced<T> {
        Sourced<T>(value.map(transform), provenance, at: timestamp)
    }
}

extension Sourced: Equatable where Value: Equatable {}
extension Sourced: Hashable where Value: Hashable {}
extension Sourced: Codable where Value: Codable {}

/// Confidence attached to a score, a diagnosis hypothesis or an identification.
public enum Confidence: String, Codable, Comparable, CaseIterable, Sendable {
    case none, low, medium, high

    public var label: String {
        switch self {
        case .none: return "Aucune"
        case .low: return "Faible"
        case .medium: return "Moyenne"
        case .high: return "Élevée"
        }
    }

    private var rank: Int {
        switch self { case .none: return 0; case .low: return 1; case .medium: return 2; case .high: return 3 }
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rank < rhs.rank }
}
