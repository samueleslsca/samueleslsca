#if os(macOS)
import SwiftUI
import NetScopeCore
import NetScopeSystem

struct NetScopeProApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("NetScope Pro", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { model.start() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Quick Test") { model.startSpeedTest(.quick) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(model.runningTest != nil)
                Button("Rafraîchir la connexion") { Task { await model.refreshConnection() } }
                    .keyboardShortcut("r", modifiers: [.command])
            }
        }

        MenuBarExtra {
            MenuBarView().environmentObject(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(model).frame(width: 640, height: 560)
        }
    }
}

extension AppModel {
    var menuBarSymbol: String {
        guard pathStatus?.satisfied ?? true else { return "wifi.exclamationmark" }
        if isWired { return "cable.connector" }
        switch wifi?.rssi.value ?? -100 {
        case (-60)...: return "wifi"
        case (-72)...: return "wifi"
        default: return "wifi.exclamationmark"
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard, speedtest, wifi, devices, map, router, traffic, security, diagnostics, history
    case bufferbloat, health, multipoint, heatmap, isp, gaming
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .speedtest: return "Speedtest"
        case .wifi: return "Wi-Fi Analyzer"
        case .devices: return "Connected Devices"
        case .map: return "Network Map"
        case .router: return "Router Control"
        case .traffic: return "Traffic Monitor"
        case .security: return "Security Center"
        case .diagnostics: return "Diagnostics & Optimization"
        case .history: return "History & Reports"
        case .bufferbloat: return "Bufferbloat & QoS Lab"
        case .health: return "Internet Health Monitor"
        case .multipoint: return "Multi-point Diagnostics"
        case .heatmap: return "Wi-Fi Heatmap"
        case .isp: return "ISP Performance Audit"
        case .gaming: return "Gaming Network Lab"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .speedtest: return "speedometer"
        case .wifi: return "wifi"
        case .devices: return "laptopcomputer.and.iphone"
        case .map: return "point.3.connected.trianglepath.dotted"
        case .router: return "wifi.router"
        case .traffic: return "arrow.up.arrow.down"
        case .security: return "lock.shield"
        case .diagnostics: return "stethoscope"
        case .history: return "chart.xyaxis.line"
        case .bufferbloat: return "hourglass"
        case .health: return "waveform.path.ecg"
        case .multipoint: return "point.topleft.down.to.point.bottomright.curvepath"
        case .heatmap: return "map"
        case .isp: return "building.columns"
        case .gaming: return "gamecontroller"
        }
    }

    static let main: [SidebarItem] = [.dashboard, .speedtest, .wifi, .devices, .map, .router, .traffic, .security, .diagnostics, .history]
    static let labs: [SidebarItem] = [.bufferbloat, .health, .multipoint, .heatmap, .isp, .gaming]
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: SidebarItem? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("NetScope") {
                    ForEach(SidebarItem.main) { item in Label(item.title, systemImage: item.symbol).tag(item) }
                }
                Section("Laboratoires") {
                    ForEach(SidebarItem.labs) { item in Label(item.title, systemImage: item.symbol).tag(item) }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240)
            .safeAreaInset(edge: .bottom) { SidebarStatus().padding(10) }
        } detail: {
            Group {
                switch selection ?? .dashboard {
                case .dashboard: DashboardView(selection: $selection)
                case .speedtest: SpeedtestView()
                case .wifi: WiFiAnalyzerView()
                case .devices: DevicesView()
                case .map: NetworkMapView()
                case .router: RouterControlView()
                case .traffic: TrafficMonitorView()
                case .security: SecurityCenterView()
                case .diagnostics: DiagnosticsView()
                case .history: HistoryReportsView()
                case .bufferbloat: BufferbloatLabView()
                case .health: HealthMonitorView()
                case .multipoint: MultipointView()
                case .heatmap: HeatmapView()
                case .isp: ISPAuditView()
                case .gaming: GamingLabView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $model.settings.privacyMode) { Label("Mode confidentialité", systemImage: "eye.slash") }
                        .help("Masque IP, MAC et SSID à l’écran et dans les exports")
                }
            }
        }
    }
}

struct SidebarStatus: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: (model.pathStatus?.satisfied ?? false) ? .green : .red)
            VStack(alignment: .leading, spacing: 1) {
                Text((model.pathStatus?.satisfied ?? false) ? "Connecté" : "Hors ligne").font(.caption.weight(.semibold))
                Text(model.connection?.primaryInterface.map { "\($0.kind.label) · \($0.bsdName)" } ?? "—")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if model.runningTest != nil { ProgressView().controlSize(.small) }
        }
        .padding(8).glassCard(cornerRadius: 10)
    }
}
#endif
