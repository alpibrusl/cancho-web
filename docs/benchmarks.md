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
