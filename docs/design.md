# cancho-web: a FastAPI-shaped layer for cancho

> **Status: design, one real example built (§7), its declaration half extracted (§8), and parameters validated by
> construction built (§9, 2026-10-08)**: `src/web.cho` writes the router and the OpenAPI document from one declaration, and
> `web.dispatch` judges a request's declared parameters before the handler runs. Middleware is not built; the first section
> says what this does *not* try to be.

## 1. What it is, and is not

FastAPI is routes + validated bodies + dependency injection + generated docs +
`async`. This takes the first, second and fourth, restates the third, and does
not do the fifth.

| FastAPI | Here |
|---|---|
| path operations (decorators) | a route table built at start-up (`std.route`), dispatched on the route id the router returns |
| typed path/query parameters | `route.param_nat`, `http.query_value`, declared with the route so the OpenAPI document knows them |
| request body validation (pydantic) | [`cancho-schema`](https://github.com/alpibrusl/cancho-schema): the same declaration validates and documents |
| error responses | `application/problem+json`, produced by the layer, never by hand |
| OpenAPI + `/docs` | `GET /openapi.json` generated from the route table at start-up; a docs UI later, as static content |
| dependency injection | **not done.** Lex has no closures and no reflection; "dependencies" are the arguments a handler is given, explicit and visible in its signature (and so in its authority) |
| `async`/`await` | **not done.** One thread, a `Poller`, no blocking call; more cores by `reuseport` and more processes, or threads (`examples/users_threads`, §10) |

It sits on `http.server`, the package `cancho` ships in `packages/http-server/`
(`docs/http-server.md` there): sockets, framing, pipelining, back-pressure,
timeouts. That layer returns one whole request at a time and takes an answer.

## 2. The constraint that shapes it

The obvious API is `web.serve(app, handler)`: the framework owns the loop and
calls a handler. **It does not type-check** in cancho today, and the reason was
reproduced rather than assumed (`cancho` `docs/http-server.md` §2): a function
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
filesystem path...) and `cancho authority` reports it for the whole program.
A web layer that hid capabilities behind injection would throw that away. The
test of the layer is that a compiled service reports `net_in`, `conn_*`,
`poll`, `clock`, `heap` -- and no `ffi`.

## 5. Milestones

Each is a thing that runs and is tested before the next starts.

1. **Hello.** A service that fetches `http.server` from the `cancho` store and
   answers `/health`. Establishes the build: `vcs fetch` + `build --std`, and CI
   pinned to a `cancho` release.
2. **Routes and parameters.** Declared once, with parameter types; a bad
   parameter is a 422 problem+json by construction.
3. **Bodies.** Validation through `cancho-schema`; the handler reads through the
   slot table.
4. **OpenAPI.** The document generated at start-up, checked against a stock
   OpenAPI validator, and diffed in CI so a change to the API is a visible
   change to a file.
5. **Middleware.** Request id, access log, timing.
6. **Measured.** The same app as a FastAPI service, on the benchmark `cancho`
   already carries (`benches/server/`): requests a second and the tail. The
   `cancho` figure for the bare loop is the ceiling this layer is accountable
   to; what it costs is measured, not promised.

## 6. Open questions

1. **Where `http.server` lives.** In `cancho/packages/` today, where the
   compiler's conformance tests use it. When this repository has code that
   depends on it, it should probably move here and `cancho` keep a copy of the
   example as its regression test; that is a decision for then.
2. **Versioning against the compiler.** A `cancho` store records no hash of
   the `std` it was published against, so this repository's CI pins a `cancho`
   release explicitly.
3. **Streaming and TLS.** `http.server` hands over whole requests: bodies larger than its buffer are a 413 today, and `Expect: 100-continue`
   is open. *Corrected 2026-10-08: this item used to list TLS as open too. `cancho` now has a TLS 1.3 server and `http.server` a byte-fed
   mode that a terminator drives (`docs/http-server.md` section 11, `examples/https_hello`), and a response can be streamed. This layer
   uses neither: see §10.*

