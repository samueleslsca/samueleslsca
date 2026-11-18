#if os(macOS)
import SwiftUI
import NetScopeCore

struct RouterControlView: View {
    @EnvironmentObject var model: AppModel
    @State private var freeboxHost = "mafreebox.freebox.fr"
    @State private var owHost = ""
    @State private var owUser = ""
    @State private var owPassword = ""
    @State private var blockTarget: RouterClient?

    var body: some View {
        Page("Router Control", subtitle: "Consultation et gestion via les API officielles de votre box — seules les actions réellement prises en charge sont proposées") {
            detectionCard
            if let e = model.router.error { ErrorBanner(message: e) }
            if let s = model.router.status { Label(s, systemImage: "info.circle").font(.callout) }
            if model.activeAdapter != nil {
                HStack(alignment: .top, spacing: 16) { infoCard; capabilitiesCard }
                clientsCard
                wifiCard
            }
            adaptersCard
            auditCard
        }
        .sheet(item: $blockTarget) { c in BlockSheet(client: c) }
    }

    var detectionCard: some View {
        Card("Détection", symbol: "magnifyingglass", trailing: AnyView(
            Button(model.router.detecting ? "Détection…" : "Détecter") { Task { await model.detectRouter() } }.disabled(model.router.detecting).glassButton())) {
            Text("La détection interroge uniquement les points de découverte publics documentés (Freebox /api_version, OpenWrt /ubus) sur votre passerelle.").font(.caption).foregroundStyle(.secondary)
            ForEach(model.router.probes, id: \.self) { p in
                HStack {
                    Image(systemName: "wifi.router")
                    VStack(alignment: .leading) {
                        Text("\(RouterRegistry.descriptor(id: p.adapterID)?.name ?? p.adapterID) \(p.model ?? "")").bold()
                        Text("\(p.evidence) · API \(p.apiVersion ?? "?")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if p.adapterID == "freebox" {
                        Button("Connecter") { Task { await model.connectFreebox(host: URL(string: p.baseURL)?.host ?? freeboxHost) } }.prominentGlassButton()
                    } else if p.adapterID == "openwrt" {
                        Button("Configurer ci-dessous") { owHost = URL(string: p.baseURL)?.host ?? "" }.glassButton()
                    }
                }
            }
            DisclosureGroup("Connexion manuelle") {
                HStack {
                    TextField("Hôte Freebox", text: $freeboxHost).textFieldStyle(.roundedBorder).frame(width: 220)
                    Button("Connecter une Freebox") { Task { await model.connectFreebox(host: freeboxHost) } }.glassButton()
                }
                HStack {
                    TextField("Hôte OpenWrt", text: $owHost).textFieldStyle(.roundedBorder).frame(width: 160)
                    TextField("Utilisateur rpcd", text: $owUser).textFieldStyle(.roundedBorder).frame(width: 140)
                    SecureField("Mot de passe (stocké dans le trousseau)", text: $owPassword).textFieldStyle(.roundedBorder).frame(width: 240)
                    Button("Connecter OpenWrt") {
                        Task { await model.connectOpenWrt(host: owHost, user: owUser, password: owPassword); owPassword = "" }
                    }.disabled(owHost.isEmpty || owUser.isEmpty).glassButton()
                }
            }
        }
    }

    var infoCard: some View {
        Card("Routeur", symbol: "wifi.router", trailing: AnyView(Button("Actualiser") { Task { await model.refreshRouter() } }.glassButton())) {
            let i = model.router.info, w = model.router.wan
            let p = Provenance.router(adapter: model.router.adapterID ?? "")
            KeyValueRow(label: "Modèle", value: i?.model, provenance: p)
            KeyValueRow(label: "Firmware", value: i?.firmware, provenance: p)
            KeyValueRow(label: "Uptime", value: i?.uptimeSeconds.map { Duration.seconds($0).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)) }, provenance: p)
            KeyValueRow(label: "État WAN", value: w?.state, provenance: p)
            KeyValueRow(label: "Média / type", value: [w?.media, w?.type].compactMap { $0 }.joined(separator: " · "), provenance: p)
            KeyValueRow(label: "IPv4 WAN", value: w?.ipv4, provenance: p)
            KeyValueRow(label: "Synchro ↓ / ↑", value: w?.syncDownBps.map { "\(Units.bitRate($0)) / \(w?.syncUpBps.map(Units.bitRate) ?? "—")" }, provenance: p)
            KeyValueRow(label: "Débit instantané ↓ / ↑", value: w?.currentDownBps.map { "\(Units.bitRate($0)) / \(w?.currentUpBps.map(Units.bitRate) ?? "—")" }, provenance: p)
            if let t = model.router.lastRefresh { Text("Mis à jour \(t.relative)").font(.caption2).foregroundStyle(.tertiary) }
        }
    }

    var capabilitiesCard: some View {
        Card("Fonctions disponibles", symbol: "checklist") {
            ForEach(RouterCapabilities.all.indices, id: \.self) { i in
                let cap = RouterCapabilities.all[i].0, name = RouterCapabilities.all[i].1
                HStack {
                    Image(systemName: model.router.capabilities.contains(cap) ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(model.router.capabilities.contains(cap) ? .green : .secondary)
                    Text(name)
                }.font(.callout)
            }
            if !model.router.capabilities.contains(.blockDevice), model.router.adapterID == "freebox" {
                Text("Blocage indisponible : accordez la permission « Modification des réglages de la Freebox » à NetScope dans Freebox OS (Paramètres → Gestion des accès → Applications).").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 340)
    }

    var clientsCard: some View {
        Card("Clients déclarés par le routeur", symbol: "list.bullet.rectangle") {
            Table(model.router.clients) {
                TableColumn("Nom") { (c: RouterClient) in Text(model.redact(c.name ?? "—")) }
                TableColumn("IP") { (c: RouterClient) in Text(model.redact(c.ipv4 ?? "—")).monospacedDigit() }.width(120)
                TableColumn("MAC") { (c: RouterClient) in Text(c.mac.map { model.settings.privacyMode ? MACAddress.redact($0) : $0 } ?? "—").font(.caption.monospaced()) }.width(140)
                TableColumn("Liaison") { (c: RouterClient) in Text(c.link.rawValue + (c.wifiSignalDbm.map { " \($0) dBm" } ?? "")) }.width(110)
                TableColumn("État") { (c: RouterClient) in Text(c.active == true ? "Actif" : (c.active == false ? "Inactif" : "—")) }.width(70)
                TableColumn("Accès") { (c: RouterClient) in
                    let blocked = model.router.rules.contains { $0.mac == c.mac && $0.blocked }
                    if model.router.capabilities.contains(.blockDevice), c.mac != nil {
                        Button(blocked ? "Débloquer" : "Bloquer…") { blockTarget = c }.buttonStyle(.link)
                    } else {
                        Text("Non pris en charge").font(.caption).foregroundStyle(.tertiary)
                            .help("Ce routeur ou cette session ne fournit pas d’API de blocage. NetScope ne simule jamais un blocage par un filtre local.")
                    }
                }.width(130)
            }
            .frame(minHeight: 260)
        }
    }

    var wifiCard: some View {
        Card("Paramètres Wi-Fi rapportés", symbol: "wifi") {
            if let w = model.router.wifi {
                ForEach(w.networks.indices, id: \.self) { i in
                    let n = w.networks[i]
                    KeyValueRow(label: model.redact(n.ssid ?? "?"), value: [n.band, n.channel.map { "canal \($0)" }, n.channelWidthMHz.map { "\($0) MHz" }, n.encryption, n.wpsEnabled == true ? "WPS actif" : nil].compactMap { $0 }.joined(separator: " · "),
                                provenance: .router(adapter: model.router.adapterID ?? ""))
                }
                KeyValueRow(label: "Filtrage MAC", value: w.macFilterMode)
                KeyValueRow(label: "Réseau invité", value: w.guestNetworkEnabled.map { $0 ? "configuré" : "absent" })
            } else { Text("Non fourni par cet adaptateur.").foregroundStyle(.secondary) }
        }
    }

    var adaptersCard: some View {
        Card("Compatibilité des adaptateurs", symbol: "puzzlepiece.extension") {
            ForEach(RouterRegistry.descriptors) { d in
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text(d.name).bold(); Text(d.status.rawValue).font(.caption).padding(.horizontal, 6).background(.quaternary, in: Capsule()) }
                    Text(d.notes).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    var auditCard: some View {
        Card("Journal des actions administratives", symbol: "doc.text.magnifyingglass") {
            if model.auditLog.isEmpty { Text("Aucune action effectuée.").foregroundStyle(.secondary) }
            ForEach(model.auditLog.prefix(20)) { e in
                HStack(alignment: .top) {
                    Image(systemName: e.verified ? "checkmark.seal" : "xmark.octagon").foregroundStyle(e.verified ? .green : .red)
                    VStack(alignment: .leading) {
                        Text("\(e.action) — \(model.redact(e.target))").font(.callout)
                        Text("\(e.timestamp.shortDateTime) · \(e.adapterID) · \(e.outcome)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Explicit, step-by-step confirmation before any blocking action.
struct BlockSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var client: RouterClient
    @State private var confirmed = false
    @State private var running = false
    @State private var outcome: String?

    var isBlocked: Bool { model.router.rules.contains { $0.mac == client.mac && $0.blocked } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isBlocked ? "Débloquer un appareil" : "Bloquer un appareil").font(.title2.bold())
            Card("1. Appareil concerné", symbol: "iphone") {
                KeyValueRow(label: "Nom", value: client.name)
                KeyValueRow(label: "MAC", value: client.mac)
                KeyValueRow(label: "IP", value: client.ipv4)
                KeyValueRow(label: "Liaison", value: client.link.rawValue)
            }
            Card("2–3. Vérifications", symbol: "checkmark.shield") {
                Label(client.mac != nil ? "Identité : adresse MAC fournie par le routeur" : "Identité non vérifiable (pas de MAC)", systemImage: client.mac != nil ? "checkmark" : "xmark")
                Label(model.router.capabilities.contains(.blockDevice) ? "Droits : la session dispose de la permission de modification" : "Droits insuffisants", systemImage: model.router.capabilities.contains(.blockDevice) ? "checkmark" : "xmark")
                if client.mac.map(MACAddress.isLocallyAdministered) == true {
                    Label("Adresse MAC aléatoire : l’appareil peut changer d’adresse et contourner la règle.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            Card("4. Conséquences", symbol: "exclamationmark.triangle") {
                Text(isBlocked ? "L’appareil pourra de nouveau s’associer au Wi-Fi." :
                    "Le blocage utilise le filtrage MAC Wi-Fi de la box : l’appareil ne pourra plus s’associer au Wi-Fi. Il reste joignable s’il est branché en Ethernet. Si c’est votre propre Mac ou l’appareil qui administre la box, vous pourriez perdre l’accès. La règle n’est effective que si le filtrage MAC est en mode liste noire (actuel : \(model.router.wifi?.macFilterMode ?? "inconnu")).")
                    .font(.callout)
            }
            Toggle("5. Je confirme vouloir \(isBlocked ? "débloquer" : "bloquer") cet appareil", isOn: $confirmed)
            if let outcome { Text(outcome).font(.callout.bold()) }
            HStack {
                Button("Fermer") { dismiss() }
                Spacer()
                Button(running ? "Exécution…" : (isBlocked ? "Débloquer" : "Bloquer")) {
                    guard let mac = client.mac else { return }
                    running = true
                    Task {
                        outcome = await model.setBlocked(mac: mac, name: client.name ?? mac, blocked: !isBlocked)
                        running = false
                    }
                }
                .disabled(!confirmed || running || client.mac == nil || !model.router.capabilities.contains(.blockDevice))
                .prominentGlassButton()
            }
        }
        .padding(20).frame(width: 560)
    }
}
#endif
