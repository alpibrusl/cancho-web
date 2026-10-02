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

## What is compared

`examples/users` (this repository, over `http.server` and `lexsys-schema`) and the
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
| **lex-sys users** | **128,972** | **70,768** | **94,659** | **64,327** |
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
| lex-sys users | 156 µs | 270 µs | 442 µs | 1.1 ms | 17.0 ms |
| FastAPI, uvicorn | 5.2 ms | 8.3 ms | 11.8 ms | 14.8 ms | 17.3 ms |

## How to read it

* **It is one core against one core.** Neither server uses a second; FastAPI is normally
  run with several worker processes, and lex-sys with `reuseport` copies. Per-core is the
  fair comparison and not what a deployment does.
* **FastAPI is CPU-bound in Python, not in its server.** uvloop and httptools, which speed
  up the network layer, change almost nothing (they are within noise of plain asyncio, and
  slightly lower on two columns), and the lean variant -- no response validation -- gains
  about 10%. What is left is routing, dependency resolution and pydantic.
* **The page was the narrowest gap, and the reason was in the service -- since fixed.**
  Listing 20 users spliced 20 stored JSON values through `json.put_fragment`, each checked
  by the strict parser, though each was the program's own canonical output. Splicing them
  as bytes took the page from about 40,000 to 62,000 requests a second, and a one-pass
  `std.buffer.append` (lex-sys `docs/http-server.md` §9) to 71,000.
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
LEX_SYS=/path/to/lex-sys benches/run.sh 3        # needs >= 4 cores for the pinning
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
lex-sys, Go, the C floor and FastAPI and refuses to start timing unless every status and
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
| **lex-sys users** | **128,972** | **70,768** | **94,659** | **64,327** |
| Go `net/http` | 79,772 | 65,654 | 60,278 | 53,580 |
| FastAPI, best of three | 5,216 | 4,604 | 3,606 | 4,163 |

| lex-sys against | GET one | page | invalid | create |
|---|---:|---:|---:|---:|
| Go | **1.6x** | **1.08x** | **1.6x** | **1.2x** |
| C floor | 1.09x (a tie) | 0.67x | 0.88x | 0.70x |
| C ceiling | 0.94x | | | |

Latency of GET one user under the same load (32 requests in flight; microseconds):

| | p50 | p90 | p99 | p99.9 | max |
|---|---:|---:|---:|---:|---:|
| C ceiling | 137 | 222 | 404 | 1,513 | 35,118 |
| lex-sys users | 156 | 270 | 442 | 1,140 | 16,995 |
| C floor | 178 | 269 | 433 | 1,158 | 19,645 |
| Go `net/http` | 325 | 483 | 850 | 1,770 | 6,937 |
| FastAPI, uvicorn | 5,161 | 8,318 | 11,842 | 14,805 | 17,341 |

### What it says

* **On a read, lex-sys is where a hand-written C server is, and at 94% of the kernel's
  limit.** The ceiling shows why there is little room above: one core spends about 7
  microseconds a request in the socket path, `epoll_wait`, `read` and `send`, before any
  server code runs. The C floor being no faster than lex-sys on a read is not a claim that
  lex-sys beats C -- the floor formats its headers with `snprintf` and was not tuned further;
  it is a reminder that the floor is a hand-written baseline, and the ceiling is the bound.
* **It is ahead of Go on every workload**, by 1.6x on a read and a rejected body, 1.2x on a
  create, and 1.08x on a page (within noise there), with half the p99. That is Go's
  goroutine-per-connection runtime and GC on one core, against a loop with neither; it is
  not a statement about Go with several cores, which was not measured.
* **The page was where lex-sys lost, twice over, and both causes were found by this
  comparison.** The first run had it at 40,755, 0.62x of Go and 0.41x of the C floor. The
  application re-parsed each stored user with the strict parser although it had itself
  rendered it (fixed: the users are spliced as bytes, 62,000), and `std.buffer.append` copied a
  byte at a time through `push`, which checks the capacity and rebuilds the buffer for every
  byte (fixed in lex-sys: 71,000). What remains against the C floor (0.67x) is the same shape:
  the page is still copied twice as bytes, once into the page and once into the reply, and the
  language has no slice-copy primitive (`bulk-io.md` §4 there).
* **On a create or a rejected body lex-sys serves 12-30% fewer requests than the C floor.**
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

* **A repeated key.** `{"name":"first","name":"second"}`: the lex-sys service keeps the
  **first**, Go and the C floor keep the last, and so does pydantic, which is what most
  clients expect of "last one wins". RFC 8259 leaves it open; the service's choice is a
  quirk worth deciding on, not a bug in the others. Shown by `edges.py`, not counted.
* **A lone surrogate** (`"\ud83d"`): the lex-sys service answers 400, as does the C floor
  (after the check found it accepting one); Go accepts it and stores U+FFFD. Not counted.
* **The C floor's own bugs**, found by the same check and fixed: a loose number scanner
  that turned `"age":-` into a 422 instead of a 400, and one `epoll_ctl` call per request
  (a syscall too many, worth about 10% on a read).
