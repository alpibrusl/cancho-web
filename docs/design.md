# lexsys-web: a FastAPI-shaped layer for lex-sys

> **Status: design, with one real example built** (§7). The framework layer is not
> extracted yet, and the first section says what it does *not* try to be.

## 1. What it is, and is not

FastAPI is routes + validated bodies + dependency injection + generated docs +
`async`. This takes the first, second and fourth, restates the third, and does
not do the fifth.

| FastAPI | Here |
|---|---|
| path operations (decorators) | a route table built at start-up (`std.route`), dispatched on the route id the router returns |
| typed path/query parameters | `route.param_nat`, `http.query_value`, declared with the route so the OpenAPI document knows them |
| request body validation (pydantic) | [`lexsys-schema`](https://github.com/alpibrusl/lexsys-schema): the same declaration validates and documents |
| error responses | `application/problem+json`, produced by the layer, never by hand |
| OpenAPI + `/docs` | `GET /openapi.json` generated from the route table at start-up; a docs UI later, as static content |
| dependency injection | **not done.** Lex has no closures and no reflection; "dependencies" are the arguments a handler is given, explicit and visible in its signature (and so in its authority) |
| `async`/`await` | **not done.** One thread, a `Poller`, no blocking call; more cores by `reuseport` and more processes |

It sits on `http.server`, the package `lex-sys` ships in `packages/http-server/`
(`docs/http-server.md` there): sockets, framing, pipelining, back-pressure,
timeouts. That layer returns one whole request at a time and takes an answer.

## 2. The constraint that shapes it

The obvious API is `web.serve(app, handler)`: the framework owns the loop and
calls a handler. **It does not type-check** in lex-sys today, and the reason was
reproduced rather than assumed (`lex-sys` `docs/http-server.md` §2): a function
value's type may mention only regions already in scope, and a request is a view
of a buffer the loop borrowed itself. A handler cannot be handed a view of
buffers it cannot name a region for.

So the application keeps its loop, and this layer is **the middle of it**:

```
loop {
    srv = server.wait(heap, srv, clock, listener, 1000);
    while ((slot = server.next(heap, srv)) >= 0) {
        // web: match the route, read the typed params, validate the body,
        //      run the middleware that is registered, build the answer
        // app: the handler, an ordinary function the app writes
        server.respond(srv, answer);
    }
}
```

`web` provides `dispatch`: given the request views it answers *which route, its
parameters in a slot table, and whether the body validated against the route's
schema* -- or the problem+json answer itself when something is wrong with the
request. The application's handler runs only for requests that survived. The
handler is a `match` on the route id, as `examples/api`'s `handle` is: a
decorator is a name beside a function, and a `match` is the same thing in a form
the checker can read.

A framework that owns the loop would need higher-rank function types in the
compiler. That is recorded as the thing to ask for **if** hand-written dispatch
turns out to be the cost people actually mind; it is not proposed here.

## 3. Middleware

A middleware is a function the application calls in an order it can see, around
the handler: request id, access log, timing (the `Clock` capability), a body
size limit. There is no chain object because a chain of function values hits the
same wall as §2, and an explicit sequence of calls is more legible than a
registered list. The layer supplies the standard ones as plain functions.

## 4. Authority is the feature

Every handler's signature lists what it can touch (`heap`, `conn_write`, a
filesystem path...) and `lex-sys authority` reports it for the whole program.
A web layer that hid capabilities behind injection would throw that away. The
test of the layer is that a compiled service reports `net_in`, `conn_*`,
`poll`, `clock`, `heap` -- and no `ffi`.

## 5. Milestones

Each is a thing that runs and is tested before the next starts.

1. **Hello.** A service that fetches `http.server` from the `lex-sys` store and
   answers `/health`. Establishes the build: `vcs fetch` + `build --std`, and CI
   pinned to a `lex-sys` release.
2. **Routes and parameters.** Declared once, with parameter types; a bad
   parameter is a 422 problem+json by construction.
3. **Bodies.** Validation through `lexsys-schema`; the handler reads through the
   slot table.
