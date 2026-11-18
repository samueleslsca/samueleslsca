import Foundation

// MARK: - Profiles & metrics

public enum BoostMetric: String, Codable, CaseIterable, Hashable, Sendable {
    case download, upload, idleLatency, loadedLatency, jitter, loss

    public var label: String {
        switch self {
        case .download: return "Débit descendant"
        case .upload: return "Débit montant"
        case .idleLatency: return "Latence au repos"
        case .loadedLatency: return "Latence sous charge"
        case .jitter: return "Gigue"
        case .loss: return "Pertes"
        }
    }
    public var lowerIsBetter: Bool { self != .download && self != .upload }

    public func format(_ v: Double) -> String {
        switch self {
        case .download, .upload: return Units.bitRate(v)
        case .loss: return String(format: "%.2f %%", v)
        default: return Units.ms(v)
        }
    }
}

public enum BoostProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case maxSpeed, ultraLowLatency, streaming, smartAuto
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .maxSpeed: return "MAX SPEED"
        case .ultraLowLatency: return "ULTRA LOW LATENCY"
        case .streaming: return "STREAMING & VIDEO"
        case .smartAuto: return "SMART AUTO"
        }
    }
    public var goal: String {
        switch self {
        case .maxSpeed: return "Maximiser le débit descendant et montant mesuré, sans sacrifier excessivement la stabilité."
        case .ultraLowLatency: return "Obtenir la latence la plus basse et la plus stable, y compris sous charge."
        case .streaming: return "Stabiliser l’upload, la gigue et les pertes pour la visio et le streaming."
        case .smartAuto: return "Meilleur compromis vitesse / latence / stabilité selon vos mesures réelles."
        }
    }
    public var symbol: String {
        switch self {
        case .maxSpeed: return "bolt.fill"
        case .ultraLowLatency: return "timer"
        case .streaming: return "video.fill"
        case .smartAuto: return "wand.and.stars"
        }
    }
    /// Metrics whose improvement is the goal of the profile.
    public var primaryMetrics: [BoostMetric] {
        switch self {
        case .maxSpeed: return [.download, .upload]
        case .ultraLowLatency: return [.loadedLatency, .idleLatency, .jitter]
        case .streaming: return [.upload, .jitter, .loss, .loadedLatency]
        case .smartAuto: return BoostMetric.allCases
        }
    }
    /// Metrics that must not degrade beyond the tolerance (trade-off guard).
    public var guardMetrics: [BoostMetric] {
        switch self {
        case .maxSpeed: return [.loadedLatency, .loss]
        case .ultraLowLatency: return [.download, .upload, .loss]
        case .streaming: return [.download]
        case .smartAuto: return []
        }
    }
}

// MARK: - Safety & status

public enum SafetyLevel: Int, Codable, Comparable, CaseIterable, Sendable {
    case readOnly = 1, reversible = 2, sensitive = 3
    public static func < (a: SafetyLevel, b: SafetyLevel) -> Bool { a.rawValue < b.rawValue }
    public var label: String {
        switch self {
        case .readOnly: return "Niveau 1 — lecture seule"
        case .reversible: return "Niveau 2 — modification réversible"
        case .sensitive: return "Niveau 3 — action sensible"
        }
    }
}

public enum BoostStatus: String, Codable, Sendable {
    case analyzing = "Analyse en cours"
    case available = "Optimisation disponible"
    case authorizationNeeded = "Autorisation nécessaire"
    case applied = "Modification appliquée"
    case gainConfirmed = "Gain confirmé"
    case noGain = "Aucun gain démontré"
    case restoreNeeded = "Restauration nécessaire"
    case restored = "Restauré"
    case guided = "À réaliser par vous"
    case failed = "Échec"
    case skipped = "Non retenu"
}

public enum BoostPhase: Int, Codable, CaseIterable, Comparable, Sendable {
    case idle, analysis, recommendations, authorization, optimization, verification, report
    public static func < (a: BoostPhase, b: BoostPhase) -> Bool { a.rawValue < b.rawValue }
    public var label: String {
        switch self {
        case .idle: return "Prêt"
        case .analysis: return "Analyse"
        case .recommendations: return "Recommandations"
        case .authorization: return "Autorisations"
        case .optimization: return "Optimisations"
        case .verification: return "Vérification"
        case .report: return "Rapport"
        }
    }
}

// MARK: - Measurements

