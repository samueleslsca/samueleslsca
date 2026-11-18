# Guide utilisateur

## Lire les valeurs

Chaque valeur porte un badge :
- **Mesuré** (vert) : mesuré sur ce Mac (CoreWLAN, ping, networkQuality…)
- **Fourni par le routeur** (bleu) : rapporté par l’API de votre box
- **Calculé** (turquoise) : déduit d’autres mesures, par exemple SNR = RSSI − bruit
- **Estimé** (orange) : modèle ou heuristique, donc incertain
- **Non disponible** (gris) : survolez le badge pour lire la raison

Le **mode confidentialité** (icône œil, barre d’outils) masque IP, MAC et SSID à l’écran et dans les exports. Activez-le avant une capture d’écran.

## Parcours conseillé quand « ça rame »

1. **Diagnostics & Optimization → Lancer le diagnostic** : 8 étapes, du local vers Internet. Cochez le speedtest si vous acceptez la consommation de données.
2. Lisez l’**analyse finale** : faits observés, puis hypothèses classées par confiance. Chacune liste les éléments qui la soutiennent (+), ceux qui la contredisent (−), les vérifications à faire et les actions, avec leur risque et leur réversibilité.
3. L’**Optimization Center** sépare ce qui améliore la **latence**, la **stabilité** et le **débit réel**.
4. Après une modification (emplacement, canal, câble, QoS), relancez les mêmes tests au moins 3 fois. **History & Reports → Avant / après** n’annonce une amélioration que si l’écart dépasse la variabilité normale.

## Questions fréquentes (assistant local)

L’assistant répond hors ligne à partir de vos mesures : « Pourquoi mon Wi-Fi est-il lent ? », « Pourquoi un bon débit mais un ping élevé ? » (souvent du bufferbloat), « Pourquoi mes appels vidéo coupent-ils ? », etc. L’assistant IA est facultatif (Réglages → Assistant) : chaque envoi demande une confirmation et ne transmet qu’un résumé masqué.

## Tester correctement son débit

- Évitez les transferts en cours : NetScope vous prévient si l’interface est déjà chargée.
- Comparez **Wi-Fi et Ethernet** : un test en Ethernet sur la box isole l’accès Internet.
- Bits contre octets : les débits sont en Mbit/s, les volumes en Mo (1 Mo/s = 8 Mbit/s).
- Un seul test ne prouve rien. Répétez à différentes heures, ou activez les tests planifiés (Réglages).
- **Test LAN** : installez `iperf3` sur une autre machine (`iperf3 -s`), indiquez son adresse dans Réglages, puis choisissez le mode LAN. C’est une mesure du réseau local, pas d’Internet.

## Wi-Fi

- **RSSI** : ≥ −60 dBm excellent, −67 bon, −75 moyen, en dessous faible. **SNR** : ≥ 40 dB excellent, 25 bon, 15 moyen.
- **Scanner** les voisins interrompt brièvement la liaison : faites-le à la demande, au plus toutes les 30 s.
- La recommandation de canal tient compte de la charge mesurée et ne propose pas systématiquement la plus grande largeur : 20 MHz en 2,4 GHz, 40 à 80 MHz en 5 GHz dense.

## Appareils

- **Découvrir (passif)** lit les caches et écoute Bonjour. **Sondage actif** pingue chaque adresse de votre sous-réseau privé (après confirmation), uniquement sur un réseau qui vous appartient.
- Marquez vos appareils « connus » ; un nouvel appareil déclenche une alerte si l’option est activée.
- Un appareil « non observé récemment » n’est pas forcément déconnecté (veille, MAC aléatoire, absence de trafic).

## Box / routeur

- **Freebox** : Router Control → Détecter → Connecter, puis validez « NetScope Pro » sur l’écran de la Freebox. Pour le blocage, accordez la permission « Modification des réglages » à l’application dans Freebox OS. Un blocage passe par 5 étapes : appareil, vérifications, conséquences, confirmation, exécution vérifiée. Il est consigné dans le journal.
- **OpenWrt** : créez un utilisateur rpcd avec des droits de lecture (ubus), puis connectez-vous dans Router Control. Le mot de passe est stocké dans le trousseau.

## Laboratoires

- **Bufferbloat & QoS Lab** : 3 essais « avant », modification de la QoS/SQM sur la box, puis 3 essais « après ». Cible : la passerelle (file d’attente locale) ou 1.1.1.1 (file d’attente de l’accès).
- **Internet Health Monitor** : activez-le pour quelques jours. Il distingue les coupures locales (passerelle injoignable), les coupures Internet et les défaillances DNS.
- **Multi-point** : lancez l’agent sur un Raspberry Pi en Ethernet, appairez-le, puis lancez la comparaison pour savoir si le problème vient du Wi-Fi, du LAN, de la box ou de l’accès.
- **Wi-Fi Heatmap** : importez un plan, étalonnez l’échelle (2 points + distance), puis cliquez votre position dans chaque pièce. Recommencez avec un autre « emplacement du routeur » pour comparer.
- **ISP Performance Audit** : saisissez votre offre, faites des tests en Ethernet à différentes heures, puis générez le **rapport technique pour votre opérateur**.
- **Gaming Lab** : ajoutez les serveurs documentés par l’éditeur du jeu. NetScope signale les indices de CGNAT ou de double NAT, sans prétendre connaître le NAT de la console.

## Barre de menus

L’icône réseau ouvre une synthèse : état, interface, IP, signal, latence passerelle, dernier test, bouton Quick Test.