4. **OpenAPI.** The document generated at start-up, checked against a stock
   OpenAPI validator, and diffed in CI so a change to the API is a visible
   change to a file.
5. **Middleware.** Request id, access log, timing.
6. **Measured.** The same app as a FastAPI service, on the benchmark `lex-sys`
   already carries (`benches/server/`): requests a second and the tail. The
   `lex-sys` figure for the bare loop is the ceiling this layer is accountable
   to; what it costs is measured, not promised.

## 6. Open questions

1. **Where `http.server` lives.** In `lex-sys/packages/` today, where the
   compiler's conformance tests use it. When this repository has code that
   depends on it, it should probably move here and `lex-sys` keep a copy of the
   example as its regression test; that is a decision for then.
2. **Versioning against the compiler.** A `lex-sys` store records no hash of
   the `std` it was published against, so this repository's CI pins a `lex-sys`
   release explicitly.
3. **Streaming.** `http.server` hands over whole requests. Bodies larger than
   its buffer (413 today), `Expect: 100-continue` and TLS are its open items
   (`lex-sys` `docs/server.md` §6), and this layer inherits them.

## 7. What building a real service found

`examples/users` is milestones 1-3 and 4 (by hand) built as a service rather than
a framework: routes with typed parameters, a body validated by `lexsys-schema`,
`problem+json` errors, and an OpenAPI document that embeds the generated schemas.
`tests/e2e.py` runs it on a real socket and holds it to that document, and
Schemathesis generates requests from the document. It is the reason to write
examples before the layer: a framework extracted from nothing would have encoded
the wrong decisions.

**Defects it found in `lexsys-schema`** (fixed there, recorded in that repo's
design §11-§12): `150.0` is an integer, and string length counts code points. Both
were decisions the schema repository's own tests agreed with, because the tests
had been shaped to the decisions. Schemathesis, which reads the generated document
the way the standard does, disagreed on the first run.

**Defects it found in this repository's own example**, fixed here: an unknown query
parameter has to be refused for the reason an unknown body field is; the document
must state the integer maximum the server enforces (a 17-digit limit that is true
of the server and false of the contract is a defect in the contract); and
`json.to_int` on a float-spelled integer answered 0, which would have stored
`"age": 0` silently (hence `schema.to_int`).

**Gaps in the packages underneath -- found by this example, since fixed** (`lex-sys`,
`http-server.md` §8, `http.md`, `json.md` §6.1; each with a test that fails without it):

* `server.reply` hard-coded `Content-Type: application/json`, so `problem+json` needed
  the example's own `reply_as`. **Fixed:** `server.reply_as` takes the content type.
* `http.respond_head` always wrote `Content-Length`, so a correct `204 No Content`
  was impossible and `DELETE` answered 200 with the deleted record. **Fixed:**
  `http.respond_no_content` / `server.reply_empty` write a `204`/`304` head with
  neither header; `DELETE` is a `204`, the document declares it with no `content`, and
  `tests/e2e.py` checks that the answer has no body and neither header and that two
  pipelined `204`s and a `200` stay framed.
* `json.Writer` could not splice a fragment, so the OpenAPI document and the list were
  assembled with `Buffer`s, correct only by construction. **Fixed:**
  `json.put_fragment` takes any complete JSON value and *checks* it (a fragment that is
  not exactly one value traps). The document's static `paths` is now a fragment, so a
  typo stops the service at start-up instead of serving an invalid document.
* The store was fixed-capacity (10,000 users, 4 MiB) because a `res` field cannot be
  replaced through a `&!` reference. **Fixed in the example, not in `lex-sys`:** growing
  takes and returns the `Store` by value, as `std.buffer` and `std.vec` do (reading and
  deleting still go by reference). It now grows to 100,000 users or 64 MiB;
  `Growth.test_the_store_grows_past_what_the_old_fixed_arena_held` creates 12,000
  ~400-byte users (4.8 MB, past the old arena) and fails with a `503` when the arena
  is capped at the old size.

**What the example does not test yet:** throughput and tail latency against the
same service in FastAPI (milestone 6), TLS, streaming bodies.