* **The C floor under AddressSanitizer and UBSan**, with 300 random and truncated requests
  as well as both check scripts, ran clean.

### What is not measured

Go with more than one core, or with Gin or fasthttp; Rust (axum on tokio); Node (Fastify);
a second core for lex-sys (`reuseport` copies); TLS; a real handler's work; resident memory
and start-up time. The Go and C servers leave out `/openapi.json`, and the C server also
chunked request bodies, and neither reads `150.0` as an integer as lex-sys does -- none of it
is on a benchmarked path.

## On PostgreSQL

`examples/users_pg` is the same API with PostgreSQL as its store (`lexsys-pg`'s driver, queries written
by `pgen` from `examples/users_pg/queries.sql`). It is compared with the same API in FastAPI twice,
because "FastAPI with a database" is not one number either:

| | |
|---|---|
| **lex-sys `users_pg`** | one connection, opened and logged in before it listens; every request that needs the database makes a **blocking** round trip on it (`http.server` is one loop, so the loop waits) |
| **FastAPI + SQLAlchemy 2 (async) + asyncpg** | what most FastAPI code with a database looks like: a session per request from a pool of 10, the ORM, a `response_model` |
| **FastAPI + asyncpg, lean** | a pool of 10 asyncpg connections, the same SQL as `queries.sql`, answers built without a model |

The work is held equal before anything is timed: `equivalent.py` sends all three the same sixteen
requests, each against its own fresh database, and the run stops unless statuses and successful bodies
agree. (`name` and `email` refuse U+0000 in all three: PostgreSQL text cannot hold it; see
`lexsys-schema`'s design.md §13.) The server under test is on core 0, **PostgreSQL on core 1**, the load
generator on cores 2 and 3, so the three do not share a core. Everything else is as above: 5 seconds of
load, median of 3, "create" a fixed 20,000 requests against a fresh table (it adds state).
`benches/run_pg.sh` reproduces it. PostgreSQL 16, default settings (`fsync` on), on the same VM.

### Results

Requests a second:

| | GET one user | GET a page of 20 | POST, invalid (422) | POST, create |
|---|---:|---:|---:|---:|
| **lex-sys `users_pg`** | **10,214** | **3,916** | **93,724** | **2,676** |
| FastAPI + SQLAlchemy + asyncpg | 1,040 | 572 | 3,273 | 809 |
| FastAPI + asyncpg, lean | 2,953 | 1,952 | 3,360 | 2,375 |

Latency of `GET one user` (32 requests in flight): lex-sys p50 2.3 ms, p99 5.0 ms; lean FastAPI p50 8.1 ms,
p99 25.9 ms; FastAPI + SQLAlchemy p50 21.8 ms, p99 58.2 ms.

And what PostgreSQL does alone on its core (`pgbench`, libpq, 16 clients, the same row lookup and the same
insert; no HTTP, no framework), transactions a second:

| protocol | get one row | insert |
|---|---:|---:|
| simple query | 15,012 | 8,975 |
| extended, parse every time (what `pg.extended` sends) | 12,577 | 8,304 |
| extended, prepared once | 26,787 | 12,159 |

### What it says

* **A read is PostgreSQL-bound, and lex-sys is close to the bound.** 10,214 requests a second is 81% of the
  12,577 that PostgreSQL itself answers over the same protocol, with the HTTP server, the JSON and the
  validation on top. Subtracting the 7.8 microseconds an in-memory read costs (129,000 a second, above) leaves
  **about 90 microseconds of loop time for one blocking round trip** to a PostgreSQL on its own core -- the
  low end of the 100-300 microseconds `lexsys-pg`'s design.md estimated before anything was measured.
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
  non-blocking-connection slice of `lexsys-pg` (design.md §5) -- and this is the number that says so.
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
* **Pool sizes** other than 10 for FastAPI, and a lex-sys service with more than one connection (which it cannot
  have until the connection stops blocking the loop).
* **Go, Rust and Node** with a database; and the cost of TLS to PostgreSQL, which `lexsys-pg` cannot do yet.

### Prepared statements

`pgen` now writes `prepare_all` and every generated function runs its statement by name (lexsys-pg, design.md
section 9): PostgreSQL parses and plans each query once per connection instead of on every call. The same run
times both builds of `users_pg` -- the one that parses on every call (the numbers above) and the one that does
not -- with the FastAPI services and `pgbench` in the same session, same machine, same pinning:

| requests a second, median of 3 (the create column is noisy: see below) | GET one user | GET a page of 20 | POST, invalid (422) | POST, create |
|---|---:|---:|---:|---:|
| **lex-sys `users_pg`, prepared** | **14,976** | **4,496** | **95,328** | **4,404** |
| lex-sys `users_pg`, parsing every call (before) | 9,788 | 3,865 | 90,902 | 2,748 |
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
  pool or a connection that does not block the loop would fill (lexsys-pg design.md section 5).
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
  loop to keep serving while a query is pending -- which is the design in lexsys-pg's `docs/nonblocking.md`.
