# MAX BOOST — Smart Network Performance Optimizer

MAX BOOST cherche les gains de performance **réellement mesurables** sur votre Mac, votre Wi-Fi et votre routeur. Il n’applique que les réglages que vous autorisez explicitement, mesure chaque changement, puis conserve ou annule selon le résultat.

## Parcours

**Analyse → Recommandations → Autorisations → Optimisations → Vérification → Rapport**

1. **Analyse** (niveau 1, lecture seule) : N mesures comparables (3 par défaut), chacune composée d’un ping ICMP de 20 paquets vers une cible fixe, puis d’un `networkQuality` aux options fixes. S’y ajoutent le diagnostic complet, l’analyse Wi-Fi, 4 relevés `nettop` (≈ 15 s), la lecture des capacités du routeur, l’inspection de la pile réseau (DNS, MTU, IPv6, VPN, proxy, Ethernet, ordre des services, paramètres TCP) et, sur demande uniquement, un benchmark des DNS publics.
2. **Recommandations** : les optimisations candidates sont classées selon le gain probable × la pertinence pour le profil − le risque. Chacune affiche ses preuves, les appareils concernés, ses compromis, son niveau de sécurité et sa réversibilité.
3. **Autorisations** : rien d’automatisé ne s’exécute sans case cochée (niveau 2) ou sans une feuille de confirmation spécifique (niveau 3 : changement exact, appareils affectés, sauvegarde, procédure de récupération, double confirmation).
4. **Optimisations** : une seule modification à la fois, pour pouvoir attribuer l’effet. Chacune passe par l’enchaînement sauvegarde → application → vérification que l’appareil répond → confirmation.
5. **Vérification** : N nouvelles mesures, puis comparaison A/B (**Baseline → Candidate → Validated**). Si le gain n’est pas confirmé et que l’option est active, **restauration automatique** de l’état précédent.
6. **Rapport** : BEFORE BOOST / AFTER BOOST (médianes, intervalles interquartiles, écarts, verdicts), score avant/après, compromis, limites restantes, export PDF/HTML/JSON/Markdown. Les sessions sont conservées dans l’historique.

Pour les actions **guidées** (à réaliser vous-même), le bouton « J’ai effectué les actions guidées — Vérifier » relance les mesures et compare avec la référence.

## Profils

| Profil | Objectifs (métriques principales) | Garde-fous (ne doivent pas se dégrader au-delà de la tolérance) |
|---|---|---|
| MAX SPEED | Débit ↓ et ↑ | Latence sous charge, pertes |
| ULTRA LOW LATENCY | Latence sous charge, latence au repos, gigue | Débit ↓ et ↑, pertes |
| STREAMING & VIDEO | Débit ↑, gigue, pertes, latence sous charge | Débit ↓ |
| SMART AUTO | Toutes les métriques, avec priorité aux plus faibles du score | Toute dégradation est signalée comme compromis |

La tolérance de perte sur les garde-fous est réglable (15 % par défaut). Si une optimisation de latence coûte plus de débit que cette tolérance, elle n’est **pas** considérée comme un gain, et l’avertissement est affiché.

## Ce qui peut réellement être appliqué

| Action | Niveau | Mécanisme | Restauration |
|---|---|---|---|
| **SQM CAKE / fq_codel sur OpenWrt** (avec auto-tuning 95 / 90 / 85 %) | 3 — sensible | rpcd : `uci set` → `uci apply {rollback: true, timeout: 60}` → vérification de joignabilité → `uci confirm` | Sauvegarde de la section `sqm` relue avant modification ; restauration en un clic ; **retour arrière automatique du routeur** si la confirmation n’arrive pas |
| **Demander à une application de quitter** (forte consommation prouvée) | 2 — réversible | `NSRunningApplication.terminate()` : fermeture normale comme ⌘Q, jamais forcée, applications standard uniquement | Relancer l’application |

Tout le reste est **guidé**, avec les étapes exactes et les valeurs à saisir : changement de bande, de canal ou de largeur, position du Mac ou de la box, reconnexion au meilleur point d’accès, Ethernet, câble, ordre des services, DNS, VPN, QoS d’une box sans API.

### Pourquoi pas plus d’automatismes ?

- **Freebox** : la documentation officielle n’a pas pu être consultée depuis l’environnement de développement (le site réinitialise la connexion). L’écriture de la configuration Wi-Fi (canal, largeur) n’est donc pas implémentée, et aucune API QoS n’est intégrée. Ces réglages restent guidés.
- **DNS** : NetScope ne modifie pas les DNS du système. Une recommandation n’apparaît que si un benchmark reproductible montre un gain net (au moins 20 ms et au moins 30 %, sans échec), avec ce rappel : une résolution plus rapide ne signifie pas un débit plus élevé.
- **Pile réseau** : observation uniquement. Jamais de modification des paramètres TCP, de la MTU ou du noyau, jamais de désactivation d’IPv6, du pare-feu ou des protections système, jamais de réglage issu de guides non validés.
- **Wi-Fi** : aucun contournement des restrictions radio, réglementaires ou de macOS.

