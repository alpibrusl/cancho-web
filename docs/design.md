# cancho-web: a FastAPI-shaped layer for cancho

> **Status: design, one real example built (§7), and its declaration half extracted (§8)**:
> `src/web.cho` writes the router and the OpenAPI document from one declaration. Dispatch and
> middleware are not built; the first section says what this does *not* try to be. §9 designs the
> next slice (parameters validated by construction).

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
| `async`/`await` | **not done.** One thread, a `Poller`, no blocking call; more cores by `reuseport` and more processes |

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
3. **Streaming.** `http.server` hands over whole requests. Bodies larger than
   its buffer (413 today), `Expect: 100-continue` and TLS are its open items
   (`cancho` `docs/server.md` §6), and this layer inherits them.

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

**What the example does not test yet:** TLS, streaming bodies, more than one core.

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
`Vec[int]` of 8-int records: declaring is `O(1)`, `openapi` scans them once at start-up.

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

* **It does not dispatch.** The application keeps its loop and its `if` on the id, for the reason
  in §2: a callback cannot be handed a view of the loop's buffers. A named constant per id, checked
  against what `operation` returned at start-up, would remove the one remaining way for the `if`
  and the declaration to disagree; it is not built.
* **It does not validate parameters for the handler.** `route.param_nat` and `http.query_value` are
  still the handler's, and a path or query parameter that fails its declared schema is still a check
  the handler makes -- although the declaration now says what that schema is. Making a bad
  parameter a `422` by construction is the next slice, and needs a place to put the answer; the
  declaration has the information, the dispatch does not exist yet. §9 designs it.
* **Responses are documented, not enforced.** `respond` says what a handler may answer; nothing
  checks that it did. The contract test does, per request, from outside.

## 9. Parameters by construction (design, not built)

> **Status: design.** Nothing here exists yet. Every number below is a figure from the
> current code or `docs/benchmarks.md`; the costs of the new code are *to be measured* (§9.7),
> not promised.

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
let (answer, id) = web.dispatch(heap, api, sc, request, table, params, args, out, keep);
if id >= 0 {
    // the route matched and every declared parameter is valid; read them from `args`
    let limit  = web.int(args, limit_slot);          // present or defaulted: always a valid int here
    let offset = web.int(args, offset_slot);
} // else: `answer` already holds the 404, 405 or 422; send it
```

* **`id >= 0`**: the handler runs. `out` is untouched. For each declared parameter of that
  operation, `args` holds two ints (§9.3), in declaration order.
* **`id < 0`**: dispatch has already written the whole answer to `out` -- the 404 for no such
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
(a handler's request is a borrowed view of the loop's buffers). Percent-decoding stays the
handler's, through `route.param_decoded` and `http.percent_decode`, as today; whether dispatch
should offer it is §9.9.

A parameter that is required and absent never reaches a slot (422). An optional one with no
default has `b = 0`, and the handler asks `web.present`. A **default** is a declaration
(`web.default_int(heap, api, op, "limit", 20)`), written to the OpenAPI schema as `default` and
applied by dispatch -- so `default_limit()` stops being a second copy of a number the document
states.

### 9.4 What dispatch checks, and what it answers

For the matched operation only, in this order, collecting **every** error as `validate` does for
bodies:

| code | when |
|---|---|
| `required` | a required query or header parameter is absent |
| `unknown` | a query key the operation did not declare (the rule `query_keys_known` encodes today) |
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

### 9.7 What must be shown before this is called done

1. **The contract does not move.** `examples/users/openapi.json` is byte-identical (`cmp`), the
   same fixed point §8 used.
2. **The answers do not move, except one.** The existing 27 end-to-end tests, Schemathesis
   included, pass; the single change is the 422 `detail` for a bad parameter, which becomes the
   `errors` list above. That test is rewritten, and the change is listed in the commit.
3. **A rule tag per refusal.** `tests/web_test.cho` has a case for each code in §9.4, for each
   place (path, query, header), and for several errors at once; plus the cases that must *not*
   refuse (a declared key, a default applied, an optional absent, a 17-digit value at the range).
4. **No input reaches a panic.** A table of hostile parameter text (empty, 18 digits, a lone
   `-`, `%`, an embedded NUL, a very long query, 10,000 repeated keys) against every operation of
   both examples, expecting a `422` or success, never a trap. The long-query case checks that
   dispatch is linear in the query length.
5. **The cost, measured, not argued.** The benchmark's GET one (128,972 requests a second) and
   page of 20 (70,768) must stay within the run-to-run spread (about 5%) of those figures, on the
   same VM, alternated, three rounds, as §8 did; the rejected-body case (94,659) must not move.
   Dispatch parses the integer once where the handler did, so the expectation is neutral, and if
   it is not, the table says by how much and the claim here is corrected in place.

### 9.8 What this deliberately is not

* **Not bodies.** A body gives the handler a tape and its slots, an allocation per request and a
  different shape; parameters are a few ints. Bodies are the next slice, and they reuse the idiom
  (`web.dispatch` would also fill the body's `slots`), but they are not designed here.
* **Not dependency injection**, and not middleware: nothing runs but the checks the declaration
  already states. A handler's authority is still its signature.
* **Not a new way to say a route.** `web.operation`, `web.find`, `web.openapi` and every
  existing `*_param` call are unchanged; a service that keeps calling `web.find` keeps working.
  Dispatch is additive, and `web.find` remains the thing it calls.

### 9.9 Open questions

1. **Offsets or decoded text.** Percent-decoding needs a destination buffer, which dispatch does
   not have without an allocation; handing back raw offsets keeps it free. A `decoded` variant
   would need a per-request scratch buffer in `args`' owner. Defer until a service needs it.
2. **`pointer` for a parameter.** `/query/limit` (no contract change) or additive `in` and `name`
   members (contract changes, `Problem` gains two optional fields). Chosen: the first, for the
   fixed point; to be revisited if a client is found that dislikes it.
3. **Leading zeros and `-0`.** Accepted today; a stricter rule is a contract change and belongs
   in a slice of its own, with Schemathesis's view of it.
4. **Generated constants for ids and slots** (§9.2, first row). If hand-written `let limit_slot =
   web.slot(...)` lines turn out to be what people mind, a `pgen`-style tool is the answer; not
   before there is a service that does.
5. **Headers.** The slot table covers them identically (`b = 0` when absent), but header names
   are case-insensitive and `http.header` is the existing lookup; `lexsys-hooks`'s
   `Idempotency-Key` is the case to design against.
