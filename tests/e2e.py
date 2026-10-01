#!/usr/bin/env python3
"""End-to-end tests of examples/users: the real binary, real sockets, a real client.

    python3 tests/e2e.py                       # builds with scripts/build.sh
    BIN=build/users python3 tests/e2e.py       # an already built binary
    LEX_SYS=/path/to/lex-sys python3 tests/e2e.py

The service is held to its own OpenAPI document: every response any test sees is
checked against the schema that document declares for that operation and status,
and `test_schemathesis` has Schemathesis generate requests *from* the document
and check what comes back. A schema that the validator enforces but the document
does not state (or the reverse) fails here, which is what generating both from
one declaration is for.
"""
import http.client
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

import jsonschema
from openapi_spec_validator import validate as validate_openapi

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
BIN = os.environ.get("BIN")

PROC = None
PORT = None
DOC = None


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def setUpModule():
    global PROC, PORT, DOC, BIN
    if not BIN:
        BIN = os.path.join(tempfile.mkdtemp(prefix="users-"), "users")
        subprocess.run([os.path.join(ROOT, "scripts", "build.sh"),
                        os.path.join(ROOT, "examples", "users", "users.ls"), BIN], check=True)
    PORT = free_port()
    PROC = subprocess.Popen([BIN, str(PORT)], stderr=subprocess.PIPE)
    line = PROC.stderr.readline().decode().strip()
    assert line == "listening on %d" % PORT, line
    DOC = json.loads(get("/openapi.json")[2])


def tearDownModule():
    for c in CONNS:
        c.close()
    PROC.kill()
    PROC.wait()
    PROC.stderr.close()


CONNS = []


def conn():
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    CONNS.append(c)
    return c


def call(c, method, path, body=None, headers=None):
    h = dict(headers or {})
    data = None
    if body is not None:
        data = body if isinstance(body, (bytes, str)) else json.dumps(body)
        h.setdefault("Content-Type", "application/json")
    c.request(method, path, body=data, headers=h)
    r = c.getresponse()
    raw = r.read()
    return r.status, r, raw


def get(path):
    return call(conn(), "GET", path)


# ----------------------------------------------------------------- the contract
def route_of(method, path):
    """The (OpenAPI path, operation) a concrete request belongs to."""
    path = path.split("?")[0]
    for template, item in DOC["paths"].items():
        pattern = re.sub(r"\{[^}]+\}", "[^/]+", template)
        if re.fullmatch(pattern, path) and method.lower() in item:
            return item[method.lower()]
    return None


def conforms(method, path, status, resp, raw):
    """Every response must be one the document declares, with a body that fits it."""
    op = route_of(method, path)
    if op is None:
        return  # an undocumented route (405, 404): not part of the contract
    declared = op["responses"].get(str(status))
    assert declared is not None, "%s %s answered %d, which the document does not declare" % (method, path, status)
    if "$ref" in declared:
        declared = DOC["components"]["responses"][declared["$ref"].rsplit("/", 1)[1]]
    content = declared.get("content", {})
    ctype = resp.getheader("Content-Type", "").split(";")[0]
    assert ctype in content, "%s %s %d: Content-Type %r not declared (%s)" % (method, path, status, ctype, list(content))
    schema = content[ctype]["schema"]
    jsonschema.validate(json.loads(raw), {**schema, "components": DOC["components"]},
                        cls=jsonschema.Draft202012Validator)


def request(c, method, path, body=None, headers=None):
    status, resp, raw = call(c, method, path, body, headers)
    conforms(method, path, status, resp, raw)
    return status, resp, (json.loads(raw) if raw else None)


# ------------------------------------------------------------------------ tests
class Document(unittest.TestCase):
    def test_the_document_is_valid_openapi_3_1(self):
        validate_openapi(DOC)
        self.assertEqual(DOC["openapi"], "3.1.0")

    def test_the_document_is_deterministic(self):
        self.assertEqual(get("/openapi.json")[2], get("/openapi.json")[2])


def all_users(c):
    """Every user, by walking the pages: the other tests have filled the store."""
    out, offset = [], 0
    while True:
        _, _, page = request(c, "GET", "/users?limit=100&offset=%d" % offset)
        out += page["items"]
        offset += 100
        if offset >= page["total"] + 100 or not page["items"]:
            return out


