# lexsys-web

> **Status: one real example built** -- [`examples/users`](examples/users/users.ls),
> a CRUD JSON API over the `http.server` and `lexsys-schema` packages, held to its
> own OpenAPI document by an end-to-end test over real sockets and by Schemathesis.
> The framework layer ([`docs/design.md`](docs/design.md)) is not extracted yet:
> the example is what it will be extracted *from*.

A web layer for [lex-sys](https://github.com/alpibrusl/lex-sys): routes with typed
parameters, request bodies validated by
[`lexsys-schema`](https://github.com/alpibrusl/lexsys-schema), `problem+json`
errors, and an OpenAPI document generated from the same declarations -- on top of
the `http.server` package that `lex-sys` already ships (`packages/http-server/`).

One thread, a `Poller`, no `Ffi`, no `extern fn`: the compiled server's authority
report names exactly what it can do, and C is not on the list.

## Try it

```
scripts/build.sh examples/users/users.ls build/users      # fetches + verifies both packages
build/users 8080
curl -XPOST -H 'Content-Type: application/json' -d '{"name":"Ada","age":36}' localhost:8080/users
curl localhost:8080/openapi.json
```

`scripts/build.sh` needs `lex-sys` on `PATH` (or `LEX_SYS=`) and checkouts of
[`lex-sys`](https://github.com/alpibrusl/lex-sys) and
[`lexsys-schema`](https://github.com/alpibrusl/lexsys-schema) beside this one (or
`LEX_SYS_DIR=`, `SCHEMA_DIR=`). `deps/*.lock` pin the packages by hash; `vcs fetch`
refuses a store that no longer matches.

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

`lex-sys authority` on the built service reports `args`, `clock`, `conn_*`,
`heap`, `net_in`, `poll` and the console's error stream -- **no `ffi`, no
filesystem**.

## Measured

On one core each, every implementation checked to do the same work first
([`docs/benchmarks.md`](docs/benchmarks.md) has the tables, the method, and what each
comparison does and does not show):

* against **FastAPI**: about 23x the requests a second on a read, 9x on a page, 16x on a
  create, and a p99 of 0.4 ms against 12 ms;
* against **Go's `net/http`**: 1.5x on a read, a create and a rejected body -- and **0.6x on a
  page**, where Go is faster;
* against a **hand-written C server** for the same API: within noise on a read, behind it by
  15-27% on a rejected body and a create, and 2.4x behind on a page; and 87% of the
  most one core can do over loopback TCP (a server that does no work).

## Licence

[EUPL-1.2](LICENSE).
