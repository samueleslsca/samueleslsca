# NetScope Pro

Application macOS native (Swift / SwiftUI) d’analyse, de surveillance, de diagnostic et d’optimisation de votre réseau personnel.

> **État de cette version : lisez [Statut de vérification](#statut-de-vérification) avant d’installer.** Le cœur (mesures, analyses, stockage, routeurs) est compilé et testé. La couche macOS (interface SwiftUI, CoreWLAN) a été écrite sans pouvoir être compilée dans l’environnement de développement (Linux, sans SDK macOS). Il faudra donc probablement corriger quelques erreurs à la première compilation dans Xcode.

## Ce que fait NetScope Pro

| Module | Ce qui est réellement mesuré / fourni |
|---|---|
| **Dashboard** | Connexion (interface, IPv4/IPv6, passerelle, DNS, VPN, proxy), qualité Wi-Fi, dernier test, appareils, score global explicable (6 sous-scores, méthode et niveau de confiance) |
| **Speedtest Pro** | Apple `networkQuality` en JSON (détection des options disponibles selon la version de macOS) : débits, latence au repos et sous charge, réactivité (RPM), TCP/TLS/HTTP. S’y ajoutent le ping ICMP (gigue, pertes) et le DNS. Modes Quick, Full, Gaming, Visio, Streaming, LAN (iperf3) ; annulation ; mode données réduites ; courbe en direct à partir des compteurs de l’interface |
| **Wi-Fi Analyzer** | CoreWLAN : RSSI, bruit, SNR calculé, canal, bande, largeur, débit de liaison, norme, sécurité ; historique du signal ; scan des voisins (sur demande) ; graphique des canaux ; recommandation de canal et de largeur |
| **Connected Devices** | Caches ARP/NDP, Bonjour/mDNS, clients du routeur, sondage ICMP optionnel (sous-réseau privé local uniquement, après accord) ; déduplication multi-sources ; détection des MAC aléatoires ; classification avec niveau de confiance et justification ; renommage, « connu » / « à examiner », export CSV. **Local Device Monitor** : périphériques USB, Thunderbolt, Bluetooth et Ethernet du Mac |
| **Network Map** | Topologie observée, liens confirmés (traits pleins) ou supposés (pointillés), fiche par appareil, filtres ; **jumeau numérique** avec des scénarios hypothétiques étiquetés « simulation » |
| **Router Control** | Freebox (API officielle Freebox OS : autorisation sur la box, session HMAC, clients, WAN, Wi-Fi, **blocage par filtrage MAC Wi-Fi** avec confirmation en 5 étapes, vérification par relecture et journal d’audit) ; OpenWrt (ubus, lecture seule) |
| **Traffic Monitor** | Débit entrant et sortant (compteurs 64 bits), volume de la session, pics, trafic par processus (`nettop`), trafic WAN et par client si le routeur le fournit |
| **Security Center** | Contrôles notés vérifié / suspect / non vérifié / indisponible : chiffrement Wi-Fi, WPS, réseau invité, firmware, appareils inconnus, changements de passerelle ou DNS (alerte possible d’usurpation ARP, sans conclusion hâtive), fuite IPv6 hors VPN ; notifications |
| **Diagnostics & Optimization** | Assistant en 8 étapes, moteur de corrélation (13 causes : faits, éléments pour et contre, confiance, vérifications, actions avec risque et réversibilité), Optimization Center qui distingue latence, stabilité et débit, assistant local hors ligne, assistant IA optionnel (sur consentement) |
| **History & Reports** | SQLite local, 24 h / 7 j / 30 j / 90 j / période personnalisée, comparaisons Wi-Fi/Ethernet, par réseau, par heure, avant/après (avec test de variabilité), exports PDF / CSV / JSON / HTML / Markdown |
| **Bufferbloat & QoS Lab** | Latence au repos, sous charge descendante et sous charge montante, sur plusieurs essais ; note A+ à F ; comparaison avant/après qui n’annonce jamais d’amélioration sans preuve |
| **Internet Health Monitor** | Vérifications légères périodiques, détection des coupures (locales, Internet ou DNS), disponibilité, tendances, mode basse consommation, rapport |
| **Multi-point Diagnostics** | Agent Python (Raspberry Pi…) en HTTPS avec épinglage du certificat et appairage par code ; comparaison Mac / agent / LAN / WAN pour localiser le segment fautif |
| **Wi-Fi Heatmap** | Import d’un plan, étalonnage sur 2 points, murs, points de mesure, interpolation IDW (zones non mesurées laissées vides), comparaison des emplacements du routeur, suggestions de points d’accès, export PDF |
| **ISP Performance Audit** | Offre déclarée et débits mesurés, Ethernet, heures de pointe, incidents, vérifications restantes, **rapport PDF pour l’opérateur** |
| **Gaming Network Lab** | Destinations au choix, pics, P99, pertes, latence sous charge, détection CGNAT / double NAT avec ses limites |
| **Barre de menus** | État, IP, signal, passerelle, dernier test, Quick Test |

Chaque valeur affichée porte sa source : **Mesuré**, **Fourni par le routeur**, **Calculé**, **Estimé** ou **Non disponible** (avec la raison). Aucune donnée simulée n’apparaît dans les vues de production.

## Statut de vérification

| Élément | Statut |
|---|---|
| `NetScopeCore` (≈ 5 600 lignes : parseurs, moteurs, stockage, routeurs, rapports) | ✅ Compilé (Swift 6.0.3) et **71 tests unitaires passent** sous Linux |
| Agent multi-point (`Agent/`) | ✅ 8 tests d’intégration HTTPS : 7 passent, 1 ignoré (pas de `ping` dans le conteneur de développement) |
| `NetScopeSystem` + application SwiftUI (≈ 4 300 lignes) | ⚠️ **Non compilé** : le SDK macOS est absent de l’environnement de développement. Écrit avec des API documentées, mais quelques erreurs de compilation sont probables au premier build |
| CI GitHub Actions (macOS 15/26 : build, tests, auto-test, `.app`) | ⚠️ Workflow fourni, mais les jobs ont été rejetés sans runner (Actions désactivé ou bloqué par la facturation sur le compte) |
| Adaptateur Freebox | ⚠️ Implémenté d’après la documentation officielle du SDK, testé avec un transport simulé ; **non validé sur une vraie Freebox** |
| Paquet `.app` | ❌ Pas produit (requiert macOS) ; `scripts/build_app.sh` le génère sur votre Mac |

## Démarrage rapide (sur votre Mac)

```bash
git clone <ce dépôt> && cd <dépôt>
./scripts/phase0_audit.sh > audit.txt     # audit lecture seule de votre Mac (phase 0)
swift test                                # tests du cœur
swift run NetScopePro --self-test         # vérifie les parseurs sur la sortie réelle de vos outils système
./scripts/build_app.sh                    # produit dist/NetScope Pro.app
open "dist/NetScope Pro.app"
```

Ou dans Xcode : ouvrez `Package.swift`, ou générez le projet avec `brew install xcodegen && xcodegen generate`, puis ouvrez `NetScopePro.xcodeproj`.

Prérequis : macOS 14 ou ultérieur, Xcode 16 ou ultérieur (Xcode 26 pour le Liquid Glass natif).

## Documentation

- [Installation et désinstallation](docs/INSTALL.md)
- [Guide utilisateur](docs/USER_GUIDE.md)
- [Architecture technique](docs/ARCHITECTURE.md)
- [Matrice de compatibilité (macOS, routeurs)](docs/COMPATIBILITY.md)
- [Limitations connues](docs/LIMITATIONS.md)
- [Audit Phase 0 et matrice de faisabilité](docs/PHASE0_AUDIT.md)
- [Agent de mesure distant](Agent/README.md)

## Confidentialité

Fonctionnement local, aucune télémétrie, secrets dans le trousseau, aucune donnée envoyée sans votre accord explicite (IP publique, assistant IA), mode confidentialité qui masque IP, MAC et SSID à l’écran et dans les exports, effacement complet de l’historique dans les Réglages.