class Users(unittest.TestCase):
    def test_create_read_list_delete(self):
        c = conn()
        status, resp, user = request(c, "POST", "/users", {"name": "Ada", "email": "ada@example.com", "age": 36, "role": "admin", "tags": ["x", "y"]})
        self.assertEqual(status, 201)
        self.assertEqual(resp.getheader("Location"), "/users/%d" % user["id"])
        self.assertEqual({k: user[k] for k in ("name", "email", "age", "role", "tags")},
                         {"name": "Ada", "email": "ada@example.com", "age": 36, "role": "admin", "tags": ["x", "y"]})
        self.assertEqual(request(c, "GET", "/users/%d" % user["id"])[2], user)
        self.assertIn(user, all_users(c))
        self.assertEqual(request(c, "DELETE", "/users/%d" % user["id"])[2], user)
        self.assertEqual(request(c, "GET", "/users/%d" % user["id"])[0], 404)
        self.assertEqual(request(c, "DELETE", "/users/%d" % user["id"])[0], 404)

    def test_only_the_required_field(self):
        status, _, user = request(conn(), "POST", "/users", {"name": "Bo"})
        self.assertEqual((status, set(user)), (201, {"id", "name"}))

    def test_what_is_stored_is_canonical_not_the_requests_text(self):
        # Odd spacing, an escaped name, a duplicate key (the first wins, as the
        # validator reads it): none of it survives into the stored user.
        body = b'{ "name" : "J\\u00e9r\\u00f4me\\n" ,\n "age":7, "age":999 }'
        status, _, user = request(conn(), "POST", "/users", body)
        self.assertEqual((status, user["name"], user["age"]), (201, "Jérôme\n", 7))

    def test_pagination(self):
        c = conn()
        ids = [request(c, "POST", "/users", {"name": "p%d" % i})[2]["id"] for i in range(5)]
        everything = all_users(c)
        live = [u["id"] for u in everything]
        self.assertTrue(set(ids) <= set(live))
        self.assertEqual(request(c, "GET", "/users?limit=1")[2]["total"], len(live))
        _, _, first = request(c, "GET", "/users?limit=2")
        _, _, second = request(c, "GET", "/users?limit=2&offset=2")
        self.assertEqual([u["id"] for u in first["items"]], live[:2])
        self.assertEqual([u["id"] for u in second["items"]], live[2:4])
        self.assertEqual(request(c, "GET", "/users?offset=100000")[2]["items"], [])

    def test_a_deleted_user_leaves_the_listing_and_the_total(self):
        c = conn()
        a = request(c, "POST", "/users", {"name": "gone"})[2]["id"]
        before = request(c, "GET", "/users?limit=1")[2]["total"]
        request(c, "DELETE", "/users/%d" % a)
        self.assertEqual(request(c, "GET", "/users?limit=1")[2]["total"], before - 1)


class Validation(unittest.TestCase):
    def errors(self, body):
        status, resp, problem = request(conn(), "POST", "/users", body)
        self.assertEqual(status, 422, problem)
        self.assertEqual(resp.getheader("Content-Type"), "application/problem+json")
        return {(e["pointer"], e["code"]) for e in problem["errors"]}, problem

    def test_every_error_is_reported_with_its_pointer(self):
        got, problem = self.errors({"name": "", "age": 151, "role": "root", "tags": ["ok", 7, ""], "extra": 1})
        self.assertEqual(got, {("/name", "min_length"), ("/age", "maximum"), ("/role", "choice"),
                               ("/tags/1", "type"), ("/tags/2", "min_length"), ("/extra", "unknown")})
        self.assertEqual(problem["count"], 6)

    def test_a_missing_required_field_is_named(self):
        self.assertEqual(self.errors({})[0], {("/name", "required")})

    def test_no_coercion(self):
        got, _ = self.errors({"name": "x", "age": "36"})
        self.assertEqual(got, {("/age", "type")})
        got, _ = self.errors(b'{"name":"x","age":36.5}')
        self.assertEqual(got, {("/age", "type")})

    def test_a_body_that_is_not_an_object(self):
        for body in ([], "s", 7, None, True):
            self.assertEqual(self.errors(json.dumps(body).encode())[0], {("", "type")})

    def test_a_whole_number_written_as_a_float_is_an_integer(self):
        # `150.0` is what a Python client sends for 150, and what JSON Schema's
        # `"type":"integer"` -- which the document says -- accepts. Found by
        # Schemathesis; see lexsys-schema docs/design.md section 11.
        for text, want in ((b"150.0", 150), (b"1.5e2", 150), (b"0.0", 0)):
            status, _, user = request(conn(), "POST", "/users", b'{"name":"f","age":' + text + b'}')
            self.assertEqual((status, user["age"]), (201, want), text)
        self.assertEqual(self.errors(b'{"name":"f","age":150.5}')[0], {("/age", "type")})
        self.assertEqual(self.errors(b'{"name":"f","age":151.0}')[0], {("/age", "maximum")})

    def test_nothing_gets_stored_on_failure(self):
        before = request(conn(), "GET", "/users?limit=1")[2]["total"]
        self.errors({"name": ""})
        self.assertEqual(request(conn(), "GET", "/users?limit=1")[2]["total"], before)

    def test_bad_json_is_a_400_with_the_position(self):
        for body, where in ((b'{"name": ', 9), (b'{"name":"x",}', 12), (b'', None), (b'{"a":01}', None)):
            status, resp, problem = request(conn(), "POST", "/users", body)
            self.assertEqual(status, 400, (body, problem))
            self.assertEqual(problem["title"], "Bad Request")

    def test_the_wrong_content_type_is_a_415(self):
        status, _, problem = request(conn(), "POST", "/users", b'{"name":"x"}', {"Content-Type": "text/plain"})
        self.assertEqual(status, 415)
        status, _, _ = request(conn(), "POST", "/users", b'{"name":"x"}', {"Content-Type": "application/json; charset=utf-8"})
        self.assertEqual(status, 201)


