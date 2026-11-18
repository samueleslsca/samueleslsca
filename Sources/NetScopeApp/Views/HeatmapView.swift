#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NetScopeCore

/// Wi-Fi Heatmap Engine: floor plan import, two-point scale calibration, walls, manual survey points,
/// IDW interpolation with "non mesuré" areas, placement comparison, AP suggestions, PDF export.
struct HeatmapView: View {
    @EnvironmentObject var model: AppModel
    @State private var projectID: UUID?
    @State private var tool: Tool = .measure
    @State private var metric: HeatmapMetric = .rssi
    @State private var placement = "Emplacement A"
    @State private var pending: CGPoint?
    @State private var calibrationMeters = "5"
    @State private var material: WallMaterial = .drywall
    @State private var info: String?
    @State private var measuring = false
    @State private var image: NSImage?

    static let legendSteps = [-50, -60, -67, -75, -85]

    enum Tool: String, CaseIterable { case measure = "Mesurer ici", calibrate = "Étalonner l’échelle", wall = "Tracer un mur", router = "Placer le routeur" }

    var project: HeatmapProject? { model.heatmapProjects.first { $0.id == projectID } ?? model.heatmapProjects.first }

    var body: some View {
        Page("Wi-Fi Heatmap", subtitle: "Cartographie de la couverture à partir de mesures réelles prises sur place — les zones non mesurées restent vides") {
            Card("Projet", symbol: "map") {
                HStack {
                    Picker("Projet", selection: Binding(get: { project?.id }, set: { projectID = $0; loadImage() })) {
                        ForEach(model.heatmapProjects) { Text($0.name).tag(Optional($0.id)) }
                    }.frame(width: 260)
                    Button("Nouveau projet avec un plan…") { newProject() }.glassButton()
                    Spacer()
                    if project != nil { Button("Exporter PDF") { exportPDF() }.glassButton() }
                }
                if let p = project {
                    HStack {
                        Picker("Outil", selection: $tool) { ForEach(Tool.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    }
                    HStack {
                        Picker("Métrique", selection: $metric) { ForEach(HeatmapMetric.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 240)
                        TextField("Emplacement du routeur", text: $placement).textFieldStyle(.roundedBorder).frame(width: 200)
                            .help("Les mesures sont regroupées par emplacement du routeur pour comparer plusieurs positions.")
                        if tool == .calibrate { TextField("Distance réelle (m)", text: $calibrationMeters).textFieldStyle(.roundedBorder).frame(width: 140) }
                        if tool == .wall { Picker("Matériau", selection: $material) { ForEach(WallMaterial.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 200) }
                    }
                    Text(help(for: tool)).font(.caption).foregroundStyle(.secondary)
                    KeyValueRow(label: "Échelle", value: p.pixelsPerMeter.map { String(format: "%.1f px/m · plan %.1f × %.1f m", $0, p.widthMeters, p.heightMeters) } ?? "Non étalonnée")
                    if let info { Text(info).font(.callout) }
                }
            }
            if let p = project {
                Card("Plan", symbol: "square.grid.3x3") {
                    canvas(p).aspectRatio(p.widthMeters / max(p.heightMeters, 0.1), contentMode: .fit).frame(maxHeight: 560)
                    legend
                }
                comparison(p)
            } else {
                EmptyStateView(title: "Aucun projet", symbol: "map", message: "Importez un plan 2D (image) de votre logement, étalonnez l’échelle avec deux points, puis déplacez-vous avec le Mac et cliquez sur votre position pour enregistrer une mesure.")
            }
            Card("Visualisation 3D", symbol: "cube") {
                Text("Non incluse dans cette version : la heatmap reste 2D. La simulation d’un point d’accès supplémentaire est disponible dans Network Map → Jumeau numérique.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear { loadImage() }
    }

    func help(for t: Tool) -> String {
        switch t {
        case .measure: return "Placez-vous à l’endroit voulu avec le Mac, puis cliquez sur votre position : RSSI, bruit, canal, bande, débit de liaison et latence passerelle sont mesurés à cet instant."
        case .calibrate: return "Cliquez deux points dont vous connaissez la distance réelle (ex. une porte, un mur), après avoir saisi cette distance."
        case .wall: return "Cliquez le début puis la fin du mur. Les murs servent à la simulation (atténuation indicative)."
        case .router: return "Cliquez la position du routeur pour l’emplacement saisi."
        }
    }

    func canvas(_ p: HeatmapProject) -> some View {
        GeometryReader { geo in
            let size = geo.size
            let sx = size.width / p.widthMeters, sy = size.height / p.heightMeters
            let grid = HeatmapEngine.interpolate(p, metric: metric, placement: placement, cellMeters: 0.5, maxRadius: 3)
            ZStack(alignment: .topLeading) {
                if let image { Image(nsImage: image).resizable().frame(width: size.width, height: size.height).opacity(0.85) }
                else { Rectangle().fill(.quaternary) }
                Canvas { ctx, _ in
                    for r in 0..<grid.rows { for c in 0..<grid.cols {
                        guard let v = grid.value(col: c, row: r) else { continue }
                        let rect = CGRect(x: Double(c) * grid.cellMeters * sx, y: Double(r) * grid.cellMeters * sy,
                                          width: grid.cellMeters * sx + 0.5, height: grid.cellMeters * sy + 0.5)
                        ctx.fill(Path(rect), with: .color(color(v).opacity(0.45)))
                    } }
                    for w in p.walls {
                        var path = Path()
                        path.move(to: CGPoint(x: w.a.x * sx, y: w.a.y * sy)); path.addLine(to: CGPoint(x: w.b.x * sx, y: w.b.y * sy))
                        ctx.stroke(path, with: .color(.primary), lineWidth: w.material == .concrete || w.material == .metal ? 4 : 2)
                    }
                    for s in p.samples where s.routerPlacement == placement {
                        let pt = CGRect(x: s.position.x * sx - 4, y: s.position.y * sy - 4, width: 8, height: 8)
                        ctx.fill(Path(ellipseIn: pt), with: .color(.white)); ctx.stroke(Path(ellipseIn: pt), with: .color(.black), lineWidth: 1)
                    }
                    if let r = p.routerPositions[placement] {
                        ctx.draw(Text(Image(systemName: "wifi.router.fill")).font(.title2), at: CGPoint(x: r.x * sx, y: r.y * sy))
                    }
                    for s in HeatmapEngine.suggestAccessPoints(p, placement: placement) {
                        ctx.draw(Text(Image(systemName: "plus.circle.fill")).font(.title2).foregroundColor(.green), at: CGPoint(x: s.x * sx, y: s.y * sy))
                    }
                    if let pend = pending { ctx.fill(Path(ellipseIn: CGRect(x: pend.x - 5, y: pend.y - 5, width: 10, height: 10)), with: .color(.orange)) }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { loc in tap(loc, size: size, project: p) }
            .overlay(alignment: .topTrailing) { if measuring { ProgressView().padding() } }
        }
    }

    var legend: some View {
        HStack(spacing: 12) {
            ForEach(Self.legendSteps, id: \.self) { v in
                HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(color(Double(v))).frame(width: 14, height: 10); Text("\(v) dBm").font(.caption2) }
            }
            HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).stroke(.secondary).frame(width: 14, height: 10); Text("Non mesuré").font(.caption2) }
            HStack(spacing: 4) { Image(systemName: "plus.circle.fill").foregroundStyle(.green); Text("Point d’accès suggéré (estimation)").font(.caption2) }
        }
    }

    /// Color for the active metric. RSSI scale is shown in the legend; other metrics are normalized.
    func color(_ v: Double) -> Color {
        let t: Double
        switch metric {
        case .rssi: t = (v + 85) / 35
        case .snr: t = (v - 10) / 30
        case .txRate: t = v / 800
        case .latency: t = 1 - (v - 2) / 30
        }
        let x = min(max(t, 0), 1)
        return Color(hue: x * 0.33, saturation: 0.9, brightness: 0.9)
    }

    func comparison(_ p: HeatmapProject) -> some View {
        Card("Comparaison des emplacements du routeur", symbol: "arrow.left.arrow.right") {
            let placements = Array(Set(p.samples.map(\.routerPlacement))).sorted()
            if placements.isEmpty { Text("Aucune mesure.").foregroundStyle(.secondary) }
            ForEach(placements, id: \.self) { pl in
                let c = HeatmapEngine.coverage(p, placement: pl)
                KeyValueRow(label: pl, value: "\(c.samples) mesures · RSSI médian \(c.medianRSSI.map { String(format: "%.0f dBm", $0) } ?? "—") · zones faibles \(c.weakFraction.map { String(format: "%.0f %%", $0 * 100) } ?? "—") · surface mesurée \(String(format: "%.0f %%", c.measuredFraction * 100))")
            }
            Text("Les zones « faibles » sont sous −75 dBm. Les suggestions de points d’accès sont des estimations à valider par une nouvelle campagne de mesures.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    func tap(_ loc: CGPoint, size: CGSize, project p0: HeatmapProject) {
        var p = p0
        let meters = Point2D(x: loc.x / size.width * p.widthMeters, y: loc.y / size.height * p.heightMeters)
        switch tool {
        case .measure:
            measuring = true
            Task {
                model.refreshWiFi()
                let w = model.wifi
                var lat: Double?
                if let gw = model.connection?.defaultGatewayIPv4 { lat = (try? await model.latencyService.ping(gw, count: 5, interval: 0.2))?.medianMs }
                p.samples.append(HeatmapSample(position: meters, rssi: w?.rssi.value, noise: w?.noise.value, channel: w?.channel.value, band: w?.band.value,
                                               bssid: w?.bssid.value, txRateMbps: w?.txRateMbps.value, gatewayLatencyMs: lat, routerPlacement: placement))
                model.saveHeatmap(p)
                info = "Mesure enregistrée : \(w?.rssi.value.map { "\($0) dBm" } ?? "RSSI indisponible")"
                measuring = false
            }
        case .calibrate:
            if let first = pending {
                let a = Point2D(x: first.x, y: first.y), b = Point2D(x: loc.x, y: loc.y)
                let imagePx = image.map { Double($0.size.width) / size.width } ?? 1
                if let m = Double(calibrationMeters.replacingOccurrences(of: ",", with: ".")),
                   let ppmView = HeatmapProject.pixelsPerMeter(p1: a, p2: b, meters: m) {
                    p.pixelsPerMeter = ppmView * imagePx
                    p.widthMeters = size.width / ppmView
                    p.heightMeters = size.height / ppmView
                    model.saveHeatmap(p)
                    info = String(format: "Échelle étalonnée : plan de %.1f × %.1f m", p.widthMeters, p.heightMeters)
                }
                pending = nil
            } else { pending = loc }
        case .wall:
            if let first = pending {
                p.walls.append(Wall(a: Point2D(x: first.x / size.width * p.widthMeters, y: first.y / size.height * p.heightMeters), b: meters, material: material))
                model.saveHeatmap(p); pending = nil
            } else { pending = loc }
        case .router:
            p.routerPositions[placement] = meters
            model.saveHeatmap(p)
        }
    }

    func planDirectory() -> URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("NetScopePro/plans", isDirectory: true)
    }

    func newProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .pdf, .heic, .tiff]
        guard panel.runModal() == .OK, let src = panel.url, let dir = planDirectory() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID()
        let dest = dir.appendingPathComponent(id.uuidString + "." + src.pathExtension)
        try? FileManager.default.copyItem(at: src, to: dest)
        let img = NSImage(contentsOf: dest)
        let ratio = img.map { $0.size.height / max($0.size.width, 1) } ?? 0.7
        let p = HeatmapProject(id: id, name: src.deletingPathExtension().lastPathComponent, floorPlanFile: dest.lastPathComponent,
                               widthMeters: 10, heightMeters: 10 * ratio)
        model.saveHeatmap(p); projectID = id; image = img
        info = "Plan importé. Étalonnez l’échelle avant de mesurer (dimensions provisoires : 10 m de large)."
    }

    func loadImage() {
        guard let f = project?.floorPlanFile, let dir = planDirectory() else { image = nil; return }
        image = NSImage(contentsOf: dir.appendingPathComponent(f))
    }

    @MainActor func exportPDF() {
        guard let p = project else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = "heatmap-\(p.name).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content = VStack(alignment: .leading, spacing: 8) {
            Text("NetScope Pro — Heatmap « \(p.name) »").font(.title2.bold())
            Text("\(metric.rawValue) · emplacement \(placement) · \(p.samples.filter { $0.routerPlacement == placement }.count) mesures · \(Date().shortDateTime)").font(.caption)
            canvas(p).frame(width: 760, height: 760 * p.heightMeters / max(p.widthMeters, 0.1))
            legend
            Text("Interpolation par pondération inverse de la distance (rayon 3 m). Les zones non colorées n’ont pas été mesurées. Les points d’accès suggérés sont des estimations.").font(.caption2)
        }
        .padding(24).frame(width: 808).environmentObject(model)
        let renderer = ImageRenderer(content: content)
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil); draw(ctx); ctx.endPDFPage(); ctx.closePDF()
        }
    }
}
#endif
