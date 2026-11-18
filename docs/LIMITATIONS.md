# Limitations connues

## Liées à cette livraison

1. **Couche macOS non compilée.** `NetScopeSystem` et l’application SwiftUI ont été écrites dans un environnement Linux sans SDK macOS. Elles s’appuient sur des API documentées (les énumérations CoreWLAN sont mappées par valeur brute pour limiter les écarts entre SDK), mais **le premier build dans Xcode révélera probablement quelques erreurs** de type ou de signature à corriger.
2. **Aucune exécution sur macOS réelle.** Les parseurs ont été validés sur des échantillons écrits à la main au format documenté. `swift run NetScopePro --self-test` sert à les vérifier sur la sortie réelle de votre Mac.
3. **CI macOS non exécutée.** Le workflow `.github/workflows/ci.yml` est prêt, mais GitHub Actions a refusé les jobs sans leur assigner de runner (Actions désactivé ou bloqué par la facturation sur le compte).
4. **Adaptateurs routeurs non validés sur matériel.** Freebox et OpenWrt suivent leur documentation officielle et sont testés contre un transport simulé. Les noms de champs de l’API Freebox peuvent varier selon la version du firmware.
5. **Pas d’icône d’application** dédiée (icône générique de macOS).

## Liées aux plateformes et aux API

- **Débits Internet** : mesurés vers l’infrastructure Apple (`networkQuality`) ; un autre serveur peut donner un résultat différent. `networkQuality` ne fournit pas de taux de pertes : les pertes viennent d’un ping ICMP séparé.
- **Courbe en direct** : débit réel de l’interface pendant le test (compteurs système), pas une métrique interne de `networkQuality`, qui ne publie pas de résultats intermédiaires exploitables en JSON.
- **SSID/BSSID** : nécessitent l’autorisation de localisation depuis macOS 14.4.
- **MLO, OFDMA, temps d’antenne, clients d’un autre point d’accès** : non exposés par macOS.
- **Appareils** : la découverte passive ne voit que les appareils récemment actifs vis-à-vis du Mac ou annoncés par Bonjour. Sans routeur compatible, NetScope ignore combien d’appareils sont réellement connectés et ne connaît pas leur trafic.
- **Fabricants** : aucune base OUI n’est fournie (licence et mise à jour). Importez `oui.csv` depuis le registre public de l’IEEE (Réglages). Les adresses MAC aléatoires n’ont pas de fabricant.
- **Trafic par processus** : différence de compteurs cumulés fournis par `nettop`. Un processus apparu entre deux relevés n’est pas comptabilisé.
- **Blocage Freebox** : filtrage MAC Wi-Fi uniquement, sans effet sur l’Ethernet, et contournable par un appareil qui change d’adresse MAC. Il n’est effectif que si la box est en mode « liste noire ». Le passage en liste blanche n’est volontairement pas proposé.
- **NAT** : NetScope détecte des indices de CGNAT ou de double NAT, mais ne connaît pas le type de NAT affiché par une console.
- **Vulnérabilités** : aucune base de CVE intégrée. La version du firmware est rapportée et marquée « non vérifié ».
- **Heatmap** : 2D uniquement, pas de 3D. L’interpolation IDW n’extrapole pas au-delà de 3 m d’un point de mesure. Les suggestions de points d’accès et le modèle d’atténuation des murs sont des estimations.
- **Monitoring** : il s’arrête quand l’application est fermée (pas de démon système). Une coupure plus courte que l’intervalle de vérification peut passer inaperçue.
- **Application non sandboxée** : NetScope lance des outils système en lecture (`networkQuality`, `ping`, `netstat`, `arp`, `nettop`…), incompatibles avec le bac à sable de l’App Store. La distribution se fait donc hors App Store, signée avec Hardened Runtime.
- **Sans privilèges administrateur** : toutes les fonctions marchent sans sudo. En contrepartie, pas de capture de paquets ni de mesure radio de bas niveau.
- **MAX BOOST** : seules deux actions sont automatisables (SQM sur OpenWrt, demande de fermeture d’une application standard) ; tout le reste est guidé. L’écriture Wi-Fi de la Freebox n’est pas implémentée, faute d’avoir pu vérifier sa documentation officielle. Voir [MAX_BOOST.md](MAX_BOOST.md).
- **Assistant IA** : facultatif. Il nécessite votre propre clé API et une confirmation à chaque envoi ; seules des données masquées sont transmises.
