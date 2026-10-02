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
| **lex-sys users** | **120,342** | **39,350** | **93,414** | **73,976** |
| FastAPI, uvicorn (asyncio) | 4,921 | 4,300 | 3,481 | 4,182 |
| FastAPI, uvloop + httptools | 4,675 | 4,144 | 3,532 | 4,100 |
| FastAPI lean, uvloop + httptools | 5,232 | 4,556 | 3,401 | 4,495 |

About **23x** on a read, **9x** on a page, **26x** on a rejected body and **16x** on a
create, against the best FastAPI figure in each column.

Latency of `GET one user` under that load (32 requests in flight, so each figure is a
service time *plus the queue of the others*):

| | p50 | p90 | p99 | p99.9 | max |
|---|---:|---:|---:|---:|---:|
| lex-sys users | 159 µs | 211 µs | 362 µs | 944 µs | 17.1 ms |
| FastAPI, uvicorn | 5.0 ms | 8.6 ms | 14.0 ms | 24.3 ms | 42.9 ms |

## How to read it

* **It is one core against one core.** Neither server uses a second; FastAPI is normally
  run with several worker processes, and lex-sys with `reuseport` copies. Per-core is the
  fair comparison and not what a deployment does.
* **FastAPI is CPU-bound in Python, not in its server.** uvloop and httptools, which speed
  up the network layer, change almost nothing (they are within noise of plain asyncio, and
  slightly lower on two columns), and the lean variant -- no response validation -- gains
  about 10%. What is left is routing, dependency resolution and pydantic.
* **The page is the narrowest gap (9x), and the reason is in the service.** Listing 20
  users splices 20 stored JSON values through `json.put_fragment`, each checked by the
  strict parser. That check costs, and it is the price of a writer that cannot produce an
  invalid document. Rendering from structured data instead of re-validating stored text
  would be faster and is not done here.
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

Requests a second, median of 3 (the FastAPI row is the best of its three set-ups):

| | GET one user | GET a page of 20 | POST, invalid (422) | POST, create |
|---|---:|---:|---:|---:|
| C ceiling (canned reply) | 137,203 | -- | -- | -- |
| C floor | 112,880 | 99,904 | 107,945 | 94,848 |
| **lex-sys users** | **119,852** | **40,755** | **92,070** | **69,446** |
| Go `net/http` | 77,593 | 65,296 | 61,539 | 49,436 |
| FastAPI, best of three | 5,145 | 4,524 | 3,632 | 4,238 |

| lex-sys against | GET one | page | invalid | create |
|---|---:|---:|---:|---:|
| Go | **1.5x** | **0.62x** | **1.5x** | **1.4x** |
| C floor | 1.06x (a tie) | 0.41x | 0.85x | 0.73x |
| C ceiling | 0.87x | | | |

Latency of GET one user under the same load (32 requests in flight; microseconds):

| | p50 | p90 | p99 | p99.9 | max |
|---|---:|---:|---:|---:|---:|
| C ceiling | 138 | 220 | 378 | 953 | 23,927 |
| lex-sys users | 167 | 250 | 408 | 1,312 | 7,249 |
| C floor | 178 | 245 | 430 | 1,261 | 6,629 |
| Go `net/http` | 316 | 484 | 809 | 2,013 | 4,935 |
| FastAPI, uvicorn | 5,113 | 8,574 | 11,970 | 14,585 | 19,169 |

### What it says

* **On a read, lex-sys is where a hand-written C server is, and 13% under the kernel's
  limit.** The two are within noise (119,852 against 112,880), and the ceiling shows why
  there is little room above them: one core spends about 7 microseconds a request in the
  socket path, `epoll_wait`, `read` and `send`, before any server code runs. The C floor
  being *slower* than lex-sys on a read is not a claim that lex-sys beats C -- the floor
  formats its headers with `snprintf` and was not tuned further; it is a reminder that the
  floor is a hand-written baseline, and the ceiling is the bound.
* **It is ahead of Go by about 1.5x on everything but a page**, with half the p99. That is
  Go's goroutine-per-connection runtime and GC on one core, against a loop with neither;
  it is not a statement about Go with several cores, which was not measured.
* **The page is where lex-sys loses, and the cause is known.** 20 users spliced into a page
  cost lex-sys about 25 microseconds and the C floor about 10: `put_fragment` re-parses each
  stored user with the strict parser (§"How to read it" above). Go beats it too, 1.6x. A page
  rendered from structured data instead of re-validated text is the obvious change and is not
  made here, so the figure stands as measured.
* **On a create lex-sys serves 27% fewer requests a second than the C floor, and on a
  rejected body 15% fewer.** Probably because it parses, validates and writes the canonical
  answer in separate passes where the floor does all three in one; that was not profiled.
* **The load generator was checked, not assumed.** `kload` used about 3.4 s of CPU in 5 on its
  two cores, and giving it a third core did not raise the ceiling's throughput (131,000-142,000
  either way), so it is not what limits the figures in this table.

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
