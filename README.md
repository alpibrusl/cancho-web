<p align="center"><img src="docs/logo.png" alt="cancho-web" width="220"></p>

# cancho-web

[![ci](https://github.com/alpibrusl/cancho-web/actions/workflows/ci.yml/badge.svg)](https://github.com/alpibrusl/cancho-web/actions/workflows/ci.yml)

**Declare the API once.** cancho-web makes the API boundary a checked artifact of the program: one declaration defines the route, checks its inputs, generates the OpenAPI document, and is what CI tests. A web layer for [cancho](https://github.com/alpibrusl/cancho), a typed systems language
with linear ownership and capability effects: routes with typed parameters, request bodies validated by
[`cancho-schema`](https://github.com/alpibrusl/cancho-schema), `problem+json` errors, and an OpenAPI document generated from
the same declarations -- on top of the `http.server` package that `cancho` ships (`packages/http-server/`). The
[project page](https://alpibrusl.github.io/cancho-web/) has the pictures, [the examples](https://alpibrusl.github.io/cancho-web/examples.html)
and [the evidence](https://alpibrusl.github.io/cancho-web/evidence.html).

One thread, a `Poller`, no `Ffi`, no `extern fn`: the compiled server's authority report names exactly what it can do, and C is not on the list.

## Status

**Alpha. The declaration half of the framework is built.**
[`examples/users`](examples/users/users.cho) is a CRUD JSON API over `http.server` and
`cancho-schema`, held to its own OpenAPI document by an end-to-end test over real sockets
and by Schemathesis, and benchmarked against FastAPI, Go and C ([below](#benchmarks)).
[`src/web.cho`](src/web.cho) declares each operation once -- its route, parameters, body and
responses -- and the router and the OpenAPI document both come from that declaration
(the document is checked in as [`examples/users/openapi.json`](examples/users/openapi.json),
so a change to the API is a change to a file). `web.dispatch` judges a request's path, query and header parameters with the
schema nodes that document them *before* the handler runs, so the handler is not reached for a request that breaks the
contract (`examples/users` uses it; [`docs/design.md`](docs/design.md) §9). Not yet: middleware, and defaults declared
once ([`docs/design.md`](docs/design.md) §8 and §9.10 say what is next and why).

## What you get

* **One declaration.** An operation's route, parameters, body and responses are written once; the router and the OpenAPI 3.1 document are made from it, so a route cannot be served and undocumented.
* **Parameters judged before the handler.** `web.dispatch` checks every declared path, query and header parameter against its schema node, refuses an unknown or repeated query key, and answers the 404, the 405 or the 422 itself; the handler reads valid values from a slot table.
* **Every error at once.** A body that breaks the rules gets all of its errors, each with its JSON Pointer, as RFC 9457 `application/problem+json`. No coercion.
* **A contract that is a file.** The served document is byte for byte the checked-in `openapi.json`, and Schemathesis generates requests from it.
* **Who may call, declared.** Bearer schemes, `require` and `no_auth` are written to the document and can be read back; nothing here checks a token.
* **A package.** `web` is published as a store, so a project names it in `cancho.toml` instead of copying a file.
* **Fast, measured.** 14-18x FastAPI and 1.3-1.4x Go `net/http` on one core, 19-25x FastAPI's two workers on two; ahead of a hand-written C server on a read and a page, 6-11% behind it on the rest ([benchmarks](#benchmarks)).
* **PostgreSQL**, optionally, with a pool: the same API, the same tests, the same document.

## Requirements

- The **cancho** compiler and checkouts of **cancho-schema** (and, for the PostgreSQL example, **cancho-pg**), at the revisions
  this repository's CI builds with (below). A package store records no hash of the `std` it was published with, so the compiler
  revision is part of the contract.
- Rust, to build that compiler (its `rust-toolchain.toml` pins the toolchain).
- To run the tests: `python3` and `pip install jsonschema openapi-spec-validator schemathesis`.

## Quick start

**1. Get the compiler and the two packages**, at the revisions CI builds and tests against (read from `ci.yml`, so this text
cannot drift from it):

```
git clone https://github.com/alpibrusl/cancho
git clone https://github.com/alpibrusl/cancho-schema
git clone https://github.com/alpibrusl/cancho-web && cd cancho-web
pin() { sed -n "s/^ *$1: *//p" .github/workflows/ci.yml; }
(cd ../cancho && git checkout "$(pin CANCHO_REV)" && cargo build --release -p cancho)
(cd ../cancho-schema && git checkout "$(pin SCHEMA_REV)")
export CANCHO=$PWD/../cancho/target/release/cancho
```

**2. Build and run the example** (the two packages are fetched and verified against
`deps/*.lock` -- by hash -- every time, never taken from a copy checked in here):

```
scripts/build.sh examples/users/users.cho build/users
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

`scripts/build.sh` looks for `cancho` on `PATH` (or `CANCHO=`) and for the checkouts at
`../cancho` and `../cancho-schema` (or `CANCHO_DIR=`, `SCHEMA_DIR=`), which is why step 1
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
Content-Type: application/problem+json

{"type":"about:blank","title":"Unprocessable Content","status":422,"count":1,"errors":[{"pointer":"/query/limit","code":"minimum","detail":"is below the minimum"}]}
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

[`examples/users_pg`](examples/users_pg/users_pg.cho) is this service with a table behind it: the same routes,
the same schema nodes, the same OpenAPI document (plus a `pattern` on `name` and `email`, which refuse
U+0000 because PostgreSQL text cannot hold it) and the same answers, byte for byte (except the `422` for a bad parameter: `users_pg` has not been moved to `web.dispatch`), and the end-to-end suite,
Schemathesis included, runs against it unchanged (`USERS_PG=1 python3 tests/e2e.py`). It reaches the
database through functions that `pgen` (in [`cancho-pg`](https://github.com/alpibrusl/cancho-pg)) wrote from
[`queries.sql`](examples/users_pg/queries.sql) by asking the server what each statement's parameters and
columns are, and through `cancho-pg`'s driver, so `cancho authority` on it names the network, one random-file
read for the login, and nothing foreign.

```
createdb users_pg && psql users_pg -f examples/users_pg/schema.sql
scripts/build.sh examples/users_pg/users_pg.cho build/users_pg
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

The shape is declared once, as data (`setup` in [`users.cho`](examples/users/users.cho)); the
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
let (routed, id) = web.dispatch(heap, api, sc, request, table, params, args, scratch, out, keep);   // in handle
if id == web.answered() { return (routed, store); }       // the 404, 405 or 422 is already written
if id == 3 { return create(heap, sc, new_user, store, request, table, body, routed, keep); }
```

`dispatch` is called in the application's loop where `web.find` was; it is not a callback and keeps nothing. For a request that
has a route and valid parameters it answers the route id and fills `args`, two ints for each declared parameter, in the order
they were declared; the slots are learned once at start-up:

```
let limit_slot = web.slot(api, op_list, "limit");          // once, by name
...
if web.present(args, limit_slot) { limit = web.int_arg(args, limit_slot); }   // a valid int, 1..100: dispatch judged it
```

A parameter that breaks its node is a `422` that lists every error, with where it is (`/query/limit`, `/path/id`,
`/header/Idempotency-Key`) and a code a client can switch on (`type`, `range`, `minimum`, `maximum`, `min_length`,
`max_length`, `choice`, `required`, `unknown`, `duplicate`, `nul`). A path or query value is judged decoded (`%35` is `5`; in a
query `+` is a space); an integer is digits and nothing else (`5.0`, `+5` and `0x5` are `type`). `web.slot`, `web.most_args`,
`web.int_arg`, `web.bool_arg`, `web.present`, `web.text_start` and `web.text_end` are the accessors; `web.find` is
unchanged and `examples/users_pg` and `examples/users_threads` still use it.

Who may call an operation is declared the same way, and only the document is affected (the
application's own gate still decides): `web.bearer_scheme(heap, api, "admin", "the admin token")`,
then `web.require(heap, api, op, "admin")` once for each token that will do (alternatives),
`web.no_auth(heap, api, op)` for an open route, and `web.default_require` for the document's default.
An API whose errors are not `problem+json` names its error schema `Error` and answers with
`web.respond_error(heap, api, op, 404, "no such user")`.

What was declared can be asked back, so that a gate need not keep a second table: `web.requirements(api, op)` is how many alternatives
`op` has (its own `require` calls, else the document's default; 0 for an open operation, for one that does not exist, and for one about which
nothing was declared), `web.requirement(api, op, i)` the scheme of the `i`-th (an empty text beyond the last) and `web.is_open(api, op)` whether
it was declared `no_auth`. A caller needs one of the alternatives. Nothing here checks a token.

A request header is `web.header_param(heap, api, op, "Idempotency-Key", node, false)`; a plain-text answer is
`web.respond_text`; `web.optional_body` is a body that may be left out; words are `web.summary`, `web.describe` (an operation), `web.describe_param` (a parameter by
name) and `web.about` (the document). None of them changes what is routed.

`web` is also a package, so a project does not copy it: `scripts/publish.sh` writes the store
[`.cancho-vcs`](.cancho-vcs) from `src/web.cho`, with `cancho-schema` recorded as its requirement, and a project's
`cancho.toml` names it (`[dependencies.web]`, `git`, a `rev` that has the store, `path = ".cancho-vcs"`; the project
names `cancho-schema` too, to import it). CI checks that the committed store is what the source publishes
(`scripts/publish.sh --check`).

The loop is the application's own: `wait` does the I/O once, `next` hands over one parsed
request, the handler builds its answer, `respond` sends it. That inversion (instead of a
callback) is forced by the region system -- `cancho`'s `docs/http-server.md` §2 -- and is why
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

`cancho authority` on the built service reports `args`, `clock`, `conn_*`, `heap`, `net_in`,
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
cancho test tests/web_test.cho src/web.cho build/deps/*.cho --std   # `web` unit tests (after a build has fetched build/deps)
benches/check.sh                  # the Go and C implementations still do the same work (seconds)
scripts/check-authority.sh        # what the service can touch (`cancho authority`) is the pinned docs/authority.json
```

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) builds the pinned compiler and
runs the end-to-end tests, Schemathesis included, `benches/check.sh`, and the authority report check on every push.

## Benchmarks

On one core each, every implementation checked to do the same work first
([`docs/benchmarks.md`](docs/benchmarks.md) has the tables, the method, and what each
comparison does and does not show):

| requests a second | GET one | page of 20 | rejected body | create |
|---|---:|---:|---:|---:|
| **cancho** | **83,289** | **75,286** | **63,241** | **53,755** |
| Go `net/http` | 65,216 | 53,792 | 47,011 | 41,051 |
| hand-written C (epoll) | 75,734 | 68,144 | 67,376 | 60,719 |
| FastAPI (best set-up) | 4,921 | 4,307 | 3,536 | 3,948 |

* against **FastAPI**: 14-18x, and a p99 of 0.55 ms against 10.8 ms;
* against **Go's `net/http`**: 1.3-1.4x ahead, with a p99 of two thirds of Go's;
* against the **hand-written C server**: 1.10x ahead on a read and a page, 6% and 11% behind on a rejected body and a
  create, and 92% of the most one core can do over loopback TCP (a server that answers one canned reply).

A request costs the same in an API of 6, 206 or 2,006 operations (within 3.5%, the noise of the VM). At rest it is **1.8 MiB resident and starts in 4 ms**, 2.0 MiB with 100 idle connections (FastAPI: 47 MiB and half a second; Go: 7-12 MiB); the sizes
are in [`docs/benchmarks.md`](docs/benchmarks.md#start-up-and-memory-2026-10-08), with what they do not show.

Against the stronger yardsticks (a separate, slower run, [`docs/benchmarks.md`](docs/benchmarks.md#stronger-yardsticks-go-fasthttp-and-rust-axum-2026-10-08)): **Go's fasthttp is faster than cancho on a single-user read (11%) and a create (7%)**, cancho is ahead on a page of 20 (15%) and level on a rejected body, and cancho is 1.3-1.8x ahead of axum on one thread.

On **two cores each** (two processes sharing a port, against FastAPI's two workers and Go on two cores) the gap with FastAPI
narrows and does not close: 19-25x, against 23-27x on one core. One cancho process is 13-15x ahead of two FastAPI workers.

One 4-vCPU VM, one run; repeats differ by about 5% (a create by up to 10%). **The first run, on a faster VM and before
`web.dispatch`, had 128,972 on a read and 15-26x FastAPI**: FastAPI barely moved between the two VMs (5,216 and 4,921) and cancho did
(0.65x), so a ratio against a Python program depends on the machine; both runs are in [`docs/benchmarks.md`](docs/benchmarks.md),
with what each does and does not show. The page endpoint was 40,755 in the first comparison: the comparison is what found the two
causes, one in the example and one in cancho's `std.buffer`, both fixed.

## Layout

```
src/web.cho                the declaration layer: operations, parameters, bodies, responses -> router + OpenAPI
examples/users/users.cho   the service: schemas, the declared API, handlers, store, the loop
examples/users/openapi.json  the contract as a file, checked against what the service serves
scripts/build.sh          fetch + verify the locked packages, then build
scripts/check-authority.sh  the service's `cancho authority` report against docs/authority.json (CI fails when it changes)
docs/authority.json       what the users service can touch, as last approved: effects, bounds, foreign symbols
deps/*.lock               the packages this builds against, pinned by hash
tests/e2e.py              the end-to-end tests (real binary, real sockets, Schemathesis)
tests/web_test.cho         unit tests of `web`: documents derived by hand, compared byte for byte
benches/                  the benchmark: the FastAPI, Go (net/http, fasthttp), Rust (axum) and C implementations of the same
                          API, the load generator, and the checks that they do the same work
                          (`ab.sh` times two builds of the service, alternated: is a change free?)
docs/design.md            what the framework layer will be, and what building the example found
docs/benchmarks.md        the method, the numbers, and how to read them
docs/index.html           the project page; examples.html and evidence.html beside it
docs/logo.jpg             the logo as given; scripts/site_assets.py derives the page's images from it
scripts/gen_site.py       writes the three pages, robots.txt and sitemap.xml (needs the cancho-gateway page for its CSS: GATEWAY_INDEX)
scripts/figures.py        draws docs/figures/bench.svg from the table in this file
```

## Limitations

Not yet built:

Middleware, auth, and anything like FastAPI's dependency injection; defaults declared once
(a handler still says what `limit` is when it is absent); `$ref`/`$defs` in the generated JSON Schema. (`dispatch` is in all
three services now: `users`, `users_pg` and `users_threads`; the last two were converted after the first, so a bad parameter is
the same answer in each.) The design document says which of these are decided and which are open.

What `cancho` has now that this layer has not been tried with (corrected 2026-10-08; this file used to list all three as
missing):

* **TLS.** `cancho` has a TLS 1.3 server (`packages/tls`; its own notes say it has not been independently reviewed) and
  `http.server` can be driven by bytes instead of sockets (`docs/http-server.md` section 11), which is how its
  `examples/https_hello` serves HTTPS with keep-alive and pipelining. The loop here is the application's own, so
  nothing in `web` stands in the way, but **no service in this repository has been put behind it**: no example, no
  test, no measurement. Until one is, terminate TLS in front.
* **More than one core.** `cancho` has threads (`spawn` and `join`). `examples/users_threads` runs the unchanged loop in two
  of them (one heap and one clock each, one `SO_REUSEPORT` listener) and measured no worse than two processes
  ([`docs/benchmarks.md`](docs/benchmarks.md#two-threads-in-one-process)). Each thread keeps its own store, so it is not a
  deployable service: a store the threads share is not built.
* **Streaming.** `http.server` can stream a *response*; this layer does not use it. A request body is still read whole
  (a `413` past its buffer).

## Learn more

| | |
|---|---|
| [the project page](https://alpibrusl.github.io/cancho-web/), [the examples](https://alpibrusl.github.io/cancho-web/examples.html) | what it is, and the users API run |
| [the evidence](https://alpibrusl.github.io/cancho-web/evidence.html) | the tests, what building it found, what is not claimed |
| [`docs/design.md`](docs/design.md) | what the framework layer will be, and what building the example found |
| [`docs/benchmarks.md`](docs/benchmarks.md) | the method, the numbers, and how to read them |

## Contributing

Every change goes through what CI runs: the end-to-end tests (Schemathesis included) and `benches/check.sh`. Design before code, in
`docs/`, with claims measured; a claim that turns out false is corrected in place.

## Licence

[EUPL-1.2](LICENSE).
