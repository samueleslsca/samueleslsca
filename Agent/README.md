# Agent de mesure NetScope

Petit serveur HTTPS (Python 3.9+, bibliothèque standard uniquement) à installer sur une seconde machine de votre réseau, idéalement un Raspberry Pi **en Ethernet**. Il permet à NetScope Pro de comparer des mesures prises à plusieurs endroits et de localiser le segment responsable d’un ralentissement.

## Installation

```bash
sudo apt install python3 openssl iputils-ping traceroute iperf3   # iperf3 et traceroute optionnels
python3 netscope_agent.py --port 8765
```

Au démarrage, l’agent affiche :
- l’**empreinte SHA-256** de son certificat TLS (créé une fois, auto-signé) ;
- un **code d’appairage** à 6 chiffres, à usage unique.

Dans NetScope Pro → Multi-point Diagnostics → Appairer un agent, saisissez l’adresse IP, le port et le code. **Vérifiez que l’empreinte affichée par l’app correspond à celle de l’agent.** Une fois appairé, relancez l’agent avec `--no-pairing` pour refuser toute nouvelle demande.

## Sécurité

- HTTPS uniquement (TLS 1.2 minimum). NetScope épingle le certificat : toute substitution est refusée.
- Jeton porteur aléatoire de 256 bits ; l’agent n’en stocke que l’empreinte SHA-256 (`agent_state.json`, permissions 600).
- 5 codes erronés provoquent un nouveau code.
- Commandes lancées sans shell, arguments validés, délais maximaux. Mesures en lecture seule : ping, traceroute, client iperf3, serveur iperf3 à usage unique. Aucune capture, aucune modification de configuration.

## API (POST JSON)

| Point | Corps | Réponse |
|---|---|---|
| `/pair` | `{"code": "123456", "client": "…"}` | `{"token": "…"}` |
| `/info` | `{}` | version, plateforme, outils disponibles |
| `/ping` | `{"target": "1.1.1.1", "count": 20}` | `samples_ms`, `sent`, `received` |
| `/traceroute` | `{"target": "…"}` | sortie brute |
| `/iperf` | `{"server": "…", "reverse": true, "seconds": 8}` | JSON iperf3 brut |
| `/iperf-server` | `{}` | démarre `iperf3 -s -1` (un seul test, arrêt au bout de 60 s maximum) |

## Tests

```bash
python3 -m unittest discover -s Agent -p "test_*.py" -v
```

## Service systemd (facultatif)

```ini
# /etc/systemd/system/netscope-agent.service
[Unit]
Description=NetScope measurement agent
After=network-online.target
[Service]
ExecStart=/usr/bin/python3 /opt/netscope/netscope_agent.py --port 8765 --no-pairing
User=netscope
Restart=on-failure
[Install]
WantedBy=multi-user.target
```
