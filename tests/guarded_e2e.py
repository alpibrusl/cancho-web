#!/usr/bin/env python3
"""End-to-end tests of examples/guarded: the real binary, real sockets.

    python3 tests/guarded_e2e.py                    # builds with scripts/build.sh
    BIN=build/guarded python3 tests/guarded_e2e.py

What is held to the document: the operations the document says need a credential answer 401 without one, 403 with a
credential that opens another door, and pass with one that opens this; every status the service answers is a status the
document declares for that operation; and the access log names the path and never the query string or a token.
"""
import http.client
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.environ.get("BIN")
ADMIN, INGEST = "adm1n-s3cret", "1ngest-s3cret"
PROC = PORT = DOC = None
LOG = []


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def setUpModule():
    global PROC, PORT, DOC, BIN
    if not BIN:
        BIN = os.path.join(tempfile.mkdtemp(prefix="guarded-"), "guarded")
        subprocess.run([os.path.join(ROOT, "scripts", "build.sh"), os.path.join(ROOT, "examples", "guarded", "guarded.cho"), BIN], check=True)
    PORT = free_port()
    PROC = subprocess.Popen([BIN, str(PORT), ADMIN, INGEST], stderr=subprocess.PIPE)
    assert PROC.stderr.readline().decode().strip() == "listening on %d" % PORT

    def drain():
        for line in PROC.stderr:
            LOG.append(line.decode().rstrip("\n"))

    threading.Thread(target=drain, daemon=True).start()
    DOC = json.loads(call("GET", "/openapi.json")[2])


def tearDownModule():
    PROC.kill()


def call(method, path, token=None, header=None):
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    headers = {}
    if token is not None:
        headers["Authorization"] = "Bearer " + token
    if header is not None:
        headers["Authorization"] = header
    c.request(method, path, headers=headers)
    r = c.getresponse()
    body = r.read()
    c.close()
    declared = DOC["paths"].get(path.split("?")[0], {}).get(method.lower()) if DOC else None
    if declared is not None:
        assert str(r.status) in declared["responses"], (method, path, r.status, "is not a status the document declares")
    return r.status, r, body


class Guard(unittest.TestCase):
    def test_an_open_operation_needs_nothing(self):
        self.assertEqual(call("GET", "/health")[0], 200)
        self.assertEqual(call("GET", "/health", token="garbage")[0], 200)

    def test_no_credential_is_a_401_that_asks_for_one(self):
        for method, path in (("GET", "/report"), ("POST", "/events")):
            status, r, body = call(method, path)
            self.assertEqual(status, 401)
            self.assertEqual(r.getheader("WWW-Authenticate"), "Bearer")
            self.assertTrue(r.getheader("Content-Type").startswith("application/problem+json"))
            self.assertEqual(json.loads(body)["status"], 401)

    def test_a_token_nobody_holds_is_a_401_invalid_token(self):
        status, r, _ = call("GET", "/report", token="nope")
        self.assertEqual(status, 401)
        self.assertEqual(r.getheader("WWW-Authenticate"), 'Bearer error="invalid_token"')
        for near in (ADMIN[:-1], ADMIN + "x", ADMIN.upper()):
            self.assertEqual(call("GET", "/report", token=near)[0], 401, near)

    def test_a_token_that_opens_another_door_is_a_403(self):
        status, r, body = call("GET", "/report", token=INGEST)
        self.assertEqual(status, 403)
        self.assertEqual(r.getheader("WWW-Authenticate"), 'Bearer error="insufficient_scope"')
        self.assertEqual(json.loads(body)["title"], "Forbidden")

    def test_any_one_alternative_will_do(self):
        self.assertEqual(call("GET", "/report", token=ADMIN)[0], 200)
        self.assertEqual(call("POST", "/events", token=INGEST)[0], 202)
        self.assertEqual(call("POST", "/events", token=ADMIN)[0], 202)

    def test_the_header_is_read_as_the_rfc_says(self):
        self.assertEqual(call("GET", "/report", header="bearer " + ADMIN)[0], 200)
        self.assertEqual(call("GET", "/report", header="BEARER   " + ADMIN)[0], 200)
        self.assertEqual(call("GET", "/report", header="Basic " + ADMIN)[0], 401)
        self.assertEqual(call("GET", "/report", header="Bearer")[0], 401)

    def test_the_document_says_what_the_gate_does(self):
        self.assertEqual(DOC["paths"]["/report"]["get"]["security"], [{"admin": []}])
        self.assertEqual(DOC["paths"]["/events"]["post"]["security"], [{"ingest": []}, {"admin": []}])
        self.assertEqual(DOC["paths"]["/health"]["get"]["security"], [])
        self.assertEqual(sorted(DOC["components"]["securitySchemes"]), ["admin", "ingest"])
        for scheme in DOC["components"]["securitySchemes"].values():
            self.assertEqual((scheme["type"], scheme["scheme"]), ("http", "bearer"))

    def test_routing_and_parameter_refusals_come_first_and_are_public(self):
        self.assertEqual(call("GET", "/nope")[0], 404)
        self.assertEqual(call("DELETE", "/report")[0], 405)

    def test_the_log_names_the_path_and_never_the_query_or_a_token(self):
        call("GET", "/health?token=" + ADMIN + "&x=1")
        call("GET", "/report", token=ADMIN)
        call("GET", "/report", token="not-" + ADMIN)
        import time
        time.sleep(0.3)
        text = "\n".join(LOG)
        self.assertIn("GET /health 200 ", text)
        self.assertIn("GET /report 200 ", text)
        self.assertIn("GET /report 401 ", text)
        for secret in (ADMIN, INGEST, "x=1", "?"):
            self.assertNotIn(secret, text)
        for line in LOG:
            self.assertRegex(line, r"^[A-Z]+ /\S* \d{3} \d+ms$")


if __name__ == "__main__":
    unittest.main(verbosity=2)
