# Matrice de compatibilité

## Selon la version de macOS

| Fonction | macOS 14 Sonoma | macOS 15 Sequoia | macOS 26 Tahoe | Source / remarque |
|---|---|---|---|---|
| Lancement de l’application | ✅ | ✅ | ✅ | Cible de déploiement : macOS 14 |
| Liquid Glass natif | Repli `.regularMaterial` | Repli | ✅ (build Xcode 26) | `glassEffect`, `.glass` |
| `networkQuality -c` (JSON) | ✅ | ✅ | ✅ | Options détectées à l’exécution via `-h` (`-s`, `-u`, `-d`, `-I`, `-M` selon la version) |
| Limitation de la durée du test (`-M`) | Selon la version | Selon la version | Selon la version | Le mode « réduit » n’utilise `-M` que si l’option est annoncée |
| RSSI, bruit, canal, bande, largeur, débit de liaison, norme | ✅ | ✅ | ✅ | CoreWLAN |
| SSID / BSSID | ✅ avec autorisation de localisation (14.4+) | ✅ avec autorisation | ✅ avec autorisation | Sans autorisation : « Indisponible » avec la raison |
| SSID des réseaux voisins | Idem | Idem | Idem | `scanForNetworks` |
| Détection Wi-Fi 7 (802.11be) | — | Si le SDK l’expose | Si le SDK l’expose | Correspondance par valeur brute (`CWPHYMode` = 7) : **à valider** sur une machine Wi-Fi 7 |
| MLO, OFDMA, temps d’occupation radio | ❌ | ❌ | ❌ | Non exposés par les API publiques |
| Accès au réseau local (Bonjour, routeur) | ✅ | ✅ invite de confidentialité réseau local | ✅ invite | `NSLocalNetworkUsageDescription`, `NSBonjourServices` |
| Compteurs d’interface 64 bits | ✅ | ✅ | ✅ | `sysctl NET_RT_IFLIST2` |
| Trafic par processus | ✅ | ✅ | ✅ | `nettop` (compteurs cumulés) |
| Notifications | ✅ (app empaquetée) | ✅ | ✅ | Inactives si lancé comme exécutable nu |
| Processeur | Apple Silicon et Intel | | | Aucun code spécifique à une architecture |

## Routeurs et box

| Marque | Statut | API | Fonctions |
|---|---|---|---|
| **Freebox** (Free) | ✅ Implémenté, non validé sur matériel réel | API officielle Freebox OS (dev.freebox.fr/sdk/os) | Infos système, firmware, uptime, clients (actifs et historiques, Wi-Fi/Ethernet, signal, débit par client), WAN (état, média, IP, synchro, débit instantané, volumes), configuration Wi-Fi (SSID, bande, canal, largeur, chiffrement, WPS si exposé), réseau invité, **blocage/déblocage par filtrage MAC Wi-Fi** (permission « réglages » requise), journal d’audit |
| **OpenWrt** | ✅ Lecture seule, non validé sur matériel réel | ubus JSON-RPC (uhttpd-mod-ubus, rpcd, luci-rpc) | Carte, version, uptime, état WAN, baux DHCP |
| Bouygues Bbox | ⏳ Prévu | API Bbox documentée | — |
| AVM FRITZ!Box | ⏳ Prévu | TR-064 documenté | — |
| Ubiquiti UniFi | ⏳ Prévu | UniFi Network Integration API | — |
| Orange Livebox | ❌ | Aucune API publique documentée | — |
| Box SFR | ❌ | Aucune API publique documentée | — |
| ASUS | ❌ | Aucune API publique documentée | — |
| TP-Link | ❌ | Aucune API locale publique (hors Omada) | — |

Fonctions non implémentées pour tous les adaptateurs : restrictions planifiées, règles d’accès avancées, sauvegarde de configuration, réglages QoS/SQM, changement de canal. Elles apparaissent désactivées, avec une explication. Sans routeur compatible, toutes les fonctions locales de l’application restent disponibles.
