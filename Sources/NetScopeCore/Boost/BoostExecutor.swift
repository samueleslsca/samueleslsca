import Foundation

/// Router-side SQM operations (implemented by `OpenWrtAdapter`).
public protocol SQMTuning: Sendable {
    func readSQM() async throws -> [SQMSettings]
    func stageSQM(_ s: SQMSettings, restoring: Bool) async throws
    func applyWithRollback(timeout: Int) async throws
    func confirmApply() async throws
    func isReachable() async -> Bool
}

extension OpenWrtAdapter: SQMTuning {}

/// Mac-side "ask an application to quit" (graceful, never forced). Implemented in NetScopeSystem.
public protocol ApplicationQuitting: Sendable {
    func quittableNames() async -> Set<String>
    func requestQuit(pid: Int, name: String) async throws
}

public enum BoostExecutionError: Error, LocalizedError, Equatable {
    case unsupported(String), notFound(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported(let m): return "Action non prise en charge : \(m)"
        case .notFound(let m): return "Introuvable : \(m)"
        }
    }
}

/// Executes the supported MAX BOOST actions. Guided actions are never executed.
public struct StandardBoostExecutor: BoostChangeExecutor {
    let sqm: SQMTuning?
    let apps: ApplicationQuitting?
    let rollbackTimeout: Int

    public init(sqm: SQMTuning?, apps: ApplicationQuitting?, rollbackTimeout: Int = 60) {
        self.sqm = sqm; self.apps = apps; self.rollbackTimeout = rollbackTimeout
    }

    public func snapshot(before action: BoostAction) async throws -> BoostAction? {
        switch action {
        case .guided: return nil
        case .quitApplication: return nil   // relaunch is up to the user
        case .routerSQM(let s):
            guard let sqm else { throw BoostExecutionError.unsupported("aucun routeur avec SQM connecté") }
            guard let prev = try await sqm.readSQM().first(where: { $0.section == s.section }) else { throw BoostExecutionError.notFound("section SQM \(s.section)") }
            return .routerSQM(prev)
        }
    }

    public func apply(_ action: BoostAction) async throws {
        switch action {
        case .guided: throw BoostExecutionError.unsupported("action guidée")
        case .quitApplication(let pid, let name):
            guard let apps else { throw BoostExecutionError.unsupported("fermeture d’application") }
            try await apps.requestQuit(pid: pid, name: name)
        case .routerSQM(let s):
            guard let sqm else { throw BoostExecutionError.unsupported("aucun routeur avec SQM connecté") }
            try await sqm.stageSQM(s, restoring: false)
            try await sqm.applyWithRollback(timeout: rollbackTimeout)
        }
    }

    public func isReachable(after action: BoostAction) async -> Bool {
        if case .routerSQM = action { return await sqm?.isReachable() ?? false }
        return true
    }

    public func confirm(_ action: BoostAction) async throws {
        if case .routerSQM = action { try await sqm?.confirmApply() }
    }

    public func restore(_ snapshot: BoostAction) async throws {
        switch snapshot {
        case .routerSQM(let s):
            guard let sqm else { throw BoostExecutionError.unsupported("routeur déconnecté") }
            try await sqm.stageSQM(s, restoring: true)
            try await sqm.applyWithRollback(timeout: rollbackTimeout)
        default: throw BoostExecutionError.unsupported("restauration automatique")
        }
    }
}
