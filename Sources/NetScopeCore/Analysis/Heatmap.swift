import Foundation

public struct Point2D: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public func distance(to o: Point2D) -> Double { ((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y)).squareRoot() }
}

public enum WallMaterial: String, Codable, CaseIterable, Sendable {
    case drywall = "Cloison légère", brick = "Brique", concrete = "Béton", glass = "Vitre", wood = "Bois", metal = "Métal"
    /// Typical 5 GHz attenuation (dB) — rough planning values used for simulation only.
    public var attenuationDB: Double {
        switch self {
        case .drywall: return 3; case .wood: return 4; case .glass: return 2
        case .brick: return 8; case .concrete: return 15; case .metal: return 25
        }
    }
}

public struct Wall: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var a: Point2D
    public var b: Point2D
    public var material: WallMaterial
    public init(id: UUID = UUID(), a: Point2D, b: Point2D, material: WallMaterial) { self.id = id; self.a = a; self.b = b; self.material = material }
}

public struct HeatmapSample: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: Date
    /// Position in meters on the floor plan.
    public var position: Point2D
    public var rssi: Int?
    public var noise: Int?
    public var channel: Int?
    public var band: WiFiBand?
    public var bssid: String?
    public var txRateMbps: Double?
    public var gatewayLatencyMs: Double?
    public var routerPlacement: String
    public var snr: Int? { guard let r = rssi, let n = noise, n < 0 else { return nil }; return r - n }

    public init(id: UUID = UUID(), timestamp: Date = Date(), position: Point2D, rssi: Int?, noise: Int?, channel: Int?,
                band: WiFiBand?, bssid: String?, txRateMbps: Double?, gatewayLatencyMs: Double?, routerPlacement: String) {
        self.id = id; self.timestamp = timestamp; self.position = position; self.rssi = rssi; self.noise = noise
        self.channel = channel; self.band = band; self.bssid = bssid; self.txRateMbps = txRateMbps
        self.gatewayLatencyMs = gatewayLatencyMs; self.routerPlacement = routerPlacement
    }
}

public struct HeatmapProject: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var floorPlanFile: String?
    /// Plan size in meters (after calibration).
    public var widthMeters: Double
    public var heightMeters: Double
    /// Pixels per meter of the imported image, set by the two-point calibration.
    public var pixelsPerMeter: Double?
    public var walls: [Wall]
    public var samples: [HeatmapSample]
    public var routerPositions: [String: Point2D]
    public var created: Date

    public init(id: UUID = UUID(), name: String, floorPlanFile: String? = nil, widthMeters: Double, heightMeters: Double,
                pixelsPerMeter: Double? = nil, walls: [Wall] = [], samples: [HeatmapSample] = [],
                routerPositions: [String: Point2D] = [:], created: Date = Date()) {
        self.id = id; self.name = name; self.floorPlanFile = floorPlanFile; self.widthMeters = widthMeters
        self.heightMeters = heightMeters; self.pixelsPerMeter = pixelsPerMeter; self.walls = walls; self.samples = samples
        self.routerPositions = routerPositions; self.created = created
    }

    /// Two-point calibration: two pixel positions and the real distance between them.
    public static func pixelsPerMeter(p1: Point2D, p2: Point2D, meters: Double) -> Double? {
        guard meters > 0 else { return nil }
        let d = p1.distance(to: p2)
        return d > 0 ? d / meters : nil
    }
}

public struct HeatmapGrid: Sendable {
    public var cols: Int
    public var rows: Int
    public var cellMeters: Double
    /// Interpolated value per cell; nil = not measured (too far from any sample).
    public var values: [Double?]
    public func value(col: Int, row: Int) -> Double? { values[row * cols + col] }
    public var measuredFraction: Double { values.isEmpty ? 0 : Double(values.compactMap { $0 }.count) / Double(values.count) }
}

public enum HeatmapMetric: String, CaseIterable, Codable, Sendable { case rssi = "RSSI", snr = "SNR", txRate = "Débit de liaison", latency = "Latence passerelle" }

