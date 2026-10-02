#!/usr/bin/env python3
"""Edge cases where a hand-written validator is likely to differ from a reference.

    python3 benches/edges.py <reference-port> <port> [<port> ...]

Each must be freshly started. `equivalent.py` is the gate the benchmark runs; this is
the wider net used while writing the Go and C servers (the lex-sys service is the
reference): code-point lengths with escapes and astral characters, both ends of every
range, duplicate keys, whitespace, bodies that are not objects, malformed JSON, the
content type, and query strings. Statuses must match and successful bodies must be equal.

Not compared, because the servers are known to differ (see the header of each): `150.0`
whole floats, `null` fields, invalid UTF-8, differently-cased keys. Two more are run
last and only shown: a repeated key (the lex-sys service keeps the first, the others the
last) and a lone surrogate escape (the lex-sys service answers 400).
"""
import http.client
import json
import sys


def call(port, method, path, body=None, ctype="application/json"):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    h = {"Content-Type": ctype} if (body is not None and ctype) else {}
    c.request(method, path, body=body.encode() if isinstance(body, str) else body, headers=h)
    r = c.getresponse()
    raw = r.read()
    ok_json = r.getheader("Content-Type", "").startswith("application/json")
    return r.status, (json.loads(raw) if raw and ok_json else None)


def post(obj):
    return ("POST", "/users", obj if isinstance(obj, str) else json.dumps(obj))


A = "\U0001F600"  # one code point, four bytes, two surrogates in JSON escapes
CASES = [
    post({"name": "n"}),
    post({"name": "x" * 64}),
    post({"name": "x" * 65}),
    post({"name": A * 64}),
    post({"name": A * 65}),
    post('{"name":"\\ud83d\\ude00\\ud83d\\ude00"}'),
    post('{"name":"caf\\u00e9 \\"q\\" \\\\ \\n\\t"}'),
    post('{"name":"' + "\\u00e9" * 64 + '"}'),
    post('{"name":"' + "\\u00e9" * 65 + '"}'),
    post({"name": "é" * 64}),
    post({"name": "é" * 65}),
    post({"name": "ok", "email": "ab"}),
    post({"name": "ok", "email": "abc"}),
    post({"name": "ok", "email": "e" * 120}),
    post({"name": "ok", "email": "e" * 121}),
    post({"name": "ok", "age": 0}),
    post({"name": "ok", "age": 150}),
    post({"name": "ok", "age": 151}),
    post({"name": "ok", "age": -1}),
    post({"name": "ok", "age": "3"}),
    post({"name": "ok", "age": 1.5}),
    post({"name": "ok", "age": True}),
    post({"name": "ok", "role": "admin"}),
    post({"name": "ok", "role": "guest"}),
    post({"name": "ok", "role": "Admin"}),
    post({"name": "ok", "role": 1}),
    post({"name": "ok", "tags": []}),
    post({"name": "ok", "tags": ["t" * 16]}),
    post({"name": "ok", "tags": ["t" * 17]}),
    post({"name": "ok", "tags": [""]}),
    post({"name": "ok", "tags": ["a"] * 8}),
    post({"name": "ok", "tags": ["a"] * 9}),
    post({"name": "ok", "tags": [1]}),
    post({"name": "ok", "tags": "a"}),
    post({"name": "ok", "tags": [A * 16]}),
    post({"name": "ok", "tags": [A * 17]}),
    post({"name": 1}),
    post({"name": ["a"]}),
    post({"name": {"a": 1}}),
    post({"name": "a", "name2": 1}),
    post(' \n{ "name" : "spaced" , "age" : 7 ,\t"tags":[ "a" , "b" ] }\r\n'),
    post('{"name":"a","tags":[]}'),
    post("{}"),
    post("[]"),
    post("[1,2]"),
    post('"x"'),
    post("7"),
    post("true"),
    post(""),
    post("{"),
    post('{"name":'),
    post('{"name":"a"'),
    post('{"name":"a",}'),
    post('{"name":"a"} x'),
    post('{"name":"a"}{"name":"b"}'),
    post('{"name":"a\nb"}'),
    post('{"name":"a\\x"}'),
    post('{"name":"a","age":-}'),
    post('{"name":"a","tags":["a",]}'),
    ("POST", "/users", '{"name":"typed"}', "text/plain"),
    ("POST", "/users", '{"name":"typed"}', "application/json; charset=utf-8"),
    ("POST", "/users", '{"name":"typed"}', "Application/JSON"),
    ("GET", "/users?limit=1&offset=1", None),
    ("GET", "/users?offset=1", None),
    ("GET", "/users?offset=0&limit=100", None),
    ("GET", "/users?offset=999", None),
    ("GET", "/users?limit=abc", None),
    ("GET", "/users?limit=", None),
    ("GET", "/users?limit=-1", None),
    ("GET", "/users?offset=-1", None),
    ("GET", "/users?limit=5&bogus=1", None),
    ("GET", "/users?bogus", None),
    ("GET", "/users/0", None),
    ("GET", "/users/abc", None),
    ("GET", "/users/-1", None),
    ("GET", "/users/99999999999999999999", None),
    ("GET", "/users/1", None),
    ("DELETE", "/users/2", None),
    ("GET", "/users/2", None),
    ("DELETE", "/users/2", None),
    ("GET", "/users?limit=100", None),
    ("GET", "/users", None),
    ("GET", "/health", None),
    ("GET", "/nothing", None),
]
KNOWN = [post('{"name":"first","name":"second"}'), post('{"name":"\\ud83d"}')]
ref, others = int(sys.argv[1]), [int(p) for p in sys.argv[2:]]
bad = 0
for case in CASES:
    method, path, body = case[:3]
    ctype = case[3] if len(case) > 3 else "application/json"
    sr, br = call(ref, method, path, body, ctype)
    results = [call(p, method, path, body, ctype) for p in others]
    ok = [s == sr and (sr >= 400 or b == br) for s, b in results]
    if not all(ok):
        bad += 1
        shown = (body if isinstance(body, str) else str(body))[:50]
        print("DIFFERENT %-6s %-26s %-50r ref=%s others=%s" % (method, path, shown, sr, [s for s, _ in results]))
        for (s, b), good in zip(results, ok):
            if not good and s < 400 and sr < 400:
                print("    ref  ", str(br)[:160], "\n    other", str(b)[:160])
for method, path, body in KNOWN:
    print("known difference  %-50r %s" % (body[:50], [call(p, method, path, body)[0] for p in [ref] + others]))
print("%d cases, %d servers: %s" % (len(CASES), len(others), "all agree" if not bad else "%d DIFFER" % bad))
sys.exit(1 if bad else 0)
