#if os(macOS)
import AppKit
import NetScopeCore

/// Asks a regular (Dock-visible) application to quit normally, exactly like ⌘Q: the app may save, ask the user
/// or refuse. Never force-terminates, never touches background daemons or system processes.
public struct AppQuitService: ApplicationQuitting {
    public init() {}

    public enum QuitError: Error, LocalizedError {
        case notARegularApp(String), refused(String)
        public var errorDescription: String? {
            switch self {
            case .notARegularApp(let n): return "« \(n) » n’est pas une application standard : NetScope ne la ferme pas (mettez son transfert en pause manuellement)."
            case .refused(let n): return "« \(n) » n’a pas accepté de quitter (document non enregistré ou refus de l’application)."
            }
        }
    }

    @MainActor static func regularApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && !($0.bundleIdentifier ?? "").hasPrefix("com.apple.finder")
        }
    }

    public func quittableNames() async -> Set<String> {
        await MainActor.run {
            Set(Self.regularApps().flatMap { app in [app.localizedName, app.executableURL?.lastPathComponent].compactMap { $0 } })
        }
    }

    public func requestQuit(pid: Int, name: String) async throws {
        let ok: Bool = try await MainActor.run {
            let byPID = NSRunningApplication(processIdentifier: pid_t(pid))
            let target = (byPID?.activationPolicy == .regular ? byPID : nil)
                ?? Self.regularApps().first { $0.localizedName == name || $0.executableURL?.lastPathComponent == name }
            guard let app = target else { throw QuitError.notARegularApp(name) }
            return app.terminate()
        }
        if !ok { throw QuitError.refused(name) }
    }
}
#endif
