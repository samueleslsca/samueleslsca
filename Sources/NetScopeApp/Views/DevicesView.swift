#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NetScopeCore

struct DevicesView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var categoryFilter: DeviceCategory?
    @State private var trustFilter: TrustState?
    @State private var selected: NetworkDevice.ID?
    @State private var sortOrder = [KeyPathComparator(\NetworkDevice.lastSeen, order: .reverse)]
    @State private var confirmProbe = false

    var filtered: [NetworkDevice] {
        model.inventory.search(query)
            .filter { categoryFilter == nil || $0.category == categoryFilter }
            .filter { trustFilter == nil || $0.trust == trustFilter }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Page("Connected Devices", subtitle: "Appareils observés sur votre réseau local (ARP, IPv6, Bonjour, routeur) — l’absence de réponse ne signifie pas déconnexion") {
            Card("Découverte", symbol: "dot.radiowaves.right") {
                HStack {
                    Button(model.discovering ? "Découverte…" : "Découvrir (passif)") { Task { await model.discoverDevices() } }
                        .disabled(model.discovering).prominentGlassButton()
                    Button("Sondage actif du sous-réseau…") { confirmProbe = true }
                        .disabled(model.discovering || model.connection?.primaryInterface?.ipv4.first?.subnet == nil).glassButton()
                    if let p = model.discoveryProgress { ProgressView(value: Double(p.0), total: Double(max(p.1, 1))).frame(width: 160); Text("\(p.0)/\(p.1)").font(.caption) }
                    Spacer()
                    Button("Exporter CSV") { exportCSV() }.glassButton()
                }
                Text("Passif : lecture des caches ARP/NDP et écoute Bonjour (aucune connexion aux appareils). Actif : un ping par adresse de votre sous-réseau privé, 16 au maximum en parallèle, uniquement après votre accord.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.oui.isEmpty {
                    Text("Fabricants : aucune base OUI importée (Réglages → Importer oui.csv de l’IEEE). Les fabricants fournis par la box restent affichés.").font(.caption).foregroundStyle(.tertiary)
                }
            }
            HStack {
                TextField("Rechercher (nom, IP, MAC, fabricant)", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Picker("Catégorie", selection: $categoryFilter) {
                    Text("Toutes").tag(DeviceCategory?.none)
                    ForEach(DeviceCategory.allCases, id: \.self) { Text($0.label).tag(DeviceCategory?.some($0)) }
                }.frame(width: 200)
                Picker("État", selection: $trustFilter) {
                    Text("Tous").tag(TrustState?.none)
                    ForEach(TrustState.allCases, id: \.self) { Text($0.label).tag(TrustState?.some($0)) }
                }.frame(width: 200)
            }
            HStack(alignment: .top, spacing: 16) {
                Table(filtered, selection: $selected, sortOrder: $sortOrder) {
                    TableColumn("") { (d: NetworkDevice) in Image(systemName: d.category.symbol).foregroundStyle(d.trust == .toReview ? .orange : .accentColor) }.width(24)
                    TableColumn("Nom", value: \.displayName) { (d: NetworkDevice) in Text(model.redact(d.displayName)) }
                    TableColumn("IP") { (d: NetworkDevice) in Text(model.redact(d.ipv4 ?? d.ipv6.first ?? "—")).monospacedDigit() }.width(120)
                    TableColumn("Catégorie") { (d: NetworkDevice) in Text(d.category.label) }.width(120)
                    TableColumn("État") { (d: NetworkDevice) in Text(d.observationState().rawValue).font(.caption) }.width(150)
                    TableColumn("Vu", value: \.lastSeen) { (d: NetworkDevice) in Text(d.lastSeen.relative).font(.caption) }.width(110)
                }
                .frame(minHeight: 380)
                if let id = selected, let d = model.inventory.devices.first(where: { $0.id == id }) {
                    DeviceDetail(device: d).frame(width: 360)
                }
            }
            PeripheralsCard()
        }
        .confirmationDialog("Sondage actif du sous-réseau", isPresented: $confirmProbe) {
            Button("Sonder \(model.connection?.primaryInterface?.ipv4.first?.subnet?.description ?? "")") {
                model.settings.acknowledgedActiveProbe = true
                Task { await model.activeProbe() }
            }
        } message: {
            Text("NetScope enverra un ping (ICMP) à chaque adresse de votre sous-réseau local privé, puis relira le cache ARP. Aucune connexion aux services des appareils. N’utilisez cette fonction que sur un réseau qui vous appartient ou pour lequel vous êtes autorisé.")
        }
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "netscope-inventaire.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? CSVExport.devices(model.inventory.devices, redactor: model.redactor).write(to: url, atomically: true, encoding: .utf8)
    }
}