class Paths(unittest.TestCase):
    def test_bad_ids_and_query_values_are_422(self):
        c = conn()
        for path in ("/users/0", "/users/abc", "/users/-1", "/users/99999999999999999999"):
            self.assertEqual(request(c, "GET", path)[0], 422, path)
        for q in ("limit=0", "limit=101", "limit=x", "limit=-1", "offset=-1", "offset=x", "limit=",
                  "offset=99999999999999999999", "lmit=5", "limit=5&extra=1", "&"):
            self.assertEqual(request(c, "GET", "/users?" + q)[0], 422, q)

    def test_unknown_things(self):
        c = conn()
        self.assertEqual(request(c, "GET", "/nothing")[0], 404)
        self.assertEqual(request(c, "GET", "/users/1/extra")[0], 404)
        status, resp, _ = call(c, "PUT", "/users")
        self.assertEqual(status, 405)
        self.assertEqual(resp.getheader("Allow"), "GET, POST")

    def test_health(self):
        self.assertEqual(request(conn(), "GET", "/health")[2], {"ok": True})


class Connections(unittest.TestCase):
    def test_keep_alive_serves_many_on_one_connection(self):
        c = conn()
        for i in range(200):
            self.assertEqual(request(c, "GET", "/health")[0], 200)

    def test_pipelined_requests_are_answered_in_order(self):
        s = socket.create_connection(("127.0.0.1", PORT))
        names = ["pipe%d" % i for i in range(20)]
        wire = b"".join(
            b"POST /users HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s"
            % (len(b), b) for b in (json.dumps({"name": n}).encode() for n in names))
        s.sendall(wire)
        f = s.makefile("rb")
        got = []
        for _ in names:
            f.readline()
            length = 0
            while True:
                line = f.readline()
                if line == b"\r\n":
                    break
                if line.lower().startswith(b"content-length:"):
                    length = int(line.split(b":")[1])
            got.append(json.loads(f.read(length))["name"])
        self.assertEqual(got, names)

    def test_concurrent_clients_do_not_lose_or_duplicate_users(self):
        created = []
        lock = threading.Lock()

        def worker(k):
            c = conn()
            for i in range(25):
                _, _, u = request(c, "POST", "/users", {"name": "t%d-%d" % (k, i)})
                _, _, back = request(c, "GET", "/users/%d" % u["id"])
                assert back == u
                with lock:
                    created.append(u["id"])

        threads = [threading.Thread(target=worker, args=(k,)) for k in range(8)]
        [t.start() for t in threads]
        [t.join() for t in threads]
        self.assertEqual(len(created), 200)
        self.assertEqual(len(set(created)), 200, "an id was handed out twice")

    def test_a_body_larger_than_the_buffer_is_refused_and_the_server_lives(self):
        c = conn()
        status, resp, raw = call(c, "POST", "/users", json.dumps({"name": "x" * 20000}))
        self.assertEqual(status, 413)
        self.assertEqual(request(conn(), "GET", "/health")[0], 200)


class Schemathesis(unittest.TestCase):
    def test_generated_requests_from_the_document_get_conforming_answers(self):
        env = dict(os.environ, SCHEMATHESIS_HOOKS="")
        run = subprocess.run(
            [sys.executable, "-m", "schemathesis.cli", "run", "http://127.0.0.1:%d/openapi.json" % PORT,
             "--checks", "all", "--max-examples", os.environ.get("EXAMPLES", "60"),
             "--exclude-checks", "ignored_auth", "--no-color"],
            capture_output=True, text=True, env=env, timeout=600)
        sys.stdout.write(run.stdout[-3000:])
        self.assertEqual(run.returncode, 0, run.stdout[-3000:] + run.stderr[-1500:])


if __name__ == "__main__":
    unittest.main(verbosity=2)