/// One comparable measurement run (same protocol for baseline and candidate).
public struct BoostSample: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var interface: String?
    public var networkName: String?
    public var target: String
    public var vpnActive: Bool
    public var downloadBps: Double?
    public var uploadBps: Double?
    public var idleLatencyMs: Double?
    public var loadedLatencyMs: Double?
    public var jitterMs: Double?
    public var lossPercent: Double?
    public var rssi: Int?
    public var backgroundBps: Double?

    public init(id: UUID = UUID(), timestamp: Date = Date(), interface: String?, networkName: String?, target: String,
                vpnActive: Bool = false, downloadBps: Double?, uploadBps: Double?, idleLatencyMs: Double?,
                loadedLatencyMs: Double?, jitterMs: Double?, lossPercent: Double?, rssi: Int? = nil, backgroundBps: Double? = nil) {
        self.id = id; self.timestamp = timestamp; self.interface = interface; self.networkName = networkName
        self.target = target; self.vpnActive = vpnActive; self.downloadBps = downloadBps; self.uploadBps = uploadBps
        self.idleLatencyMs = idleLatencyMs; self.loadedLatencyMs = loadedLatencyMs; self.jitterMs = jitterMs
        self.lossPercent = lossPercent; self.rssi = rssi; self.backgroundBps = backgroundBps
    }

    /// Builds a sample from a networkQuality result plus an ICMP probe to a fixed target.
    public static func from(_ t: SpeedTestResult, ping: LatencyStats?, rssi: Int?, background: Double?) -> BoostSample {
        BoostSample(timestamp: t.timestamp, interface: t.interfaceName, networkName: t.networkName,
                    target: ping?.target ?? t.server ?? "networkQuality", vpnActive: t.vpnActive,
                    downloadBps: t.downloadBps, uploadBps: t.uploadBps,
                    idleLatencyMs: ping?.medianMs ?? t.idleLatencyMs, loadedLatencyMs: t.worstLoadedLatencyMs,
                    jitterMs: ping?.jitterMs ?? t.jitterMs, lossPercent: ping?.lossPercent, rssi: rssi, backgroundBps: background)
    }

    public func value(_ m: BoostMetric) -> Double? {
        switch m {
        case .download: return downloadBps
        case .upload: return uploadBps
        case .idleLatency: return idleLatencyMs
        case .loadedLatency: return loadedLatencyMs
        case .jitter: return jitterMs
        case .loss: return lossPercent
        }
    }
}

// MARK: - Candidates & actions

public struct SQMSettings: Codable, Hashable, Sendable {
    public var section: String
    public var interface: String
    public var enabled: Bool
    /// kbit/s, as required by sqm-scripts.
    public var downloadKbps: Int
    public var uploadKbps: Int
    public var qdisc: String
    public var script: String

    public init(section: String, interface: String, enabled: Bool, downloadKbps: Int, uploadKbps: Int,
                qdisc: String = "cake", script: String = "piece_of_cake.qos") {
        self.section = section; self.interface = interface; self.enabled = enabled
        self.downloadKbps = downloadKbps; self.uploadKbps = uploadKbps; self.qdisc = qdisc; self.script = script
    }

    public var summary: String {
        enabled ? "SQM activé sur \(interface) : ↓ \(downloadKbps) kbit/s, ↑ \(uploadKbps) kbit/s, \(qdisc)/\(script)" : "SQM désactivé sur \(interface)"
    }
}

/// What a candidate would do. Only the non-`guided` kinds are ever executed, and only after explicit authorization.
public enum BoostAction: Codable, Hashable, Sendable {
    /// The user performs it (instructions provided). NetScope only measures before/after.
    case guided(steps: [String])
    /// Ask a regular macOS application to quit normally (never force-killed).
    case quitApplication(pid: Int, name: String)
    /// Change sqm-scripts settings on an OpenWrt router (rpcd uci apply with automatic rollback).
    case routerSQM(SQMSettings)

    public var isAutomatable: Bool { if case .guided = self { return false }; return true }
}

public enum BoostCategory: String, Codable, CaseIterable, Sendable {
    case wifi = "Wi-Fi", router = "Routeur", bandwidth = "Bande passante", stack = "Pile réseau macOS"
    case dns = "DNS", physical = "Câblage / matériel", latency = "Latence sous charge"
}

public struct BoostCandidate: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var evidence: [String]
    public var category: BoostCategory
    public var targets: [BoostMetric]
    public var expectedGain: Confidence
    public var risk: RiskLevel
    public var reversible: Bool
    public var safety: SafetyLevel
    public var action: BoostAction
    public var affected: [String]
    public var tradeoffs: [String]
    public var status: BoostStatus
    public var priority: Double

    public init(id: String, title: String, detail: String, evidence: [String], category: BoostCategory, targets: [BoostMetric],
                expectedGain: Confidence, risk: RiskLevel, reversible: Bool, safety: SafetyLevel, action: BoostAction,
                affected: [String] = [], tradeoffs: [String] = [], status: BoostStatus = .available, priority: Double = 0) {
        self.id = id; self.title = title; self.detail = detail; self.evidence = evidence; self.category = category
        self.targets = targets; self.expectedGain = expectedGain; self.risk = risk; self.reversible = reversible
        self.safety = safety; self.action = action; self.affected = affected; self.tradeoffs = tradeoffs
        self.status = status; self.priority = priority
    }
}

// MARK: - Session

public struct BoostSession: Codable, Identifiable, Sendable {
    public var id: UUID
    public var started: Date
    public var finished: Date?
    public var profile: BoostProfile
    public var phase: BoostPhase
    public var baseline: [BoostSample]
    public var final: [BoostSample]
    public var candidates: [BoostCandidate]
    public var changes: [ChangeRecord]
    public var evaluations: [String: ABResult]
    public var scoreBefore: BoostScore?
    public var scoreAfter: BoostScore?
    public var log: [String]
    public var notes: [String]

    public init(profile: BoostProfile, started: Date = Date()) {
        self.id = UUID(); self.started = started; self.profile = profile; self.phase = .idle
        self.baseline = []; self.final = []; self.candidates = []; self.changes = []; self.evaluations = [:]
        self.log = []; self.notes = []
    }
}