## Score MAX BOOST (0–100)

| Critère | Poids | Barème |
|---|---|---|
| Débit / référence | 25 | Médiane ↓ / (offre déclarée ou meilleure mesure Ethernet) ; sinon échelle absolue |
| Latence au repos | 15 | 5 ms → 100 … 300 ms → 0 |
| Latence sous charge | 20 | Latence ajoutée : 5 ms → 100, 30 → 80, 60 → 60, 200 → 25, 400 → 0 |
| Stabilité | 15 | Gigue et coefficient de variation du débit entre essais |
| Pertes | 10 | 0 % → 100, 1 % → 70, 5 % → 20, 10 % → 0 |
| Qualité radio | 10 | RSSI (+ SNR) ; 100 en Ethernet |
| Fiabilité | 5 | Déconnexions sur 24 h |

Un critère sans mesure est exclu (jamais supposé bon) et réduit la confiance. **Un score de 100 ne prouve pas qu’aucune amélioration n’est possible.**

## Règles de comparaison A/B

- Même interface, même cible de latence, même réseau, même état VPN. Sinon le verdict est « non comparable ».
- Avertissement si plus de 3 h séparent les mesures, ou si un trafic de fond important est détecté pendant une mesure.
- Une métrique n’est « améliorée » que si sa médiane varie d’au moins 10 % **et** que les intervalles interquartiles avant/après ne se recouvrent pas, avec au moins 3 mesures par état.
- Un gain non distinguable de la variabilité est présenté comme **non confirmé**.

## Sécurité

| Niveau | Contenu |
|---|---|
| 1 — automatique, non perturbateur | Mesures, diagnostics, analyses |
| 2 — modification réversible | Demande de fermeture d’une application |
| 3 — action sensible | SQM sur le routeur (peut interrompre Internet pour tous les appareils) |

Interdits : déconnexion forcée, brouillage, désauthentification Wi-Fi, usurpation ARP, toute modification silencieuse. En cas de perte de connectivité, NetScope **ne prétend pas** pouvoir restaurer à distance un routeur inaccessible. Il affiche la procédure de récupération : attendre le retour arrière automatique de rpcd, puis LuCI ou SSH, puis le mode failsafe.

Chaque modification et chaque restauration est consignée dans le journal d’audit de Router Control.

## Préparer OpenWrt pour MAX BOOST

1. Installer `sqm-scripts` (et `luci-app-sqm` si vous le souhaitez), puis créer une section `queue` sur l’interface WAN (désactivée, c’est suffisant).
2. Créer un utilisateur rpcd dont l’ACL autorise la lecture et l’écriture `uci` sur `sqm`, et la lecture de `system`.
3. Connecter le routeur dans Router Control, puis lancer MAX BOOST avec le profil ULTRA LOW LATENCY.

## Architecture

`NetScopeCore/Boost/` :

| Service | Fichier |
|---|---|
| MaxBoostOrchestrator, BoostBaselineService, NetworkRollbackManager, BoostHistoryService | `BoostOrchestration.swift` |
| PerformanceABTestingService, MaxBoostScore | `BoostScoreAndAB.swift` |
| WiFiOptimizationEngine, BandwidthContentionAnalyzer, NetworkConfigurationInspector, BufferbloatTuningService, RouterQoSOptimizer, BoostCandidateEvaluator | `BoostEngines.swift` |
| StandardBoostExecutor (seule couche qui modifie), protocoles `SQMTuning` / `ApplicationQuitting` | `BoostExecutor.swift` |
| Modèles (profils, niveaux, statuts, sessions) | `BoostModels.swift` |

Lecture et écriture sont strictement séparées : `BoostEnvironment` (dans l’app : `AppBoostEnvironment`) ne fait que lire, et seul `BoostChangeExecutor` modifie. L’orchestrateur ne transmet à l’exécuteur que les identifiants autorisés.

Tests : `Tests/NetScopeCoreTests/MaxBoostTests.swift`, soit 24 tests : score, A/B, moteurs, classement, rollback, orchestration de bout en bout (rien sans autorisation ; gain confirmé conservé ; absence de gain → restauration), et intégration OpenWrt contre un rpcd simulé (apply/confirm, restauration exacte, retour arrière automatique si le routeur devient injoignable, ACL refusée, validation des entrées, sqm-scripts absent).

## Limites

- La couche macOS (onglet, environnement réel, fermeture d’applications) n’a pas pu être compilée ici (pas de SDK macOS) ; le moteur, lui, est compilé et testé.
- L’intégration SQM n’a pas été validée sur un vrai routeur OpenWrt. La sémantique rpcd suit la documentation officielle d’OpenWrt, mais le rechargement effectif de SQM après `uci apply` dépend de la configuration de votre routeur. L’absence d’effet mesurable aboutit simplement à « Aucun gain démontré » et à une restauration.
- La consommation de données est importante : environ 3 mesures par état, et 9 mesures supplémentaires pour l’auto-tuning SQM. Une estimation s’affiche avant l’application.
- La priorisation par appareil, le changement de canal et la QoS des box autres qu’OpenWrt restent guidés.
