# lexsys-web

A web layer for [lex-sys](https://github.com/alpibrusl/lex-sys), a typed systems language
with linear ownership and capability effects: routes with typed parameters, request bodies
validated by [`lexsys-schema`](https://github.com/alpibrusl/lexsys-schema), `problem+json`
errors, and an OpenAPI document generated from the same declarations -- on top of the
`http.server` package that `lex-sys` ships (`packages/http-server/`).

One thread, a `Poller`, no `Ffi`, no `extern fn`: the compiled server's authority report
names exactly what it can do, and C is not on the list.

> **Status: one real example built, the framework not extracted.**
> [`examples/users`](examples/users/users.ls) is a CRUD JSON API over `http.server` and
> `lexsys-schema`, held to its own OpenAPI document by an end-to-end test over real sockets
> and by Schemathesis, and benchmarked against FastAPI, Go and C
> ([below](#measured)). What a user writes today is that file: the routes are a table of
> ids and the dispatch is an `if` chain, which is more ceremony than FastAPI's decorators.
> Extracting the layer that removes it is what [`docs/design.md`](docs/design.md) plans, and
> the example is what it will be extracted *from*.

## Try it

You need the `lex-sys` compiler (Rust; the toolchain is pinned by its `rust-toolchain.toml`)
and this repository's two packages checked out beside it:

```
git clone https://github.com/alpibrusl/lex-sys
git clone https://github.com/alpibrusl/lexsys-schema
git clone https://github.com/alpibrusl/lexsys-web && cd lexsys-web
(cd ../lex-sys && git checkout 232a59c8451aa7df0b72ab0d0ee053b26a951e86 && cargo build --release -p lex-sys)
export LEX_SYS=$PWD/../lex-sys/target/release/lex-sys

scripts/build.sh examples/users/users.ls build/users      # fetches + verifies both packages
build/users 8080
```

(`232a59c` is the revision CI builds and tests against: a package store records no hash of the
`std` it was published with, so the compiler version is part of the contract.)
`scripts/build.sh` looks for `lex-sys` on `PATH` (or `LEX_SYS=`) and for the checkouts at
`../lex-sys` and `../lexsys-schema` (or `LEX_SYS_DIR=`, `SCHEMA_DIR=`). `deps/*.lock` pin the
packages by hash; `vcs fetch` refuses a store that no longer matches.

## A session

Every response below is real output of the built service.

```
$ curl -i -XPOST -H 'Content-Type: application/json' \
       -d '{"name":"Ada Lovelace","email":"ada@example.org","age":36,"role":"admin","tags":["math","code"]}' \
       localhost:8080/users
HTTP/1.1 201 Created
Content-Type: application/json
Content-Length: 103
Connection: keep-alive
Location: /users/1

{"id":1,"name":"Ada Lovelace","email":"ada@example.org","age":36,"role":"admin","tags":["math","code"]}
```

A body that breaks the rules gets **every** error, with where it is, as RFC 9457
`application/problem+json`:

```
$ curl -i -XPOST -H 'Content-Type: application/json' -d '{"name":"","age":151,"role":"root","nope":1}' localhost:8080/users
HTTP/1.1 422 Unprocessable Content
Content-Type: application/problem+json
Content-Length: 369

{"type":"about:blank","title":"Unprocessable Content","status":422,"count":4,"errors":[{"pointer":"/name","code":"min_length","detail":"is too short"},{"pointer":"/age","code":"maximum","detail":"is above the maximum"},{"pointer":"/role","code":"choice","detail":"is not one of the allowed values"},{"pointer":"/nope","code":"unknown","detail":"is not a known field"}]}
```

```
$ curl 'localhost:8080/users?limit=1&offset=1'
{"total":2,"items":[{"id":2,"name":"Grace"}]}

$ curl -i -XDELETE localhost:8080/users/2
HTTP/1.1 204 No Content
Connection: keep-alive

$ curl -i localhost:8080/users/2
HTTP/1.1 404 Not Found
Content-Type: application/problem+json

{"type":"about:blank","title":"Not Found","status":404,"detail":"no such user"}

$ curl -i 'localhost:8080/users?limit=0'
HTTP/1.1 422 Unprocessable Content

{"type":"about:blank","title":"Unprocessable Content","status":422,"detail":"limit must be an integer from 1 to 100"}
```

| | |
|---|---|
| `GET /health` | `{"ok":true}` |
| `GET /users?limit=&offset=` | a page (`limit` 1..100, default 20); an unknown query key is a 422 |
| `POST /users` | create: 201 and `Location`; 400 for malformed JSON, 415 for another content type, 422 for a body that breaks the schema |
| `GET /users/:id`, `DELETE /users/:id` | the user / 204; 404 if there is none; 422 for an `id` that is not a positive integer |
| `GET /openapi.json` | the contract (OpenAPI 3.1: `NewUser`, `User`, `Page`, `Problem`), generated from the same schema nodes the validator runs |

Storage is in memory, up to 100,000 users or 64 MiB (past that a `POST` is a 503); a delete
leaves a hole, ids are not reused.

## How it is written

The shape is declared once, as data (`setup` in [`users.ls`](examples/users/users.ls)); the
same nodes validate a body *and* appear in `/openapi.json`:

```
var s = schema.empty(heap);
let (s1, name)  = schema.new_string(heap, s, 1, 64);
let (s2, email) = schema.new_string(heap, s1, 3, 120);
let (s3, age)   = schema.new_int(heap, s2, 0, 150);
...
let (s7, new_user) = schema.new_object(heap, s6, true);       // true: unknown keys are refused
s = user_fields(heap, s7, new_user, 0 - 1, name, email, age, role, tags);
```

The routes are a table, and a request is looked up in it (`routes`, `handle`):

```
r = route.add(heap, r, "GET",    "/users/:id", 4);
r = route.add(heap, r, "DELETE", "/users/:id", 5);
...
let id = route.find(router, http.method(request, table), path, params);
if id == 3 { return create(heap, sc, new_user, store, request, table, body, out, keep); }
```

The loop is the application's own: `wait` does the I/O once, `next` hands over one parsed
request, the handler builds its answer, `respond` sends it. That inversion (instead of a
callback) is forced by the region system -- `lex-sys`'s `docs/http-server.md` §2 -- and is why
a handler's request is a borrowed view of the loop's buffers, copied nowhere.

```
// the shape of `run`, with the borrows left out (the real one is 40 lines)
while true {
    srv = server.wait(heap, srv, clock, listener, 1000);       // I/O, once
    while server.next(heap, srv) >= 0 {                        // a request is in hand
        ...                                                    // route, validate, answer
        server.respond(srv, answer);
    }
}
```

`lex-sys authority` on the built service reports `args`, `clock`, `conn_*`, `heap`, `net_in`,
`poll` and the console's error stream -- **no `ffi`, no filesystem**.

## Tests

```
python3 tests/e2e.py              # 25 tests; builds first       (pip install jsonschema openapi-spec-validator schemathesis)
EXAMPLES=500 python3 tests/e2e.py # more generated requests
```

The real binary on a real socket, a real HTTP client, and:

* **the contract:** every response any test sees must be one the served OpenAPI
  document declares, with a body that validates against the schema it declares;
* **the document itself** validates as OpenAPI 3.1;
* **Schemathesis** generates requests from the document (positive and negative
  cases, stateful scenarios) and checks what comes back: 8,447 cases in the last
  500-example run, none failing;
* pipelining, keep-alive, 8 concurrent clients, an oversized body, and the
  validation edge cases (every error with its pointer, no coercion, `150.0`).

```
benches/check.sh                  # the Go and C implementations still do the same work (seconds)
```

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) builds the pinned compiler and
runs the end-to-end tests, Schemathesis included, and `benches/check.sh` on every push.

## Measured

On one core each, every implementation checked to do the same work first
([`docs/benchmarks.md`](docs/benchmarks.md) has the tables, the method, and what each
comparison does and does not show):

| requests a second | GET one | page of 20 | rejected body | create |
|---|---:|---:|---:|---:|
| **lex-sys** | **128,972** | **70,768** | **94,659** | **64,327** |
| Go `net/http` | 79,772 | 65,654 | 60,278 | 53,580 |
| hand-written C (epoll) | 117,958 | 105,523 | 107,680 | 91,783 |
| FastAPI (best set-up) | 5,216 | 4,604 | 3,606 | 4,163 |

* against **FastAPI**: about 15-26x, and a p99 of 0.44 ms against 12 ms;
* against **Go's `net/http`**: 1.1-1.6x ahead, with half the p99;
* against the **hand-written C server**: level on a read, 12-33% behind on the rest, and 94% of
  the most one core can do over loopback TCP (a server that answers one canned reply).

One 4-vCPU VM, one run; repeats differ by about 5% (a create by up to 10%). The page endpoint
was 40,755 in the first comparison: the comparison is what found the two causes, one in the
example and one in lex-sys's `std.buffer`, both fixed.

## Layout

```
examples/users/users.ls   the service: schema, routes, handlers, store, the loop
scripts/build.sh          fetch + verify the locked packages, then build
deps/*.lock               the packages this builds against, pinned by hash
tests/e2e.py              the end-to-end tests (real binary, real sockets, Schemathesis)
benches/                  the benchmark: the FastAPI, Go and C implementations of the same
                          API, the load generator, and the checks that they do the same work
docs/design.md            what the framework layer will be, and what building the example found
docs/benchmarks.md        the method, the numbers, and how to read them
```

## Not yet

The framework layer (declare a route with its schema and get the dispatch, validation and
documentation from one place); middleware, auth, and anything like FastAPI's dependency
injection; TLS; streaming bodies; more than one core; `$ref`/`$defs` in the generated schema.
The design document says which of these are decided and which are open.

## Licence

[EUPL-1.2](LICENSE).