## 7. What building a real service found

`examples/users` is milestones 1-3 and 4 (by hand) built as a service rather than
a framework: routes with typed parameters, a body validated by `cancho-schema`,
`problem+json` errors, and an OpenAPI document that embeds the generated schemas.
`tests/e2e.py` runs it on a real socket and holds it to that document, and
Schemathesis generates requests from the document. It is the reason to write
examples before the layer: a framework extracted from nothing would have encoded
the wrong decisions.

**Defects it found in `cancho-schema`** (fixed there, recorded in that repo's
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

**Gaps in the packages underneath -- found by this example, since fixed** (`cancho`,
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
  replaced through a `&!` reference. **Fixed in the example, not in `cancho`:** growing
  takes and returns the `Store` by value, as `std.buffer` and `std.vec` do (reading and
  deleting still go by reference). It now grows to 100,000 users or 64 MiB;
  `Growth.test_the_store_grows_past_what_the_old_fixed_arena_held` creates 12,000
  ~400-byte users (4.8 MB, past the old arena) and fails with a `503` when the arena
  is capped at the old size.

**What the benchmark found** (`docs/benchmarks.md`): the comparison with Go and C
showed the page endpoint at 0.62x of Go, for two reasons, both fixed. The example
re-validated stored users with `json.put_fragment` although the store only ever holds
what `render_user` wrote from a body that had just validated, so the page now splices
them as bytes (40,000 -> 62,000 requests a second); and `std.buffer.append` in `cancho`
copied one byte at a time through `push` (62,000 -> 71,000, cancho PR #181). The first is
a design point for the framework layer: a value validated on the way in and rendered by
the program itself should not be validated again on the way out. `put_fragment` stays
for what the program did *not* render.

**What the example does not test yet:** TLS, streaming bodies, shared state between threads (§10 says what exists in `cancho` for each).

## 8. The declaration half, built

**What was wrong.** `examples/users` said what its routes were three times: in the `std.route`
table, in the `if` chain that tests the id the router returns, and in a hand-written JSON string
of OpenAPI `paths`. Nothing made them agree. A route could be served and undocumented, or
documented with a parameter the handler never read; the end-to-end contract tests and Schemathesis
catch the second kind only for operations that are documented.

**What `src/web.cho` is.** An operation is declared once:

```
let (api, op) = web.operation(heap, api, "GET", "/users/:id", "getUser");
api = web.path_param(heap, api, op, "id", path_id);        // a cancho-schema node
api = web.respond(heap, api, op, 200, "the user", user);
api = web.respond_problem(heap, api, op, 404);
```

`operation` registers the route and answers its id -- the number the handler tests -- and everything
declared after it about that id is what `web.openapi` writes: path and query parameters, the body,
the responses (with a header, a `$ref` to a named component, or the shared problem response), and
`components.schemas` generated by `cancho-schema` from the nodes the application validates with.
`internal` registers a route that is served and not documented (the document itself). `web.find`
is `route.find` over the declared router. The representation is a router, a text pool and one
`Vec[int]` of 8-int records: declaring is `O(1)`, `openapi` scans them once at start-up. *(Corrected 2026-10-08: `openapi` did not scan them once. It rescanned the records inside loops that already did, and called `op_at`, a scan, so generating the document for 4,000 operations took 103 s. `op_at` is an index lookup now and it takes 1.1 s; it is still quadratic, 8 s at 10,000. `docs/benchmarks.md`, "Does the size of the API matter?".)*

**How it was checked.** The refactor had a fixed point: the hand-written document the service
already served. The generated document is **byte-for-byte identical** to it (`cmp`), and is now
checked in as `examples/users/openapi.json` and compared with what the service serves by an
end-to-end test, which fails when a declaration changes (checked by changing one description).
`tests/web_test.cho` compares documents derived by hand with the output for a minimal API, shared
path parameters with `$ref`s and the problem response, and query/body/header/hidden routes with
the routing the declaration also made. Throughput is unchanged: GET one 123,200-124,500 against
113,900-123,600 for the hand-written routes and a page 70,800-75,700 against 70,400-72,500
(alternated, three rounds each; the spread is run-to-run noise).

**Who may call, and a declared error shape.** An operation can say which credentials it takes: `bearer_scheme` lists an HTTP bearer scheme under `components.securitySchemes`; `require` adds one alternative to an operation's `security` (the caller needs one of them); `no_auth` writes `security: []` for an open operation; `default_require` writes the document's own default, which an operation without a `require` inherits. An API whose errors are not `application/problem+json` names a component `Error` and answers with `respond_error`, which is a `$ref` to `components.responses.Error` that carries the status's own description (OpenAPI 3.1 allows that on a reference). It is the description only: nothing here checks a token, and a service keeps its own gate. Nothing is written for any of it unless it was declared: the users document is unchanged byte for byte. `tests/web_test.cho` compares a document with two alternatives, an open operation under a default and the error response with one derived by hand, and the same document is a valid OpenAPI 3.1 file for `openapi-spec-validator`. It came from `lexsys-hooks`, whose 26 routes in three token scopes were described by hand (cancho-web#14).

**What `lexsys-hooks` needed that this did not have.** Moving that service's 26 routes onto `web` (its `docs/openapi.json` is now generated from them) found six things the layer could not say, each now a call: `header_param` (a request header such as `Idempotency-Key`, written as a header parameter and not routed), `optional_body` (`required: false`), `respond_text` (a `text/plain` answer: its Prometheus exposition), `summary` and `describe` (an operation's own words), `describe_param` (a parameter's description, written once for a path parameter) and `about` (the document's `info.summary` and `info.description`). Nothing is written for any of them unless it was declared. And it needed `web` to be a **package**: `scripts/publish.sh` writes `.cancho-vcs` from `src/web.cho` (with `cancho-schema` as its requirement, at the commit `ci.yml` builds with) so that a project names `web` in its `cancho.toml` instead of copying the file; `scripts/publish.sh --check` fails when the committed store is not what the source publishes.

**Asking who may call.** The same declaration can be read back: `requirements`, `requirement` and `is_open` answer, for an operation id, the alternatives the document writes for it (its own, else the default; open; nothing declared). It is the accessor a service needs to derive its gate from the declaration instead of keeping a table beside it (`lexsys-hooks` keeps one and tests that the two agree). It has no more authority than `web.openapi`: it reads records, and a service that makes its gate depend on it has made `declare` order and `require` calls part of its security, which is a decision for that service. Not built: a caller that matches the alternatives against a request's credentials; nothing in `web` knows what a token is.

**What it does not do, and why.**

* **It does not own the loop.** (*Corrected 2026-10-08: §9 built `web.dispatch`, which the application calls in its loop; it routes and judges parameters, and the handler is still an `if` on the id.*) The application keeps its loop and its `if` on the id, for the reason
  in §2: a callback cannot be handed a view of the loop's buffers. A named constant per id, checked
  against what `operation` returned at start-up, would remove the one remaining way for the `if`
  and the declaration to disagree; it is not built.
* **It does not validate parameters for the handler.** `route.param_nat` and `http.query_value` are
  still the handler's, and a path or query parameter that fails its declared schema is still a check
  the handler makes -- although the declaration now says what that schema is. Making a bad
  parameter a `422` by construction was the next slice and is built (§9): `web.dispatch` writes the answer.
* **Responses are documented, not enforced.** `respond` says what a handler may answer; nothing
  checks that it did. The contract test does, per request, from outside.

## 9. Parameters by construction

> **Status: built (2026-10-08), with the corrections of §9.10.** `web.dispatch`, `web.slot`, `web.most_args` and the
> accessors are in `src/web.cho`, `examples/users` uses them, and §9.7 says what was shown. This section was written as a
> design first and is kept as it was written except where a sentence turned out false: those are corrected in place and
> listed in §9.10. `examples/users_pg` and `examples/users_threads` still use `web.find` and their own checks.

### 9.1 The problem, in the code as it stands

`examples/users` declares `limit` once, as a schema node with the range 1..100, and then checks
it again by hand: `default_limit()`, `max_limit()`, `query_number`, `query_keys_known`, the
`if limit < 1 || limit > max_limit()` in `list`, and `route.param_nat` plus `id < 1` in `one`.
That is the same fact written twice, in a place where nothing makes the two agree -- the
failure §8 was written to remove for routes and documents. A handler that forgets one of those
checks serves a request the contract says is invalid, and only Schemathesis, from outside, would
notice. FastAPI gets this by reflecting on a function's type hints; cancho has no reflection,
and `docs/design.md` §2 rules out the callback that would make the handler's signature the
declaration. So the declaration stays data (`cancho-schema`, §2 of its design: *why data, not
types*) and the question is only how the *values* reach the handler.

### 9.2 Decision: a slot table, filled by `web.dispatch`

`web.dispatch` is a function the application calls in its own loop, at the place where
`handle` calls `web.find` today. It is not a callback and owns nothing:

```
let (answer, id) = web.dispatch(heap, api, sc, request, table, params, args, scratch, out, keep);
if id != web.answered() {
    // the route matched and every declared parameter is valid; read them from `args`
    let limit  = web.int_arg(args, limit_slot);      // a valid int if it was present: ask `web.present`
    let offset = web.int_arg(args, offset_slot);
} // else: `answer` already holds the 404, 405 or 422; send it
```

* **a route id**: the handler runs. `out` is untouched. For each declared parameter of that
  operation, `args` holds two ints (§9.3), in declaration order.
* **`web.answered()` (-1)**: dispatch has already written the whole answer to `out` -- the 404 for no such
  path, the 405 with `Allow` (the code `handle` has today, moved), or the 422 for a parameter.
  The caller sends it. The handler does not run, so it cannot forget the check.
* **Slots are numbers learned at start-up**, the way operation ids are: `web.query_param`
  and `web.path_param` keep returning `Api` (existing callers do not change), and a new
  `web.slot(api, op, "limit")` answers the index once, which the service keeps in a `let`.
  Asking by name per request is not offered: it would be a string comparison in the hot loop
  for a fact known at start-up.
* **`args` is a caller-owned `[int]`**, sized by `web.most_args(api)` exactly as `params` is
  sized by `web.most_params(api)` today. No allocation per request, no new capability:
  `cancho authority` reports what it reports now.

**Why this and not the alternatives.**

| | Verdict |
|---|---|
| **A generated record per operation** (`pgen`-style: a tool writes `struct ListUsersArgs`) | The shape is right and cancho has the precedent (`cancho-pg`). Rejected *for now*: the declaration is a program that runs at start-up (`setup`), so a generator would have to run the service or re-read `.cho` source; that is a build stage and a second source of truth for a saving of one `let`. Open for later (§9.9). |
| **A guard the handler calls** (`if !web.check_query(...) { return ... }`) | Smaller, and wrong: it moves the forgotten check from three places to one *call*, which can still be forgotten. The point is that the handler is not reached. |
| **A callback with typed arguments** | Does not type-check (§2). |
| **A slot table** | `cancho-schema` already works this way: `validate` fills `slots`, each a tape node or -1, and the handler reads through them; `route.find` already fills `params`. A third table of the same kind is the existing idiom, costs nothing per request, and is read with plain indexing. |

### 9.3 What a slot holds

Two ints per parameter, `(a, b)`, by the kind of its schema node:

| node | `a` | `b` |
|---|---|---|
| integer | the value, or the declared default when absent | `1` present in the request, `0` absent |
| string, choice | start of the value in the request head, or -1 | end, or -1 |
| bool | `0` or `1` (default if absent) | present flag |

Text slots are offsets into **the request head** (`request`), one base for path, query and
header alike, so `request[a..b]` is the value with no copy and the borrow rules already hold
(a handler's request is a borrowed view of the loop's buffers). The offsets are of the value *as sent*; a value is
*judged* decoded (§9.10), and a handler that wants the decoded text decodes it, through `route.param_decoded`.

A parameter that is required and absent never reaches a slot (422). An optional one with no
default has `b = 0`, and the handler asks `web.present`. *Corrected: a default as a declaration (`web.default_int`), written to the OpenAPI schema as `default` and applied by dispatch, **is not built** (§9.10); the example keeps `default_limit()`, and it is still a second copy of a number the document does not state.*

### 9.4 What dispatch checks, and what it answers

For the matched operation only, in this order, collecting **every** error as `validate` does for
bodies:

| code | when |
|---|---|
| `required` | a required query or header parameter is absent |
| `unknown` | a query key the operation did not declare (the rule `query_keys_known` encoded), **for an operation that declares at least one query parameter** (§9.10) |
| `duplicate` | a declared query key given twice. `http.query_value` takes the first and ignores the rest; for an API that already refuses unknown keys, silently choosing one is the same defect |
| `type` | an integer parameter is not decimal digits (an optional `-`), or has more than 17 digits |
| `minimum`, `maximum` | outside the node's range |
| `min_length`, `max_length`, `choice` | as `cancho-schema` already names them for bodies |

Text is not coerced: `"5.0"`, `"+5"`, `" 5"`, `"0x5"` and the empty string are `type`. Leading
zeros stay accepted, because `number_of` accepts them now and the point of this slice is not to
change which requests are valid (§9.8 keeps the contract fixed). The 17-digit cap is the one
`route.param_nat` has, and the reason is the same (19 digits would overflow an `int`), so no input
reaches an overflow.

The answer is the `problem+json` the body path already produces, with the same `count` and
`errors` members. `Problem.errors[].pointer` is **kept**, so the generated `Problem` component and
`openapi.json` do not change: a parameter's pointer is its address in the request,
`/query/limit`, `/path/id`, `/header/idempotency-key`. (A pointer that does not point into a JSON
document is a stretch of RFC 6901, and the alternative -- an additive optional `in` and `name` --
is in §9.9. The first costs no change to the contract; the second is more honest.)

An operation with no declared parameters pays one comparison of a count.

### 9.5 What it needs from `cancho-schema`

One entry point, because "the same nodes validate and document" is the property that makes this
framework worth having, and `web` must not grow a second validator for scalars:

```
pub fn check_text(s: &Schema, node: int, text: &[byte]) -> int   // 0, or an error code
pub fn int_of_text(text: &[byte]) -> int                          // after check_text said 0
```

Text is the input, not a JSON tape: the rules are `to_int`'s (no float spelling, no coercion)
applied to a decimal string, and the string rules are `cancho-schema` §12's (code points, not
bytes). This is a change in the other repository, first, with its own tests and design entry;
this repository's CI then bumps `SCHEMA_REV`. It is the one dependency of the slice.

### 9.6 What changes in `examples/users`

`query_number`, `query_keys_known`, `number_of`, `default_limit`, `max_limit`, the two range
checks in `list` and the `id < 1` check in `one` are deleted -- the handler receives `limit`,
`offset` and `id` already valid. That is the measure of the slice: **the example loses code**,
and `web` gains the one place that has it. `lexsys-hooks` (26 routes) is the second consumer
and the check that the slot API is not shaped to one example.

### 9.7 What had to be shown before this was called done, and what was

1. **The contract does not move.** `examples/users/openapi.json` byte-identical (`cmp`), the same fixed point §8 used.
   *Shown:* the end-to-end test that compares the served document with the file passes, unchanged.
2. **The answers do not move, except one.** The existing 27 end-to-end tests, Schemathesis included, pass; the single change
   is the 422 for a bad parameter, which becomes the `errors` list above. *Shown, with two more changes the design did not
   foresee* (§9.10: a value is judged decoded, so `limit=%35` is now 5 and was a 422; and the default `detail` sentences are now the codes'). The one test that
   needed a change was not changed: it asserts a status, not a sentence.
3. **A rule tag per refusal.** *Shown:* `tests/web_test.cho` has seven dispatch tests (14 in the file) with a case for every code in
   §9.4, for each place (path, query, header), for several errors at once, for two path parameters, and for the cases that
   must *not* refuse (a declared key, an optional absent, a value at the end of its range, a header that contains `%zz`).
4. **No input reaches a panic.** *Shown for what dispatch can be handed:* 2,000 unknown keys (counted to 64, 16 listed), 2,000
   copies of a known key (one `duplicate`), one 20,000-byte key, a header that is not text, `%zz`, `%ff`, an integer of 20 digits,
   a `%00` (refused as `nul` by a string that forbids it, and as a `choice` by one that does not allow it), and a scratch buffer too small.
   **Not shown as written:** the design named 10,000 repeated keys and an embedded raw NUL. A head is limited to 65,536 bytes
   (`http.max_head`), so 2,000 is what fits in a useful query, and `http.parse` refuses a raw 0xFF in the request target (tested), so a
   byte that is not text arrives in a header or percent-encoded. Linear in the query: two passes over it per declared parameter,
   and the unknown-key pass stops at 64 errors.
5. **The cost, measured, not argued.** `benches/ab.sh` alternates the old build (`main`) and the new one, on the workloads of
   `benches/run.sh` plus `GET /users?limit=0`, six rounds, server on core 0 and `kload` on cores 2 and 3. **This VM is slower than the one
   `docs/benchmarks.md` was measured on** (a read here is about 86,000, not 129,000), so only the ratios are comparable.

   | requests a second, median of 6 | before | after | after / before |
   |---|---:|---:|---:|
   | GET one user | 86,140 | 84,816 | 0.985 |
   | GET a page of 20 | 76,294 | 74,451 | 0.976 |
   | POST, invalid body (422) | 63,011 | 62,739 | 0.996 |
   | POST, create | 55,507 | 54,559 | 0.983 |
   | GET `/users?limit=0` (a parameter refused) | 81,516 | 73,011 | **0.896** |

   Within the 5% the figures of this VM move by, **except the refusal of a parameter, which is 10% slower**: it judges the request
   twice (a pass that answers 0 or not, then a pass that writes the entries) and builds a JSON document per error where the
   hand-written code wrote one fixed sentence. A rejected *body*, the case this section promised would not move, did not.
   **The first implementation was slower** (0.93-0.94 on a read, repeated in two runs, outside the noise): it scanned every
   record of the declaration for each request, so its cost grew with the size of the API and not with the operation. §9.10.

### 9.8 What this deliberately is not

* **Not bodies.** A body gives the handler a tape and its slots, an allocation per request and a
  different shape; parameters are a few ints. Bodies are the next slice, and they reuse the idiom
  (`web.dispatch` would also fill the body's `slots`), but they are not designed here.
* **Not dependency injection**, and not middleware: nothing runs but the checks the declaration
  already states. A handler's authority is still its signature.
* **Not a new way to say a route.** `web.operation`, `web.find`, `web.openapi` and every
  existing `*_param` call are unchanged; a service that keeps calling `web.find` keeps working.
  Dispatch is additive, and `web.find` remains the thing it calls.

### 9.9 Open questions, as they stand

1. **Offsets or decoded text.** *Answered:* the slot keeps offsets of the raw value, a value is judged decoded into a `scratch`
   the caller owns (§9.10), and a handler that wants the decoded text decodes it.
2. **`pointer` for a parameter.** *Answered as proposed:* `/query/limit`, `/path/id`, `/header/Idempotency-Key`; `Problem`
   is unchanged. To be revisited if a client is found that dislikes it.
3. **Leading zeros and `-0`.** Accepted, as before (`cancho-schema` §14 says so); a stricter rule is a contract change and belongs in a slice of its own.
4. **Generated constants for ids and slots** (§9.2, first row). Still open: `examples/users` keeps three `web.slot` lookups at start-up, which is not a burden at this size.
5. **Defaults as a declaration.** Still open, and now the next step for parameters: the document needs `"default"` inside the parameter's
   schema, which means splicing into the fragment `cancho-schema` writes.
6. **Headers.** *Answered:* looked up by a lowercase copy of the declared name kept in the text pool, so the document keeps the
   declared spelling and the lookup ignores case. `cancho-hooks`'s `Idempotency-Key` is the case to design against, and is not yet a consumer of `dispatch`.

### 9.10 What building it found, and what it changed in the design above

* **`cancho-schema` needed more than one function.** `check_text`, `int_of_text` and `bool_of_text` (its design §14), and then
  `is_int`, `is_bool` and `is_string`, because a slot keeps the value in the shape its node says and `web` had no way to ask. And the
  first merge forgot to republish the store consumers build from, so nothing could use them: it now has a CI step that fails when
  the committed store is not what the source publishes.
* **One error per parameter, the first, and `range` instead of a 17-digit cap** (decided in `cancho-schema` §14). The cap came
  from the hand-written `number_of`; a cap the node does not state is the defect §7 describes.
* **A value is judged decoded.** Percent-decoding needs a destination, so `dispatch` takes a `scratch` the caller allocates once
  (the example gives it 256 bytes); a path or query value that is longer is `max_length`, whatever its kind, and a bad escape is
  `type`. In a query `+` is a space; in a path it is not; a header is judged as sent (`%zz` is three characters of one). The change
  that follows is visible: `/users?limit=%35` was a 422 and is a 200, and `/users/%35` is user 5.
* **An operation that declares no query parameter ignores its query string, as before.** The design said "a query key the operation
  did not declare" for every operation. `GET /health?x=1` would then be a 422 the document does not declare for `/health`, and the
  contract test (every response must be declared) would be right to fail it. An operation that declares any query parameter is closed.
  An empty pair (`a=1&&b=2`, or `&`) is a key with no name and is unknown, as `query_keys_known` had it; a trailing `&` is not.
* **No defaults** (§9.3, §9.9).
* **404 and 405 moved into `dispatch`**, byte for byte as `handle` wrote them: the 404 as `problem+json`, the 405 as `{"error":"method not
  allowed"}` with `Allow`, which is not `problem+json` and is not in the document; it was that before and was not changed here.
* **Two passes, not one.** `judge` answers whether anything is wrong and allocates nothing; only a request that fails runs
  `explain`, which writes the entries. The first version ran one function with a buffer in both cases and allocated an empty buffer per
  request; that was part of the first measurement's 6%.
* **Generating the document was the slow part of a large API, and was found only because the benchmark declared one.** `op_at` scanned every record; it is an index lookup now (see §8's correction). A request, by contrast, costs the same in an API of 6, 206 and 2,006 operations, within the noise (`docs/benchmarks.md`).
* **The declaration has an index now.** Each operation's parameters are a chain through their records and `Api` keeps, for each operation, where its
  record and its first parameter are. Before it, `dispatch` scanned the whole declaration per request. This is the claim of §8 ("declaring is
  `O(1)`") made true for reading as well: dispatch costs the parameters of one operation.
* **The unit tests were first written in HTTP/1.1 and trapped:** `http.parse` requires a `Host` header there. They are HTTP/1.0.
* **Mutations.** Twenty changes to `dispatch` and the code under it (the unknown-key pass off, the duplicate check off, a required
  parameter ignored, both bounds off, the header looked up by its declared case, the path offset without its start, `+` not a space,
  the two codes of the scratch room swapped, the second capture read as the first, the pointer not escaped, the first error not
  listed, the `Allow` header lost, a bool read inverted, a header decoded, the empty pair skipped, the chain cut after one
  parameter, a parameter not linked to its operation, an unknown key given the wrong place) each fail at least one test. The
  first round missed one: no test said a header is not decoded; it has one now.
* **Not converted:** `examples/users_pg` and `examples/users_threads` keep `web.find` and their own checks, so their answer to a bad
  parameter is the old sentence and `users_pg` could not be built or run here (no PostgreSQL server). The suites assert a status and the contract, not a sentence, so
  they agree on everything they check; the README's "byte for byte" is qualified.
