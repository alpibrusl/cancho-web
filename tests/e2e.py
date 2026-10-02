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
    if not content:
        # A response the document declares with no body (the `204`): no body, and
        # no `Content-Length` or `Content-Type` either (RFC 9110 section 15.3.5).
        assert raw == b"", "%s %s %d declares no body but sent %r" % (method, path, status, raw[:60])
        assert resp.getheader("Content-Length") is None and resp.getheader("Content-Type") is None
        return
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
    def test_the_served_document_is_the_checked_in_one(self):
        # `examples/users/openapi.json` is the API's contract as a file: a change to
        # the declared routes, parameters, bodies or schemas changes this file, so the
        # change shows in review. Regenerate it with `build/users 8080 & curl -s
        # localhost:8080/openapi.json > examples/users/openapi.json`.
        status, _, raw = get("/openapi.json")
        self.assertEqual(status, 200)
        with open(os.path.join(ROOT, "examples", "users", "openapi.json"), "rb") as f:
            self.assertEqual(raw, f.read())

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
        status, _, body = request(c, "DELETE", "/users/%d" % user["id"])
        self.assertEqual((status, body), (204, None))
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

    def test_a_page_is_the_users_as_answered_one_by_one(self):
        # The page is spliced from stored bytes, not rendered again, so it must be
        # exactly the answers of `GET /users/:id` joined -- whatever the stored users
        # look like, with holes left by deletes, with an offset, and past the 4 KB a
        # naive client buffer holds.
        c = conn()
        made = []
        for i in range(30):
            body = {"name": "n\u00e9 %d \"q\" \\ \U0001F600" % i}
            if i % 2:
                body["email"] = "e%d@example.org" % i
            if i % 3 == 0:
                body["age"] = i
            if i % 4 == 0:
                body["role"] = ["admin", "user", "guest"][i % 3]
            if i % 5 == 0:
                body["tags"] = ["t%d" % j for j in range(i % 8)]
            made.append(request(c, "POST", "/users", body)[2]["id"])
        for gone in (made[3], made[10], made[11]):
            self.assertEqual(call(c, "DELETE", "/users/%d" % gone)[0], 204)
        for query in ("limit=100", "limit=7&offset=3", "limit=100&offset=5", "limit=1"):
            status, _, raw = call(c, "GET", "/users?" + query)
            self.assertEqual(status, 200)
            page = json.loads(raw)
            singles = [call(c, "GET", "/users/%d" % u["id"])[2] for u in page["items"]]
            self.assertEqual(raw, b'{"total":%d,"items":[' % page["total"] + b",".join(singles) + b"]}", query)
        for i in range(100):
            request(c, "POST", "/users", {"name": "padding-%03d-%s" % (i, "x" * 40)})
        total = json.loads(call(c, "GET", "/users?limit=1")[2])["total"]
        raw = call(c, "GET", "/users?limit=100&offset=%d" % (total - 100))[2]  # the padding users
        self.assertGreater(len(raw), 4096)
        self.assertEqual(len(json.loads(raw)["items"]), 100)

    def test_a_deleted_user_leaves_the_listing_and_the_total(self):
        c = conn()
        a = request(c, "POST", "/users", {"name": "gone"})[2]["id"]
        before = request(c, "GET", "/users?limit=1")[2]["total"]
        request(c, "DELETE", "/users/%d" % a)
        self.assertEqual(request(c, "GET", "/users?limit=1")[2]["total"], before - 1)


class Frames(unittest.TestCase):
    def test_a_204_is_framed_by_its_blank_line_not_a_length(self):
        # No Content-Length on a 204: the next answer on the connection starts at
        # the blank line. Two DELETEs and a GET, pipelined, answered in order.
        c = conn()
        a = request(c, "POST", "/users", {"name": "d1"})[2]["id"]
        b = request(c, "POST", "/users", {"name": "d2"})[2]["id"]
        s = socket.create_connection(("127.0.0.1", PORT))
        s.sendall(("DELETE /users/%d HTTP/1.1\r\nHost: t\r\n\r\nDELETE /users/%d HTTP/1.1\r\nHost: t\r\n\r\n"
                   "GET /health HTTP/1.1\r\nHost: t\r\n\r\n" % (a, b)).encode())
        got = b""
        while got.count(b"\r\n\r\n") < 3 or not got.endswith(b'{"ok":true}'):
            chunk = s.recv(4096)
            assert chunk, got
            got += chunk
        s.close()
        self.assertEqual(got.split(b"\r\n\r\n")[0], b"HTTP/1.1 204 No Content\r\nConnection: keep-alive")
        self.assertEqual(got.count(b"204 No Content"), 2)
        self.assertNotIn(b"Content-Length: 0", got.split(b"HTTP/1.1 200")[0])


class Growth(unittest.TestCase):
    def test_the_store_grows_past_what_the_old_fixed_arena_held(self):
        # The first version kept 10,000 users in a fixed 4 MiB arena. Twelve
        # thousand users of about 400 bytes is 4.8 MB: the store has to grow.
        c = conn()
        base = request(c, "GET", "/users?limit=1")[2]["total"]
        user = {"name": "n" * 64, "email": "e" * 100 + "@x.io", "age": 40, "role": "user", "tags": ["t" * 16] * 8}
        last = None
        for i in range(12000):
            status, _, last = request(c, "POST", "/users", user)
            self.assertEqual(status, 201, i)
        self.assertEqual(request(c, "GET", "/users?limit=1")[2]["total"], base + 12000)
        self.assertEqual(request(c, "GET", "/users/%d" % last["id"])[2], last)
        first = request(c, "GET", "/users?limit=1&offset=%d" % (base + 11999))[2]["items"]
        self.assertEqual(first[0]["id"], last["id"])


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