struct DeviceDetail: View {
    @EnvironmentObject var model: AppModel
    var device: NetworkDevice
    @State private var label = ""

    var body: some View {
        Card("Détails", symbol: device.category.symbol) {
            TextField("Nom local", text: $label, onCommit: { model.inventory.setLabel(label, for: device.id); model.saveInventory() })
                .textFieldStyle(.roundedBorder)
                .onAppear { label = device.userLabel ?? "" }
                .onChange(of: device.id) { _ in label = device.userLabel ?? "" }
            Picker("Statut", selection: Binding(get: { device.trust }, set: { model.inventory.setTrust($0, for: device.id); model.saveInventory() })) {
                ForEach(TrustState.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Catégorie", selection: Binding(get: { device.category }, set: { model.inventory.setCategory($0, for: device.id); model.saveInventory() })) {
                ForEach(DeviceCategory.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            KeyValueRow(label: "IPv4", value: device.ipv4)
            if !device.ipv6.isEmpty { KeyValueRow(label: "IPv6", value: device.ipv6.joined(separator: "\n")) }
            KeyValueRow(label: "MAC", value: device.mac.map { model.settings.privacyMode ? MACAddress.redact($0) : $0 })
            if device.isRandomizedMAC {
                Label("Adresse MAC privée/aléatoire : le même appareil peut apparaître sous plusieurs entrées dans le temps, et le fabricant ne peut pas être déduit.", systemImage: "shuffle")
                    .font(.caption).foregroundStyle(.orange)
            }
            KeyValueRow(label: "Fabricant", value: device.vendor, provenance: device.vendorProvenance)
            KeyValueRow(label: "Noms", value: device.hostnames.isEmpty ? nil : device.hostnames.joined(separator: ", "))
            KeyValueRow(label: "Services", value: device.services.isEmpty ? nil : device.services.joined(separator: ", "))
            KeyValueRow(label: "Interface", value: device.interface)
            KeyValueRow(label: "Liaison (routeur)", value: device.routerConnectionType)
            KeyValueRow(label: "Découvert par", value: device.methods.map(\.rawValue).joined(separator: ", "))
            KeyValueRow(label: "Première / dernière observation", value: "\(device.firstSeen.shortDateTime)\n\(device.lastSeen.shortDateTime)")
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text("Identification").font(.caption.bold()); ConfidenceLabel(confidence: device.categoryConfidence) }
                ForEach(device.categoryEvidence, id: \.self) { Text("• " + $0).font(.caption).foregroundStyle(.secondary) }
            }
            if device.appearances.count > 1 {
                Text("Apparitions : " + device.appearances.suffix(5).map(\.shortDateTime).joined(separator: ", ")).font(.caption2)
            }
            Button("Supprimer de l’inventaire", role: .destructive) { model.inventory.remove(device.id); model.saveInventory() }.buttonStyle(.link)
        }
    }
}

struct PeripheralsCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Card("Périphériques connectés au Mac (Local Device Monitor)", symbol: "cable.connector",
             trailing: AnyView(Button("Actualiser") { Task { model.peripherals = await model.peripheralService.read() } }.glassButton())) {
            Text("Distinct des clients du réseau : appareils physiquement reliés à ce Mac (USB, Thunderbolt, Bluetooth, adaptateurs Ethernet), lus via system_profiler.")
                .font(.caption).foregroundStyle(.secondary)
            if model.peripherals.isEmpty { Text("Aucune donnée — cliquez sur Actualiser.").foregroundStyle(.tertiary) }
            ForEach(["USB", "Thunderbolt", "Bluetooth", "Ethernet"], id: \.self) { bus in
                let items = model.peripherals.filter { $0.bus == bus }
                if !items.isEmpty {
                    Text(bus).font(.subheadline.bold())
                    ForEach(items) { p in
                        HStack {
                            Text(p.name)
                            if let c = p.connected { Text(c ? "connecté" : "non connecté").font(.caption).foregroundStyle(c ? .green : .secondary) }
                            Spacer()
                            Text(p.detail["manufacturer"] ?? p.detail["device_minorType"] ?? p.detail["device_speed"] ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
#endif
