import Foundation

/// Privacy mode: masks IPv4/IPv6, MAC addresses and known SSIDs in any exported or displayed text.
public struct PrivacyRedactor: Sendable {
    public var enabled: Bool
    public var ssids: [String]
    public init(enabled: Bool, ssids: [String] = []) { self.enabled = enabled; self.ssids = ssids }

    public func redact(_ s: String) -> String {
        guard enabled else { return s }
        var out = s
        for ssid in ssids where !ssid.isEmpty { out = out.replacingOccurrences(of: ssid, with: "«SSID masqué»") }
        out = Self.replace(out, pattern: #"\b([0-9A-Fa-f]{1,2}[:-]){5}[0-9A-Fa-f]{1,2}\b"#, with: "••:••:••:••:••:••")
        out = Self.replace(out, pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, with: "x.x.x.x")
        out = Self.replace(out, pattern: #"\b(?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{1,4}\b|\b(?:[0-9A-Fa-f]{1,4}:){1,6}:(?:[0-9A-Fa-f]{1,4})?\b"#, with: "x:x::x")
        return out
    }

    static func replace(_ s: String, pattern: String, with r: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: r)
    }
}

public struct Report: Codable, Sendable {
    public struct Table: Codable, Sendable {
        public var header: [String]
        public var rows: [[String]]
        public init(header: [String], rows: [[String]]) { self.header = header; self.rows = rows }
    }
    public struct Section: Codable, Sendable {
        public var heading: String
        public var paragraphs: [String]
        public var bullets: [String]
        public var tables: [Table]
        public init(heading: String, paragraphs: [String] = [], bullets: [String] = [], tables: [Table] = []) {
            self.heading = heading; self.paragraphs = paragraphs; self.bullets = bullets; self.tables = tables
        }
    }
    public var title: String
    public var subtitle: String
    public var generatedAt: Date
    public var sections: [Section]

    public init(title: String, subtitle: String, generatedAt: Date = Date(), sections: [Section]) {
        self.title = title; self.subtitle = subtitle; self.generatedAt = generatedAt; self.sections = sections
    }

    public func redacted(_ r: PrivacyRedactor) -> Report {
        var c = self
        c.subtitle = r.redact(subtitle)
        c.sections = sections.map { s in
            Section(heading: r.redact(s.heading), paragraphs: s.paragraphs.map(r.redact), bullets: s.bullets.map(r.redact),
                    tables: s.tables.map { Table(header: $0.header, rows: $0.rows.map { $0.map(r.redact) }) })
        }
        return c
    }

    public func markdown() -> String {
        var o = "# \(title)\n\n_\(subtitle)_\n\nGénéré le \(ReportFormat.dateTime(generatedAt))\n"
        for s in sections {
            o += "\n## \(s.heading)\n\n"
            for p in s.paragraphs { o += p + "\n\n" }
            for b in s.bullets { o += "- \(b)\n" }
            if !s.bullets.isEmpty { o += "\n" }
            for t in s.tables {
                o += "| " + t.header.joined(separator: " | ") + " |\n|" + t.header.map { _ in "---" }.joined(separator: "|") + "|\n"
                for r in t.rows { o += "| " + r.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |\n" }
                o += "\n"
            }
        }
        return o
    }

    public func html() -> String {
        func e(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var o = """
        <!doctype html><html lang="fr"><head><meta charset="utf-8"><title>\(e(title))</title>
        <style>body{font:11pt -apple-system,Helvetica,sans-serif;color:#1d1d1f;margin:32px}h1{font-size:20pt;margin-bottom:0}
        h2{font-size:13pt;border-bottom:1px solid #d2d2d7;padding-bottom:4px;margin-top:22px}.sub{color:#6e6e73}
        table{border-collapse:collapse;width:100%;margin:8px 0}th,td{border:1px solid #d2d2d7;padding:4px 6px;text-align:left;font-size:9.5pt}
        th{background:#f5f5f7}</style></head><body>
        <h1>\(e(title))</h1><p class="sub">\(e(subtitle)) — généré le \(e(ReportFormat.dateTime(generatedAt)))</p>
        """
        for s in sections {
            o += "<h2>\(e(s.heading))</h2>"
            for p in s.paragraphs { o += "<p>\(e(p))</p>" }
            if !s.bullets.isEmpty { o += "<ul>" + s.bullets.map { "<li>\(e($0))</li>" }.joined() + "</ul>" }
            for t in s.tables {
                o += "<table><tr>" + t.header.map { "<th>\(e($0))</th>" }.joined() + "</tr>"
                for r in t.rows { o += "<tr>" + r.map { "<td>\(e($0))</td>" }.joined() + "</tr>" }
                o += "</table>"
            }
        }
        return o + "</body></html>"
    }

    public func json() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }
}

public enum ReportFormat {
    public static func dateTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR"); f.dateStyle = .long; f.timeStyle = .short
        return f.string(from: d)
    }
    public static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
}

public enum ReportBuilder {
    public static let limitations = [
        "Les débits Internet sont mesurés avec Apple networkQuality vers les serveurs Apple ; un autre serveur peut donner un résultat différent.",
        "Un test isolé ne permet pas de conclusion définitive : les résultats varient selon l’heure, la charge et le serveur.",
        "Les mesures Wi-Fi dépendent de la position du Mac au moment de la mesure.",
        "Les appareils « observés » ne représentent pas nécessairement la totalité des appareils connectés.",
        "Aucune donnée n’a été simulée : les valeurs absentes sont indiquées comme non disponibles.",
    ]

