#if os(macOS)
import SwiftUI
import NetScopeCore

/// Observed topology. Confirmed links (router-reported or directly observed) are solid; assumed links dashed.
struct NetworkMapView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: UUID?
    @State private var categories: Set<DeviceCategory> = Set(DeviceCategory.allCases)
    @State private var onlyRecent = false

    var nodes: [NetworkDevice] {
        model.inventory.devices.filter { categories.contains($0.category) && $0.ipv4 != model.connection?.defaultGatewayIPv4 }
            .filter { !onlyRecent || [.activeNow, .reportedByRouter].contains($0.observationState()) }
    }

    var body: some View {
        Page("Network Map", subtitle: "Internet → box/routeur → réseau local → appareils, d’après les informations réellement disponibles") {
            HStack {
                Menu("Types d’appareils") {
                    ForEach(DeviceCategory.allCases, id: \.self) { c in
                        Toggle(c.label, isOn: Binding(get: { categories.contains(c) }, set: { on in if on { categories.insert(c) } else { categories.remove(c) } }))
                    }
                }.frame(width: 200)
                Toggle("Vus récemment uniquement", isOn: $onlyRecent)
                Spacer()
                Label("Lien confirmé", systemImage: "line.diagonal").foregroundStyle(.primary)
                Label("Lien supposé", systemImage: "line.diagonal").foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                Card("Topologie observée", symbol: "point.3.connected.trianglepath.dotted") { canvas.frame(minHeight: 460) }
                if let id = selected, let d = model.inventory.devices.first(where: { $0.id == id }) {
                    DeviceDetail(device: d).frame(width: 340)
                }
            }
            Card("Limites de la carte", symbol: "info.circle") {
                Text("Sans intégration routeur, NetScope sait seulement que les appareils partagent le sous-réseau du Mac : les liens vers la box sont alors « supposés ». Les points d’accès, répéteurs et la répartition Wi-Fi/Ethernet ne sont affichés que s’ils sont rapportés par le routeur. Aucune topologie n’est inventée.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            DigitalTwinCard()
        }
    }

    var canvas: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let internet = CGPoint(x: w / 2, y: 40)
            let router = CGPoint(x: w / 2, y: 140)
            let list = nodes
            let radius = min(w, h - 160) / 2.4
            let center = CGPoint(x: w / 2, y: 140 + radius + 30)
            let positions: [CGPoint] = list.indices.map { i in
                let a = Double(i) / Double(max(list.count, 1)) * .pi * 2 - .pi / 2
                return CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius * 0.75)
            }
            ZStack {
                Path { p in p.move(to: internet); p.addLine(to: router) }
                    .stroke(model.router.wan?.state == "up" || (model.pathStatus?.satisfied ?? false) ? Color.green : .red, lineWidth: 2)
                ForEach(list.indices, id: \.self) { i in
                    let d = list[i]
                    let confirmed = d.methods.contains(.router) || d.methods.contains(.selfDevice)
                    Path { p in p.move(to: router); p.addLine(to: positions[i]) }
                        .stroke(confirmed ? Color.primary.opacity(0.5) : Color.secondary.opacity(0.35),
                                style: StrokeStyle(lineWidth: confirmed ? 1.5 : 1, dash: confirmed ? [] : [5, 4]))
                }
                node("Internet", symbol: "globe", at: internet, tint: .blue)
                node(model.router.info?.model ?? "Box / routeur", symbol: "wifi.router", at: router, tint: .indigo)
                ForEach(list.indices, id: \.self) { i in
                    let d = list[i]
                    Button { selected = d.id } label: {
                        VStack(spacing: 2) {
                            Image(systemName: d.methods.contains(.selfDevice) ? "macbook" : d.category.symbol)
                                .font(.title3).frame(width: 34, height: 34)
                                .background(selected == d.id ? Color.accentColor.opacity(0.3) : Color.clear, in: Circle())
                                .foregroundStyle(d.trust == .toReview ? .orange : .primary)
                            Text(model.redact(d.displayName)).font(.caption2).lineLimit(1).frame(maxWidth: 90)
                            if let link = d.routerConnectionType { Text(link).font(.system(size: 9)).foregroundStyle(.secondary) }
                        }
                    }
                    .buttonStyle(.plain)
                    .position(positions[i])
                    .accessibilityLabel("\(d.displayName), \(d.category.label)")
                }
            }
        }
    }

    func node(_ title: String, symbol: String, at p: CGPoint, tint: Color) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint).frame(width: 40, height: 40).glassCard(cornerRadius: 20)
            Text(model.redact(title)).font(.caption.bold())
        }
        .position(p)
    }
}

/// Network Digital Twin: hypothetical scenarios, always labelled as simulations.
struct DigitalTwinCard: View {
    @EnvironmentObject var model: AppModel
    @State private var scenario = 0

    var body: some View {
        Card("Jumeau numérique — scénarios hypothétiques", symbol: "cube.transparent") {
            Picker("Scénario", selection: $scenario) {
                Text("Wi-Fi → Ethernet").tag(0); Text("Ajout d’un point d’accès").tag(1)
                Text("Réduction de la congestion").tag(2); Text("Activation QoS/SQM").tag(3)
            }.pickerStyle(.segmented)
            let r = result
            if let r {
                Label(r.disclaimer, systemImage: "exclamationmark.bubble").font(.callout.bold()).foregroundStyle(.orange)
                ForEach(r.predicted.keys.sorted(), id: \.self) { k in KeyValueRow(label: k, value: r.predicted[k], provenance: .estimated(model: "Simulation NetScope")) }
                ForEach(r.assumptions, id: \.self) { Text("Hypothèse : " + $0).font(.caption).foregroundStyle(.secondary) }
            } else {
                Text(missing).foregroundStyle(.secondary)
            }
        }
    }

    var result: SimulationResult? {
        let wanRef = model.speedTests.filter { $0.succeeded && model.ethernetInterfaceNames.contains($0.interfaceName ?? "") }.compactMap(\.downloadBps).max()
            ?? model.router.wan?.syncDownBps
        switch scenario {
        case 0: return NetworkSimulator.wifiToEthernet(currentWiFiDownBps: model.latestTest?.downloadBps, wanReferenceBps: wanRef)
        case 1:
            guard let p = model.heatmapProjects.first, let router = p.routerPositions.values.first else { return nil }
            let target = HeatmapEngine.suggestAccessPoints(p, placement: p.routerPositions.keys.first ?? "", max: 1).first ?? router
            let weakest = p.samples.min { ($0.rssi ?? 0) < ($1.rssi ?? 0) }?.position ?? Point2D(x: p.widthMeters, y: p.heightMeters)
            return NetworkSimulator.addAccessPoint(project: p, apPosition: target, client: weakest, noiseDBm: Double(model.wifi?.noise.value ?? -92))
        case 2:
            guard let bg = model.backgroundTrafficBps(seconds: 60) else { return nil }
            return NetworkSimulator.reduceCongestion(currentDownBps: model.latestTest?.downloadBps, backgroundBps: bg, linkCapacityBps: model.router.wan?.syncDownBps)
        default:
            return NetworkSimulator.enableSQM(idleMs: model.latestTest?.idleLatencyMs, loadedMs: model.latestTest?.worstLoadedLatencyMs)
        }
    }

    var missing: String {
        switch scenario {
        case 1: return "Créez un projet Wi-Fi Heatmap avec un emplacement de routeur et des mesures pour simuler un point d’accès."
        case 2: return "Aucune mesure de trafic de fond récente."
        default: return "Données insuffisantes."
        }
    }
}
#endif
