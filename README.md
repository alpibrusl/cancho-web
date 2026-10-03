# lexsys-web

[![ci](https://github.com/alpibrusl/lexsys-web/actions/workflows/ci.yml/badge.svg)](https://github.com/alpibrusl/lexsys-web/actions/workflows/ci.yml)

A web layer for [lex-sys](https://github.com/alpibrusl/lex-sys), a typed systems language
with linear ownership and capability effects: routes with typed parameters, request bodies
validated by [`lexsys-schema`](https://github.com/alpibrusl/lexsys-schema), `problem+json`
errors, and an OpenAPI document generated from the same declarations -- on top of the
`http.server` package that `lex-sys` ships (`packages/http-server/`).

One thread, a `Poller`, no `Ffi`, no `extern fn`: the compiled server's authority report
names exactly what it can do, and C is not on the list.

## Status

**The declaration half of the framework is built.**
[`examples/users`](examples/users/users.ls) is a CRUD JSON API over `http.server` and
`lexsys-schema`, held to its own OpenAPI document by an end-to-end test over real sockets
and by Schemathesis, and benchmarked against FastAPI, Go and C ([below](#benchmarks)).
[`src/web.ls`](src/web.ls) declares each operation once -- its route, parameters, body and
responses -- and the router and the OpenAPI document both come from that declaration
(the document is checked in as [`examples/users/openapi.json`](examples/users/openapi.json),
so a change to the API is a change to a file). Not yet: dispatch -- the handler is still an
`if` on the route id and still checks its own path and query parameters -- and middleware
([`docs/design.md`](docs/design.md) §8 says what is next and why).

## Requirements

- The **lex-sys** compiler and checkouts of **lexsys-schema** (and, for the PostgreSQL example, **lexsys-pg**), at the revisions
  this repository's CI builds with (below). A package store records no hash of the `std` it was published with, so the compiler
  revision is part of the contract.
- Rust, to build that compiler (its `rust-toolchain.toml` pins the toolchain).
- To run the tests: `python3` and `pip install jsonschema openapi-spec-validator schemathesis`.

## Quick start

**1. Get the compiler and the two packages**, at the revisions CI builds and tests against (read from `ci.yml`, so this text
cannot drift from it):

```
git clone https://github.com/alpibrusl/lex-sys
git clone https://github.com/alpibrusl/lexsys-schema
git clone https://github.com/alpibrusl/lexsys-web && cd lexsys-web
pin() { sed -n "s/^ *$1: *//p" .github/workflows/ci.yml; }
(cd ../lex-sys && git checkout "$(pin LEX_SYS_REV)" && cargo build --release -p lex-sys)
(cd ../lexsys-schema && git checkout "$(pin SCHEMA_REV)")
export LEX_SYS=$PWD/../lex-sys/target/release/lex-sys
```

**2. Build and run the example** (the two packages are fetched and verified against
`deps/*.lock` -- by hash -- every time, never taken from a copy checked in here):

```
scripts/build.sh examples/users/users.ls build/users
build/users 8080 &
```

**3. Use it:**

```
$ curl -s -XPOST -H 'Content-Type: application/json' -d '{"name":"Ada","age":36}' localhost:8080/users
{"id":1,"name":"Ada","age":36}

$ curl -s -XPOST -H 'Content-Type: application/json' -d '{"name":"","age":151}' localhost:8080/users
{"type":"about:blank","title":"Unprocessable Content","status":422,"count":2,"errors":[{"pointer":"/name","code":"min_length","detail":"is too short"},{"pointer":"/age","code":"maximum","detail":"is above the maximum"}]}

$ curl -s 'localhost:8080/users?limit=5'
{"total":1,"items":[{"id":1,"name":"Ada","age":36}]}

$ curl -s localhost:8080/openapi.json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["openapi"], sorted(d["paths"]))'
3.1.0 ['/health', '/users', '/users/{id}']
```

Every error at once, each with its JSON Pointer, as RFC 9457 `problem+json`; and an OpenAPI
3.1 document generated from the same schema nodes the validator runs. [A session](#a-session)
below has the rest (`Location`, `204`, `404`, `415`, paging).

**4. Check it works on your machine:**

```
pip install jsonschema openapi-spec-validator schemathesis
python3 tests/e2e.py            # 27 tests over real sockets, Schemathesis included, ~25 s
benches/check.sh                # the Go and C comparison servers still do the same work
```

`scripts/build.sh` looks for `lex-sys` on `PATH` (or `LEX_SYS=`) and for the checkouts at
`../lex-sys` and `../lexsys-schema` (or `LEX_SYS_DIR=`, `SCHEMA_DIR=`), which is why step 1
clones them beside this one.

## Examples

Three runnable services, all held to their own OpenAPI document by the end-to-end tests: `examples/users` (the CRUD API below),
`examples/users_pg` (the same API on PostgreSQL) and `examples/users_threads` (the same loop in two threads of one process).

### A session

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

#### The same API on PostgreSQL

[`examples/users_pg`](examples/users_pg/users_pg.ls) is this service with a table behind it: the same routes,
the same schema nodes, the same OpenAPI document (plus a `pattern` on `name` and `email`, which refuse
U+0000 because PostgreSQL text cannot hold it) and the same answers, byte for byte, and the end-to-end suite,
Schemathesis included, runs against it unchanged (`USERS_PG=1 python3 tests/e2e.py`). It reaches the
database through functions that `pgen` (in [`lexsys-pg`](https://github.com/alpibrusl/lexsys-pg)) wrote from
[`queries.sql`](examples/users_pg/queries.sql) by asking the server what each statement's parameters and
columns are, and through `lexsys-pg`'s driver, so `lex-sys authority` on it names the network, one random-file
read for the login, and nothing foreign.

```
createdb users_pg && psql users_pg -f examples/users_pg/schema.sql
scripts/build.sh examples/users_pg/users_pg.ls build/users_pg
build/users_pg 8080 127.0.0.1 5432 postgres users_pg -         # <port> <db host> <db port> <db user> <db> <password|->
```

By default it holds one connection and each request that needs the database blocks the loop for a round trip.
Each query is prepared once at start-up (`queries.prepare_all`). Measured
([`docs/benchmarks.md`](docs/benchmarks.md#on-postgresql)): a read is 14,976 requests a second, 5.1x lean
FastAPI + asyncpg and 13.9x FastAPI + SQLAlchemy -- the rest is PostgreSQL waiting while the one loop works.
Give it an eighth argument (`reuseport`, or `-` for none) and a ninth, a number of connections, and it stops
waiting:

```
build/users_pg 8080 127.0.0.1 5432 postgres users_pg - - 4     # ... <password|-> <reuseport|-> <connections>
```

A request that needs the database is held, its query is queued on a `pg.pool` of that many connections, and the
loop goes on; the answer is sent when it arrives. `GET /health` stays under a millisecond while a query waits a
second on a lock (the blocking service: 645 ms), and in one process on one core a read reaches about 64,000 a
second with one connection (the blocking service: 15,638; three copies: 25,180) and a create 8,091 with four
(four blocking copies: 5,818; the ranges overlap) --
[`docs/benchmarks.md`](docs/benchmarks.md#a-pool-in-one-process) has the setup, the ranges and what it does not
do. The same 29 tests pass against both, plus 6 for the pool (`USERS_PG_POOL=2 USERS_PG=1 python3 tests/e2e.py`).

## Usage

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

Each operation is declared once with `web` (`setup`): the route, its parameters, its body and its
responses. The router answers the id that `handle` tests, and the OpenAPI document is generated from
the same declaration, so a route cannot be served and undocumented:

```
let (a4, op_get) = web.operation(heap, api, "GET", "/users/:id", "getUser");
api = web.path_param(heap, a4, op_get, "id", path_id);              // path_id: a schema node, 1..
api = web.respond(heap, api, op_get, 200, "the user", user);
api = web.respond_problem(heap, api, op_get, 404);
api = web.respond_problem(heap, api, op_get, 422);
...
let id = web.find(api, http.method(request, table), path, params);   // in handle
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
python3 tests/e2e.py              # 27 tests; builds first       (pip install jsonschema openapi-spec-validator schemathesis)
EXAMPLES=500 python3 tests/e2e.py # more generated requests
```

The real binary on a real socket, a real HTTP client, and:

* **the contract:** every response any test sees must be one the served OpenAPI
  document declares, with a body that validates against the schema it declares;
* **the document itself** validates as OpenAPI 3.1, and is byte-for-byte the checked-in
  `examples/users/openapi.json`;
* **Schemathesis** generates requests from the document (positive and negative
  cases, stateful scenarios) and checks what comes back: 8,447 cases in the last
  500-example run, none failing;
* pipelining, keep-alive, 8 concurrent clients, an oversized body, and the
  validation edge cases (every error with its pointer, no coercion, `150.0`).

```
lex-sys test tests/web_test.ls src/web.ls build/deps/*.ls --std   # `web` unit tests (after a build has fetched build/deps)
benches/check.sh                  # the Go and C implementations still do the same work (seconds)
```

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) builds the pinned compiler and
runs the end-to-end tests, Schemathesis included, and `benches/check.sh` on every push.

## Benchmarks

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
src/web.ls                the declaration layer: operations, parameters, bodies, responses -> router + OpenAPI
examples/users/users.ls   the service: schemas, the declared API, handlers, store, the loop
examples/users/openapi.json  the contract as a file, checked against what the service serves
scripts/build.sh          fetch + verify the locked packages, then build
deps/*.lock               the packages this builds against, pinned by hash
tests/e2e.py              the end-to-end tests (real binary, real sockets, Schemathesis)
tests/web_test.ls         unit tests of `web`: documents derived by hand, compared byte for byte
benches/                  the benchmark: the FastAPI, Go and C implementations of the same
                          API, the load generator, and the checks that they do the same work
docs/design.md            what the framework layer will be, and what building the example found
docs/benchmarks.md        the method, the numbers, and how to read them
```

## Limitations

Not yet built:

Dispatch and parameter validation by construction (a path or query parameter that fails its
schema is still a check the handler makes); middleware, auth, and anything like FastAPI's
dependency injection; TLS; streaming bodies; more than one core; `$ref`/`$defs` in the generated
JSON Schema. The design document says which of these are decided and which are open.

## Documentation

- [`docs/design.md`](docs/design.md): what the framework layer will be, and what building the example found.
- [`docs/benchmarks.md`](docs/benchmarks.md): the method, the numbers, and how to read them.

## Contributing

Every change goes through what CI runs: the end-to-end tests (Schemathesis included) and `benches/check.sh`. Design before code, in
`docs/`, with claims measured; a claim that turns out false is corrected in place.

## Licence

[EUPL-1.2](LICENSE).