    public static func speedTestTable(_ tests: [SpeedTestResult]) -> Report.Table {
        Report.Table(header: ["Date", "Mode", "Interface", "↓", "↑", "Latence repos", "Latence charge", "RPM", "VPN"],
                     rows: tests.map { t in
                        [ReportFormat.dateTime(t.timestamp), t.mode.label, t.interfaceName ?? "—",
                         t.downloadBps.map(Units.bitRate) ?? "—", t.uploadBps.map(Units.bitRate) ?? "—",
                         Units.ms(t.idleLatencyMs), Units.ms(t.worstLoadedLatencyMs),
                         t.responsivenessRPM.map { String(format: "%.0f", $0) } ?? "—", t.vpnActive ? "oui" : "non"]
                     })
    }

    public static func diagnostic(_ d: DiagnosticReport, tests: [SpeedTestResult], network: String?) -> Report {
        var sections = [Report.Section(heading: "Faits observés", bullets: d.observedFacts)]
        if !d.dataGaps.isEmpty { sections.append(.init(heading: "Données manquantes", bullets: d.dataGaps)) }
        for h in d.hypotheses {
            var b = h.supporting.map { "✔︎ " + $0 } + h.contradicting.map { "✘ " + $0 }
            b += h.nextChecks.map { "→ Vérification : " + $0 }
            sections.append(.init(heading: "Hypothèse : \(h.cause.rawValue) (confiance \(h.confidence.label.lowercased()))",
                                  paragraphs: h.symptoms, bullets: b,
                                  tables: h.recommendations.isEmpty ? [] : [Report.Table(header: ["Action", "Effet", "Efficacité", "Risque", "Réversible"],
                                    rows: h.recommendations.map { [$0.title, $0.impact.rawValue, $0.expectedEffectiveness.label, $0.risk.rawValue, $0.reversible ? "oui" : "non"] })]))
        }
        if !tests.isEmpty { sections.append(.init(heading: "Mesures de débit", tables: [speedTestTable(tests)])) }
        sections.append(.init(heading: "Méthode et limites", paragraphs: [BufferbloatAnalyzer.methodology], bullets: limitations))
        return Report(title: "NetScope Pro — Rapport de diagnostic", subtitle: network.map { "Réseau : \($0)" } ?? "Réseau actuel",
                      generatedAt: d.timestamp, sections: sections)
    }

