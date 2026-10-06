# lexsys-web: a FastAPI-shaped layer for lex-sys

> **Status: design, one real example built (§7), and its declaration half extracted (§8)**:
> `src/web.ls` writes the router and the OpenAPI document from one declaration. Dispatch and
> middleware are not built; the first section says what this does *not* try to be.

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

**What the benchmark found** (`docs/benchmarks.md`): the comparison with Go and C
showed the page endpoint at 0.62x of Go, for two reasons, both fixed. The example
re-validated stored users with `json.put_fragment` although the store only ever holds
what `render_user` wrote from a body that had just validated, so the page now splices
them as bytes (40,000 -> 62,000 requests a second); and `std.buffer.append` in `lex-sys`
copied one byte at a time through `push` (62,000 -> 71,000, lex-sys PR #181). The first is
a design point for the framework layer: a value validated on the way in and rendered by
the program itself should not be validated again on the way out. `put_fragment` stays
for what the program did *not* render.

**What the example does not test yet:** TLS, streaming bodies, more than one core.

## 8. The declaration half, built

**What was wrong.** `examples/users` said what its routes were three times: in the `std.route`
table, in the `if` chain that tests the id the router returns, and in a hand-written JSON string
of OpenAPI `paths`. Nothing made them agree. A route could be served and undocumented, or
documented with a parameter the handler never read; the end-to-end contract tests and Schemathesis
catch the second kind only for operations that are documented.

**What `src/web.ls` is.** An operation is declared once:

```
let (api, op) = web.operation(heap, api, "GET", "/users/:id", "getUser");
api = web.path_param(heap, api, op, "id", path_id);        // a lexsys-schema node
api = web.respond(heap, api, op, 200, "the user", user);
api = web.respond_problem(heap, api, op, 404);
```

`operation` registers the route and answers its id -- the number the handler tests -- and everything
declared after it about that id is what `web.openapi` writes: path and query parameters, the body,
the responses (with a header, a `$ref` to a named component, or the shared problem response), and
`components.schemas` generated by `lexsys-schema` from the nodes the application validates with.
`internal` registers a route that is served and not documented (the document itself). `web.find`
is `route.find` over the declared router. The representation is a router, a text pool and one
`Vec[int]` of 8-int records: declaring is `O(1)`, `openapi` scans them once at start-up.

**How it was checked.** The refactor had a fixed point: the hand-written document the service
already served. The generated document is **byte-for-byte identical** to it (`cmp`), and is now
checked in as `examples/users/openapi.json` and compared with what the service serves by an
end-to-end test, which fails when a declaration changes (checked by changing one description).
`tests/web_test.ls` compares documents derived by hand with the output for a minimal API, shared
path parameters with `$ref`s and the problem response, and query/body/header/hidden routes with
the routing the declaration also made. Throughput is unchanged: GET one 123,200-124,500 against
113,900-123,600 for the hand-written routes and a page 70,800-75,700 against 70,400-72,500
(alternated, three rounds each; the spread is run-to-run noise).

**Who may call, and a declared error shape.** An operation can say which credentials it takes: `bearer_scheme` lists an HTTP bearer scheme under `components.securitySchemes`; `require` adds one alternative to an operation's `security` (the caller needs one of them); `no_auth` writes `security: []` for an open operation; `default_require` writes the document's own default, which an operation without a `require` inherits. An API whose errors are not `application/problem+json` names a component `Error` and answers with `respond_error`, which is a `$ref` to `components.responses.Error` that carries the status's own description (OpenAPI 3.1 allows that on a reference). It is the description only: nothing here checks a token, and a service keeps its own gate. Nothing is written for any of it unless it was declared: the users document is unchanged byte for byte. `tests/web_test.ls` compares a document with two alternatives, an open operation under a default and the error response with one derived by hand, and the same document is a valid OpenAPI 3.1 file for `openapi-spec-validator`. It came from `lexsys-hooks`, whose 26 routes in three token scopes were described by hand (lexsys-web#14).

**What `lexsys-hooks` needed that this did not have.** Moving that service's 26 routes onto `web` (its `docs/openapi.json` is now generated from them) found six things the layer could not say, each now a call: `header_param` (a request header such as `Idempotency-Key`, written as a header parameter and not routed), `optional_body` (`required: false`), `respond_text` (a `text/plain` answer: its Prometheus exposition), `summary` and `describe` (an operation's own words), `describe_param` (a parameter's description, written once for a path parameter) and `about` (the document's `info.summary` and `info.description`). Nothing is written for any of them unless it was declared. And it needed `web` to be a **package**: `scripts/publish.sh` writes `.lex-sys-vcs` from `src/web.ls` (with `lexsys-schema` as its requirement, at the commit `ci.yml` builds with) so that a project names `web` in its `lex-sys.toml` instead of copying the file; `scripts/publish.sh --check` fails when the committed store is not what the source publishes.

**What it does not do, and why.**

* **It does not dispatch.** The application keeps its loop and its `if` on the id, for the reason
  in §2: a callback cannot be handed a view of the loop's buffers. A named constant per id, checked
  against what `operation` returned at start-up, would remove the one remaining way for the `if`
  and the declaration to disagree; it is not built.
* **It does not validate parameters for the handler.** `route.param_nat` and `http.query_value` are
  still the handler's, and a path or query parameter that fails its declared schema is still a check
  the handler makes -- although the declaration now says what that schema is. Making a bad
  parameter a `422` by construction is the next slice, and needs a place to put the answer; the
  declaration has the information, the dispatch does not exist yet.
* **Responses are documented, not enforced.** `respond` says what a handler may answer; nothing
  checks that it did. The contract test does, per request, from outside.
