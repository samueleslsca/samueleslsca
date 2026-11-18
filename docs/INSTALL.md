# Installation et désinstallation

## Prérequis

- macOS 14 Sonoma ou ultérieur (Apple Silicon ou Intel)
- Xcode 16 ou ultérieur (Xcode 26 pour le Liquid Glass natif), ou au minimum les Command Line Tools avec Swift 5.10+
- Optionnel : `iperf3` (`brew install iperf3`) pour le test LAN ; `xcodegen` pour générer un projet Xcode

## 1. Audit de votre Mac (lecture seule)

```bash
./scripts/phase0_audit.sh > audit.txt            # aucune modification système
./scripts/phase0_audit.sh --privacy > audit.txt  # masque IP, MAC et SSID
```

## 2. Compilation et tests

```bash
swift test                           # tests unitaires du cœur
swift build -c release               # compile l’application
swift run NetScopePro --self-test    # vérifie les parseurs sur VOTRE Mac (lecture seule, sans test de débit)
```

Si la compilation de la couche macOS échoue (voir [LIMITATIONS.md](LIMITATIONS.md)), les messages d’erreur de Xcode indiquent le fichier et la ligne. Les corrections attendues sont mineures : signatures d’API, annotations de type.

## 3. Création de l’application

```bash
./scripts/build_app.sh
open "dist/NetScope Pro.app"
```

Le script produit `dist/NetScope Pro.app`, signé ad hoc avec Hardened Runtime, ainsi que `dist/NetScopePro-macOS.zip`. Pour une signature Developer ID :

```bash
SIGN_IDENTITY="Developer ID Application: Votre Nom (TEAMID)" ./scripts/build_app.sh
```

Avec Xcode : `brew install xcodegen && xcodegen generate && open NetScopePro.xcodeproj`, puis Product → Run. Vous pouvez aussi ouvrir directement `Package.swift`.

### Premier lancement

1. Une app signée ad hoc peut être bloquée par Gatekeeper : clic droit → Ouvrir, ou Réglages Système → Confidentialité et sécurité → Ouvrir quand même.
2. **Réseau local** : acceptez l’invite de macOS, nécessaire pour Bonjour et la box.
3. **Localisation** : Wi-Fi Analyzer → « Demander l’autorisation » pour lire le SSID et le BSSID (NetScope n’utilise pas votre position).
4. **Notifications** : facultatives.
5. **Speedtest** : acceptez l’avertissement de consommation de données.

## 4. Agent de mesure (facultatif)

Voir [Agent/README.md](../Agent/README.md).

## Désinstallation

1. Quittez NetScope Pro (barre de menus → Quitter, ou ⌘Q).
2. Si vous le souhaitez, effacez d’abord l’historique : Réglages → Général → Effacer tout l’historique local.
3. Supprimez l’application : `rm -rf "/Applications/NetScope Pro.app"` (ou là où vous l’avez placée).
4. Supprimez les données locales :
   ```bash
   rm -rf ~/Library/Application\ Support/NetScopePro
   defaults delete fr.netscope.pro 2>/dev/null; defaults delete NetScopePro 2>/dev/null
   ```
5. Supprimez les secrets du trousseau (jetons de routeur, d’agent, clé IA) : ouvrez Trousseau d’accès, recherchez `fr.netscope.pro` et supprimez les éléments, ou :
   ```bash
   while security delete-generic-password -s fr.netscope.pro >/dev/null 2>&1; do :; done
   ```
6. Freebox : dans Freebox OS → Paramètres → Gestion des accès → Applications, révoquez « NetScope Pro ». Retirez aussi les éventuelles règles du filtrage MAC Wi-Fi créées par NetScope (commentaire « NetScope — … »).
7. Réinitialisez les autorisations, si vous le souhaitez : `tccutil reset All fr.netscope.pro`.

NetScope n’installe aucun démon, extension système, profil ou outil privilégié : rien d’autre n’est à retirer.