public enum HeatmapEngine {
    /// Inverse-distance-weighted interpolation (power 2). Cells farther than `maxRadius` from every
    /// sample stay nil and are rendered as "non mesuré" — the map never extrapolates into unknown areas.
    public static func interpolate(_ project: HeatmapProject, metric: HeatmapMetric, placement: String?,
                                   cellMeters: Double = 0.5, maxRadius: Double = 3.0) -> HeatmapGrid {
        let pts: [(Point2D, Double)] = project.samples
            .filter { placement == nil || $0.routerPlacement == placement }
            .compactMap { s in
                let v: Double?
                switch metric {
                case .rssi: v = s.rssi.map(Double.init)
                case .snr: v = s.snr.map(Double.init)
                case .txRate: v = s.txRateMbps
                case .latency: v = s.gatewayLatencyMs
                }
                return v.map { (s.position, $0) }
            }
        let cols = max(1, Int((project.widthMeters / cellMeters).rounded(.up)))
        let rows = max(1, Int((project.heightMeters / cellMeters).rounded(.up)))
        var values = [Double?](repeating: nil, count: cols * rows)
        guard !pts.isEmpty else { return HeatmapGrid(cols: cols, rows: rows, cellMeters: cellMeters, values: values) }
        for r in 0..<rows {
            for c in 0..<cols {
                let p = Point2D(x: (Double(c) + 0.5) * cellMeters, y: (Double(r) + 0.5) * cellMeters)
                var num = 0.0, den = 0.0, near = false, exact: Double?
                for (q, v) in pts {
                    let d = p.distance(to: q)
                    if d < 1e-6 { exact = v; break }
                    if d <= maxRadius { near = true; let w = 1 / (d * d); num += w * v; den += w }
                }
                if let e = exact { values[r * cols + c] = e } else if near, den > 0 { values[r * cols + c] = num / den }
            }
        }
        return HeatmapGrid(cols: cols, rows: rows, cellMeters: cellMeters, values: values)
    }

    public struct CoverageSummary: Codable, Hashable, Sendable {
        public var placement: String
        public var samples: Int
        public var medianRSSI: Double?
        public var weakFraction: Double?
        public var measuredFraction: Double
    }

    public static func coverage(_ project: HeatmapProject, placement: String, weakThreshold: Int = Thresholds.rssiFair) -> CoverageSummary {
        let grid = interpolate(project, metric: .rssi, placement: placement)
        let measured = grid.values.compactMap { $0 }
        let weak = measured.isEmpty ? nil : Double(measured.filter { $0 < Double(weakThreshold) }.count) / Double(measured.count)
        let s = project.samples.filter { $0.routerPlacement == placement }
        return CoverageSummary(placement: placement, samples: s.count, medianRSSI: Stats.median(s.compactMap { $0.rssi.map(Double.init) }),
                               weakFraction: weak, measuredFraction: grid.measuredFraction)
    }

    /// Suggests positions for an additional access point: centroid of the largest weak region,
    /// pulled 30 % toward the existing router so the new AP keeps a usable backhaul.
    public static func suggestAccessPoints(_ project: HeatmapProject, placement: String, max count: Int = 2) -> [Point2D] {
        let grid = interpolate(project, metric: .rssi, placement: placement)
        var weakCells: [Point2D] = []
        for r in 0..<grid.rows { for c in 0..<grid.cols {
            if let v = grid.value(col: c, row: r), v < Double(Thresholds.rssiFair) {
                weakCells.append(Point2D(x: (Double(c) + 0.5) * grid.cellMeters, y: (Double(r) + 0.5) * grid.cellMeters))
            }
        } }
        guard !weakCells.isEmpty else { return [] }
        // Simple k-means on weak cells.
        let k = min(count, weakCells.count)
        var centers = (0..<k).map { weakCells[$0 * weakCells.count / k] }
        for _ in 0..<10 {
            var groups = [[Point2D]](repeating: [], count: k)
            for p in weakCells { let i = centers.indices.min { p.distance(to: centers[$0]) < p.distance(to: centers[$1]) }!; groups[i].append(p) }
            centers = groups.enumerated().map { i, g in g.isEmpty ? centers[i] : Point2D(x: g.map(\.x).reduce(0, +) / Double(g.count), y: g.map(\.y).reduce(0, +) / Double(g.count)) }
        }
        if let router = project.routerPositions[placement] {
            centers = centers.map { Point2D(x: $0.x + (router.x - $0.x) * 0.3, y: $0.y + (router.y - $0.y) * 0.3) }
        }
        return centers
    }
}
