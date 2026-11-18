"""Integration tests for the NetScope agent: starts a real HTTPS server on localhost."""
import hashlib
import json
import shutil
import ssl
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

import netscope_agent as agent


def post(port, path, body, token=None, ctx=None):
    req = urllib.request.Request(f"https://127.0.0.1:{port}{path}", data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", **({"Authorization": f"Bearer {token}"} if token else {})})
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=30) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


@unittest.skipUnless(shutil.which("openssl"), "openssl required")
class AgentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp())
        cls.cert, cls.key = agent.ensure_certificate(cls.tmp)
        cls.state = agent.AgentState(cls.tmp / "state.json")
        cls.httpd = agent.build_server("127.0.0.1", 0, cls.state, cls.cert, cls.key)
        cls.port = cls.httpd.server_address[1]
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()
        # Client trusts exactly this self-signed certificate (equivalent of NetScope's pinning).
        cls.ctx = ssl.create_default_context(cafile=str(cls.cert))
        cls.ctx.check_hostname = False

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def pair(self):
        status, body = post(self.port, "/pair", {"code": self.state.code, "client": "test"}, ctx=self.ctx)
        self.assertEqual(status, 200)
        return body["token"]

    def test_fingerprint_matches_der(self):
        der = ssl.PEM_cert_to_DER_cert(self.cert.read_text())
        self.assertEqual(agent.fingerprint(self.cert), hashlib.sha256(der).hexdigest())

    def test_requires_auth(self):
        status, _ = post(self.port, "/info", {}, ctx=self.ctx)
        self.assertEqual(status, 401)
        status, _ = post(self.port, "/info", {}, token="deadbeef", ctx=self.ctx)
        self.assertEqual(status, 401)

    def test_pairing_single_use_and_tokens_hashed(self):
        code = self.state.code
        token = self.pair()
        self.assertNotEqual(code, self.state.code, "code is single-use")
        status, _ = post(self.port, "/pair", {"code": code}, ctx=self.ctx)
        self.assertEqual(status, 403)
        saved = (self.tmp / "state.json").read_text()
        self.assertNotIn(token, saved, "raw token never persisted")
        status, info = post(self.port, "/info", {}, token=token, ctx=self.ctx)
        self.assertEqual(status, 200)
        self.assertEqual(info["version"], agent.VERSION)

    def test_bruteforce_regenerates_code(self):
        before = self.state.code
        for _ in range(5):
            post(self.port, "/pair", {"code": "000000" if before != "000000" else "111111"}, ctx=self.ctx)
        self.assertNotEqual(before, self.state.code)

    def test_input_validation(self):
        token = self.pair()
        for bad in ["-f", "8.8.8.8; rm -rf /", "a b", "", 42, "$(id)"]:
            status, _ = post(self.port, "/ping", {"target": bad}, token=token, ctx=self.ctx)
            self.assertEqual(status, 400, bad)
        status, _ = post(self.port, "/iperf", {"server": "--help"}, token=token, ctx=self.ctx)
        self.assertEqual(status, 400)

    def test_ping_localhost(self):
        token = self.pair()
        status, body = post(self.port, "/ping", {"target": "127.0.0.1", "count": 3}, token=token, ctx=self.ctx)
        if status == 503:
            self.skipTest(body.get("error"))
        self.assertEqual(status, 200)
        self.assertEqual(body["target"], "127.0.0.1")
        self.assertIn("samples_ms", body)

    def test_untrusted_client_rejected(self):
        strict = ssl.create_default_context()
        with self.assertRaises(urllib.error.URLError):
            post(self.port, "/info", {}, ctx=strict)

    def test_parsers_and_validators(self):
        mac = "4 packets transmitted, 3 packets received, 25.0% packet loss\n64 bytes: time=1.5 ms\n64 bytes: time=2.5 ms"
        self.assertEqual(agent.parse_ping(mac)["received"], 3)
        linux = "64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=9.81 ms\n2 packets transmitted, 1 received, 50% packet loss"
        self.assertEqual(agent.parse_ping(linux)["samples_ms"], [9.81])
        self.assertTrue(agent.valid_host("fe80::1%en0"))
        self.assertTrue(agent.valid_host("speed.example.net"))
        self.assertFalse(agent.valid_host("-oProxyCommand=x"))
        self.assertEqual(agent.bounded_int("9999", 1, 100, 20), 100)
        self.assertEqual(agent.bounded_int(None, 1, 100, 20), 20)


if __name__ == "__main__":
    unittest.main()