    /// "Rapport technique pour mon opérateur Internet".
    public static func ispReport(profile: ISPProfile, audit: ISPAuditResult, tests: [SpeedTestResult], health: HealthReport?) -> Report {
        var sections: [Report.Section] = [
            .init(heading: "Abonnement déclaré", tables: [Report.Table(header: ["Élément", "Valeur"], rows: [
                ["Opérateur", profile.provider], ["Offre", profile.plan], ["Type d’accès", profile.accessType.rawValue],
                ["Débit commercial ↓ / ↑", "\(profile.advertisedDownBps.map(Units.bitRate) ?? "—") / \(profile.advertisedUpBps.map(Units.bitRate) ?? "—")"],
                ["Débit garanti ↓ / ↑", "\(profile.guaranteedDownBps.map(Units.bitRate) ?? "non renseigné") / \(profile.guaranteedUpBps.map(Units.bitRate) ?? "non renseigné")"],
            ])]),
            .init(heading: "Synthèse des mesures", bullets: [
                "Tests valides : \(audit.totalTests), dont \(audit.ethernetTests) en Ethernet",
                "Débit descendant médian : \(audit.medianDownBps.map(Units.bitRate) ?? "—") (Ethernet : \(audit.ethernetMedianDownBps.map(Units.bitRate) ?? "—"))",
                "Débit montant médian : \(audit.medianUpBps.map(Units.bitRate) ?? "—") (Ethernet : \(audit.ethernetMedianUpBps.map(Units.bitRate) ?? "—"))",
            ] + audit.findings),
        ]
        if let h = health {
            sections.append(.init(heading: "Historique des incidents",
                                  paragraphs: [String(format: "Disponibilité mesurée : %@ sur la période, %d coupure(s), durée totale %.0f min.",
                                                      h.availabilityPercent.map { String(format: "%.2f %%", $0) } ?? "—", h.outages.count, h.totalDowntime / 60)],
                                  tables: [Report.Table(header: ["Début", "Fin", "Durée", "Type"], rows: h.outages.map {
                                      [ReportFormat.dateTime($0.start), $0.end.map(ReportFormat.dateTime) ?? "en cours",
                                       $0.duration.map { String(format: "%.0f s", $0) } ?? "—", $0.kind.rawValue] })]))
        }
        sections.append(.init(heading: "Détail des tests", tables: [speedTestTable(tests)]))
        sections.append(.init(heading: "Vérifications restantes", bullets: audit.remainingChecks.isEmpty ? ["Aucune"] : audit.remainingChecks))
        sections.append(.init(heading: "Méthode et limites", paragraphs: [audit.disclaimer], bullets: limitations))
        return Report(title: "Rapport technique pour mon opérateur Internet", subtitle: "\(profile.provider) — \(profile.plan)", sections: sections)
    }
}

public enum CSVExport {
    public static func speedTests(_ t: [SpeedTestResult]) -> String {
        CSV.document(header: ["timestamp", "mode", "engine", "server", "interface", "network", "download_bps", "upload_bps",
                              "idle_latency_ms", "dl_loaded_latency_ms", "ul_loaded_latency_ms", "jitter_ms", "loss_percent",
                              "responsiveness_rpm", "vpn", "proxy", "error"],
                     rows: t.map { r in
                        [ReportFormat.iso(r.timestamp), r.mode.rawValue, r.engine.rawValue, r.server ?? "", r.interfaceName ?? "", r.networkName ?? "",
                         r.downloadBps.map { String(format: "%.0f", $0) } ?? "", r.uploadBps.map { String(format: "%.0f", $0) } ?? "",
                         f(r.idleLatencyMs), f(r.downloadLoadedLatencyMs), f(r.uploadLoadedLatencyMs), f(r.jitterMs), f(r.packetLossPercent),
                         f(r.responsivenessRPM), r.vpnActive ? "1" : "0", r.proxyActive ? "1" : "0", r.error ?? ""]
                     })
    }

    public static func devices(_ d: [NetworkDevice], redactor: PrivacyRedactor) -> String {
        CSV.document(header: ["name", "category", "confidence", "ipv4", "mac", "randomized_mac", "vendor", "vendor_source",
                              "first_seen", "last_seen", "methods", "trust"],
                     rows: d.map { x in
                        [redactor.redact(x.displayName), x.category.label, x.categoryConfidence.label, redactor.redact(x.ipv4 ?? ""),
                         redactor.enabled ? (x.mac.map(MACAddress.redact) ?? "") : (x.mac ?? ""), x.isRandomizedMAC ? "1" : "0",
                         x.vendor ?? "", x.vendorProvenance?.category.label ?? "", ReportFormat.iso(x.firstSeen), ReportFormat.iso(x.lastSeen),
                         x.methods.map(\.rawValue).joined(separator: "; "), x.trust.label]
                     })
    }

    public static func health(_ s: [HealthSample]) -> String {
        CSV.document(header: ["timestamp", "interface", "gateway_reachable", "gateway_rtt_ms", "internet_reachable", "internet_rtt_ms",
                              "internet_loss_percent", "dns_ok", "dns_ms"],
                     rows: s.map { x in
                        [ReportFormat.iso(x.timestamp), x.interface ?? "", b(x.gatewayReachable), f(x.gatewayRTTms), x.internetReachable ? "1" : "0",
                         f(x.internetRTTms), f(x.internetLossPercent), b(x.dnsOK), f(x.dnsMs)]
                     })
    }

    static func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "" }
    static func b(_ v: Bool?) -> String { v.map { $0 ? "1" : "0" } ?? "" }
}
