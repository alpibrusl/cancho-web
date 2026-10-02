#!/usr/bin/env python3
"""Check that two servers do the same work before their speeds are compared.

    python3 benches/equivalent.py <port-a> <port-b>

Both must be freshly started (empty). The same requests go to each; the status codes
must match, and the JSON bodies of the successful ones must be equal (the `id` of a
created user is the same, 1, on both). Error *documents* differ by design and are not
compared, only their status.
"""
import http.client
import json
import sys


def call(port, method, path, body=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    c.request(method, path, body=body, headers={"Content-Type": "application/json"} if body else {})
    r = c.getresponse()
    raw = r.read()
    return r.status, (json.loads(raw) if raw and r.getheader("Content-Type", "").startswith("application/") else raw)


CASES = [
    ("POST", "/users", json.dumps({"name": "Ada", "email": "ada@example.org", "age": 36, "role": "admin", "tags": ["x", "y"]})),
    ("POST", "/users", json.dumps({"name": "Bo"})),
    ("GET", "/users/1", None),
    ("GET", "/users/2", None),
    ("GET", "/users/3", None),
    ("GET", "/users?limit=1", None),
    ("GET", "/users?limit=20", None),
    ("GET", "/users?limit=0", None),
    ("GET", "/users?limit=101", None),
    ("POST", "/users", json.dumps({"name": ""})),
    ("POST", "/users", json.dumps({"name": "x", "extra": 1})),
    ("POST", "/users", json.dumps({"name": "x", "age": 151})),
    ("POST", "/users", json.dumps({"name": "x", "role": "root"})),
    ("POST", "/users", json.dumps({"name": "x", "tags": ["t"] * 9})),
    ("POST", "/users", json.dumps({"age": 3})),
    ("GET", "/health", None),
]
a, b = int(sys.argv[1]), int(sys.argv[2])
bad = 0
for method, path, body in CASES:
    sa, ba = call(a, method, path, body)
    sb, bb = call(b, method, path, body)
    ok = sa == sb and (sa >= 400 or ba == bb)
    if not ok:
        bad += 1
    print("%-4s %-18s %s %s  %s" % (method, path, sa, sb, "ok" if ok else "DIFFERENT: %r vs %r" % (ba, bb)))
print("equivalent" if not bad else "%d DIFFER" % bad)
sys.exit(1 if bad else 0)
