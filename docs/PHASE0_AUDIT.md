# Phase 0 — Audit et matrice de faisabilité

## Ce qui a pu être audité, et ce qui ne l’a pas été

Le développement s’est fait dans un conteneur cloud **Linux** (Ubuntu 24.04, 4 vCPU), sans accès à votre Mac (aucun dossier partagé) ni à un runner macOS (GitHub Actions a refusé les jobs). Concrètement :

| Point d’audit demandé | Résultat |
|---|---|
| Version de macOS, processeur | **Non audité sur votre Mac.** Lu à l’exécution par l’app (Réglages → Environnement), par `--self-test` et par `scripts/phase0_audit.sh` |
| Xcode, Swift, SDK | Environnement de dev : Swift 6.0.3 (Linux). Votre Mac : via le script d’audit |
| Interfaces Wi-Fi/Ethernet/VPN | Classées à l’exécution (networksetup + ifconfig + routes) |
| API disponibles par métrique | Vérifiées sur la documentation Apple ; voir la matrice ci-dessous |
| Commandes système | Recherche à l’exécution par chemin absolu (`FeasibilityAuditor`) |
| Permissions | Localisation (SSID/BSSID), réseau local, notifications : demandées au moment de l’usage |
| Connectivité | Testée par l’auto-test et le diagnostic |

Le script `scripts/phase0_audit.sh` reproduit l’intégralité de l’audit demandé sur votre Mac, **en lecture seule**. Lancez-le et conservez la sortie.

## Matrice de faisabilité technique

| Métrique / fonction | Source retenue | Faisable | Privilèges | Remarque |
|---|---|---|---|---|
| Interface active, IPv4/IPv6 | ifconfig + netstat -rn | ✅ | Aucun | |
| Passerelle par défaut | netstat -rn (routes scopées gérées) | ✅ | Aucun | Cas VPN : passerelle physique affichée |
| DNS | scutil --dns | ✅ | Aucun | Résolveurs scopés distingués |
| Proxy | scutil --proxy | ✅ | Aucun | |
| VPN | interfaces utun/ipsec/ppp + routes | ✅ (détectable) | Aucun | Heuristique : certains VPN sont invisibles |
| Changement de chemin réseau | NWPathMonitor | ✅ | Aucun | Notification système, sans polling |
| RSSI, bruit, canal, bande, largeur, débit de liaison, norme, sécurité | CoreWLAN | ✅ | Aucun | |
| SSID, BSSID | CoreWLAN | ✅ sous condition | Autorisation de localisation | macOS 14.4+ |
| Réseaux voisins | CoreWLAN scanForNetworks | ✅ | Localisation pour les SSID | Interrompt brièvement la liaison |
| Événements SSID/BSSID/liaison | CWEventDelegate | ✅ | Aucun | |
| MLO, OFDMA, occupation radio | — | ❌ | — | Non exposés |
| Débit, latence sous charge, RPM | networkQuality -c | ✅ | Aucun | macOS 12+ |
| Pertes, gigue | ping ICMP | ✅ | Aucun | |
| Temps DNS | client UDP (RFC 1035) | ✅ | Aucun | Sans passer par le cache système |
| Traceroute | /usr/sbin/traceroute | ✅ | Aucun | |
| Débit LAN | iperf3 (installé par l’utilisateur) | ✅ optionnel | Aucun | Serveur contrôlé requis |
| Voisins ARP/NDP | arp -an, ndp -an | ✅ | Aucun | |
| Bonjour | NetServiceBrowser | ✅ | Invite réseau local | |
| Sondage actif | ping par hôte (≤ 16 en parallèle, ≤ /22, privé, local) | ✅ sur accord | Aucun | |
| Trafic de l’interface | sysctl NET_RT_IFLIST2 (64 bits) | ✅ | Aucun | |
| Trafic par processus | nettop -P -L 1 -x | ✅ | Aucun | Compteurs cumulés |
| Périphériques USB/TB/BT/Ethernet | system_profiler -json | ✅ | Aucun | |
| Clients, WAN, Wi-Fi de la box | API officielle de la box | ✅ Freebox, OpenWrt | Autorisation sur la box | Autres marques : voir COMPATIBILITY.md |
| Blocage d’appareil | Filtre MAC Wi-Fi de la Freebox | ✅ Freebox | Permission « réglages » | Désactivé ailleurs |
| Secrets | Trousseau | ✅ | Aucun | |
| Historique | SQLite | ✅ | Aucun | |
| PDF | Pipeline d’impression AppKit, ImageRenderer | ✅ | Aucun | |
| Liquid Glass | glassEffect (macOS 26) | ✅ avec repli | — | |

## Dépendances

Aucune dépendance tierce : Foundation, SwiftUI, Swift Charts, CoreWLAN, CoreLocation, Network, Security, UserNotifications, CryptoKit et SQLite3 (système). L’agent n’utilise que la bibliothèque standard Python, plus `openssl` pour créer son certificat. Aucun binaire n’est téléchargé ni exécuté à l’exécution.
