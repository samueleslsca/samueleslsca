#!/usr/bin/env python3
"""NetScope Pro — lightweight remote measurement agent (Raspberry Pi, Linux, macOS).

Standard library only (Python 3.9+). Requires the `openssl` CLI once, to create a self-signed
TLS certificate. Exposes a small HTTPS API used by NetScope Pro for multi-point diagnostics.

Security model
  * TLS only (self-signed certificate; NetScope pins its SHA-256 fingerprint at pairing time).
  * Explicit pairing: a random 6-digit code is printed on this console; a client must present it
    to obtain a bearer token. 5 wrong attempts regenerate the code. Pairing can be closed with --no-pairing.
  * Every other endpoint requires the bearer token (compared in constant time).
  * Commands run without a shell, with validated arguments and timeouts. Only read-only measurements:
    ping, traceroute, iperf3 client, one-shot iperf3 server. No packet capture, no configuration change.

Usage
  python3 netscope_agent.py [--port 8765] [--bind 0.0.0.0] [--state ./agent_state.json] [--no-pairing]
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import shutil
import ssl
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

VERSION = "1.0.0"
HOST_RE = re.compile(r"^(?!-)[A-Za-z0-9.\-:%]{1,253}$")
MAX_BODY = 4096


def valid_host(h: object) -> bool:
    if not isinstance(h, str) or not HOST_RE.match(h) or h.startswith("."):
        return False
    try:
        ipaddress.ip_address(h.split("%")[0])
        return True
    except ValueError:
        return all(label and len(label) <= 63 for label in h.split("."))


def bounded_int(v: object, lo: int, hi: int, default: int) -> int:
    try:
        i = int(v)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default
    return max(lo, min(hi, i))


def parse_ping(text: str) -> dict:
    samples = [float(m) for m in re.findall(r"time[=<]([\d.]+)", text)]
    sent = received = None
    m = re.search(r"(\d+) packets transmitted, (\d+) (?:packets )?received", text)
    if m:
        sent, received = int(m.group(1)), int(m.group(2))
    return {"samples_ms": samples, "sent": sent if sent is not None else len(samples),
            "received": received if received is not None else len(samples)}


class AgentState:
    def __init__(self, path: Path, allow_pairing: bool = True):
        self.path = path
        self.lock = threading.Lock()
        self.allow_pairing = allow_pairing
        self.tokens: dict[str, dict] = {}
        self.failed_attempts = 0
        self.code = self._new_code()
        if path.exists():
            try:
                data = json.loads(path.read_text())
                self.tokens = {k: v for k, v in data.get("tokens", {}).items() if isinstance(v, dict)}
            except (OSError, ValueError):
                self.tokens = {}

    @staticmethod
    def _new_code() -> str:
        return f"{secrets.randbelow(1_000_000):06d}"

    def save(self) -> None:
        tmp = self.path.with_suffix(".tmp")
        # Only token hashes are stored, never the tokens themselves.
        tmp.write_text(json.dumps({"tokens": self.tokens}))
        os.chmod(tmp, 0o600)
        tmp.replace(self.path)

    def pair(self, code: object, client: object) -> str | None:
        with self.lock:
            if not self.allow_pairing or not isinstance(code, str):
                return None
            if not hmac.compare_digest(code.encode(), self.code.encode()):
                self.failed_attempts += 1
                if self.failed_attempts >= 5:
                    self.code = self._new_code()
                    self.failed_attempts = 0
                    print(f"[pairing] trop d’essais : nouveau code {self.code}", flush=True)
                return None
            token = secrets.token_hex(32)
            digest = hashlib.sha256(token.encode()).hexdigest()
            self.tokens[digest] = {"client": str(client)[:64], "paired": int(time.time())}
            self.code = self._new_code()  # single use
            self.failed_attempts = 0
            self.save()
            print(f"[pairing] client appairé ({str(client)[:64]}). Nouveau code : {self.code}", flush=True)
            return token

    def authorized(self, header: str | None) -> bool:
        if not header or not header.startswith("Bearer "):
            return False
        digest = hashlib.sha256(header[7:].strip().encode()).hexdigest()
        with self.lock:
            return any(hmac.compare_digest(digest, d) for d in self.tokens)


def run(cmd: list[str], timeout: float) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False,
                          env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin", "LC_ALL": "C"})


class Measurements:
    @staticmethod
    def ping(target: str, count: int) -> dict:
        exe = shutil.which("ping")
        if not exe:
            raise RuntimeError("ping indisponible")
        cmd = [exe, "-n", "-c", str(count), "-i", "0.2"]
        cmd += ["-W", "1"] if sys.platform.startswith("linux") else ["-W", "1000"]
        cmd.append(target)
        r = run(cmd, timeout=count * 0.2 + 10)
        out = parse_ping(r.stdout)
        out["target"] = target
        return out

    @staticmethod
    def traceroute(target: str) -> dict:
        exe = shutil.which("traceroute")
        if not exe:
            raise RuntimeError("traceroute indisponible")
        r = run([exe, "-n", "-m", "20", "-q", "2", "-w", "2", target], timeout=90)
        return {"raw": r.stdout}

    @staticmethod
    def iperf_client(server: str, reverse: bool, seconds: int) -> dict:
        exe = shutil.which("iperf3")
        if not exe:
            raise RuntimeError("iperf3 indisponible sur l’agent")
        cmd = [exe, "-c", server, "-t", str(seconds), "-P", "4", "-J", "--connect-timeout", "3000"]
        if reverse:
            cmd.append("-R")
        r = run(cmd, timeout=seconds + 20)
        return {"raw": r.stdout}

    @staticmethod
    def iperf_server_once() -> dict:
        exe = shutil.which("iperf3")
        if not exe:
            return {"started": False, "error": "iperf3 indisponible sur l’agent"}
        # One test then exit; detached so the HTTP response returns immediately. Hard stop after 60 s.
        proc = subprocess.Popen([exe, "-s", "-1"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        threading.Timer(60, lambda: proc.poll() is None and proc.kill()).start()
        return {"started": True, "port": 5201}


def make_handler(state: AgentState):
    class Handler(BaseHTTPRequestHandler):
        server_version = f"NetScopeAgent/{VERSION}"
        sys_version = ""

        def log_message(self, fmt: str, *args) -> None:  # concise, no secrets
            sys.stderr.write(f"[{self.address_string()}] {self.command} {self.path.split('?')[0]}\n")

        def _json(self, status: int, payload: dict) -> None:
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _body(self) -> dict | None:
            try:
                n = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                return None
            if n < 0 or n > MAX_BODY:
                return None
            try:
                data = json.loads(self.rfile.read(n) or b"{}")
            except ValueError:
                return None
            return data if isinstance(data, dict) else None

        def do_GET(self) -> None:
            self._json(405, {"error": "POST uniquement"})

        def do_POST(self) -> None:
            body = self._body()
            if body is None:
                return self._json(400, {"error": "corps JSON invalide"})
            if self.path == "/pair":
                token = state.pair(body.get("code"), body.get("client", "inconnu"))
                return self._json(200, {"token": token}) if token else self._json(403, {"error": "code invalide ou appairage fermé"})
            if not state.authorized(self.headers.get("Authorization")):
                return self._json(401, {"error": "non autorisé"})
            try:
                if self.path == "/info":
                    return self._json(200, {"version": VERSION, "platform": sys.platform,
                                            "iperf3": shutil.which("iperf3") is not None,
                                            "traceroute": shutil.which("traceroute") is not None})
                if self.path == "/ping":
                    target = body.get("target")
                    if not valid_host(target):
                        return self._json(400, {"error": "cible invalide"})
                    return self._json(200, Measurements.ping(target, bounded_int(body.get("count"), 1, 100, 20)))
                if self.path == "/traceroute":
                    target = body.get("target")
                    if not valid_host(target):
                        return self._json(400, {"error": "cible invalide"})
                    return self._json(200, Measurements.traceroute(target))
                if self.path == "/iperf":
                    server = body.get("server")
                    if not valid_host(server):
                        return self._json(400, {"error": "serveur invalide"})
                    return self._json(200, Measurements.iperf_client(server, bool(body.get("reverse")), bounded_int(body.get("seconds"), 1, 30, 8)))
                if self.path == "/iperf-server":
                    return self._json(200, Measurements.iperf_server_once())
            except (RuntimeError, subprocess.TimeoutExpired) as e:
                return self._json(503, {"error": str(e)})
            return self._json(404, {"error": "inconnu"})

    return Handler


def ensure_certificate(directory: Path) -> tuple[Path, Path]:
    cert, key = directory / "agent_cert.pem", directory / "agent_key.pem"
    if cert.exists() and key.exists():
        return cert, key
    if not shutil.which("openssl"):
        sys.exit("openssl est requis pour créer le certificat TLS de l’agent.")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
                    "-nodes", "-keyout", str(key), "-out", str(cert), "-days", "825",
                    "-subj", "/CN=NetScope Agent"], check=True, capture_output=True)
    os.chmod(key, 0o600)
    return cert, key


def fingerprint(cert: Path) -> str:
    der = ssl.PEM_cert_to_DER_cert(cert.read_text())
    return hashlib.sha256(der).hexdigest()


def build_server(bind: str, port: int, state: AgentState, cert: Path, key: Path) -> ThreadingHTTPServer:
    httpd = ThreadingHTTPServer((bind, port), make_handler(state))
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(str(cert), str(key))
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    return httpd


def main() -> None:
    ap = argparse.ArgumentParser(description="NetScope Pro measurement agent")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--state", default=str(Path(__file__).with_name("agent_state.json")))
    ap.add_argument("--no-pairing", action="store_true", help="refuse new pairings")
    a = ap.parse_args()
    state_path = Path(a.state)
    cert, key = ensure_certificate(state_path.parent)
    state = AgentState(state_path, allow_pairing=not a.no_pairing)
    httpd = build_server(a.bind, a.port, state, cert, key)
    print(f"NetScope Agent {VERSION} — https://{a.bind}:{a.port}")
    print(f"Empreinte SHA-256 du certificat : {fingerprint(cert)}")
    print(f"Code d’appairage : {state.code}" if state.allow_pairing else "Appairage fermé (--no-pairing).", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
