# Architecture technique

## Vue d’ensemble

```
┌──────────────────────────── NetScopePro (app SwiftUI, macOS 14+) ────────────────────────────┐
│ RootView (NavigationSplitView) · 16 écrans · MenuBarExtra · Settings                         │
│ AppModel (@MainActor ObservableObject) : orchestration, cadences, persistance, événements    │
└───────────────┬──────────────────────────────────────────────────────┬───────────────────────┘
                │                                                      │
┌───────────────▼──────────── NetScopeSystem (macOS) ───┐   ┌──────────▼──── NetScopeCore (multiplateforme) ────────────┐
│ WiFiDiagnosticsService  (CoreWLAN + CoreLocation)     │   │ Modèles + Provenance (Mesuré/Routeur/Calculé/Estimé/ND)  │
│ PathMonitorService      (Network.framework)           │   │ CommandRunner sécurisé (liste blanche, sans shell)       │
│ InterfaceCountersReader (sysctl NET_RT_IFLIST2, 64 b) │   │ Parseurs : networkQuality, ping, netstat, arp, ndp,      │
│ BonjourDiscoveryService (mDNS)                        │   │   scutil, ifconfig, traceroute, iperf3, nettop,          │
│ KeychainSecretStore     (Security)                    │   │   system_profiler                                        │
│ NotificationsService    (UserNotifications)           │   │ Services : interfaces, latence, speedtest, LAN, DNS      │
│ LocalPeripheralService  (system_profiler)             │   │   (client UDP RFC 1035), voisins, trafic, traceroute     │
│ AgentClient             (HTTPS + épinglage)           │   │ Moteurs : Diagnostics, QualityScore, Bufferbloat, Health,│
│ ClaudeAssistantClient   (opt-in)                      │   │   NAT/Gaming, Security, Heatmap, ISP, Multi-point,       │
│ SystemFacts             (audit à l’exécution)         │   │   Simulation, Assistant, OptimizationCenter              │
└───────────────────────────────────────────────────────┘   │ Routeurs : protocole + registre ; Freebox ; OpenWrt      │
                                                            │ Stockage : HistoryStore SQLite (WAL, récupération)       │
                                                            │ Rapports : Markdown/HTML/JSON/CSV, masquage              │
                                                            └──────────────────────────────────────────────────────────┘
```

**Pourquoi trois modules ?** Toute la logique de mesure et d’analyse se trouve dans `NetScopeCore`, sans dépendance à AppKit, CoreWLAN ou SwiftUI. Elle se compile et se teste partout, y compris en CI Linux. Les API propres à Apple sont isolées dans `NetScopeSystem`, l’interface dans l’application. Cette séparation, proche de MVVM (vues → `AppModel` → services → moteurs purs), garde les moteurs testables avec des entrées enregistrées.

## Services demandés et leur implémentation

| Service du cahier des charges | Implémentation |
|---|---|
| NetworkInterfaceService | `NetworkInterfaceService` (ifconfig, netstat, scutil, networksetup) + `PathMonitorService` |
| WiFiDiagnosticsService | `WiFiDiagnosticsService` (CoreWLAN) |
| InternetSpeedTestService | `InternetSpeedTestService` (networkQuality, détection des options) + `LANTestService` (iperf3) |
| LatencyMonitoringService | `LatencyMonitoringService` (ping, ping continu par tranches) |
| DNSDiagnosticsService | `DNSDiagnosticsService` + `DNSClient` (requêtes UDP brutes vers un résolveur précis) |
| NetworkDiscoveryService | `NeighborDiscoveryService` (ARP/NDP, sondage autorisé) + `BonjourDiscoveryService` |
| RouterIntegrationService | protocole `RouterAdapter`, `RouterRegistry`, `FreeboxAdapter`, `OpenWrtAdapter` |
| DeviceInventoryService | `DeviceInventory` (fusion, déduplication, classification) + `OUIDatabase` |
| NetworkSecurityService | `SecurityAuditor`, `ChangeDetector`, `NATAnalyzer` |
| NetworkOptimizationService | `OptimizationCenter`, `ChannelAdvisor`, `CampaignComparison` |
| TrafficMonitoringService | `InterfaceCountersReader` + `ThroughputCalculator` + `ProcessTrafficService` |
| DiagnosticsEngine | `DiagnosticsEngine` (13 règles), `QualityScorer`, `LocalAssistant` |
| ReportingService | `ReportBuilder`, `Report` (MD/HTML/JSON), `CSVExport`, `ReportExporter` (PDF) |
| NotificationsService | `NotificationsService` |

## Principes de conception

- **Provenance obligatoire** : `Sourced<T>` associe une valeur, sa `Provenance` et son horodatage. Une valeur `nil` étiquetée « mesurée » est automatiquement requalifiée en « non disponible ».
- **Exécution sûre des commandes** : `ArgumentValidator` vérifie chaque argument par rapport aux options autorisées de chaque outil, chemins absolus fixes. `Process` est lancé sans shell, avec un environnement minimal, un délai maximal et une annulation propagée (le processus est terminé). Seuls des outils en lecture sont utilisés.
- **Cadences adaptées**, sans polling inutile : changements de chemin réseau et événements Wi-Fi signalés par notification système ; Wi-Fi toutes les 3 s (appel CoreWLAN peu coûteux), compteurs toutes les 1 s (sysctl), connexion toutes les 30 s, passerelle toutes les 60 s (3 paquets), cache ARP toutes les 5 min. Les tests lourds ne partent jamais en arrière-plan, sauf les tests planifiés que vous activez vous-même, plafonnés et suspendus pendant les transferts.
- **Séparation observation / modification** : seules deux actions modifient quelque chose (filtre MAC de la Freebox, et son mode). Elles passent par une confirmation, sont vérifiées par relecture et consignées dans un journal d’audit.
- **Pas de conclusion hâtive** : le moteur de diagnostic ne dépasse pas une confiance « moyenne » pour un problème extérieur au réseau local et n’accuse jamais l’opérateur sans preuve. Les comparaisons avant/après exigent 3 mesures par côté et des intervalles interquartiles qui ne se recouvrent pas.

## Concurrence

Swift Concurrency (async/await, `TaskGroup`, `async let`) ; adaptateurs routeurs implémentés comme `actor` ; `AppModel` isolé sur `@MainActor` ; appels bloquants (sockets DNS, `Process`) déportés hors du pool coopératif.

## Stockage

`HistoryStore` (SQLite, mode WAL) : table `records(id, kind, ts, network, payload JSON)`, indexée par `(kind, ts)`. Au démarrage, `PRAGMA quick_check` est exécuté ; une base corrompue est mise de côté et recréée, avec un message à l’utilisateur. Un enregistrement illisible est ignoré et compté, sans plantage. Une purge par ancienneté est configurable.

## Interface et Liquid Glass

`GlassBackground` applique `.glassEffect(.regular, in: .rect(cornerRadius:))` et les styles de bouton `.glass` / `.glassProminent` lorsque le SDK macOS 26 est présent (`#if compiler(>=6.2)`) et que le système est en macOS 26 (`#available`). Sinon, il se replie sur `.regularMaterial` et les styles `.bordered`. Typographie système, SF Symbols, Swift Charts.
