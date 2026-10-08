# The users API against FastAPI, Go and C

> **Status: measured, on one machine** (the numbers below are from a 4-vCPU
> Firecracker VM, Intel Xeon 2.1 GHz, Linux 6.18, Python 3.11, FastAPI 0.142,
> uvicorn 0.54, Go 1.24). Repeats of the same configuration on this VM differ by
> about 5% (the C ceiling alone ranged 131,000-142,000), so treat differences
> smaller than that as ties, the *ratios* as the finding and the absolute figures
> as this VM's. `benches/run.sh` reproduces them.
>
> Sections 1-2 are the FastAPI comparison; the Go and C comparison is
> [below](#against-go-and-a-hand-written-c-server).
>
> **These are the tables of the first run.** The run of 2026-10-08, on the current code and a slower VM, and the two-core comparison are at
> [the end](#the-run-of-2026-10-08-and-what-changed-since-the-first); the README and the project page quote that run.

## What is compared

`examples/users` (this repository, over `http.server` and `cancho-schema`) and the
same API written the ordinary way in FastAPI + pydantic (`benches/fastapi_users/app.py`):
the same routes, the same limits, the same validation rules. They are held to *do the
same work* before either is timed: `benches/equivalent.py` sends both the same sixteen
requests -- valid and invalid, reads, pages, a 404, a limit past its range -- and the
run refuses to start unless every status agrees and every successful body is equal.
(Error *documents* differ by design: FastAPI has its own 422 shape, this service answers
RFC 9457; only their status is compared.)

FastAPI is measured three ways, because "FastAPI" is not one number:

| | |
|---|---|
| **uvicorn (asyncio)** | `uvicorn app:app` -- what the tutorial runs |
| **uvloop + httptools** | `--loop uvloop --http httptools` -- the faster setup the documentation recommends |
| **lean** | the same, and handlers return the stored bytes instead of going through a `response_model`: the least work an honest FastAPI handler can do |

Each server runs **alone on core 0**; the load generator (`benches/kload.c`, two threads
of 16 keep-alive connections, closed loop, one request outstanding per connection) runs
on cores 2 and 3. A request is 5 seconds of load, three times, median; "create" is a fixed
30,000 requests from a fresh process (it adds state, so "as many as fit in 5 s" would fill
the store).

## Results

Requests a second, median of 3:

| | GET one user | GET a page of 20 | POST, invalid (422) | POST, create |
|---|---:|---:|---:|---:|
| **cancho users** | **128,972** | **70,768** | **94,659** | **64,327** |
| FastAPI, uvicorn (asyncio) | 4,828 | 4,028 | 3,545 | 4,091 |
| FastAPI, uvloop + httptools | 4,851 | 4,208 | 3,456 | 4,129 |
| FastAPI lean, uvloop + httptools | 5,216 | 4,604 | 3,606 | 4,163 |

About **25x** on a read, **15x** on a page, **26x** on a rejected body and **15x** on a
create, against the best FastAPI figure in each column. (These are the figures of the run
after the page endpoint was fixed, see "Against Go" below; the first run of this document
had the page at 39,350, 9x. Create is the noisiest column: identical binaries span
65,000-79,000 across runs, so 15-18x is the honest range there.)

Latency of `GET one user` under that load (32 requests in flight, so each figure is a
service time *plus the queue of the others*):

| | p50 | p90 | p99 | p99.9 | max |
|---|---:|---:|---:|---:|---:|
| cancho users | 156 µs | 270 µs | 442 µs | 1.1 ms | 17.0 ms |
| FastAPI, uvicorn | 5.2 ms | 8.3 ms | 11.8 ms | 14.8 ms | 17.3 ms |

## How to read it

* **It is one core against one core.** Neither server uses a second; FastAPI is normally
  run with several worker processes, and cancho with `reuseport` copies. Per-core is the
  fair comparison and not what a deployment does. *Two cores each are measured below ([Two cores each](#two-cores-each-2026-10-08)): the gap narrows from 23-27x to 19-25x and does not close.*
* **FastAPI is CPU-bound in Python, not in its server.** uvloop and httptools, which speed
  up the network layer, change almost nothing (they are within noise of plain asyncio, and
  slightly lower on two columns), and the lean variant -- no response validation -- gains
  about 10%. What is left is routing, dependency resolution and pydantic.
* **The page was the narrowest gap, and the reason was in the service -- since fixed.**
  Listing 20 users spliced 20 stored JSON values through `json.put_fragment`, each checked
  by the strict parser, though each was the program's own canonical output. Splicing them
  as bytes took the page from about 40,000 to 62,000 requests a second, and a one-pass
  `std.buffer.append` (cancho `docs/http-server.md` §9) to 71,000.
* **Nothing here measures TLS, a database, or a real handler's work.** A service that
  spends 5 ms in a query is 5 ms slower in both. The comparison is of the *framework's
  own* cost per request, which is what a framework chooses.
* **A load generator is code too.** `kload` found a bug in itself on the first FastAPI
  run: it matched `Content-Length:` case-sensitively, and uvicorn sends it lowercase, so
  the body of every answer was left unread and counted as the next response. The
  figures looked plausible (about 5,000 a second) and were wrong in a way that happened
  to land near the right answer. It was caught only because the generator now checks every
  status against the one expected (`KLOAD_EXPECT`) and fails the run, and it now matches
  headers case-insensitively. A benchmark that cannot fail is not a measurement.

## Reproducing

```
pip install fastapi uvicorn uvloop httptools
CANCHO=/path/to/cancho benches/run.sh 3        # needs >= 4 cores for the pinning
```

## Against Go and a hand-written C server

FastAPI is a weak yardstick for speed: beating it by 9-26x says mostly that Python's
cost per request is high. These add two compiled peers and a bound, so that a number is
a position and not only a ratio.

| | |
|---|---|
| **Go `net/http`** (`benches/go_users`) | the standard library only: `net/http`, `encoding/json` into a struct, hand-written range checks (it has no validator), a mutex around the store. Default GC; one core visible (`taskset`) so `GOMAXPROCS` is 1. Written the ordinary way, not the fastest way Go can do it |
| **C floor** (`benches/c_floor/floor.c`) | one thread, one epoll loop, a parser that knows four routes, and a JSON reader that validates and writes the stored answer in one pass because it knows this schema and no other. Not a framework and not a proven minimum -- a hand-written baseline |
| **C ceiling** (`benches/c_floor/ceiling.c`) | an epoll server that answers every read with the same canned 200: no parsing, no state. It is the most one core can do over loopback TCP (`epoll_wait`, `read`, `send`) and answers GET one user only |

Same method as before, and the same gate: `benches/equivalent.py` sends the 16 requests to
cancho, Go, the C floor and FastAPI and refuses to start timing unless every status and
every successful body agrees; `benches/edges.py` adds 84 more (code-point lengths with
escapes and astral characters, both ends of every range, malformed JSON, content types,
query strings) for the three implementations whose validators are hand-written. Both are
part of `run.sh`, and both found things (below).

### Results

Requests a second, median of 3 (the FastAPI row is the best of its three set-ups in each
column; the figures are of the run after the page endpoint was fixed):

| | GET one user | GET a page of 20 | POST, invalid (422) | POST, create |
|---|---:|---:|---:|---:|
| C ceiling (canned reply) | 137,180 | -- | -- | -- |
| C floor | 117,958 | 105,523 | 107,680 | 91,783 |
| **cancho users** | **128,972** | **70,768** | **94,659** | **64,327** |
| Go `net/http` | 79,772 | 65,654 | 60,278 | 53,580 |
| FastAPI, best of three | 5,216 | 4,604 | 3,606 | 4,163 |

| cancho against | GET one | page | invalid | create |
|---|---:|---:|---:|---:|
| Go | **1.6x** | **1.08x** | **1.6x** | **1.2x** |
| C floor | 1.09x (a tie) | 0.67x | 0.88x | 0.70x |
| C ceiling | 0.94x | | | |

Latency of GET one user under the same load (32 requests in flight; microseconds):

| | p50 | p90 | p99 | p99.9 | max |
|---|---:|---:|---:|---:|---:|
| C ceiling | 137 | 222 | 404 | 1,513 | 35,118 |
| cancho users | 156 | 270 | 442 | 1,140 | 16,995 |
| C floor | 178 | 269 | 433 | 1,158 | 19,645 |
| Go `net/http` | 325 | 483 | 850 | 1,770 | 6,937 |
| FastAPI, uvicorn | 5,161 | 8,318 | 11,842 | 14,805 | 17,341 |

### What it says

* **On a read, cancho is where a hand-written C server is, and at 94% of the kernel's
  limit.** The ceiling shows why there is little room above: one core spends about 7
  microseconds a request in the socket path, `epoll_wait`, `read` and `send`, before any
  server code runs. The C floor being no faster than cancho on a read is not a claim that
  cancho beats C -- the floor formats its headers with `snprintf` and was not tuned further;
  it is a reminder that the floor is a hand-written baseline, and the ceiling is the bound.
* **It is ahead of Go on every workload**, by 1.6x on a read and a rejected body, 1.2x on a
  create, and 1.08x on a page (within noise there), with half the p99. That is Go's
  goroutine-per-connection runtime and GC on one core, against a loop with neither; it is
  not a statement about Go with several cores, which was not measured.
* **The page was where cancho lost, twice over, and both causes were found by this
  comparison.** The first run had it at 40,755, 0.62x of Go and 0.41x of the C floor. The
  application re-parsed each stored user with the strict parser although it had itself
  rendered it (fixed: the users are spliced as bytes, 62,000), and `std.buffer.append` copied a
  byte at a time through `push`, which checks the capacity and rebuilds the buffer for every
  byte (fixed in cancho: 71,000). What remains against the C floor (0.67x) is the same shape:
  the page is still copied twice as bytes, once into the page and once into the reply, and the
  language has no slice-copy primitive (`bulk-io.md` §4 there).
* **On a create or a rejected body cancho serves 12-30% fewer requests than the C floor.**
  Probably because it parses, validates and writes the canonical answer in separate passes
  where the floor does all three in one; that was not profiled. Create is also the noisiest
  workload: the same two binaries, alternated, gave 65,209-78,951 on a create.
* **The load generator was checked, not assumed.** `kload` used about 3.4 s of CPU in 5 on its
  two cores, and giving it a third core did not raise the ceiling's throughput (131,000-142,000
  either way), so it is not what limits the figures in this table. (It could not read a
  response over 4 KB until this change -- a page of 50 users or more -- and now reads 64 KiB.)

### What the cross-checks found

Writing two more implementations against the same gate found differences in the *reference*
as well as the new code, which is what a differential check is for:

* **A repeated key.** `{"name":"first","name":"second"}`: the cancho service keeps the
  **first**, Go and the C floor keep the last, and so does pydantic, which is what most
  clients expect of "last one wins". RFC 8259 leaves it open; the service's choice is a
  quirk worth deciding on, not a bug in the others. Shown by `edges.py`, not counted.
* **A lone surrogate** (`"\ud83d"`): the cancho service answers 400, as does the C floor
  (after the check found it accepting one); Go accepts it and stores U+FFFD. Not counted.
* **The C floor's own bugs**, found by the same check and fixed: a loose number scanner
  that turned `"age":-` into a 422 instead of a 400, and one `epoll_ctl` call per request
  (a syscall too many, worth about 10% on a read).
* **The C floor under AddressSanitizer and UBSan**, with 300 random and truncated requests
  as well as both check scripts, ran clean.

### What is not measured

Go with more than one core, or with Gin or fasthttp; Rust (axum on tokio); Node (Fastify);
a second core for cancho (`reuseport` copies); TLS; a real handler's work; resident memory
and start-up time. The Go and C servers leave out `/openapi.json`, and the C server also
chunked request bodies, and neither reads `150.0` as an integer as cancho does -- none of it
is on a benchmarked path.

## On PostgreSQL

`examples/users_pg` is the same API with PostgreSQL as its store (`cancho-pg`'s driver, queries written
by `pgen` from `examples/users_pg/queries.sql`). It is compared with the same API in FastAPI twice,
because "FastAPI with a database" is not one number either:

| | |
|---|---|
| **cancho `users_pg`** | one connection, opened and logged in before it listens; every request that needs the database makes a **blocking** round trip on it (`http.server` is one loop, so the loop waits) |
| **FastAPI + SQLAlchemy 2 (async) + asyncpg** | what most FastAPI code with a database looks like: a session per request from a pool of 10, the ORM, a `response_model` |
| **FastAPI + asyncpg, lean** | a pool of 10 asyncpg connections, the same SQL as `queries.sql`, answers built without a model |

The work is held equal before anything is timed: `equivalent.py` sends all three the same sixteen
requests, each against its own fresh database, and the run stops unless statuses and successful bodies
agree. (`name` and `email` refuse U+0000 in all three: PostgreSQL text cannot hold it; see
`cancho-schema`'s design.md §13.) The server under test is on core 0, **PostgreSQL on core 1**, the load
generator on cores 2 and 3, so the three do not share a core. Everything else is as above: 5 seconds of
load, median of 3, "create" a fixed 20,000 requests against a fresh table (it adds state).
`benches/run_pg.sh` reproduces it. PostgreSQL 16, default settings (`fsync` on), on the same VM.

### Results

Requests a second:

| | GET one user | GET a page of 20 | POST, invalid (422) | POST, create |
|---|---:|---:|---:|---:|
| **cancho `users_pg`** | **10,214** | **3,916** | **93,724** | **2,676** |
| FastAPI + SQLAlchemy + asyncpg | 1,040 | 572 | 3,273 | 809 |
| FastAPI + asyncpg, lean | 2,953 | 1,952 | 3,360 | 2,375 |

Latency of `GET one user` (32 requests in flight): cancho p50 2.3 ms, p99 5.0 ms; lean FastAPI p50 8.1 ms,
p99 25.9 ms; FastAPI + SQLAlchemy p50 21.8 ms, p99 58.2 ms.

And what PostgreSQL does alone on its core (`pgbench`, libpq, 16 clients, the same row lookup and the same
insert; no HTTP, no framework), transactions a second:

| protocol | get one row | insert |
|---|---:|---:|
| simple query | 15,012 | 8,975 |
| extended, parse every time (what `pg.extended` sends) | 12,577 | 8,304 |
| extended, prepared once | 26,787 | 12,159 |

### What it says

* **A read is PostgreSQL-bound, and cancho is close to the bound.** 10,214 requests a second is 81% of the
  12,577 that PostgreSQL itself answers over the same protocol, with the HTTP server, the JSON and the
  validation on top. Subtracting the 7.8 microseconds an in-memory read costs (129,000 a second, above) leaves
  **about 90 microseconds of loop time for one blocking round trip** to a PostgreSQL on its own core -- the
  low end of the 100-300 microseconds `cancho-pg`'s design.md estimated before anything was measured.
  FastAPI's lean variant saturates its core (91% in `top` under this load; 2,953 a second, 3.5x slower) and the
  SQLAlchemy one is slower still (9.8x). The comparison with FastAPI is therefore mostly a comparison of
  what each spends *around* the query, and that is where the 3-10x is.
* **The headroom is in the driver, not the language.** `pg.extended` sends Parse every time. PostgreSQL does
  2.1x as many one-row lookups a second when the statement is prepared once (26,787 against 12,577), and
  asyncpg, and so both FastAPI variants, already do that. So this service pays twice the database work per query
  that its competitors do, and wins. Prepare-once was the first thing to build; it is built, and
  [measured below](#prepared-statements).
* **A write is not CPU-bound: it waits for `fsync`.** One connection makes one commit at a time: 2,676 creates
  a second is about **370 microseconds each**, with the loop blocked the whole time (so a read behind a write
  waits too). *Correction:* this paragraph went on to say that preparing the statement took about 140 of those
  microseconds off. That was read from one median of three that was at the top of a very wide range
  ([below](#copies-of-the-blocking-service): ten runs of the same build span 2.1k to 4.2k creates a second), and
  is withdrawn: what a prepared `INSERT` saves is **not established** here. `pgbench`'s 16 clients get 8,304 inserts
  a second because PostgreSQL commits several of them per `fsync` (group commit); one connection never can.
  Lean FastAPI has ten connections and reaches 2,375 a second, where Python, not the database, is the limit
  (it was at its core's limit on reads; not separately measured here for writes). A service
  with a real write workload wants a **pool** and a connection that does not block the loop -- the
  non-blocking-connection slice of `cancho-pg` (design.md §5) -- and this is the number that says so.
* **A page is two round trips** (a count and a page of 20), 3,916 a second against 1,952 lean: 2.0x, with the
  same 2.1x of prepare-once to come. Not compared with a floor: `pgbench` was only asked for a lookup and an insert.
* **A rejected body does not touch the database** (93,724 against 3,273-3,360: 28x), which is the in-memory
  ratio again and a check that adding a database did not slow the path that never reaches it.

### What is not measured, and what would change it

* **One machine, one disk.** `fsync` latency is this VM's; the create column in particular will differ on other
  storage, and `synchronous_commit=off` would change it (and what it means). Repeats differ by about 5%, create by
  more.
* **A PostgreSQL on its own core.** With it sharing the server's core, a blocking client and an asynchronous one
  would both slow down, and not by the same amount.
* **Pool sizes** other than 10 for FastAPI, and a cancho service with more than one connection (which it could not
  have until the connection stopped blocking the loop; it can now: [below](#a-pool-in-one-process)).
* **Go, Rust and Node** with a database; and the cost of TLS to PostgreSQL, which `cancho-pg` cannot do yet.

### Prepared statements

`pgen` now writes `prepare_all` and every generated function runs its statement by name (cancho-pg, design.md
section 9): PostgreSQL parses and plans each query once per connection instead of on every call. The same run
times both builds of `users_pg` -- the one that parses on every call (the numbers above) and the one that does
not -- with the FastAPI services and `pgbench` in the same session, same machine, same pinning:

| requests a second, median of 3 (the create column is noisy: see below) | GET one user | GET a page of 20 | POST, invalid (422) | POST, create |
|---|---:|---:|---:|---:|
| **cancho `users_pg`, prepared** | **14,976** | **4,496** | **95,328** | **4,404** |
| cancho `users_pg`, parsing every call (before) | 9,788 | 3,865 | 90,902 | 2,748 |
| FastAPI + asyncpg, lean | 2,918 | 1,961 | 3,337 | 2,657 |
| FastAPI + SQLAlchemy + asyncpg | 1,078 | 582 | 3,238 | 846 |

Latency of `GET one user`: prepared p50 1.5 ms, p90 2.2 ms, p99 5.2 ms (a tail of 55 ms at p99.9 and 105 ms at
the maximum, which the unprepared build does not have: 7.9 and 11.4 ms; not investigated); before p50 2.4 ms,
p99 4.7 ms; lean FastAPI p50 8.0 ms, p99 25.3 ms. `pgbench` in this session, the same lookup: 12,635 a second
parsing every time, **24,717 prepared**; the same insert: 8,960 and 11,705.

* **A read is 53% faster** (14,976 against 9,788), **5.1x lean FastAPI** (13.9x the SQLAlchemy one). The
  repeat of the "before" build is within 4% of the first measurement (10,214, 3,916, 93,724, 2,676), so the
  machine did not drift between the two sets.
* **It is no longer PostgreSQL-bound.** Before, a read was at 77% of what PostgreSQL itself did over the same
  protocol (9,788 of 12,635). Now it is at 61% of the prepared ceiling (14,976 of 24,717): a request takes 67
  microseconds, about 8 of them the service's own work, and PostgreSQL needs 40 of them (1 / 24,717), so the
  remaining ~19 are PostgreSQL's core sitting idle while the single loop parses the next HTTP request and
  renders the answer. That idle is what one blocking connection costs once the database is fast, and what a
  pool or a connection that does not block the loop would fill (cancho-pg design.md section 5).
* **A page gained 16%** (3,865 to 4,496; smaller than a read's gain, and its repeats agree within a few percent), not 53%: it is two round trips (80 of its 222 microseconds at the prepared ceiling) and
  the rest is the service rendering 20 rows, each through a JSON writer and a validated fragment for its tags.
  Not profiled here; it is where to look next for that endpoint.
* **A create: no conclusion.** 4,404 against 2,748 looked like a 60% gain, and I wrote it up as one. It is not
  one: re-running the prepared build alone, ten runs at one copy gave 2,155 to 4,245 creates a second (medians of
  five: 2,746 and 2,609), so 4,404 was the top of the noise and 2,748 sits in the middle of it. Writes depend on
  the disk's state in a way reads do not. What a create costs, and whether preparing helps it, needs many more runs
  than three; only the reads and pages above are measured well enough to compare.
* **A rejected body** (no database) is unchanged, 95,328 against 90,902, within noise: nothing here touched that path.

Reproduce with `UNPREPARED_BIN=<the older build> benches/run_pg.sh` (it adds the "before" row).

### Copies of the blocking service

The cheapest way past one blocking connection needs no new code: run several copies of the service on the same
core, sharing a port (`SO_REUSEPORT`, the service's eighth argument; the kernel spreads the connections). Each
copy has its own database connection, so while one waits for PostgreSQL another runs. All copies are pinned to
the one core the single service had; PostgreSQL stays on its own and the load generator on two more.
`benches/run_pg_copies.sh` reproduces it; requests a second, median of 3 (creates: see below):

| copies on core 0 | GET one user | GET a page of 20 | POST, create |
|---:|---:|---:|---:|
| 1 | 15,011 | 4,764 | 2,634 |
| 2 | 22,604 | 5,456 | 4,048 |
| 3 | **24,211** | **6,224** | 4,298 |
| 4 | 23,881 | 5,852 | 5,685 |

* **Two copies take a read from 61% of PostgreSQL's prepared ceiling to 91% of it** (22,604 of 24,717), and three
  reach it (24,211): the idle ~19 microseconds the previous section found are filled by the other copy's work. More
  than three adds nothing, because PostgreSQL is then the limit, and nothing is lost: the copies cost memory, not
  throughput. So on a read-heavy service the blocking model, with a handful of copies, is within a few percent
  of PostgreSQL itself, and the single loop's ceiling is not the problem it looked like.
  > **Corrected (see [A pool in one process](#a-pool-in-one-process)).** "PostgreSQL's prepared ceiling" in this
  > bullet is the 24,717 a second that `pgbench` reaches, which pays a round trip per query. It is not a ceiling:
  > one pipelined connection reaches 64,000-66,000 a second on the same lookup, so "three copies are within a few
  > percent of PostgreSQL itself" was wrong, and what the copies fill is a gap that pipelining fills better.
* **A page** gains 31% at three copies (4,764 to 6,224): it is the one workload whose limit is the service's own
  rendering, which copies on one core do not shorten.
* **A write gains, and by more than the reads' pattern predicts.** Creates are noisy (above), so these are ten
  runs each at one and at four copies, medians of five twice: **one copy 2,746 and 2,609; four copies 6,659 and
  6,290**, runs from 4.9k to 7.2k at four and from 2.2k to 4.2k at one. Concurrent connections let PostgreSQL commit
  several inserts per `fsync` (`pgbench`, 16 clients: 11,705); one connection cannot, and a single non-blocking
  connection that *pipelines* its queries still commits them one `Sync` at a time. This is the case for several
  connections, not for non-blocking I/O as such.
* **What this does not buy.** Copies share nothing: no cache, no counters, no connection pool a request could
  borrow from, each holds its own PostgreSQL backend (a server's `max_connections` is a limit), and a query that
  takes a second still blocks *that copy's* clients. A service with state in memory, or with slow queries, wants the
  loop to keep serving while a query is pending -- which is the design in cancho-pg's `docs/nonblocking.md`.

### A pool in one process

`users_pg` with a ninth argument -- `users_pg <port> <host> <port> <user> <db> <password|-> <reuseport|-> <n>` -- holds
`n` database connections in a `pg.pool` (`cancho-pg`, `docs/nonblocking.md`) and no longer waits for any of them: a
request that needs the database is held (`http.server`'s `hold`), its query is queued, the loop goes on to the next
request, and the held one is answered when the poller says the reply is in. Every handler is two halves (`begin`
checks the request and encodes the query, `conclude` reads the reply), which the blocking service runs back to back.
The same 29 tests pass against both, with 6 more for the pool (`tests/e2e.py`, `USERS_PG_POOL=n` runs the whole
suite against it); the same 24 requests get byte-identical answers from both.

**The property that was missing.** A query held behind a table lock for a second; 100 `GET /health` to the same
process meanwhile: the pool's median 0.14 ms and **maximum 0.76 ms**; the blocking service **645 ms**.

**Throughput.** Server on core 0, PostgreSQL on core 1, `kload` on cores 2 and 3; requests a second, the same
session, median of three 5-second rounds for reads and a page, and ten runs for creates (`benches/run_pool.sh`;
`benches/run_pg_copies.sh` for the copies):

| | GET one user | GET a page of 20 | POST, create (median of 10; range) |
|---|---:|---:|---:|
| blocking, 1 copy | 15,638 | 4,524 | 2,317 (3 runs) |
| blocking, 3 copies on core 0 | 25,180 | 6,361 | 7,065 (3 runs) |
| blocking, 4 copies on core 0 | | | 5,818 (4,528-8,329) |
| **pool, 1 connection** | **63,980 / 65,894 / 64,262** (three runs) | 7,894-8,409 | 3,818 (3,190-5,306) |
| pool, 2 connections | 58,681 | 8,169 | 5,266 (4,659-7,555) |
| **pool, 4 connections** | 45,056 | 7,420 | **8,091 (6,836-10,776)** |

* **A read: one connection is 4.1x the blocking service and 2.5x three copies.** The ~19 microseconds of
  PostgreSQL idling per query that copies fill with other work, a pipelining connection never creates: the queue is
  never empty. This is more than the ceiling the previous sections used (24,717, `pgbench`'s: one query, one round
  trip), which is why that figure is corrected above.
* **More connections make reads slower** (65,000 to 45,000 from one to four): PostgreSQL's backends share its one
  core, and four of them switch where one pipelines. Reads want one connection, writes several.
* **A write wants the pool of four, and beats four copies on the median** (8,091 against 5,818, 39% more) **with
  ranges that overlap** (the best copy run, 8,329, is above the pool's median). It does it with one process,
  one core and four backends, not four processes; creates are the noisiest column here, so read the ranges.
* **A page is two round trips and gains less** (about 8,000 against 4,524 blocking, 1.8x): its limit is the service's
  own rendering, as with copies.
* **What it does not buy.** A slow query holds up the requests queued behind it *on its own connection* (in order),
  not the others; there is no reconnecting after a database restart (database routes answer 503 until the service is
  restarted) and no per-request deadline. `cancho-pg`'s `docs/nonblocking.md` section 9 lists what is open.

The client under this service, one connection against libpq and the Python clients, is in that document too
(section 9.2): level with libpq one query at a time, about 2.3x slower pipelined, cause not found.

### Two threads in one process

[`examples/users_threads`](../examples/users_threads/users_threads.cho) runs the unchanged `users` loop in two threads, one `SO_REUSEPORT` listener, forked heap and forked clock each (cancho `docs/parallelism.md` section 9). Same workload as "Copies of the blocking service" (invalid `POST /users`, server on cores 0-1, load generator on 2-3), interleaved with two processes in three rounds of five runs: **threads 149,380 a second** (median of 15), **processes 141,208**; the ranges overlap almost completely, so the result is that threads are *not worse*, not that they are faster. A stateless service shares nothing either way; what threads add is the possibility of sharing a store, which is not built (each thread keeps its own, so this example is not a deployable service). Reproduced by cancho's `benches/parallel/threads_users.sh`.


## The run of 2026-10-08, and what changed since the first

The tables above are the first run. It was measured before `web.dispatch` and the schema changes, on a faster VM. Everything was run again, in one
session (`benches/run.sh 3`), on the code of this branch and the VM of the section below. The equivalence gate passed for every implementation (the same 16
requests and the same 84 more); FastAPI 0.142.4, uvicorn 0.53.0, uvloop 0.23.0, Go 1.24.7, the pinned cancho compiler. Same method as above: one core
each, `kload` on cores 2 and 3, five seconds, three times, median.

| requests a second, median of 3 | GET one user | GET a page of 20 | POST, invalid (422) | POST, create |
|---|---:|---:|---:|---:|
| C ceiling (a canned reply) | 90,700 | -- | -- | -- |
| hand-written C (epoll) | 75,734 | 68,144 | 67,376 | 60,719 |
| **cancho users** | **83,289** | **75,286** | **63,241** | **53,755** |
| Go `net/http` | 65,216 | 53,792 | 47,011 | 41,051 |
| FastAPI, uvicorn (asyncio) | 4,374 | 3,852 | 3,456 | 3,751 |
| FastAPI, uvloop + httptools | 4,528 | 4,009 | 3,385 | 3,801 |
| FastAPI lean, uvloop + httptools | 4,921 | 4,307 | 3,536 | 3,948 |

| cancho against | GET one | page | invalid | create |
|---|---:|---:|---:|---:|
| FastAPI, best of three | 16.9x | 17.5x | 17.9x | 13.6x |
| Go | 1.28x | 1.40x | 1.35x | 1.31x |
| C floor | 1.10x | 1.10x | 0.94x | 0.89x |
| C ceiling | 0.92x | | | |

Latency of GET one user under that load (32 requests in flight; microseconds):

| | p50 | p90 | p99 | p99.9 | max |
|---|---:|---:|---:|---:|---:|
| C ceiling | 224 | 298 | 478 | 1,217 | 2,729 |
| C floor | 278 | 369 | 518 | 953 | 3,435 |
| cancho users | 249 | 322 | 547 | 1,815 | 6,038 |
| Go `net/http` | 393 | 460 | 841 | 1,303 | 4,087 |
| FastAPI, uvicorn | 5,406 | 8,391 | 10,763 | 17,877 | 42,171 |

**Which numbers change, and which do not.**

* **This VM is slower than the first run's**: the ceiling is 90,700 here and was 137,180, and cancho's read is 0.65x of what it was (83,289 against 128,972). **FastAPI
  barely moved** (4,921 against 5,216, 0.94x), which is why the ratio against it **fell from 15-26x to 14-18x** with no change to either program that explains it. A ratio between a Python program and a
  loop that is bound by system calls depends on the machine; neither run is the "true" one, and the page quotes the second, the
  one on the current code.
* **Against Go: 1.3-1.4x here, 1.08-1.6x there.** Go lost less than cancho on a read (0.82x of its first-run figure against 0.65x), and cancho's page got faster where Go's lost 18%, so the ratio on a read fell (1.6x to 1.28x) and on a page rose (1.08x to 1.40x).
* **Against the hand-written C floor, cancho is ahead on a read and a page (1.10x) and behind on a rejected body (0.94x) and a create (0.89x).** The first run had the page at 0.67x and the
  others at 0.70-0.88x. On the page the C floor lost what the VM took (105,523 to 68,144, 0.65x) and cancho's did not (70,768 to 75,286, 1.06x), and that cancho's page is *faster* in
  absolute terms on a slower VM is not explained here: the compiler revision and the program both changed since the first run, and neither was bisected. Treat the page ratio as the least settled.
* **The p99 is 0.55 ms against FastAPI's 10.8 ms** (the first run: 0.44 against 11.8); against Go it is two thirds of Go's, where it was half.
* **A single median of three.** The spread of a repeat on this VM is about 5%, a create up to 10%, so 0.94x and 0.89x on the C floor are real differences only if the other run's direction (0.88x and 0.70x) is
  counted too: both runs have it behind there.

## Two cores each (2026-10-08)

`run.sh` is one core against one core, and FastAPI is not normally deployed that way. `benches/run_cores.sh` gives every server cores 0 and 1 and `kload` cores 2 and 3 of the same
4-vCPU VM, with the one-core figure of each beside it. The workloads are the ones that share no state, because every process keeps its own store (a read of a stored user would find it on one worker and
not on the other): `GET /health`, `POST /users` with a body that is refused, `GET /users?limit=0`. Median of 3, five seconds.

| requests a second | GET /health | POST, invalid | GET ?limit=0 |
|---|---:|---:|---:|
| cancho, 1 process | 77,478 | 55,888 | 63,260 |
| **cancho, 2 processes** (`users <port> reuseport`, twice) | **115,443** | **90,064** | **105,987** |
| cancho, 2 threads of 1 process (`users_threads`) | 126,256 | 89,753 | 111,814 |
| Go `net/http`, 1 core | 44,886 | 35,088 | 39,676 |
| Go `net/http`, 2 cores | 58,956 | 45,593 | 50,540 |
| FastAPI lean, 1 worker | 3,414 | 2,262 | 2,332 |
| FastAPI lean, 2 workers | 6,169 | 4,307 | 4,217 |

| what the second core gave | GET /health | POST, invalid | GET ?limit=0 |
|---|---:|---:|---:|
| cancho, 2 processes | 1.49x | 1.61x | 1.68x |
| cancho, 2 threads | 1.63x | 1.61x | 1.77x |
| Go | 1.31x | 1.30x | 1.27x |
| FastAPI lean | 1.81x | 1.90x | 1.81x |

| cancho, 2 processes, against | GET /health | POST, invalid | GET ?limit=0 |
|---|---:|---:|---:|
| FastAPI, 2 workers | 18.7x | 20.9x | 25.1x |
| Go, 2 cores | 1.96x | 1.98x | 2.10x |
| (one core each: FastAPI) | 22.7x | 24.7x | 27.1x |

* **The second core narrows the gap with FastAPI and does not close it.** FastAPI scales best (1.8-1.9x), cancho 1.5-1.8x, Go 1.3x; against FastAPI's two workers cancho's two processes are 19-25x ahead, against 23-27x at one core.
  **One cancho process is ahead of two FastAPI workers** by 13-15x on these workloads (77,478 against 6,169 on a health check).
* **Threads and processes are the same within the noise**, as the earlier comparison found (`Two threads in one process`, above), and the threads example keeps a store each, so it is not a deployable service.
* **cancho's two-core figures may be understated.** At 115,000 a second `kload` is near the most it was shown to drive on the first VM (131,000-142,000, checked there by giving it a third core), and that check was **not repeated on this VM**.
  The ratios against FastAPI and Go are therefore lower bounds for the cancho side; the second core's gain for cancho may be larger than 1.5-1.8x.
* **Go on two cores was not tuned** (`GOMAXPROCS` is the two visible cores, the default GC), and its 1.3x says more about that than about Go. A Go with `fasthttp` or a Rust `axum` would be a stronger yardstick and was not measured.
* **Not measured:** four cores for the server (the VM has four, and the load generator needs two), a workload with state (a store shared between workers is not built), and memory.
* An earlier version of this table was wrong and was discarded: `run_cores.sh` started one process for the "2 processes" row, so that row showed no scaling at all (77,622 against 77,251).
  It started two after the first table was seen to say something the code could not do, and each contender now runs in its own process group so that no worker outlives its row.

## Start-up and memory (2026-10-08)

Listed above as not measured. `benches/resources.py` starts each server five times and records the time from `exec` to the first answered `GET /health`, and its resident memory
(`VmRSS` of the process and everything it started, so a uvicorn master and its workers count) at four moments: idle, after 1,000 users were created through it, with 100 more keep-alive
connections held open and silent, and its high-water mark (`VmHWM`) after 20,000 requests on 16 connections. Medians of 5. The servers are not pinned: this is about size, not speed.

| median of 5 | start-up (ms) | idle (MiB) | 1,000 users (MiB) | 100 idle connections (MiB) | peak after 20,000 requests (MiB) |
|---|---:|---:|---:|---:|---:|
| cancho users | 4 | 1.8 | 2.0 | 2.0 | 2.1 |
| Go `net/http` | 6 | 7.4 | 11.8 | 12.1 | 14.1 |
| hand-written C (epoll) | 4 | 1.8 | 2.2 | 6.7 | 6.5 |
| FastAPI lean, uvloop + httptools | 486 | 47.2 | 47.4 | 47.7 | 47.8 |
| FastAPI lean, 2 workers | 586 | 131.4 | 131.6 | 132.1 | 132.2 |

* **cancho is as small as the hand-written C server at rest and smaller with connections open**: 2.0 MiB with 100 idle connections, where the C server's per-connection buffers
  take it to 6.7 MiB. Go is 4 times larger idle and 6-7 times with connections open or after a run; FastAPI 24-26 times (one worker) and 66-73 times (two).
* **What is not shown.** The memory of `http.server` is sized at start from its limits (a connection's buffer, a total budget of 256 MiB for input, up to 1,024 connections), and
  a resident figure counts only the pages that were touched: **100 idle connections is the light end, and a server with many busy ones, or a store near its 64 MiB, is larger.** The store here
  held 1,000 small users. A real handler's memory is a real handler's.
* **The start-up of FastAPI is Python importing**, half a second to the first answer, and is no fault of the framework's design. Neither server was started cold from a disk that had not been read: the
  figures are with the files in the page cache.
* The memory is a *size* result and was not repeated on another machine; the processes are the ones `run.sh` builds.

## Does the size of the API matter? (2026-10-08)

`web.dispatch` finds an operation's parameters through an index (`docs/design.md` §9.10), so a request should cost the parameters of its operation and not the size of the API.
That was argued, and the first implementation (which scanned every declaration record per request) showed it could fail: 6.5% on an API of six operations. `benches/scale.sh` asks it directly.
`users <port> - <n>` declares `n` more operations after the six real ones (`GET /filler/<i>/:id`, each with a path parameter, nothing answers them), so the same requests go to the same
six routes in an API of 6, 206 and 2,006 operations. Five rounds, alternating the sizes, server on core 0, `kload` on cores 2 and 3, median of 5.

| requests a second | GET one user | GET a page of 20 | GET `?limit=0` (refused) |
|---|---:|---:|---:|
| 6 operations | 71,219 | 62,681 | 61,446 |
| 206 operations | 72,588 | 63,027 | 62,643 |
| 2,006 operations | 73,532 | 61,968 | 63,555 |

**No dependence on the size of the API**: every cell is within 3.5% of the six-operation figure, in both directions, which is inside what this VM moves by (about 5%). (The absolute figures are lower than in the run above:
this was a different session of the same VM, and the machine drifts between sessions; only the three rows of this table share one.) That includes the router, which holds all 2,006 routes.

**What does grow is the start-up.** Declaring operations was never the cost; generating the OpenAPI document was. It rescanned every record of the declaration, inside loops that already did, and called `op_at`, itself a scan.
`op_at` is now a lookup in the index `operation` keeps (a one-line change; the document is byte-identical, which the unit tests and the end-to-end comparison check):

| operations declared | start-up before | start-up after |
|---|---:|---:|
| 200 | 0.04 s | 0.01 s |
| 1,000 | 1.76 s | 0.13 s |
| 2,000 | 12.77 s | 0.29 s |
| 4,000 | 102.58 s | 1.11 s |
| 10,000 | (not run) | 8.05 s |

It is **still quadratic** (10,000 operations take 8 s, 2.5 times as many as 4,000 for 7 times the time), and nothing here has an API that large: `cancho-hooks` has 28 operations, the users API 6. The cost is
paid once, before the first request is accepted. The filler count is capped at 10,000 for that reason. `docs/design.md` §8 said declaring was `O(1)` and that `openapi` "scans them once"; declaring was, and the second half was not true, and is corrected there.

## Dispatch: a change measured (2026-10-08)

`web.dispatch` (`docs/design.md` §9) judges the declared parameters of every request before the handler runs. Whether that was free is
what `benches/ab.sh` answers: two builds of `examples/users` (`main` and the branch), alternated round by round so a drift of the machine lands on
both, on the workloads above plus `GET /users?limit=0`, six rounds, server on core 0, `kload` on cores 2 and 3.

**This VM is slower than the one above** (a read here is about 86,000 a second, not 129,000), so only the ratios mean anything.

| requests a second, median of 6 | before | after | after / before |
|---|---:|---:|---:|
| GET one user | 86,140 | 84,816 | 0.985 |
| GET a page of 20 | 76,294 | 74,451 | 0.976 |
| POST, invalid body (422) | 63,011 | 62,739 | 0.996 |
| POST, create | 55,507 | 54,559 | 0.983 |
| GET `/users?limit=0` (a parameter refused) | 81,516 | 73,011 | **0.896** |

Within the 5% this VM moves by, except the refusal of a parameter, which is 10% slower: two passes over the request, and a JSON document per error where the
hand-written code wrote one sentence. **The first implementation was slower on a read (0.93-0.94, in two runs)**: it scanned every record of the
declaration for each request. Giving each operation an index and a chain of its own parameters removed that, and a pass that allocates nothing for
a request that is fine removed the rest; `docs/design.md` §9.10.

## Stronger yardsticks: Go fasthttp and Rust axum (2026-10-08)

FastAPI is the comparison people ask for, but not the hardest one. Two more servers were written to the same
workload as `benches/go_users` (same routes, same limits, hand-written range checks, same stored answer) and
added to `benches/run.sh`, which gates them with `equivalent.py` (16 requests, all agree) and `edges.py` (84 cases,
all agree except the two known ones, listed below) before any timing:

* `benches/fasthttp_users`: Go with `valyala/fasthttp` v1.75.0, the Go server people reach for when `net/http` is
  too slow. Its `go.mod` asks for Go 1.26.0, so it was built with that toolchain, while `go_users` was built with
  1.24.7 on the same machine; the two Go servers are not the same compiler.
* `benches/axum_users`: Rust, axum 0.8 on tokio's `current_thread` runtime (one thread, like everything else here),
  serde_json into a struct with `deny_unknown_fields`, `TCP_NODELAY` on, release profile with LTO.

One core each, median of 3, 5 s runs, in a single run of `run.sh` on one VM. This VM was slower than the one behind
the tables above (cancho's GET one is 72,153 here against 83,289 there), so the numbers below are to be read against
each other, not against those.

| requests a second | GET one | page of 20 | rejected body | create |
|---|---:|---:|---:|---:|
| cancho | 72,153 | 62,320 | 55,136 | 42,562 |
| Go fasthttp | **80,150** | 54,236 | 53,872 | **45,428** |
| hand-written C (epoll) | 61,126 | 54,812 | 55,804 | 51,543 |
| Go `net/http` | 43,616 | 36,259 | 32,841 | 27,991 |
| Rust axum (one thread) | 39,747 | 38,803 | 33,196 | 32,241 |
| FastAPI lean (uvloop + httptools) | 3,184 | 2,832 | 2,198 | 2,606 |

GET one user, latency under that load, microseconds (p50 p90 p99 p99.9):

| | p50 | p90 | p99 | p99.9 |
|---|---:|---:|---:|---:|
| cancho | 280 | 457 | 765 | 2,772 |
| Go fasthttp | 262 | 440 | 739 | 2,270 |
| Go `net/http` | 560 | 817 | 1,499 | 3,092 |
| Rust axum | 533 | 763 | 1,196 | 2,759 |

What it shows, and what it does not:

* **fasthttp is faster than cancho on a single-user read** (80,150 against 72,153, 11% ahead) and on a create
  (7% ahead); cancho is ahead on a page of 20 (15%) and about level on a rejected body (2%). The earlier claim that
  cancho beats Go holds against `net/http`, the standard library; it does not hold against the Go server written
  for speed. A service cancho-web builds is in the same league as that one, not above it.
* **cancho is 1.3-1.8x ahead of axum** on one thread, and 1.5-1.7x ahead of `net/http`. axum here pays for tower's
  layers, a `Router`, extractors and serde; it is the idiomatic way to write it, not the fastest Rust could be.
  A hand-tuned `hyper` service would be nearer.
* the hand-written C server is slower than cancho on the reads in this run (61,126 against 72,153), which it was
  not in the run above (75,734 against 83,289). The C server did not change; the machine did, and C's two
  numbers came out lower relative to the rest. Single runs on a shared VM move individual rows by 10% or more,
  so none of the orderings within 10% of each other here (cancho, fasthttp, C) is established.
* the repeated-key and lone-surrogate edge cases differ across servers by design (`edges.py` prints them):
  cancho keeps the first of a repeated key, Go the last, axum refuses it (fasthttp's server accepts it; which key it keeps was not checked); a lone `\ud83d` escape is a
  400 on cancho, axum and C, and a 201 on both Go servers.
* not measured: more than one core for these two servers, memory, and start-up.
